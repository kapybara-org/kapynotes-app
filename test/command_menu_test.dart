import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/folders.dart';
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
    await library.load();
    notes.create(
      body: 'Goals - Oct 2026\nSee Sintra and Cascais before December',
    );
    notes.create(
      body:
          'Trip budget\nGo to Sintra on a weekday. The weekend queues are '
          'brutal.\n☐ Book the Sintra train tickets',
    );
    final drawing = notes.create(drawing: true);
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

  Future<void> pumpMenu(
    WidgetTester tester, {
    LibrarySpace space = LibrarySpace.notes,
    bool hiddenUnlocked = false,
    bool withSettings = false,
    List<String> recentIds = const [],
    bool askKapyAi = false,
    TagShelf? tags,
    Note? tagNote,
    FolderTree? folders,
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
            ],
            showHidden: true,
            recentIds: recentIds,
            displayTime: (instant) => instant,
            taskLabel: (note) => note.title,
            tasks: board,
            folders: folders,
            hiddenUnlocked: hiddenUnlocked,
            askKapyAi: askKapyAi,
            tags: tags,
            tagNote: tagNote,
            settingsIndex: withSettings
                ? (lend) => SettingsDialog(
                    onIndex: lend,
                    layoutPrefs: LayoutPrefs(memory)..load(),
                    shortcuts: shortcuts,
                    rates: RatesRepository(memory),
                    notes: notes,
                  )
                : null,
            onChosen: (choice) => chosen = choice,
          ),
        ),
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

  testWidgets('folders are found by name after the notes, each with where '
      'it sits, and only where a folder can open', (tester) async {
    await setUpNotes(tester);
    final folders = FolderStore(memory);
    final work = folders.create('Work')!;
    final clients = folders.create('Sintra clients', parentId: work.id)!;
    folders.create('Sintra');
    folders.create('Lisbon');
    await pumpMenu(tester, folders: folders.tree);
    await type(tester, 'sintra');

    expect(row('Sintra'), findsOneWidget);
    expect(row('Lisbon'), findsNothing);
    expect(
      find.descendant(of: row('Sintra clients'), matching: find.text('Work')),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(find.text('Folders')).dy,
      greaterThan(tester.getTopLeft(find.text('Notes')).dy),
    );

    await tester.tap(row('Sintra clients'));
    expect(chosen, isA<OpenFolderChoice>());
    expect((chosen! as OpenFolderChoice).folderId, clients.id);

    await tester.pumpWidget(const SizedBox.shrink());
    await pumpMenu(tester);
    await type(tester, 'sintra');
    expect(find.text('Folders'), findsNothing);
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

    testWidgets('with a setting found, Return opens it and Tab asks', (
      tester,
    ) async {
      await setUpNotes(tester);
      await pumpMenu(tester, askKapyAi: true, withSettings: true);
      await type(tester, 'text size');

      expect(find.text('Open in Settings'), findsOneWidget);
      expect(find.text('Ask Kapy AI'), findsOneWidget);
      expect(row('Ask Kapy AI: text size'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(chosen, isA<RevealSettingChoice>());

      chosen = null;
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      expect((chosen! as AskKapyAiChoice).text, 'text size');
    });
  });

  group('on a touch screen', () {
    testWidgets('no row hints at a keyboard shortcut, as one on a desktop '
        'does', (tester) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      await setUpNotes(tester);
      await pumpMenu(tester);
      expect(find.byType(Keycap), findsWidgets);

      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      await tester.pumpWidget(const SizedBox());
      await pumpMenu(tester);
      expect(row('New note'), findsOneWidget);
      expect(find.byType(Keycap), findsNothing);

      await type(tester, 'sintra');
      expect(find.byType(Keycap), findsNothing);
    });

    testWidgets('Go to has no Tasks, which a desktop lists', (tester) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      await setUpNotes(tester);
      await pumpMenu(tester);
      expect(row('Tasks'), findsOneWidget);

      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      await tester.pumpWidget(const SizedBox());
      await pumpMenu(tester);
      expect(row('Notes'), findsOneWidget);
      expect(row('Drawings'), findsOneWidget);
      expect(row('Tasks'), findsNothing);
    });
  });

  group('tags', () {
    late TagStore store;
    late Tag work;
    late Tag secret;
    late Tag travel;
    late Note trip;

    /// Work on one note, Travel on none, and a Secret tag the lists leave
    /// out, as they do while Hidden is locked and only Hidden notes carry it.
    Future<TagShelf> shelf(WidgetTester tester) async {
      await setUpNotes(tester);
      store = TagStore(memory);
      await store.load();
      work = store.create('Work')!;
      travel = store.create('Travel')!;
      secret = store.create('Secret')!;
      trip = notes.notes.firstWhere((note) => note.title == 'Trip budget');
      store.addTag(trip.id, work.id);
      return TagShelf(
        store: store,
        listed: () => [(tag: work, count: 1), (tag: travel, count: 0)],
        untagged: () => 3,
        isShared: (_) => false,
        onFilter: (_) {},
        child: const SizedBox.shrink(),
      );
    }

    testWidgets('a result carries the dot of its first tag, in the dialog the '
        'app opens', (tester) async {
      await shelf(tester);
      await tester.binding.setSurfaceSize(const Size(1000, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          theme: KapyTheme.dark(),
          home: Scaffold(
            body: Builder(
              builder: (inner) {
                context = inner;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      unawaited(
        showCommandMenu(
          context,
          notes: notes,
          shortcuts: shortcuts,
          space: LibrarySpace.notes,
          destinations: const [LibrarySpace.notes],
          recentIds: [trip.id],
          displayTime: (instant) => instant,
          taskLabel: (note) => note.title,
          marksOf: (noteId) => [
            for (final tag in store.tagsOf(noteId)) tagMarkOf(tag),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.descendant(of: row('Trip budget'), matching: find.byType(TagDot)),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: row('Goals - Oct 2026'),
          matching: find.byType(TagDot),
        ),
        findsNothing,
      );
    });

    testWidgets('# lists the tags with counts, letters narrow them, and ↵ '
        'chooses one to filter by', (tester) async {
      final tags = await shelf(tester);
      await pumpMenu(tester, tags: tags);

      await type(tester, '#');
      expect(find.text('Filter by tag'), findsOneWidget);
      expect(row('Work'), findsOneWidget);
      expect(row('Travel'), findsOneWidget);
      expect(row('Secret'), findsNothing);
      expect(find.text('Filter notes'), findsOneWidget);

      await type(tester, '#tr');
      expect(row('Work'), findsNothing);
      expect(row('Travel'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect((chosen! as FilterTagChoice).tagId, travel.id);
    });

    testWidgets('# with no match says so and offers nothing, and a hidden-only '
        'tag is no match', (tester) async {
      final tags = await shelf(tester);
      await pumpMenu(tester, tags: tags);

      await type(tester, '#secret');
      expect(find.text('No tag named “secret”'), findsOneWidget);
      expect(find.textContaining('Hidden'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(chosen, isNull);
    });

    testWidgets('# is plain search where there are no tags', (tester) async {
      await setUpNotes(tester);
      await pumpMenu(tester);
      await type(tester, '#sintra');
      expect(find.text('Filter by tag'), findsNothing);
      expect(find.text('New note: #sintra'), findsOneWidget);
    });

    testWidgets('Tag note… is offered for the open note, ↵ swaps the menu for '
        'its tags, and ticks follow ↵', (tester) async {
      final tags = await shelf(tester);
      await pumpMenu(tester, tags: tags, tagNote: trip);

      await type(tester, 'tag');
      expect(find.text('Actions'), findsOneWidget);
      expect(row('Tag note…'), findsOneWidget);
      expect(find.text('Trip budget'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('command-menu-tagging')),
        findsOneWidget,
      );
      expect(find.text('Tag note · Trip budget'), findsOneWidget);
      expect(find.byKey(ValueKey('tag-row-${work.id}')), findsOneWidget);
      expect(find.byKey(ValueKey('tag-row-${secret.id}')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(ValueKey('tag-row-${work.id}')),
          matching: find.byType(KapyIcon),
        ),
        findsOneWidget,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(
        [for (final tag in store.tagsOf(trip.id)) tag.name.v],
        ['Work', 'Travel'],
      );
      expect(chosen, isNull);
    });

    testWidgets('in Tag note…, a hidden-only tag\'s name is refused neutrally '
        'and neither picked nor shown', (tester) async {
      final tags = await shelf(tester);
      await pumpMenu(tester, tags: tags, tagNote: trip);
      await type(tester, 'tag');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('command-menu-field')),
        'secret',
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Create “secret”'), findsOneWidget);
      expect(find.text(chooseAnotherName), findsOneWidget);
      expect(find.textContaining('Hidden'), findsNothing);
      expect(store.tagsOf(trip.id).map((tag) => tag.id), [work.id]);
      expect(store.tags, hasLength(3));
    });

    testWidgets('Tag note… is not offered with no open note', (tester) async {
      final tags = await shelf(tester);
      await pumpMenu(tester, tags: tags);
      await type(tester, 'tag');
      expect(row('Tag note…'), findsNothing);
    });

    testWidgets('# and Tag note… never ask Kapy AI', (tester) async {
      final tags = await shelf(tester);
      await pumpMenu(tester, tags: tags, tagNote: trip, askKapyAi: true);

      await type(tester, '#tr');
      expect(find.textContaining('Ask Kapy AI:'), findsNothing);
      expect(find.text('Ask Kapy AI'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      expect(chosen, isNull);

      await type(tester, 'tag');
      expect(row('Ask Kapy AI: tag'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('command-menu-tagging')),
        findsOneWidget,
      );
      expect(find.text('Ask Kapy AI'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      expect(chosen, isNull);
    });
  });
}
