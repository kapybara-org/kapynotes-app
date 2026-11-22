import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/desktop_integration.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/voice_prefs.dart';
import 'package:kapy_notes/ui/settings_dialog.dart';
import 'package:kapy_notes/ui/settings_rows.dart';
import 'package:material_ui/material_ui.dart';

class MemoryFakeStore extends LocalStore {
  MemoryFakeStore() : super(fileName: 'settings-sheet-test.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
}

late MemoryFakeStore store;
late NotesStore notes;
late LayoutPrefs prefs;
late ShortcutPrefs shortcuts;

/// A phone-sized surface with nothing on it but the button that opens
/// settings, which is all any of this needs.
Future<void> _pumpPhone(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  VoicePrefs? voicePrefs,
  DesktopIntegration? desktopIntegration,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: KapyTheme.dark(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSettings(
              context,
              layoutPrefs: prefs,
              shortcuts: shortcuts,
              rates: RatesRepository(store),
              notes: notes,
              voicePrefs: voicePrefs,
              desktopIntegration: desktopIntegration,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openSettings(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _openCategory(WidgetTester tester, String name) async {
  await tester.tap(find.byKey(ValueKey('settings-section-$name')));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() async {
    // These tests run on a desktop host, so the phone has to be declared.
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    store = MemoryFakeStore();
    notes = NotesStore(store);
    await notes.load();
    prefs = LayoutPrefs(store)..load();
    shortcuts = ShortcutPrefs(store)..load();
  });

  testWidgets('opens on its categories rather than on every pane at once', (
    tester,
  ) async {
    await _pumpPhone(tester);
    await _openSettings(tester);

    expect(
      find.byKey(const ValueKey('settings-section-notes')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('settings-section-appearance')),
      findsOneWidget,
    );
    // Numbers stopped being a category of its own: one choice and a credit
    // line is not worth a click on the way to everything else.
    expect(
      find.byKey(const ValueKey('settings-section-numbers')),
      findsNothing,
    );
    // One line each, as M16 draws them, with the notes before their look and
    // Appearance saying what it is set to.
    expect(
      find.text('How Kapy Notes looks: theme, paper, fonts and text size'),
      findsNothing,
    );
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey('settings-section-notes')))
          .dy,
      lessThan(
        tester
            .getTopLeft(
              find.byKey(const ValueKey('settings-section-appearance')),
            )
            .dy,
      ),
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('settings-section-appearance')),
        matching: find.text('System'),
      ),
      findsOneWidget,
    );

    // Shortcuts and the window belong to a desktop. About does not: phones
    // update through their store, but the release notes still live there.
    for (final section in ['shortcuts', 'window']) {
      expect(
        find.byKey(ValueKey('settings-section-$section')),
        findsNothing,
        reason: '$section is not a phone category',
      );
    }
    expect(
      find.byKey(const ValueKey('settings-section-about')),
      findsOneWidget,
      reason: 'About keeps the release notes reachable on a phone',
    );

    // The whole point of the list: none of the panes are on this screen.
    expect(find.text('Daily separators'), findsNothing);
    expect(find.text('PAPER AND TEXT'), findsNothing);
  });

  testWidgets('pushes one category and comes back to the list', (tester) async {
    await _pumpPhone(tester);
    await _openSettings(tester);
    await _openCategory(tester, 'appearance');

    // The title says where you are, and only that category is here.
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('PAPER AND TEXT'), findsOneWidget);
    expect(find.byKey(const ValueKey('transparency-setting')), findsNothing);
    expect(find.byKey(const ValueKey('settings-section-notes')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('settings-sheet-back')));
    await tester.pumpAndSettle();

    expect(find.text('PAPER AND TEXT'), findsNothing);
    expect(
      find.byKey(const ValueKey('settings-section-notes')),
      findsOneWidget,
    );
  });

  testWidgets('a switch inside a pushed category still changes the setting', (
    tester,
  ) async {
    await _pumpPhone(tester);
    await _openSettings(tester);
    await _openCategory(tester, 'notes');

    expect(prefs.dailySeparatorsEnabled, isTrue);
    await tester.tap(find.byKey(const ValueKey('daily-separators-toggle')));
    await tester.pumpAndSettle();

    expect(prefs.dailySeparatorsEnabled, isFalse);
  });

  testWidgets('markdown in notes is a switch among the writing settings', (
    tester,
  ) async {
    await _pumpPhone(tester);
    await _openSettings(tester);
    await _openCategory(tester, 'notes');

    final toggle = find.byKey(const ValueKey('markdown-toggle'));
    await tester.scrollUntilVisible(toggle, 200);
    expect(
      find.descendant(of: toggle, matching: find.text('Markdown')),
      findsOneWidget,
    );
    expect(prefs.markdownEnabled, isTrue);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(prefs.markdownEnabled, isFalse);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(prefs.markdownEnabled, isTrue);
  });

  testWidgets('the back gesture leaves the category before the sheet', (
    tester,
  ) async {
    await _pumpPhone(tester);
    await _openSettings(tester);
    await _openCategory(tester, 'appearance');

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('settings-section-notes')),
      findsOneWidget,
      reason: 'the first back is out of the category, not out of settings',
    );

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('settings-section-notes')),
      findsNothing,
      reason: 'and the second back is out of settings',
    );
  });

  testWidgets('Done closes the whole sheet from inside a category', (
    tester,
  ) async {
    await _pumpPhone(tester);
    await _openSettings(tester);
    await _openCategory(tester, 'notes');

    await tester.tap(find.byKey(const ValueKey('settings-sheet-done')));
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsNothing);
    expect(find.byKey(const ValueKey('settings-section-notes')), findsNothing);
  });

  testWidgets('gives every row a thumb to aim at', (tester) async {
    await _pumpPhone(tester);
    await _openSettings(tester);

    // The list itself first.
    expect(
      tester
          .getSize(find.byKey(const ValueKey('settings-section-notes')))
          .height,
      greaterThanOrEqualTo(44),
    );

    await _openCategory(tester, 'notes');
    for (final key in ['daily-separators-toggle', 'export-notes']) {
      expect(
        tester.getSize(find.byKey(ValueKey(key))).height,
        greaterThanOrEqualTo(44),
        reason: '$key is smaller than a fingertip',
      );
    }
  });

  testWidgets('lifts clear of the keyboard rather than sitting under it', (
    tester,
  ) async {
    await _pumpPhone(tester);
    await _openSettings(tester);

    final sheet = find.byKey(const ValueKey('settings-sheet'));
    expect(tester.getRect(sheet).bottom, closeTo(844, 0.5));
    final top = tester.getRect(sheet).top;

    // Signing in happens in here, so a keyboard is not a hypothetical.
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();

    final lifted = tester.getRect(sheet);
    expect(lifted.bottom, closeTo(544, 0.5));
    expect(
      lifted.top,
      closeTo(top, 0.5),
      reason: 'the sheet shortens from the bottom; its top edge stays put',
    );
  });

  testWidgets('a narrow Windows window widens for settings, then narrows', (
    tester,
  ) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.windows;
    final nativeCalls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const windowChannel = MethodChannel('window_manager');
    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      nativeCalls.add(call);
      if (call.method == 'getBounds') {
        return {'x': 200.0, 'y': 80.0, 'width': 520.0, 'height': 720.0};
      }
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(windowChannel, null));
    final integration = DesktopIntegration(layoutPrefs: prefs);
    addTearDown(integration.dispose);
    // The native window is widened before the dialog opens, so the view it
    // lays out in is the widened one.
    await _pumpPhone(
      tester,
      size: const Size(1004, 760),
      desktopIntegration: integration,
    );
    await _openSettings(tester);

    expect(
      nativeCalls.map((call) => call.method),
      containsAllInOrder(['getBounds', 'setMinimumSize', 'setBounds']),
    );
    expect(
      (nativeCalls.lastWhere((call) => call.method == 'setBounds').arguments
          as Map)['width'],
      1004.0,
      reason: 'the Windows host is widened before the dialog is shown',
    );
    expect(
      find.byKey(const ValueKey('settings-dialog-content')),
      findsOneWidget,
    );
    final appearance = find.byKey(
      const ValueKey('settings-section-appearance'),
    );
    expect(appearance, findsOneWidget);
    expect(find.text('Writing font'), findsOneWidget);
    expect(
      tester.getCenter(appearance).dx,
      lessThan(tester.getCenter(find.text('Writing font')).dx),
    );
    // Headings are written in capitals on a phone only.
    expect(find.text('TEXT'), findsNothing);
    expect(find.byKey(const ValueKey('settings-sheet-done')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('settings-done')));
    await tester.pumpAndSettle();
    expect(
      (nativeCalls.lastWhere((call) => call.method == 'setBounds').arguments
          as Map)['width'],
      520.0,
      reason: 'closing settings gives the user their narrow window back',
    );
  });

  test('Windows settings keeps secondary copy comfortably readable', () {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.windows;

    expect(SettingsMetrics.titleSize, 14);
    expect(SettingsMetrics.subtitleSize, 13);
    expect(
      SettingsMetrics.titleSize - SettingsMetrics.subtitleSize,
      1,
      reason: 'the hierarchy should be clear without miniaturising subtitles',
    );
  });

  testWidgets('a phone gives a settings subtitle two lines', (tester) async {
    const copy = 'How Kapy Notes looks: theme, paper, fonts and text size';
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: const Center(
          child: SizedBox(
            width: 380,
            child: SettingsRowCopy(title: 'Appearance', subtitle: copy),
          ),
        ),
      ),
    );

    final subtitle = tester.renderObject<RenderParagraph>(
      find.descendant(of: find.text(copy), matching: find.byType(RichText)),
    );
    expect(subtitle.maxLines, 2);
    expect(subtitle.didExceedMaxLines, isFalse);
    expect(subtitle.getMaxIntrinsicWidth(double.infinity), greaterThan(380));
  });

  testWidgets('desktop settings subtitles stay on one line', (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: const SizedBox(
          width: 180,
          child: SettingsRowCopy(
            title: 'Ready to type on open',
            subtitle: 'Restore your cursor position when you return to the app',
          ),
        ),
      ),
    );

    final subtitle = tester.widget<Text>(
      find.text('Restore your cursor position when you return to the app'),
    );
    expect(subtitle.maxLines, 1);
    expect(subtitle.softWrap, isFalse);
    expect(subtitle.overflow, TextOverflow.ellipsis);
  });

  testWidgets('voice notes puts each engine choice in one row', (tester) async {
    await _pumpPhone(tester, voicePrefs: VoicePrefs(store)..load());
    await _openSettings(tester);
    await _openCategory(tester, 'voice');

    expect(find.text('VOICE NOTES'), findsOneWidget);
    expect(find.text('TRANSCRIPTION'), findsOneWidget);
    // The cloud and this device are one mutually exclusive choice, so they
    // are two halves of one control rather than two rows.
    for (final key in ['transcribe-with-cloud', 'transcribe-with-device']) {
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('transcribe-with')),
          matching: find.byKey(ValueKey(key)),
        ),
        findsOneWidget,
      );
    }
    // What this device can run is said under the choice, whether or not this
    // build can offer anything: that line is where you look to find out.
    expect(find.byKey(const ValueKey('local-transcription-line')), findsOne);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('local-summary-line')),
      200,
    );
    expect(find.text('SUMMARIES'), findsOneWidget);
  });

  testWidgets('opens straight on a pane when sent to one', (tester) async {
    await _pumpPhone(tester, voicePrefs: VoicePrefs(store)..load());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await _openCategory(tester, 'voice');
    expect(find.text('TRANSCRIPTION'), findsOneWidget);
  });

  testWidgets('notes settings does not offer the welcome note', (tester) async {
    await _pumpPhone(tester, voicePrefs: VoicePrefs(store)..load());
    await _openSettings(tester);
    await _openCategory(tester, 'notes');

    expect(find.byKey(const ValueKey('open-welcome-note')), findsNothing);
    expect(find.text('Welcome note'), findsNothing);
  });

  testWidgets('signed out, the cloud says it needs an account', (tester) async {
    final voice = VoicePrefs(store)..load();
    await _pumpPhone(tester, voicePrefs: voice);
    await _openSettings(tester);
    await _openCategory(tester, 'voice');

    // No account is wired up here, which is what signed out looks like.
    expect(
      find.byKey(const ValueKey('voice-sign-in-row')),
      findsNothing,
      reason: 'the cloud choice is disabled, not a detour out of Voice',
    );
    expect(
      find.text('Cloud needs you signed in. This device works offline'),
      findsOneWidget,
    );
    final before = voice.transcriptEngine;
    await tester.tap(find.byKey(const ValueKey('transcribe-with-cloud')));
    await tester.pumpAndSettle();
    expect(voice.transcriptEngine, before);
    expect(find.byType(BottomSheet), findsOneWidget);
  });
}
