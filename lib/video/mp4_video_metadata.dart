import 'dart:io';
import 'dart:typed_data';

import '../audio/mp4_duration.dart';
import 'video_ingest.dart';

/// Reads a video's display size and duration straight out of its MPEG-4 or
/// QuickTime container, for Linux, where there is no player in the app to
/// ask. Those are the only containers a note takes.
///
/// The size is the video track's `tkhd` size turned the way its matrix turns
/// it, so a phone's portrait clip measures tall, as the players elsewhere
/// report it. Null for anything without a video track or a duration.
Future<VideoMetadata?> readMp4VideoMetadata(File file) async {
  final bytes = await file.readAsBytes();
  final durationMs = mp4DurationMs(bytes);
  if (durationMs == null || durationMs <= 0) return null;
  final data = ByteData.sublistView(bytes);
  for (final moov in _boxes(data, 0, bytes.length, 'moov')) {
    for (final trak in _boxes(data, moov.start, moov.end, 'trak')) {
      if (!_isVideo(data, trak)) continue;
      final size = _displaySize(data, trak);
      if (size == null) continue;
      return VideoMetadata(
        width: size.width,
        height: size.height,
        durationMs: durationMs,
      );
    }
  }
  return null;
}

typedef _Box = ({int start, int end});

/// The children of the box spanning [from, to) named [type], in order. Stops
/// at the first size that does not fit, as a damaged file has.
Iterable<_Box> _boxes(ByteData data, int from, int to, String type) sync* {
  var offset = from;
  while (offset + 8 <= to) {
    var size = data.getUint32(offset);
    var header = 8;
    if (size == 1) {
      if (offset + 16 > to) return;
      size = data.getUint64(offset + 8);
      header = 16;
    } else if (size == 0) {
      size = to - offset;
    }
    if (size < header || offset + size > to) return;
    if (_type(data, offset + 4) == type) {
      yield (start: offset + header, end: offset + size);
    }
    offset += size;
  }
}

String _type(ByteData data, int at) =>
    String.fromCharCodes([for (var i = 0; i < 4; i++) data.getUint8(at + i)]);

bool _isVideo(ByteData data, _Box trak) {
  for (final mdia in _boxes(data, trak.start, trak.end, 'mdia')) {
    for (final hdlr in _boxes(data, mdia.start, mdia.end, 'hdlr')) {
      if (hdlr.start + 12 <= hdlr.end &&
          _type(data, hdlr.start + 8) == 'vide') {
        return true;
      }
    }
  }
  return false;
}

({int width, int height})? _displaySize(ByteData data, _Box trak) {
  for (final tkhd in _boxes(data, trak.start, trak.end, 'tkhd')) {
    final version = data.getUint8(tkhd.start);
    final matrix = tkhd.start + (version == 1 ? 52 : 40);
    if (version > 1 || matrix + 44 > tkhd.end) return null;
    final width = data.getUint32(matrix + 36) >> 16;
    final height = data.getUint32(matrix + 40) >> 16;
    if (width <= 0 || height <= 0) return null;
    final turned =
        data.getInt32(matrix) == 0 && data.getInt32(matrix + 16) == 0;
    return turned
        ? (width: height, height: width)
        : (width: width, height: height);
  }
  return null;
}
