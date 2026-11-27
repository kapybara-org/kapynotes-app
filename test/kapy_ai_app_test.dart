import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hugeicons/hugeicons.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/core/toast.dart';
import 'package:kapy_notes/data/folders.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note_drawing.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/tags.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/data/voice_prefs.dart';
import 'package:kapy_notes/sync/account.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/sync/key_store.dart';
import 'package:kapy_notes/sync/sync_state.dart';
import 'package:kapy_notes/ui/billing/pro_sheet.dart';
import 'package:kapy_notes/ui/compact_icon_button.dart';
import 'package:kapy_notes/ui/editor/note_field.dart';
import 'package:kapy_notes/ui/kapy_ai/kapy_ai_picker.dart';
import 'package:kapy_notes/ui/kapy_ai/kapy_ai_panel.dart';
import 'package:kapy_notes/ui/kapy_ai/kapy_ai_settings.dart';
import 'package:kapy_notes/ui/page_pane.dart';
import 'package:kapy_notes/ui/spaces_rail.dart';
import 'package:kapy_notes/ui/settings_dialog.dart';
import 'package:kapy_notes/ui/settings_rows.dart';
import 'package:material_ui/material_ui.dart';

import 'billing/billing_fakes.dart';
import 'fake_kapy_ai.dart';
import 'sync/fake_server.dart';
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
  bool sidebar = false,
  FolderStore? folders,
  Account? account,
}) async {
  AppPlatform.debugTargetPlatformOverride = platform;
  addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
  store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await notes.load();
  prefs.load();
  if (prefs.sidebarVisible != sidebar) prefs.toggleSidebar();
  shortcuts.load();
  await tester.pumpWidget(
    KapyNotesApp(
      store: store,
      notes: notes,
      rates: RatesRepository(store),
      prefs: prefs,
      shortcuts: shortcuts,
      kapyAi: ai,
      folders: folders,
      account: account,
    ),
  );
  await tester.pumpAndSettle();
}

Finder get _button => find.byKey(const ValueKey('page-kapy-ai'));
Finder get _panel => find.byKey(const ValueKey('kapy-ai-panel'));
Finder get _ask => find.byKey(const ValueKey('sidebar-ask-kapy'));

Future<void> _chord(WidgetTester tester, LogicalKeyboardKey letter) async {
  final key = AppPlatform.isMacOS
      ? LogicalKeyboardKey.metaLeft
      : LogicalKeyboardKey.controlLeft;
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyDownEvent(letter);
  await tester.sendKeyUpEvent(letter);
  await tester.sendKeyUpEvent(key);
  await tester.pumpAndSettle();
}

