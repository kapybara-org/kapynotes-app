import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// The sample rates an ADTS header can name, by the index it names them with.
const _rates = [
  96000, 88200, 64000, 48000, 44100, 32000, //
  24000, 22050, 16000, 12000, 11025, 8000, 7350,
];

/// Samples in one AAC-LC frame.
const _samplesPerFrame = 1024;

/// Frames to a chunk in the MPEG-4 file: about a second of speech at 16 kHz.
const _framesPerChunk = 16;

/// Rewraps a recording made as ADTS into the MPEG-4 file every recording is
/// kept as, or returns null when it holds not one whole frame.
///
/// Why a phone records ADTS at all: an MPEG-4 file is unreadable until it is
/// closed, because its index, the `moov` box, is written last. A recording
/// the system kills outright (out of memory, a crash, Force stop) is never
/// closed. ADTS puts a small header in front of every AAC frame instead, so
/// whatever reached the disk before the kill is still audio, all but the
/// frame being written. This reads the frames up to the first that is cut
/// short or makes no sense, which is where a kill stops a file, and writes
/// them out again with an index: the same AAC, so nothing is re-encoded, and
/// a file every player, the waveform and the upload already know.
Uint8List? mp4FromAdts(Uint8List adts) {
  final starts = <int>[];
  final sizes = <int>[];
  int? profile, rateIndex, channels;
  var offset = 0;
  while (offset + 7 <= adts.length) {
    // Twelve bits of sync, then the MPEG version, a layer of 0 and whether a
    // checksum follows the header.
    if (adts[offset] != 0xFF || adts[offset + 1] & 0xF6 != 0xF0) break;
    final header = adts[offset + 1] & 1 == 1 ? 7 : 9;
    final p = adts[offset + 2] >> 6;
    final r = (adts[offset + 2] >> 2) & 0xF;
    final c = ((adts[offset + 2] & 1) << 2) | (adts[offset + 3] >> 6);
    final length =
        ((adts[offset + 3] & 3) << 11) |
        (adts[offset + 4] << 3) |
        (adts[offset + 5] >> 5);
    final blocks = adts[offset + 6] & 3;
    if (r >= _rates.length || c == 0 || blocks != 0 || length <= header) break;
    if (profile != null && (p != profile || r != rateIndex || c != channels)) {
      break;
    }
    if (offset + length > adts.length) break;
    profile = p;
    rateIndex = r;
    channels = c;
    starts.add(offset + header);
    sizes.add(length - header);
    offset += length;
  }
  if (sizes.isEmpty) return null;

  final rate = _rates[rateIndex!];
  final channelCount = channels!;
  final frames = sizes.length;
  final duration = frames * _samplesPerFrame;
  final total = sizes.fold(0, (sum, size) => sum + size);
  final largest = sizes.reduce((a, b) => a > b ? a : b);
  final fullChunks = frames ~/ _framesPerChunk;
  final rest = frames % _framesPerChunk;
  final chunks = fullChunks + (rest > 0 ? 1 : 0);
  // The ES descriptor's AudioSpecificConfig: object type, rate, channels.
  final objectType = profile! + 1;
  final config = [
    (objectType << 3) | (rateIndex >> 1),
    ((rateIndex & 1) << 7) | (channelCount << 3),
  ];

  Uint8List moov(int dataStart) {
    final offsets = _Fields();
    var at = dataStart;
    for (var i = 0; i < frames; i++) {
      if (i % _framesPerChunk == 0) offsets.u32(at);
      at += sizes[i];
    }
    final table = _Fields();
    for (final size in sizes) {
      table.u32(size);
    }
    // Which chunks hold how many frames: all of them sixteen, but the last.
    final runs = _Fields()..u32((fullChunks > 0 ? 1 : 0) + (rest > 0 ? 1 : 0));
    if (fullChunks > 0) {
      runs
        ..u32(1)
        ..u32(_framesPerChunk)
        ..u32(1);
    }
    if (rest > 0) {
      runs
        ..u32(fullChunks + 1)
        ..u32(rest)
        ..u32(1);
    }
    final decoderConfig =
        (_Fields()
              ..u8(0x40) // MPEG-4 audio
              ..u8(0x15) // an audio stream
              ..u24(largest)
              ..u32(largest * 8 * rate ~/ _samplesPerFrame)
              ..u32(total * 8 * rate ~/ duration)
              ..bytes(_descriptor(0x05, config)))
            .done;
    final esDescriptor =
        (_Fields()
              ..u16(0) // ES_ID
              ..u8(0) // no dependence, URL or OCR stream
              ..bytes(_descriptor(0x04, decoderConfig))
              ..bytes(_descriptor(0x06, const [0x02])))
            .done;
    final mp4a = _box('mp4a', [
      (_Fields()
            ..zeros(6)
            ..u16(1) // data reference index
            ..zeros(8)
            ..u16(channelCount)
            ..u16(16) // bits per sample
            ..zeros(4)
            ..u32(rate << 16))
          .done,
      _fullBox('esds', [_descriptor(0x03, esDescriptor)]),
    ]);
    final stbl = _box('stbl', [
      _fullBox('stsd', [(_Fields()..u32(1)).done, mp4a]),
      _fullBox('stts', [
        (_Fields()
              ..u32(1)
              ..u32(frames)
              ..u32(_samplesPerFrame))
            .done,
      ]),
      _fullBox('stsc', [runs.done]),
      _fullBox('stsz', [
        (_Fields()
              ..u32(0)
              ..u32(frames))
            .done,
        table.done,
      ]),
      _fullBox('stco', [(_Fields()..u32(chunks)).done, offsets.done]),
    ]);
    final minf = _box('minf', [
      _fullBox('smhd', [Uint8List(4)]),
      _box('dinf', [
        _fullBox('dref', [
          (_Fields()..u32(1)).done,
          _fullBox('url ', const [], flags: 1),
        ]),
      ]),
      stbl,
    ]);
    final mdia = _box('mdia', [
      _fullBox('mdhd', [
        (_Fields()
              ..zeros(8)
              ..u32(rate)
              ..u32(duration)
              ..u16(0x55C4) // und
              ..u16(0))
            .done,
      ]),
      _fullBox('hdlr', [
        (_Fields()
              ..zeros(4)
              ..bytes(ascii.encode('soun'))
              ..zeros(12)
              ..bytes(ascii.encode('SoundHandler'))
              ..u8(0))
            .done,
      ]),
      minf,
    ]);
    final trak = _box('trak', [
      _fullBox('tkhd', [
        (_Fields()
              ..zeros(8)
              ..u32(1) // track id
              ..zeros(4)
              ..u32(duration)
              ..zeros(12)
              ..u16(0x0100) // full volume
              ..zeros(2)
              ..matrix()
              ..zeros(8))
            .done,
      ], flags: 7),
      mdia,
    ]);
    return _box('moov', [
      _fullBox('mvhd', [
        (_Fields()
              ..zeros(8)
              ..u32(rate)
              ..u32(duration)
              ..u32(0x00010000) // normal rate
              ..u16(0x0100) // full volume
              ..zeros(10)
              ..matrix()
              ..zeros(24)
              ..u32(2)) // next track id
            .done,
      ]),
      trak,
    ]);
  }

  final ftyp = _box('ftyp', [
    ascii.encode('M4A '),
    Uint8List(4),
    ascii.encode('M4A mp42isom'),
  ]);
  // Every offset in the index is the same width whatever it holds, so the
  // index measured with placeholders is the length of the real one.
  final dataStart = ftyp.length + moov(0).length + 8;
  final out = BytesBuilder(copy: false)
    ..add(ftyp)
    ..add(moov(dataStart))
    ..add(_u32(8 + total))
    ..add(ascii.encode('mdat'));
  for (var i = 0; i < frames; i++) {
    out.add(Uint8List.sublistView(adts, starts[i], starts[i] + sizes[i]));
  }
  return out.takeBytes();
}

