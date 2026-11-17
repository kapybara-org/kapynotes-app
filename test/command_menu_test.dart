import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/note_drawing.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/task_board.dart';
import 'package:kapy_notes/data/tags.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/ui/command_menu.dart';
import 'package:kapy_notes/ui/keycap.dart';
import 'package:kapy_notes/ui/settings_dialog.dart';
import 'package:kapy_notes/ui/spaces_rail.dart';
import 'package:kapy_notes/ui/tag_colours.dart';
import 'package:kapy_notes/ui/tag_ui.dart';
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
  late _MemoryStore memory;
  late TagStore tags;
  CommandChoice? chosen;

  /// Notes about a trip to Sintra in every place a note can be: two notes,
  /// a task in one of them, a drawing, one archived and one hidden.
  Future<void> setUpNotes(WidgetTester tester) async {
    final store = memory = _MemoryStore();
    notes = NotesStore(store, now: () => DateTime(2026, 11, 17, 16, 40));
    shortcuts = ShortcutPrefs(store)..load();
    final library = TaskLibrary(
      notes: notes,
      store: store,
      storage: MemoryDocStorage(),
    );
    await notes.load();
    tags = TagStore(store);
    await tags.load();
    await library.load();
    notes.create(
      body: 'Goals - Oct 2026\nSee Sintra and Cascais before December',
    );
    notes.create(
      body:
          'Trip budget\nGo to Sintra on a weekday. The weekend queues are '
          'brutal.\n☐ Book the Sintra train tickets',
    );
    final drawing = notes.create();
    notes.setDrawingMode(drawing.id, drawing: true);
    notes.updateDrawing(
      drawing.id,
      NoteDrawing.empty,
      title: 'Sintra day route',
    );
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

  Widget tagged(Widget menu) => TagShelf(
    store: tags,
    listed: () => [
      for (final tag in tags.tags)
        (
          tag: tag,
          count: [
            for (final note in notes.notes)
              if (tags.tagsOf(note.id).any((on) => on.id == tag.id)) note,
          ].length,
        ),
    ],
    untagged: () => 0,
    isShared: (_) => false,
    onFilter: (_) {},
    child: TagMarks(
      marksOf: (noteId) => [
        for (final tag in tags.tagsOf(noteId)) tagMarkOf(tag),
      ],
      child: menu,
    ),
  );

  Future<void> pumpMenu(
    WidgetTester tester, {
    LibrarySpace space = LibrarySpace.notes,
    bool hiddenUnlocked = false,
    bool withSettings = false,
    List<String> recentIds = const [],
    Note? openNote,
    bool withTags = false,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final menu = CommandMenu(
      notes: notes,
      shortcuts: shortcuts,
      space: space,
      destinations: const [
        LibrarySpace.notes,
        LibrarySpace.tasks,
        LibrarySpace.drawings,
      ],
      showHidden: true,
      recentIds: recentIds,
      displayTime: (instant) => instant,
      taskLabel: (note) => note.title,
      tasks: board,
      hiddenUnlocked: hiddenUnlocked,
      settingsIndex: withSettings
          ? (lend) => SettingsDialog(
              onIndex: lend,
              layoutPrefs: LayoutPrefs(memory)..load(),
              shortcuts: shortcuts,
              rates: RatesRepository(memory),
              notes: notes,
            )
          : null,
      openNote: openNote,
      onChosen: (choice) => chosen = choice,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Scaffold(body: withTags ? tagged(menu) : menu),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder row(String title) => find.byKey(ValueKey('command-menu-row-$title'));

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
    final recent = notes.notes.firstWhere(
      (note) => note.title == 'Trip budget',
    );
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

  testWidgets('settings are found by what they are called, and Return opens '
      'Settings on the row', (tester) async {
    await setUpNotes(tester);
    await pumpMenu(tester, withSettings: true);
    await type(tester, 'text size');

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Appearance › Text'), findsWidgets);
    expect(find.text('Open in Settings'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    final choice = chosen! as RevealSettingChoice;
    expect(choice.section, SettingsSection.appearance);
    expect(choice.reveal, isNotNull);
  });

  testWidgets('a shortcut shows its key, and a setting a note can not match '
      'stays out of the way', (tester) async {
    await setUpNotes(tester);
    await pumpMenu(tester, withSettings: true);
    await type(tester, 'new task');
    expect(keycapOn(tester, 'New task'), '⇧⌘N');

    await type(tester, 'sintra');
    expect(find.text('Settings'), findsNothing);
    expect(find.text('Open in Settings'), findsNothing);
    expect(find.text('Open'), findsOneWidget);
  });

  testWidgets('settings that live elsewhere go nowhere, so they are not '
      'offered', (tester) async {
    await setUpNotes(tester);
    await pumpMenu(tester, withSettings: true);
    await type(tester, 'results column');
    expect(find.text('Calculation results'), findsNothing);
  });

  testWidgets('without the settings index there is no Settings section', (
    tester,
  ) async {
    await setUpNotes(tester);
    await pumpMenu(tester);
    await type(tester, 'text size');
    expect(find.text('Settings'), findsNothing);
  });

  testWidgets('settings follow the notes, tasks and drawings unless the words '
      'are the name of a setting', (tester) async {
    await setUpNotes(tester);
    await pumpMenu(tester, withSettings: true);
    notes.create(body: 'Shortcuts for the trip');
    await tester.pumpAndSettle();
    await type(tester, 'shortcuts');
    final notesHeading = tester.getTopLeft(find.text('Notes'));
    final settingsHeading = tester.getTopLeft(find.text('Settings'));
    expect(settingsHeading.dy < notesHeading.dy, isTrue);

    await type(tester, 'trip');
    expect(find.text('Settings'), findsNothing);
  });

  group('tags', () {
    late Note trip;

    Future<void> withTags(WidgetTester tester) async {
      await setUpNotes(tester);
      trip = notes.notes.firstWhere((note) => note.title == 'Trip budget');
      final work = tags.create('Work')!;
      tags.create('Travel');
      tags.addTag(trip.id, work.id);
    }

    testWidgets('a result carries the dot of its first tag', (tester) async {
      await withTags(tester);
      await pumpMenu(tester, withTags: true, recentIds: [trip.id]);

      expect(
        find.descendant(of: row('Trip budget'), matching: find.byType(TagDot)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row('Notes'), matching: find.byType(TagDot)),
        findsNothing,
      );
    });

    testWidgets('# lists the tags with their counts, and letters narrow it', (
      tester,
    ) async {
      await withTags(tester);
      await pumpMenu(tester, withTags: true);
      await type(tester, '#');

      expect(find.text('Filter by tag'), findsOneWidget);
      expect(row('Work'), findsOneWidget);
      expect(row('Travel'), findsOneWidget);
      expect(
        find.descendant(of: row('Work'), matching: find.text('1')),
        findsOneWidget,
      );
      expect(find.text('Filter notes'), findsOneWidget);

      await type(tester, '#tr');
      expect(row('Work'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(
        chosen,
        isA<FilterTagChoice>().having(
          (choice) => choice.tagId,
          'tagId',
          tags.named('Travel')!.id,
        ),
      );
    });

    testWidgets('# with no match says so and offers nothing else', (
      tester,
    ) async {
      await withTags(tester);
      await pumpMenu(tester, withTags: true);
      await type(tester, '#zzz');

      expect(find.text('No tag named “zzz”'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(chosen, isNull);
    });

    testWidgets('typing # without tags leaves search alone', (tester) async {
      await setUpNotes(tester);
      await pumpMenu(tester);
      await type(tester, '#');

      expect(find.text('Filter by tag'), findsNothing);
      expect(find.text('Use “#”'), findsOneWidget);
    });

    testWidgets('Tag note… ticks and unticks tags on the open note, and a new '
        'name creates one', (tester) async {
      await withTags(tester);
      await pumpMenu(tester, withTags: true, openNote: trip);
      await type(tester, 'tag');

      expect(find.text('Actions'), findsOneWidget);
      expect(
        find.descendant(
          of: row('Tag note…'),
          matching: find.text('Trip budget'),
        ),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(find.text('Tag note · Trip budget'), findsOneWidget);
      Finder tick(String name) => find.descendant(
        of: row(name),
        matching: findKapyIcon(KapyIcons.checkRounded),
      );
      expect(row('Work'), findsOneWidget);

      expect(tick('Work'), findsOneWidget);
      await tester.tap(row('Travel'));
      await tester.pumpAndSettle();
      expect(tick('Travel'), findsOneWidget);
      await tester.tap(row('Work'));
      await tester.pumpAndSettle();
      expect(tags.tagsOf(trip.id).map((tag) => tag.name.v), ['Travel']);
      expect(tick('Work'), findsNothing);

      await type(tester, 'Garden');
      await tester.tap(row('Create “Garden”'));
      await tester.pumpAndSettle();
      expect(
        tags.tagsOf(trip.id).map((tag) => tag.name.v),
        containsAll(['Travel', 'Garden']),
      );
      expect(chosen, isNull);
    });

    testWidgets('Tag note… is offered only with a note open', (tester) async {
      await withTags(tester);
      await pumpMenu(tester, withTags: true);
      await type(tester, 'tag');

      expect(row('Tag note…'), findsNothing);
    });
  });
}
