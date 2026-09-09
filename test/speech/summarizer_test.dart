import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/speech/apple_summarizer.dart';
import 'package:kapy_notes/speech/note_summary_text.dart';
import 'package:kapy_notes/speech/summarizer.dart';

/// A summariser that answers however a test tells it to.
class _Fake implements Summarizer {
  _Fake(this.state, {this.title = 'Title'});

  SummarizerReadiness state;
  final String title;
  int calls = 0;
  String? lastInstruction;
  int rewrites = 0;

  @override
  Future<SummarizerReadiness> readiness() async => state;

  @override
  Future<SummaryDraft> summarize({
    required String text,
    required String lang,
    String? jobId,
    String? instruction,
  }) async {
    calls++;
    lastInstruction = instruction;
    return SummaryDraft(engine: 'fake', title: title, points: const ['a']);
  }

  @override
  Future<String> rewrite({
    required String text,
    required String lang,
    required String instruction,
    String? jobId,
  }) async {
    rewrites++;
    lastInstruction = instruction;
    return 'a post about $instruction';
  }
}

void main() {
  group('reading what a model wrote', () {
    test('a clean answer comes through as it is', () {
      final parsed = parseSummaryText('''
Standup thoughts
- Ship the export fix today
- Ask Priya about the invoice
''');
      expect(parsed.title, 'Standup thoughts');
      expect(parsed.points, [
        'Ship the export fix today',
        'Ask Priya about the invoice',
      ]);
    });

    test('the chat wrapper a small model adds is thrown away', () {
      final parsed = parseSummaryText('''
```
**Summary of the transcript:**

## Grocery run

1. Buy oat milk and rice
2) Return the parcel
* 
```
''');
      // "Summary of the transcript:" introduces something; it is not a title.
      expect(parsed.title, 'Grocery run');
      expect(parsed.points, ['Buy oat milk and rice', 'Return the parcel']);
    });

    test('a paragraph with no bullets becomes points', () {
      final parsed = parseSummaryText(
        'The roof needs looking at. Call the surveyor on Monday. '
        'The quote was two thousand.',
      );
      expect(parsed.points.length, 3);
      expect(parsed.points.first, 'The roof needs looking at.');
      // Nothing was offered as a heading, so the first point stands in.
      expect(parsed.title, isNotEmpty);
    });

    test('a title too long to be one is cut, not kept whole', () {
      final parsed = parseSummaryText(
        'A very long heading that simply keeps going well past any '
        'reasonable length\n- one point',
      );
      expect(parsed.title.split(' ').length, lessThanOrEqualTo(maxTitleWords + 1));
      expect(parsed.title, endsWith('…'));
    });

    test('more points than the dialog shows are dropped', () {
      final parsed = parseSummaryText(
        'Title\n${List.generate(9, (i) => '- point $i').join('\n')}',
      );
      expect(parsed.points, hasLength(maxSummaryPoints));
    });

    test('nothing at all still gives something to show', () {
      final parsed = parseSummaryText('   \n\n  ');
      expect(parsed.title, 'Voice note');
      expect(parsed.points, isEmpty);
    });

    test('quotes and bold around a title are decoration, not the title', () {
      final parsed = parseSummaryText('"**The leak**"\n- call someone');
      expect(parsed.title, 'The leak');
    });
  });

  group('choosing a summariser on this device', () {
    test('the platform model wins when it is ready', () async {
      final platform = _Fake(SummarizerReadiness.ready, title: 'Apple');
      final downloaded = _Fake(SummarizerReadiness.ready, title: 'Gemma');
      final device = DeviceSummarizer([platform, downloaded]);

      final draft = await device.summarize(text: 'hello', lang: 'en');

      expect(draft.title, 'Apple');
      expect(downloaded.calls, 0, reason: 'the free one was already there');
    });

    test('a download answers for a machine the platform cannot help', () async {
      final device = DeviceSummarizer([
        _Fake(SummarizerReadiness.unsupported),
        _Fake(SummarizerReadiness.ready, title: 'Gemma'),
      ]);

      expect(await device.readiness(), SummarizerReadiness.ready);
      expect((await device.summarize(text: 'x', lang: 'en')).title, 'Gemma');
    });

    test('it reports the failure the user can act on', () async {
      // An ineligible Mac and a model that has not been downloaded: only one
      // of those is something anybody can do anything about.
      final device = DeviceSummarizer([
        _Fake(SummarizerReadiness.unsupported),
        _Fake(SummarizerReadiness.needsDownload),
      ]);

      expect(await device.readiness(), SummarizerReadiness.needsDownload);
    });

    test('nothing ready is an unavailable, not a wrong answer', () async {
      final device = DeviceSummarizer([_Fake(SummarizerReadiness.unsupported)]);

      await expectLater(
        device.summarize(text: 'x', lang: 'en'),
        throwsA(isA<SummarizerUnavailable>()),
      );
    });

    test('waiting is worth saying only when nothing else is actionable', () async {
      final device = DeviceSummarizer([
        _Fake(SummarizerReadiness.preparing),
        _Fake(SummarizerReadiness.unsupported),
      ]);

      expect(await device.readiness(), SummarizerReadiness.preparing);
    });
  });

  group('routing', () {
    test('the preference decides, and is read every time', () async {
      var engine = SummaryEngine.cloud;
      final cloud = _Fake(SummarizerReadiness.ready, title: 'Cloud');
      final device = _Fake(SummarizerReadiness.ready, title: 'Device');
      final router = RoutingSummarizer(
        engineOf: () => engine,
        cloud: cloud,
        device: device,
      );

      expect((await router.summarize(text: 'x', lang: 'en')).title, 'Cloud');
      engine = SummaryEngine.device;
      expect((await router.summarize(text: 'x', lang: 'en')).title, 'Device');
    });
  });

  group('what a failure means', () {
    test('a missing download is worth retrying and an old Mac is not', () {
      expect(
        const SummarizerUnavailable(
          SummarizerReadiness.needsDownload,
          '',
        ).isTemporary,
        isTrue,
      );
      expect(
        const SummarizerUnavailable(
          SummarizerReadiness.unsupported,
          '',
        ).isTemporary,
        isFalse,
      );
    });
  });

  group("Apple's model, through the channel", () {
    late List<MethodCall> calls;

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      calls = [];
    });

    void answerWith(Object? Function(MethodCall call) handler) {
      const channel = MethodChannel(AppleSummarizer.channelName);
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

    test("the runner's four answers each mean something different", () async {
      final answers = <String, SummarizerReadiness>{
        'ready': SummarizerReadiness.ready,
        'disabled': SummarizerReadiness.needsSystemFeature,
        'preparing': SummarizerReadiness.preparing,
        'unsupported': SummarizerReadiness.unsupported,
      };
      for (final entry in answers.entries) {
        answerWith((_) => entry.key);
        expect(
          await AppleSummarizer().readiness(),
          entry.value,
          reason: entry.key,
        );
      }
    });

    test('a guided answer arrives as a title and points', () async {
      answerWith(
        (call) => call.method == 'availability'
            ? 'ready'
            : {
                'title': ' Standup thoughts ',
                'points': ['Ship the fix', '  ', 'Reply to the landlord'],
              },
      );

      final draft = await AppleSummarizer().summarize(
        text: 'a transcript',
        lang: 'en',
      );

      expect(draft.engine, AppleSummarizer.engineId);
      expect(draft.title, 'Standup thoughts');
      // The blank one was the model filling its own array, not a point.
      expect(draft.points, ['Ship the fix', 'Reply to the landlord']);
      expect(calls.last.arguments['text'], 'a transcript');
    });

    test('a runner that could only manage text is still read', () async {
      answerWith(
        (call) => call.method == 'availability'
            ? 'ready'
            : {'text': 'The leak\n- call the plumber\n- book Friday'},
      );

      final draft = await AppleSummarizer().summarize(text: 't', lang: 'en');

      expect(draft.title, 'The leak');
      expect(draft.points, ['call the plumber', 'book Friday']);
    });

    test('it does not ask a Mac that already said no', () async {
      answerWith((_) => 'disabled');

      await expectLater(
        AppleSummarizer().summarize(text: 't', lang: 'en'),
        throwsA(
          isA<SummarizerUnavailable>().having(
            (e) => e.message,
            'message',
            contains('System Settings'),
          ),
        ),
      );
      expect(calls.map((c) => c.method), ['availability']);
    });

    test('a platform with no such channel is simply unsupported', () async {
      // No mock handler at all: the same shape as a Windows build.
      expect(
        await AppleSummarizer().readiness(),
        SummarizerReadiness.unsupported,
      );
    });
  });
}