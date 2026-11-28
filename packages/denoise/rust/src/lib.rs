//! Takes the background noise out of a voice recording, on the device.
//!
//! The model is DPDFNet-2 (Ceva, Apache-2.0), downloaded on demand and run
//! by the small engine in engine.rs. The signal path is sherpa-onnx's offline DPDFNet denoiser,
//! step for step, because that is what made the clips that were approved: a
//! centred STFT with reflect padding and a Vorbis window, the model once per
//! 10 ms frame with its state carried from frame to frame, the inverse STFT,
//! and a shift of four frames back for the model's look-ahead.
//!
//! It streams. Thirty minutes is 57 MB of 16-bit PCM in and the same out, and
//! this holds one window of each.

use std::collections::HashMap;
use std::ffi::CStr;
use std::fs::File;
use std::io::{self, BufReader, BufWriter, Read, Seek, SeekFrom, Write};
use std::os::raw::{c_char, c_int};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;
use std::sync::atomic::{AtomicI32, Ordering};

use realfft::num_complex::Complex32;
use realfft::RealFftPlanner;

mod engine;
use engine::{Engine, Tensor};

const N_FFT: usize = 320;
const HOP: usize = 160;
const BINS: usize = N_FFT / 2 + 1;
const PAD: usize = N_FFT / 2;
/// sherpa moves the waveform back by twice the window: the model answers for
/// a frame four frames after it hears it.
const SHIFT: usize = 2 * N_FFT;
/// A tenth of a second. Anything shorter is copied as it is.
const SHORTEST: usize = 1600;
const CHUNK: usize = 16_000;

/// The settings the signal path below is written for, as the model's own
/// metadata states them. A model that says anything else is refused rather
/// than cleaned with the wrong transform.
const EXPECTED: [(&str, &str); 10] = [
    ("model_type", "dpdfnet"),
    ("sample_rate", "16000"),
    ("n_fft", "320"),
    ("hop_length", "160"),
    ("window_length", "320"),
    ("window_type", "vorbis"),
    ("normalized", "0"),
    ("center", "1"),
    ("pad_mode", "reflect"),
    ("freq_bins", "161"),
];

pub const KD_OK: c_int = 0;
pub const KD_CANCELLED: c_int = 1;
pub const KD_BAD_MODEL: c_int = 2;
pub const KD_BAD_INPUT: c_int = 3;
pub const KD_WRITE_FAILED: c_int = 4;
pub const KD_FAILED: c_int = 5;

#[derive(Debug)]
pub enum Error {
    Cancelled,
    BadModel(String),
    BadInput(String),
    Write(String),
    Failed(String),
}

impl Error {
    fn code(&self) -> c_int {
        match self {
            Error::Cancelled => KD_CANCELLED,
            Error::BadModel(_) => KD_BAD_MODEL,
            Error::BadInput(_) => KD_BAD_INPUT,
            Error::Write(_) => KD_WRITE_FAILED,
            Error::Failed(_) => KD_FAILED,
        }
    }

    fn message(&self) -> String {
        match self {
            Error::Cancelled => "cancelled".into(),
            Error::BadModel(m) => format!("model: {m}"),
            Error::BadInput(m) => format!("input: {m}"),
            Error::Write(m) => format!("output: {m}"),
            Error::Failed(m) => m.clone(),
        }
    }
}

/// Somewhere the recording can be read from, a stretch at a time.
pub trait Samples {
    fn len(&self) -> usize;

    /// Fills [out] with the samples from [at] on, as floats in [-1, 1).
    fn read(&mut self, at: usize, out: &mut [f32]) -> io::Result<()>;
}

/// Raw little-endian signed 16-bit mono PCM: what the audio_decode channel
/// writes.
pub struct PcmFile {
    file: BufReader<File>,
    len: usize,
    pos: usize,
    bytes: Vec<u8>,
}

impl PcmFile {
    pub fn open(path: &Path) -> io::Result<Self> {
        let file = File::open(path)?;
        let len = (file.metadata()?.len() / 2) as usize;
        Ok(Self { file: BufReader::new(file), len, pos: 0, bytes: Vec::new() })
    }
}

