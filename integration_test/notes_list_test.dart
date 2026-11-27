// The desktop Notes list on a real Mac: the whole app over notes kept in
// memory, in a 1100 × 640 window, which fits the CI runner's screen.
//
//   flutter drive --driver test_driver/integration_test.dart \
//     --target integration_test/notes_list_test.dart -d macos \
//     --dart-define=KAPYNOTES_SYNC=false
//
// It runs the device checks that three 1.35 changes still owe:
// - Ask Kapy left of New note in the list's bar (#225): where it sits, its
//   name on hover, and a click that opens Kapy AI on the note shown.
// - New beside show-list while the list is hidden (#254): it makes a note or
//   a drawing, by click and by Tab and Enter.
// - A row's screen-reader actions while notes are picked (#239), and a note
//   for a later day staying off the list until its day (KAP-302). VoiceOver can't run on a CI runner, so the test reads the
//   actions from the app's semantics tree, which is what the Mac hands
//   VoiceOver, and does them from there.
// - D03, D04 and D07 of the final boards, over the boards' notes in a
//   1440 × 900 window, for the design check to hold against them.
// - KAPY-72's folder boards, d1 to d6, in the same window: Add notes beside
//   a folder, notes dragged onto a folder and into the open one, Undo, a new
//   folder, the empty states, and a tree note's whole-row hover.
// - Move to folder… on a row's menu (KAP-377): its list opens where the menu
//   was, from the same corner, on the board and in a 400 wide window.
// - ⌘F's find bar in a note (KAP-389): no matches, the second of three, and
//   the match esc leaves selected.
// - KAP-408's calm list: the View menu beside the search, the one chip for
//   what narrows the list, the checklist pie, and the list at 400 px.
// Each state is taken light and dark, as screenshots in build/screenshots;
// the boards' states dark only, as the boards draw them, with d1 and d3
// light too.
import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/semantics.dart'
    show CustomSemanticsAction, SemanticsAction, SemanticsNode;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/appearance.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/day_tabs.dart';
import 'package:kapy_notes/data/folders.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note_days.dart';
import 'package:kapy_notes/data/note_drawing.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/tags.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/ui/checklist_pie.dart';
import 'package:kapy_notes/ui/context_menu.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/editor/note_field.dart';
import 'package:kapy_notes/ui/editor/note_header.dart' show NoteMetaRow;
import 'package:kapy_notes/ui/editor_panes.dart'
    show EditorPaneFrame, NoteDragFeedback;
import 'package:kapy_notes/ui/folders_ui.dart' show FolderPage, TreeNoteFace;
import 'package:kapy_notes/ui/note_tabs.dart';
import 'package:kapy_notes/ui/notes_list.dart';
import 'package:kapy_notes/ui/page_toolbar.dart';
import 'package:kapy_notes/ui/sidebar.dart';
import 'package:kapy_notes/ui/sidebar_timestamp.dart';
import 'package:kapy_notes/ui/tag_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

