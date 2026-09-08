import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/audio/mp4_duration.dart';

/// A box: 4-byte size, 4-byte type, payload.
Uint8List box(String type, List<int> payload, {bool largesize = false}) {
  final builder = BytesBuilder();
  if (largesize) {
    builder.add(Uint8List(4)..buffer.asByteData().setUint32(0, 1));
    builder.add(Uint8List.fromList(type.codeUnits));
    final size = ByteData(8)..setUint64(0, 16 + payload.length);
    builder.add(size.buffer.asUint8List());
  } else {
    final size = ByteData(4)..setUint32(0, 8 + payload.length);
    builder.add(size.buffer.asUint8List());
    builder.add(Uint8List.fromList(type.codeUnits));
  }
  builder.add(payload);
  return builder.toBytes();
}

/// A version-0 `mvhd` payload: version+flags, two times, timescale, duration.
List<int> mvhd0(int timescale, int duration) {
  final data = ByteData(100);
  data.setUint8(0, 0); // version 0
  data.setUint32(12, timescale);
  data.setUint32(16, duration);
  return data.buffer.asUint8List().sublist(0, 100);
}

List<int> mvhd1(int timescale, int duration) {
  final data = ByteData(112);
  data.setUint8(0, 1); // version 1
  data.setUint32(20, timescale);
  data.setUint64(24, duration);
  return data.buffer.asUint8List().sublist(0, 112);
}

void main() {
  group('real recordings', () {
    test('reads the duration with moov written last, as a recorder does', () {
      // The shape AVAudioRecorder and Android's MPEG4Writer produce: the
      // timing box is only written when the file is closed, so it lands after
      // a megabytes-long mdat.
      final bytes = File('test/fixtures/tone_5s.m4a').readAsBytesSync();
      final ms = mp4DurationMs(bytes);
      expect(ms, isNotNull);
      expect(ms, closeTo(5000, 200));
    });

    test('reads it just as well with moov written first', () {
      final bytes = File(
        'test/fixtures/tone_5s_faststart.m4a',
      ).readAsBytesSync();
      expect(mp4DurationMs(bytes), closeTo(5000, 200));
    });
  });

  group('box walking', () {
    Uint8List file(List<int> moovPayload, {List<int>? mdat}) => Uint8List.fromList([
      ...box('ftyp', List.filled(20, 0)),
      ...box('mdat', mdat ?? List.filled(64, 7)),
      ...box('moov', moovPayload),
    ]);

    test('a 64-bit mvhd is read at its own offsets', () {
      final bytes = file(box('mvhd', mvhd1(48000, 96000)));
      expect(mp4DurationMs(bytes), 2000);
    });

    test('a 32-bit mvhd is read at its own offsets', () {
      final bytes = file(box('mvhd', mvhd0(16000, 24000)));
      expect(mp4DurationMs(bytes), 1500);
    });

    test('a largesize box is skipped by its 64-bit length', () {
      final bytes = Uint8List.fromList([
        ...box('ftyp', List.filled(12, 0)),
        ...box('mdat', List.filled(64, 7), largesize: true),
        ...box('moov', box('mvhd', mvhd0(1000, 3500))),
      ]);
      expect(mp4DurationMs(bytes), 3500);
    });

    test('a size-0 mdat swallows the rest, so there is no moov to find', () {
      // What a writer killed mid-recording leaves behind. The point is that it
      // returns null instead of walking off the end.
      final bytes = Uint8List.fromList([
        ...box('ftyp', List.filled(12, 0)),
        0, 0, 0, 0, ...'mdat'.codeUnits, ...List.filled(64, 7),
      ]);
      expect(mp4DurationMs(bytes), isNull);
    });

    test('no moov at all is null, not a crash', () {
      expect(mp4DurationMs(Uint8List.fromList(box('ftyp', List.filled(12, 0)))), isNull);
    });

    test('a truncated moov is null', () {
      final full = file(box('mvhd', mvhd0(1000, 3500)));
      expect(mp4DurationMs(full.sublist(0, full.length - 40)), isNull);
    });

    test('an unwritten duration is null rather than 49 days', () {
      final bytes = file(box('mvhd', mvhd0(1000, 0xFFFFFFFF)));
      expect(mp4DurationMs(bytes), isNull);
    });

    test('a zero timescale cannot divide by zero', () {
      expect(mp4DurationMs(file(box('mvhd', mvhd0(0, 1000)))), isNull);
    });

    test('empty and tiny inputs are null', () {
      expect(mp4DurationMs(Uint8List(0)), isNull);
      expect(mp4DurationMs(Uint8List(5)), isNull);
    });

    test('a box claiming a size past the end stops the walk', () {
      final bytes = Uint8List.fromList([
        255, 255, 255, 255, ...'mdat'.codeUnits, 1, 2, 3, 4,
      ]);
      expect(mp4DurationMs(bytes), isNull);
    });
  });
}
