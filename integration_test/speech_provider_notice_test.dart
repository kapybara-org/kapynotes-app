// Does the provider notice look and answer right on a real device, with the
// platform's own fonts, back gesture and keyboard?
//
// The widget tests in test/speech_provider_notice_test.dart prove who sees it
// and what each answer records, against a fake server. This runs the same
// notice on a device:
//
//   flutter test integration_test/speech_provider_notice_test.dart -d <id>
//
// --dart-define=NOTICE_HOLD=<seconds> keeps it on screen in each theme, after
// printing "notice-hold <theme>", for a screenshot.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/voice_prefs.dart';
import 'package:kapy_notes/speech/speech_api.dart';
import 'package:kapy_notes/sync/account.dart';
import 'package:kapy_notes/ui/speech_provider_notice.dart';
import 'package:material_ui/material_ui.dart';

class _Store extends LocalStore {
  _Store() : super(fileName: 'speech-provider-notice-integration.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
}

class _Speech implements SpeechApi {
  int accepted = speechConsentVersion;
  final List<int> sent = [];

  SpeechConsentStatus get _status => SpeechConsentStatus(
    acceptedVersion: accepted,
    currentVersion: speechConsentVersion,
  );

  @override
  Future<SpeechConsentStatus> consent() async => _status;

  @override
  Future<SpeechConsentStatus> acceptConsent(int version) async {
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
  final SpeechApi speech;

  @override
  AccountState get state => AccountState.ready;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

const _notice = 'Cloud transcription has new providers';
const _hold = int.fromEnvironment('NOTICE_HOLD');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late _Store store;
  late NotesStore notes;
  late _Speech speech;

  setUp(() {
    store = _Store();
    notes = NotesStore(store)..create(body: 'Groceries');
    speech = _Speech();
  });

  Future<VoicePrefs> launch(WidgetTester tester, {bool dark = false}) async {
    final prefs = VoicePrefs(store)..load();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      MaterialApp(
        theme: dark ? KapyTheme.dark() : KapyTheme.light(),
        debugShowCheckedModeBanner: false,
        home: SpeechProviderNoticeListener(
          account: _Account(speech),
          prefs: prefs,
          notes: notes,
          child: const Scaffold(body: Center(child: Text('home'))),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return prefs;
  }

  for (final dark in [false, true]) {
    testWidgets('shows on a real device, ${dark ? 'dark' : 'light'}', (
      tester,
    ) async {
      final prefs = await launch(tester, dark: dark);
      expect(find.text(_notice), findsOneWidget);
      await tester.ensureVisible(find.text('Keep on'));
      await tester.ensureVisible(find.text('Turn off'));
      await tester.pumpAndSettle();
      if (_hold > 0) {
        // ignore: avoid_print
        print('notice-hold ${dark ? 'dark' : 'light'}');
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: _hold)),
        );
      }
      await tester.tap(find.text('Keep on'));
      await tester.pumpAndSettle();
      expect(prefs.owesProviderNotice, isFalse);
      expect(speech.sent, isEmpty);
    });
  }

  testWidgets('Turn off withdraws and is not asked again', (tester) async {
    var prefs = await launch(tester);
    await tester.ensureVisible(find.text('Turn off'));
    await tester.tap(find.text('Turn off'));
    await tester.pumpAndSettle();
    expect(speech.sent, [0]);
    expect(prefs.owesProviderNotice, isFalse);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    prefs = await launch(tester);
    expect(find.text(_notice), findsNothing);
  });

  testWidgets("the platform's own close records nothing", (tester) async {
    final prefs = await launch(tester);
    if (Platform.isAndroid) {
      await tester.binding.handlePopRoute();
    } else if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    } else {
      await tester.tapAt(const Offset(4, 4));
    }
    await tester.pumpAndSettle();
    expect(find.text(_notice), findsNothing);
    expect(prefs.owesProviderNotice, isTrue);
    await launch(tester);
    expect(find.text(_notice), findsOneWidget);
  });
}
