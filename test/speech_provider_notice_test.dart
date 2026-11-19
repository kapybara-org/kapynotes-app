import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/voice_prefs.dart';
import 'package:kapy_notes/speech/speech_api.dart';
import 'package:kapy_notes/sync/account.dart';
import 'package:kapy_notes/ui/speech_provider_notice.dart';
import 'package:kapy_notes/ui/voice_consent_sheet.dart';
import 'package:material_ui/material_ui.dart';

class _Store extends LocalStore {
  _Store() : super(fileName: 'speech-provider-notice-test.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
}

class _Speech implements SpeechApi {
  int accepted = speechConsentVersion;
  bool offline = false;
  bool refuses = false;
  int asked = 0;
  final List<int> sent = [];

  SpeechConsentStatus get _status => SpeechConsentStatus(
    acceptedVersion: accepted,
    currentVersion: speechConsentVersion,
  );

  @override
  Future<SpeechConsentStatus> consent() async {
    asked++;
    if (offline) throw const SocketException('offline');
    return _status;
  }

  @override
  Future<SpeechConsentStatus> acceptConsent(int version) async {
    if (refuses) throw const SocketException('offline');
    sent.add(version);
    accepted = version;
    return _status;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Account extends ChangeNotifier implements Account {
  _Account(this.speech);

  @override
  SpeechApi? speech;

  AccountState _state = AccountState.ready;

  @override
  AccountState get state => _state;
  set state(AccountState value) {
    _state = value;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

const _notice = 'Cloud transcription has new providers';
const _audio =
    'To transcribe a recording, Kapy Notes sends its audio through our server '
    "and OpenRouter to Microsoft's MAI-Transcribe 2, or, when that model is "
    "busy or unavailable, to NVIDIA's Nemotron 3.5 Transcribe. Kapy Notes does "
    'not store the uploaded audio on its server.';

void main() {
  late _Store store;
  late NotesStore notes;
  late _Speech speech;
  late _Account account;

  setUp(() {
    store = _Store();
    notes = NotesStore(store)..create(body: 'Groceries');
    speech = _Speech();
    account = _Account(speech);
  });

  /// One launch: a fresh listener over prefs read back from the same store.
  Future<VoicePrefs> launch(
    WidgetTester tester, {
    Account? signedIn,
    bool useAccount = true,
    ThemeData? theme,
    Widget home = const Scaffold(body: Text('home')),
  }) async {
    final prefs = VoicePrefs(store)..load();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? KapyTheme.light(),
        debugShowCheckedModeBanner: false,
        home: SpeechProviderNoticeListener(
          account: useAccount ? (signedIn ?? account) : null,
          prefs: prefs,
          notes: notes,
          retryAfter: const Duration(seconds: 1),
          child: home,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return prefs;
  }

  Future<void> settleToasts(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }

  group('who sees it', () {
    testWidgets('someone with cloud transcription on from an earlier build', (
      tester,
    ) async {
      await launch(tester);
      expect(find.text(_notice), findsOneWidget);
      expect(find.text(_audio), findsOneWidget);
      expect(find.textContaining('DeepSeek'), findsNothing);
      expect(find.textContaining('Soniox'), findsNothing);
      expect(
        find.text(
          'Cloud summaries send the transcript text to MiniMax M3.1 Flash '
          'through OpenRouter.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('nobody signed out, and nobody without an account', (
      tester,
    ) async {
      account.speech = null;
      account.state = AccountState.signedOut;
      await launch(tester);
      expect(find.text(_notice), findsNothing);
      await launch(tester, useAccount: false);
      expect(find.text(_notice), findsNothing);
      expect(speech.asked, 0);
    });

    testWidgets('nobody with cloud transcription off', (tester) async {
      speech.accepted = 0;
      final prefs = await launch(tester);
      expect(find.text(_notice), findsNothing);
      expect(prefs.owesProviderNotice, isTrue);
    });

    testWidgets('not while the welcome note is all there is', (tester) async {
      notes = NotesStore(_Store());
      Onboarding(_Store()).seedWelcomeNote(notes);
      expect(Onboarding.holdsOnlyWelcome(notes), isTrue);
      await launch(tester);
      await tester.pump(const Duration(seconds: 3));
      expect(find.text(_notice), findsNothing);
      expect(speech.asked, 0);
    });

    testWidgets('not over a passphrase prompt, until the account unlocks', (
      tester,
    ) async {
      for (final state in [
        AccountState.restoring,
        AccountState.needsPassphrase,
        AccountState.locked,
        AccountState.keysChanged,
      ]) {
        account.state = state;
        await launch(tester);
        expect(find.text(_notice), findsNothing, reason: '$state');
      }
      expect(speech.asked, 0);
      account.state = AccountState.ready;
      await tester.pumpAndSettle();
      expect(find.text(_notice), findsOneWidget);
    });

    testWidgets('not over another sheet; it waits for that one to close', (
      tester,
    ) async {
      await launch(
        tester,
        home: Builder(
          builder: (context) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              showDialog<void>(
                context: context,
                builder: (context) =>
                    const AlertDialog(title: Text('Unlock Hidden')),
              );
            });
            return const Scaffold(body: Text('home'));
          },
        ),
      );
      expect(find.text('Unlock Hidden'), findsOneWidget);
      expect(find.text(_notice), findsNothing);
      await tester.pump(const Duration(seconds: 3));
      expect(find.text(_notice), findsNothing);

      Navigator.of(tester.element(find.text('Unlock Hidden'))).pop();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text(_notice), findsOneWidget);
    });

    testWidgets('offline, the home screen is left alone until next launch', (
      tester,
    ) async {
      speech.offline = true;
      final prefs = await launch(tester);
      expect(find.text(_notice), findsNothing);
      expect(find.text('home'), findsOneWidget);
      expect(prefs.owesProviderNotice, isTrue);
      await tester.pump(const Duration(seconds: 3));
      expect(speech.asked, 1);

      speech.offline = false;
      await launch(tester);
      expect(find.text(_notice), findsOneWidget);
    });
  });

  group('answers', () {
    testWidgets('Keep on records it, once only across restarts', (
      tester,
    ) async {
      var prefs = await launch(tester);
      await tester.tap(find.text('Keep on'));
      await tester.pumpAndSettle();
      expect(prefs.owesProviderNotice, isFalse);
      expect(speech.sent, isEmpty);

      prefs = await launch(tester);
      expect(find.text(_notice), findsNothing);
      expect(speech.asked, 1);
    });

    testWidgets('Turn off goes through the Settings switch, then records it', (
      tester,
    ) async {
      var prefs = await launch(tester);
      await tester.tap(find.text('Turn off'));
      await tester.pumpAndSettle();
      expect(speech.sent, [0]);
      expect(find.text('Cloud transcription turned off'), findsOneWidget);
      expect(prefs.owesProviderNotice, isFalse);
      await settleToasts(tester);

      prefs = await launch(tester);
      expect(find.text(_notice), findsNothing);
    });

    testWidgets('a Turn off that fails records nothing and asks again', (
      tester,
    ) async {
      speech.refuses = true;
      final prefs = await launch(tester);
      await tester.tap(find.text('Turn off'));
      await settleToasts(tester);
      expect(prefs.owesProviderNotice, isTrue);

      speech.refuses = false;
      await launch(tester);
      expect(find.text(_notice), findsOneWidget);
    });

    for (final (name, close) in [
      (
        'Esc',
        (WidgetTester tester) =>
            tester.sendKeyEvent(LogicalKeyboardKey.escape),
      ),
      ('back', (WidgetTester tester) => tester.binding.handlePopRoute()),
      ('a tap outside', (WidgetTester tester) => tester.tapAt(Offset.zero)),
    ]) {
      testWidgets('closing with $name records nothing, and it comes back', (
        tester,
      ) async {
        final prefs = await launch(tester);
        await close(tester);
        await tester.pumpAndSettle();
        expect(find.text(_notice), findsNothing);
        expect(prefs.owesProviderNotice, isTrue);
        expect(speech.sent, isEmpty);

        await tester.pump(const Duration(seconds: 3));
        expect(find.text(_notice), findsNothing, reason: 'not this launch');

        await launch(tester);
        expect(find.text(_notice), findsOneWidget);
      });
    }
  });

  group('first-time consent on this build', () {
    testWidgets('turning cloud transcription on records the notice as seen', (
      tester,
    ) async {
      speech.accepted = 0;
      final prefs = VoicePrefs(store)..load();
      await tester.pumpWidget(
        MaterialApp(
          theme: KapyTheme.light(),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => setCloudTranscription(
                context,
                speech: speech,
                prefs: prefs,
                on: true,
              ),
              child: const Text('switch'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('switch'));
      await tester.pumpAndSettle();
      expect(find.text(_audio), findsOneWidget, reason: 'the consent sheet');
      await tester.tap(find.text('Turn on'));
      await settleToasts(tester);
      expect(speech.sent, [speechConsentVersion]);
      expect(prefs.owesProviderNotice, isFalse);

      await launch(tester);
      expect(find.text(_notice), findsNothing);
      expect(speech.asked, 0);
    });

    test('consent from the recording prompt records it too', () {
      final prefs = VoicePrefs(store)..load();
      prefs.transcriptionDeclinedVersion = 1;
      prefs.consentGiven();
      expect(prefs.transcriptionDeclinedVersion, isNull);
      expect(prefs.owesProviderNotice, isFalse);
    });
  });

  group('fits', () {
    for (final (name, size, platform) in [
      ('a small desktop window', const Size(480, 420), TargetPlatform.macOS),
      ('a phone', const Size(390, 844), TargetPlatform.iOS),
      ('phone landscape', const Size(844, 390), TargetPlatform.android),
    ]) {
      testWidgets('$name, with both answers reachable', (tester) async {
        AppPlatform.debugTargetPlatformOverride = platform;
        addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final prefs = await launch(tester);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('Keep on'));
        await tester.ensureVisible(find.text('Turn off'));
        await tester.tap(find.text('Keep on'));
        await tester.pumpAndSettle();
        expect(prefs.owesProviderNotice, isFalse);
      });
    }
  });

  group('goldens', () {
    for (final (name, size, platform, dark) in [
      ('desktop_light', const Size(640, 720), TargetPlatform.macOS, false),
      ('desktop_dark', const Size(640, 720), TargetPlatform.macOS, true),
      ('phone_light', const Size(390, 844), TargetPlatform.iOS, false),
    ]) {
      testWidgets(name, (tester) async {
        AppPlatform.debugTargetPlatformOverride = platform;
        addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await launch(
          tester,
          theme: dark ? KapyTheme.dark() : KapyTheme.light(),
        );
        await expectLater(
          find.byType(AlertDialog),
          matchesGoldenFile('goldens/speech_provider_notice_$name.png'),
        );
      });
    }
  });
}
