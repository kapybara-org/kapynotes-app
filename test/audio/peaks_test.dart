import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/audio/peaks.dart';

void main() {
  group('bucketPeaks', () {
    test('always returns exactly the width the chip draws', () {
      for (final count in [0, 1, 7, 100, 999, 18000]) {
        final samples = List.filled(count, -20.0);
        expect(bucketPeaks(samples), hasLength(peaksLength));
      }
    });

    test('no samples is a flat line, not a crash', () {
      expect(bucketPeaks(const []).every((byte) => byte == 0), isTrue);
    });

    test('silence sits at the bottom and full scale at the top', () {
      expect(bucketPeaks(List.filled(100, -45.0)).first, 0);
      expect(bucketPeaks(List.filled(100, 0.0)).first, 255);
    });

    test('anything below the floor is clamped, not wrapped', () {
      // -160 is what some backends report for true digital silence. Without
      // the clamp this underflows and draws a full-height bar for silence.
      expect(bucketPeaks(List.filled(100, -160.0)).first, 0);
    });

    test('a bucket takes its loudest sample, not its mean', () {
      // Speech is mostly gaps. Averaging flattens a normal sentence.
      final samples = [for (var i = 0; i < 100; i++) i == 50 ? 0.0 : -45.0];
      expect(bucketPeaks(samples)[50], 255);
    });

    test('a recording shorter than the width still fills it', () {
      final peaks = bucketPeaks(List.filled(7, 0.0));
      expect(peaks.every((byte) => byte == 255), isTrue);
    });

    test('a long recording is spread across the whole width', () {
      // Loud only in the last tenth: the shape has to land at the end.
      final samples = [
        for (var i = 0; i < 10000; i++) i < 9000 ? -45.0 : 0.0,
      ];
      final peaks = bucketPeaks(samples);
      expect(peaks.first, 0);
      expect(peaks.last, 255);
      expect(peaks[85], 0);
      expect(peaks[95], 255);
    });

    test('a NaN sample is ignored rather than poisoning its bucket', () {
      // Two samples per bucket, one of them unusable: the real one still wins.
      final mixed = [
        for (var i = 0; i < 200; i++) i.isEven ? double.nan : 0.0,
      ];
      expect(bucketPeaks(mixed).every((byte) => byte == 255), isTrue);
    });

    test('nothing but NaN is a flat line, not a crash', () {
      final peaks = bucketPeaks(List.filled(100, double.nan));
      expect(peaks.every((byte) => byte == 0), isTrue);
    });
  });

  group('levelFromAmplitude', () {
    test('maps the floor to nothing and full scale to everything', () {
      expect(levelFromAmplitude(-45), 0);
      expect(levelFromAmplitude(0), 1);
      expect(levelFromAmplitude(-22.5), closeTo(0.5, 0.01));
    });

    test('stays inside 0..1 for anything a backend can report', () {
      expect(levelFromAmplitude(-160), 0);
      expect(levelFromAmplitude(12), 1);
      expect(levelFromAmplitude(double.nan), 0);
    });
  });
}
