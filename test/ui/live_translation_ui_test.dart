import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/audio/live_text.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/voice_prefs.dart';
import 'package:kapy_notes/speech/live_translation.dart';
import 'package:kapy_notes/ui/editor/live_text_card.dart';
import 'package:kapy_notes/ui/settings_dialog.dart';
import 'package:material_ui/material_ui.dart';

import '../audio/live_translation_test.dart' show FakeLiveEngine;

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'live-ui-test.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
  @override
  void putNow(String key, Object? value) => data[key] = value;
}

const _offLine = 'See what’s said, and its translation, while you record.';

void main() {
  late _MemoryStore store;
  late NotesStore notes;
  late VoicePrefs voice;
  late FakeLiveEngine engine;

  setUp(() async {
    store = _MemoryStore();
    notes = NotesStore(store);
    await notes.load();
    voice = VoicePrefs(store)..load();
    voice.language = 'es';
    engine = FakeLiveEngine();
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
  });

  Future<void> openVoice(
    WidgetTester tester, {
    LiveTranslationLauncher? live,
  }) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSettings(
                context,
                layoutPrefs: LayoutPrefs(store)..load(),
                shortcuts: ShortcutPrefs(store)..load(),
                rates: RatesRepository(store),
                notes: notes,
                voicePrefs: voice,
                liveTranslation: live,
                section: SettingsSection.voice,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  LiveTranslationLauncher launcher() =>
      LiveTranslationLauncher(engine: engine, prefs: voice);

  group('Settings', () {
    testWidgets('no card where the app has no live translation', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
      await openVoice(tester);
      expect(find.text(_offLine), findsNothing);
    });

    testWidgets('no card where the device can’t do it', (tester) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
      engine.available = false;
      await openVoice(tester, live: launcher());
      expect(find.text(_offLine), findsNothing);
      expect(engine.calls, ['isAvailable']);
    });

    testWidgets('turning it on picks a language and gets it ready', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
      await openVoice(tester, live: launcher());
      expect(find.text(_offLine), findsOneWidget);
      expect(find.text('Translate to'), findsNothing);
      expect(engine.calls, ['isAvailable', 'languages']);

      await tester.tap(find.text(_offLine));
      await tester.pumpAndSettle();
      expect(find.text('Downloaded'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('voice-live-to-en')));
      await tester.pumpAndSettle();

      expect(engine.calls.skip(2), [
        'pairStatus es en',
        'pairStatus es en',
        'prepare es en',
        'pairStatus es en',
      ]);
      expect(voice.liveTranslation, isTrue);
      expect(voice.liveTranslateTo, 'en');
      expect(find.text('Spoken language'), findsOneWidget);
      expect(find.text('Translate to'), findsOneWidget);
      expect(find.textContaining('Show on the'), findsNothing);
      expect(
        find.text(
          'Translated on this Mac. It’s free, and nothing you say leaves it.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('on Android it says the download first, and Not now keeps it '
        'off', (tester) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
      voice.liveTranslateTo = 'en';
      engine.status = LivePairStatus.downloadable;
      engine.bytes = 62000000;
      await openVoice(tester, live: launcher());

      await tester.tap(find.text(_offLine));
      await tester.pumpAndSettle();
      expect(find.text('Download Spanish and English?'), findsOneWidget);
      expect(find.textContaining('download of about 62 MB'), findsOneWidget);

      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(engine.calls.where((c) => c.startsWith('prepare')), isEmpty);
      expect(voice.liveTranslation, isFalse);
    });

    testWidgets('a pair the device can’t translate says so and stays off', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      voice.liveTranslateTo = 'en';
      engine.status = LivePairStatus.unsupported;
      await openVoice(tester, live: launcher());

      await tester.tap(find.text(_offLine));
      await tester.pumpAndSettle();
      expect(find.textContaining('isn’t on this'), findsOneWidget);
      expect(voice.liveTranslation, isFalse);
    });
  });

  group('the live text card', () {
    late LivePhrases text;
    setUp(() {
      text = LivePhrases(
        from: 'es',
        to: 'en',
        fromName: 'Spanish',
        toName: 'English',
        engine: engine,
      );
      addTearDown(text.dispose);
    });

    Future<void> show(WidgetTester tester, {bool wide = false}) =>
        tester.pumpWidget(
          MaterialApp(
            theme: KapyTheme.light(),
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: LiveTextCard(
                  text: text,
                  prefs: voice,
                  paused: false,
                  wide: wide,
                ),
              ),
            ),
          ),
        );

    testWidgets('leads with the translation, and the words as heard', (
      tester,
    ) async {
      await show(tester);
      expect(find.text('Listening for Spanish…'), findsOneWidget);

      engine.phraseEvents.add(
        const LivePhrase(
          id: 1,
          heard: 'Hola a todos',
          translation: 'Hello all',
        ),
      );
      engine.phraseEvents.add(const LivePhrase(id: 2, heard: 'Y el'));
      await tester.pump();

      expect(find.text('Spanish → English'), findsOneWidget);
      expect(find.text('Hello all'), findsOneWidget);
      expect(find.text('Hola a todos'), findsOneWidget);
      expect(find.text('…'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Hello all')).dy,
        lessThan(tester.getTopLeft(find.text('Hola a todos')).dy),
      );
    });

    testWidgets('folds to a tab, and remembers it', (tester) async {
      await show(tester, wide: true);
      await tester.tap(find.byKey(const ValueKey('live-text-fold')));
      await tester.pump();
      expect(voice.liveTextFolded, isTrue);
      expect(find.text('Live text'), findsOneWidget);
      expect(find.text('Listening for Spanish…'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('live-text-unfold')));
      await tester.pump();
      expect(voice.liveTextFolded, isFalse);
    });

    testWidgets('says when live text stopped, and that recording goes on', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
      await show(tester);
      engine.stopEvents.add(LiveTranslationStop.failed);
      await tester.pump();
      expect(
        find.text('Live text stopped. The recording carries on.'),
        findsOneWidget,
      );
    });
  });
}
