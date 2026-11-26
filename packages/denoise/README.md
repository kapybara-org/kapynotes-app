# denoise

Takes the background noise out of a voice recording on the device, for
Remove noise. The model is DPDFNet-2 by Ceva (Apache-2.0), downloaded the
first time someone uses it; this package is what runs it.

- `rust/` is the library. It reads the ONNX file itself and runs its 25
  operators with plain loops (`src/engine.rs`), and wraps them in
  sherpa-onnx's signal path: a centred STFT with a Vorbis window, the model
  once per 10 ms frame, the inverse STFT and a four-frame shift
  (`src/lib.rs`). It streams, so a thirty-minute recording never sits in
  memory. On the reference clips its output matches sherpa-onnx's own
  denoiser to 2.4e-7.
- `prebuilt/` holds the built library for every target the app ships on.
  `hook/build.dart` hands Flutter the right one, so no build machine needs
  Rust.
- `lib/denoise.dart` is the Dart binding.
- `test/identity.onnx` is DPDFNet-2's inputs, outputs and metadata around a
  graph that passes them straight through, written by
  `tool/identity_model.py`. It tests the signal path without the 10 MB model.

## Changing the library

1. Edit `rust/` and run `cargo test --release` there.
2. Push. The Denoise library workflow runs on any change under `rust/`; it
   tests and builds every target and uploads them as one artifact,
   `prebuilt`.
3. Replace `prebuilt/` with that artifact's contents and commit it, quoting
   the run id. `prebuilt/SHA256SUMS` lists what each file should hash to.
