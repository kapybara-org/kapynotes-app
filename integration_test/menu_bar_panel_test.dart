// The menu bar panel on a real engine: a second Flutter view in a native
// panel, which flutter test cannot host. The stores are in memory, so nothing
// is read from or written to the app's own files and sync is never built.
//
//   flutter build macos --profile -t integration_test/menu_bar_panel_test.dart \
//     --dart-define=KAPYNOTES_SYNC=false
//   open -g --stdout out.txt "build/macos/Build/Products/Profile/Kapy Notes.app"
//
// By default the panel opens through the icon's channel without becoming key,
// so nothing on the Mac loses focus: each opening is timed (MENUBAR_OPEN_MS)
// and capture, the tabs and checking are driven with synthetic events.
//
// With --dart-define=MENUBAR_DRIVEN=true it instead puts the real icon in
// the menu bar and waits, at most 60 s, for an outside driver to work it
// through accessibility, then prints what happened (MENUBAR_DRIVEN). The
// driver, integration_test/menu_bar_icon_press.swift, presses the icon as
// VoiceOver does, checks that the panel opens and that a second press closes
// it, and ends the wait by creating menubar-driven-done in the app's temp
// directory. The panel never becomes key, so nothing on the Mac loses focus.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/core/app_tray.dart';
import 'package:kapy_notes/core/appearance.dart';
import 'package:kapy_notes/core/menu_bar_panel.dart';
import 'package:kapy_notes/core/theme.dart';
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

const _driven = bool.fromEnvironment('MENUBAR_DRIVEN');

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

typedef _Panel = ({
  NotesStore notes,
  TasksController tasks,
  LayoutPrefs prefs,
  MenuBarPanelController controller,
  List<String> opened,
});

/// The panel as the app wires it, on in-memory stores, with the main window
/// hidden so that nothing but the panel is ever on screen.
Future<_Panel> _pumpPanel(WidgetTester tester, {required bool takesKey}) async {
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
  final controller = MenuBarPanelController(takesKey: takesKey);
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
        look: () => (
          light: KapyTheme.light(),
          dark: KapyTheme.dark(),
          mode: prefs.appearance.themeMode,
        ),
        lookChanges: prefs.appearanceListenable,
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
  return (
    notes: notes,
    tasks: tasks,
    prefs: prefs,
    controller: controller,
    opened: opened,
  );
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
    final (:notes, :tasks, :prefs, :controller, :opened) = await _pumpPanel(
      tester,
      takesKey: false,
    );

    // From the icon's click to the panel shown with its first frame drawn.
    final times = <int>[];
    final misses = <String>[];
    final slow = <String>[];
    String ms(int us) => (us / 1000).toStringAsFixed(1);
    for (var i = 0; i < 200; i++) {
      final watch = Stopwatch()..start();
      final shown = await controller.click();
      final us = watch.elapsedMicroseconds;
      if (!shown) {
        misses.add('#$i ${controller.lastMiss?.name} after ${ms(us)} ms');
        await Future<void>.delayed(const Duration(milliseconds: 300));
        continue;
      }
      times.add(us);
      if (us > 300000) slow.add('#$i ${ms(us)}');
      expect(controller.isOpen, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await controller.close();
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    final warm = times.skip(1).toList()..sort();
    stdout.writeln(
      'MENUBAR_DIAG misses=${misses.length} [${misses.join('; ')}] '
      'over300ms=[${slow.join(', ')}] '
      'p90=${ms(warm[warm.length * 9 ~/ 10])} '
      'p99=${ms(warm[warm.length * 99 ~/ 100])}',
    );
    expect(misses, isEmpty);
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
  }, skip: _driven);

  testWidgets('the menu bar icon answers an outside driver', (tester) async {
    final (:notes, :tasks, :prefs, :controller, :opened) = await _pumpPanel(
      tester,
      takesKey: false,
    );
    final tray = AppTray(
      onOpen: () => opened.add('open'),
      onNewNote: () => opened.add('new note'),
      onNewTask: () => opened.add('new task'),
      onSettings: () => opened.add('settings'),
      onQuit: () => opened.add('quit'),
      onClick: controller.click,
    );
    addTearDown(tray.dispose);
    await tray.setVisible(true);
    stdout.writeln('MENUBAR_DRIVEN ready');

    final done = File('${Directory.systemTemp.path}/menubar-driven-done');
    final until = DateTime.now().add(const Duration(seconds: 60));
    while (!done.existsSync() && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    await tasks.reconcileNow();
    stdout.writeln(
      'MENUBAR_DRIVEN openings=${controller.openings} '
      'open=${controller.isOpen} '
      'notes=${notes.notes.map((note) => note.title).toList()} '
      'tasks=${tasks.read().open.map((item) => item.words).toList()} '
      'tasksTab=${prefs.menuBarOpensTasks} window=$opened',
    );
  }, skip: !_driven);
}
