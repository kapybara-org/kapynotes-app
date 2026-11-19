import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'audio_decode.dart';

/// The one program every voice note on Linux goes through.
///
/// Linux has no audio API that a plugin can count on across distributions, so
/// recording, playback and the speech model's decode all run ffmpeg, talking
/// to PulseAudio — or to PipeWire's PulseAudio server, which is what a current
/// desktop runs. The packages ship one in `libexec/`, which the runner puts
/// first on `PATH`; a build run from the source tree finds the system's.
const String ffmpegExecutable = 'ffmpeg';

/// Starts ffmpeg with [arguments], quietly: no banner, nothing on stderr but
/// errors, and no reading keystrokes from stdin, which is either audio or
/// nothing.
Future<Process> startFfmpeg(List<String> arguments) => Process.start(
  ffmpegExecutable,
  ['-nostdin', '-hide_banner', '-loglevel', 'error', ...arguments],
);

/// What [process] said on stderr, once it has finished saying it.
///
/// Every caller reads it, and has to: a pipe nobody drains is one a chatty
/// ffmpeg eventually blocks on.
Future<String> ffmpegErrors(Process process) => process.stderr
    .transform(const Utf8Decoder(allowMalformed: true))
    .join()
    .then((text) => text.trim());

/// Whether there is an ffmpeg on `PATH` to run.
///
/// Asked before playing rather than discovered by failing to: a recording
/// that cannot be opened says so on its chip, where a player that never
/// starts would look as if it were playing silence.
Future<bool> ffmpegIsInstalled() async {
  final path = Platform.environment['PATH'] ?? '';
  for (final directory in path.split(':')) {
    if (directory.isEmpty) continue;
    if (await File('$directory/$ffmpegExecutable').exists()) return true;
  }
  return false;
}

/// Decodes [source] to mono 16-bit PCM at [sampleRate], for the speech model.
///
/// Linux's half of [AudioDecoder]. The other platforms each have a decoder in
/// the box to reach over a channel; here the box is the ffmpeg the packages
/// already ship to record and play, which reads AAC and resamples in one go.
/// The samples go to a file for the reason [DecodedAudio] gives.
Future<DecodedAudio> decodeWithFfmpeg(
  File source, {
  required int sampleRate,
}) async {
  final output = File(
    '${Directory.systemTemp.path}/kapy-decode-$pid-'
    '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}.pcm',
  );
  final Process process;
  try {
    process = await startFfmpeg([
      '-i',
      source.path,
      '-map',
      '0:a:0',
      '-ac',
      '1',
      '-ar',
      '$sampleRate',
      '-c:a',
      'pcm_s16le',
      '-f',
      's16le',
      '-y',
      output.path,
    ]);
  } on ProcessException catch (error) {
    debugPrint('KapyNotes: could not start ffmpeg to decode: $error');
    throw const AudioDecodeException(
      'This build cannot read recordings on the device.',
    );
  }
  final errors = ffmpegErrors(process);
  process.stdout.drain<void>().ignore();
  final code = await process.exitCode;
  final decoded = DecodedAudio(
    file: output,
    sampleRate: sampleRate,
    frames: await output.exists() ? await output.length() ~/ 2 : 0,
  );
  if (code != 0) {
    debugPrint(
      'KapyNotes: ffmpeg could not decode ${source.path}: ${await errors}',
    );
    await decoded.dispose();
    throw const AudioDecodeException('This recording could not be read.');
  }
  if (decoded.frames <= 0) {
    await decoded.dispose();
    throw const AudioDecodeException('This recording has no audio in it.');
  }
  return decoded;
}
