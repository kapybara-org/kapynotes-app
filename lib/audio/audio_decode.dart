import 'dart:io';

import 'package:flutter/services.dart';

/// Turns a recording into the raw samples a recogniser can read.
///
/// This is the one piece of native code the whole voice feature needs, and it
/// exists because of an unavoidable mismatch: every recording this app makes
/// is AAC in an `.m4a`, and every speech model on earth wants 16 kHz mono
/// PCM. Nothing in Dart decodes AAC, and the four platforms each already have
/// a decoder in the box — `AVAudioConverter`, `MediaCodec`, Media Foundation
/// — so the job is to reach each of them, not to ship a fifth.
///
/// Apple platforms running macOS or iOS 26 never come here at all: their
/// recogniser reads the `.m4a` itself. This is for everything else, and for
/// the older Macs and iPhones that fall back to the downloaded model.
///
/// ## Why the answer is a file
///
/// Thirty minutes — the longest recording the app will make — is 57 MB of
/// 16-bit PCM, and would be 115 MB as float32. Handing that back through a
/// method channel would mean the native buffer and the Dart copy alive at
/// once, on a phone, for a feature whose whole promise is that it costs the
/// user nothing. So the native side writes the samples to a file and this
/// returns the path; the recogniser's isolate reads it in windows and never
/// holds more than one at a time.
class DecodedAudio {
  const DecodedAudio({
    required this.file,
    required this.sampleRate,
    required this.frames,
  });

  /// Raw little-endian signed 16-bit PCM, one channel, no header.
  ///
  /// Sixteen bits rather than float32 because it halves the file for no loss
  /// that matters: these models are trained on 16-bit audio, and the widening
  /// to float happens a window at a time in the isolate anyway.
  final File file;

  final int sampleRate;

  /// Samples, not bytes. The length of the recording is
  /// `frames / sampleRate` seconds.
  final int frames;

  Duration get duration =>
      Duration(milliseconds: sampleRate <= 0 ? 0 : (frames * 1000) ~/ sampleRate);

  /// Throws away the decoded copy. The caller owns it: it is a derived file in
  /// a temporary directory, and leaving 57 MB behind after every transcript
  /// would be a slow leak nobody would attribute to this.
  Future<void> dispose() async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // A temp file the OS already reclaimed, or a directory gone read-only.
      // Neither is worth failing a finished transcript over.
    }
  }
}

/// Raised when a recording could not be decoded.
///
/// Its own type because the queue treats it as terminal: a file that will not
/// decode now will not decode on the fourth retry, and the honest thing to
/// tell somebody is that this recording cannot be read rather than to spin.
class AudioDecodeException implements Exception {
  const AudioDecodeException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The `kapynotes/audio_decode` channel.
class AudioDecoder {
  const AudioDecoder({MethodChannel channel = const MethodChannel(channelName)})
    : _channel = channel;

  static const String channelName = 'kapynotes/audio_decode';

  /// What every model in the catalogue is trained on. Not a parameter of the
  /// recording — a property of the recogniser — so it lives here rather than
  /// travelling from the caller.
  static const int modelSampleRate = 16000;

  final MethodChannel _channel;

  /// Decodes [source] to mono PCM at [sampleRate], resampling if it has to.
  ///
  /// The caller must [DecodedAudio.dispose] the result.
  Future<DecodedAudio> decode(
    File source, {
    int sampleRate = modelSampleRate,
  }) async {
    final Object? answer;
    try {
      answer = await _channel.invokeMethod<Object?>('decode', {
        'path': source.path,
        'sampleRate': sampleRate,
      });
    } on MissingPluginException {
      throw const AudioDecodeException(
        'This build cannot read recordings on the device.',
      );
    } on PlatformException catch (error) {
      throw AudioDecodeException(
        error.message ?? 'This recording could not be read.',
      );
    }
    if (answer is! Map) {
      throw const AudioDecodeException('This recording could not be read.');
    }
    final path = answer['path'];
    final frames = answer['frames'];
    if (path is! String || path.isEmpty || frames is! int || frames <= 0) {
      throw const AudioDecodeException('This recording came back empty.');
    }
    return DecodedAudio(
      file: File(path),
      sampleRate: answer['sampleRate'] is int
          ? answer['sampleRate']! as int
          : sampleRate,
      frames: frames,
    );
  }
}