impl Samples for PcmFile {
    fn len(&self) -> usize {
        self.len
    }

    fn read(&mut self, at: usize, out: &mut [f32]) -> io::Result<()> {
        if at != self.pos {
            self.file.seek(SeekFrom::Start(at as u64 * 2))?;
        }
        self.bytes.resize(out.len() * 2, 0);
        self.file.read_exact(&mut self.bytes)?;
        for (o, b) in out.iter_mut().zip(self.bytes.chunks_exact(2)) {
            *o = f32::from(i16::from_le_bytes([b[0], b[1]])) / 32768.0;
        }
        self.pos = at + out.len();
        Ok(())
    }
}

impl Samples for &[f32] {
    fn len(&self) -> usize {
        <[f32]>::len(self)
    }

    fn read(&mut self, at: usize, out: &mut [f32]) -> io::Result<()> {
        let end = at + out.len();
        if end > <[f32]>::len(self) {
            return Err(io::ErrorKind::UnexpectedEof.into());
        }
        out.copy_from_slice(&self[at..end]);
        Ok(())
    }
}

/// The recording with half a window reflected onto each end, as knf's
/// centred STFT pads it, read front to back one sample at a time.
struct Padded<'a, S: Samples + ?Sized> {
    src: &'a mut S,
    n: usize,
    /// Samples 1..=PAD, mirrored in front of the first.
    head: [f32; PAD],
    /// Samples n-PAD-1..n-1, mirrored after the last.
    tail: [f32; PAD],
    next: usize,
    chunk: Vec<f32>,
    chunk_at: usize,
}

impl<'a, S: Samples + ?Sized> Padded<'a, S> {
    fn new(src: &'a mut S) -> io::Result<Self> {
        let n = src.len();
        let mut head = [0.0; PAD];
        src.read(1, &mut head)?;
        let mut tail = [0.0; PAD];
        src.read(n - PAD - 1, &mut tail)?;
        Ok(Self { src, n, head, tail, next: 0, chunk: Vec::new(), chunk_at: 0 })
    }

    fn sample(&mut self) -> io::Result<f32> {
        let q = self.next;
        self.next += 1;
        if q < PAD {
            return Ok(self.head[PAD - 1 - q]);
        }
        let j = q - PAD;
        if j >= self.n {
            return Ok(self.tail[PAD - 1 - (j - self.n)]);
        }
        if j >= self.chunk_at + self.chunk.len() {
            self.chunk.resize(CHUNK.min(self.n - j), 0.0);
            self.src.read(j, &mut self.chunk)?;
            self.chunk_at = j;
        }
        Ok(self.chunk[j - self.chunk_at])
    }
}

fn vorbis() -> [f32; N_FFT] {
    let pi = std::f32::consts::PI;
    let half = N_FFT as f32 / 2.0;
    std::array::from_fn(|i| {
        let s = (0.5 * pi * (i as f32 + 0.5) / half).sin();
        (0.5 * pi * s * s).sin()
    })
}

/// The model's state before the first frame: its running ERB and spectrum
/// normalisation start where training left them, and everything else at zero,
/// the way sherpa-onnx builds it. Refuses a model whose signal settings are not
/// the ones this file implements.
pub fn start_state(meta: &HashMap<&str, &str>) -> Result<Vec<f32>, Error> {
    let get = |key: &str| {
        meta.get(key).copied().ok_or_else(|| Error::BadModel(format!("no {key} in its metadata")))
    };
    for (key, want) in EXPECTED {
        let got = get(key)?;
        if got != want {
            return Err(Error::BadModel(format!("{key} is {got}, not {want}")));
        }
    }
    let floats = |key: &str| -> Result<Vec<f32>, Error> {
        get(key)?
            .split(',')
            .map(|v| v.trim().parse::<f32>().map_err(|_| Error::BadModel(format!("{key} has {v}"))))
            .collect()
    };
    let size: usize =
        get("state_size")?.parse().map_err(|_| Error::BadModel("state_size is not a number".into()))?;
    let erb = floats("erb_norm_init")?;
    let spec = floats("spec_norm_init")?;
    if erb.len() + spec.len() > size {
        return Err(Error::BadModel("its start values are longer than its state".into()));
    }
    let mut state = vec![0.0; size];
    state[..erb.len()].copy_from_slice(&erb);
    state[erb.len()..erb.len() + spec.len()].copy_from_slice(&spec);
    Ok(state)
}

