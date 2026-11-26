import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/audio/adts.dart';
import 'package:kapy_notes/audio/mp4_duration.dart';

/// Five seconds of a 440 Hz tone as a phone records it: AAC-LC, 16 kHz, mono,
/// 48 kbps, in ADTS. Made with
/// `ffmpeg -f lavfi -i sine=frequency=440:sample_rate=16000:duration=5
/// -ac 1 -c:a aac -b:a 48k -f adts tone_5s.aac`.
final _tone = File('test/fixtures/tone_5s.aac').readAsBytesSync();

/// The AAC in each ADTS frame of [adts], read here without the code under
/// test: every frame's length is in its own header.
List<Uint8List> _payloads(Uint8List adts) {
  final payloads = <Uint8List>[];
  var at = 0;
  while (at + 7 <= adts.length) {
    final length =
        ((adts[at + 3] & 3) << 11) | (adts[at + 4] << 3) | (adts[at + 5] >> 5);
    if (at + length > adts.length) break;
    payloads.add(Uint8List.sublistView(adts, at + 7, at + length));
    at += length;
  }
  return payloads;
}

/// The payload of the box at [path] in [bytes], such as `moov/trak`, less
/// its first [skip] bytes.
Uint8List _box(Uint8List bytes, String path, {int skip = 0}) {
  var data = bytes;
  for (final type in path.split('/')) {
    var at = 0;
    Uint8List? found;
    while (at + 8 <= data.length) {
      final size = ByteData.sublistView(data).getUint32(at);
      if (ascii.decode(data.sublist(at + 4, at + 8)) == type) {
        found = Uint8List.sublistView(data, at + 8, at + size);
        break;
      }
      at += size;
    }
    if (found == null) throw StateError('no $type in $path');
    data = found;
  }
  return Uint8List.sublistView(data, skip);
}

/// The frames an MPEG-4 file's index says it holds, read off its sample
/// sizes, its chunks' offsets and how many frames each chunk has.
List<Uint8List> _indexed(Uint8List mp4) {
  const stbl = 'moov/trak/mdia/minf/stbl';
  final sizes = ByteData.sublistView(_box(mp4, '$stbl/stsz'));
  final offsets = ByteData.sublistView(_box(mp4, '$stbl/stco'));
  final runs = ByteData.sublistView(_box(mp4, '$stbl/stsc'));
  final count = sizes.getUint32(8);
  final chunks = offsets.getUint32(4);
  int framesIn(int chunk) {
    var frames = 0;
    for (var i = 0; i < runs.getUint32(4); i++) {
      if (runs.getUint32(8 + i * 12) <= chunk + 1) {
        frames = runs.getUint32(12 + i * 12);
      }
    }
    return frames;
  }

  final frames = <Uint8List>[];
  for (var chunk = 0; chunk < chunks; chunk++) {
    var at = offsets.getUint32(8 + chunk * 4);
    for (var i = 0; i < framesIn(chunk); i++) {
      final size = sizes.getUint32(12 + frames.length * 4);
      frames.add(Uint8List.sublistView(mp4, at, at + size));
      at += size;
    }
  }
  expect(frames, hasLength(count));
  return frames;
}

void main() {
  test('a recording made as ADTS becomes an MPEG-4 file of the same audio', () {
    final mp4 = mp4FromAdts(_tone)!;
    final frames = _payloads(_tone);

    expect(ascii.decode(mp4.sublist(4, 8)), 'ftyp');
    expect(frames, hasLength(80));
    // 80 frames of 1024 samples at 16 kHz.
    expect(mp4DurationMs(mp4), 5120);
    expect(_indexed(mp4), frames);
  });

  test('its decoder is told what the frames are: AAC-LC, 16 kHz, mono', () {
    final mp4 = mp4FromAdts(_tone)!;
    final mp4a = _box(mp4, 'moov/trak/mdia/minf/stbl/stsd', skip: 8);
    expect(ascii.decode(mp4a.sublist(4, 8)), 'mp4a');
    final data = ByteData.sublistView(mp4a, 8);
    expect(data.getUint16(16), 1, reason: 'channels');
    expect(data.getUint32(24) >> 16, 16000, reason: 'sample rate');
    // The AudioSpecificConfig ends the esds box: object type 2 (LC),
    // rate index 8 (16 kHz), one channel.
    final esds = _box(Uint8List.sublistView(mp4a, 8 + 28), 'esds');
    final config = esds.sublist(esds.length - 5, esds.length - 3);
    expect(config, [0x14, 0x08]);
  });

  test('a recording cut off mid-frame keeps every whole frame before it', () {
    for (final cut in [1000, 9001, 15000, _tone.length - 1]) {
      final killed = Uint8List.sublistView(_tone, 0, cut);
      final whole = _payloads(killed);

      final mp4 = mp4FromAdts(killed)!;

      expect(_indexed(mp4), whole, reason: 'cut at $cut');
      expect(mp4DurationMs(mp4), whole.length * 1024 * 1000 ~/ 16000);
    }
  });

  test('chunks of sixteen frames, and a short one at the end', () {
    // 80 frames fill five chunks; 42 fill two and leave ten for a third.
    final full = mp4FromAdts(_tone)!;
    expect(
      ByteData.sublistView(
        _box(full, 'moov/trak/mdia/minf/stbl/stco'),
      ).getUint32(4),
      5,
    );
    final cut = _tone.sublist(0, 15000);
    final part = mp4FromAdts(cut)!;
    expect(_payloads(cut), hasLength(42));
    expect(
      ByteData.sublistView(
        _box(part, 'moov/trak/mdia/minf/stbl/stco'),
      ).getUint32(4),
      3,
    );
    expect(_indexed(part), _payloads(cut));
  });

  test('a file with not one whole frame in it gives nothing', () {
    expect(mp4FromAdts(Uint8List(0)), isNull);
    expect(mp4FromAdts(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8])), isNull);
    expect(mp4FromAdts(_tone.sublist(0, 7)), isNull);
  });

  test('reading stops where the frames stop making sense', () {
    final frames = _payloads(_tone);
    final first = 7 + frames[0].length;
    final damaged = Uint8List.fromList([
      ..._tone.sublist(0, first),
      ...List.filled(64, 0xAB),
      ..._tone.sublist(first),
    ]);

    expect(_indexed(mp4FromAdts(damaged)!), [frames[0]]);
  });

  group('finishAdtsRecording', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('kapy-adts'));
    tearDown(() => temp.deleteSync(recursive: true));

    test('leaves the MPEG-4 file and removes the ADTS', () async {
      final adts = File('${temp.path}/voice-1.aac')..writeAsBytesSync(_tone);
      final mp4 = File('${temp.path}/voice-1.m4a');

      expect(await finishAdtsRecording(adts, mp4), isTrue);

      expect(adts.existsSync(), isFalse);
      expect(mp4DurationMs(mp4.readAsBytesSync()), 5120);
    });

    test('with no audio in it, leaves nothing at all', () async {
      final adts = File('${temp.path}/voice-2.aac')..writeAsBytesSync([0xFF]);
      final mp4 = File('${temp.path}/voice-2.m4a');

      expect(await finishAdtsRecording(adts, mp4), isFalse);

      expect(adts.existsSync(), isFalse);
      expect(mp4.existsSync(), isFalse);
    });
  });

  test('the ADTS sits beside the MPEG-4 file it becomes', () {
    expect(adtsBeside('/tmp/voice-1-2.m4a'), '/tmp/voice-1-2.aac');
  });
}
