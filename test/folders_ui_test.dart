import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kMiddleMouseButton, kSecondaryButton;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/folders.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/tags.dart' show noteTagsMax;
import 'package:kapy_notes/ui/context_menu.dart' show KapyMenuActionRow;
import 'package:kapy_notes/ui/editor/note_header.dart' show NoteMetaRow;
import 'package:kapy_notes/ui/editor_panes.dart' show NoteDragFeedback;
import 'package:kapy_notes/ui/folders_ui.dart';
import 'package:kapy_notes/ui/note_tabs.dart' show NoteTabRow;
import 'package:kapy_notes/ui/notes_list.dart'
    show NoteCardFace, NoteListRowFace, NotesGroupHeading;
import 'package:kapy_notes/ui/sidebar.dart';
import 'package:material_ui/material_ui.dart';

import 'app_test.dart' show MemoryStore, openNoteBody, pressShortcut;
import 'golden_test.dart'
    show
        goldenDays,
        goldenFolders,
        goldenNotes,
        goldenPrefs,
        goldenTags,
        pumpForGolden;
import 'test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);

  test('the tree lists folders by name, each open one with its own folders '
      'and then its notes; a count takes in what its folders hold; a note '
      'in no folder and a drawing never show', () async {
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
    notes.create(body: 'Dentist');
    final sketch = notes.create(drawing: true);
    folders.file([call.id, sketch.id], clients.id);
    folders.file([kickoff.id], acme.id);

    List<String> lines(Set<String> open) => [
      for (final line in folderLines(folders.tree, notes.notes, open))
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
    expect(lines({work.id, clients.id, acme.id}), [
      'Personal 0 empty',
      'Work 2 open',
      'Clients 2 open',
      'Acme 1 open',
      'Acme kickoff at 4',
      'Call with Arjun at 3',
    ]);
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
    Future<void> pumpWindow(
      WidgetTester tester, {
      bool drawings = false,
      bool days = false,
    }) => pumpForGolden(
      tester,
      size: const Size(1440, 900),
      brightness: Brightness.dark,
      withNote: false,
      withDrawings: drawings,
      withDays: days,
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

    /// ⌘-click on a Mac, and Ctrl-click on the Linux and Windows hosts.
    Future<void> commandClick(WidgetTester tester, Finder finder) async {
      final key = AppPlatform.isMacOS
          ? LogicalKeyboardKey.metaLeft
          : LogicalKeyboardKey.controlLeft;
      await tester.sendKeyDownEvent(key);
      await tester.tap(finder);
      await tester.sendKeyUpEvent(key);
      await tester.pumpAndSettle();
    }

    testWidgets('the switch at the foot puts the folder tree in place of the '
        'notes and their filter, and the notes come back as they were', (
      tester,
    ) async {
      await pumpWindow(tester);
      goldenFolders.create('Work');
      goldenNotes.create(body: 'Dentist');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('notes-view')), findsOneWidget);

      await tapKey(tester, 'notes-switch-folders');
      expect(goldenPrefs.foldersShown, isTrue);
      expect(find.byKey(const ValueKey('notes-view')), findsNothing);
      expect(inTab(find.text('Work')), findsOneWidget);
      // Beside the rail, the notes in no folder are in the notes list and in
      // a folder's Add notes, not under the tree.
      expect(find.text('Not in a folder'), findsNothing);
      expect(find.text('Dentist'), findsNothing);

      await tapKey(tester, 'notes-switch-notes');
      expect(goldenPrefs.foldersShown, isFalse);
      expect(find.byKey(const ValueKey('folders-tab')), findsNothing);
      expect(find.byKey(const ValueKey('notes-view')), findsOneWidget);
    });

    testWidgets('Drawings and Archive hold no folders, so they have no '
        'switch, and the tree is back when the notes are', (tester) async {
      await pumpWindow(tester, drawings: true);
      goldenFolders.create('Work');
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
      await tapKey(tester, 'notes-view');
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
      expect(name.style!.fontWeight, FontWeight.w400);

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

    testWidgets("grouped by day, a folder's page and the list's count leave "
        'out a note for a later day until its day, and grouped by tag or A to '
        'Z count it; the tree lists and counts it all along', (tester) async {
      await pumpWindow(tester, days: true);
      final work = goldenFolders.create('Work')!;
      final clients = goldenFolders.create('Clients', parentId: work.id)!;
      final acme = goldenFolders.create('Acme', parentId: clients.id)!;
      final call = goldenNotes.create(body: 'Call with Arjun');
      final renewal = goldenNotes.create(body: 'Renewal notes');
      goldenFolders.file([call.id, renewal.id], acme.id);
      await tester.pumpAndSettle();
      int listCount() =>
          tester.widget<SidebarWindowBar>(find.byType(SidebarWindowBar)).count;
      final all = listCount();
      final now = goldenNotes.now();
      goldenDays.setDay(renewal.id, DateTime(now.year, now.month, now.day + 2));
      await tapKey(tester, 'notes-switch-folders');
      await tapKey(tester, 'folder-${work.id}');
      await tapKey(tester, 'folder-card-${clients.id}');
      expect(pageTitle(tester), 'Clients');

      void counts({required bool listed}) {
        expect(
          onPage(
            find.text(
              listed
                  ? '2 notes and 1 folder, in Work'
                  : '1 note and 1 folder, in Work',
            ),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(ValueKey('folder-card-${acme.id}')),
            matching: find.text(listed ? '2 notes' : '1 note'),
          ),
          findsOneWidget,
        );
        expect(onPage(rowOf(call.id)), findsOneWidget);
        expect(
          onPage(rowOf(renewal.id)),
          listed ? findsOneWidget : findsNothing,
        );
        expect(listCount(), listed ? all : all - 1);
      }

      counts(listed: false);
      goldenPrefs
        ..setFolderOpen(clients.id, true)
        ..setFolderOpen(acme.id, true);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(ValueKey('folder-${acme.id}')),
          matching: find.text('2'),
        ),
        findsOneWidget,
      );
      expect(inTab(find.text('Renewal notes')), findsOneWidget);

      for (final grouping in [NotesGrouping.byTag, NotesGrouping.aToZ]) {
        goldenPrefs.notesGrouping = grouping;
        await tester.pumpAndSettle();
        counts(listed: true);
      }
      goldenPrefs.notesGrouping = NotesGrouping.byDate;
      await tester.pumpAndSettle();
      counts(listed: false);

      goldenDays.setDay(renewal.id, DateTime(now.year, now.month, now.day));
      await tester.pumpAndSettle();
      counts(listed: true);
    });

    testWidgets("grouped by tag, a folder's page heads its notes with their "
        'first tags, as the list beside the rail does', (tester) async {
      await pumpWindow(tester);
      final work = goldenFolders.create('Work')!;
      final call = goldenNotes.create(body: 'Call with Arjun');
      final roadmap = goldenNotes.create(body: 'Roadmap');
      goldenFolders.file([call.id, roadmap.id], work.id);
      goldenTags.addTag(call.id, goldenTags.create('Acme')!.id);
      goldenPrefs.notesGrouping = NotesGrouping.byTag;
      await tester.pumpAndSettle();
      await tapKey(tester, 'notes-switch-folders');
      await tapKey(tester, 'folder-${work.id}');

      Finder group(String label) =>
          onPage(find.byKey(ValueKey('folder-group-$label')));
      expect(group('Acme'), findsOneWidget);
      expect(group('No tag'), findsOneWidget);
      expect(
        tester.getRect(onPage(rowOf(call.id))).top,
        lessThan(tester.getRect(group('No tag')).top),
      );
      expect(
        tester.getRect(onPage(rowOf(roadmap.id))).top,
        greaterThan(tester.getRect(group('No tag')).top),
      );
    });

    testWidgets('a folder whose only note waits for a later day holds no '
        'notes on its page and its card, and never says it is empty', (
      tester,
    ) async {
      await pumpWindow(tester, days: true);
      final work = goldenFolders.create('Work')!;
      final renewals = goldenFolders.create('Renewals', parentId: work.id)!;
      final renewal = goldenNotes.create(body: 'Renewal notes');
      goldenFolders.file([renewal.id], renewals.id);
      final now = goldenNotes.now();
      goldenDays.setDay(renewal.id, DateTime(now.year, now.month, now.day + 2));
      await tester.pumpAndSettle();
      await tapKey(tester, 'notes-switch-folders');

      await tapKey(tester, 'folder-${work.id}');
      expect(onPage(find.text('1 folder, in My notes')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(ValueKey('folder-card-${renewals.id}')),
          matching: find.text('1 note'),
        ),
        findsNothing,
      );

      await tapKey(tester, 'folder-card-${renewals.id}');
      expect(onPage(find.text('No notes, in Work')), findsOneWidget);
      expect(
        onPage(find.byKey(const ValueKey('folder-page-empty'))),
        findsNothing,
      );
      expect(onPage(rowOf(renewal.id)), findsNothing);
    });

    testWidgets('⌘-click or a middle click on a folder opens it in a tab '
        'behind, once, under its icon and name', (tester) async {
      await pumpWindow(tester);
      final work = goldenFolders.create('Work')!;
      final personal = goldenFolders.create('Personal')!;
      goldenNotes.create(body: 'Dentist');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dentist'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'notes-switch-folders');

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
      expect(onPage(find.text('Nothing in this folder yet.')), findsOneWidget);
      expect(find.byKey(const ValueKey('folder-page-holds')), findsNothing);
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
        find.descendant(of: month, matching: find.text('Aug–Sep')),
        findsOneWidget,
      );
      for (final key in ['page-path', 'page-saved']) {
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

    testWidgets('⌘K shows a folder in the tab in front, from Archive too', (
      tester,
    ) async {
      await pumpWindow(tester);
      final work = goldenFolders.create('Work')!;
      goldenNotes.archive(goldenNotes.create(body: 'Old receipts').id);
      await tester.pumpAndSettle();

      await tapKey(tester, 'notes-view');
      await tapKey(tester, 'notes-filter-archive');

      await press(tester, ShortcutAction.findNotes);
      await tester.enterText(
        find.byKey(const ValueKey('command-menu-field')),
        'work',
      );
      await tester.pumpAndSettle();
      await tapKey(tester, 'command-menu-row-${work.name}');
      expect(pageTitle(tester), 'Work');
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

    /// Where the menu a right click at [click] opens sits, and where the
    /// folder list its Move to folder… opens, which esc then closes.
    Future<(Rect, Rect)> moveFrom(
      WidgetTester tester,
      String noteId,
      Offset click,
    ) async {
      await tester.tapAt(
        click,
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      final menu = tester.getRect(
        find.byKey(const ValueKey('kapy-context-menu')),
      );
      await tapKey(tester, 'folder-note-$noteId');
      final picker = find.byKey(const ValueKey('folder-picker'));
      final opened = tester.getRect(picker);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(picker, findsNothing);
      return (menu, opened);
    }

    /// The click is on the menu's top or bottom edge, within its width, so
    /// on no item, and the list hangs from the menu's corner on the click's
    /// side of it.
    void expectHung(Rect menu, Rect opened, Offset click) {
      expect(
        click.dy == menu.top || click.dy == menu.bottom,
        isTrue,
        reason: '$menu has no edge at $click',
      );
      expect(click.dx, inInclusiveRange(menu.left, menu.right));
      Offset corner(Rect rect) => Offset(
        click.dx > menu.center.dx ? rect.right : rect.left,
        click.dy > menu.center.dy ? rect.bottom : rect.top,
      );
      expect(corner(opened), corner(menu));
    }

    testWidgets('Move to folder… opens where its menu was, hung from the '
        'corner the menu hung from', (tester) async {
      await pumpWindow(tester);
      goldenFolders.create('Work');
      final note = goldenNotes.create(body: 'Pricing ideas');
      await tester.pumpAndSettle();
      final row = tester.getRect(rowOf(note.id));

      // Whichever corner the menu keeps at the click, the list hangs from
      // that same corner. Near the row's end that is the top right when the
      // menu fits to the left of the click, and the top left when it does not.
      final end = row.centerRight - const Offset(16, 0);
      final (menuAtEnd, pickerAtEnd) = await moveFrom(tester, note.id, end);
      expectHung(menuAtEnd, pickerAtEnd, end);

      final start = row.centerLeft + const Offset(16, 0);
      final (menuAtStart, pickerAtStart) = await moveFrom(
        tester,
        note.id,
        start,
      );
      expectHung(menuAtStart, pickerAtStart, start);

      await tester.tap(rowOf(note.id));
      await tester.pumpAndSettle();
      await tapKey(tester, 'page-more');
      final more = tester.getRect(
        find.byKey(const ValueKey('kapy-context-menu')),
      );
      await tapKey(tester, 'page-more-folder');
      expect(
        tester.getRect(find.byKey(const ValueKey('folder-picker'))).topRight,
        more.topRight,
      );
    });

    testWidgets('in a 400 wide window, Move to folder… opens where its menu '
        'was and keeps 8 inside the window, its list shortening when the '
        'window is short', (tester) async {
      await pumpForGolden(
        tester,
        size: const Size(400, 800),
        brightness: Brightness.dark,
        withNote: false,
      );
      final note = goldenNotes.create(body: 'Pricing ideas');
      await tester.pumpAndSettle();
      await tapKey(tester, 'page-show-list');
      final row = tester.getRect(rowOf(note.id));
      const window = Rect.fromLTRB(8, 8, 392, 792);

      final end = row.centerRight - const Offset(8, 0);
      final (menuAtEnd, pickerAtEnd) = await moveFrom(tester, note.id, end);
      expectHung(menuAtEnd, pickerAtEnd, end);
      expect(window.intersect(pickerAtEnd), pickerAtEnd);

      final start = row.centerLeft + const Offset(8, 0);
      final (menuAtStart, pickerAtStart) = await moveFrom(
        tester,
        note.id,
        start,
      );
      expectHung(menuAtStart, pickerAtStart, start);
      expect(window.intersect(pickerAtStart), pickerAtStart);

      for (var i = 1; i <= 12; i++) {
        goldenFolders.create('Folder $i');
      }
      tester.view.physicalSize = const Size(400, 300);
      await tester.pumpAndSettle();
      final (_, short) = await moveFrom(
        tester,
        note.id,
        tester.getRect(rowOf(note.id)).centerRight - const Offset(8, 0),
      );
      expect(const Rect.fromLTRB(8, 8, 392, 292).intersect(short), short);
    });

    testWidgets("in a 300 tall window, the tag list from a note's menu "
        'shortens to fit', (tester) async {
      await pumpForGolden(
        tester,
        size: const Size(400, 800),
        brightness: Brightness.dark,
        withNote: false,
      );
      for (var i = 1; i <= 12; i++) {
        goldenTags.create('Tag $i');
      }
      final note = goldenNotes.create(body: 'Pricing ideas');
      await tester.pumpAndSettle();
      await tapKey(tester, 'page-show-list');
      tester.view.physicalSize = const Size(400, 300);
      await tester.pumpAndSettle();
      await tester.tapAt(
        tester.getRect(rowOf(note.id)).centerRight - const Offset(8, 0),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      await tapKey(tester, 'tags-note-${note.id}');
      expect(find.byKey(const ValueKey('tag-picker-field')), findsOneWidget);
    });

    testWidgets(
      "a note's menu, opened mid-list in a short window, stays inside "
      'it with no item under the pointer',
      (tester) async {
        await pumpWindow(tester);
        final notes = [
          for (var i = 1; i <= 3; i++) goldenNotes.create(body: 'Note $i'),
        ];
        tester.view.physicalSize = const Size(1440, 360);
        await tester.pumpAndSettle();
        final rows = [for (final note in notes) tester.getRect(rowOf(note.id))]
          ..sort((a, b) => a.top.compareTo(b.top));
        final at = rows[1].centerRight - const Offset(16, 0);
        await tester.tapAt(
          at,
          buttons: kSecondaryButton,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();

        final menu = tester.getRect(
          find.byKey(const ValueKey('kapy-context-menu')),
        );
        expect(const Rect.fromLTWH(0, 0, 1440, 360).intersect(menu), menu);
        expect(
          !menu.contains(at) || at.dy == menu.top || at.dy == menu.bottom,
          isTrue,
          reason: '$menu holds the pointer at $at',
        );
        final underPointer = {
          for (final entry in tester.hitTestOnBinding(at).path) entry.target,
        };
        expect(
          find
              .byType(PopupMenuItem<String>)
              .evaluate()
              .where((item) => underPointer.contains(item.renderObject)),
          isEmpty,
        );
      },
    );

    testWidgets('Move to folder… works from the keyboard: ↓ in More reaches '
        'it, ↵ opens the list on the menu with its field ready, and ↓ there '
        'keeps the folder it reaches in sight', (tester) async {
      await pumpWindow(tester);
      final folders = [
        for (var i = 1; i <= 14; i++)
          goldenFolders.create('Folder ${i.toString().padLeft(2, '0')}')!,
      ];
      final note = goldenNotes.create(body: 'Pricing ideas');
      await tester.pumpAndSettle();
      await tester.tap(rowOf(note.id));
      await tester.pumpAndSettle();
      await tapKey(tester, 'page-more');
      final menu = tester.getRect(
        find.byKey(const ValueKey('kapy-context-menu')),
      );

      final item = find.byKey(const ValueKey('page-more-folder'));
      FocusNode itemFocus() => Focus.of(
        tester.element(
          find.descendant(of: item, matching: find.byType(KapyMenuActionRow)),
        ),
      );
      for (var i = 0; i < 20 && !itemFocus().hasPrimaryFocus; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }
      expect(itemFocus().hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      final picker = find.byKey(const ValueKey('folder-picker'));
      expect(tester.getRect(picker).topRight, menu.topRight);
      final field = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const ValueKey('folder-picker-field')),
          matching: find.byType(EditableText),
        ),
      );
      expect(field.focusNode.hasPrimaryFocus, isTrue);

      for (var i = 0; i < 12; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
      }
      final list = tester.getRect(
        find.descendant(of: picker, matching: find.byType(ListView)),
      );
      final reached = tester.getRect(
        find.byKey(ValueKey('folder-pick-${folders[11].id}')),
      );
      expect(reached.top, greaterThanOrEqualTo(list.top));
      expect(reached.bottom, lessThanOrEqualTo(list.bottom));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(goldenFolders.tree.folderOf(note.id), folders[11].id);
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

    testWidgets("the View icon sits beside the search in the list and at the "
        "end of a folder's page header, and Group by is in its menu, on no "
        "day's heading", (tester) async {
      await pumpWindow(tester);
      final work = goldenFolders.create('Work')!;
      goldenFolders.file([goldenNotes.create(body: 'Roadmap').id], work.id);
      await tester.pumpAndSettle();
      final view = find.byKey(const ValueKey('notes-view'));
      final search = tester.getRect(
        find.byKey(const ValueKey('sidebar-search-box')),
      );
      expect(tester.getCenter(view).dy, closeTo(search.center.dy, 0.5));
      expect(tester.getRect(view).left, greaterThan(search.right));
      expect(
        find.descendant(of: find.byType(NotesGroupHeading), matching: view),
        findsNothing,
      );

      await tapKey(tester, 'notes-switch-folders');
      await tapKey(tester, 'folder-${work.id}');
      expect(onPage(view), findsOneWidget);
      await tester.tap(onPage(view));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('notes-grouping-byDate')),
        findsOneWidget,
      );
      // A folder's page leaves out Archive and Hidden, whose notes are in no
      // folder.
      expect(find.byKey(const ValueKey('notes-filter-archive')), findsNothing);
    });

    testWidgets("a span's chip sits under the search, and the archive's View "
        'menu has no Group by', (tester) async {
      await pumpWindow(tester);
      goldenNotes.archive(goldenNotes.create(body: 'Old receipts').id);
      goldenNotes.create(body: 'Dentist');
      await tester.pumpAndSettle();
      for (final key in [
        'notes-view',
        'notes-filter-when',
        'notes-filter-when-thisMonth',
      ]) {
        await tapKey(tester, key);
      }
      final search = tester.getRect(
        find.byKey(const ValueKey('sidebar-search-box')),
      );
      final chip = tester.getRect(
        find.byKey(const ValueKey('notes-filter-chip')),
      );
      expect(chip.top, greaterThanOrEqualTo(search.bottom));
      expect(chip.left, search.left);

      await tapKey(tester, 'notes-view');
      await tapKey(tester, 'notes-filter-archive');
      await tapKey(tester, 'notes-view');
      expect(find.byKey(const ValueKey('notes-filter-menu')), findsOneWidget);
      expect(find.byKey(const ValueKey('notes-grouping-byDate')), findsNothing);
    });

    testWidgets('an empty folder and a note keep the chevron slot, so their '
        "icons line up with their siblings', 20 wide beside the rail", (
      tester,
    ) async {
      await pumpWindow(tester);
      final work = goldenFolders.create('Work')!;
      final clients = goldenFolders.create('Clients', parentId: work.id)!;
      final acme = goldenFolders.create('Acme', parentId: clients.id)!;
      final product = goldenFolders.create('Product')!;
      final offsite = goldenNotes.create(body: 'Offsite agenda');
      goldenFolders.file([offsite.id], clients.id);
      goldenPrefs
        ..setFolderOpen(work.id, true)
        ..setFolderOpen(clients.id, true);
      await tester.pumpAndSettle();
      await tapKey(tester, 'notes-switch-folders');

      double left(Finder row, KapyIconData data) => tester
          .getRect(
            find.descendant(
              of: row,
              matching: find.byWidgetPredicate(
                (widget) => widget is KapyIcon && widget.icon == data,
              ),
            ),
          )
          .left;
      Finder rowFor(Folder folder) =>
          find.byKey(ValueKey('folder-${folder.id}'));
      double folderIcon(Folder folder) =>
          left(rowFor(folder), KapyIcons.folderOutlined);
      expect(folderIcon(product), folderIcon(work));
      expect(folderIcon(work) - tester.getRect(rowFor(work)).left, 8 + 20);
      expect(left(rowOf(offsite.id), KapyIcons.noteOutlined), folderIcon(acme));
    });

    testWidgets("the tree and the switch keep r3's measures", (tester) async {
      await pumpWindow(tester);
      final work = goldenFolders.create('Work')!;
      final clients = goldenFolders.create('Clients', parentId: work.id)!;
      final filed = goldenNotes.create(body: 'Pricing ideas');
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

      // KAP-408's switch: words alone, 32 tall, with no track round them.
      final bar = find.byKey(const ValueKey('notes-folders-switch'));
      expect(tester.getSize(bar).height, 32);
      expect(
        find.descendant(of: bar, matching: find.byType(KapyIcon)),
        findsNothing,
      );
      expect(
        tester
            .getSize(find.byKey(const ValueKey('notes-switch-folders')))
            .height,
        32,
      );
    });

    Finder listed(String noteId) =>
        find.descendant(of: find.byType(Sidebar), matching: rowOf(noteId));

    /// Presses on [noteId]'s row in the list and moves sideways, which picks
    /// the note up.
    Future<TestGesture> grab(WidgetTester tester, String noteId) async {
      final drag = await tester.startGesture(
        tester.getCenter(listed(noteId)),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(const Offset(12, 2));
      await tester.pump();
      return drag;
    }

    /// How faded [noteId]'s row in the list is.
    double fade(WidgetTester tester, String noteId) => tester
        .widget<Opacity>(
          find
              .descendant(of: listed(noteId), matching: find.byType(Opacity))
              .first,
        )
        .opacity;

    Future<void> openFolder(WidgetTester tester, Folder folder) async {
      await tapKey(tester, 'notes-switch-folders');
      await tapKey(tester, 'folder-${folder.id}');
    }

    final panel = find.byKey(const ValueKey('add-notes'));
    final addButton = find.byKey(const ValueKey('add-notes-add'));
    Finder tick(String noteId) => find.byKey(ValueKey('add-note-$noteId'));
    String addLabel(WidgetTester tester) => tester
        .widget<Text>(
          find.descendant(of: addButton, matching: find.byType(Text)),
        )
        .data!;

    testWidgets('a folder opens with Add notes at its right, listing the '
        'notes in no folder newest first; the ticked ones go in together, '
        'and Undo takes them back out', (tester) async {
      await pumpWindow(tester);
      final work = goldenFolders.create('Work')!;
      final clients = goldenFolders.create('Clients')!;
      final call = goldenNotes.create(body: 'Call with Arjun');
      final dentist = goldenNotes.create(body: 'Dentist');
      final pricing = goldenNotes.create(body: 'Pricing ideas');
      goldenFolders.file([call.id], clients.id);
      await tester.pumpAndSettle();
      await openFolder(tester, work);
      Finder inPanel(Finder finder) =>
          find.descendant(of: panel, matching: finder);

      expect(inPanel(find.text('Add notes to Work')), findsOneWidget);
      expect(inPanel(find.text('2 not in a folder')), findsOneWidget);
      expect(tick(call.id), findsNothing);
      expect(
        tester.getRect(tick(pricing.id)).top,
        lessThan(tester.getRect(tick(dentist.id)).top),
      );
      expect(tester.getSize(tick(dentist.id)).height, 48);
      expect(tester.getRect(panel).right, tester.getRect(page()).right);
      // One Add notes at a time: the page's own waits for the panel's ×.
      expect(find.byKey(const ValueKey('folder-page-add-notes')), findsNothing);
      expect(addLabel(tester), 'Add notes');

      await tester.tap(tick(dentist.id));
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(tick(dentist.id)),
        isSemantics(isChecked: true),
      );
      expect(addLabel(tester), 'Add 1 note');
      await tapKey(tester, 'add-notes-select-all');
      expect(addLabel(tester), 'Add 2 notes');
      expect(find.byKey(const ValueKey('add-notes-select-all')), findsNothing);

      await tester.tap(addButton);
      await tester.pumpAndSettle();
      expect(goldenFolders.tree.folderOf(dentist.id), work.id);
      expect(goldenFolders.tree.folderOf(pricing.id), work.id);
      expect(find.text('Added 2 notes to “Work”'), findsOneWidget);
      expect(inPanel(find.text('Every note is in a folder')), findsOneWidget);
      expect(addButton, findsNothing);
      expect(onPage(find.text('Dentist')), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(goldenFolders.tree.folderOf(dentist.id), isNull);
      expect(goldenFolders.tree.folderOf(pricing.id), isNull);
      expect(tick(dentist.id), findsOneWidget);
      expect(addLabel(tester), 'Add notes');
    });

    testWidgets('Add notes finds notes by what is in them, keeps what was '
        'ticked through a search, and offers Add only with something to '
        'add', (tester) async {
      await pumpWindow(tester);
      final work = goldenFolders.create('Work')!;
      final dentist = goldenNotes.create(body: 'Dentist\nThursday 4pm');
      final gym = goldenNotes.create(body: 'Gym plan');
      await tester.pumpAndSettle();
      await openFolder(tester, work);
      final field = find.byKey(const ValueKey('add-notes-field'));

      await tester.enterText(field, 'thursday');
      await tester.pumpAndSettle();
      expect(tick(dentist.id), findsOneWidget);
      expect(tick(gym.id), findsNothing);
      await tester.tap(tick(dentist.id));
      await tester.pumpAndSettle();

      await tester.enterText(field, 'zebra');
      await tester.pumpAndSettle();
      expect(find.text('No notes match “zebra”'), findsOneWidget);
      expect(addLabel(tester), 'Add 1 note');
      await tapKey(tester, 'add-notes-field-clear');
      expect(tick(gym.id), findsOneWidget);
      await tester.tap(tick(dentist.id));
      await tester.pumpAndSettle();
      await tester.enterText(field, 'zebra');
      await tester.pumpAndSettle();
      expect(addButton, findsNothing);

      goldenFolders.file([dentist.id, gym.id], work.id);
      await tester.pumpAndSettle();
      expect(find.text('Every note is in a folder'), findsOneWidget);
      expect(field, findsNothing);
      expect(addButton, findsNothing);
    });

    testWidgets('New folder spans the list under the search on the Folders '
        'side, names a folder at the top of the tree, and opens it with Add '
        'notes; its × puts Add notes away for the page to bring back', (
      tester,
    ) async {
      await pumpWindow(tester);
      goldenNotes.create(body: 'Dentist');
      goldenPrefs.addNotesShown = false;
      await tester.pumpAndSettle();
      final button = find.byKey(const ValueKey('folders-new'));
      expect(button, findsNothing);

      await tapKey(tester, 'notes-switch-folders');
      expect(find.text('No folders yet'), findsOneWidget);
      expect(
        find.text('Make a folder, then pick the notes that go in it.'),
        findsOneWidget,
      );
      final search = tester.getRect(
        find.byKey(const ValueKey('sidebar-search-box')),
      );
      final box = tester.getRect(button);
      expect(box.left, search.left);
      expect(box.right, search.right);
      expect(box.top, greaterThan(search.bottom));
      expect(box.height, 32);

      await tapKey(tester, 'folders-new');
      await submit(tester, 'Ideas');
      expect(names(null), ['Ideas']);
      expect(pageTitle(tester), 'Ideas');
      expect(goldenPrefs.addNotesShown, isTrue);
      expect(panel, findsOneWidget);
      expect(onPage(find.text('Nothing in this folder yet.')), findsOneWidget);
      expect(
        onPage(
          find.text(
            'Tick notes on the right and add them, or drag notes here.',
          ),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('folder-page-holds')), findsNothing);

      await tapKey(tester, 'add-notes-close');
      expect(panel, findsNothing);
      expect(goldenPrefs.addNotesShown, isFalse);
      expect(
        onPage(find.text('Use Add notes, or drag notes here.')),
        findsOneWidget,
      );
      await tapKey(tester, 'folder-page-add-notes');
      expect(panel, findsOneWidget);
      expect(goldenPrefs.addNotesShown, isTrue);
    });

    testWidgets('where the page would keep less than 360 beside it, Add '
        'notes stands over its right edge instead', (tester) async {
      await pumpForGolden(
        tester,
        size: const Size(900, 700),
        brightness: Brightness.dark,
        withNote: false,
      );
      final work = goldenFolders.create('Work')!;
      goldenNotes.create(body: 'Dentist');
      await tester.pumpAndSettle();
      await openFolder(tester, work);

      final over = tester.getRect(panel);
      final whole = tester.getRect(page());
      expect(over.width, 320);
      expect(over.right, whole.right - 12);
      expect(over.top, whole.top + 12);
    });

    testWidgets('a notice centres on the page between the list and Add '
        'notes, at its right or over its right edge', (tester) async {
      await pumpWindow(tester);
      final work = goldenFolders.create('Work')!;
      final dentist = goldenNotes.create(body: 'Dentist');
      goldenNotes.create(body: 'Pricing ideas');
      await tester.pumpAndSettle();
      await openFolder(tester, work);
      await tester.tap(tick(dentist.id));
      await tester.pumpAndSettle();
      await tester.tap(addButton);
      await tester.pumpAndSettle();
      final notice = find.byKey(const ValueKey('toast-surface'));
      expect(notice, findsOneWidget);

      // At 1080 the page keeps 668 beside the list, too little for Add notes
      // to stand beside it, and 336 between the list and Add notes over it.
      for (final width in [1440.0, 1080.0]) {
        tester.view.physicalSize = Size(width, 900);
        await tester.pumpAndSettle();
        final list = tester.getRect(find.byType(Sidebar)).right;
        final add = tester.getRect(panel).left;
        expect(
          tester.getCenter(notice).dx,
          closeTo((list + add) / 2, 1),
          reason: '$width',
        );
        expect(
          tester.getRect(notice).left,
          greaterThanOrEqualTo(list + 16),
          reason: '$width',
        );
        expect(
          tester.getRect(notice).right,
          lessThanOrEqualTo(add - 16),
          reason: '$width',
        );
      }
      expect(tester.getRect(panel).right, tester.getRect(page()).right - 12);
    });

    testWidgets('a note dragged from the list and held over Folders turns '
        'the list to the tree, where a folder it is let go on files it', (
      tester,
    ) async {
      await pumpWindow(tester);
      final work = goldenFolders.create('Work')!;
      final dentist = goldenNotes.create(body: 'Dentist');
      await tester.pumpAndSettle();

      final drag = await grab(tester, dentist.id);
      expect(find.byType(NoteDragFeedback), findsOneWidget);
      expect(fade(tester, dentist.id), 0.45);
      await drag.moveTo(
        tester.getCenter(find.byKey(const ValueKey('notes-switch-folders'))),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(goldenPrefs.foldersShown, isFalse);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(goldenPrefs.foldersShown, isTrue);

      await drag.moveTo(
        tester.getCenter(find.byKey(ValueKey('folder-${work.id}'))),
      );
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
      expect(goldenFolders.tree.folderOf(dentist.id), work.id);
      expect(find.text('Moved to “Work”'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(goldenFolders.tree.folderOf(dentist.id), isNull);
    });

    testWidgets('picked notes drag together, each faded where it is listed, '
        'into the open folder or onto a folder card on its page; Undo puts '
        'each back in its own folder', (tester) async {
      await pumpWindow(tester);
      final work = goldenFolders.create('Work')!;
      final clients = goldenFolders.create('Clients', parentId: work.id)!;
      final personal = goldenFolders.create('Personal')!;
      final dentist = goldenNotes.create(body: 'Dentist');
      final gym = goldenNotes.create(body: 'Gym plan');
      final call = goldenNotes.create(body: 'Call with Arjun');
      goldenFolders
        ..file([gym.id], personal.id)
        ..file([call.id], work.id);
      await tester.pumpAndSettle();
      await openFolder(tester, work);
      await tapKey(tester, 'notes-switch-notes');
      final ring = find.byKey(const ValueKey('folder-page-drop'));
      final title = find.byKey(const ValueKey('folder-page-title'));

      // A note already in the folder has nowhere new to go there.
      var drag = await grab(tester, call.id);
      await drag.moveTo(tester.getCenter(title));
      await tester.pump();
      expect(ring, findsNothing);
      await drag.up();
      await tester.pumpAndSettle();
      expect(goldenFolders.tree.folderOf(call.id), work.id);

      // A press swept down the list picks the rows it crosses.
      final sweep = await tester.startGesture(
        tester.getCenter(listed(gym.id)),
        kind: PointerDeviceKind.mouse,
      );
      await sweep.moveBy(const Offset(0, 6));
      await tester.pump();
      await sweep.moveTo(tester.getCenter(listed(dentist.id)));
      await tester.pump();
      await sweep.up();
      await tester.pumpAndSettle();
      drag = await grab(tester, gym.id);
      expect(
        find.descendant(
          of: find.byType(NoteDragFeedback),
          matching: find.text('2 notes'),
        ),
        findsOneWidget,
      );
      expect(fade(tester, dentist.id), 0.45);
      expect(fade(tester, gym.id), 0.45);
      expect(fade(tester, call.id), 1);
      await drag.moveTo(tester.getCenter(title));
      await tester.pump();
      expect(ring, findsOneWidget);
      await drag.up();
      await tester.pumpAndSettle();
      expect(ring, findsNothing);
      expect(fade(tester, dentist.id), 1);
      expect(goldenFolders.tree.folderOf(dentist.id), work.id);
      expect(goldenFolders.tree.folderOf(gym.id), work.id);
      expect(find.text('Moved 2 notes to “Work”'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(goldenFolders.tree.folderOf(dentist.id), isNull);
      expect(goldenFolders.tree.folderOf(gym.id), personal.id);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      drag = await grab(tester, dentist.id);
      await drag.moveTo(
        tester.getCenter(find.byKey(ValueKey('folder-card-${clients.id}'))),
      );
      await tester.pump();
      expect(ring, findsNothing);
      await drag.up();
      await tester.pumpAndSettle();
      expect(goldenFolders.tree.folderOf(dentist.id), clients.id);
      expect(find.text('Moved to “Clients”'), findsOneWidget);
    });

    testWidgets(
      "a card clicked with a slip on its folder's page stays where it "
      'is, from the folder or one inside it, and of picked notes dropped '
      'on the page only the ones from outside move',
      (tester) async {
        await pumpWindow(tester);
        final work = goldenFolders.create('Work')!;
        final clients = goldenFolders.create('Clients', parentId: work.id)!;
        final brief = goldenNotes.create(body: 'Acme brief');
        final call = goldenNotes.create(body: 'Call with Arjun');
        final dentist = goldenNotes.create(body: 'Dentist');
        goldenFolders
          ..file([brief.id], clients.id)
          ..file([call.id], work.id);
        await tester.pumpAndSettle();
        await openFolder(tester, work);
        final page = find.byKey(ValueKey('folder-page-${work.id}'));
        final ring = find.byKey(const ValueKey('folder-page-drop'));
        for (final (note, slip) in [
          (brief, const Offset(2, 0)),
          (brief, const Offset(3, 1)),
          (call, const Offset(2, 0)),
        ]) {
          final click = await tester.startGesture(
            tester.getCenter(
              find.descendant(of: page, matching: rowOf(note.id)),
            ),
            kind: PointerDeviceKind.mouse,
          );
          await click.moveBy(slip);
          await tester.pump();
          expect(ring, findsNothing, reason: '${note.title} $slip');
          await click.up();
          await tester.pumpAndSettle();
        }
        expect(goldenFolders.tree.folderOf(brief.id), clients.id);
        expect(goldenFolders.tree.folderOf(call.id), work.id);
        expect(find.textContaining('Moved'), findsNothing);

        await tapKey(tester, 'notes-switch-notes');
        final sweep = await tester.startGesture(
          tester.getCenter(listed(dentist.id)),
          kind: PointerDeviceKind.mouse,
        );
        await sweep.moveBy(const Offset(0, 6));
        await tester.pump();
        await sweep.moveTo(tester.getCenter(listed(brief.id)));
        await tester.pump();
        await sweep.up();
        await tester.pumpAndSettle();
        final drag = await grab(tester, dentist.id);
        expect(
          find.descendant(
            of: find.byType(NoteDragFeedback),
            matching: find.text('3 notes'),
          ),
          findsOneWidget,
        );
        await drag.moveTo(
          tester.getCenter(find.byKey(const ValueKey('folder-page-title'))),
        );
        await tester.pump();
        expect(ring, findsOneWidget);
        await drag.up();
        await tester.pumpAndSettle();
        expect(goldenFolders.tree.folderOf(dentist.id), work.id);
        expect(goldenFolders.tree.folderOf(brief.id), clients.id);
        expect(goldenFolders.tree.folderOf(call.id), work.id);
        expect(find.text('Moved to “Work”'), findsOneWidget);
      },
    );

    testWidgets("a folder's row in the tree still takes a note up out of a "
        'folder inside it, dragged from the page', (tester) async {
      await pumpWindow(tester);
      final work = goldenFolders.create('Work')!;
      final clients = goldenFolders.create('Clients', parentId: work.id)!;
      final brief = goldenNotes.create(body: 'Acme brief');
      goldenFolders.file([brief.id], clients.id);
      await tester.pumpAndSettle();
      await openFolder(tester, work);
      final drag = await tester.startGesture(
        tester.getCenter(
          find.descendant(
            of: find.byKey(ValueKey('folder-page-${work.id}')),
            matching: rowOf(brief.id),
          ),
        ),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(const Offset(12, 2));
      await tester.pump();
      await drag.moveTo(
        tester.getCenter(find.byKey(ValueKey('folder-${work.id}'))),
      );
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
      expect(goldenFolders.tree.folderOf(brief.id), work.id);
      expect(find.text('Moved to “Work”'), findsOneWidget);
    });

    testWidgets("one of Add notes' ticked rows drags every ticked note with "
        'it, and an unticked row goes alone', (tester) async {
      await pumpWindow(tester);
      final work = goldenFolders.create('Work')!;
      final personal = goldenFolders.create('Personal')!;
      final dentist = goldenNotes.create(body: 'Dentist');
      final groceries = goldenNotes.create(body: 'Groceries');
      final books = goldenNotes.create(body: 'Book list');
      final gifts = goldenNotes.create(body: 'Gift ideas');
      await tester.pumpAndSettle();
      await openFolder(tester, work);
      for (final note in [dentist, groceries, books]) {
        await tester.tap(tick(note.id));
        await tester.pump();
      }
      final personalRow = find.byKey(ValueKey('folder-${personal.id}'));
      Future<void> dragRow(String noteId, String count) async {
        final drag = await tester.startGesture(
          tester.getCenter(tick(noteId)),
          kind: PointerDeviceKind.mouse,
        );
        await drag.moveBy(const Offset(12, 2));
        await tester.pump();
        expect(
          find.descendant(
            of: find.byType(NoteDragFeedback),
            matching: find.text(count),
          ),
          findsOneWidget,
          reason: count,
        );
        await drag.moveTo(tester.getCenter(personalRow));
        await tester.pump();
        await drag.up();
        await tester.pumpAndSettle();
      }

      await dragRow(groceries.id, '3 notes');
      for (final note in [dentist, groceries, books]) {
        expect(goldenFolders.tree.folderOf(note.id), personal.id);
      }
      expect(goldenFolders.tree.folderOf(gifts.id), isNull);
      expect(find.text('Moved 3 notes to “Personal”'), findsOneWidget);

      await dragRow(gifts.id, 'Gift ideas');
      expect(goldenFolders.tree.folderOf(gifts.id), personal.id);
    });

    testWidgets('filing notes counts only the ones that move, and Undo puts '
        'back only those', (tester) async {
      await pumpWindow(tester);
      final work = goldenFolders.create('Work')!;
      final personal = goldenFolders.create('Personal')!;
      final dentist = goldenNotes.create(body: 'Dentist');
      final gym = goldenNotes.create(body: 'Gym plan');
      final call = goldenNotes.create(body: 'Call with Arjun');
      goldenFolders
        ..file([gym.id], personal.id)
        ..file([call.id], work.id);
      await tester.pumpAndSettle();
      fileNotes(tester.element(find.byType(Sidebar)), goldenFolders, [
        dentist.id,
        gym.id,
        call.id,
      ], work.id);
      await tester.pumpAndSettle();
      expect(find.text('Moved 2 notes to “Work”'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(goldenFolders.tree.folderOf(dentist.id), isNull);
      expect(goldenFolders.tree.folderOf(gym.id), personal.id);
      expect(goldenFolders.tree.folderOf(call.id), work.id);
    });

    testWidgets('Add notes works from the keyboard: Tab reaches a note, Space '
        'ticks it, and Enter on Add adds it', (tester) async {
      await pumpWindow(tester);
      final work = goldenFolders.create('Work')!;
      final dentist = goldenNotes.create(body: 'Dentist');
      await tester.pumpAndSettle();
      await openFolder(tester, work);
      await tester.tap(find.byKey(const ValueKey('add-notes-field')));
      await tester.pumpAndSettle();

      Future<void> tabTo(Finder target) async {
        bool focused() {
          final at = FocusManager.instance.primaryFocus?.context;
          return at != null &&
              find
                  .descendant(
                    of: target,
                    matching: find.byElementPredicate(
                      (element) => identical(element, at),
                    ),
                  )
                  .evaluate()
                  .isNotEmpty;
        }

        for (var step = 0; step < 8 && !focused(); step++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pumpAndSettle();
        }
        expect(focused(), isTrue);
      }

      await tabTo(tick(dentist.id));
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(addLabel(tester), 'Add 1 note');
      await tabTo(addButton);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(goldenFolders.tree.folderOf(dentist.id), work.id);
      expect(find.text('Added to “Work”'), findsOneWidget);
    });

    testWidgets('at 2× text, Add notes, its rows and New folder keep their '
        'words whole', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpWindow(tester);
      final work = goldenFolders.create('Work')!;
      final dentist = goldenNotes.create(body: 'Dentist');
      await tester.pumpAndSettle();
      await openFolder(tester, work);
      await tester.tap(tick(dentist.id));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getSize(tick(dentist.id)).height, greaterThan(48));
      for (final finder in [
        find.byKey(const ValueKey('folders-new')),
        tick(dentist.id),
        addButton,
      ]) {
        final box = tester.getRect(finder);
        for (final text in tester.widgetList<Text>(
          find.descendant(of: finder, matching: find.byType(Text)),
        )) {
          final rect = tester.getRect(find.byWidget(text));
          expect(box.contains(rect.topLeft), isTrue, reason: text.data);
          expect(
            box.inflate(0.5).contains(rect.bottomRight),
            isTrue,
            reason: text.data,
          );
        }
      }
    });

    testWidgets('a note in the tree lights its whole row under the pointer, '
        'not only its words', (tester) async {
      await pumpWindow(tester);
      final work = goldenFolders.create('Work')!;
      final call = goldenNotes.create(body: 'Call');
      goldenFolders.file([call.id], work.id);
      goldenPrefs.setFolderOpen(work.id, true);
      await tester.pumpAndSettle();
      await tapKey(tester, 'notes-switch-folders');
      final face = find.descendant(
        of: rowOf(call.id),
        matching: find.byType(TreeNoteFace),
      );
      final width = tester.getSize(face).width;
      expect(width, greaterThan(200));

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(face));
      addTearDown(mouse.removePointer);
      await tester.pumpAndSettle();
      expect(tester.getSize(face).width, width);

      // The notes list's rows and cards keep theirs too.
      await mouse.moveTo(Offset.zero);
      await tapKey(tester, 'notes-switch-notes');
      final listFace = find.descendant(
        of: listed(call.id),
        matching: find.byWidgetPredicate(
          (widget) => widget is NoteCardFace || widget is NoteListRowFace,
        ),
      );
      final listWidth = tester.getSize(listFace).width;
      await mouse.moveTo(tester.getCenter(listFace));
      await tester.pumpAndSettle();
      expect(tester.getSize(listFace).width, listWidth);
    });
  });
}
