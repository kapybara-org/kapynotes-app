import 'dart:typed_data';

/// Reads a recording's duration out of its MPEG-4 container.
///
/// Needed because `record` reports what it *asked* for, not what was written:
/// a pause, an interruption, or a Windows encoder that clamped the sample rate
/// all leave the elapsed timer and the file disagreeing. The file is the truth,
/// and the chip's width is drawn from it.
///
/// The awkward part is where the answer lives. Both `AVAudioRecorder` and
/// Android's `MPEG4Writer` stream the audio out as they go and only write the
/// `moov` box — the one holding the timing — when the recording is *closed*.
/// So `moov` is usually the last top-level box, after a `mdat` that may be
/// megabytes long, and there is no way to know its offset without walking the
/// box list. This walks it.
///
/// Returns null for anything it cannot make sense of, which the caller treats
/// as "use the elapsed timer instead" rather than as a failure: a recording
/// with an unreadable header is still a recording.
int? mp4DurationMs(Uint8List bytes) {
  final moov = _findBox(bytes, 0, bytes.length, 'moov');
  if (moov == null) return null;
  final mvhd = _findBox(bytes, moov.start, moov.end, 'mvhd');
  if (mvhd == null) return null;

  final data = ByteData.sublistView(bytes);
  // [mvhd.start] is the first byte of the payload, past the size-and-type
  // header. The first byte there is the full-box version, and it decides the
  // width of the two times that follow — which is what moves everything after
  // them. Offsets below are payload-relative, so they read 8 less than the
  // ones quoted against the box start in the ISO spec.
  final at = mvhd.start;
  if (at + 1 > mvhd.end) return null;
  final version = bytes[at];

  final int timescale;
  final int duration;
  if (version == 0) {
    // version+flags 4, creation 4, modification 4, then timescale, duration.
    if (at + 20 > mvhd.end || at + 20 > bytes.length) return null;
    timescale = data.getUint32(at + 12);
    duration = data.getUint32(at + 16);
  } else if (version == 1) {
    // The two times are 8 bytes each here, and the duration is too.
    if (at + 32 > mvhd.end || at + 32 > bytes.length) return null;
    timescale = data.getUint32(at + 20);
    duration = data.getUint64(at + 24);
  } else {
    return null;
  }

  if (timescale <= 0 || duration <= 0) return null;
  // 0xFFFFFFFF is what a writer leaves behind when it never closed the file.
  if (version == 0 && duration == 0xFFFFFFFF) return null;
  return (duration * 1000) ~/ timescale;
}

/// A box's payload range, `[start, end)`, where `start` is the first byte
/// after the 8-byte size-and-type header.
typedef _Box = ({int start, int end});

/// Finds a direct child box named [type] between [from] and [to].
///
/// Sizes are the fiddly part of the format and all three encodings appear in
/// the wild: a 32-bit size, a 64-bit `largesize` flagged by a size of 1, and a
/// size of 0 meaning "the rest of the file" — which is exactly what a writer
/// that was killed mid-recording leaves on the `mdat`.
_Box? _findBox(Uint8List bytes, int from, int to, String type) {
  final data = ByteData.sublistView(bytes);
  var offset = from;
  while (offset + 8 <= to) {
    var size = data.getUint32(offset);
    var headerSize = 8;
    if (size == 1) {
      if (offset + 16 > to) return null;
      size = data.getUint64(offset + 8);
      headerSize = 16;
    } else if (size == 0) {
      size = to - offset;
    }
    // A size that does not advance, or runs past the end, means the file is
    // damaged. Stop rather than loop forever or read someone else's memory.
    if (size < headerSize || offset + size > to) return null;

    final name = String.fromCharCodes(bytes, offset + 4, offset + 8);
    if (name == type) {
      return (start: offset + headerSize, end: offset + size);
    }
    offset += size;
  }
  return null;
}
