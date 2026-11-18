import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/audio/voice_recorder.dart';
import 'package:kapy_notes/audio/voice_recording_controller.dart';
import 'package:kapy_notes/billing/note_limit.dart';
import 'package:kapy_notes/core/menu_bar_panel.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/ui/menu_bar_panel.dart';
import 'package:kapy_notes/ui/tasks/tasks_controller.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'menu-bar-panel-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;

  @override
  void putNow(String key, Object? value) => data[key] = value;
}

/// The plan's answers, without an account behind them.
class _Limit extends ChangeNotifier implements NoteLimit {
  _Limit({this.limit});

  @override
  final int? limit;

  @override
  bool canCreate = true;

  final Set<String> locked = {};

  @override
  bool isLocked(Note note) => locked.contains(note.id);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(loadTestFonts);

  late DateTime clock;
  late _MemoryStore store;
  late NotesStore notes;
  late TaskLibrary library;
  late TasksController tasks;
  late LayoutPrefs prefs;
  late ShortcutPrefs shortcuts;
  late MenuBarPanelController controller;
  late List<String> window;
  late _Limit limit;
  late Set<String> viewOnly;
  late _SilentRecorder recorder;
  late VoiceRecordingController recording;

  setUp(() async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
    clock = DateTime(2026, 11, 18, 15, 43);
    store = _MemoryStore();
    notes = NotesStore(store, now: () => clock);
    library = TaskLibrary(
      notes: notes,
      store: store,
      storage: MemoryDocStorage(),
      now: () => clock,
    );
    await notes.load();
    limit = _Limit(limit: 20);
    viewOnly = {};
    bool canEdit(Note note) => panelCanEdit(
      note,
      limit: limit,
      canEditShared: (note) => !viewOnly.contains(note.id),
    );
    tasks = TasksController(
      notes: notes,
      library: library,
      canEdit: canEdit,
      now: () => clock,
    );
    prefs = LayoutPrefs(store)..load();
    shortcuts = ShortcutPrefs(store)..load();
    controller = MenuBarPanelController(
      channel: const MethodChannel('test/menubar_panel'),
    );
    window = [];
    recorder = _SilentRecorder();
    recording = VoiceRecordingController(
      recorder: recorder,
      tempDirectory: Directory.systemTemp,
    );
  });

  tearDown(() {
    AppPlatform.debugTargetPlatformOverride = null;
    recording.dispose();
    controller.dispose();
    tasks.dispose();
    library.dispose();
  });

  void later([Duration by = const Duration(minutes: 1)]) =>
      clock = clock.add(by);

  /// Past DocStore's write delay too, so no timer outlives the test.
  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> pumpPanel(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
    int opening = 0,
  }) async {
    // Loaded inside the test's fake clock: a future made in setUp is never
    // awaited to the end in here.
    await library.load();
    tester.view.physicalSize = const Size(360, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: brightness == Brightness.light
            ? KapyTheme.light()
            : KapyTheme.dark(),
        home: MenuBarPanel(
          key: ValueKey(opening),
          controller: controller,
          notes: notes,
          tasks: tasks,
          prefs: prefs,
          shortcuts: shortcuts,
          canEdit: (note) => panelCanEdit(
            note,
            limit: limit,
            canEditShared: (note) => !viewOnly.contains(note.id),
          ),
          inWindow: (act) async => act((
            openNote: (id) => window.add('note $id'),
            openTasks: () => window.add('tasks'),
            find: () => window.add('find'),
            newTask: () => window.add('new task'),
            openSettings: () => window.add('settings'),
            explainNoteLimit: () => window.add('limit'),
          )),
          noteLimit: limit,
          recording: recording,
          now: () => clock,
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const ValueKey('menu-bar-field')), text);
    await tester.pump();
  }

  Future<void> press(WidgetTester tester, {bool meta = false}) async {
    if (meta) await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    if (meta) await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await settle(tester);
  }

  Finder field(String hint) => find.descendant(
    of: find.byKey(const ValueKey('menu-bar-field')),
    matching: find.text(hint),
  );

  /// A note with these tasks, which Tasks has taken in before the clock
  /// moves on, so that the list keeps the order they were written in.
  Future<Note> withTasks(String title, List<String> lines) async {
    final note = notes.create(
      body: [title, ...lines.map((l) => '☐ $l')].join('\n'),
    );
    await tasks.reconcileNow();
    later();
    return note;
  }

  group('tabs', () {
    testWidgets('a first run opens on Notes', (tester) async {
      await pumpPanel(tester);
      expect(field('Write a note…'), findsOneWidget);
      expect(find.byKey(const ValueKey('menu-bar-empty')), findsOneWidget);
    });

    testWidgets('it opens on the tab used last, and ⌘1 and ⌘2 switch', (
      tester,
    ) async {
      await pumpPanel(tester);
      await tester.tap(find.byKey(const ValueKey('menu-bar-tab-tasks')));
      await settle(tester);
      expect(field('Add a task…'), findsOneWidget);
      expect(prefs.menuBarOpensTasks, isTrue);
      expect(store.data['menuBarOpensTasks.v1'], isTrue);

      await pumpPanel(tester, opening: 1);
      expect(field('Add a task…'), findsOneWidget, reason: 'reopens on Tasks');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await settle(tester);
      expect(field('Write a note…'), findsOneWidget);
      expect(prefs.menuBarOpensTasks, isFalse);
    });

    testWidgets('each tab keeps its own draft, and so does closing', (
      tester,
    ) async {
      await pumpPanel(tester);
      await type(tester, 'Half a thought');
      await tester.tap(find.byKey(const ValueKey('menu-bar-tab-tasks')));
      await settle(tester);
      await type(tester, 'Call the bank');
      await tester.tap(find.byKey(const ValueKey('menu-bar-tab-notes')));
      await settle(tester);
      expect(find.text('Half a thought'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await pumpPanel(tester, opening: 1);
      expect(find.text('Half a thought'), findsOneWidget);
      expect(controller.taskDraft.text, 'Call the bank');
      expect(notes.notes, isEmpty, reason: 'Esc saves nothing');
    });
  });

  group('capture to a note', () {
    testWidgets('Return saves a note named by its first line', (tester) async {
      await pumpPanel(tester);
      await type(tester, 'Groceries\nmilk and eggs');
      expect(find.text('Save'), findsOneWidget, reason: 'the hint while typing');
      await press(tester);

      expect(notes.notes.single.title, 'Groceries');
      expect(notes.notes.single.body, 'Groceries\nmilk and eggs');
      expect(controller.noteDraft.text, isEmpty);
      expect(find.text('Saved to Notes'), findsOneWidget);
      expect(window, isEmpty, reason: 'the panel stays put');
      expect(find.text('Groceries'), findsOneWidget, reason: 'top of Recent');

      await tester.pump(const Duration(seconds: 4));
      expect(find.text('Saved to Notes'), findsNothing);
    });

    testWidgets('⌘Return saves and opens it', (tester) async {
      await pumpPanel(tester);
      await type(tester, 'Trip to Goa');
      await press(tester, meta: true);
      expect(window, ['note ${notes.notes.single.id}']);
    });

    testWidgets('an empty field saves nothing', (tester) async {
      await pumpPanel(tester);
      await type(tester, '   ');
      await press(tester);
      expect(notes.notes, isEmpty);
    });

    testWidgets('the mic records into a new note, and only on Notes', (
      tester,
    ) async {
      await pumpPanel(tester);
      await tester.tap(find.byKey(const ValueKey('menu-bar-mic')));
      await tester.pump();

      expect(recording.isRecording, isTrue);
      expect(recording.session!.noteId, notes.notes.single.id);
      expect(find.byKey(const ValueKey('menu-bar-recording')), findsOneWidget);
      // Cancelling deletes the file, and real I/O never completes inside the
      // fake-async zone that testWidgets runs in.
      await tester.runAsync(recording.cancel);
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(find.byKey(const ValueKey('menu-bar-mic')), findsNothing);
    });

    testWidgets('without the microphone, the empty note goes again', (
      tester,
    ) async {
      recorder.permitted = false;
      await pumpPanel(tester);
      await tester.tap(find.byKey(const ValueKey('menu-bar-mic')));
      await tester.pump();

      expect(recording.isRecording, isFalse);
      expect(notes.notes, isEmpty);
      expect(
        find.text('Kapy Notes needs microphone access to record'),
        findsOneWidget,
      );
    });

    testWidgets('on the Free plan at its limit, no note is made', (
      tester,
    ) async {
      limit.canCreate = false;
      await pumpPanel(tester);
      await type(tester, 'One too many');
      await press(tester);

      expect(notes.notes, isEmpty);
      expect(find.text('The Free plan keeps 20 notes.'), findsOneWidget);
      expect(controller.noteDraft.text, 'One too many', reason: 'kept');
      await tester.tap(find.byKey(const ValueKey('menu-bar-link-Upgrade')));
      await tester.pump();
      expect(window, ['limit']);
    });
  });

  group('capture to a task', () {
    setUp(() => prefs.menuBarOpensTasks = true);

    testWidgets('with no note, it goes to the end of Tasks', (tester) async {
      await withTasks('Freelance', ['Send the March invoice']);
      await pumpPanel(tester);
      later();
      await type(tester, 'Return the library books');
      expect(find.text('Add to Tasks'), findsOneWidget);
      await press(tester);

      final open = tasks.read().open;
      expect(open.last.words, 'Return the library books');
      expect(open.last.note.title, 'Tasks');
      expect(find.text('Added to Tasks'), findsOneWidget);
      expect(find.text('No note'), findsWidgets);

      await tester.tap(find.byKey(const ValueKey('menu-bar-link-Undo')));
      await settle(tester);
      expect(tasks.read().open.map((item) => item.words), [
        'Send the March invoice',
      ]);
    });

    testWidgets('into the chosen note, which stays chosen', (tester) async {
      final budget = await withTasks('Home budget', ['Pay the electricity bill']);
      await pumpPanel(tester);
      await tester.tap(find.byKey(const ValueKey('menu-bar-note-chip')));
      await settle(tester);
      await tester.tap(find.byKey(ValueKey('menu-bar-pick-${budget.id}')));
      await settle(tester);

      await type(tester, 'Call the bank about the card');
      await press(tester);
      await type(tester, 'Book the car service');
      await press(tester);

      expect(notes.byId(budget.id)!.body, endsWith(
        '☐ Call the bank about the card\n☐ Book the car service',
      ));
      expect(controller.taskNoteId, budget.id);
    });

    testWidgets('⌘Return adds and opens its note, or Tasks', (tester) async {
      final budget = await withTasks('Home budget', ['Pay the electricity bill']);
      await pumpPanel(tester);
      await type(tester, 'Buy coffee beans');
      await press(tester, meta: true);
      expect(window, ['tasks']);

      controller.taskNoteId = budget.id;
      await pumpPanel(tester, opening: 1);
      await type(tester, 'Book the car service');
      await press(tester, meta: true);
      expect(window, ['tasks', 'note ${budget.id}']);
    });

    testWidgets('on the Free plan at its limit, no Tasks note is made', (
      tester,
    ) async {
      limit.canCreate = false;
      await pumpPanel(tester);
      await type(tester, 'Buy coffee beans');
      await press(tester);
      expect(notes.notes, isEmpty);
      expect(find.text('The Free plan keeps 20 notes.'), findsOneWidget);
    });

    testWidgets('the note picker leaves out what cannot take a task', (
      tester,
    ) async {
      final mine = await withTasks('Groceries', []);
      final locked = await withTasks('Old plan', []);
      limit.locked.add(locked.id);
      final shared = notes.create(
        body: 'Team offsite',
        spaceId: 'space',
        contentKey: Uint8List(32),
      );
      viewOnly.add(shared.id);
      final hidden = await withTasks('Diary', []);
      notes.hide(hidden.id);

      await pumpPanel(tester);
      await tester.tap(find.byKey(const ValueKey('menu-bar-note-chip')));
      await settle(tester);
      expect(find.byKey(ValueKey('menu-bar-pick-${mine.id}')), findsOneWidget);
      for (final note in [locked, shared, hidden]) {
        expect(find.byKey(ValueKey('menu-bar-pick-${note.id}')), findsNothing);
      }
    });
  });

  group('the Tasks tab', () {
    setUp(() => prefs.menuBarOpensTasks = true);

    testWidgets('checking a task keeps its row until the panel closes', (
      tester,
    ) async {
      await withTasks('Home budget', ['Pay the electricity bill', 'Renew passport']);
      await pumpPanel(tester);
      expect(find.text('0 of 2 done'), findsOneWidget);
      final item = tasks.read().open.first;

      await tester.tap(find.byKey(ValueKey('menu-bar-check-${item.id}')));
      await settle(tester);
      expect(notes.notes.single.body, contains('☑ Pay the electricity bill'));
      expect(find.text('Pay the electricity bill'), findsOneWidget);
      expect(find.text('1 of 2 done'), findsOneWidget);

      await tester.tap(find.byKey(ValueKey('menu-bar-check-${item.id}')));
      await settle(tester);
      expect(notes.notes.single.body, contains('☐ Pay the electricity bill'));

      await tester.tap(find.byKey(ValueKey('menu-bar-check-${item.id}')));
      await settle(tester);
      await pumpPanel(tester, opening: 1);
      expect(find.text('Pay the electricity bill'), findsNothing);
    });

    testWidgets('Space checks the row the arrow keys are on', (tester) async {
      await withTasks('Home budget', ['Pay the electricity bill']);
      await pumpPanel(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await settle(tester);
      expect(notes.notes.single.body, contains('☑ Pay the electricity bill'));
    });

    testWidgets('locked and view-only notes show their tasks, unchecked', (
      tester,
    ) async {
      final locked = await withTasks('Old plan', ['Archive the drafts']);
      limit.locked.add(locked.id);
      final shared = notes.create(
        body: 'Team offsite\n☐ Draft the Q1 hiring plan',
        spaceId: 'space',
        contentKey: Uint8List(32),
      );
      viewOnly.add(shared.id);
      await tasks.reconcileNow();
      await pumpPanel(tester);

      for (final item in tasks.read().open) {
        await tester.tap(find.byKey(ValueKey('menu-bar-check-${item.id}')));
        await settle(tester);
      }
      expect(notes.byId(locked.id)!.body, contains('☐ Archive the drafts'));
      expect(notes.byId(shared.id)!.body, contains('☐ Draft the Q1'));
      expect(find.text('0 of 2 done'), findsOneWidget);
    });

    testWidgets('hidden notes and their tasks never appear', (tester) async {
      final diary = await withTasks('Diary', ['Write about the trip']);
      notes.hide(diary.id);
      await withTasks('Groceries', ['Buy coffee beans']);
      await pumpPanel(tester);
      expect(find.text('Write about the trip'), findsNothing);
      expect(find.text('Buy coffee beans'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('menu-bar-tab-notes')));
      await settle(tester);
      expect(find.text('Diary'), findsNothing);
      expect(find.text('Groceries'), findsOneWidget);
    });

    testWidgets('a long list ends in All tasks, which opens the page', (
      tester,
    ) async {
      await withTasks('Errands', [for (var i = 1; i <= 9; i++) 'Errand $i']);
      await pumpPanel(tester);
      expect(find.text('Errand 6'), findsOneWidget);
      expect(find.text('Errand 7'), findsNothing);
      expect(find.text(' · 3 more'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('menu-bar-all-tasks')));
      expect(window, ['tasks']);
    });
  });

  group('the Notes tab', () {
    testWidgets('pinned first, then recent, and a click opens the note', (
      tester,
    ) async {
      final budget = notes.create(body: 'Home budget');
      later(const Duration(hours: 2));
      final trip = notes.create(body: 'Trip to Goa');
      later(const Duration(minutes: 5));
      notes.togglePinned(budget.id);
      await pumpPanel(tester);

      expect(find.text('Pinned'), findsOneWidget);
      expect(find.text('Recent'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Home budget')).dy,
        lessThan(tester.getTopLeft(find.text('Trip to Goa')).dy),
      );
      expect(find.text('5m'), findsOneWidget);
      await tester.tap(find.text('Trip to Goa'));
      expect(window, ['note ${trip.id}']);
    });

    testWidgets('the footer opens the window and Find', (tester) async {
      await pumpPanel(tester);
      await tester.tap(find.byKey(const ValueKey('menu-bar-search')));
      await tester.tap(find.byKey(const ValueKey('menu-bar-open-app')));
      expect(window, ['find']);
      expect(
        find.text(ShortcutPrefs.defaultFor(ShortcutAction.openApp).keycapLabel),
        findsOneWidget,
      );
    });
  });

  group('goldens', () {
    Future<void> golden(
      WidgetTester tester,
      String name, {
      bool atRest = true,
    }) async {
      if (atRest) {
        FocusManager.instance.primaryFocus?.unfocus();
        await settle(tester);
      }
      await expectLater(
          find.byKey(const ValueKey('menu-bar-panel')),
          matchesGoldenFile('goldens/menu_bar_panel_$name.png'),
        );
    }

    Future<void> seedTasks() async {
      await withTasks('Freelance', ['Send the March invoice']);
      await withTasks('Trip to Goa', ['Renew passport before the trip']);
      await withTasks('Home budget', ['Pay the electricity bill']);
      await withTasks('Team offsite', ['Draft the Q1 hiring plan']);
      await withTasks('Groceries', ['Buy coffee beans']);
      await withTasks('Tasks', ['Return the library books']);
      final budget = notes.notes.firstWhere((n) => n.title == 'Home budget');
      notes.updateBody(budget.id, '${budget.body}\n☐ Book the car service');
      await withTasks('Errands', ['Collect the dry cleaning', 'Water the plants']);
    }

    testWidgets('Tasks, light, one just checked', (tester) async {
      prefs.menuBarOpensTasks = true;
      await seedTasks();
      await tasks.reconcileNow();
      tasks.doNow(
        tasks.read().open.firstWhere(
          (item) => item.words == 'Send the March invoice',
        ),
      );
      await pumpPanel(tester);
      final bill = tasks.read().open.firstWhere(
        (item) => item.words == 'Pay the electricity bill',
      );
      await tester.tap(find.byKey(ValueKey('menu-bar-check-${bill.id}')));
      await settle(tester);
      await golden(tester, 'tasks_light');
    });

    testWidgets('Tasks capture in use, light', (tester) async {
      prefs.menuBarOpensTasks = true;
      await seedTasks();
      await tasks.reconcileNow();
      tasks.doNow(
        tasks.read().open.firstWhere(
          (item) => item.words == 'Send the March invoice',
        ),
      );
      controller.taskNoteId = notes.notes
          .firstWhere((n) => n.title == 'Home budget')
          .id;
      await pumpPanel(tester);
      await type(tester, 'Call the bank about the card');
      await golden(tester, 'capture_light', atRest: false);
    });

    testWidgets('Notes, dark', (tester) async {
      for (final title in ['Freelance', 'Q4 planning', 'Groceries', 'Team offsite']) {
        notes.create(body: title);
        later(const Duration(hours: 20));
      }
      final reading = notes.create(body: 'Reading list');
      later(const Duration(hours: 3));
      final budget = notes.create(body: 'Home budget');
      later(const Duration(minutes: 30));
      notes.create(body: 'Trip to Goa');
      later(const Duration(minutes: 5));
      notes.togglePinned(budget.id);
      notes.togglePinned(reading.id);
      await pumpPanel(tester, brightness: Brightness.dark);
      await golden(tester, 'notes_dark');
    });

    testWidgets('empty, first run, dark', (tester) async {
      await pumpPanel(tester, brightness: Brightness.dark);
      await golden(tester, 'empty_dark');
    });
  });
}

/// A recorder with no microphone behind it, which only remembers its file.
class _SilentRecorder implements VoiceRecorderBackend {
  bool permitted = true;
  String? startedAt;

  final _amplitude = StreamController<double>.broadcast();
  final _paused = StreamController<bool>.broadcast();

  @override
  Future<bool> hasPermission() async => permitted;

  @override
  Future<void> start(String path) async => startedAt = path;

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<String?> stop() async => startedAt;

  @override
  Future<void> cancel() async {}

  @override
  Stream<double> get amplitude => _amplitude.stream;

  @override
  Stream<bool> get paused => _paused.stream;

  @override
  Future<void> dispose() async {
    await _amplitude.close();
    await _paused.close();
  }
}
