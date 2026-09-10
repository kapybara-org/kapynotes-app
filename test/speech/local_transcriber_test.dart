import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/audio/audio_decode.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/speech/local_model_store.dart';
import 'package:kapy_notes/speech/local_models.dart';
import 'package:kapy_notes/speech/sherpa_transcriber.dart';
import 'package:kapy_notes/speech/transcriber.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('kapy-models');
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.windows;
  });

  tearDown(() {
    AppPlatform.debugTargetPlatformOverride = null;
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  group('the downloaded recogniser', () {
    test('nothing downloaded asks for the download, and does not fetch', () async {
      final models = LocalModelStore(
        catalogue: const [parakeetTdt06bV3Int8],
        directory: temp,
      );
      addTearDown(models.dispose);

      expect(
        await SherpaTranscriber(models: models).readiness(),
        TranscriberReadiness.needsDownload,
      );
    });

    test('being asked to work without the model says what would fix it', () async {
      final models = LocalModelStore(
        catalogue: const [parakeetTdt06bV3Int8],
        directory: temp,
      );
      addTearDown(models.dispose);

      await expectLater(
        SherpaTranscriber(
          models: models,
        ).transcribe(audio: File('/tmp/note.m4a'), requestId: 'r1'),
        throwsA(
          isA<TranscriberUnavailable>()
              .having(
                (error) => error.readiness,
                'readiness',
                TranscriberReadiness.needsDownload,
              )
              .having(
                (error) => error.message,
                'message',
                contains('Parakeet TDT 0.6B v3'),
              ),
        ),
      );
    });

    test('the engine is named with its exact export', () {
      final models = LocalModelStore(catalogue: const [], directory: temp);
      addTearDown(models.dispose);

      expect(
        SherpaTranscriber(models: models).engineId,
        'sherpa/parakeet-tdt-0.6b-v3-int8',
        reason: 'another quantisation of the same model is another transcript',
      );
    });

    test('is only for the platforms with no recogniser of their own', () {
      // Apple's platforms have one built in, and the runtime is stubbed out
      // of those builds: asking there would be a crash rather than an answer.
      for (final apple in [TargetPlatform.macOS, TargetPlatform.iOS]) {
        AppPlatform.debugTargetPlatformOverride = apple;
        expect(SherpaTranscriber.isPossibleHere, isFalse, reason: '$apple');
      }
      for (final bare in [
        TargetPlatform.windows,
        TargetPlatform.android,
        TargetPlatform.linux,
      ]) {
        AppPlatform.debugTargetPlatformOverride = bare;
        expect(SherpaTranscriber.isPossibleHere, isTrue, reason: '$bare');
      }
    });
  });

  group('decoding a recording', () {
    final calls = <MethodCall>[];

    void answerWith(Object? Function(MethodCall call) handler) {
      calls.clear();
      const channel = MethodChannel(AudioDecoder.channelName);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return handler(call);
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
    }

    test('the runner is asked for the rate the model wants', () async {
      final pcm = File('${temp.path}/out.pcm')..writeAsBytesSync([0, 0]);
      answerWith(
        (_) => {'path': pcm.path, 'sampleRate': 16000, 'frames': 32000},
      );

      final decoded = await const AudioDecoder().decode(File('/tmp/note.m4a'));

      expect(calls.single.arguments['path'], '/tmp/note.m4a');
      expect(calls.single.arguments['sampleRate'], 16000);
      expect(decoded.frames, 32000);
      expect(
        decoded.duration,
        const Duration(seconds: 2),
        reason: 'frames are samples, not bytes',
      );
    });

    test('the decoded copy is thrown away when it is done with', () async {
      final pcm = File('${temp.path}/out.pcm')..writeAsBytesSync([0, 0]);
      answerWith((_) => {'path': pcm.path, 'sampleRate': 16000, 'frames': 1});

      final decoded = await const AudioDecoder().decode(File('/tmp/note.m4a'));
      await decoded.dispose();

      expect(pcm.existsSync(), isFalse);
      // Twice is not an error: a failure part-way through disposes too.
      await decoded.dispose();
    });

    test('a build with no decoder says so rather than throwing plugin noise', () async {
      // No mock handler at all, which is what a platform with no such channel
      // looks like.
      await expectLater(
        const AudioDecoder().decode(File('/tmp/note.m4a')),
        throwsA(isA<AudioDecodeException>()),
      );
    });

    test('a runner that answers with nothing is a recording that cannot be read', () async {
      answerWith((_) => {'path': '', 'frames': 0});

      await expectLater(
        const AudioDecoder().decode(File('/tmp/note.m4a')),
        throwsA(isA<AudioDecodeException>()),
      );
    });

    test('a decode failure keeps the reason the runner gave', () async {
      answerWith((_) {
        throw PlatformException(
          code: 'decode',
          message: 'This recording has no audio in it.',
        );
      });

      await expectLater(
        const AudioDecoder().decode(File('/tmp/note.m4a')),
        throwsA(
          isA<AudioDecodeException>().having(
            (error) => error.message,
            'message',
            'This recording has no audio in it.',
          ),
        ),
      );
    });
  });
}
