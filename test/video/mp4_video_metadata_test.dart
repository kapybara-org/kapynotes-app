import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/video/mp4_video_metadata.dart';
import 'package:kapy_notes/video/video_ingest.dart';

List<int> _u32(int value) => [
  value >> 24 & 0xff,
  value >> 16 & 0xff,
  value >> 8 & 0xff,
  value & 0xff,
];

List<int> _box(String type, List<int> payload) => [
  ..._u32(payload.length + 8),
  ...type.codeUnits,
  ...payload,
];

const _identity = [0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000];
const _quarterTurn = [0, 0x00010000, 0, 0xFFFF0000, 0, 0, 0, 0, 0x40000000];

/// A container with only the boxes the reader looks at: a movie header
/// that says how long, and one track that says what it is and how big.
Uint8List _movie({
  String handler = 'vide',
  List<int> matrix = _identity,
  int width = 1920,
  int height = 1080,
  int timescale = 600,
  int duration = 3318,
}) {
  final mvhd = _box('mvhd', [
    ...List.filled(12, 0),
    ..._u32(timescale),
    ..._u32(duration),
    ...List.filled(80, 0),
  ]);
  final tkhd = _box('tkhd', [
    ...List.filled(40, 0),
    for (final entry in matrix) ..._u32(entry),
    ..._u32(width << 16),
    ..._u32(height << 16),
  ]);
  final hdlr = _box('hdlr', [
    ...List.filled(8, 0),
    ...handler.codeUnits,
    ...List.filled(13, 0),
  ]);
  final trak = _box('trak', [...tkhd, ..._box('mdia', hdlr)]);
  return Uint8List.fromList([
    ..._box('ftyp', 'isom\x00\x00\x02\x00isomiso2mp41'.codeUnits),
    ..._box('mdat', List.filled(64, 7)),
    ..._box('moov', [...mvhd, ...trak]),
  ]);
}

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('kapy-mp4');
  });

  tearDown(() async {
    AppPlatform.debugTargetPlatformOverride = null;
    await directory.delete(recursive: true);
  });

  Future<File> write(Uint8List bytes) async =>
      File('${directory.path}/clip.mp4')..writeAsBytesSync(bytes);

  test('reads the size and the length out of the container', () async {
    final metadata = await readMp4VideoMetadata(await write(_movie()));

    expect(metadata?.width, 1920);
    expect(metadata?.height, 1080);
    expect(metadata?.durationMs, 5530);
  });

  test('a portrait phone clip measures tall, as its matrix turns it', () async {
    final metadata = await readMp4VideoMetadata(
      await write(_movie(matrix: _quarterTurn)),
    );

    expect(metadata?.width, 1080);
    expect(metadata?.height, 1920);
  });

  test('a file with no video track is not a video', () async {
    expect(
      await readMp4VideoMetadata(await write(_movie(handler: 'soun'))),
      isNull,
    );
    expect(
      await readMp4VideoMetadata(
        await write(Uint8List.fromList(_box('mdat', List.filled(64, 1)))),
      ),
      isNull,
    );
  });

  test('Linux measures an added video without a player', () async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.linux;

    final metadata = await readVideoMetadata(await write(_movie()));

    expect(metadata?.width, 1920);
    expect(metadata?.durationMs, 5530);
  });
}