Future<void> _toggleWithKeys(WidgetTester tester) =>
    _chord(tester, LogicalKeyboardKey.keyJ);

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

  group('Kapy AI Cloud without Pro, in the app', () {
    /// A signed-out account with billing, and the panel open on a question
    /// Kapy AI Cloud won't answer.
    Future<Finder> lockedCard(WidgetTester tester) async {
      final state = SyncState(store);
      final account = Account(
        auth: FakeAuth(),
        syncApi: (_) => FakeApi(FakeServer()),
        keys: KeyStore(InMemorySecureStore()),
        notes: notes,
        state: state,
        store: store,
        tags: TagStore(store),
        tasks: TaskLibrary(
          notes: notes,
          store: store,
          state: state,
          storage: MemoryDocStorage(),
        ),
      )..billing = billingFor(FakeSession(), FakeBillingApi());
      addTearDown(account.dispose);
      final at = DateTime(2026, 11, 26, 9, 41);
      ai.set(
        current: KapyChat(
          id: 'c',
          title: 'Lisbon?',
          createdAt: at,
          updatedAt: at,
          model: KapyModel.cloud,
          messages: [
            KapyMessage(id: 'q', role: KapyRole.user, text: 'Lisbon?', at: at),
          ],
        ),
        pending: const KapyCloudLocked(signIn: true, upgrade: true),
      );
      notes.create(body: 'Trip budget\n900 flights');
      await _pump(tester, account: account);
      await tester.tap(_button);
      await tester.pumpAndSettle();
      return find.byKey(const ValueKey('kapy-ai-notice'));
    }

    testWidgets('Sign in opens Settings at Account & sync', (tester) async {
      final notice = await lockedCard(tester);
      await tester.tap(
        find.descendant(of: notice, matching: find.text('Sign in')),
      );
      await tester.pumpAndSettle();
      final settings = tester.widget<SettingsDialog>(
        find.byType(SettingsDialog),
      );
      expect(settings.section, SettingsSection.account);
    });

    testWidgets('Upgrade opens the Pro sheet', (tester) async {
      final notice = await lockedCard(tester);
      await tester.tap(
        find.descendant(of: notice, matching: find.text('Upgrade')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ProSheet), findsOneWidget);
    });
  });

  group('on the page', () {
    testWidgets('the button opens and closes the panel beside the page, '
        'with no line under the composer about its keys', (tester) async {
      notes.create(body: 'Trip budget\n900 flights');
      await _pump(tester);

      expect(_button, findsOneWidget);
      expect(_panel, findsNothing);

      await tester.tap(_button);
      await tester.pumpAndSettle();
      expect(_panel, findsOneWidget);
      expect(find.byKey(const ValueKey('kapy-ai-overlay')), findsNothing);
      expect(find.text('This note · Trip budget'), findsOneWidget);
      expect(find.textContaining('opens and closes Kapy AI'), findsNothing);
      expect(
        tester
            .widget<Tooltip>(
              find
                  .descendant(of: _button, matching: find.byType(Tooltip))
                  .first,
            )
            .message,
        contains('J'),
      );

      await tester.tap(_button);
      await tester.pumpAndSettle();
      expect(_panel, findsNothing);
    });

    testWidgets('Ask Kapy, left of New note in the list, opens the panel', (
      tester,
    ) async {
      notes.create(body: 'Trip budget');
      await _pump(tester, sidebar: true);

      expect(_ask, findsOneWidget);
      final newNote = find.byKey(const ValueKey('sidebar-new-note'));
      expect(tester.getRect(_ask).right, tester.getRect(newNote).left);
      expect(
        tester.getCenter(_ask).dy,
        closeTo(tester.getCenter(newNote).dy, 0.5),
      );
      final tip = tester.widget<Tooltip>(
        find.descendant(of: _ask, matching: find.byType(Tooltip)),
      );
      expect(tip.message, startsWith('Ask Kapy  '));

      await tester.tap(_ask);
      await tester.pumpAndSettle();
      expect(_panel, findsOneWidget);
      expect(find.text('This note · Trip budget'), findsOneWidget);

      // Asking again keeps the panel open, where the page's button would
      // close it.
      await tester.tap(_ask);
      await tester.pumpAndSettle();
      expect(_panel, findsOneWidget);
    });

    testWidgets('Ask Kapy stays in the Notes views, out of Drawings', (
      tester,
    ) async {
      await _pump(tester, sidebar: true);
      expect(_ask, findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('rail-drawings')));
      await tester.pumpAndSettle();
      expect(_ask, findsNothing);

      await tester.tap(find.byKey(const ValueKey('rail-notes')));
      await tester.pumpAndSettle();
      expect(_ask, findsOneWidget);
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

    testWidgets(
      'a click elsewhere in it leaves the panel focused, and Esc then '
      'closes it',
      (tester) async {
        notes.create(body: 'Trip budget');
        await _pump(tester);
        await _toggleWithKeys(tester);
        await tester.tap(find.byKey(const ValueKey('kapy-ai-field')));
        await tester.pumpAndSettle();

        await tester.tap(
          find.descendant(of: _panel, matching: find.text('Kapy AI')).first,
        );
        await tester.pumpAndSettle();

        expect(FocusManager.instance.primaryFocus?.debugLabel, 'kapy-ai-panel');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(_panel, findsNothing);
      },
      variant: TargetPlatformVariant.desktop(),
    );

    testWidgets(
      'a press in its focused field leaves the field focused throughout',
      (tester) async {
        notes.create(body: 'Trip budget');
        await _pump(tester);
        await _toggleWithKeys(tester);
        final field = find.byKey(const ValueKey('kapy-ai-field'));
        await tester.tap(field);
        await tester.pumpAndSettle();

        final press = await tester.startGesture(tester.getCenter(field));
        await tester.pump();
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'kapy-ai-composer',
        );
        await press.up();
        await tester.pumpAndSettle();
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'kapy-ai-composer',
        );
      },
      variant: TargetPlatformVariant.desktop(),
    );

    testWidgets('Esc closes it from the field and from anywhere in it, but '
        'not while an input method is composing', (tester) async {
      notes.create(body: 'Trip budget');
      await _pump(tester);
      final field = find.byKey(const ValueKey('kapy-ai-field'));

      await _toggleWithKeys(tester);
      await tester.tap(field);
      await tester.enterText(field, 'What did I budget?');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(_panel, findsNothing, reason: 'Esc in the field');

      await tester.tap(_button);
      await tester.pumpAndSettle();
      expect(_panel, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(_panel, findsNothing, reason: 'Esc after opening it with a click');

      await tester.tap(_button);
      await tester.pumpAndSettle();
      // Back to the note, then a click on the panel's header, which takes no
      // focus of its own.
      await tester.tap(find.byType(NoteField));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: _panel, matching: find.text('Kapy AI')).first,
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(_panel, findsNothing, reason: 'Esc after a click on the header');

      await _toggleWithKeys(tester);
      await tester.tap(field);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'にほ',
          selection: TextSelection.collapsed(offset: 2),
          composing: TextRange(start: 0, end: 2),
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(_panel, findsOneWidget, reason: 'Esc ends the composing first');
    });

    testWidgets('on a tablet, a tap in it leaves the keyboard up', (
      tester,
    ) async {
      notes.create(body: 'Trip budget');
      await _pump(
        tester,
        size: const Size(1366, 1024),
        platform: TargetPlatform.iOS,
      );
      await tester.tap(_button);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(NoteField));
      await tester.pumpAndSettle();
      tester.testTextInput.log.clear();

      await tester.tap(
        find.descendant(of: _panel, matching: find.text('Kapy AI')).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('kapy-ai-field')));
      await tester.pumpAndSettle();

      expect([
        for (final call in tester.testTextInput.log) call.method,
      ], isNot(contains('TextInput.hide')));
    });

    for (final platform in [TargetPlatform.linux, TargetPlatform.macOS]) {
      for (final sidebar in [false, true]) {
        testWidgets('over a narrow page it fits, down to the smallest window '
            '(${platform.name}, ${sidebar ? 'with' : 'no'} notes list)', (
          tester,
        ) async {
          notes.create(body: 'Trip budget');
          for (final width in [1100.0, 800.0, 640.0, 520.0, 400.0]) {
            await _pump(
              tester,
              size: Size(width, 700),
              platform: platform,
              sidebar: sidebar,
            );
            if (_panel.evaluate().isEmpty) await _toggleWithKeys(tester);
            expect(_panel, findsOneWidget, reason: 'open at $width');
            expect(tester.takeException(), isNull, reason: 'at $width');
            final panel = tester.getRect(_panel);
            final dock = tester.getRect(find.byType(KapyAiDock));
            expect(
              panel.left >= dock.left && panel.right <= dock.right,
              isTrue,
              reason: 'the panel $panel inside $dock at $width',
            );
            expect(panel.left, greaterThanOrEqualTo(0), reason: 'at $width');
          }
        });
      }
    }

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

    final notice = find.byKey(const ValueKey('toast-surface'));

    testWidgets('a notice centres on the page between the notes list and the '
        'panel beside it', (tester) async {
      notes.create(body: 'Trip budget');
      await _pump(tester, sidebar: true);
      await tester.tap(_button);
      await tester.pumpAndSettle();
      Toast.show(tester.element(_panel), 'Copied');
      await tester.pumpAndSettle();

      expect(
        tester.getCenter(notice).dx,
        tester.getCenter(find.byType(PagePane)).dx,
      );
      expect(
        tester.getRect(notice).right,
        lessThan(tester.getRect(_panel).left),
      );
    });

    testWidgets('a notice keeps left of the panel over a narrow page', (
      tester,
    ) async {
      notes.create(body: 'Trip budget');
      await _pump(tester, size: const Size(1100, 760));
      await tester.tap(_button);
      await tester.pumpAndSettle();
      Toast.show(tester.element(_panel), 'Copied');
      await tester.pumpAndSettle();

      final overlay = tester.getRect(
        find.byKey(const ValueKey('kapy-ai-overlay')),
      );
      expect(tester.getCenter(notice).dx, overlay.left / 2);
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

    testWidgets('turned off in Settings, the button and ⌘J do nothing', (
      tester,
    ) async {
      notes.create(body: 'Trip budget');
      ai.enabled = false;
      await _pump(tester);

      expect(_button, findsNothing);
      expect(_ask, findsNothing);
      await _toggleWithKeys(tester);
      expect(_panel, findsNothing);
    });

    testWidgets('a build without Kapy AI shows nothing of it', (tester) async {
      kapyAiAvailable = false;
      notes.create(body: 'Trip budget');
      await _pump(tester);

      expect(_button, findsNothing);
      expect(_ask, findsNothing);
      await _toggleWithKeys(tester);
      expect(_panel, findsNothing);
    });
  });

  group('the panel’s header follows where it sits', () {
    final chats = find.byKey(const ValueKey('kapy-ai-chats'));
    final sheet = find.byKey(const ValueKey('kapy-ai-sheet'));
    Finder header() =>
        find.ancestor(of: chats, matching: find.byType(SizedBox)).first;
    TextStyle? titleStyle(WidgetTester tester) => tester
        .widget<Text>(
          find.descendant(
            of: find.ancestor(of: chats, matching: find.byType(Row)).first,
            matching: find.text('Kapy AI'),
          ),
        )
        .style;
    KapyIconData icon(WidgetTester tester) => tester
        .widget<KapyIcon>(
          find.descendant(of: chats, matching: find.byType(KapyIcon)),
        )
        .icon;
    Border? hairline(WidgetTester tester) {
      final box = tester.widget<DecoratedBox>(
        find
            .descendant(of: header(), matching: find.byType(DecoratedBox))
            .first,
      );
      return (box.decoration as BoxDecoration).border as Border?;
    }

    for (final (platform, size) in [
      (TargetPlatform.macOS, const Size(1500, 800)),
      (TargetPlatform.iOS, const Size(744, 1133)),
      (TargetPlatform.iOS, const Size(1366, 1024)),
      (TargetPlatform.android, const Size(1280, 800)),
    ]) {
      final name =
          '${platform.name} at ${size.width.toInt()}×${size.height.toInt()}';
      testWidgets('docked on $name, it is D10’s', (tester) async {
        notes.create(body: 'Trip budget\n900 flights\n600 hotel');
        await _pump(tester, size: size, platform: platform);
        await tester.tap(_button);
        await tester.pumpAndSettle();

        expect(_panel, findsOneWidget);
        expect(sheet, findsNothing);
        final style = titleStyle(tester);
        expect(style?.fontFamily, 'Figtree');
        expect(style?.fontSize, 13);
        expect(
          icon(tester).paths,
          same(HugeIcons.strokeRoundedTransactionHistory),
        );
        expect(
          hairline(tester),
          Border(
            bottom: BorderSide(color: tester.element(chats).palette.separator),
          ),
        );
        expect(tester.getSize(header()).height, 52);
      });
    }

    testWidgets(
      'on a phone’s sheet pulled up to full height, it is unchanged',
      (tester) async {
        notes.create(body: 'Trip budget\n900 flights\n600 hotel');
        await _pump(
          tester,
          size: const Size(390, 844),
          platform: TargetPlatform.iOS,
        );
        await tester.tap(_button);
        await tester.pumpAndSettle();
        await tester.drag(
          find.byKey(const ValueKey('kapy-ai-grabber')),
          const Offset(0, -500),
        );
        await tester.pumpAndSettle();

        expect(sheet, findsOneWidget);
        final style = titleStyle(tester);
        expect(style?.fontFamily, 'Shantell Sans');
        expect(style?.fontSize, 17);
        expect(icon(tester), same(KapyIcons.scheduleRounded));
        expect(hairline(tester), isNull);
        expect(tester.getSize(header()).height, 56);
      },
    );
  });

  group('a phone’s sheet over the note (M10)', () {
    const question = 'What is left on this note?';
    const answer =
        'One task: send the deck this morning. The pricing page is due Friday.';
    final sheet = find.byKey(const ValueKey('kapy-ai-sheet'));
    final grabber = find.byKey(const ValueKey('kapy-ai-grabber'));
    final field = find.byKey(const ValueKey('kapy-ai-field'));
    final chip = find.byKey(const ValueKey('kapy-ai-chip'));
    final picker = find.byKey(const ValueKey('kapy-ai-model-button'));
    final chats = find.byKey(const ValueKey('kapy-ai-chats'));
    final newChat = find.byKey(const ValueKey('kapy-ai-new-chat'));
    final answerText = find.textContaining(answer, findRichText: true);
    const screen = Size(402, 874);

    Future<String> open(WidgetTester tester) async {
      final note = notes.create(
        body: 'Call with Arjun\n☐ Send the deck this morning\nPricing page',
      );
      ai = FakeKapyAi(pro: true)..set(model: KapyModel.cloud);
      await _pump(tester, size: screen, platform: TargetPlatform.iOS);
      await tester.tap(_button);
      await tester.pumpAndSettle();
      return note.id;
    }

    testWidgets('a half-typed question is still there when the sheet opens '
        'again after Back', (tester) async {
      await open(tester);
      await tester.enterText(field, 'What did Arjun');
      await tester.pump();

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(sheet, findsNothing);

      await tester.tap(_button);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<EditableText>(
              find.descendant(of: field, matching: find.byType(EditableText)),
            )
            .controller
            .text,
        'What did Arjun',
      );
    });

    Future<void> ask(WidgetTester tester, String noteId) async {
      await tester.enterText(field, question);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('kapy-ai-send')));
      await tester.pumpAndSettle();
      expect(ai.calls.last, 'ask:$question:$noteId');
      final asked = KapyMessage(
        id: 'q',
        role: KapyRole.user,
        text: question,
        at: DateTime(2026, 11, 17, 16, 41),
      );
      KapyChat chat(List<KapyMessage> messages) => KapyChat(
        id: 'm10',
        title: question,
        createdAt: asked.at,
        updatedAt: asked.at,
        model: KapyModel.cloud,
        messages: messages,
      );
      ai.set(current: chat([asked]));
      await tester.pumpAndSettle();
      expect(find.text('Reading your notes…'), findsOneWidget);
      ai.set(
        current: chat([
          asked,
          KapyMessage(
            id: 'a',
            role: KapyRole.assistant,
            text: answer,
            at: asked.at,
            model: KapyModel.cloud,
          ),
        ]),
        answering: false,
      );
      await tester.pumpAndSettle();
    }

    double sheetTop(WidgetTester tester) => tester.getRect(sheet).top;

    testWidgets('from the note’s button it rests over the note, compact', (
      tester,
    ) async {
      await open(tester);

      expect(_panel, findsOneWidget);
      expect(
        sheetTop(tester),
        moreOrLessEquals(screen.height * 0.423, epsilon: 1),
      );
      expect(grabber, findsOneWidget);
      expect(find.text('Kapy AI'), findsOneWidget);
      expect(find.text('Close'), findsOneWidget);
      expect(find.text('About Call with Arjun'), findsOneWidget);
      expect(find.text('Ask about this note'), findsOneWidget);
      for (final gone in [chip, picker, chats, newChat]) {
        expect(gone, findsNothing);
      }
      expect(
        tester
            .widget<CompactIconButton>(
              find.descendant(
                of: _button,
                matching: find.byType(CompactIconButton),
              ),
            )
            .selected,
        isFalse,
        reason: 'M10 keeps Kapy AI a bare icon while its sheet is up',
      );
      for (final above in [
        find.byKey(const ValueKey('page-home')),
        _button,
        find.byType(NoteField),
      ]) {
        expect(
          tester.getRect(above).top,
          lessThan(sheetTop(tester)),
          reason: '$above stays in view above the sheet',
        );
      }
      expect(
        tester.testTextInput.isVisible,
        isFalse,
        reason: 'the keyboard waits for a tap, so the note stays in view',
      );
    });

    testWidgets('asking about the note shows the question and the answer', (
      tester,
    ) async {
      final id = await open(tester);
      await ask(tester, id);

      expect(find.text(question), findsOneWidget);
      expect(answerText, findsOneWidget);
      expect(find.text('Reading your notes…'), findsNothing);
      expect(
        tester.getRect(answerText).bottom,
        lessThanOrEqualTo(tester.getRect(field).top),
      );
      expect(find.byKey(const ValueKey('kapy-ai-copy')), findsNothing);
    });

    testWidgets('pulled up, it is the full panel with the same chat', (
      tester,
    ) async {
      final id = await open(tester);
      await ask(tester, id);
      await tester.enterText(field, 'And the pricing page?');
      await tester.pump();

      await tester.drag(grabber, const Offset(0, -500));
      await tester.pumpAndSettle();

      expect(sheetTop(tester), moreOrLessEquals(0, epsilon: 1));
      for (final shown in [chats, newChat, picker]) {
        expect(shown, findsOneWidget);
      }
      expect(find.text('This note · Call with Arjun'), findsOneWidget);
      expect(find.text('About Call with Arjun'), findsNothing);
      expect(find.text(question), findsOneWidget);
      expect(answerText, findsOneWidget);
      expect(find.byKey(const ValueKey('kapy-ai-copy')), findsOneWidget);
      expect(
        tester.widget<TextField>(field).controller!.text,
        'And the pricing page?',
        reason: 'what was typed in the compact sheet is still there',
      );
    });

    testWidgets('pulled down past its rest, it goes', (tester) async {
      await open(tester);
      await tester.drag(grabber, const Offset(0, 400));
      await tester.pumpAndSettle();
      expect(_panel, findsNothing);
    });

    testWidgets('Close and the scrim each put it away', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('kapy-ai-close')));
      await tester.pumpAndSettle();
      expect(_panel, findsNothing);

      await tester.tap(_button);
      await tester.pumpAndSettle();
      expect(_panel, findsOneWidget);
      await tester.tapAt(const Offset(200, 60));
      await tester.pumpAndSettle();
      expect(_panel, findsNothing);
    });

    testWidgets('Pick another with the keyboard up opens the full panel '
        'with the picker', (tester) async {
      final id = await open(tester);
      await tester.tap(field);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      await tester.enterText(field, question);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('kapy-ai-send')));
      await tester.pumpAndSettle();
      expect(ai.calls.last, 'ask:$question:$id');
      ai.set(
        current: KapyChat(
          id: 'm10',
          title: question,
          createdAt: DateTime(2026, 11, 17, 16, 41),
          updatedAt: DateTime(2026, 11, 17, 16, 41),
          model: KapyModel.cloud,
          messages: [
            KapyMessage(
              id: 'q',
              role: KapyRole.user,
              text: question,
              at: DateTime(2026, 11, 17, 16, 41),
            ),
          ],
        ),
        pending: const KapyAccountConsent(KapyAccountKind.codex),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Pick another'));
      await tester.pumpAndSettle();

      expect(sheetTop(tester), moreOrLessEquals(0, epsilon: 1));
      expect(chats, findsOneWidget);
      expect(find.byKey(const ValueKey('kapy-ai-picker')), findsOneWidget);
    });

    testWidgets('from Quick find’s Ask row it opens at full height', (
      tester,
    ) async {
      notes.create(body: 'Call with Arjun');
      ai = FakeKapyAi(pro: true)..set(model: KapyModel.cloud);
      await _pump(tester, size: screen, platform: TargetPlatform.iOS);
      final back = find.byKey(const ValueKey('page-home'));
      if (back.evaluate().isNotEmpty) {
        await tester.tap(back);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const ValueKey('sidebar-search-field')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('command-menu-field')),
        'sintra',
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('command-menu-row-Ask Kapy AI: sintra')),
      );
      await tester.pumpAndSettle();

      expect(ai.calls, hasLength(2));
      expect(ai.calls.first, 'newChat');
      expect(ai.calls.last, startsWith('ask:sintra:'));
      expect(sheetTop(tester), moreOrLessEquals(0, epsilon: 1));
      expect(chats, findsOneWidget);
      expect(find.text('Ask about this note'), findsNothing);
    });

    double restTop(double keyboard) =>
        (screen.height - keyboard) * (1 - kapyAiSheetRest);

    Future<void> keyboardAt(WidgetTester tester, double inset) async {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await tester.pumpAndSettle();
    }

    void composerAbove(WidgetTester tester, double inset) {
      final bottom = tester.getRect(field).bottom;
      expect(
        bottom <= screen.height - inset && bottom >= screen.height - inset - 80,
        isTrue,
        reason: 'the field ends at $bottom, just above a $inset keyboard',
      );
    }

    Future<void> heldDrag(WidgetTester tester, double dy) async {
      final hold = await tester.startGesture(tester.getCenter(grabber));
      for (var step = 0; step < 10; step++) {
        await hold.moveBy(Offset(0, dy / 10));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump(const Duration(milliseconds: 300));
      await hold.up();
      await tester.pumpAndSettle();
    }

    void atRest(WidgetTester tester, double inset) {
      expect(sheetTop(tester), moreOrLessEquals(restTop(inset), epsilon: 1));
      expect(find.text('About Call with Arjun'), findsOneWidget);
      expect(chats, findsNothing);
    }

    testWidgets('the keyboard keeps the field just above it, and going down '
        'in one frame or in steps leaves the sheet at rest', (tester) async {
      await open(tester);
      await tester.tap(field);
      await keyboardAt(tester, 300);
      composerAbove(tester, 300);
      atRest(tester, 300);

      tester.view.resetViewInsets();
      await tester.pump();
      atRest(tester, 0);

      await keyboardAt(tester, 300);
      for (final inset in [240.0, 180.0, 120.0, 60.0, 0.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pump();
        composerAbove(tester, inset);
      }
      await tester.pumpAndSettle();
      atRest(tester, 0);
    });

    testWidgets('slow, short drags settle back at rest, keyboard up or down', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(field);
      await keyboardAt(tester, 300);
      for (final dy in [30.0, 60.0, 100.0]) {
        await heldDrag(tester, dy);
        atRest(tester, 300);
        composerAbove(tester, 300);
      }
      await keyboardAt(tester, 0);
      for (final dy in [-150.0, 150.0]) {
        await heldDrag(tester, dy);
        atRest(tester, 0);
      }
    });

    testWidgets('dragged to full or back to rest with the keyboard up, it '
        'stays there when the keyboard goes down', (tester) async {
      await open(tester);
      await tester.tap(field);
      await keyboardAt(tester, 300);
      await heldDrag(tester, -300);
      expect(sheetTop(tester), moreOrLessEquals(0, epsilon: 1));
      expect(chats, findsOneWidget);
      composerAbove(tester, 300);
      await keyboardAt(tester, 0);
      expect(sheetTop(tester), moreOrLessEquals(0, epsilon: 1));
      expect(chats, findsOneWidget);

      await tester.tap(field);
      await keyboardAt(tester, 300);
      await heldDrag(tester, 230);
      atRest(tester, 300);
      await keyboardAt(tester, 0);
      atRest(tester, 0);
    });

    testWidgets('the field tapped again while the keyboard is going down '
        'sits above it when it comes back up', (tester) async {
      await open(tester);
      await tester.tap(field);
      await keyboardAt(tester, 300);
      await heldDrag(tester, 150);
      tester.view.viewInsets = const FakeViewPadding(bottom: 150);
      await tester.pump();
      await tester.tap(field);
      await keyboardAt(tester, 300);
      composerAbove(tester, 300);
      atRest(tester, 300);
    });

    testWidgets('at 2× text a tall keyboard in one frame overflows nothing, '
        'and the chat scrolls in the sheet', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final id = await open(tester);
      await ask(tester, id);
      await tester.tap(field);
      tester.view.viewInsets = const FakeViewPadding(bottom: 360);
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      composerAbove(tester, 360);
      expect(sheetTop(tester), moreOrLessEquals(restTop(360), epsilon: 1));
      final chat = tester.state<ScrollableState>(
        find
            .ancestor(
              of: find.text(question),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(chat.position.maxScrollExtent, greaterThan(0));
    });

    testWidgets('the field takes no keyboard at any frame of the entrance', (
      tester,
    ) async {
      notes.create(body: 'Call with Arjun');
      ai = FakeKapyAi(pro: true)..set(model: KapyModel.cloud);
      await _pump(tester, size: screen, platform: TargetPlatform.iOS);
      await tester.tap(_button);
      for (var frame = 0; frame < 40; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          tester.testTextInput.hasAnyClients,
          isFalse,
          reason: 'frame $frame',
        );
      }
      await tester.pumpAndSettle();
      expect(tester.testTextInput.hasAnyClients, isFalse);
    });

    testWidgets('scrolling the chat with the keyboard up puts the keyboard '
        'away and leaves the sheet at rest', (tester) async {
      final id = await open(tester);
      await ask(tester, id);
      await tester.tap(field);
      await keyboardAt(tester, 300);
      await tester.drag(find.text(question), const Offset(0, 120));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isFalse);
      expect(tester.testTextInput.hasAnyClients, isFalse);
      atRest(tester, 300);
      await keyboardAt(tester, 0);
      atRest(tester, 0);
    });
  });

  group('in ⌘K', () {
    Finder sidebarField(String words) => find.descendant(
      of: find.byKey(const ValueKey('sidebar-search-field')),
      matching: find.text(words),
    );
    final menuField = find.byKey(const ValueKey('command-menu-field'));
    final menu = find.byKey(const ValueKey('command-menu'));
    final askRow = find.byKey(
      const ValueKey('command-menu-row-Ask Kapy AI: sintra'),
    );

    Future<String> openMenuOverNote(WidgetTester tester) async {
      final note = notes.create(body: 'Trip budget\n900 flights');
      await _pump(tester, sidebar: true);
      await _chord(tester, LogicalKeyboardKey.keyK);
      expect(menu, findsOneWidget);
      return note.id;
    }

    Future<void> type(WidgetTester tester, String words) async {
      await tester.enterText(menuField, words);
      await tester.pumpAndSettle();
    }

    testWidgets('Drawings\' field says Search drawings, even with Kapy AI on', (
      tester,
    ) async {
      await _pump(tester, sidebar: true);
      await tester.tap(find.byKey(const ValueKey('rail-drawings')));
      await tester.pumpAndSettle();
      expect(sidebarField('Search drawings'), findsOneWidget);
      expect(sidebarField('Search or Ask Kapy AI'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('rail-notes')));
      await tester.pumpAndSettle();
      expect(sidebarField('Search'), findsOneWidget);
    });

    final noteRow = find.byKey(const ValueKey('command-menu-row-Sintra trip'));
    final drawingRow = find.byKey(
      const ValueKey('command-menu-row-Sintra map'),
    );

    void tripAndMap() {
      final drawing = notes.create(drawing: true);
      notes.updateDrawing(drawing.id, NoteDrawing.empty, title: 'Sintra map');
      notes.create(body: 'Sintra trip\nTrain at nine');
    }

    Future<void> searchFromField(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('sidebar-search-field')));
      await tester.pumpAndSettle();
      expect(menu, findsOneWidget);
    }

    void findsEverything() {
      expect(noteRow, findsOneWidget);
      expect(drawingRow, findsOneWidget);
      expect(askRow, findsOneWidget);
    }

    void findsDrawingsAlone() {
      expect(drawingRow, findsOneWidget);
      expect(noteRow, findsNothing);
      expect(askRow, findsNothing);
    }

    testWidgets('Drawings\' field searches drawings alone, where Notes\' '
        'searches everything', (tester) async {
      tripAndMap();
      await _pump(tester, sidebar: true);
      await tester.tap(find.byKey(const ValueKey('rail-drawings')));
      await tester.pumpAndSettle();
      await searchFromField(tester);
      expect(find.text('Search or Ask Kapy AI…'), findsNothing);
      expect(find.text('Search drawings…'), findsOneWidget);
      await type(tester, 'sintra');
      findsDrawingsAlone();
      expect(
        find.descendant(of: menu, matching: find.text('Ask Kapy AI')),
        findsNothing,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(ai.calls.where((call) => call.startsWith('ask:')), isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('rail-notes')));
      await tester.pumpAndSettle();
      await searchFromField(tester);
      await type(tester, 'sintra');
      findsEverything();
    });

    testWidgets('on a phone, Drawings\' field opens on the Drawings pill, '
        'where Notes\' opens on All', (tester) async {
      tripAndMap();
      await _pump(
        tester,
        size: const Size(402, 874),
        platform: TargetPlatform.iOS,
      );
      final back = find.byKey(const ValueKey('page-home'));
      if (back.evaluate().isNotEmpty) {
        await tester.tap(back);
        await tester.pumpAndSettle();
      }
      await searchFromField(tester);
      await type(tester, 'sintra');
      findsEverything();
      await tester.tap(find.byKey(const ValueKey('command-menu-cancel')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('bar-folders')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('folders-drawings-tile')));
      await tester.pumpAndSettle();
      await searchFromField(tester);
      expect(
        find.descendant(of: menu, matching: find.text('Search drawings')),
        findsOneWidget,
      );
      await type(tester, 'sintra');
      findsDrawingsAlone();
      expect(
        find.byKey(const ValueKey('command-menu-row-New drawing')),
        findsOneWidget,
      );
      expect(
        tester.getSemantics(
          find.byKey(const ValueKey('command-scope-drawings')),
        ),
        isSemantics(isSelected: true),
      );
    });

    testWidgets('⌘K offers to ask, the list’s field reads as D01 draws it, '
        'and Tab asks with the note’s chip', (tester) async {
      final id = await openMenuOverNote(tester);
      expect(sidebarField('Search'), findsOneWidget);
      expect(sidebarField('Search or Ask Kapy AI'), findsNothing);
      expect(find.text('Search or Ask Kapy AI…'), findsOneWidget);

      await type(tester, 'sintra');
      expect(askRow, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();

      expect(menu, findsNothing);
      expect(_panel, findsOneWidget);
      expect(ai.calls, ['newChat', 'ask:sintra:$id']);
      expect(find.text('This note · Trip budget'), findsOneWidget);
    });

    testWidgets('Return on the Ask row asks the same way', (tester) async {
      final id = await openMenuOverNote(tester);

      await type(tester, 'sintra');
      for (var step = 0; step < 3; step++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      }
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(_panel, findsOneWidget);
      expect(ai.calls, ['newChat', 'ask:sintra:$id']);
    });

    testWidgets('asked while Kapy AI is answering, the question waits in the '
        'composer', (tester) async {
      await openMenuOverNote(tester);
      ai.set(answering: true);

      await type(tester, 'sintra');
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();

      expect(_panel, findsOneWidget);
      expect(ai.calls, isNot(contains('newChat')));
      expect(ai.calls.where((call) => call.startsWith('ask:')), isEmpty);
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('kapy-ai-field')),
      );
      expect(field.controller!.text, 'sintra');
      expect(find.text('Kapy AI is still answering'), findsOneWidget);

      ai.set(answering: false);
      await tester.pumpAndSettle();
      expect(find.text('Kapy AI is still answering'), findsNothing);
      expect(
        ai.calls.where((call) => call.startsWith('ask:')),
        isEmpty,
        reason: 'it never sends by itself',
      );
      await tester.tap(find.byKey(const ValueKey('kapy-ai-send')));
      await tester.pumpAndSettle();
      expect(ai.calls.last, startsWith('ask:sintra:'));
    });

    testWidgets('a question asked while answering goes after what is typed', (
      tester,
    ) async {
      await openMenuOverNote(tester);
      ai.set(answering: true);
      await type(tester, 'sintra');
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();

      final composer = find.byKey(const ValueKey('kapy-ai-field'));
      await tester.enterText(composer, 'my own words');
      await tester.pumpAndSettle();
      await _chord(tester, LogicalKeyboardKey.keyK);
      expect(menu, findsOneWidget);
      await type(tester, 'lisbon');
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(composer).controller!;
      expect(field.text, 'my own words\nlisbon');
      expect(
        field.selection,
        TextSelection.collapsed(offset: field.text.length),
      );
      expect(ai.calls.where((call) => call.startsWith('ask:')), isEmpty);
    });

    testWidgets('the row asks with a click', (tester) async {
      final id = await openMenuOverNote(tester);

      await type(tester, 'sintra');
      await tester.tap(askRow);
      await tester.pumpAndSettle();

      expect(ai.calls, ['newChat', 'ask:sintra:$id']);
    });

    testWidgets('Search, Create and Go to still work with the limit reached', (
      tester,
    ) async {
      ai = FakeKapyAi(pro: true)
        ..set(
          cloudUsage: CloudUsage(
            remaining: 0,
            limit: 500,
            resetsAt: DateTime(2026, 12),
          ),
          pending: KapyLimitReached(resetsAt: DateTime(2026, 12)),
        );
      await openMenuOverNote(tester);

      await type(tester, 'sintra');
      expect(
        find.byKey(const ValueKey('command-menu-row-New note: sintra')),
        findsOneWidget,
      );
      expect(askRow, findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('command-menu-row-New note: sintra')),
      );
      await tester.pumpAndSettle();
      expect(menu, findsNothing);
      expect(ai.calls, isEmpty);
    });

    testWidgets('turned off in Settings, it is only Search', (tester) async {
      ai.enabled = false;
      await openMenuOverNote(tester);
      expect(sidebarField('Search'), findsOneWidget);
      expect(sidebarField('Search or Ask Kapy AI'), findsNothing);
      expect(find.text('Search…'), findsOneWidget);

      await type(tester, 'sintra');
      expect(askRow, findsNothing);
      expect(find.text('Ask Kapy AI'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(ai.calls, ['enabled:false']);
      expect(_panel, findsNothing);
    });

    testWidgets('the list’s field reads the same as the switch flips, and '
        '⌘K follows it', (tester) async {
      notes.create(body: 'Trip budget');
      await _pump(tester, sidebar: true);
      expect(sidebarField('Search'), findsOneWidget);

      ai.enabled = false;
      await tester.pumpAndSettle();
      expect(sidebarField('Search'), findsOneWidget);
      await _chord(tester, LogicalKeyboardKey.keyK);
      expect(find.text('Search…'), findsOneWidget);
      expect(find.text('Search or Ask Kapy AI…'), findsNothing);
    });

    testWidgets('in a build without Kapy AI, ⌘K is exactly as it was', (
      tester,
    ) async {
      kapyAiAvailable = false;
      await openMenuOverNote(tester);
      expect(sidebarField('Search'), findsOneWidget);
      expect(find.text('Search…'), findsOneWidget);

      await type(tester, 'sintra');
      expect(askRow, findsNothing);
      expect(find.text('Ask Kapy AI'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(ai.calls, isEmpty);
      expect(_panel, findsNothing);
    });
  });

  group('in Settings', () {
    final searchField = find.byKey(const ValueKey('settings-search'));
    final searchRow = find.byKey(
      const ValueKey('settings-search-result-shortcut-row-findNotes'),
    );

    testWidgets('the Search shortcut says Ask Kapy AI while it is on', (
      tester,
    ) async {
      await _openSettings(
        tester,
        kapyAi: ai,
        section: SettingsSection.shortcuts,
      );
      expect(find.text('Search or Ask Kapy AI'), findsOneWidget);
      expect(find.text('Search'), findsNothing);

      await tester.enterText(searchField, 'ask kapy');
      await tester.pumpAndSettle();
      expect(searchRow, findsOneWidget);
    });

    testWidgets('the Search shortcut is plain Search with the switch off', (
      tester,
    ) async {
      ai.enabled = false;
      await _openSettings(
        tester,
        kapyAi: ai,
        section: SettingsSection.shortcuts,
      );
      expect(find.text('Search'), findsOneWidget);
      expect(find.text('Search or Ask Kapy AI'), findsNothing);

      await tester.enterText(searchField, 'ask kapy');
      await tester.pumpAndSettle();
      expect(searchRow, findsNothing);

      await tester.enterText(searchField, 'search');
      await tester.pumpAndSettle();
      expect(searchRow, findsOneWidget);
    });

    testWidgets('the Search shortcut follows the switch as it is flipped', (
      tester,
    ) async {
      await _openSettings(tester, kapyAi: ai, section: SettingsSection.voice);
      ai.enabled = false;
      await tester.pumpAndSettle();
      await tester.tap(find.text('Shortcuts'));
      await tester.pumpAndSettle();
      expect(find.text('Search or Ask Kapy AI'), findsNothing);
      expect(find.text('Search'), findsOneWidget);
    });

    testWidgets('the Search shortcut is plain Search without Kapy AI', (
      tester,
    ) async {
      kapyAiAvailable = false;
      await _openSettings(
        tester,
        kapyAi: ai,
        section: SettingsSection.shortcuts,
      );
      expect(find.text('Search'), findsOneWidget);
      expect(find.text('Search or Ask Kapy AI'), findsNothing);
    });
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
            models: [FakeKapyAi.gpt],
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
      expect(find.text('Found on this Mac'), findsNWidgets(2));
      expect(find.text('Key ending 4f2a, kept on this Mac'), findsOneWidget);
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
        find.text(
          'Not found on this Mac. Install it, sign in, then check again',
        ),
        findsNWidgets(2),
      );
      expect(
        find.text(
          'Get a key, then add it here, for answers from a plan you pay for',
        ),
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

    testWidgets(
      'Get a key opens the page that makes one, or says it could not',
      (tester) async {
        ai = FakeKapyAi(
          accountList: const [
            KapyAccountState(
              kind: KapyAccountKind.openRouter,
              status: KapyAccountStatus.notConnected,
            ),
          ],
        );
        final launched = <String>[];
        var opens = true;
        const channel = MethodChannel('plugins.flutter.io/url_launcher');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            final url = (call.arguments as Map?)?['url'];
            if (url is String) launched.add(url);
            return opens;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        await _openSettings(
          tester,
          kapyAi: ai,
          reveal: 'kapy-account-openRouter',
        );

        expect(
          find.text(
            'Get a key, then add it here, for answers from a plan you pay for',
          ),
          findsOneWidget,
        );
        expect(find.text('Add key'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('kapy-openrouter-get-key')));
        await tester.pump();
        expect(launched, ['https://openrouter.ai/keys']);
        expect(find.text('Could not open the page for a key'), findsNothing);

        opens = false;
        await tester.tap(find.byKey(const ValueKey('kapy-openrouter-get-key')));
        await tester.pump();
        expect(launched, hasLength(2));
        expect(find.text('Could not open the page for a key'), findsOneWidget);
        await tester.pump(const Duration(seconds: 10));
      },
    );

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
        find.text('Signed out. Sign in there, then check again'),
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
      expect(find.text('This key was rejected'), findsOneWidget);
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

      expect(find.byKey(const ValueKey('day-strip-forward')), findsNothing);
      expect(
        find.byKey(const ValueKey('day-strip-date')),
        findsOneWidget,
        reason: 'the day keeps its one button beside the panel',
      );
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
            models: [FakeKapyAi.gpt],
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

  group("a phone's Kapy AI tab", () {
    final tab = find.byKey(const ValueKey('bar-kapyAi'));
    final page = find.byKey(const ValueKey('kapy-ai-page'));
    final home = find.byKey(const ValueKey('home-title-notes'));

    Future<void> pumpPhone(WidgetTester tester, {FolderStore? folders}) async {
      await _pump(
        tester,
        size: const Size(390, 844),
        platform: TargetPlatform.iOS,
        folders: folders,
      );
      final back = find.byKey(const ValueKey('page-home'));
      if (back.evaluate().isNotEmpty) {
        await tester.tap(back);
        await tester.pumpAndSettle();
      }
    }

    Future<void> tap(WidgetTester tester, Finder finder) async {
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    testWidgets("Back closes the model picker first, then goes Home", (
      tester,
    ) async {
      await pumpPhone(tester);
      await tap(tester, tab);
      await tap(tester, find.byType(KapyAiModelButton));
      final picker = find.byType(KapyAiPicker);
      expect(picker, findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(picker, findsNothing);
      expect(page, findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(page, findsNothing);
      expect(home, findsOneWidget);
    });

    testWidgets('with the model picker open, another tab takes it away, and '
        "Back then does that tab's step", (tester) async {
      await pumpPhone(tester);
      await tap(tester, tab);
      await tap(tester, find.byType(KapyAiModelButton));
      expect(find.byType(KapyAiPicker), findsOneWidget);

      await tap(tester, find.byKey(const ValueKey('bar-folders')));
      expect(page, findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(home, findsOneWidget);
      expect(
        tester.widget<PhoneSpaces>(find.byType(PhoneSpaces)).tab,
        PhoneTab.notes,
      );
    });

    for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
      testWidgets('on ${platform.name}, its page, its picker and the sheet '
          'over a note name no desktop keys or clicks (KAP-115)', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        final keys = RegExp(
          r'Ctrl|Cmd|Alt ?\+|Option ?\+|Shift ?\+|[⌘⌥⌃⇧↵]|\besc\b|[Cc]lick',
        );
        void expectNoKeys(String where) {
          final shown = [
            for (final tip in tester.widgetList<Tooltip>(find.byType(Tooltip)))
              tip.message ?? '',
            for (final text in tester.widgetList<Text>(find.byType(Text)))
              text.data ?? text.textSpan?.toPlainText() ?? '',
          ];
          expect(shown.where(keys.hasMatch), isEmpty, reason: where);
          expect(
            find.semantics.byPredicate(
              (node) =>
                  keys.hasMatch(node.label) ||
                  keys.hasMatch(node.tooltip) ||
                  keys.hasMatch(node.hint),
            ),
            findsNothing,
            reason: where,
          );
        }

        notes.create(body: 'Call with Arjun\nPricing page');
        await _pump(tester, size: const Size(390, 844), platform: platform);
        await tester.tap(_button);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('kapy-ai-sheet')), findsOneWidget);
        expectNoKeys('the sheet');
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();

        final back = find.byKey(const ValueKey('page-home'));
        if (back.evaluate().isNotEmpty) await tap(tester, back);
        await tap(tester, tab);
        expect(page, findsOneWidget);
        expectNoKeys('the page');
        await tap(tester, find.byType(KapyAiModelButton));
        expect(find.byType(KapyAiPicker), findsOneWidget);
        expectNoKeys('the picker');
        semantics.dispose();
      });
    }

    testWidgets("mounts Kapy AI's page clear of the bar, lit in it; Notes and "
        'Back both go Home', (tester) async {
      await pumpPhone(tester);
      expect(page, findsNothing);

      await tap(tester, tab);
      expect(page, findsOneWidget);
      expect(home, findsNothing);
      expect(
        tester.widget<PhoneSpaces>(find.byType(PhoneSpaces)).tab,
        PhoneTab.kapyAi,
      );
      final field = find.byKey(const ValueKey('kapy-ai-page-field'));
      expect(
        tester.getRect(find.byKey(const ValueKey('phone-bar'))).top -
            tester
                .getRect(
                  find
                      .ancestor(of: field, matching: find.byType(Container))
                      .first,
                )
                .bottom,
        12,
      );

      await tap(tester, find.byKey(const ValueKey('bar-notes')));
      expect(page, findsNothing);
      expect(home, findsOneWidget);

      await tap(tester, tab);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(page, findsNothing);
      expect(home, findsOneWidget);
    });

    testWidgets("on Android over three buttons, its composer ends above the "
        'pill', (tester) async {
      tester.view.viewPadding = const FakeViewPadding(bottom: 48);
      tester.view.padding = const FakeViewPadding(bottom: 48);
      await _pump(
        tester,
        size: const Size(412, 915),
        platform: TargetPlatform.android,
      );
      final back = find.byKey(const ValueKey('page-home'));
      if (back.evaluate().isNotEmpty) await tap(tester, back);
      await tap(tester, tab);

      final pill = tester.getRect(find.byKey(const ValueKey('phone-bar')));
      // The send button sits on the composer's last row, at its foot.
      final composer = tester.getRect(
        find.byKey(const ValueKey('kapy-ai-page-send')),
      );
      expect(pill.bottom, lessThanOrEqualTo(915 - 48));
      expect(composer.bottom, lessThanOrEqualTo(pill.top));
    });

    testWidgets('New chat opens the conversation over it', (tester) async {
      await pumpPhone(tester);
      await tap(tester, tab);

      await tap(tester, find.byKey(const ValueKey('kapy-ai-page-new-chat')));
      expect(_panel, findsOneWidget);
    });

    testWidgets("an account's Add row opens Settings at that account", (
      tester,
    ) async {
      ai.accountList = const [
        KapyAccountState(
          kind: KapyAccountKind.openRouter,
          status: KapyAccountStatus.notConnected,
        ),
      ];
      await pumpPhone(tester);
      await tap(tester, tab);

      await tap(tester, find.byKey(const ValueKey('kapy-ai-model-button')));
      // With no account yet, the picker's way to one is its Add row.
      await tap(
        tester,
        find.byKey(const ValueKey('kapy-ai-connect-openRouter')),
      );
      final settings = tester.widget<SettingsDialog>(
        find.byType(SettingsDialog),
      );
      expect(settings.section, SettingsSection.voice);
      expect(settings.reveal, kapyAccountRowId(KapyAccountKind.openRouter));
    });

    testWidgets('S on it opens Settings', (tester) async {
      await pumpPhone(tester);
      await tap(tester, tab);

      final account = find.descendant(
        of: page,
        matching: find.byKey(const ValueKey('phone-account')),
      );
      expect(tester.getSize(account), const Size(44, 44));
      await tap(tester, account);
      expect(find.byType(SettingsDialog), findsOneWidget);
    });

    testWidgets('switched off, the tab goes, and the bar is back on Notes', (
      tester,
    ) async {
      await pumpPhone(tester);
      await tap(tester, tab);
      expect(page, findsOneWidget);

      ai.enabled = false;
      await tester.pumpAndSettle();
      expect(tab, findsNothing);
      expect(page, findsNothing);
      expect(home, findsOneWidget);

      ai.enabled = true;
      await tester.pumpAndSettle();
      expect(tab, findsOneWidget);
      expect(page, findsNothing);
    });

    testWidgets('Back from it lands on Notes with the picks made there kept, '
        'as the bar does', (tester) async {
      notes.create(body: 'Groceries\nOat milk, lemons');
      await pumpPhone(tester);
      await tester.longPress(find.text('Groceries'));
      await tester.pumpAndSettle();
      await tap(tester, find.text('Select'));
      final picked = find.text('1 selected');
      expect(picked, findsOneWidget);

      await tap(tester, tab);
      expect(page, findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(page, findsNothing);
      expect(
        tester.widget<PhoneSpaces>(find.byType(PhoneSpaces)).tab,
        PhoneTab.notes,
      );
      expect(picked, findsOneWidget);
    });

    testWidgets("with Kapy AI on, Folders' and Drawings' fields still name "
        'what they search', (tester) async {
      Finder field(String words) => find.descendant(
        of: find.byKey(const ValueKey('sidebar-search-field')),
        matching: find.text(words),
      );
      await pumpPhone(tester, folders: FolderStore(store));
      expect(field('Search or Ask Kapy AI'), findsOneWidget);

      await tap(tester, find.byKey(const ValueKey('bar-folders')));
      expect(field('Search folders'), findsOneWidget);

      await tap(tester, find.byKey(const ValueKey('folders-drawings-tile')));
      expect(field('Search drawings'), findsOneWidget);
      expect(field('Search or Ask Kapy AI'), findsNothing);
    });

    testWidgets("after a visit to Drawings, + on it makes a note, and Folders "
        'is back on its tree', (tester) async {
      await pumpPhone(tester);
      await tap(tester, find.byKey(const ValueKey('bar-folders')));
      await tap(tester, find.byKey(const ValueKey('folders-drawings-tile')));
      await tap(tester, tab);

      // The blank note the app opens on is the one + reuses, as for a note.
      await tap(tester, find.byKey(const ValueKey('phone-new')));
      expect(page, findsNothing);
      expect(notes.notes.where((note) => note.isDrawing), isEmpty);

      await tap(tester, find.byKey(const ValueKey('page-home')));
      await tap(tester, find.byKey(const ValueKey('bar-folders')));
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('phone-list-title')))
            .data,
        'Folders',
      );
    });

    testWidgets('a build without Kapy AI has no tab for it', (tester) async {
      kapyAiAvailable = false;
      await pumpPhone(tester);
      expect(tab, findsNothing);
      expect(find.byKey(const ValueKey('bar-folders')), findsOneWidget);
    });
  });
}
