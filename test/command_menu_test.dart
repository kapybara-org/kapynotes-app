import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note_drawing.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/task_board.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/ui/command_menu.dart';
import 'package:kapy_notes/ui/keycap.dart';
import 'package:kapy_notes/ui/spaces_rail.dart';
import 'package:kapy_notes/ui/tasks/tasks_controller.dart';
import 'package:material_ui/material_ui.dart';

import 'kapy_icon_finder.dart';
import 'test_fonts.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'command-menu-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS);
  tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

  late NotesStore notes;
  late ShortcutPrefs shortcuts;
  late TaskBoard board;
  CommandChoice? chosen;

  /// Notes about a trip to Sintra in every place a note can be: two notes,
  /// a task in one of them, a drawing, one archived and one hidden.
  Future<void> setUpNotes(WidgetTester tester) async {
    final store = _MemoryStore();
    notes = NotesStore(store, now: () => DateTime(2026, 11, 17, 16, 40));
    shortcuts = ShortcutPrefs(store)..load();
    final library = TaskLibrary(
      notes: notes,
      store: store,
      storage: MemoryDocStorage(),
    );
    await notes.load();
    await library.load();
    notes.create(body: 'Goals - Oct 2026\nSee Sintra and Cascais before December');
    notes.create(
      body:
          'Trip budget\nGo to Sintra on a weekday. The weekend queues are '
          'brutal.\n☐ Book the Sintra train tickets',
    );
    final drawing = notes.create();
    notes.setDrawingMode(drawing.id, drawing: true);
    notes.updateDrawing(drawing.id, NoteDrawing.empty, title: 'Sintra day route');
    notes.archive(notes.create(body: 'Old Sintra plan').id);
    notes.hide(notes.create(body: 'Secret Sintra gift').id);
    final tasks = TasksController(
      notes: notes,
      library: library,
      canEdit: (_) => true,
    );
    await tasks.reconcileNow();
    board = tasks.read();
    chosen = null;
    addTearDown(() {
      tasks.dispose();
      library.dispose();
    });
  }

  Future<void> pumpMenu(
    WidgetTester tester, {
    LibrarySpace space = LibrarySpace.notes,
    bool hiddenUnlocked = false,
    List<String> recentIds = const [],
    bool askKapyAi = false,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Scaffold(
          body: CommandMenu(
            notes: notes,
            shortcuts: shortcuts,
            space: space,
            destinations: const [
              LibrarySpace.notes,
              LibrarySpace.tasks,
              LibrarySpace.drawings,
              LibrarySpace.hidden,
              LibrarySpace.archive,
            ],
            recentIds: recentIds,
            displayTime: (instant) => instant,
            taskLabel: (note) => note.title,
            tasks: board,
            hiddenUnlocked: hiddenUnlocked,
            askKapyAi: askKapyAi,
            onChosen: (choice) => chosen = choice,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder row(String title) =>
      find.byKey(ValueKey('command-menu-row-$title'));

  String? keycapOn(WidgetTester tester, String title) {
    final caps = find.descendant(of: row(title), matching: find.byType(Keycap));
    return caps.evaluate().isEmpty ? null : tester.widget<Keycap>(caps).label;
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(
      find.byKey(const ValueKey('command-menu-field')),
      text,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('before typing: recent notes, then Create and Go to with the '
      'keys that work from here', (tester) async {
    await setUpNotes(tester);
    final recent = notes.notes.firstWhere((note) => note.title == 'Trip budget');
    await pumpMenu(tester, recentIds: [recent.id]);

    for (final heading in ['Recent', 'Create', 'Go to']) {
      expect(find.text(heading), findsOneWidget);
    }
    expect(row('Trip budget'), findsOneWidget);
    expect(keycapOn(tester, 'New note'), '⌘N');
    expect(keycapOn(tester, 'New task'), '⇧⌘N');
    expect(keycapOn(tester, 'New drawing'), '⇧⌘D');
    expect(keycapOn(tester, 'Notes'), '⌥⌘1');
    expect(keycapOn(tester, 'Tasks'), '⌥⌘2');
    expect(keycapOn(tester, 'Drawings'), '⌥⌘3');
    expect(keycapOn(tester, 'Archive'), '⌥⌘5');
    expect(keycapOn(tester, 'Settings'), '⌘,');
    expect(row('Hidden'), findsOneWidget);
    expect(find.text('Search…'), findsOneWidget);
    expect(find.text('Ask AI'), findsNothing);
  });

  testWidgets('in Tasks, New note has no key, because there the key adds a '
      'task', (tester) async {
    await setUpNotes(tester);
    await pumpMenu(tester, space: LibrarySpace.tasks);

    expect(keycapOn(tester, 'New note'), isNull);
    expect(keycapOn(tester, 'New task'), '⇧⌘N');
  });

  testWidgets('typing searches notes, tasks and drawings, offers the words '
      'as a task or a note, and counts what Archive holds', (tester) async {
    await setUpNotes(tester);
    await pumpMenu(tester);
    await type(tester, 'sintra');

    for (final heading in ['Notes', 'Tasks', 'Drawings', 'Use “sintra”']) {
      expect(find.text(heading), findsOneWidget, reason: heading);
    }
    expect(row('Trip budget'), findsOneWidget);
    expect(
      find.descendant(
        of: row('Trip budget'),
        matching: find.textContaining('on a weekday', findRichText: true),
      ),
      findsOneWidget,
    );
    expect(row('Goals - Oct 2026'), findsOneWidget);
    expect(row('Book the Sintra train tickets'), findsOneWidget);
    expect(row('Sintra day route'), findsOneWidget);
    expect(row('New task: sintra'), findsOneWidget);
    expect(row('New note: sintra'), findsOneWidget);
    expect(row('1 more in Archive'), findsOneWidget);
    // Hidden stays out of a search while it is locked.
    expect(row('Secret Sintra gift'), findsNothing);

    await tester.tap(row('1 more in Archive'));
    expect(chosen, isA<SearchArchiveChoice>());
    expect((chosen! as SearchArchiveChoice).query, 'sintra');
  });

  testWidgets('every word in any order, as the list always matched', (
    tester,
  ) async {
    await setUpNotes(tester);
    await pumpMenu(tester);
    await type(tester, 'weekday sintra');

    expect(row('Trip budget'), findsOneWidget);
    expect(row('Goals - Oct 2026'), findsNothing);
  });

  testWidgets('unlocked, Hidden notes are found too, behind a lock', (
    tester,
  ) async {
    await setUpNotes(tester);
    await pumpMenu(tester, hiddenUnlocked: true);
    await type(tester, 'gift');

    expect(row('Secret Sintra gift'), findsOneWidget);
    expect(
      find.descendant(
        of: row('Secret Sintra gift'),
        matching: findKapyIcon(KapyIcons.lockRounded),
      ),
      findsOneWidget,
    );
  });

  testWidgets('Return opens the first result, and the arrows move first', (
    tester,
  ) async {
    await setUpNotes(tester);
    await pumpMenu(tester);
    await type(tester, 'sintra');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect((chosen! as OpenNoteChoice).note.title, 'Trip budget');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(
      (chosen! as OpenTaskChoice).task.words,
      'Book the Sintra train tickets',
    );
  });

  testWidgets('with nothing found, the words can still become a task or a '
      'note', (tester) async {
    await setUpNotes(tester);
    await pumpMenu(tester);
    await type(tester, 'buy stamps');

    expect(find.text('Notes'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect((chosen! as NewTaskChoice).text, 'buy stamps');
  });

  group('Ask Kapy AI', () {
    testWidgets('is offered only where Kapy AI can be asked', (tester) async {
      await setUpNotes(tester);
      await pumpMenu(tester);
      expect(find.text('Search…'), findsOneWidget);
      await type(tester, 'sintra');

      expect(row('Ask Kapy AI: sintra'), findsNothing);
      expect(find.text('Ask Kapy AI'), findsNothing);
      expect(row('New note: sintra'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await pumpMenu(tester, askKapyAi: true);
      expect(find.text('Search or Ask Kapy AI…'), findsOneWidget);
      await type(tester, 'sintra');
      expect(row('Ask Kapy AI: sintra'), findsOneWidget);
      expect(keycapOn(tester, 'Ask Kapy AI: sintra'), 'tab');
      expect(
        find.descendant(
          of: row('Ask Kapy AI: sintra'),
          matching: findKapyIcon(KapyIcons.sparklesOutlined),
        ),
        findsOneWidget,
      );
    });

    testWidgets('is not there before anything is typed', (tester) async {
      await setUpNotes(tester);
      await pumpMenu(tester, askKapyAi: true);

      expect(find.textContaining('Ask Kapy AI:'), findsNothing);
      expect(find.text('Ask Kapy AI'), findsNothing);
    });

    testWidgets('the row asks the typed words when it is chosen', (
      tester,
    ) async {
      await setUpNotes(tester);
      await pumpMenu(tester, askKapyAi: true);
      await type(tester, 'sintra');

      await tester.tap(row('Ask Kapy AI: sintra'));
      expect((chosen! as AskKapyAiChoice).text, 'sintra');
    });

    testWidgets('Return on the highlighted row asks', (tester) async {
      await setUpNotes(tester);
      await pumpMenu(tester, askKapyAi: true);
      await type(tester, 'buy stamps');

      // Nothing matched, so the rows are New task, New note, then Ask.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect((chosen! as AskKapyAiChoice).text, 'buy stamps');
    });

    testWidgets('Tab asks from anywhere, and says so in the footer', (
      tester,
    ) async {
      await setUpNotes(tester);
      await pumpMenu(tester, askKapyAi: true);
      expect(find.text('Ask Kapy AI'), findsNothing);

      await type(tester, '  sintra  ');
      expect(find.text('Ask Kapy AI'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);

      expect((chosen! as AskKapyAiChoice).text, 'sintra');
    });

    testWidgets('Tab with nothing typed, or without Kapy AI, does nothing', (
      tester,
    ) async {
      await setUpNotes(tester);
      await pumpMenu(tester, askKapyAi: true);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      expect(chosen, isNull);

      await tester.pumpWidget(const SizedBox());
      await pumpMenu(tester);
      await type(tester, 'sintra');
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      expect(chosen, isNull);
    });

    testWidgets('typing with the Ask row, dark', (tester) async {
      await setUpNotes(tester);
      await pumpMenu(tester, askKapyAi: true);
      await type(tester, 'sintra');

      await expectLater(
        find.byKey(const ValueKey('command-menu')),
        matchesGoldenFile('goldens/command_menu_dark_ask.png'),
      );
    });
  });
}
