// The menu bar panel on a real engine: a second Flutter view in a native
// panel, which flutter test cannot host. This opens it through the same
// channel the menu bar icon uses, times each opening, and then captures,
// switches tabs and checks a task in it with synthetic events.
//
// The panel opens without becoming key, so nothing on the Mac loses focus,
// and with no menu bar icon in this run it sits in the top-right corner. The
// stores are in memory: nothing is read from or written to the app's own
// files, and sync is never constructed.
//
//   flutter build macos --profile -t integration_test/menu_bar_panel_test.dart \
//     --dart-define=KAPYNOTES_SYNC=false
//   open -g --stdout out.txt "build/macos/Build/Products/Profile/Kapy Notes.app"
//
// Each run prints MENUBAR_OPEN_MS with the cold, median and slowest opening.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/core/menu_bar_panel.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/ui/menu_bar_panel.dart';
import 'package:kapy_notes/ui/tasks/tasks_controller.dart';
import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'menu-bar-panel-integration.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;

  @override
  void putNow(String key, Object? value) => data[key] = value;
}

/// Types into the panel's field. A live binding has no test text input, so
/// the words go straight into the draft the field edits.
Future<void> write(
  WidgetTester tester,
  TextEditingController draft,
  String words,
) async {
  await tester.tap(find.byKey(const ValueKey('menu-bar-field')));
  draft.value = TextEditingValue(
    text: words,
    selection: TextSelection.collapsed(offset: words.length),
  );
  await tester.pumpAndSettle();
}

/// Return as the Mac sends it. A profile build strips the key names that
/// sendKeyEvent finds the physical key by, so it is named here.
Future<void> pressReturn(WidgetTester tester) async {
  for (final down in [true, false]) {
    await (down ? tester.sendKeyDownEvent : tester.sendKeyUpEvent)(
      LogicalKeyboardKey.enter,
      platform: 'macos',
      physicalKey: PhysicalKeyboardKey.enter,
    );
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('the menu bar panel opens, captures and checks in place', (
    tester,
  ) async {
    await windowManager.ensureInitialized();
    await windowManager.hide();

    final store = _MemoryStore();
    final notes = NotesStore(store);
    await notes.load();
    final library = TaskLibrary(
      notes: notes,
      store: store,
      storage: MemoryDocStorage(),
    );
    await library.load();
    final tasks = TasksController(
      notes: notes,
      library: library,
      canEdit: (_) => true,
    );
    final prefs = LayoutPrefs(store)..load();
    final shortcuts = ShortcutPrefs(store)..load();
    final controller = MenuBarPanelController(takesKey: false);
    final opened = <String>[];
    addTearDown(() async {
      await controller.close();
      controller.dispose();
      tasks.dispose();
      library.dispose();
    });

    expect(await controller.isSupported, isTrue);

    await tester.pumpWidget(
      ViewAnchor(
        view: MenuBarPanelView(
          controller: controller,
          prefs: prefs,
          panel: (context) => MenuBarPanel(
            controller: controller,
            notes: notes,
            tasks: tasks,
            prefs: prefs,
            shortcuts: shortcuts,
            canEdit: (_) => true,
            inWindow: (act) async => act((
              openNote: (id) => opened.add('note $id'),
              openTasks: () => opened.add('tasks'),
              find: () => opened.add('find'),
              newTask: () => opened.add('new task'),
              openSettings: () => opened.add('settings'),
              explainNoteLimit: () => opened.add('limit'),
            )),
            now: notes.now,
          ),
        ),
        child: const SizedBox.shrink(),
      ),
    );

    // From the icon's click to the panel shown with its first frame drawn.
    final times = <int>[];
    for (var i = 0; i < 21; i++) {
      final watch = Stopwatch()..start();
      expect(await controller.click(), isTrue);
      times.add(watch.elapsedMicroseconds);
      expect(controller.isOpen, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await controller.close();
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    final warm = times.skip(1).toList()..sort();
    String ms(int us) => (us / 1000).toStringAsFixed(1);
    stdout.writeln(
      'MENUBAR_OPEN_MS cold=${ms(times.first)} '
      'median=${ms(warm[warm.length ~/ 2])} max=${ms(warm.last)} '
      'n=${warm.length}',
    );

    await controller.open();
    await tester.pumpAndSettle();
    final view = controller.view!;
    expect(view.physicalSize.width / view.devicePixelRatio, 360);
    expect(find.text('Write a note…'), findsOneWidget);

    await write(tester, controller.noteDraft, 'Integration note');
    await pressReturn(tester);
    await tester.pumpAndSettle();
    expect(notes.notes.single.title, 'Integration note');
    expect(find.text('Saved to Notes'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('menu-bar-tab-tasks')));
    await tester.pumpAndSettle();
    expect(prefs.menuBarOpensTasks, isTrue);
    expect(find.text('Add a task…'), findsOneWidget);

    await write(tester, controller.taskDraft, 'Water the plants');
    await pressReturn(tester);
    await tasks.reconcileNow();
    await tester.pumpAndSettle();
    final task = tasks.read().open.singleWhere(
      (item) => item.words == 'Water the plants',
    );

    await tester.tap(find.byKey(ValueKey('menu-bar-check-${task.id}')));
    await tasks.reconcileNow();
    await tester.pumpAndSettle();
    expect(tasks.read().open.where((item) => item.id == task.id), isEmpty);
    expect(
      find.byKey(ValueKey('menu-bar-task-${task.id}')),
      findsOneWidget,
      reason: 'a checked row stays until the panel closes',
    );
    expect(opened, isEmpty, reason: 'nothing asked for the window');

    // Whether ⇧⌥⌘Space is free on this Mac, registered the way the app does.
    final shortcut = ShortcutPrefs.defaultFor(ShortcutAction.openMenuBarPanel);
    final hotKey = HotKey(
      identifier: 'kapynotes.openMenuBarPanel',
      key: shortcut.physicalKey,
      modifiers: [
        if (shortcut.alt) HotKeyModifier.alt,
        if (shortcut.control) HotKeyModifier.control,
        if (shortcut.meta) HotKeyModifier.meta,
        if (shortcut.shift) HotKeyModifier.shift,
      ],
      scope: HotKeyScope.system,
    );
    try {
      await hotKeyManager.register(hotKey, keyDownHandler: (_) {});
      stdout.writeln('MENUBAR_HOTKEY registered');
    } catch (error) {
      stdout.writeln('MENUBAR_HOTKEY taken: $error');
    } finally {
      await hotKeyManager.unregisterAll();
    }
  });
}