/// Rewraps the ADTS recording at [adts] as the MPEG-4 file at [mp4], then
/// removes [adts]. Returns false, with nothing written, when it held no audio.
///
/// Off the main isolate: half an hour of speech is about 11 MB to walk.
/// [mp4] is complete before [adts] goes, so a recording cut off in here is
/// simply rewrapped again from [adts] on the next launch.
Future<bool> finishAdtsRecording(File adts, File mp4) async {
  final bytes = await adts.readAsBytes();
  final wrapped = await Isolate.run(() => mp4FromAdts(bytes));
  if (wrapped != null) await mp4.writeAsBytes(wrapped, flush: true);
  await adts.delete();
  return wrapped != null;
}

/// Where a phone writes the audio of a recording that ends up at [mp4Path].
String adtsBeside(String mp4Path) =>
    '${mp4Path.substring(0, mp4Path.length - '.m4a'.length)}.aac';

Uint8List _u32(int value) =>
    (ByteData(4)..setUint32(0, value)).buffer.asUint8List();

Uint8List _box(String type, List<List<int>> parts) {
  final out = BytesBuilder(copy: false)
    ..add(_u32(8 + parts.fold(0, (sum, part) => sum + part.length)))
    ..add(ascii.encode(type));
  for (final part in parts) {
    out.add(part);
  }
  return out.takeBytes();
}

/// A box that starts with a version, 0 here, and 24 bits of flags.
Uint8List _fullBox(String type, List<List<int>> parts, {int flags = 0}) =>
    _box(type, [_u32(flags), ...parts]);

/// An MPEG-4 descriptor, whose length always fits one byte here.
List<int> _descriptor(int tag, List<int> payload) => [
  tag,
  payload.length,
  ...payload,
];

/// Big-endian fields, written in order.
class _Fields {
  final _out = BytesBuilder();

  void u8(int value) => _out.addByte(value);

  void u16(int value) => _out
    ..addByte(value >> 8)
    ..addByte(value & 0xFF);

  void u24(int value) {
    u8(value >> 16);
    u16(value & 0xFFFF);
  }

  void u32(int value) => _out.add(_u32(value));

  void zeros(int count) => _out.add(Uint8List(count));

  void bytes(List<int> value) => _out.add(value);

  /// The identity matrix a movie and its track are drawn through.
  void matrix() {
    for (final value in const [
      0x10000,
      0,
      0,
      0,
      0x10000,
      0,
      0,
      0,
      0x40000000,
    ]) {
      u32(value);
    }
  }

  Uint8List get done => _out.takeBytes();
}
