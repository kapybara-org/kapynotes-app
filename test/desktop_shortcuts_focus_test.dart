import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note_drawing.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/tags.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/account.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/sync/key_store.dart';
import 'package:kapy_notes/sync/sync_state.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/sidebar.dart';
import 'package:kapy_notes/ui/spaces_rail.dart';
import 'package:material_ui/material_ui.dart';

import 'fake_kapy_ai.dart';
import 'sync/fake_server.dart';
import 'test_fonts.dart';

class _Store extends LocalStore {
  _Store() : super(fileName: 'desktop-shortcuts-focus-test.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
}

/// A control in the window that takes no typing, and how to reach it with
/// the mouse alone: from wherever the last key left the window, into a text
/// field, then the click on the control that takes the keyboard out of it.
typedef _Control = ({
  String name,
  LibrarySpace home,
  Future<void> Function(WidgetTester tester) arrive,
});

/// KAP-373: Go to's keys and Kapy AI's answer wherever the last click left
/// the keyboard, not only while a text field or a list holds it.
void main() {
  late FakeServer server;
  late _Store store;
  late NotesStore notes;
  late TaskLibrary tasks;
  late Account account;
  late LayoutPrefs prefs;
  late ShortcutPrefs shortcuts;
  late FakeKapyAi ai;
  late bool wasAvailable;

  setUpAll(loadTestFonts);

  setUp(() {
    wasAvailable = kapyAiAvailable;
    kapyAiAvailable = true;
    server = FakeServer();
    store = _Store();
    store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
    notes = NotesStore(store, now: () => DateTime(2026, 11, 17, 16, 40));
    final state = SyncState(store);
    final sam = server.user('user-1');
    tasks = TaskLibrary(
      notes: notes,
      store: store,
      state: state,
      storage: MemoryDocStorage(),
    );
    account = Account(
      auth: FakeAuth(id: 'user-1', email: sam.email, name: sam.name),
      syncApi: (_) =>
          FakeApi(server, device: 'device-user-1', userId: 'user-1'),
      keys: KeyStore(InMemorySecureStore()),
      notes: notes,
      state: state,
      store: store,
      tags: TagStore(store),
      tasks: tasks,
    );
    prefs = LayoutPrefs(store);
    shortcuts = ShortcutPrefs(store);
    ai = FakeKapyAi();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('kapynotes/window_material'),
          (call) async => false,
        );
  });

  tearDown(() {
    kapyAiAvailable = wasAvailable;
    ai.dispose();
    account.dispose();
  });