import '../test/fake_kapy_ai.dart';
import '../test/kapy_icon_finder.dart';
import 'rates_support.dart';
import 'screenshot.dart';
import 'sharing_support.dart' show pumpUntil, shown;

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'notes-list-integration.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  kapyAiAvailable = true;

  const mouse = PointerDeviceKind.mouse;
  late NotesStore notes;
  FolderStore? folderStore;
  late LayoutPrefs prefs;
  late ShortcutPrefs shortcuts;

  /// The app with the list beside the page in a window [size] wide, over
  /// [bodies] written a minute apart, oldest first; [prepare] then tags them
  /// or gives them days, and [file] puts them in folders.
  Future<void> launch(
    WidgetTester tester, {
    required List<String> bodies,
    void Function(TagStore tags, NoteDayStore days)? prepare,
    void Function(FolderStore folders)? file,
    Size size = const Size(1100, 640),
  }) async {
    if (AppPlatform.isDesktop) {
      await windowManager.ensureInitialized();
      await windowManager.setBounds(Offset.zero & size);
    }
    final store = _MemoryStore();
    store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
    var clock = DateTime.now().subtract(const Duration(hours: 1));
    notes = NotesStore(store, now: () => clock);
    final tags = TagStore(store);
    final days = NoteDayStore(store);
    final dayTabs = DayTabsStore(store);
    prefs = LayoutPrefs(store)..load();
    shortcuts = ShortcutPrefs(store)..load();
    await notes.load();
    await tags.load();
    await days.load();
    await dayTabs.load();
    final folders = file == null ? null : FolderStore(store);
    await folders?.load();
    for (final body in bodies) {
      clock = clock.add(const Duration(minutes: 1));
      notes.create(body: body);
    }
    clock = DateTime.now();
    prepare?.call(tags, days);
    folderStore = folders;
    if (folders != null) file!(folders);
    final tasks = TaskLibrary(
      notes: notes,
      store: store,
      storage: MemoryDocStorage(),
    );
    await tasks.load();
    if (!prefs.sidebarVisible) prefs.toggleSidebar();
    await tester.pumpWidget(
      KapyNotesApp(
        store: store,
        notes: notes,
        rates: offlineRates(store),
        prefs: prefs,
        shortcuts: shortcuts,
        tags: tags,
        days: days,
        dayTabs: dayTabs,
        tasks: tasks,
        folders: folders,
        kapyAi: FakeKapyAi(),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));
  }

  String id(String title) =>
      notes.allNotes.singleWhere((note) => note.title == title).id;

  Future<void> shot(WidgetTester tester, String name) async {
    for (final mode in [AppearanceMode.light, AppearanceMode.dark]) {
      prefs.appearance = mode;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: name);
      await screenshot('notes-list-$name-${mode.name}');
    }
  }

  Future<void> click(WidgetTester tester, Finder finder) async {
    await tester.tap(finder, kind: mouse);
    await tester.pumpAndSettle();
  }

  /// Rests the mouse on [finder] for as long as a tooltip waits, then leaves
  /// it there; the caller takes it away. It is the mouse the clicks use, so
  /// it moves there rather than arriving a second time.
  Future<TestGesture> hover(WidgetTester tester, Finder finder) async {
    final pointer = await tester.createGesture(kind: mouse);
    await pointer.moveTo(tester.getCenter(finder));
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    await tester.pumpAndSettle();
    return pointer;
  }

  Finder row(String title) => find.widgetWithText(NoteRow, title);

  testWidgets('Ask Kapy sits left of New note, names itself, and opens '
      'Kapy AI on the note shown', (tester) async {
    await launch(tester, bodies: ['Trip budget\nFlights for two']);
    final ask = find.byKey(const ValueKey('sidebar-ask-kapy'));
    final newNote = find.byKey(const ValueKey('sidebar-new-note'));
    expect(ask, findsOneWidget);
    expect(tester.getRect(ask).right, tester.getRect(newNote).left);
    expect(
      tester.getCenter(ask).dy,
      moreOrLessEquals(tester.getCenter(newNote).dy, epsilon: 0.5),
    );

    final tip = tester
        .widget<Tooltip>(
          find.descendant(of: ask, matching: find.byType(Tooltip)),
        )
        .message!;
    expect(tip, startsWith('Ask Kapy  '));
    final pointer = await hover(tester, ask);
    expect(find.text(tip), findsOneWidget);
    await shot(tester, 'ask-kapy');
    await pointer.removePointer();

    final panel = find.byKey(const ValueKey('kapy-ai-panel'));
    await click(tester, ask);
    expect(panel, findsOneWidget);
    expect(find.text('This note · Trip budget'), findsOneWidget);
    await shot(tester, 'ask-kapy-panel');

    await click(tester, ask);
    expect(panel, findsOneWidget, reason: 'a second click keeps it open');
  });

  testWidgets('with the list hidden, New beside show-list makes what the '
      'space holds, by click and by keyboard', (tester) async {
    final semantics = tester.ensureSemantics();
    await launch(tester, bodies: ['Groceries\nOat milk, lemons']);
    final pageNew = find.byKey(const ValueKey('page-new'));
    final showList = find.byKey(const ValueKey('page-show-list'));
    expect(pageNew, findsNothing);
    await click(tester, find.byKey(const ValueKey('sidebar-hide')));

    void besideShowList(String label) {
      expect(pageNew, findsOneWidget);
      expect(tester.getSize(pageNew), tester.getSize(showList));
      expect(
        tester.getTopLeft(pageNew).dx - tester.getTopRight(showList).dx,
        4,
      );
      expect(tester.getCenter(pageNew).dy, tester.getCenter(showList).dy);
      expect(tester.getSemantics(pageNew).label, label);
    }

    besideShowList('New note');
    final pointer = await hover(tester, pageNew);
    expect(
      find.text(
        SidebarWindowBar.newTooltip(
          'note',
          shortcuts.hintFor(ShortcutAction.newNote),
        ),
      ),
      findsOneWidget,
    );
    await shot(tester, 'new');
    await pointer.removePointer();

    var before = notes.notes.length;
    await click(tester, pageNew);
    expect(notes.notes, hasLength(before + 1));
    expect(notes.notes.first.isDrawing, isFalse);

    await click(tester, find.byKey(const ValueKey('rail-drawings')));
    besideShowList('New drawing');
    await click(tester, pageNew);
    expect(notes.notes.first.isDrawing, isTrue);
    await shot(tester, 'new-drawing');

    await click(tester, find.byKey(const ValueKey('rail-notes')));
    final plus = find.descendant(
      of: pageNew,
      matching: findKapyIcon(KapyIcons.addRounded),
    );
    bool focused() => Focus.of(tester.element(plus)).hasPrimaryFocus;
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    for (var tabs = 0; !focused() && tabs < 50; tabs++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(focused(), isTrue);
    await shot(tester, 'new-focused');
    before = notes.notes.length;
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(notes.notes, hasLength(before + 1));

    await click(tester, showList);
    expect(pageNew, findsNothing);
    semantics.dispose();
  });

  testWidgets('while notes are picked, a row offers its right-click menu as '
      'screen-reader actions, and its Delete takes the row with the picks', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await launch(
      tester,
      bodies: ['First', 'Second', 'Third', 'Fourth', 'Fifth'],
    );

    List<String> picked() => [
      for (final note in tester.widgetList<NoteRow>(find.byType(NoteRow)))
        if (note.selecting && note.checked) note.note.title,
    ];
    SemanticsNode node(String title) => tester.getSemantics(
      find
          .descendant(of: row(title), matching: find.byType(GestureDetector))
          .first,
    );
    Map<String, int> actions(String title) => {
      for (final action
          in node(title).getSemanticsData().customSemanticsActionIds ??
              const <int>[])
        CustomSemanticsAction.getAction(action)!.label!: action,
    };

    await click(tester, row('Fifth'));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await click(tester, row('Fourth'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(picked(), ['Fifth', 'Fourth']);

    // A row not picked offers what its right click offers, which picks it.
    final offered = actions('Third').keys.toList();
    expect(offered, contains('Delete 3 notes…'));
    await tester.tap(row('Third'), buttons: kSecondaryButton, kind: mouse);
    await tester.pumpAndSettle();
    expect(
      offered,
      unorderedEquals([
        for (final item in tester.widgetList<KapyMenuActionRow>(
          find.byType(KapyMenuActionRow),
        ))
          item.action.label,
      ]),
    );
    await shot(tester, 'picked-menu');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(picked(), ['Fifth', 'Fourth', 'Third']);

    // Its Delete, done as VoiceOver does it, picks the row and deletes it
    // with the picks.
    final first = node('First');
    first.owner!.performAction(
      first.id,
      SemanticsAction.customAction,
      actions('First')['Delete 4 notes…'],
    );
    await tester.pumpAndSettle();
    expect(picked(), ['Fifth', 'Fourth', 'Third', 'First']);
    expect(find.text('Delete 4 notes?'), findsOneWidget);
    await shot(tester, 'picked-delete');
    await tester.tap(find.byKey(const ValueKey('confirm-delete')), kind: mouse);
    // The toast goes after 1.8 s, so it is looked for as it arrives rather
    // than once everything has settled.
    final toast = find.text('4 notes deleted');
    for (var tries = 0; toast.evaluate().isEmpty && tries < 40; tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    }
    expect(toast, findsOneWidget);
    expect(notes.notes.map((note) => note.title), ['Second']);
    semantics.dispose();
  });

  testWidgets("a note for a later day stays off the list's days, and grouped "
      'by tag it keeps its place under No tag', (tester) async {
    await launch(
      tester,
      bodies: ['Renewal notes\nRead the contract', 'Standup\nShip it'],
      prepare: (tags, days) {
        final now = notes.now();
        days.setDay(
          id('Renewal notes'),
          DateTime(now.year, now.month, now.day + 2),
        );
      },
    );
    final list = find.byType(Sidebar);
    expect(find.byKey(const ValueKey('sidebar-group-Upcoming')), findsNothing);
    expect(
      find.descendant(of: list, matching: find.text('Renewal notes')),
      findsNothing,
    );
    await shot(tester, 'later-day-by-date');

    await click(tester, find.byKey(const ValueKey('notes-view')));
    await click(tester, find.byKey(const ValueKey('notes-grouping-byTag')));
    for (final title in ['Standup', 'Renewal notes']) {
      expect(
        find.descendant(of: list, matching: find.text(title)),
        findsOneWidget,
        reason: title,
      );
    }
    await shot(tester, 'later-day-by-tag');
  });

  testWidgets("KAP-364: grouped by day, Drawings counts only what it lists, "
      'so a drawing for the day after tomorrow is out of its count, and A to '
      'Z lists and counts it', (tester) async {
    await launch(
      tester,
      bodies: ['Standup\nShip it'],
      prepare: (tags, days) {
        final shelf = notes.create(drawing: true);
        notes.updateDrawing(shelf.id, NoteDrawing.empty, title: 'Shelf plan');
        final deck = notes.create(drawing: true);
        notes.updateDrawing(deck.id, NoteDrawing.empty, title: 'Deck flow');
        final now = notes.now();
        days.setDay(shelf.id, DateTime(now.year, now.month, now.day + 2));
      },
    );
    await click(tester, find.byKey(const ValueKey('rail-drawings')));
    final list = find.byType(Sidebar);
    Finder listed(String title) =>
        find.descendant(of: list, matching: find.text(title));
    int count() =>
        tester.widget<SidebarWindowBar>(find.byType(SidebarWindowBar)).count;
    expect(listed('Shelf plan'), findsNothing);
    expect(listed('Deck flow'), findsOneWidget);
    expect(count(), 1);
    await shot(tester, 'kap364-drawings-by-date');

    prefs.notesGrouping = NotesGrouping.aToZ;
    await tester.pumpAndSettle();
    expect(listed('Shelf plan'), findsOneWidget);
    expect(count(), 2);
    await shot(tester, 'kap364-drawings-a-to-z');
  });

  /// The boards' window, D03, D04 and D07 alike.
  const boardSize = Size(1440, 900);
  late Map<String, String> boardTags;

  /// The boards' notes, dark, in their window: Call with Arjun and Renewal
  /// notes in Work › Clients › Acme, Renewal notes on the day after
  /// tomorrow, two pinned, and the boards' six tags. The boards' Wed 19 and
  /// Fri 21 are the runner's today and the day after tomorrow.
  Future<void> board(WidgetTester tester) async {
    await launch(
      tester,
      size: boardSize,
      bodies: [
        'Lisbon budget\n180 EUR + 232 EUR',
        'Reading list\nThe Overstory, Piranesi',
        'Spare keys\nNadia has the spare set',
        'Pricing ideas\n1,799 INR a seat',
        'Gym plan\nVoice note',
        'Launch checklist\nWrite release notes',
        'Standup notes\nFinish the pricing page',
        'Renewal notes\nFor the call with Acme on Friday.\n'
            '- [ ] Send the renewal scope\n- [ ] Read the signed contract',
        'Quote for the deck\n40 seats × 12 = 480 a month',
        'Call with Arjun\nPricing page by Friday. He wants the annual plan '
            'shown first, and the invoice split across two months so the '
            'first one is smaller.\n- [ ] Send the deck',
        'Morning pages\nThree things: the deck, the renewal, the gym',
      ],
      prepare: (tags, days) {
        final now = notes.now();
        days.setDay(
          id('Renewal notes'),
          DateTime(now.year, now.month, now.day + 2),
        );
        notes
          ..togglePinned(id('Reading list'))
          ..togglePinned(id('Lisbon budget'));
        boardTags = {
          for (final (name, titles) in [
            (
              'Work',
              [
                'Call with Arjun',
                'Quote for the deck',
                'Standup notes',
                'Launch checklist',
                'Pricing ideas',
                'Renewal notes',
              ],
            ),
            ('Money', ['Lisbon budget', 'Pricing ideas']),
            ('Home', ['Spare keys', 'Gym plan']),
            ('Ideas', ['Morning pages', 'Reading list']),
            ('Travel', ['Lisbon budget', 'Reading list']),
            ('Acme', ['Call with Arjun']),
          ])
            name: () {
              final tag = tags.create(name)!.id;
              for (final title in titles) {
                tags.addTag(id(title), tag);
              }
              return tag;
            }(),
        };
      },
      file: (folders) {
        final work = folders.create('Work')!;
        final clients = folders.create('Clients', parentId: work.id)!;
        final acme = folders.create('Acme', parentId: clients.id)!;
        folders.file([id('Call with Arjun'), id('Renewal notes')], acme.id);
      },
    );
    // GitHub's Mac runner has a screen smaller than the boards' window, and
    // macOS keeps a window on its screen, so the view is held at the boards'
    // size as well: the shot draws the app's layers, not the screen.
    tester.view.physicalSize = boardSize * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    prefs.appearance = AppearanceMode.dark;
    await tester.pumpAndSettle();
  }

  /// A card under a day heading gives only its time, after its ring where it
  /// has one, as D03 and D04 draw them ("9:12", "○ 8:55"); a pinned card
  /// keeps its day.
  void expectBoardDates(WidgetTester tester) {
    Finder card(String title) =>
        find.descendant(of: row(title), matching: find.byType(NoteCardFace));
    String time(String title) => SidebarTimestamp.clock(
      prefs.displayTime(
        notes.allNotes.singleWhere((note) => note.title == title).updatedAt,
      ),
    );
    for (final title in ['Call with Arjun', 'Quote for the deck']) {
      expect(tester.widget<NoteCardFace>(card(title)).date, time(title));
    }
    expect(
      tester
          .getRect(
            find.descendant(
              of: card('Call with Arjun'),
              matching: find.byType(ChecklistPie),
            ),
          )
          .right,
      lessThan(
        tester
            .getRect(
              find.descendant(
                of: card('Call with Arjun'),
                matching: find.text(time('Call with Arjun')),
              ),
            )
            .left,
      ),
    );
    expect(
      tester.widget<NoteCardFace>(card('Reading list')).date,
      'Today, ${time('Reading list')}',
    );
  }

  Future<void> boardShot(WidgetTester tester, String name) async {
    expect(tester.getSize(find.byType(KapyNotesApp)), boardSize, reason: name);
    expect(tester.takeException(), isNull, reason: name);
    await screenshot('board-$name-dark');
  }

  final openNote = find.descendant(
    of: find.byType(NoteEditor),
    matching: find.byType(NoteField),
  );

  testWidgets("KAP-408's calm list: the View menu beside the search holds "
      'Show, Media, Tags, Group by and Layout, one chip says what narrows the '
      'list, and the list keeps working at 400 px', (tester) async {
    await board(tester);
    final list = find.byType(Sidebar);
    final view = find.byKey(const ValueKey('notes-view'));
    final menu = find.byKey(const ValueKey('notes-filter-menu'));
    final chip = find.byKey(const ValueKey('notes-filter-chip'));
    expect(
      find.descendant(of: list, matching: find.text('New note')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('sidebar-space-count')), findsNothing);
    expect(
      tester.getCenter(view).dy,
      moreOrLessEquals(
        tester.getCenter(find.byKey(const ValueKey('sidebar-search-box'))).dy,
        epsilon: 0.5,
      ),
    );

    await click(tester, view);
    await click(tester, find.byKey(const ValueKey('notes-layout-list')));
    expect(menu, findsNothing);
    expect(
      find.descendant(of: list, matching: find.byType(NoteCardFace)),
      findsNothing,
    );
    // A checklist is the pie before a row's date, never words under it.
    expect(
      find.descendant(of: list, matching: find.textContaining(' done')),
      findsNothing,
    );
    await shot(tester, 'calm-list');

    await click(tester, view);
    expect(menu, findsOneWidget);
    await shot(tester, 'calm-list-view');
    await click(tester, find.byKey(const ValueKey('media-filter-video')));
    await click(tester, find.byKey(const ValueKey('notes-filter-when')));
    await click(
      tester,
      find.byKey(const ValueKey('notes-filter-when-thisWeek')),
    );
    expect(chip, findsOneWidget);
    expect(
      find.descendant(
        of: chip,
        matching: find.text('Voice, Image · This week'),
      ),
      findsOneWidget,
    );
    await shot(tester, 'calm-list-chip');

    const narrow = Size(400, 720);
    await windowManager.setBounds(Offset.zero & narrow);
    tester.view.physicalSize = narrow * tester.view.devicePixelRatio;
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // At 400 px the list folds away, and comes back over the page.
    await click(tester, find.byKey(const ValueKey('page-show-list')));
    await shot(tester, 'calm-list-narrow');
    await click(tester, view);
    expect(tester.getRect(menu).right, lessThanOrEqualTo(narrow.width));
    await shot(tester, 'calm-list-narrow-view');
    await click(tester, find.byKey(const ValueKey('notes-filter-when')));
    expect(menu, findsNothing);
    expect(find.byKey(const ValueKey('notes-view-back')), findsOneWidget);
    await shot(tester, 'calm-list-narrow-when');
    await click(tester, find.byKey(const ValueKey('notes-view-back')));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await click(tester, chip);
    expect(chip, findsNothing);
    expect(
      find.descendant(of: list, matching: find.text('Call with Arjun')),
      findsOneWidget,
    );
  });

  testWidgets("D03's board: a second card's menu opens it in a new tab", (
    tester,
  ) async {
    await board(tester);
    expectBoardDates(tester);
    await click(tester, row('Call with Arjun'));
    final tabs = find.byType(NoteTabRow);
    expect(tabs, findsNothing, reason: 'one note open has no tab row');

    await tester.tap(
      row('Quote for the deck'),
      buttons: kSecondaryButton,
      kind: mouse,
    );
    await tester.pumpAndSettle();
    final menu = [
      for (final item in tester.widgetList<KapyMenuActionRow>(
        find.byType(KapyMenuActionRow),
      ))
        item.action.label,
    ];
    expect(menu.take(2), ['Open in new tab', 'Open to the side']);
    expect(menu, containsAll(['Pin note', 'Delete note…']));
    expect(
      tester
          .widget<KapyMenuActionRow>(
            find.widgetWithText(KapyMenuActionRow, 'Archive note'),
          )
          .action
          .hint,
      '⌘⌫',
    );
    await boardShot(tester, 'd03-menu');

    await click(
      tester,
      find.widgetWithText(KapyMenuActionRow, 'Open in new tab'),
    );
    expect(find.byType(KapyMenuActionRow), findsNothing);
    expect(tabs, findsOneWidget);
    expect(
      find.descendant(
        of: tabs,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith('note-tab-'),
        ),
      ),
      findsNWidgets(2),
    );
    for (final title in ['Call with Arjun', 'Quote for the deck']) {
      expect(
        find.descendant(of: tabs, matching: find.text(title)),
        findsOneWidget,
        reason: title,
      );
    }
    await boardShot(tester, 'd03-two-tabs');
  });

  // The Friday note (PFP-0): the board picks Fri 21 in the week and its note
  // opens, though the list leaves it out until its day.
  testWidgets("The Friday note's board: the day after tomorrow picked in the "
      'week opens its note, which stays off the list', (tester) async {
    await board(tester);
    final now = notes.now();
    final friday = DateTime(now.year, now.month, now.day + 2);
    final list = find.byType(Sidebar);
    final today = find.byKey(const ValueKey('sidebar-group-Today'));
    expect(find.byKey(const ValueKey('sidebar-group-Upcoming')), findsNothing);
    expect(row('Renewal notes'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(
          ValueKey('day-strip-${friday.year}-${friday.month}-${friday.day}'),
        ),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Container &&
              widget.decoration is BoxDecoration &&
              (widget.decoration! as BoxDecoration).shape == BoxShape.circle,
        ),
      ),
      findsOneWidget,
    );

    await click(
      tester,
      find.byKey(
        ValueKey('day-strip-${friday.year}-${friday.month}-${friday.day}'),
      ),
    );
    expect(row('Renewal notes'), findsNothing);
    expect(today, findsOneWidget, reason: 'the list stays whole');
    expect(
      find.descendant(of: list, matching: find.text('Call with Arjun')),
      findsOneWidget,
    );
    expect(
      tester.widget<NoteField>(openNote).controller.text,
      startsWith('Renewal notes\n'),
    );
    final path = find.byType(NotePathLine);
    expect(path, findsOneWidget);
    for (final folder in ['Work', 'Clients', 'Acme']) {
      expect(
        find.descendant(of: path, matching: find.text(folder)),
        findsOneWidget,
        reason: folder,
      );
    }
    expect(
      tester.getTopLeft(path).dy,
      lessThan(tester.getTopLeft(openNote).dy),
    );
    await boardShot(tester, 'pfp-friday-note');
  });

  // A day picked in the week (KAP-339): its notes take the place of the
  // tabs, one to a tab in the day's own order where it has one, pinned first
  // (KAP-348), and otherwise the earliest written first, with the first in
  // front, and a click on the day picked brings back the tabs from before.
  testWidgets("A day's notes as the tabs: today picked opens its notes, and "
      'a second click brings back the tab from before', (tester) async {
    await board(tester);
    await click(tester, row('Call with Arjun'));
    final now = notes.now();
    final today = find.byKey(
      ValueKey('day-strip-${now.year}-${now.month}-${now.day}'),
    );
    final tabs = find.byType(NoteTabRow);

    await click(tester, today);
    expect(tabs, findsOneWidget);
    final titles = [
      for (final tab in tester.widget<NoteTabRow>(tabs).tabs) tab.title,
    ];
    expect(titles, contains('Reading list'));
    expect(titles, isNot(contains('Renewal notes')));
    expect(
      tester.widget<NoteField>(openNote).controller.text,
      startsWith('${titles.first}\n'),
    );
    await boardShot(tester, 'day-tabs');

    await click(tester, today);
    expect(tabs, findsNothing);
    expect(
      tester.widget<NoteField>(openNote).controller.text,
      startsWith('Call with Arjun\n'),
    );
  });

  // A day's tab pinned from its menu (KAP-348): it comes to the front with a
  // pin in its icon's place and keeps its ×, and Unpin tab gives it back its
  // icon where it is. The menu is the tab in front's, so it shows Close tab's
  // keys.
  testWidgets("A day's tab menu: Pin tab brings the tab to the front with a "
      'pin, and Unpin tab takes the pin away', (tester) async {
    await board(tester);
    await click(tester, row('Call with Arjun'));
    final now = notes.now();
    await click(
      tester,
      find.byKey(ValueKey('day-strip-${now.year}-${now.month}-${now.day}')),
    );
    final tabs = find.byType(NoteTabRow);
    List<NoteTab> shown() => tester.widget<NoteTabRow>(tabs).tabs;
    Finder tab(String title) =>
        find.descendant(of: tabs, matching: find.text(title));
    final title = shown()[1].title;
    expect([for (final each in shown()) each.pinned], everyElement(isFalse));

    await click(tester, tab(title));
    await tester.tap(tab(title), buttons: kSecondaryButton, kind: mouse);
    await tester.pumpAndSettle();
    expect(find.text('Pin tab'), findsOneWidget);
    expect(find.text('Close tab'), findsOneWidget);
    await boardShot(tester, 'day-tab-menu');

    await click(tester, find.text('Pin tab'));
    expect(shown().first.title, title);
    expect(shown().first.pinned, isTrue);
    expect(
      tester.widget<NoteField>(openNote).controller.text,
      startsWith('$title\n'),
    );
    await boardShot(tester, 'day-tab-pinned');

    await tester.tap(tab(title), buttons: kSecondaryButton, kind: mouse);
    await tester.pumpAndSettle();
    await click(tester, find.text('Unpin tab'));
    expect(shown().first.title, title);
    expect(shown().first.pinned, isFalse);
    await boardShot(tester, 'day-tab-unpinned');
  });

  testWidgets("D07's board: + Tag lists every tag in its colour, the note's "
      'own ticked', (tester) async {
    await board(tester);
    await click(tester, row('Call with Arjun'));
    await click(tester, find.byKey(const ValueKey('note-add-tag')));
    final picker = find.byKey(const ValueKey('tag-picker'));
    expect(picker, findsOneWidget);
    expect(
      find.descendant(of: picker, matching: find.byType(TagDot)),
      findsNWidgets(boardTags.length),
    );
    for (final MapEntry(key: name, value: tag) in boardTags.entries) {
      final ticked = find.descendant(
        of: find.byKey(ValueKey('tag-row-$tag')),
        matching: findKapyIcon(KapyIcons.checkRounded),
      );
      expect(
        ticked,
        name == 'Work' || name == 'Acme' ? findsOneWidget : findsNothing,
        reason: name,
      );
    }
    await boardShot(tester, 'd07-tag-picker');
  });

  // KAPY-72's folder boards on p-2-0, d1 to d6, over the boards' notes: Add
  // notes beside a folder, the notes it adds and their Undo, notes dragged
  // onto a folder in the tree and into the open folder, a new folder, and
  // what each part says when it has nothing to show. Each state is taken
  // dark, and d1 and d3 light too, as the boards draw them.
  Finder listed(String title) =>
      find.descendant(of: find.byType(Sidebar), matching: row(title));
  Finder tick(String title) => find.byKey(ValueKey('add-note-${id(title)}'));
  final addNotes = find.byKey(const ValueKey('add-notes'));

  Folder folderNamed(String name, [String? parentId]) => folderStore!.tree
      .childrenOf(parentId)
      .singleWhere((folder) => folder.name == name);

  Future<void> showFolder(WidgetTester tester, Folder folder) async {
    for (
      var at = folder.parentId;
      at != null;
      at = folderStore!.tree.byId(at)?.parentId
    ) {
      prefs.setFolderOpen(at, true);
    }
    if (!prefs.foldersShown) {
      await click(tester, find.byKey(const ValueKey('notes-switch-folders')));
    }
    await click(tester, find.byKey(ValueKey('folder-${folder.id}')));
  }

  Future<void> lightShot(WidgetTester tester, String name) async {
    Future<void> wear(AppearanceMode mode, Brightness brightness) async {
      prefs.appearance = mode;
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(addNotes)).brightness,
        brightness,
        reason: name,
      );
    }

    await wear(AppearanceMode.light, Brightness.light);
    expect(tester.takeException(), isNull, reason: name);
    await screenshot('board-$name-light');
    await wear(AppearanceMode.dark, Brightness.dark);
  }

  /// Presses on [finder] and moves sideways, which picks up what it lists.
  Future<TestGesture> grab(WidgetTester tester, Finder finder) async {
    final drag = await tester.startGesture(
      tester.getCenter(finder),
      kind: mouse,
    );
    await drag.moveBy(const Offset(12, 2));
    await tester.pump();
    return drag;
  }

  testWidgets("KAPY-72's d1 and d2: Add notes beside Clients lists the notes "
      'in no folder, adds the ticked ones, and Undo takes them back out', (
    tester,
  ) async {
    await board(tester);
    final clients = folderNamed('Clients', folderNamed('Work').id);
    await showFolder(tester, clients);
    expect(addNotes, findsOneWidget);
    expect(tick('Call with Arjun'), findsNothing);
    for (final title in ['Quote for the deck', 'Pricing ideas', 'Gym plan']) {
      await click(tester, tick(title));
    }
    expect(find.text('Add 3 notes'), findsOneWidget);
    await boardShot(tester, 'folders-d1-adding-notes');
    await lightShot(tester, 'folders-d1-adding-notes');

    // On the Mac a toast's lifetime is an animation, so pumpAndSettle would
    // run it out: it is waited for as it arrives, and Undo is pressed right
    // after the shot.
    final added = find.text('Added 3 notes to “Clients”');
    await tester.tap(find.byKey(const ValueKey('add-notes-add')), kind: mouse);
    await pumpUntil(tester, () => shown(tester, added));
    expect(added, findsOneWidget);
    for (final title in ['Quote for the deck', 'Pricing ideas', 'Gym plan']) {
      expect(folderStore!.tree.folderOf(id(title)), clients.id, reason: title);
      expect(tick(title), findsNothing, reason: title);
    }
    await boardShot(tester, 'folders-d2-notes-added');

    await click(tester, find.text('Undo'));
    for (final title in ['Quote for the deck', 'Pricing ideas', 'Gym plan']) {
      expect(folderStore!.tree.folderOf(id(title)), isNull, reason: title);
      expect(tick(title), findsOneWidget, reason: title);
    }
    await boardShot(tester, 'folders-undo');
  });

  testWidgets("KAPY-72's d3 and d4: ticked notes dragged onto a folder in the "
      'tree, and a note dragged from the list into the open folder', (
    tester,
  ) async {
    await board(tester);
    final clients = folderNamed('Clients', folderNamed('Work').id);
    final personal = folderStore!.create('Personal')!;
    await tester.pumpAndSettle();
    await showFolder(tester, clients);
    await click(tester, tick('Gym plan'));
    await click(tester, tick('Spare keys'));

    var drag = await grab(tester, tick('Gym plan'));
    await drag.moveTo(
      tester.getCenter(find.byKey(ValueKey('folder-${personal.id}'))),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(NoteDragFeedback),
        matching: find.text('2 notes'),
      ),
      findsOneWidget,
    );
    await boardShot(tester, 'folders-d3-dragging-onto-a-folder');
    await lightShot(tester, 'folders-d3-dragging-onto-a-folder');
    await drag.up();
    final moved = find.text('Moved 2 notes to “Personal”');
    await pumpUntil(tester, () => shown(tester, moved));
    expect(moved, findsOneWidget);
    expect(folderStore!.tree.folderOf(id('Gym plan')), personal.id);
    expect(folderStore!.tree.folderOf(id('Spare keys')), personal.id);
    await boardShot(tester, 'folders-d3-dropped');

    await click(tester, find.byKey(const ValueKey('notes-switch-notes')));
    drag = await grab(tester, listed('Pricing ideas'));
    await drag.moveTo(
      tester.getCenter(find.byKey(const ValueKey('folder-page-title'))),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('folder-page-drop')), findsOneWidget);
    await boardShot(tester, 'folders-d4-dragging-into-the-open-folder');
    await drag.up();
    final into = find.text('Moved to “Clients”');
    await pumpUntil(tester, () => shown(tester, into));
    expect(into, findsOneWidget);
    expect(folderStore!.tree.folderOf(id('Pricing ideas')), clients.id);
    await boardShot(tester, 'folders-d4-dropped');
  });

  testWidgets("KAPY-72's d5 and d6: New folder names a folder and opens it "
      'with Add notes, and each part says when it has nothing to show', (
    tester,
  ) async {
    await launch(
      tester,
      size: boardSize,
      bodies: ['Dentist\nThursday 4pm', 'Morning pages\nThe deck, the gym'],
      file: (_) {},
    );
    tester.view.physicalSize = boardSize * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    prefs.appearance = AppearanceMode.dark;
    await tester.pumpAndSettle();

    await click(tester, find.byKey(const ValueKey('notes-switch-folders')));
    expect(find.text('No folders yet'), findsOneWidget);
    await boardShot(tester, 'folders-d6-no-folders');

    await click(tester, find.byKey(const ValueKey('folders-new')));
    expect(find.byKey(const ValueKey('folder-name-field')), findsOneWidget);
    await boardShot(tester, 'folders-d5-naming');
    await tester.enterText(
      find.byKey(const ValueKey('folder-name-field')),
      'Ideas',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Nothing in this folder yet.'), findsOneWidget);
    expect(addNotes, findsOneWidget);
    await boardShot(tester, 'folders-d5-a-new-folder');

    await tester.enterText(
      find.byKey(const ValueKey('add-notes-field')),
      'zebra',
    );
    await tester.pumpAndSettle();
    expect(find.text('No notes match “zebra”'), findsOneWidget);
    await boardShot(tester, 'folders-d6-no-match');

    folderStore!.file([
      id('Dentist'),
      id('Morning pages'),
    ], folderNamed('Ideas').id);
    await tester.pumpAndSettle();
    expect(find.text('Every note is in a folder'), findsOneWidget);
    await boardShot(tester, 'folders-d6-every-note-filed');
  });

  testWidgets("KAP-352: grouped by day, Clients counts only what it lists, so "
      "Friday's Renewal notes is out of its line and Acme's card, and grouped "
      'by tag it is listed and counted', (tester) async {
    await board(tester);
    final clients = folderNamed('Clients', folderNamed('Work').id);
    final acme = folderNamed('Acme', clients.id);
    await showFolder(tester, clients);
    Finder onCard(String text) => find.descendant(
      of: find.byKey(ValueKey('folder-card-${acme.id}')),
      matching: find.text(text),
    );
    Finder onPage(String title) =>
        find.descendant(of: find.byType(FolderPage), matching: row(title));

    expect(find.text('1 note and 1 folder, in Work'), findsOneWidget);
    expect(onCard('1 note'), findsOneWidget);
    expect(onPage('Call with Arjun'), findsOneWidget);
    expect(onPage('Renewal notes'), findsNothing);
    await boardShot(tester, 'kap352-clients-by-day');

    prefs.notesGrouping = NotesGrouping.byTag;
    await tester.pumpAndSettle();
    expect(find.text('2 notes and 1 folder, in Work'), findsOneWidget);
    expect(onCard('2 notes'), findsOneWidget);
    expect(onPage('Renewal notes'), findsOneWidget);
    expect(find.byKey(const ValueKey('folder-group-Work')), findsOneWidget);
    expect(find.byKey(const ValueKey('folder-group-No tag')), findsNothing);
    await boardShot(tester, 'kap352-clients-by-tag');
  });

  testWidgets('a note in the tree lights its whole row under the pointer', (
    tester,
  ) async {
    await board(tester);
    final work = folderNamed('Work');
    final clients = folderNamed('Clients', work.id);
    final acme = folderNamed('Acme', clients.id);
    prefs
      ..setFolderOpen(work.id, true)
      ..setFolderOpen(clients.id, true)
      ..setFolderOpen(acme.id, true);
    await click(tester, find.byKey(const ValueKey('notes-switch-folders')));
    final face = find.descendant(
      of: listed('Renewal notes'),
      matching: find.byType(TreeNoteFace),
    );
    final width = tester.getSize(face).width;
    final pointer = await hover(tester, face);
    expect(tester.getSize(face).width, width);
    await boardShot(tester, 'folders-whole-row-hover');
    await pointer.removePointer();
  });

  /// The open note's meta line, the first pane's while split, ends every item
  /// it shows inside the writing column.
  void expectLineInColumn(WidgetTester tester, [List<String> keys = const []]) {
    final line = find.byType(NoteMetaRow).first;
    final pane = tester.getRect(find.byType(EditorPaneFrame).first);
    final column = pane.right - (tester.getRect(line).left - pane.left);
    for (final key in [
      'note-edited',
      'note-saved',
      'note-progress',
      'note-add-tag',
      ...keys,
    ]) {
      final shown = find
          .descendant(of: line, matching: find.byKey(ValueKey(key)))
          .hitTestable();
      if (shown.evaluate().isEmpty) continue;
      expect(
        tester.getRect(shown).right,
        lessThanOrEqualTo(column),
        reason: key,
      );
    }
  }

  // Split in a 600 wide window, the left pane's meta line had no right bound:
  // 1 of 3 done ran into the pane's edge, and + Tag sat past it.
  testWidgets("KAP-173: split at 600, a note's meta line keeps to its column", (
    tester,
  ) async {
    await launch(
      tester,
      bodies: ['Right note', 'Quote for the deck\n☑ One\n☐ Two\n☐ Three'],
      prepare: (tags, _) {
        for (final name in ['Work', 'Acme']) {
          tags.addTag(id('Quote for the deck'), tags.create(name)!.id);
        }
      },
    );
    await click(tester, row('Quote for the deck'));
    await click(tester, find.byKey(const ValueKey('page-more')));
    await click(tester, find.byKey(const ValueKey('page-more-split')));
    await click(tester, row('Right note'));
    await windowManager.setBounds(Offset.zero & const Size(600, 640));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(tester.getSize(find.byType(KapyNotesApp)).width, 600);
    expectLineInColumn(tester);
    await shot(tester, 'kap173-split-600');
  });

  // In a 400 wide window the meta line's tag chip sat at the window's edge,
  // and the × it shows under the pointer was cut off.
  testWidgets("KAP-378: at 400, a note's tags step aside where the line has "
      "no room, and where it has, a chip's × shows whole", (tester) async {
    late final String quarter;
    await launch(
      tester,
      bodies: ['Quote for the deck\n☑ One\n☐ Two\n☐ Three'],
      prepare: (tags, _) {
        quarter = tags.create('Q4')!.id;
        tags.addTag(id('Quote for the deck'), quarter);
      },
      size: const Size(400, 640),
    );
    expect(tester.getSize(find.byType(KapyNotesApp)).width, 400);
    if (prefs.sidebarVisible) prefs.toggleSidebar();
    await tester.pumpAndSettle();
    final chip = find.byKey(ValueKey('tag-chip-$quarter'));
    final remove = find.byKey(ValueKey('tag-chip-remove-$quarter'));
    expect(find.text('1 of 3 done').hitTestable(), findsOneWidget);
    expectLineInColumn(tester, ['tag-chip-$quarter']);
    await shot(tester, 'kap378-400');

    notes.updateBody(id('Quote for the deck'), 'Quote for the deck');
    await tester.pumpAndSettle();
    expect(chip.hitTestable(), findsOneWidget);
    final pointer = await hover(tester, chip);
    expect(remove.hitTestable(), findsOneWidget);
    expect(tester.getRect(remove).right, lessThanOrEqualTo(400));
    await shot(tester, 'kap378-400-hover');
    await pointer.removePointer();
  });

  /// Right-clicks [title]'s row near its end, light then dark, and takes its
  /// menu as [name]-menu and Move to folder…'s list as [name]-picker, which
  /// hangs from the menu's top right corner inside the window. Esc closes it.
  /// The menu's route cancels the right-click it opens under, and the live
  /// binding passes that cancel on only while device pointer events reach the
  /// app (KAPY-45). Without it the row keeps the press, and the dark pass's
  /// right-click opens nothing.
  Future<void> moveToFolderShots(
    WidgetTester tester,
    String title,
    String name,
  ) async {
    final menu = find.byKey(const ValueKey('kapy-context-menu'));
    final picker = find.byKey(const ValueKey('folder-picker'));
    final window = (Offset.zero & tester.getSize(find.byType(KapyNotesApp)))
        .deflate(8);
    for (final mode in [AppearanceMode.light, AppearanceMode.dark]) {
      prefs.appearance = mode;
      await tester.pumpAndSettle();
      binding.shouldPropagateDevicePointerEvents = true;
      try {
        await tester.tapAt(
          tester.getRect(row(title)).centerRight - const Offset(16, 0),
          buttons: kSecondaryButton,
          kind: mouse,
        );
        await tester.pumpAndSettle();
      } finally {
        binding.shouldPropagateDevicePointerEvents = false;
      }
      final sat = tester.getRect(menu);
      expect(tester.takeException(), isNull, reason: name);
      await screenshot('notes-list-$name-menu-${mode.name}');
      await click(tester, find.byKey(ValueKey('folder-note-${id(title)}')));
      final opened = tester.getRect(picker);
      expect(opened.topRight, sat.topRight, reason: name);
      expect(window.intersect(opened), opened, reason: name);
      await screenshot('notes-list-$name-picker-${mode.name}');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(picker, findsNothing, reason: name);
    }
  }

  testWidgets("KAP-377: Move to folder… on a row's menu opens its list where "
      'the menu was, from the same corner', (tester) async {
    await board(tester);
    await moveToFolderShots(tester, 'Quote for the deck', 'kap377-board');
  });

  testWidgets('KAP-377: in a 400 wide window, the list opens where the menu '
      'was and keeps inside the window', (tester) async {
    await launch(
      tester,
      size: const Size(400, 640),
      bodies: ['Gym plan\nVoice note', 'Pricing ideas\n1,799 INR a seat'],
      file: (folders) {
        folders
          ..create('Work')
          ..create('Home');
      },
    );
    await click(tester, find.byKey(const ValueKey('page-show-list')));
    await moveToFolderShots(tester, 'Pricing ideas', 'kap377-narrow');
  });

  testWidgets('KAP-389: ⌘F finds words in the open note, Enter steps, and '
      'esc leaves the match selected', (tester) async {
    await launch(
      tester,
      bodies: [
        'Trip budget\nflights = 412 eur\nhotel = 128 eur\nfood = 55 eur',
      ],
    );
    await click(tester, row('Trip budget'));
    final bar = find.byKey(const ValueKey('note-find-bar'));
    final field = find.byKey(const ValueKey('note-find-field'));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(bar, findsOneWidget);
    expect(find.byKey(const ValueKey('command-menu')), findsNothing);

    await tester.enterText(field, 'porto');
    await tester.pumpAndSettle();
    expect(find.text('No matches'), findsOneWidget);
    await shot(tester, 'find-in-note-none');

    await tester.enterText(field, 'eur');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('2 of 3'), findsOneWidget);
    await shot(tester, 'find-in-note');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(bar, findsNothing);
    final note = tester.widget<NoteField>(
      find.descendant(
        of: find.byType(NoteEditor),
        matching: find.byType(NoteField),
      ),
    );
    final body = note.controller.text;
    final at = body.indexOf('eur', body.indexOf('hotel'));
    expect(
      note.controller.selection,
      TextSelection(baseOffset: at, extentOffset: at + 3),
    );
    await shot(tester, 'find-in-note-closed');
  });
}
