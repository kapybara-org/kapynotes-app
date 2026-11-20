import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kMiddleMouseButton, kSecondaryButton;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/folders.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/tags.dart' show noteTagsMax;
import 'package:kapy_notes/ui/context_menu.dart' show KapyMenuActionRow;
import 'package:kapy_notes/ui/editor/note_header.dart' show NoteMetaRow;
import 'package:kapy_notes/ui/folders_ui.dart';
import 'package:kapy_notes/ui/note_tabs.dart' show NoteTabRow;
import 'package:kapy_notes/ui/notes_list.dart'
    show NotesGroupHeading, NotesListControls;
import 'package:kapy_notes/ui/sidebar.dart';
import 'package:material_ui/material_ui.dart';

import 'app_test.dart' show MemoryStore, openNoteBody, pressShortcut;
import 'golden_test.dart'
    show goldenFolders, goldenNotes, goldenPrefs, goldenTags, pumpForGolden;
import 'test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);

  test('the tree lists folders by name, each open one with its own folders '
      'and then its notes; a count takes in what its folders hold; the '
      'notes in no folder come after, and drawings never show', () async {
    final store = MemoryStore();
    final notes = NotesStore(store);
    await notes.load();
    final folders = FolderStore(store);
    final work = folders.create('Work')!;
    final clients = folders.create('Clients', parentId: work.id)!;
    final acme = folders.create('Acme', parentId: clients.id)!;
    folders.create('Personal');
    final call = notes.create(body: 'Call with Arjun');
    final kickoff = notes.create(body: 'Acme kickoff');
    final dentist = notes.create(body: 'Dentist');
    final sketch = notes.create(drawing: true);
    folders.file([call.id, sketch.id], clients.id);
    folders.file([kickoff.id], acme.id);

    List<String> lines(Set<String> open) => [
      for (final line in folderLines(folders.tree, notes.notes, open).tree)
        switch (line) {
          FolderLine(:final folder, :final count, :final open, :final empty) =>
            '${folder.name} $count'
                '${open ? ' open' : ''}${empty ? ' empty' : ''}',
          NoteLine(:final note, :final depth) => '${note.title} at $depth',
        },
    ];

    expect(lines({}), ['Personal 0 empty', 'Work 2']);
    expect(lines({work.id, clients.id}), [
      'Personal 0 empty',
      'Work 2 open',
      'Clients 2 open',
      'Acme 1',
      'Call with Arjun at 3',
    ]);
    expect(folderLines(folders.tree, notes.notes, {}).loose, [dentist]);
  });

  test('the Folders tab and its open folders are kept for the next launch', () {
    final store = MemoryStore();
    LayoutPrefs(store)
      ..load()
      ..foldersShown = true
      ..setFolderOpen('a', true)
      ..setFolderOpen('b', true)
      ..setFolderOpen('a', false);

    final next = LayoutPrefs(store)..load();
    expect(next.foldersShown, isTrue);
    expect(next.openFolders, {'b'});
  });

  group('beside the rail', () {
    Future<void> pumpWindow(WidgetTester tester, {bool drawings = false}) =>
        pumpForGolden(
          tester,
          size: const Size(1440, 900),
          brightness: Brightness.dark,
          withNote: false,
          withDrawings: drawings,
        );

    Future<void> tapKey(WidgetTester tester, String key) async {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
    }

    Future<void> rightClick(WidgetTester tester, Finder finder) async {
      await tester.tapAt(
        tester.getCenter(finder),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
    }

    Future<void> submit(WidgetTester tester, String name) async {
      await tester.enterText(
        find.byKey(const ValueKey('folder-name-field')),
        name,
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
    }

    Finder inTab(Finder finder) => find.descendant(
      of: find.byKey(const ValueKey('folders-tab')),
      matching: finder,
    );

    Finder rowOf(String noteId) => find.byWidgetPredicate(
      (widget) => widget is NoteRow && widget.note.id == noteId,
    );

    List<String> names(String? parentId) => [
      for (final folder in goldenFolders.tree.childrenOf(parentId)) folder.name,
    ];

    Finder page() => find.byType(FolderPage);

    Finder onPage(Finder finder) =>
        find.descendant(of: page(), matching: finder);

    String pageTitle(WidgetTester tester) => tester
        .widget<Text>(find.byKey(const ValueKey('folder-page-title')))
        .data!;

    Finder tabRow() => find.byType(NoteTabRow);

    List<String> tabTitles(WidgetTester tester) => [
      for (final tab in tester.widget<NoteTabRow>(tabRow()).tabs) tab.title,
    ];

    Future<void> press(WidgetTester tester, ShortcutAction action) =>
        pressShortcut(tester, ShortcutPrefs.defaultFor(action));

    Future<void> commandClick(WidgetTester tester, Finder finder) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.tap(finder);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
    }

    testWidgets('the switch at the foot puts the folder tree in place of the '
        'notes and their filter, and the notes come back as they were', (
      tester,
    ) async {
      await pumpWindow(tester);
      goldenNotes.create(body: 'Dentist');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('sidebar-notes-filter')),
        findsOneWidget,
      );

      await tapKey(tester, 'notes-switch-folders');
      expect(goldenPrefs.foldersShown, isTrue);
      expect(find.byKey(const ValueKey('sidebar-notes-filter')), findsNothing);
      expect(inTab(find.text('Not in a folder')), findsOneWidget);
      expect(inTab(find.text('Dentist')), findsOneWidget);

      await tapKey(tester, 'notes-switch-notes');
      expect(goldenPrefs.foldersShown, isFalse);
      expect(find.byKey(const ValueKey('folders-tab')), findsNothing);
      expect(
        find.byKey(const ValueKey('sidebar-notes-filter')),
        findsOneWidget,
      );
    });

    testWidgets('Drawings and Archive hold no folders, so they have no '
        'switch, and the tree is back when the notes are', (tester) async {
      await pumpWindow(tester, drawings: true);
      goldenNotes.archive(goldenNotes.create(body: 'Old receipts').id);
      goldenNotes.create(body: 'Dentist');
      await tester.pumpAndSettle();
      await tapKey(tester, 'rail-notes');
      await tapKey(tester, 'notes-switch-folders');

      await tapKey(tester, 'rail-drawings');
      expect(find.byKey(const ValueKey('notes-folders-switch')), findsNothing);
      expect(find.byKey(const ValueKey('folders-tab')), findsNothing);
      await tapKey(tester, 'rail-notes');
      expect(find.byKey(const ValueKey('folders-tab')), findsOneWidget);

      await tapKey(tester, 'notes-switch-notes');
      await tapKey(tester, 'sidebar-notes-filter');
      await tapKey(tester, 'notes-filter-archive');
      expect(find.byKey(const ValueKey('notes-folders-switch')), findsNothing);
    });

    testWidgets('a folder opens and closes in the tree from its chevron, and '
        'opens as it was left', (tester) async {
      await pumpWindow(tester);
      final work = goldenFolders.create('Work')!;
      final note = goldenNotes.create(body: 'Pricing ideas');
      goldenFolders.file([note.id], work.id);
      await tester.pumpAndSettle();
      await tapKey(tester, 'notes-switch-folders');
      final row = find.byKey(ValueKey('folder-${work.id}'));
      expect(
        find.descendant(of: row, matching: find.text('1')),
        findsOneWidget,
      );
      expect(inTab(find.text('Pricing ideas')), findsNothing);

      await tapKey(tester, 'folder-chevron-${work.id}');
      expect(inTab(find.text('Pricing ideas')), findsOneWidget);
      expect(goldenPrefs.openFolders, {work.id});
      expect(page(), findsNothing);

      await tapKey(tester, 'folder-chevron-${work.id}');
      expect(inTab(find.text('Pricing ideas')), findsNothing);
      expect(goldenPrefs.openFolders, isEmpty);
    });

    testWidgets('a click on a folder shows it in the tab in front and opens it '
        'in the tree; its page has its folders as cards and its notes at any '
        'depth, and its cards and Back move between folders', (tester) async {
      await pumpWindow(tester);
      final work = goldenFolders.create('Work')!;
      final clients = goldenFolders.create('Clients', parentId: work.id)!;
      final acme = goldenFolders.create('Acme', parentId: clients.id)!;
      final roadmap = goldenNotes.create(body: 'Roadmap');
      final call = goldenNotes.create(body: 'Call with Arjun');
      final kickoff = goldenNotes.create(body: 'Acme kickoff');
      final receipts = goldenNotes.create(body: 'Old receipts');
      final dentist = goldenNotes.create(body: 'Dentist');
      goldenFolders
        ..file([roadmap.id, receipts.id], work.id)
        ..file([call.id], clients.id)
        ..file([kickoff.id], acme.id);
      goldenNotes.archive(receipts.id);
      await tester.pumpAndSettle();
      await tapKey(tester, 'notes-switch-folders');

      await tapKey(tester, 'folder-${work.id}');
      expect(pageTitle(tester), 'Work');
      expect(goldenPrefs.openFolders, {work.id});
      expect(
        onPage(find.text('3 notes and 1 folder, in My notes')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(ValueKey('folder-card-${clients.id}')),
          matching: find.text('2 notes'),
        ),
        findsOneWidget,
      );
      for (final note in [roadmap, call, kickoff]) {
        expect(onPage(rowOf(note.id)), findsOneWidget);
      }
      expect(onPage(rowOf(dentist.id)), findsNothing);
      expect(onPage(rowOf(receipts.id)), findsNothing);
      final name = tester.widget<Text>(
        find.descendant(
          of: find.byKey(ValueKey('folder-${work.id}')),
          matching: find.text('Work'),
        ),
      );
      expect(name.style!.fontWeight, FontWeight.w500);

      await tapKey(tester, 'folder-card-${clients.id}');
      expect(pageTitle(tester), 'Clients');
      expect(
        onPage(find.text('2 notes and 1 folder, in Work')),
        findsOneWidget,
      );
      expect(tabRow(), findsNothing, reason: 'it showed in the same tab');

      await press(tester, ShortcutAction.goBack);
      expect(pageTitle(tester), 'Work');

      await tester.tap(onPage(rowOf(roadmap.id)));
      await tester.pumpAndSettle();
      expect(page(), findsNothing);
      expect(openNoteBody(tester), 'Roadmap');

      await press(tester, ShortcutAction.goBack);
      expect(pageTitle(tester), 'Work');
    });

    testWidgets('⌘-click or a middle click on a folder opens it in a tab '
        'behind, once, under its icon and name', (tester) async {
      await pumpWindow(tester);
      final work = goldenFolders.create('Work')!;
      final personal = goldenFolders.create('Personal')!;
      goldenNotes.create(body: 'Dentist');
      await tester.pumpAndSettle();
      await tapKey(tester, 'notes-switch-folders');
      await tester.tap(inTab(find.text('Dentist')));
      await tester.pumpAndSettle();

      await commandClick(tester, find.byKey(ValueKey('folder-${work.id}')));
      expect(tabTitles(tester), ['Dentist', 'Work']);
      expect(
        tester.widget<NoteTabRow>(tabRow()).tabs.last.icon,
        KapyIcons.folderOutlined,
      );
      expect(page(), findsNothing);
      expect(openNoteBody(tester), 'Dentist');

      await tester.tapAt(
        tester.getCenter(find.byKey(ValueKey('folder-${personal.id}'))),
        buttons: kMiddleMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      await commandClick(tester, find.byKey(ValueKey('folder-${work.id}')));
      expect(tabTitles(tester), ['Dentist', 'Work', 'Personal']);

      goldenFolders.rename(work.id, 'Office');
      await tester.pumpAndSettle();
      expect(tabTitles(tester), ['Dentist', 'Office', 'Personal']);

      await tester.tap(
        find.descendant(of: tabRow(), matching: find.text('Office')),
      );
      await tester.pumpAndSettle();
      expect(pageTitle(tester), 'Office');
      expect(onPage(find.text('No notes, in My notes')), findsOneWidget);
    });

    testWidgets('a filed note has its folders in a light line 8 above its '
        'title, which open in this tab or behind; an unfiled note has none', (
      tester,
    ) async {
      await pumpWindow(tester);
      final work = goldenFolders.create('Work')!;
      final clients = goldenFolders.create('Clients', parentId: work.id)!;
      final call = goldenNotes.create(body: 'Call with Arjun\nAgenda');
      goldenNotes.create(body: 'Dentist');
      goldenFolders.file([call.id], clients.id);
      await tester.pumpAndSettle();
      final line = find.byKey(const ValueKey('note-path'));
      Finder onLine(String text) =>
          find.descendant(of: line, matching: find.text(text));

      await tester.tap(find.text('Dentist').first);
      await tester.pumpAndSettle();
      expect(openNoteBody(tester), 'Dentist');
      expect(line, findsNothing);
      expect(find.byKey(const ValueKey('page-path')), findsNothing);

      await tester.tap(find.text('Call with Arjun').first);
      await tester.pumpAndSettle();
      expect(onLine('Work'), findsOneWidget);
      expect(onLine('Clients'), findsOneWidget);
      expect(onLine('My notes'), findsNothing);
      expect(onLine('Call with Arjun'), findsNothing);
      expect(find.byKey(const ValueKey('page-path')), findsNothing);
      for (final name in ['Work', 'Clients']) {
        final style = tester.widget<Text>(onLine(name)).style!;
        expect(style.fontSize, 12, reason: name);
        expect(style.height, 16 / 12, reason: name);
        expect(style.fontWeight, FontWeight.w400, reason: name);
        expect(style.color, KapyTheme.darkPalette.textTertiary, reason: name);
      }
      // Path 16, 8, the title's 38, 10, then the meta row, all in one
      // column.
      final path = tester.getRect(line);
      final meta = tester.getRect(find.byType(NoteMetaRow));
      expect(path.height, EditorMetrics.pathRow);
      expect(path.left, meta.left);
      expect(
        meta.top - path.bottom,
        EditorMetrics.pathGap + EditorMetrics.titleRow + EditorMetrics.metaGap,
      );

      await tester.tap(onLine('Work'));
      await tester.pumpAndSettle();
      expect(pageTitle(tester), 'Work');
      await press(tester, ShortcutAction.goBack);
      expect(openNoteBody(tester), 'Call with Arjun\nAgenda');

      await commandClick(tester, onLine('Clients'));
      expect(tabTitles(tester), ['Call with Arjun', 'Clients']);
      expect(page(), findsNothing);
      expect(openNoteBody(tester), 'Call with Arjun\nAgenda');

      await tester.tapAt(
        tester.getCenter(onLine('Work')),
        buttons: kMiddleMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(tabTitles(tester), ['Call with Arjun', 'Clients', 'Work']);
      expect(openNoteBody(tester), 'Call with Arjun\nAgenda');
    });

    testWidgets('a deep path folds its middle into "…", whose menu opens the '
        'folder picked, and hovering shows it whole', (tester) async {
      await pumpWindow(tester);
      String? parent;
      final ids = <String, String>{};
      for (final name in ['Work', 'Clients', 'Acme', '2026']) {
        final folder = goldenFolders.create(name, parentId: parent)!;
        ids[name] = parent = folder.id;
      }
      final kickoff = goldenNotes.create(body: 'Acme kickoff');
      goldenFolders.file([kickoff.id], parent);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Acme kickoff').first);
      await tester.pumpAndSettle();
      final line = find.byKey(const ValueKey('note-path'));
      Finder onLine(String text) =>
          find.descendant(of: line, matching: find.text(text));

      for (final name in ['Work', 'Acme', '2026']) {
        expect(onLine(name), findsOneWidget, reason: name);
      }
      expect(onLine('Clients'), findsNothing);
      expect(
        find.descendant(
          of: find.byTooltip('Work › Clients › Acme › 2026'),
          matching: line,
        ),
        findsOneWidget,
      );

      await tapKey(tester, 'note-path-fold');
      await tapKey(tester, 'note-path-${ids['Clients']}');
      expect(pageTitle(tester), 'Clients');
    });

    testWidgets("a drawing's page has no days, so its path stays at the bar's "
        'top left', (tester) async {
      await pumpWindow(tester, drawings: true);
      await tapKey(tester, 'rail-drawings');
      await tester.tap(find.text('Garden plan').first);
      await tester.pumpAndSettle();
      final bar = find.byKey(const ValueKey('page-toolbar'));
      final path = find.byKey(const ValueKey('page-path'));
      for (final name in ['Drawings', 'Garden plan']) {
        expect(
          find.descendant(of: path, matching: find.text(name)),
          findsOneWidget,
          reason: name,
        );
      }
      expect(tester.getTopLeft(path).dx, tester.getRect(bar).left + 18);
      expect(find.byKey(const ValueKey('day-strip-month')), findsNothing);
      expect(find.byKey(const ValueKey('note-path')), findsNothing);
    });

    testWidgets("a folder in front has its month at the bar's top left and "
        'only More on its right, at the far end', (tester) async {
      await pumpWindow(tester);
      final work = goldenFolders.create('Work')!;
      await tester.pumpAndSettle();
      await tapKey(tester, 'notes-switch-folders');
      await tapKey(tester, 'folder-${work.id}');
      expect(page(), findsOneWidget);
      final bar = tester.getRect(find.byKey(const ValueKey('page-toolbar')));
      final month = find.byKey(const ValueKey('day-strip-month'));
      expect(tester.getTopLeft(month).dx, bar.left + 10);
      expect(
        find.descendant(of: month, matching: find.text('August–September')),
        findsOneWidget,
      );
      for (final key in ['page-path', 'page-saved', 'page-share']) {
        expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
      }
      final more = tester.getRect(find.byKey(const ValueKey('page-more')));
      expect(more.right, bar.right - 12);
      expect(more.center.dy, bar.center.dy);
      expect(tester.getCenter(month).dy, bar.center.dy);
    });

    testWidgets('in the list view a filed note says where it is ahead of its '
        'summary, and a note in no folder only has its summary', (
      tester,
    ) async {
      await pumpWindow(tester);
      goldenPrefs.noteCards = false;
      final work = goldenFolders.create('Work')!;
      final clients = goldenFolders.create('Clients', parentId: work.id)!;
      final call = goldenNotes.create(
        body: 'Call with Arjun\nPricing page by Friday',
      );
      final dentist = goldenNotes.create(
        body: 'Dentist\nBring the insurance card',
      );
      goldenFolders.file([call.id], clients.id);
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: rowOf(call.id),
          matching: find.text('Work › Clients · Pricing page by Friday'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: rowOf(dentist.id),
          matching: find.text('Bring the insurance card'),
        ),
        findsOneWidget,
      );

      goldenFolders.file([call.id], null);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: rowOf(call.id),
          matching: find.text('Pricing page by Friday'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the search field says it finds folders, and ⌘K shows one in '
        'the tab in front, from Archive too', (tester) async {
      await pumpWindow(tester);
      final work = goldenFolders.create('Work')!;
      goldenNotes.archive(goldenNotes.create(body: 'Old receipts').id);
      await tester.pumpAndSettle();
      expect(find.text('Search notes and folders'), findsOneWidget);

      await tapKey(tester, 'sidebar-notes-filter');
      await tapKey(tester, 'notes-filter-archive');
      expect(find.text('Search notes and folders'), findsNothing);

      await press(tester, ShortcutAction.findNotes);
      await tester.enterText(
        find.byKey(const ValueKey('command-menu-field')),
        'work',
      );
      await tester.pumpAndSettle();
      await tapKey(tester, 'command-menu-row-${work.name}');
      expect(pageTitle(tester), 'Work');
      expect(find.text('Search notes and folders'), findsOneWidget);
    });

    testWidgets('a note made while a folder is in front goes into it and '
        "takes the folder's place, and a deleted folder's tab closes", (
      tester,
    ) async {
      await pumpWindow(tester);
      final work = goldenFolders.create('Work')!;
      final personal = goldenFolders.create('Personal')!;
      await tester.pumpAndSettle();
      await tapKey(tester, 'notes-switch-folders');
      await tapKey(tester, 'folder-${work.id}');
      final before = {for (final note in goldenNotes.notes) note.id};

      await press(tester, ShortcutAction.newNote);
      final made = goldenNotes.notes.singleWhere(
        (note) => !before.contains(note.id),
      );
      expect(goldenFolders.tree.folderOf(made.id), work.id);
      expect(page(), findsNothing);

      await tapKey(tester, 'folder-${personal.id}');
      expect(pageTitle(tester), 'Personal');
      goldenFolders.delete(personal.id);
      await tester.pumpAndSettle();
      expect(page(), findsNothing);
      expect(tabRow(), findsNothing);
    });

    testWidgets('New folder names a folder in place, says there why a name '
        "won't do, and esc leaves it", (tester) async {
      await pumpWindow(tester);
      goldenFolders.create('Work');
      await tester.pumpAndSettle();
      await tapKey(tester, 'notes-switch-folders');

      await tapKey(tester, 'folders-new');
      await submit(tester, 'work');
      expect(find.text('A folder here already has that name'), findsOneWidget);
      await submit(tester, 'Ideas');
      expect(names(null), ['Ideas', 'Work']);
      expect(find.byKey(const ValueKey('folder-name-field')), findsNothing);

      await tapKey(tester, 'folders-new');
      await tester.enterText(
        find.byKey(const ValueKey('folder-name-field')),
        'Later',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('folder-name-field')), findsNothing);
      expect(names(null), ['Ideas', 'Work']);
    });

    testWidgets("a folder's menu renames it, makes a folder inside it, and "
        'deletes it with an Undo that brings back what was in it', (
      tester,
    ) async {
      await pumpWindow(tester);
      final work = goldenFolders.create('Work')!;
      final clients = goldenFolders.create('Clients', parentId: work.id)!;
      final note = goldenNotes.create(body: 'Pricing ideas');
      goldenFolders.file([note.id], work.id);
      await tester.pumpAndSettle();
      await tapKey(tester, 'notes-switch-folders');
      Future<void> choose(String action) async {
        await rightClick(tester, find.byKey(ValueKey('folder-${work.id}')));
        await tapKey(tester, '$action-folder-${work.id}');
      }

      await choose('rename');
      await submit(tester, 'Office');
      expect(names(null), ['Office']);

      await choose('new');
      expect(goldenPrefs.openFolders, {work.id});
      await submit(tester, 'Suppliers');
      expect(names(work.id), ['Clients', 'Suppliers']);

      await choose('delete');
      expect(find.text('Delete “Office”?'), findsOneWidget);
      expect(
        find.text('Its 1 note and 2 folders move to My notes.'),
        findsOneWidget,
      );
      await tapKey(tester, 'folder-delete-confirm');
      expect(names(null), ['Clients', 'Suppliers']);
      expect(goldenFolders.tree.folderOf(note.id), isNull);
      expect(find.text('Deleted “Office”'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(names(null), ['Office']);
      expect(goldenFolders.tree.folderOf(note.id), work.id);
      expect(goldenFolders.tree.byId(clients.id)!.parentId, work.id);
    });

    testWidgets('Move to… moves a folder with what is in it, never into '
        'itself, and Undo moves it back', (tester) async {
      await pumpWindow(tester);
      final work = goldenFolders.create('Work')!;
      final clients = goldenFolders.create('Clients', parentId: work.id)!;
      final personal = goldenFolders.create('Personal')!;
      await tester.pumpAndSettle();
      await tapKey(tester, 'notes-switch-folders');
      await rightClick(tester, find.byKey(ValueKey('folder-${work.id}')));
      await tapKey(tester, 'move-folder-${work.id}');

      await tapKey(tester, 'folder-pick-${clients.id}');
      expect(find.byKey(const ValueKey('folder-picker')), findsOneWidget);
      expect(goldenFolders.tree.byId(work.id)!.parentId, isNull);

      await tapKey(tester, 'folder-pick-${personal.id}');
      expect(goldenFolders.tree.byId(work.id)!.parentId, personal.id);
      expect(find.text('Moved “Work” to “Personal”'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(goldenFolders.tree.byId(work.id)!.parentId, isNull);
    });

    testWidgets('Move to folder… files a note, in a new folder named in its '
        'field, and Undo takes it back out', (tester) async {
      await pumpWindow(tester);
      goldenFolders.create('Work');
      final note = goldenNotes.create(body: 'Pricing ideas');
      await tester.pumpAndSettle();
      await rightClick(tester, rowOf(note.id));
      await tapKey(tester, 'folder-note-${note.id}');

      await tester.enterText(
        find.byKey(const ValueKey('folder-picker-field')),
        'Ideas',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('folder-pick-top')), findsNothing);
      expect(find.text('New folder “Ideas”'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(names(null), ['Ideas', 'Work']);
      final ideas = goldenFolders.tree.top.first;
      expect(goldenFolders.tree.folderOf(note.id), ideas.id);
      expect(find.text('Moved to “Ideas”'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(goldenFolders.tree.folderOf(note.id), isNull);
    });

    testWidgets("a drawing can't be filed, so its menu has no Move to "
        'folder…', (tester) async {
      await pumpWindow(tester, drawings: true);
      await tapKey(tester, 'rail-drawings');
      final drawing = goldenNotes.notes.firstWhere((note) => note.isDrawing);
      await rightClick(tester, rowOf(drawing.id));
      expect(find.byKey(ValueKey('pin-note-${drawing.id}')), findsOneWidget);
      expect(find.byKey(ValueKey('folder-note-${drawing.id}')), findsNothing);
    });

    /// The hint beside the menu line under [item].
    String? hintOf(WidgetTester tester, Finder item) => tester
        .widget<KapyMenuActionRow>(
          find.descendant(of: item, matching: find.byType(KapyMenuActionRow)),
        )
        .action
        .hint;

    testWidgets('Move to folder… files the open note from ⌘K and from the '
        "page's More too, with no shortcut beside it", (tester) async {
      await pumpWindow(tester);
      final work = goldenFolders.create('Work')!;
      final personal = goldenFolders.create('Personal')!;
      final note = goldenNotes.create(body: 'Pricing ideas');
      await tester.pumpAndSettle();
      await tester.tap(rowOf(note.id));
      await tester.pumpAndSettle();

      await press(tester, ShortcutAction.findNotes);
      await tester.enterText(
        find.byKey(const ValueKey('command-menu-field')),
        'move',
      );
      await tester.pumpAndSettle();
      expect(find.text('Actions'), findsOneWidget);
      await tapKey(tester, 'command-menu-row-Move to folder…');
      await tapKey(tester, 'folder-pick-${work.id}');
      expect(goldenFolders.tree.folderOf(note.id), work.id);

      await tapKey(tester, 'page-more');
      final more = find.byKey(const ValueKey('page-more-folder'));
      expect(hintOf(tester, more), isNull);
      await tester.tap(more);
      await tester.pumpAndSettle();
      await tapKey(tester, 'folder-pick-${personal.id}');
      expect(goldenFolders.tree.folderOf(note.id), personal.id);

      await rightClick(tester, rowOf(note.id));
      expect(
        hintOf(tester, find.byKey(ValueKey('folder-note-${note.id}'))),
        isNull,
      );
    });

    testWidgets('picked notes take a tag together from their menu and move '
        'together from their bar, and Undo puts each back in its own folder', (
      tester,
    ) async {
      await pumpWindow(tester);
      goldenPrefs.sidebarWidth = LayoutPrefs.maxSidebarWidth;
      final work = goldenFolders.create('Work')!;
      final personal = goldenFolders.create('Personal')!;
      final filed = goldenNotes.create(body: 'Pricing ideas');
      final loose = goldenNotes.create(body: 'Dentist');
      goldenFolders.file([filed.id], work.id);
      final money = goldenTags.create('Money')!;
      goldenTags.addTag(filed.id, money.id);
      await tester.pumpAndSettle();
      await tester.tap(rowOf(filed.id));
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tap(rowOf(loose.id));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);

      await rightClick(tester, rowOf(loose.id));
      expect(find.text('2 notes'), findsOneWidget);
      final folderItem = find.byKey(ValueKey('picked-folder-note-${loose.id}'));
      expect(hintOf(tester, folderItem), isNull);
      await tapKey(tester, 'picked-tags-note-${loose.id}');
      final row = find.byKey(ValueKey('tag-row-${money.id}'));
      expect(
        find.descendant(of: row, matching: find.byType(KapyIcon)),
        findsOneWidget,
      );
      expect(
        tester
            .widget<KapyIcon>(
              find.descendant(of: row, matching: find.byType(KapyIcon)),
            )
            .icon,
        KapyIcons.removeRounded,
        reason: 'only one of the two carries it, so it is dashed',
      );
      await tester.tap(row);
      await tester.pumpAndSettle();
      for (final note in [filed, loose]) {
        expect(goldenTags.tagsOf(note.id).map((tag) => tag.id), [money.id]);
      }
      await tester.tap(row);
      await tester.pumpAndSettle();
      for (final note in [filed, loose]) {
        expect(goldenTags.tagsOf(note.id), isEmpty);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      await tapKey(tester, 'picked-folder');
      await tapKey(tester, 'folder-pick-${personal.id}');
      for (final note in [filed, loose]) {
        expect(goldenFolders.tree.folderOf(note.id), personal.id);
      }
      expect(find.text('Moved 2 notes to “Personal”'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(goldenFolders.tree.folderOf(filed.id), work.id);
      expect(goldenFolders.tree.folderOf(loose.id), isNull);
    });

    testWidgets('a tag that a full note has no room for still comes off the '
        'other picked notes, and putting it back says how far it went', (
      tester,
    ) async {
      await pumpWindow(tester);
      goldenPrefs.sidebarWidth = LayoutPrefs.maxSidebarWidth;
      final money = goldenTags.create('Money')!;
      final tagged = goldenNotes.create(body: 'Pricing ideas');
      final full = goldenNotes.create(body: 'Dentist');
      goldenTags.addTag(tagged.id, money.id);
      goldenTags.setTags(full.id, [
        for (var i = 1; i <= noteTagsMax; i++) goldenTags.create('Tag $i')!.id,
      ]);
      await tester.pumpAndSettle();
      await tester.tap(rowOf(tagged.id));
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tap(rowOf(full.id));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();

      await rightClick(tester, rowOf(full.id));
      await tapKey(tester, 'picked-tags-note-${full.id}');
      final row = find.byKey(ValueKey('tag-row-${money.id}'));
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(goldenTags.tagsOf(tagged.id), isEmpty);
      expect(goldenTags.tagsOf(full.id), hasLength(noteTagsMax));

      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(goldenTags.tagsOf(tagged.id).map((tag) => tag.id), [money.id]);
      expect(goldenTags.tagsOf(full.id), hasLength(noteTagsMax));
      expect(
        find.text('Added to 1 of 2 notes. One already has $noteTagsMax tags.'),
        findsOneWidget,
      );
    });

    testWidgets("Undo after a move says so when a note's folder has been "
        'deleted since, and still puts back the rest', (tester) async {
      await pumpWindow(tester);
      goldenPrefs.sidebarWidth = LayoutPrefs.maxSidebarWidth;
      final work = goldenFolders.create('Work')!;
      final personal = goldenFolders.create('Personal')!;
      final filed = goldenNotes.create(body: 'Pricing ideas');
      final loose = goldenNotes.create(body: 'Dentist');
      goldenFolders.file([filed.id], work.id);
      await tester.pumpAndSettle();
      await tester.tap(rowOf(filed.id));
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tap(rowOf(loose.id));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      await tapKey(tester, 'picked-folder');
      await tapKey(tester, 'folder-pick-${personal.id}');

      goldenFolders.delete(work.id);
      await tester.pump();
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(find.text('That folder was deleted'), findsOneWidget);
      expect(goldenFolders.tree.folderOf(filed.id), personal.id);
      expect(goldenFolders.tree.folderOf(loose.id), isNull);
    });

    testWidgets("a folder card's menu and the page's More act on that folder, "
        'naming it in a field where the menu was', (tester) async {
      await pumpWindow(tester);
      final work = goldenFolders.create('Work')!;
      final clients = goldenFolders.create('Clients', parentId: work.id)!;
      goldenFolders.create('Suppliers', parentId: work.id);
      await tester.pumpAndSettle();
      await tapKey(tester, 'notes-switch-folders');
      await tapKey(tester, 'folder-${work.id}');

      await rightClick(
        tester,
        find.byKey(ValueKey('folder-card-${clients.id}')),
      );
      expect(find.byKey(ValueKey('new-folder-${clients.id}')), findsNothing);
      await tapKey(tester, 'rename-folder-${clients.id}');
      expect(find.byKey(const ValueKey('folder-name-popover')), findsOneWidget);
      await submit(tester, 'suppliers');
      expect(find.text('A folder here already has that name'), findsOneWidget);
      await submit(tester, 'Customers');
      expect(find.byKey(const ValueKey('folder-name-popover')), findsNothing);
      expect(names(work.id), ['Customers', 'Suppliers']);
      expect(onPage(find.text('Customers')), findsOneWidget);

      await tapKey(tester, 'page-more');
      await tapKey(tester, 'page-more-new');
      await submit(tester, 'Contracts');
      expect(names(work.id), ['Contracts', 'Customers', 'Suppliers']);
      expect(onPage(find.text('Contracts')), findsOneWidget);

      await tapKey(tester, 'page-more');
      await tapKey(tester, 'page-more-rename');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('folder-name-popover')), findsNothing);
      expect(pageTitle(tester), 'Work');

      await tapKey(tester, 'page-more');
      await tapKey(tester, 'page-more-delete');
      await tapKey(tester, 'folder-delete-confirm');
      expect(goldenFolders.tree.byId(work.id), isNull);
      expect(page(), findsNothing, reason: "the deleted folder's tab closed");
    });

    testWidgets("the sort sits in the controls row before the switch, in the "
        "list and on a folder's page, and on no day's heading", (tester) async {
      await pumpWindow(tester);
      final work = goldenFolders.create('Work')!;
      goldenFolders.file([goldenNotes.create(body: 'Roadmap').id], work.id);
      await tester.pumpAndSettle();
      final sort = find.byKey(const ValueKey('notes-grouping'));
      void besideTheSwitch() {
        expect(
          find.descendant(of: find.byType(NotesListControls), matching: sort),
          findsOneWidget,
        );
        expect(
          find.descendant(of: find.byType(NotesGroupHeading), matching: sort),
          findsNothing,
        );
        expect(
          tester.getRect(sort).left,
          greaterThan(
            tester
                .getRect(find.byKey(const ValueKey('sidebar-notes-filter')))
                .right,
          ),
        );
        expect(
          tester.getRect(sort).right,
          lessThan(
            tester
                .getRect(find.byKey(const ValueKey('sidebar-view-list')))
                .left,
          ),
        );
      }

      besideTheSwitch();
      await tapKey(tester, 'notes-switch-folders');
      await tapKey(tester, 'folder-${work.id}');
      expect(onPage(sort), findsOneWidget);
      besideTheSwitch();
    });

    testWidgets("the sort and the switch keep to the filter's line when a "
        "span's chip drops under it, and the archive has no sort", (
      tester,
    ) async {
      await pumpWindow(tester);
      goldenNotes.archive(goldenNotes.create(body: 'Old receipts').id);
      goldenNotes.create(body: 'Dentist');
      await tester.pumpAndSettle();
      for (final key in [
        'sidebar-notes-filter',
        'notes-filter-when',
        'notes-filter-when-thisMonth',
      ]) {
        await tapKey(tester, key);
      }
      final filter = tester.getRect(
        find.byKey(const ValueKey('sidebar-notes-filter')),
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('notes-when-chip'))).top,
        greaterThanOrEqualTo(filter.bottom),
        reason: 'at the default width the chip takes a line of its own',
      );
      for (final key in ['notes-grouping', 'sidebar-view-list']) {
        expect(
          tester.getCenter(find.byKey(ValueKey(key))).dy,
          filter.center.dy,
        );
      }

      await tapKey(tester, 'sidebar-notes-filter');
      await tapKey(tester, 'notes-filter-archive');
      expect(find.byKey(const ValueKey('notes-grouping')), findsNothing);
    });

    testWidgets("the tree and the switch keep r3's measures", (tester) async {
      await pumpWindow(tester);
      final work = goldenFolders.create('Work')!;
      final clients = goldenFolders.create('Clients', parentId: work.id)!;
      final filed = goldenNotes.create(body: 'Pricing ideas');
      final loose = goldenNotes.create(body: 'Dentist');
      goldenFolders.file([filed.id], clients.id);
      goldenPrefs
        ..setFolderOpen(work.id, true)
        ..setFolderOpen(clients.id, true);
      await tester.pumpAndSettle();
      await tapKey(tester, 'notes-switch-folders');

      Rect icon(Finder row, KapyIconData data) => tester.getRect(
        find.descendant(
          of: row,
          matching: find.byWidgetPredicate(
            (widget) => widget is KapyIcon && widget.icon == data,
          ),
        ),
      );
      final workRow = find.byKey(ValueKey('folder-${work.id}'));
      final clientsRow = find.byKey(ValueKey('folder-${clients.id}'));
      final clientsIcon = icon(clientsRow, KapyIcons.folderOutlined);
      expect(tester.getSize(workRow).height, 32);
      expect(
        tester.getRect(clientsRow).top - tester.getRect(workRow).bottom,
        2,
      );
      expect(
        clientsIcon.left - icon(workRow, KapyIcons.folderOutlined).left,
        16,
      );
      expect(
        icon(rowOf(filed.id), KapyIcons.noteOutlined).left - clientsIcon.left,
        16,
      );
      expect(tester.getSize(rowOf(filed.id)).height, 32);
      expect(tester.getSize(rowOf(loose.id)).height, 48);

      final bar = find.byKey(const ValueKey('notes-folders-switch'));
      expect(tester.getSize(bar).height, 40);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('notes-switch-folders')))
            .height,
        32,
      );
    });
  });
}