pub struct Denoiser {
    engine: Engine,
    state: Vec<f32>,
    window: [f32; N_FFT],
}

impl Denoiser {
    pub fn load(path: &Path) -> Result<Self, Error> {
        let bytes = std::fs::read(path).map_err(|e| Error::BadModel(e.to_string()))?;
        let (engine, meta) =
            Engine::load(&bytes, &["spec", "state_in"], &["spec_e", "state_out"]).map_err(Error::BadModel)?;
        let meta: HashMap<&str, &str> = meta.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
        let state = start_state(&meta)?;
        Ok(Self { engine, state, window: vorbis() })
    }

    /// One frame through the model: 161 bins as interleaved real and imaginary
    /// parts in, the cleaned bins out, and the state carried in place.
    pub fn frame(&self, bins: &[f32], state: &mut Vec<f32>) -> Result<Vec<f32>, Error> {
        let inputs = vec![
            Tensor::new(vec![1, 1, BINS, 2], bins.to_vec()),
            Tensor::new(vec![state.len()], std::mem::take(state)),
        ];
        let mut out = self.engine.run(inputs).map_err(Error::Failed)?;
        let next = out.pop().ok_or_else(|| Error::Failed("the model gave no state".into()))?;
        let cleaned = out.pop().ok_or_else(|| Error::Failed("the model gave no output".into()))?;
        if next.data.len() != self.state.len() || cleaned.data.len() != BINS * 2 {
            return Err(Error::Failed("the model's outputs have the wrong size".into()));
        }
        *state = next.data;
        Ok(cleaned.data)
    }

    /// Cleans every sample of [src] into [sink], which receives exactly as
    /// many as there are: the last four frames, which the model has not yet
    /// answered for when the recording ends, come out silent, as in sherpa.
    pub fn clean<S: Samples + ?Sized>(
        &self,
        src: &mut S,
        sink: &mut dyn FnMut(&[f32]) -> io::Result<()>,
        progress: &dyn Fn(usize, usize),
        cancelled: &dyn Fn() -> bool,
    ) -> Result<(), Error> {
        let bad_input = |e: io::Error| Error::BadInput(e.to_string());
        let write = |e: io::Error| Error::Write(e.to_string());
        let n = src.len();
        if n < SHORTEST {
            let mut all = vec![0.0; n];
            src.read(0, &mut all).map_err(bad_input)?;
            return sink(&all).map_err(write);
        }
        let frames = 1 + n / HOP;
        let total = N_FFT + (frames - 1) * HOP;
        let (keep_from, keep_to) = (PAD + SHIFT, total - PAD);

        let mut planner = RealFftPlanner::<f32>::new();
        let forward = planner.plan_fft_forward(N_FFT);
        let inverse = planner.plan_fft_inverse(N_FFT);
        let mut frame = forward.make_input_vec();
        let mut spectrum = forward.make_output_vec();
        let mut time = inverse.make_output_vec();
        let mut bins = vec![0.0f32; BINS * 2];
        let mut overlap = [0.0f32; N_FFT];
        let w = &self.window;
        let both: [f32; HOP] = std::array::from_fn(|k| w[k + HOP] * w[k + HOP] + w[k] * w[k]);
        let scale = 1.0 / N_FFT as f32;

        let mut padded = Padded::new(src).map_err(bad_input)?;
        let mut window = [0.0f32; N_FFT];
        for v in window.iter_mut() {
            *v = padded.sample().map_err(bad_input)?;
        }
        let mut state = self.state.clone();
        let mut out = Vec::with_capacity(HOP);
        let mut sent = 0;
        for i in 0..frames {
            if cancelled() {
                return Err(Error::Cancelled);
            }
            for k in 0..N_FFT {
                frame[k] = window[k] * w[k];
            }
            forward.process(&mut frame, &mut spectrum).map_err(|e| Error::Failed(e.to_string()))?;
            for (k, c) in spectrum.iter().enumerate() {
                bins[2 * k] = c.re;
                bins[2 * k + 1] = c.im;
            }
            bins[1] = 0.0;
            bins[2 * BINS - 1] = 0.0;
            let enhanced = self.frame(&bins, &mut state)?;
            for (k, c) in spectrum.iter_mut().enumerate() {
                *c = Complex32::new(enhanced[2 * k], enhanced[2 * k + 1]);
            }
            spectrum[0].im = 0.0;
            spectrum[BINS - 1].im = 0.0;
            inverse.process(&mut spectrum, &mut time).map_err(|e| Error::Failed(e.to_string()))?;
            for k in 0..N_FFT {
                overlap[k] += time[k] * scale * w[k];
            }

            out.clear();
            for k in 0..HOP {
                let at = i * HOP + k;
                if at >= keep_from && at < keep_to {
                    let d = if i == 0 { w[k] * w[k] } else { both[k] };
                    out.push(if d != 0.0 { overlap[k] / d } else { overlap[k] });
                }
            }
            if !out.is_empty() {
                sink(&out).map_err(write)?;
                sent += out.len();
            }
            overlap.copy_within(HOP.., 0);
            overlap[HOP..].fill(0.0);
            if i + 1 < frames {
                window.copy_within(HOP.., 0);
                for v in window[N_FFT - HOP..].iter_mut() {
                    *v = padded.sample().map_err(bad_input)?;
                }
            }
            progress(i + 1, frames);
        }
        let silence = [0.0f32; CHUNK];
        while sent < n {
            let take = CHUNK.min(n - sent);
            sink(&silence[..take]).map_err(write)?;
            sent += take;
        }
        Ok(())
    }
}

