import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/billing/billing.dart';
import 'package:kapy_notes/billing/billing_api.dart';
import 'package:kapy_notes/billing/entitlements.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/voice_prefs.dart';
import 'package:kapy_notes/speech/cloud_access.dart';
import 'package:kapy_notes/speech/summarizer.dart';
import 'package:kapy_notes/speech/transcriber.dart';

import '../billing/billing_fakes.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'cloud-access-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;

  @override
  void putNow(String key, Object? value) => data[key] = value;
}

/// Reads the language setting itself, as Apple's recogniser and Parakeet do.
class _Device implements Transcriber {
  _Device(this.prefs);

  final VoicePrefs prefs;
  final Set<String> knows = {'en'};

  @override
  Future<TranscriberReadiness> readiness() async {
    final language = prefs.language;
    return language == null || knows.contains(language)
        ? TranscriberReadiness.ready
        : TranscriberReadiness.unsupported;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Names itself through readiness, which is all routing has to show.
class _FixedTranscriber implements Transcriber {
  _FixedTranscriber(this.state);

  final TranscriberReadiness state;

  @override
  Future<TranscriberReadiness> readiness() async => state;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FixedSummarizer implements Summarizer {
  _FixedSummarizer(this.state);

  final SummarizerReadiness state;

  @override
  Future<SummarizerReadiness> readiness() async => state;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A server that has not answered yet, and will not in this test.
class _SilentApi extends FakeBillingApi {
  @override
  Future<Entitlements> entitlements() => Completer<Entitlements>().future;

  @override
  Future<AdoptedPurchases> adopt() => Completer<AdoptedPurchases>().future;
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 5));

enum _Plan { free, pro, trial, credit, signedOut, unknown }

void main() {
  late VoicePrefs prefs;
  late _Device device;
  late FakeBillingApi api;
  late Billing billing;
  late CloudAccess access;

  Future<void> start(_Plan plan, {String? language}) async {
    prefs = VoicePrefs(_MemoryStore())..load();
    prefs.language = language;
    device = _Device(prefs);
    final session = FakeSession();
    api = plan == _Plan.unknown ? _SilentApi() : FakeBillingApi();
    api.answer = switch (plan) {
      _Plan.pro => () => entitlementsFor(pro: true),
      _Plan.trial => () => trialFor(const Duration(days: 3)),
      _Plan.credit => () => entitlementsFor(speechCreditSeconds: 600),
      _ => entitlementsFor,
    };
    billing = billingFor(session, api);
    addTearDown(billing.dispose);
    if (plan != _Plan.signedOut) session.signIn('user-1');
    await settle();
    access = CloudAccess(prefs: prefs, device: device, billing: billing);
    addTearDown(access.dispose);
    await settle();
  }

  group('cloud allowed for transcription and summaries', () {
    const languages = [null, 'en', 'hi'];
    const table = {
      _Plan.free: [(false, false), (false, false), (true, false)],
      _Plan.pro: [(true, true), (true, true), (true, true)],
      _Plan.trial: [(true, true), (true, true), (true, true)],
      _Plan.credit: [(true, false), (true, false), (true, false)],
      _Plan.signedOut: [(true, true), (true, true), (true, true)],
      _Plan.unknown: [(true, true), (true, true), (true, true)],
    };
    for (final MapEntry(key: plan, value: rows) in table.entries) {
      for (final (index, language) in languages.indexed) {
        final (transcription, summaries) = rows[index];
        test('${plan.name}, ${language ?? 'detected'}', () async {
          await start(plan, language: language);

          expect(access.cloudTranscriptionAllowed, transcription);
          expect(access.cloudSummariesAllowed, summaries);
          expect(access.languageNeedsCloud, language == 'hi');
          expect(
            access.transcription.engine,
            transcription ? TranscriptEngine.cloud : TranscriptEngine.device,
          );
          expect(
            access.summaries.engine,
            summaries ? SummaryEngine.cloud : SummaryEngine.device,
          );
        });
      }
    }
  });

  test('a saved device choice stays on the device, on any plan', () async {
    await start(_Plan.pro);
    prefs.transcriptEngine = TranscriptEngine.device;
    prefs.summaryEngine = SummaryEngine.device;

    expect(access.transcription.engine, TranscriptEngine.device);
    expect(access.summaries.engine, SummaryEngine.device);
  });

  test(
    'the free plan never rewrites the choice, so Pro brings it back',
    () async {
      await start(_Plan.free);
      var notified = 0;
      access.addListener(() => notified++);

      expect(access.transcription.engine, TranscriptEngine.device);
      expect(prefs.transcriptEngine, TranscriptEngine.cloud);
      expect(prefs.summaryEngine, SummaryEngine.cloud);

      api.answer = () => entitlementsFor(pro: true);
      await billing.refresh();

      expect(access.transcription.engine, TranscriptEngine.cloud);
      expect(access.summaries.engine, SummaryEngine.cloud);
      expect(notified, 1);
    },
  );

  test('Settings is told why Cloud is off on the free plan', () async {
    await start(_Plan.free);

    expect(access.transcription, (
      engine: TranscriptEngine.device,
      cloudSelectable: false,
      note: 'Cloud transcription is on Pro',
    ));
    expect(access.summaries, (
      engine: SummaryEngine.device,
      cloudSelectable: false,
      note: 'Cloud summaries are on Pro',
    ));
  });

  test(
    'a language this device cannot transcribe says why Cloud stays',
    () async {
      await start(_Plan.free, language: 'hi');

      expect(access.transcription, (
        engine: TranscriptEngine.cloud,
        cloudSelectable: true,
        note: "Cloud is used for Hindi, which this device can't transcribe",
      ));
      expect(access.summaries.note, 'Cloud summaries are on Pro');
    },
  );

  test('Pro has no exception to explain', () async {
    await start(_Plan.pro, language: 'hi');

    expect(access.transcription.note, isNull);
    expect(access.summaries.note, isNull);
  });

  test('choosing another language asks the device again', () async {
    await start(_Plan.free, language: 'en');
    var notified = 0;
    access.addListener(() => notified++);
    expect(access.transcription.engine, TranscriptEngine.device);

    prefs.language = 'hi';
    await settle();
    expect(access.transcription.engine, TranscriptEngine.cloud);
    expect(notified, isNonZero);

    prefs.language = null;
    expect(access.transcription.engine, TranscriptEngine.device);
  });

  test('a language not answered for yet keeps the saved choice', () async {
    await start(_Plan.free);
    device.knows.add('hi');
    prefs.language = 'hi';

    expect(access.transcription.engine, TranscriptEngine.cloud);
    await settle();
    expect(access.transcription.engine, TranscriptEngine.device);
  });

  test('both routers send the work where the plan allows', () async {
    await start(_Plan.free);
    final transcriber = RoutingTranscriber(
      engineOf: () => access.transcription.engine,
      cloud: _FixedTranscriber(TranscriberReadiness.needsAccount),
      device: _FixedTranscriber(TranscriberReadiness.ready),
    );
    final summarizer = RoutingSummarizer(
      engineOf: () => access.summaries.engine,
      cloud: _FixedSummarizer(SummarizerReadiness.needsAccount),
      device: _FixedSummarizer(SummarizerReadiness.ready),
    );

    expect(await transcriber.readiness(), TranscriberReadiness.ready);
    expect(await summarizer.readiness(), SummarizerReadiness.ready);

    api.answer = () => entitlementsFor(pro: true);
    await billing.refresh();

    expect(await transcriber.readiness(), TranscriberReadiness.needsAccount);
    expect(await summarizer.readiness(), SummarizerReadiness.needsAccount);
  });
}
