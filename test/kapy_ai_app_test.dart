import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/voice_prefs.dart';
import 'package:kapy_notes/ui/settings_dialog.dart';
import 'package:kapy_notes/ui/settings_rows.dart';
import 'package:material_ui/material_ui.dart';

import 'fake_kapy_ai.dart';
import 'test_fonts.dart';

/// Where Kapy AI sits in the app: the button, the shortcut, the panel beside
/// the page and over it, the phone's sheet, and Settings. Every one of them
/// is absent in a build that does not carry Kapy AI.

class KapyAiTestStore extends LocalStore {
  KapyAiTestStore() : super(fileName: 'kapy-ai-app-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

late KapyAiTestStore store;
late NotesStore notes;
late LayoutPrefs prefs;
late ShortcutPrefs shortcuts;
late FakeKapyAi ai;

const _windowMaterial = MethodChannel('kapynotes/window_material');

Future<void> _pump(
  WidgetTester tester, {
  Size size = const Size(1500, 800),
  TargetPlatform platform = TargetPlatform.macOS,
}) async {
  AppPlatform.debugTargetPlatformOverride = platform;
  addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
  store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await notes.load();
  prefs.load();
  shortcuts.load();
  await tester.pumpWidget(
    KapyNotesApp(
      store: store,
      notes: notes,
      rates: RatesRepository(store),
      prefs: prefs,
      shortcuts: shortcuts,
      kapyAi: ai,
    ),
  );
  await tester.pumpAndSettle();
}

Finder get _button => find.byKey(const ValueKey('page-kapy-ai'));
Finder get _panel => find.byKey(const ValueKey('kapy-ai-panel'));

Future<void> _toggleWithKeys(WidgetTester tester) async {
  final key = AppPlatform.isMacOS
      ? LogicalKeyboardKey.metaLeft
      : LogicalKeyboardKey.controlLeft;
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.keyJ);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.keyJ);
  await tester.sendKeyUpEvent(key);
  await tester.pumpAndSettle();
}

