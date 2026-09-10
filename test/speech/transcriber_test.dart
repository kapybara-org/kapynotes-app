import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/speech/apple_transcriber.dart';
import 'package:kapy_notes/speech/transcriber.dart';

/// A transcriber that answers however a test tells it to.
class _Fake implements Transcriber {
  _Fake(this.state, {this.engine = 'fake'});

  TranscriberReadiness state;
  final String engine;
  int calls = 0;
  String? lastLanguage;

  @override
  Future<TranscriberReadiness> readiness() async => state;

  @override
  Future<TranscriptDraft> transcribe({
    required File audio,
    required String requestId,
    String? language,
  }) async {
    calls++;
    lastLanguage = language;
    return TranscriptDraft(
      engine: engine,
      lang: language ?? 'en',
      segments: const [TranscriptSegment(s: 0, e: 1000, t: 'hello')],
    );
  }
}

File get _anyFile => File('recording.m4a');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('choosing a device transcriber', () {
    test('the first one that is ready does the work', () async {
      final apple = _Fake(TranscriberReadiness.ready, engine: 'apple');
      final sherpa = _Fake(TranscriberReadiness.ready, engine: 'sherpa');

      final draft = await DeviceTranscriber([
        apple,
        sherpa,
      ]).transcribe(audio: _anyFile, requestId: 'r1');

      expect(draft.engine, 'apple');
      expect(sherpa.calls, 0, reason: 'the second one is never asked');
    });

    test('an unready first choice steps aside for the one that works', () async {
      final apple = _Fake(TranscriberReadiness.unsupported);
      final sherpa = _Fake(TranscriberReadiness.ready, engine: 'sherpa');

      final draft = await DeviceTranscriber([
        apple,
        sherpa,
      ]).transcribe(audio: _anyFile, requestId: 'r1');

      expect(draft.engine, 'sherpa');
    });

    test('the failure reported is the one the user can act on', () async {
      // An old Mac with no recogniser and no model downloaded: "download a
      // model" is a thing somebody can do, "this device cannot" is not.
      expect(
        await DeviceTranscriber([
          _Fake(TranscriberReadiness.unsupported),
          _Fake(TranscriberReadiness.needsDownload),
        ]).readiness(),
        TranscriberReadiness.needsDownload,
      );
      // Fetching a language beats spending 670 MB.
      expect(
        await DeviceTranscriber([
          _Fake(TranscriberReadiness.needsSystemFeature),
          _Fake(TranscriberReadiness.needsDownload),
        ]).readiness(),
        TranscriberReadiness.needsSystemFeature,
      );
      // A wait that fixes itself beats being told no.
      expect(
        await DeviceTranscriber([
          _Fake(TranscriberReadiness.preparing),
          _Fake(TranscriberReadiness.unsupported),
        ]).readiness(),
        TranscriberReadiness.preparing,
      );
    });

    test('nothing ready throws the reason rather than silence', () async {
      final device = DeviceTranscriber([
        _Fake(TranscriberReadiness.needsDownload),
      ]);

      await expectLater(
        device.transcribe(audio: _anyFile, requestId: 'r1'),
        throwsA(
          isA<TranscriberUnavailable>().having(
            (error) => error.readiness,
            'readiness',
            TranscriberReadiness.needsDownload,
          ),
        ),
      );
    });

    test('waiting helps for some failures and never for others', () {
      const temporary = [
        TranscriberReadiness.preparing,
        TranscriberReadiness.needsDownload,
        TranscriberReadiness.needsSystemFeature,
      ];
      for (final state in TranscriberReadiness.values) {
        expect(
          TranscriberUnavailable(state, '').isTemporary,
          temporary.contains(state),
          reason: state.name,
        );
      }
    });
  });

  group('routing by the preference', () {
    test('the setting decides, and a change takes effect at once', () async {
      var engine = TranscriptEngine.cloud;
      final cloud = _Fake(TranscriberReadiness.ready, engine: 'cloud');
      final device = _Fake(TranscriberReadiness.ready, engine: 'device');
      final routing = RoutingTranscriber(
        engineOf: () => engine,
        cloud: cloud,
        device: device,
      );

      expect(
        (await routing.transcribe(audio: _anyFile, requestId: 'r1')).engine,
        'cloud',
      );

      engine = TranscriptEngine.device;

      expect(
        (await routing.transcribe(audio: _anyFile, requestId: 'r2')).engine,
        'device',
        reason: 'nothing had to be rebuilt for the new setting to apply',
      );
    });

    test('readiness follows the same setting', () async {
      var engine = TranscriptEngine.cloud;
      final routing = RoutingTranscriber(
        engineOf: () => engine,
        cloud: _Fake(TranscriberReadiness.needsAccount),
        device: _Fake(TranscriberReadiness.ready),
      );

      expect(await routing.readiness(), TranscriberReadiness.needsAccount);
      engine = TranscriptEngine.device;
      expect(await routing.readiness(), TranscriberReadiness.ready);
    });
  });

  group('turning words into segments', () {
    List<TimedWord> words(List<(String, int, int)> raw) => [
      for (final (text, start, end) in raw)
        TimedWord(text: text, startMs: start, endMs: end),
    ];

    test('a sentence ends a segment', () {
      final segments = segmentsFromWords(
        words([
          ('Remember', 0, 400),
          ('the', 400, 500),
          ('milk.', 500, 900),
          ('Also', 1200, 1500),
          ('call', 1500, 1800),
          ('Sam.', 1800, 2200),
        ]),
      );

      expect(segments, hasLength(2));
      expect(segments.first.t, 'Remember the milk.');
      expect(segments.first.s, 0);
      expect(segments.first.e, 900);
      expect(segments.last.t, 'Also call Sam.');
      expect(segments.last.s, 1200);
    });

    test('a long run without punctuation is broken anyway', () {
      // Somebody talking without stopping still has to be readable, and a
      // single wall of text is not something playback can follow.
      final segments = segmentsFromWords(
        words([
          for (var i = 0; i < 30; i++) ('word$i', i * 1000, i * 1000 + 900),
        ]),
      );

      expect(segments.length, greaterThan(1));
      for (final segment in segments) {
        expect(segment.e - segment.s, lessThanOrEqualTo(13000));
      }
    });

    test('question and exclamation marks end one too', () {
      expect(
        segmentsFromWords(
          words([
            ('Ready?', 0, 500),
            ('Go!', 600, 900),
          ]),
        ),
        hasLength(2),
      );
    });

    test('nothing said is no segments, not an empty one', () {
      expect(segmentsFromWords(const []), isEmpty);
      expect(segmentsFromWords(words([('   ', 0, 100)])), isEmpty);
    });
  });

  group("Apple's recogniser, through the runner", () {
    setUp(() => AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS);
    tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

    final calls = <MethodCall>[];

    void answerWith(Object? Function(MethodCall call) handler) {
      calls.clear();
      const channel = MethodChannel(AppleTranscriber.channelName);
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

    test("the runner's answers each mean something different", () async {
      final answers = <String, TranscriberReadiness>{
        'ready': TranscriberReadiness.ready,
        'preparing': TranscriberReadiness.preparing,
        'unsupported': TranscriberReadiness.unsupported,
      };
      for (final entry in answers.entries) {
        answerWith((_) => entry.key);
        expect(
          await AppleTranscriber().readiness(),
          entry.value,
          reason: entry.key,
        );
      }
    });

    test('the older engine\'s refused permission is the one fixable answer', () async {
      answerWith((_) => 'denied');
      expect(
        await AppleTranscriber().readiness(),
        TranscriberReadiness.needsSystemFeature,
      );

      answerWith((call) {
        if (call.method == 'availability') return 'ready';
        throw PlatformException(
          code: 'denied',
          message: 'Kapy Notes was not allowed to use speech recognition.',
        );
      });
      await expectLater(
        AppleTranscriber().transcribe(
          audio: File('/tmp/note.m4a'),
          requestId: 'r-denied',
        ),
        throwsA(
          isA<TranscriberUnavailable>()
              .having(
                (e) => e.readiness,
                'readiness',
                TranscriberReadiness.needsSystemFeature,
              )
              .having((e) => e.isTemporary, 'temporary', isTrue),
        ),
      );
    });

    test('words from the older engine become the same segments Parakeet\'s do', () async {
      answerWith(
        (call) => call.method == 'availability'
            ? 'ready'
            : {
                'lang': 'en',
                'engine': 'apple/speech-recognizer',
                'words': [
                  {'t': 'Remember', 's': 0, 'e': 400},
                  {'t': 'milk.', 's': 500, 'e': 900},
                  {'t': 'The', 's': 1200, 'e': 1300},
                  {'t': 'meeting', 's': 1300, 'e': 1700},
                  {'t': 'moved.', 's': 1800, 'e': 2200},
                  {'not': 'a word'},
                ],
              },
      );

      final draft = await AppleTranscriber().transcribe(
        audio: File('/tmp/note.m4a'),
        requestId: 'r2',
      );

      // The transcript says which engine wrote it, so a note can still tell
      // after the phone has been upgraded to the newer one.
      expect(draft.engine, 'apple/speech-recognizer');
      expect(draft.segments.map((s) => s.t), ['Remember milk.', 'The meeting moved.']);
      expect(draft.segments.first.s, 0);
      expect(draft.segments.first.e, 900);
      expect(draft.segments.last.s, 1200);
      expect(draft.segments.last.e, 2200);
    });

    test('a shipping build never asks the runner for a particular engine', () async {
      answerWith((_) => 'ready');
      await AppleTranscriber().readiness();
      expect(calls.single.arguments, isNot(contains('engine')));
    });

    test('a runner with no such channel is a device that cannot', () async {
      // No mock handler at all, which is what an older runner looks like.
      expect(
        await AppleTranscriber().readiness(),
        TranscriberReadiness.unsupported,
      );
    });

    test('segments come back as the note stores them', () async {
      answerWith(
        (call) => call.method == 'availability'
            ? 'ready'
            : {
                'lang': 'en',
                'segments': [
                  {'s': 0, 'e': 1740, 't': 'Remember to buy milk.'},
                  {'s': 1800, 'e': 4980, 't': 'The meeting moved.'},
                  {'not': 'a segment'},
                ],
              },
      );

      final draft = await AppleTranscriber().transcribe(
        audio: File('/tmp/note.m4a'),
        requestId: 'r1',
      );

      expect(draft.engine, AppleTranscriber.engineId);
      expect(draft.lang, 'en');
      expect(draft.segments, hasLength(2), reason: 'the junk one is dropped');
      expect(draft.segments.first.t, 'Remember to buy milk.');
      expect(draft.segments.last.e, 4980);
      expect(
        draft.jobId,
        isNull,
        reason: 'nothing was billed, so there is nothing to ask about later',
      );
      expect(calls.last.arguments['path'], '/tmp/note.m4a');
    });

    test('silence is an empty transcript, not a failure', () async {
      answerWith(
        (call) => call.method == 'availability'
            ? 'ready'
            : {'lang': 'en', 'segments': <Object?>[]},
      );

      final draft = await AppleTranscriber().transcribe(
        audio: File('/tmp/quiet.m4a'),
        requestId: 'r1',
      );

      expect(draft.segments, isEmpty);
    });

    test('the language preference reaches the runner', () async {
      answerWith(
        (call) => call.method == 'availability'
            ? 'ready'
            : {'lang': 'de', 'segments': <Object?>[]},
      );

      await AppleTranscriber(language: () => 'de').transcribe(
        audio: File('/tmp/note.m4a'),
        requestId: 'r1',
      );

      expect(calls.first.arguments['language'], 'de');
      expect(calls.last.arguments['language'], 'de');
    });

    test('a device that stops being able mid-call says so, once', () async {
      answerWith((call) {
        if (call.method == 'availability') return 'ready';
        throw PlatformException(code: 'unavailable', message: 'gone');
      });

      await expectLater(
        AppleTranscriber().transcribe(
          audio: File('/tmp/note.m4a'),
          requestId: 'r1',
        ),
        throwsA(
          isA<TranscriberUnavailable>().having(
            (error) => error.isTemporary,
            'isTemporary',
            isFalse,
          ),
        ),
      );
    });

    test('nothing is asked of a platform without the framework', () async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.windows;
      answerWith((_) => 'ready');

      expect(
        await AppleTranscriber().readiness(),
        TranscriberReadiness.unsupported,
      );
      expect(calls, isEmpty, reason: 'no channel call is made at all');
    });
  });
}
