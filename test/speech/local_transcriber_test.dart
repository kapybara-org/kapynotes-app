import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
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
    test(
      'nothing downloaded asks for the download, and does not fetch',
      () async {
        final models = LocalModelStore(
          catalogue: const [parakeetTdt06bV3Int8],
          directory: temp,
        );
        addTearDown(models.dispose);

        expect(
          await SherpaTranscriber(models: models).readiness(),
          TranscriberReadiness.needsDownload,
        );
      },
    );

    test('a language the model never learned is not a download away', () async {
      final models = LocalModelStore(
        catalogue: const [parakeetTdt06bV3Int8],
        directory: temp,
      );
      addTearDown(models.dispose);

      expect(
        await SherpaTranscriber(
          models: models,
          language: () => 'hi',
        ).readiness(),
        TranscriberReadiness.unsupported,
      );
      expect(
        await SherpaTranscriber(
          models: models,
          language: () => 'de',
        ).readiness(),
        TranscriberReadiness.needsDownload,
      );
    });

    test(
      'being asked to work without the model says what would fix it',
      () async {
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
                  contains('Download the speech model'),
                ),
          ),
        );
      },
    );

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

  group('cutting a recording into chunks', () {
    const rate = 16000;
    const limit = 20 * rate;

    int noQuietest(int from, int to) =>
        fail('cut between $from and $to with a pause to cut at');

    void expectWhole(List<(int, int)> chunks, int frames) {
      expect(chunks.first.$1, 0);
      expect(chunks.last.$2, frames);
      for (var i = 1; i < chunks.length; i++) {
        expect(chunks[i].$1, chunks[i - 1].$2, reason: 'no gap, no overlap');
      }
      for (final (start, end) in chunks) {
        expect(end - start, inInclusiveRange(1, limit));
      }
    }

    test('a recording that fits is one chunk', () {
      expect(
        chunksAtPauses(
          frames: limit,
          pauses: const [5 * rate],
          limit: limit,
          quietest: noQuietest,
        ),
        [(0, limit)],
      );
    });

    test('nothing to recognise is no chunks', () {
      expect(
        chunksAtPauses(
          frames: 0,
          pauses: const [],
          limit: limit,
          quietest: noQuietest,
        ),
        isEmpty,
      );
    });

    test('each chunk ends at the last pause that fits in it', () {
      const frames = 50 * rate;
      final chunks = chunksAtPauses(
        frames: frames,
        pauses: const [4 * rate, 12 * rate, 19 * rate, 21 * rate, 38 * rate],
        limit: limit,
        quietest: noQuietest,
      );

      expect(chunks, [
        (0, 19 * rate),
        (19 * rate, 38 * rate),
        (38 * rate, frames),
      ]);
      expectWhole(chunks, frames);
    });

    test('a pause right at the limit still counts', () {
      expect(
        chunksAtPauses(
          frames: 30 * rate,
          pauses: const [limit],
          limit: limit,
          quietest: noQuietest,
        ),
        [(0, limit), (limit, 30 * rate)],
      );
    });

    test('a speaker who never stops is cut at the quietest moment', () {
      const frames = 70 * rate;
      final asked = <(int, int)>[];
      final chunks = chunksAtPauses(
        frames: frames,
        pauses: const [10 * rate, 45 * rate],
        limit: limit,
        quietest: (from, to) {
          asked.add((from, to));
          return to - rate;
        },
      );

      expect(asked, [
        (10 * rate + limit - limit ~/ 3, 10 * rate + limit),
        (45 * rate + limit - limit ~/ 3, 45 * rate + limit),
      ], reason: 'only where no pause fits, and only in the last third');
      expect(chunks, [
        (0, 10 * rate),
        (10 * rate, 29 * rate),
        (29 * rate, 45 * rate),
        (45 * rate, 64 * rate),
        (64 * rate, frames),
      ]);
      expectWhole(chunks, frames);
    });

    test('with no pauses at all, the whole recording is still covered', () {
      // What a missing or broken voice activity model leaves behind.
      const frames = 61 * rate;
      final chunks = chunksAtPauses(
        frames: frames,
        pauses: const [],
        limit: limit,
        quietest: (from, to) => to,
      );

      expect(chunks, [
        (0, limit),
        (limit, 2 * limit),
        (2 * limit, 3 * limit),
        (3 * limit, frames),
      ]);
      expectWhole(chunks, frames);
    });
  });

  group('hearing skipped speech again', () {
    const rate = 16000;
    const limit = 20 * rate;

    TimedWord word(String text, int ms) =>
        TimedWord(text: text, startMs: ms, endMs: ms + 300);

    List<TimedWord> never(int start, int end) =>
        fail('heard $start to $end again with nothing skipped');

    test('speech with words all through it is left as it is', () {
      final words = [word('one', 1200), word('two', 3000), word('three', 5500)];

      expect(
        hearAgain(
          words: words,
          speech: const [(1 * rate, 6 * rate)],
          frames: 8 * rate,
          sampleRate: rate,
          limit: limit,
          decode: never,
        ),
        same(words),
      );
    });

    test('a sentence with no words is heard again between its pauses', () {
      final asked = <(int, int)>[];
      final heard = hearAgain(
        words: [word('before', 1500), word('after', 13500)],
        speech: const [
          (1 * rate, 4 * rate),
          (5 * rate, 12 * rate),
          (13 * rate, 16 * rate),
        ],
        frames: 17 * rate,
        sampleRate: rate,
        limit: limit,
        decode: (start, end) {
          asked.add((start, end));
          return [word('skipped', 5200), word('sentence', 6000)];
        },
      );

      expect(asked, [(9 * rate ~/ 2, 25 * rate ~/ 2)]);
      expect(heard.map((w) => w.text), [
        'before',
        'skipped',
        'sentence',
        'after',
      ]);
    });

    test('words that stop partway through are heard again too', () {
      final asked = <(int, int)>[];
      hearAgain(
        words: [word('a', 1100), word('b', 2000), word('c', 2900)],
        speech: const [(1 * rate, 11 * rate)],
        frames: 12 * rate,
        sampleRate: rate,
        limit: limit,
        decode: (start, end) {
          asked.add((start, end));
          return const [];
        },
      );

      expect(asked, [
        (0, 12 * rate),
      ], reason: 'the only stretch runs from the start to the end');
    });

    test('a second hearing that finds no more is not kept', () {
      final heard = hearAgain(
        words: [word('first', 5200)],
        speech: const [(5 * rate, 12 * rate)],
        frames: 13 * rate,
        sampleRate: rate,
        limit: limit,
        decode: (start, end) => [word('second', 5300)],
      );

      expect(heard.map((w) => w.text), ['first']);
    });

    test('a cough is not a skipped sentence', () {
      final words = [word('hello', 500)];

      expect(
        hearAgain(
          words: words,
          speech: const [(0, 3 * rate ~/ 2), (3 * rate, 5 * rate)],
          frames: 6 * rate,
          sampleRate: rate,
          limit: limit,
          decode: never,
        ),
        same(words),
      );
    });

    test('skipped neighbours are heard together while they fit', () {
      final asked = <(int, int)>[];
      hearAgain(
        words: const <TimedWord>[],
        speech: const [
          (1 * rate, 9 * rate),
          (10 * rate, 18 * rate),
          (19 * rate, 27 * rate),
        ],
        frames: 28 * rate,
        sampleRate: rate,
        limit: limit,
        decode: (start, end) {
          asked.add((start, end));
          return const [];
        },
      );

      expect(asked, [(0, 37 * rate ~/ 2), (37 * rate ~/ 2, 28 * rate)]);
    });

    test('without a voice activity model there is nothing to hear again', () {
      final words = [word('only', 900)];

      expect(
        hearAgain(
          words: words,
          speech: const [],
          frames: 60 * rate,
          sampleRate: rate,
          limit: limit,
          decode: never,
        ),
        same(words),
      );
    });
  });

  group('the voice activity model', () {
    test('is bundled whole, and is the export that was measured', () async {
      final data = await rootBundle.load(sileroVadAsset);
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );

      expect(bytes.length, 643854);
      expect(
        sha256.convert(bytes).toString(),
        '9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6',
        reason: "sherpa-onnx's asr-models release, silero_vad.onnx",
      );
    });

    test('stays out of the Apple builds', () {
      // Their recogniser is the system's, so the model would be dead weight.
      final pubspec = File('pubspec.yaml').readAsStringSync();
      for (final asset in [
        sileroVadAsset,
        'assets/speech/silero_vad-LICENSE.txt',
      ]) {
        expect(
          pubspec,
          contains(
            '- path: $asset\n      platforms: [android, linux, windows]\n',
          ),
          reason: asset,
        );
      }
    });

    test('is credited where it ships, and only there', () async {
      addTearDown(LicenseRegistry.reset);
      for (final (platform, ships) in [
        (TargetPlatform.windows, true),
        (TargetPlatform.android, true),
        (TargetPlatform.linux, true),
        (TargetPlatform.macOS, false),
        (TargetPlatform.iOS, false),
      ]) {
        AppPlatform.debugTargetPlatformOverride = platform;
        LicenseRegistry.reset();
        registerVadLicense();

        final credits = (await LicenseRegistry.licenses.toList()).where(
          (entry) => entry.packages.contains('Silero VAD'),
        );
        expect(credits.length, ships ? 1 : 0, reason: '$platform');
        if (ships) {
          expect(
            credits.single.paragraphs.map((p) => p.text).join(' '),
            contains('Copyright (c) 2020-present Silero Team'),
          );
        }
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

    test(
      'a build with no decoder says so rather than throwing plugin noise',
      () async {
        // No mock handler at all, which is what a platform with no such channel
        // looks like.
        await expectLater(
          const AudioDecoder().decode(File('/tmp/note.m4a')),
          throwsA(isA<AudioDecodeException>()),
        );
      },
    );

    test(
      'a runner that answers with nothing is a recording that cannot be read',
      () async {
        answerWith((_) => {'path': '', 'frames': 0});

        await expectLater(
          const AudioDecoder().decode(File('/tmp/note.m4a')),
          throwsA(isA<AudioDecodeException>()),
        );
      },
    );

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
