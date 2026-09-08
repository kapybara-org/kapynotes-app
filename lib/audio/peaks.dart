import 'dart:math' as math;
import 'dart:typed_data';

/// How many levels a waveform is drawn from: one per 1% of the recording.
///
/// Fixed, not proportional to length, so a thirty-second note and a
/// thirty-minute one cost the note record exactly the same 100 bytes — and the
/// chip's painter never has to decide how much of a long waveform to show.
const int peaksLength = 100;

/// Turns a recording's amplitude samples into the bytes the chip draws.
///
/// The samples arrive from `record`'s `onAmplitudeChanged` at 10 Hz in dBFS,
/// where 0 is the loudest the hardware can represent and quiet is a large
/// negative number. Deliberately *not* computed from PCM: decoding the audio
/// to find its shape would mean either a native decoder or pushing megabytes
/// through the UI isolate, for a picture 56 pixels tall.
///
/// [floor] is where silence is taken to start. -45 dBFS rather than the -160
/// some backends report for true digital silence, because a room's noise floor
/// sits around -50 and scaling from -160 would draw every recording as a
/// nearly flat line.
Uint8List bucketPeaks(List<double> samples, {double floor = -45}) {
  final peaks = Uint8List(peaksLength);
  if (samples.isEmpty) return peaks;

  for (var bucket = 0; bucket < peaksLength; bucket++) {
    // Spread the samples across the buckets rather than the other way round,
    // so a recording shorter than 100 samples still fills the width instead of
    // drawing a waveform that stops a third of the way along.
    final start = (bucket * samples.length) ~/ peaksLength;
    var end = ((bucket + 1) * samples.length) ~/ peaksLength;
    if (end <= start) end = start + 1;

    var loudest = double.negativeInfinity;
    for (var i = start; i < end && i < samples.length; i++) {
      final sample = samples[i];
      if (sample.isNaN) continue;
      if (sample > loudest) loudest = sample;
    }
    if (loudest == double.negativeInfinity) continue;

    // The peak, not the mean: speech is mostly gaps, and averaging them in
    // flattens a normal sentence into a barely visible ripple.
    final scaled = (loudest - floor) / (0 - floor);
    peaks[bucket] = (scaled.clamp(0.0, 1.0) * 255).round();
  }
  return peaks;
}

/// The level the recording bar shows, from one dBFS sample. 0 to 1.
double levelFromAmplitude(double dbfs, {double floor = -45}) {
  if (dbfs.isNaN) return 0;
  return math.max(0, math.min(1, (dbfs - floor) / (0 - floor)));
}