/// Cleans one decoded recording file into another, the same length and format.
pub fn clean_file(
    model: &Path,
    input: &Path,
    output: &Path,
    progress: &dyn Fn(usize, usize),
    cancelled: &dyn Fn() -> bool,
) -> Result<(), Error> {
    let denoiser = Denoiser::load(model)?;
    let mut src = PcmFile::open(input).map_err(|e| Error::BadInput(e.to_string()))?;
    let file = File::create(output).map_err(|e| Error::Write(e.to_string()))?;
    let mut writer = BufWriter::new(file);
    let mut bytes = Vec::with_capacity(HOP * 2);
    denoiser.clean(
        &mut src,
        &mut |samples| {
            bytes.clear();
            for v in samples {
                let s = (v.clamp(-1.0, 1.0) * 32767.0).round() as i16;
                bytes.extend_from_slice(&s.to_le_bytes());
            }
            writer.write_all(&bytes)
        },
        progress,
        cancelled,
    )?;
    writer.flush().map_err(|e| Error::Write(e.to_string()))
}

/// Bumped whenever the functions below change shape, so the Dart side can tell
/// an old library from a missing one.
#[no_mangle]
pub extern "C" fn kd_abi() -> c_int {
    1
}

/// Cleans [input], raw 16-bit little-endian mono PCM at 16 kHz, into [output]
/// in the same format and length, with the DPDFNet model at [model].
///
/// [progress], if not null, is set to the work done in ten-thousandths as it
/// goes; a nonzero [cancel] stops the run at the next frame. Both are plain
/// int32s the caller owns and may touch from another thread. On failure, up
/// to [message_len] bytes of a NUL-terminated reason go to [message].
///
/// # Safety
/// The three paths must be NUL-terminated UTF-8, [progress] and [cancel] null
/// or 4-byte aligned and alive for the call, and [message] null or at least
/// [message_len] bytes.
#[no_mangle]
pub unsafe extern "C" fn kd_clean(
    model: *const c_char,
    input: *const c_char,
    output: *const c_char,
    progress: *mut i32,
    cancel: *const i32,
    message: *mut c_char,
    message_len: usize,
) -> c_int {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let path = |p: *const c_char| -> Result<&Path, Error> {
            if p.is_null() {
                return Err(Error::Failed("a path is missing".into()));
            }
            CStr::from_ptr(p)
                .to_str()
                .map(Path::new)
                .map_err(|_| Error::Failed("a path is not UTF-8".into()))
        };
        let progress = (!progress.is_null()).then(|| &*(progress as *const AtomicI32));
        let cancel = (!cancel.is_null()).then(|| &*(cancel as *const AtomicI32));
        clean_file(
            path(model)?,
            path(input)?,
            path(output)?,
            &|done, total| {
                if let Some(p) = progress {
                    p.store((done * 10_000 / total) as i32, Ordering::Relaxed);
                }
            },
            &|| cancel.is_some_and(|c| c.load(Ordering::Relaxed) != 0),
        )
    }));
    let error = match result {
        Ok(Ok(())) => return KD_OK,
        Ok(Err(e)) => e,
        Err(_) => Error::Failed("the cleaner stopped unexpectedly".into()),
    };
    if !message.is_null() && message_len > 0 {
        let text = error.message();
        let len = text.len().min(message_len - 1);
        std::ptr::copy_nonoverlapping(text.as_ptr(), message as *mut u8, len);
        *message.add(len) = 0;
    }
    error.code()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn identity() -> Denoiser {
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../test/identity.onnx");
        Denoiser::load(&path).expect("the identity model loads")
    }

    fn signal(n: usize) -> Vec<f32> {
        let mut seed = 7u32;
        (0..n)
            .map(|i| {
                seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                let noise = (seed >> 8) as f32 / (1u32 << 24) as f32 - 0.5;
                0.4 * (i as f32 * 0.07).sin() + 0.1 * noise
            })
            .collect()
    }

    fn run(d: &Denoiser, input: &[f32], cancelled: &dyn Fn() -> bool) -> Result<Vec<f32>, Error> {
        let mut out = Vec::new();
        let mut src = input;
        d.clean(&mut src, &mut |s| Ok(out.extend_from_slice(s)), &|_, _| {}, cancelled)?;
        Ok(out)
    }

    #[test]
    fn the_window_overlaps_to_one() {
        let w = vorbis();
        for k in 0..HOP {
            assert!((w[k] * w[k] + w[k + HOP] * w[k + HOP] - 1.0).abs() < 1e-6);
        }
    }

    #[test]
    fn a_model_that_passes_the_spectrum_through_gives_back_the_input_moved_by_its_lookahead() {
        let n = 16_000 + 77;
        let input = signal(n);
        let out = run(&identity(), &input, &|| false).unwrap();
        assert_eq!(out.len(), n);
        let real = n / HOP * HOP - SHIFT;
        for m in 0..real {
            assert!((out[m] - input[m + SHIFT]).abs() < 1e-5, "sample {m}: {} vs {}", out[m], input[m + SHIFT]);
        }
        assert!(out[real..].iter().all(|v| *v == 0.0));
    }

    #[test]
    fn a_recording_too_short_to_clean_is_copied() {
        let input = signal(SHORTEST - 1);
        assert_eq!(run(&identity(), &input, &|| false).unwrap(), input);
    }

    #[test]
    fn a_cancelled_run_stops() {
        let input = signal(16_000);
        assert!(matches!(run(&identity(), &input, &|| true), Err(Error::Cancelled)));
    }

    #[test]
    fn the_start_state_is_the_two_norms_then_zeros() {
        let mut meta: HashMap<&str, &str> = EXPECTED.into_iter().collect();
        meta.insert("state_size", "6");
        meta.insert("erb_norm_init", "-60,-61");
        meta.insert("spec_norm_init", "0.001, 0.002");
        assert_eq!(start_state(&meta).unwrap(), vec![-60.0, -61.0, 0.001, 0.002, 0.0, 0.0]);
        meta.insert("n_fft", "512");
        assert!(matches!(start_state(&meta), Err(Error::BadModel(_))));
    }

    #[test]
    fn a_file_that_is_not_a_model_is_refused() {
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("Cargo.toml");
        assert!(matches!(Denoiser::load(&path), Err(Error::BadModel(_))));
    }
}
