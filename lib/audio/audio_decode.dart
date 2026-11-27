import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/platform.dart';
import 'linux_ffmpeg.dart';

/// Turns a recording into the raw samples a recogniser can read.
///
/// This is the one piece of native code the whole voice feature needs, and it
/// exists because of an unavoidable mismatch: every recording this app makes
/// is AAC in an `.m4a`, and every speech model on earth wants 16 kHz mono
/// PCM. Nothing in Dart decodes AAC, and the four platforms each already have
/// a decoder in the box — `AVAudioConverter`, `MediaCodec`, Media Foundation
/// — so the job is to reach each of them, not to ship a fifth. Linux has none,
/// and uses the ffmpeg its packages already ship to record and play: see
/// [decodeWithFfmpeg].
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

  Duration get duration => Duration(
    milliseconds: sampleRate <= 0 ? 0 : (frames * 1000) ~/ sampleRate,
  );

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

/// The `kapynotes/audio_decode` channel, and ffmpeg on Linux.
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
    if (AppPlatform.isLinux) {
      return decodeWithFfmpeg(source, sampleRate: sampleRate);
    }
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

/// Raised when cleaned-up audio could not be saved as a recording.
///
/// Its own type for the reason [AudioDecodeException] is: samples that will
/// not encode now will not encode on a second try, and the honest thing to
/// tell somebody is that this recording could not be saved, with the original
/// still theirs, rather than to spin.
class AudioEncodeException implements Exception {
  const AudioEncodeException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The other direction of the `kapynotes/audio_decode` channel, and ffmpeg on
/// Linux.
///
/// Removing noise works on raw samples, so a cleaned recording comes back as
/// the same headerless 16-bit PCM [DecodedAudio] holds. But a note's recording
/// is AAC in an `.m4a` everywhere — it is what plays, syncs and shares — so
/// the samples have to go back into that before they can stand in for the
/// original. Every platform with a decoder in the box has the encoder beside
/// it — `AVAudioFile`, `MediaCodec` with `MediaMuxer`, Media Foundation's
/// sink writer — so this reaches them over the decoder's own channel rather
/// than a second one. Linux has [encodeWithFfmpeg].
///
/// ## Why both ends are files
///
/// For the reason [DecodedAudio] is one: thirty minutes of PCM is 57 MB, and
/// a method channel would hold it twice. The native side reads the samples a
/// chunk at a time and never holds the whole recording.
///
/// ## Why the destination is never half written
///
/// The encoder writes beside the destination and the finished file is renamed
/// into place, so a failure, or an app killed halfway through, leaves whatever
/// was there before rather than a recording that plays for a second and
/// stops. Beside it rather than in a temporary directory, so the rename never
/// crosses volumes; and ending in `.m4a`, because Apple's and Windows'
/// writers pick the container from the extension.
class AacEncoder {
  const AacEncoder({
    MethodChannel channel = const MethodChannel(AudioDecoder.channelName),
  }) : _channel = channel;

  final MethodChannel _channel;

  /// Encodes [pcm] — raw little-endian 16-bit mono at [sampleRate], no
  /// header — into a mono AAC-LC `.m4a` at [destination].
  ///
  /// The defaults are `VoiceRecorder.config`'s, so a cleaned recording is the
  /// same kind of file as the one it replaces. Windows bends them the way it
  /// bends a recording: its encoder takes only 44.1 or 48 kHz at 96 kbps or
  /// more, so it writes what a Windows recording would have been.
  Future<void> encode(
    File pcm,
    File destination, {
    int sampleRate = 16000,
    int bitRate = 48000,
  }) async {
    final partial = File('${destination.path}.part.m4a');
    try {
      if (await pcm.length() < 2) {
        throw const AudioEncodeException('This recording has no audio in it.');
      }
      if (AppPlatform.isLinux) {
        await encodeWithFfmpeg(
          pcm,
          partial,
          sampleRate: sampleRate,
          bitRate: bitRate,
        );
      } else {
        try {
          await _channel.invokeMethod<void>('encode', {
            'path': pcm.path,
            'destination': partial.path,
            'sampleRate': sampleRate,
            'bitRate': bitRate,
          });
        } on MissingPluginException {
          throw const AudioEncodeException(
            'This build cannot save recordings on the device.',
          );
        } on PlatformException catch (error) {
          throw AudioEncodeException(
            error.message ?? 'This recording could not be saved.',
          );
        }
      }
      await partial.rename(destination.path);
    } on Exception catch (error) {
      try {
        if (await partial.exists()) await partial.delete();
      } on FileSystemException {
        // A file that will not delete will not be renamed into place either;
        // the next save writes over it.
      }
      if (error is AudioEncodeException) rethrow;
      debugPrint('KapyNotes: could not save a recording: $error');
      throw const AudioEncodeException('This recording could not be saved.');
    }
  }
}