Future<void> _openSettings(
  WidgetTester tester, {
  KapyAi? kapyAi,
  SettingsSection section = SettingsSection.voice,
  String? reveal,
}) async {
  AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
  addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
  tester.view.physicalSize = const Size(1000, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: KapyTheme.dark(),
      home: Scaffold(
        body: SettingsDialog(
          layoutPrefs: prefs,
          shortcuts: shortcuts..load(),
          rates: RatesRepository(store),
          notes: notes,
          voicePrefs: VoicePrefs(store)..load(),
          kapyAi: kapyAi,
          section: section,
          reveal: reveal,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadTestFonts);

  late bool wasAvailable;
  setUp(() {
    wasAvailable = kapyAiAvailable;
    kapyAiAvailable = true;
    store = KapyAiTestStore();
    notes = NotesStore(store, now: () => DateTime(2026, 11, 17, 16, 40));
    prefs = LayoutPrefs(store);
    shortcuts = ShortcutPrefs(store);
    ai = FakeKapyAi();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_windowMaterial, (call) async => false);
  });
  tearDown(() {
    kapyAiAvailable = wasAvailable;
    ai.dispose();
  });

  group('on the page', () {
    testWidgets('the button opens and closes the panel beside the page', (
      tester,
    ) async {
      notes.create(body: 'Trip budget\n900 flights');
      await _pump(tester);

      expect(_button, findsOneWidget);
      expect(_panel, findsNothing);

      await tester.tap(_button);
      await tester.pumpAndSettle();
      expect(_panel, findsOneWidget);
      expect(find.byKey(const ValueKey('kapy-ai-overlay')), findsNothing);
      expect(find.text('This note · Trip budget'), findsOneWidget);

      await tester.tap(_button);
      await tester.pumpAndSettle();
      expect(_panel, findsNothing);
    });

    testWidgets('⌘J opens it, Esc and ✕ close it', (tester) async {
      notes.create(body: 'Trip budget');
      await _pump(tester);

      await _toggleWithKeys(tester);
      expect(_panel, findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(_panel, findsNothing);

      await _toggleWithKeys(tester);
      expect(_panel, findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('kapy-ai-close')));
      await tester.pumpAndSettle();
      expect(_panel, findsNothing);

      await _toggleWithKeys(tester);
      await _toggleWithKeys(tester);
      expect(_panel, findsNothing);
    });

    testWidgets('a narrow window has it over the page, not beside it', (
      tester,
    ) async {
      notes.create(body: 'Trip budget');
      await _pump(tester, size: const Size(1100, 760));

      await tester.tap(_button);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('kapy-ai-overlay')), findsOneWidget);
      expect(_panel, findsOneWidget);
    });

    testWidgets('a hidden note never gets a chip', (tester) async {
      final note = notes.create(body: 'Private plans');
      notes.hide(note.id);
      await _pump(tester);

      await tester.tap(_button);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('kapy-ai-chip')), findsNothing);
      expect(find.textContaining('Private plans'), findsNothing);
    });

    testWidgets('a phone has the button in its top bar, and a sheet', (
      tester,
    ) async {
      notes.create(body: 'Trip budget');
      await _pump(
        tester,
        size: const Size(390, 844),
        platform: TargetPlatform.iOS,
      );

      expect(_button, findsOneWidget);
      await tester.tap(_button);
      await tester.pumpAndSettle();

      expect(_panel, findsOneWidget);
      expect(find.text('This note · Trip budget'), findsOneWidget);
      expect(find.textContaining('opens and closes Kapy AI'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('kapy-ai-close')));
      await tester.pumpAndSettle();
      expect(_panel, findsNothing);
    });

    testWidgets('turned off in Settings, the button and ⌘J do nothing', (
      tester,
    ) async {
      notes.create(body: 'Trip budget');
      ai.enabled = false;
      await _pump(tester);

      expect(_button, findsNothing);
      await _toggleWithKeys(tester);
      expect(_panel, findsNothing);
    });

    testWidgets('a build without Kapy AI shows nothing of it', (tester) async {
      kapyAiAvailable = false;
      notes.create(body: 'Trip budget');
      await _pump(tester);

      expect(_button, findsNothing);
      await _toggleWithKeys(tester);
      expect(_panel, findsNothing);
    });
  });

  group('in Settings', () {
    testWidgets('Pro: both groups, and their rows', (tester) async {
      ai = FakeKapyAi(
        pro: true,
        deviceState: const DeviceModelState(
          status: DeviceModelStatus.ready,
          model: FakeKapyAi.gemma,
          totalBytes: 2600000000,
          receivedBytes: 2600000000,
        ),
        accountList: const [
          KapyAccountState(
            kind: KapyAccountKind.codex,
            status: KapyAccountStatus.connected,
            models: [FakeKapyAi.gpt, FakeKapyAi.gptMini],
          ),
          KapyAccountState(
            kind: KapyAccountKind.claudeCode,
            status: KapyAccountStatus.connected,
            models: [FakeKapyAi.sonnet],
          ),
          KapyAccountState(
            kind: KapyAccountKind.openRouter,
            status: KapyAccountStatus.connected,
            detail: '4f2a',
          ),
        ],
      );
      await _openSettings(
        tester,
        kapyAi: ai,
        reveal: 'kapy-account-openRouter',
      );

      expect(find.text('Your accounts'), findsOneWidget);
      expect(
        find.text('Used for new chats. Each chat can switch in the panel'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Models from a plan or key you already have. Hidden notes never go '
          'to them',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Deletes every Kapy AI chat on all your devices'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('kapy-device-remove')), findsOneWidget);
      expect(
        find.text('Found on this Mac · GPT-5.5, GPT-5.4 mini'),
        findsOneWidget,
      );
      expect(find.text('Found on this Mac · Sonnet 5.5'), findsOneWidget);
      expect(
        find.text('Key ending 4f2a, kept in your Keychain'),
        findsOneWidget,
      );
      expect(find.textContaining('ChatGPT sign'), findsNothing);
    });

    testWidgets('Free: Cloud is part of Pro, and the model downloads', (
      tester,
    ) async {
      ai = FakeKapyAi(
        deviceState: const DeviceModelState(
          status: DeviceModelStatus.notDownloaded,
          model: FakeKapyAi.gemma,
          totalBytes: 2600000000,
        ),
        accountList: const [
          KapyAccountState(
            kind: KapyAccountKind.codex,
            status: KapyAccountStatus.notConnected,
          ),
          KapyAccountState(
            kind: KapyAccountKind.claudeCode,
            status: KapyAccountStatus.notConnected,
          ),
          KapyAccountState(
            kind: KapyAccountKind.openRouter,
            status: KapyAccountStatus.notConnected,
          ),
        ],
      );
      await _openSettings(
        tester,
        kapyAi: ai,
        reveal: 'kapy-account-openRouter',
      );

      expect(find.text('Kapy AI Cloud is part of Pro'), findsOneWidget);
      expect(
        find.text('Deletes every Kapy AI chat on this Mac'),
        findsOneWidget,
      );
      expect(
        find.text('Install Codex and sign in there. Kapy finds it'),
        findsOneWidget,
      );
      expect(
        find.text('Install Claude Code and sign in there. Kapy finds it'),
        findsOneWidget,
      );
      expect(
        find.text('Your own key, for any model on OpenRouter'),
        findsOneWidget,
      );
      final codex = tester.getTopLeft(
        find.byKey(const ValueKey('kapy-account-codex')),
      );
      final claude = tester.getTopLeft(
        find.byKey(const ValueKey('kapy-account-claudeCode')),
      );
      expect(codex.dy, lessThan(claude.dy));

      await tester.tap(find.byKey(const ValueKey('kapy-device-download')));
      expect(ai.calls, ['downloadDeviceModel']);
    });

    testWidgets('a signed-out Codex says so, and Check again looks', (
      tester,
    ) async {
      ai = FakeKapyAi(
        accountList: const [
          KapyAccountState(
            kind: KapyAccountKind.codex,
            status: KapyAccountStatus.error,
          ),
        ],
      );
      await _openSettings(tester, kapyAi: ai, reveal: 'kapy-account-codex');

      expect(
        find.text('Signed out. Sign in inside Codex, then check again'),
        findsOneWidget,
      );
      await tester.tap(find.text('Check again'));
      expect(ai.calls, ['checkCodex']);
    });

    testWidgets('a found Codex has a switch for whether Kapy may use it', (
      tester,
    ) async {
      ai = FakeKapyAi(
        accountList: const [
          KapyAccountState(
            kind: KapyAccountKind.codex,
            status: KapyAccountStatus.connected,
            models: [FakeKapyAi.gpt],
          ),
        ],
      );
      await _openSettings(tester, kapyAi: ai, reveal: 'kapy-account-codex');

      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('kapy-account-codex')),
          matching: find.byType(SettingsSwitch),
        ),
      );
      expect(ai.calls, ['allowCodex:false']);
    });

    testWidgets('a phone is offered only the OpenRouter key', (tester) async {
      ai = FakeKapyAi(
        accountList: const [
          KapyAccountState(
            kind: KapyAccountKind.openRouter,
            status: KapyAccountStatus.notConnected,
          ),
        ],
      );
      await _openSettings(
        tester,
        kapyAi: ai,
        reveal: 'kapy-account-openRouter',
      );

      expect(find.byKey(const ValueKey('kapy-account-codex')), findsNothing);
      expect(
        find.byKey(const ValueKey('kapy-account-claudeCode')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('kapy-account-openRouter')),
        findsOneWidget,
      );
    });

    testWidgets('the key is typed masked, validated, and never echoed', (
      tester,
    ) async {
      ai = FakeKapyAi(
        accountList: const [
          KapyAccountState(
            kind: KapyAccountKind.openRouter,
            status: KapyAccountStatus.notConnected,
          ),
        ],
      )..keyAccepted = false;
      await _openSettings(
        tester,
        kapyAi: ai,
        reveal: 'kapy-account-openRouter',
      );

      await tester.tap(find.text('Add key'));
      await tester.pumpAndSettle();
      expect(
        find.text('Kept in your Keychain on this device, never synced'),
        findsOneWidget,
      );
      final field = find.byKey(const ValueKey('kapy-openrouter-key-field'));
      expect(tester.widget<TextField>(field).obscureText, isTrue);

      await tester.enterText(field, 'sk-or-v1-secret-1234');
      await tester.tap(find.byKey(const ValueKey('kapy-openrouter-save')));
      await tester.pumpAndSettle();

      expect(ai.lastKey, 'sk-or-v1-secret-1234');
      expect(find.text('OpenRouter rejected this key'), findsOneWidget);
      expect(find.text('Replace key'), findsOneWidget);
      expect(find.textContaining('secret'), findsNothing);
      expect(find.textContaining('sk-or'), findsNothing);
    });

    testWidgets('Clear history says this device only when chats do not sync', (
      tester,
    ) async {
      ai = FakeKapyAi(pro: true)..syncing = false;
      await _openSettings(tester, kapyAi: ai, reveal: 'kapy-ai-clear-history');

      expect(
        find.text('Deletes every Kapy AI chat on all your devices'),
        findsNothing,
      );
      expect(
        find.text('Deletes every Kapy AI chat on this Mac'),
        findsOneWidget,
      );
    });

    testWidgets('Clear… asks once before it clears', (tester) async {
      ai = FakeKapyAi(pro: true);
      await _openSettings(tester, kapyAi: ai, reveal: 'kapy-ai-clear-history');

      await tester.tap(find.byKey(const ValueKey('kapy-ai-clear')));
      await tester.pumpAndSettle();
      expect(ai.calls, isNot(contains('clearHistory')));

      await tester.tap(find.text('Clear').last);
      await tester.pumpAndSettle();
      expect(ai.calls, contains('clearHistory'));
    });

    testWidgets('the shortcut has a row, and search finds the groups', (
      tester,
    ) async {
      ai = FakeKapyAi(pro: true);
      await _openSettings(
        tester,
        kapyAi: ai,
        section: SettingsSection.shortcuts,
      );
      expect(find.text('Open or close Kapy AI'), findsOneWidget);

      await _openSettings(tester, kapyAi: ai);
      await tester.enterText(
        find.byKey(const ValueKey('settings-search')),
        'gemma',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          const ValueKey('settings-search-result-kapy-ai-device-model'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a build without Kapy AI has none of its settings', (
      tester,
    ) async {
      kapyAiAvailable = false;
      await _openSettings(tester, kapyAi: ai);

      expect(find.text('Your accounts'), findsNothing);
      expect(find.byKey(const ValueKey('kapy-ai-toggle')), findsNothing);

      await _openSettings(
        tester,
        kapyAi: ai,
        section: SettingsSection.shortcuts,
      );
      expect(find.text('Open or close Kapy AI'), findsNothing);

      await _openSettings(tester, kapyAi: ai);
      await tester.enterText(
        find.byKey(const ValueKey('settings-search')),
        'kapy ai',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('settings-search-result-kapy-ai-toggle')),
        findsNothing,
      );
    });

    testWidgets('Manage accounts… lands on the account it names', (
      tester,
    ) async {
      ai = FakeKapyAi(
        accountList: const [
          KapyAccountState(
            kind: KapyAccountKind.openRouter,
            status: KapyAccountStatus.notConnected,
          ),
        ],
      );
      await _openSettings(
        tester,
        kapyAi: ai,
        reveal: 'kapy-account-openRouter',
      );

      final row = tester.getRect(
        find.byKey(const ValueKey('kapy-account-openRouter')),
      );
      final dialog = tester.getRect(
        find.byKey(const ValueKey('settings-dialog-content')),
      );
      expect(row.top, greaterThanOrEqualTo(dialog.top));
      expect(row.bottom, lessThanOrEqualTo(dialog.bottom));
    });
  });

  group('goldens', () {
    void dark(WidgetTester tester) {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a narrow window, the panel over the page', (tester) async {
      dark(tester);
      notes.create(body: 'Trip budget\n900 flights\n600 hotel');
      ai = FakeKapyAi(pro: true)
        ..set(
          current: KapyChat(
            id: 'c1',
            title: 'Trip budget',
            createdAt: DateTime(2026, 11, 17),
            updatedAt: DateTime(2026, 11, 17),
            model: KapyModel.cloud,
            messages: [
              KapyMessage(
                id: 'q',
                role: KapyRole.user,
                text: 'What’s still left to book for Lisbon?',
                at: DateTime(2026, 11, 17),
              ),
              KapyMessage(
                id: 'a',
                role: KapyRole.assistant,
                text:
                    'Two things are still open: travel insurance and the '
                    'offline maps.',
                at: DateTime(2026, 11, 17),
                model: KapyModel.cloud,
              ),
            ],
          ),
          model: KapyModel.cloud,
        );
      await _pump(tester, size: const Size(1100, 760));
      await tester.tap(_button);
      await settle(tester);

      await expectLater(
        find.byType(KapyNotesApp),
        matchesGoldenFile('goldens/kapy_ai_narrow_dark.png'),
      );
    });

    testWidgets('the phone’s sheet', (tester) async {
      dark(tester);
      notes.create(body: 'Trip budget\n900 flights\n600 hotel');
      await _pump(
        tester,
        size: const Size(390, 844),
        platform: TargetPlatform.iOS,
      );
      await tester.tap(_button);
      await settle(tester);

      await expectLater(
        find.byType(KapyNotesApp),
        matchesGoldenFile('goldens/kapy_ai_phone_dark.png'),
      );
    });

    testWidgets('the panel beside the page', (tester) async {
      dark(tester);
      notes.create(body: 'Trip budget\n900 flights\n600 hotel');
      await _pump(tester, size: const Size(1500, 800));
      await tester.tap(_button);
      await settle(tester);

      await expectLater(
        find.byType(KapyNotesApp),
        matchesGoldenFile('goldens/kapy_ai_beside_dark.png'),
      );
    });

    testWidgets('Settings, Kapy AI on Pro', (tester) async {
      ai = FakeKapyAi(
        pro: true,
        deviceState: const DeviceModelState(
          status: DeviceModelStatus.ready,
          model: FakeKapyAi.gemma,
          totalBytes: 2600000000,
          receivedBytes: 2600000000,
        ),
        accountList: const [
          KapyAccountState(
            kind: KapyAccountKind.codex,
            status: KapyAccountStatus.connected,
            models: [FakeKapyAi.gpt, FakeKapyAi.gptMini],
          ),
          KapyAccountState(
            kind: KapyAccountKind.claudeCode,
            status: KapyAccountStatus.connected,
            models: [FakeKapyAi.sonnet],
          ),
          KapyAccountState(
            kind: KapyAccountKind.openRouter,
            status: KapyAccountStatus.connected,
            detail: '4f2a',
          ),
        ],
      )..defaultModel = KapyModel.cloud;
      await _openSettings(
        tester,
        kapyAi: ai,
        reveal: 'kapy-account-openRouter',
      );
      await settle(tester);

      await expectLater(
        find.byKey(const ValueKey('settings-dialog-content')),
        matchesGoldenFile('goldens/kapy_ai_settings_pro_dark.png'),
      );
    });

    testWidgets('Settings, Your accounts on Free', (tester) async {
      ai = FakeKapyAi(
        deviceState: const DeviceModelState(
          status: DeviceModelStatus.notDownloaded,
          model: FakeKapyAi.gemma,
          totalBytes: 2600000000,
        ),
        accountList: const [
          KapyAccountState(
            kind: KapyAccountKind.codex,
            status: KapyAccountStatus.notConnected,
          ),
          KapyAccountState(
            kind: KapyAccountKind.claudeCode,
            status: KapyAccountStatus.error,
          ),
          KapyAccountState(
            kind: KapyAccountKind.openRouter,
            status: KapyAccountStatus.notConnected,
          ),
        ],
      );
      await _openSettings(
        tester,
        kapyAi: ai,
        reveal: 'kapy-account-openRouter',
      );
      await settle(tester);

      await expectLater(
        find.byKey(const ValueKey('settings-dialog-content')),
        matchesGoldenFile('goldens/kapy_ai_settings_free_dark.png'),
      );
    });
  });
}
