import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/audio/audio_decode.dart';
import 'package:kapy_notes/audio/linux_ffmpeg.dart';
import 'package:kapy_notes/core/platform.dart';

/// Writing cleaned-up samples back out as a recording.
///
/// The native encoders are reached over a channel, so here they are a fake
/// that writes what the real ones are asked to; what Dart owns — the name the
/// file is written under, the rename into place and what a person is told
/// when it fails — is real. Linux's ffmpeg is the real one, where there is an
/// ffmpeg to run.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('kapy-encode-'));
  tearDown(() {
    AppPlatform.debugTargetPlatformOverride = null;
    temp.deleteSync(recursive: true);
  });

  /// [seconds] of a 440 Hz tone at half of full scale, as the noise remover
  /// leaves it: 16-bit little-endian mono at 16 kHz, no header.
  File tone(double seconds) {
    final frames = (seconds * 16000).round();
    final samples = ByteData(frames * 2);
    for (var i = 0; i < frames; i++) {
      final value = (16384 * sin(2 * pi * 440 * i / 16000)).round();
      samples.setInt16(i * 2, value, Endian.little);
    }
    return File('${temp.path}/cleaned.pcm')
      ..writeAsBytesSync(samples.buffer.asUint8List());
  }

  group('on the device', () {
    const channel = MethodChannel('test/audio_encode');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];

    /// Answers like the native encoder: writes to the name it was given, or
    /// leaves half a file there and fails with [failure].
    void encoder({PlatformException? failure}) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        final written = File((call.arguments as Map)['destination'] as String);
        if (failure != null) {
          written.writeAsBytesSync([0, 0]);
          throw failure;
        }
        written.writeAsBytesSync([1, 2, 3, 4]);
        return null;
      });
    }

    setUp(() {
      calls.clear();
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
    });
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('writes beside the destination, then moves it into place', () async {
      encoder();
      final pcm = tone(1);
      final destination = File('${temp.path}/voice.m4a');

      await const AacEncoder(channel: channel).encode(pcm, destination);

      expect(calls.single.method, 'encode');
      expect(calls.single.arguments, {
        'path': pcm.path,
        'destination': '${destination.path}.part.m4a',
        'sampleRate': 16000,
        'bitRate': 48000,
      });
      expect(destination.readAsBytesSync(), [1, 2, 3, 4]);
      expect(File('${destination.path}.part.m4a').existsSync(), isFalse);
    });

    test('passes on the rate and bit rate it is given', () async {
      encoder();

      await const AacEncoder(channel: channel).encode(
        tone(1),
        File('${temp.path}/voice.m4a'),
        sampleRate: 48000,
        bitRate: 96000,
      );

      final arguments = calls.single.arguments as Map;
      expect(arguments['sampleRate'], 48000);
      expect(arguments['bitRate'], 96000);
    });

    test(
      'a failure says what the device said and keeps the old file',
      () async {
        encoder(
          failure: PlatformException(
            code: 'encode',
            message: 'This recording could not be saved.',
          ),
        );
        final destination = File('${temp.path}/voice.m4a')
          ..writeAsBytesSync([9, 9]);

        await expectLater(
          const AacEncoder(channel: channel).encode(tone(1), destination),
          throwsA(
            isA<AudioEncodeException>().having(
              (error) => error.message,
              'message',
              'This recording could not be saved.',
            ),
          ),
        );
        expect(destination.readAsBytesSync(), [9, 9]);
        expect(File('${destination.path}.part.m4a').existsSync(), isFalse);
      },
    );

    test('a failure the device gave no words for still has some', () async {
      encoder(failure: PlatformException(code: 'encode'));

      await expectLater(
        const AacEncoder(
          channel: channel,
        ).encode(tone(1), File('${temp.path}/voice.m4a')),
        throwsA(
          isA<AudioEncodeException>().having(
            (error) => error.message,
            'message',
            'This recording could not be saved.',
          ),
        ),
      );
    });

    test('a build without the encoder says so', () async {
      final destination = File('${temp.path}/voice.m4a');

      await expectLater(
        const AacEncoder(channel: channel).encode(tone(1), destination),
        throwsA(
          isA<AudioEncodeException>().having(
            (error) => error.message,
            'message',
            'This build cannot save recordings on the device.',
          ),
        ),
      );
      expect(destination.existsSync(), isFalse);
    });

    test('an empty recording never reaches the encoder', () async {
      encoder();
      final pcm = File('${temp.path}/cleaned.pcm')..writeAsBytesSync([7]);

      await expectLater(
        const AacEncoder(
          channel: channel,
        ).encode(pcm, File('${temp.path}/voice.m4a')),
        throwsA(
          isA<AudioEncodeException>().having(
            (error) => error.message,
            'message',
            'This recording has no audio in it.',
          ),
        ),
      );
      expect(calls, isEmpty);
    });

    test('a recording that is not there is a failed save', () async {
      encoder();

      await expectLater(
        const AacEncoder(channel: channel).encode(
          File('${temp.path}/missing.pcm'),
          File('${temp.path}/voice.m4a'),
        ),
        throwsA(
          isA<AudioEncodeException>().having(
            (error) => error.message,
            'message',
            'This recording could not be saved.',
          ),
        ),
      );
      expect(calls, isEmpty);
    });
  });

  group('on Linux, through ffmpeg', () {
    final skip = _hasFfmpeg() ? false : 'needs ffmpeg on PATH';

    setUp(() => AppPlatform.debugTargetPlatformOverride = TargetPlatform.linux);

    test(
      'writes the app\'s own kind of recording, and it reads back',
      () async {
        final destination = File('${temp.path}/voice.m4a');

        await const AacEncoder().encode(tone(2), destination);

        expect(File('${destination.path}.part.m4a').existsSync(), isFalse);
        final probe = Process.runSync(ffmpegExecutable, [
          '-hide_banner',
          '-i',
          destination.path,
        ]);
        final description = probe.stderr as String;
        expect(description, matches(RegExp(r'major_brand\s*: M4A')));
        expect(description, contains('Audio: aac (LC)'));
        expect(description, contains('16000 Hz, mono'));
        final kbps = int.parse(
          RegExp(r'Audio: .*?(\d+) kb/s').firstMatch(description)!.group(1)!,
        );
        expect(kbps, inInclusiveRange(40, 56));

        final decoded = await decodeWithFfmpeg(destination, sampleRate: 16000);
        addTearDown(decoded.dispose);
        expect(decoded.frames, closeTo(32000, 1024));
        final samples = decoded.file.readAsBytesSync().buffer.asInt16List();
        final rms = sqrt(
          samples.fold<double>(0, (sum, s) => sum + s * s) / samples.length,
        );
        // A half-scale sine is about 11585 RMS, and AAC at 48 kbps keeps a tone
        // that plain almost exactly.
        expect(rms, greaterThan(8000));
      },
      skip: skip,
    );

    test(
      'a file ffmpeg cannot write is a failed save, and leaves nothing',
      () async {
        final destination = File('${temp.path}/gone/voice.m4a');

        await expectLater(
          const AacEncoder().encode(tone(1), destination),
          throwsA(
            isA<AudioEncodeException>().having(
              (error) => error.message,
              'message',
              'This recording could not be saved.',
            ),
          ),
        );
        expect(destination.existsSync(), isFalse);
        expect(File('${destination.path}.part.m4a').existsSync(), isFalse);
      },
      skip: skip,
    );
  });
}

bool _hasFfmpeg() {
  try {
    return Process.runSync(ffmpegExecutable, ['-version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}