  Future<void> pump(WidgetTester tester, TargetPlatform platform) async {
    AppPlatform.debugTargetPlatformOverride = platform;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1500, 800);
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await notes.load();
      notes.archive(notes.create(body: 'Old list').id);
      notes.updateDrawing(
        notes.create(body: '').id,
        NoteDrawing.empty,
        title: 'Shelf plan',
      );
      notes.create(
        body: [
          'Lisbon trip',
          for (var i = 1; i <= 10; i++) '☐ Errand $i',
        ].join('\n'),
      );
      await tasks.load();
      await tasks.reconcileNow();
      await account.restore();
      await account.signIn(email: 'sam@kapy373.test', password: 'x');
      await account.createPassphrase('a good passphrase');
    });
    prefs.load();
    if (!prefs.sidebarVisible) prefs.toggleSidebar();
    shortcuts.load();
    await tester.pumpWidget(
      KapyNotesApp(
        store: store,
        notes: notes,
        rates: RatesRepository(store),
        prefs: prefs,
        shortcuts: shortcuts,
        account: account,
        tasks: tasks,
        kapyAi: ai,
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> click(WidgetTester tester, Finder target, {Offset? at}) async {
    final gesture = await tester.startGesture(
      at ?? tester.getCenter(target.first),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 60));
    await gesture.up();
    await tester.pumpAndSettle();
  }

  Future<void> press(WidgetTester tester, ShortcutAction action) async {
    final binding = shortcuts.bindingFor(action)!;
    final held = [
      if (binding.meta) LogicalKeyboardKey.metaLeft,
      if (binding.control) LogicalKeyboardKey.controlLeft,
      if (binding.alt) LogicalKeyboardKey.altLeft,
      if (binding.shift) LogicalKeyboardKey.shiftLeft,
    ];
    for (final key in held) {
      await tester.sendKeyDownEvent(key);
    }
    await tester.sendKeyEvent(binding.logicalKey);
    for (final key in held.reversed) {
      await tester.sendKeyUpEvent(key);
    }
    await tester.pumpAndSettle();
  }

  LibrarySpace space(WidgetTester tester) =>
      tester.widget<SpacesRail>(find.byType(SpacesRail)).space;
  bool archiveShown() => find
      .descendant(of: find.byType(Sidebar), matching: find.text('Old list'))
      .evaluate()
      .isNotEmpty;
  final panel = find.byKey(const ValueKey('kapy-ai-panel'));
  bool panelShown() => panel.evaluate().isNotEmpty;

  Future<void> intoNotes(WidgetTester tester) async {
    await click(tester, find.byKey(const ValueKey('rail-notes')));
    if (space(tester) != LibrarySpace.notes || archiveShown()) {
      await click(tester, find.byKey(const ValueKey('rail-notes')));
    }
  }

  final controls = <_Control>[
    (
      name: "a task's box on Tasks",
      home: LibrarySpace.tasks,
      arrive: (tester) async {
        await click(tester, find.byKey(const ValueKey('rail-tasks')));
        await click(tester, find.byKey(const ValueKey('tasks-add-field')));
        expect(FocusManager.instance.primaryFocus?.debugLabel, 'Add a task');
        await click(
          tester,
          find
              .byWidgetPredicate((w) => w.runtimeType.toString() == '_RowBox')
              .hitTestable(),
        );
      },
    ),
    (
      name: 'the Kapy AI panel',
      home: LibrarySpace.notes,
      arrive: (tester) async {
        await intoNotes(tester);
        if (!panelShown()) {
          await click(tester, find.byKey(const ValueKey('page-kapy-ai')));
        }
        await click(tester, find.byKey(const ValueKey('kapy-ai-field')));
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'kapy-ai-composer',
        );
        await click(
          tester,
          panel,
          at: tester.getRect(panel).topCenter + const Offset(0, 120),
        );
      },
    ),
    (
      name: "the rail's Notes",
      home: LibrarySpace.notes,
      arrive: (tester) async {
        await intoNotes(tester);
        await click(tester, find.byType(NoteEditor));
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          startsWith('note-editor'),
        );
        await click(tester, find.byKey(const ValueKey('rail-notes')));
      },
    ),
    (
      name: "the page's More, opened and closed",
      home: LibrarySpace.notes,
      arrive: (tester) async {
        await intoNotes(tester);
        await click(tester, find.byType(NoteEditor));
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          startsWith('note-editor'),
        );
        await click(tester, find.byKey(const ValueKey('page-more')));
        await click(tester, find.byType(Navigator), at: const Offset(8, 790));
      },
    ),
  ];

  /// Each Go to key, and how to tell it went where it goes.
  final goTo = <ShortcutAction, bool Function(WidgetTester tester)>{
    ShortcutAction.showNotes: (tester) =>
        space(tester) == LibrarySpace.notes && !archiveShown(),
    ShortcutAction.showTasks: (tester) => space(tester) == LibrarySpace.tasks,
    ShortcutAction.showDrawings: (tester) =>
        space(tester) == LibrarySpace.drawings,
    ShortcutAction.showShared: (tester) => space(tester) == LibrarySpace.shared,
    ShortcutAction.showArchive: (tester) =>
        space(tester) == LibrarySpace.notes && archiveShown(),
  };

  for (final platform in [
    TargetPlatform.linux,
    TargetPlatform.windows,
    TargetPlatform.macOS,
  ]) {
    group('on ${platform.name}', () {
      for (final control in controls) {
        testWidgets('after a click on ${control.name}, Go to and Kapy AI '
            'answer their keys', (tester) async {
          await pump(tester, platform);
          final home = control.home == LibrarySpace.tasks
              ? ShortcutAction.showTasks
              : ShortcutAction.showNotes;
          for (final action in goTo.keys) {
            await control.arrive(tester);
            // A space's own key changes nothing to see on that space, so
            // another Go to key leaves it first, straight after the click.
            if (action == home) {
              final away = home == ShortcutAction.showTasks
                  ? ShortcutAction.showNotes
                  : ShortcutAction.showArchive;
              await press(tester, away);
              expect(goTo[away]!(tester), isTrue, reason: away.name);
            }
            await press(tester, action);
            expect(goTo[action]!(tester), isTrue, reason: action.name);
          }

          await control.arrive(tester);
          final before = panelShown();
          await press(tester, ShortcutAction.toggleKapyAi);
          expect(panelShown(), !before, reason: 'toggleKapyAi');
        });
      }
    });
  }
}
