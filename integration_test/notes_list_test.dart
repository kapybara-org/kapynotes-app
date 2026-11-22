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
// - A row's screen-reader actions while notes are picked, and the Upcoming
//   fold (#239). VoiceOver can't run on a CI runner, so the test reads the
//   actions from the app's semantics tree, which is what the Mac hands
//   VoiceOver, and does them from there.
// - D03, D04 and D07 of the final boards, over the boards' notes in a
//   1440 × 900 window, for the design check to hold against them.
// Each state is taken light and dark, as screenshots in build/screenshots;
// the boards' states dark only, as the boards draw them.
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
import 'package:kapy_notes/data/folders.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note_days.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/tags.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/ui/checklist_pie.dart';
import 'package:kapy_notes/ui/context_menu.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/editor/note_field.dart';
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
import 'screenshot.dart';

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
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  kapyAiAvailable = true;

  const mouse = PointerDeviceKind.mouse;
  late NotesStore notes;
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
    prefs = LayoutPrefs(store)..load();
    shortcuts = ShortcutPrefs(store)..load();
    await notes.load();
    await tags.load();
    await days.load();
    final folders = file == null ? null : FolderStore(store);
    await folders?.load();
    for (final body in bodies) {
      clock = clock.add(const Duration(minutes: 1));
      notes.create(body: body);
    }
    clock = DateTime.now();
    prepare?.call(tags, days);
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
        rates: RatesRepository(store),
        prefs: prefs,
        shortcuts: shortcuts,
        tags: tags,
        days: days,
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

  testWidgets('only the day grouping folds Upcoming: a tag named Upcoming '
      'starts open when the list groups by tag', (tester) async {
    await launch(
      tester,
      bodies: ['Renewal notes\nRead the contract', 'Standup\nShip it'],
      prepare: (tags, days) {
        final now = notes.now();
        days.setDay(
          id('Renewal notes'),
          DateTime(now.year, now.month, now.day + 2),
        );
        tags.addTag(id('Standup'), tags.create('Upcoming')!.id);
      },
    );
    final list = find.byType(Sidebar);
    final upcoming = find.byKey(const ValueKey('sidebar-group-Upcoming'));
    expect(tester.widget<NotesGroupHeading>(upcoming).folded, isTrue);
    expect(
      find.descendant(of: list, matching: find.text('Renewal notes')),
      findsNothing,
    );
    await shot(tester, 'upcoming-by-date');

    await click(tester, find.byKey(const ValueKey('notes-grouping')));
    await click(tester, find.byKey(const ValueKey('notes-grouping-byTag')));
    expect(tester.widget<NotesGroupHeading>(upcoming).label, 'Upcoming');
    expect(tester.widget<NotesGroupHeading>(upcoming).folded, isNull);
    for (final title in ['Standup', 'Renewal notes']) {
      expect(
        find.descendant(of: list, matching: find.text(title)),
        findsOneWidget,
        reason: title,
      );
    }
    await shot(tester, 'upcoming-by-tag');
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

  Future<void> boardShot(WidgetTester tester, String name) async {
    expect(tester.getSize(find.byType(KapyNotesApp)), boardSize, reason: name);
    expect(tester.takeException(), isNull, reason: name);
    await screenshot('board-$name-dark');
  }

  final openNote = find.descendant(
    of: find.byType(NoteEditor),
    matching: find.byType(NoteField),
  );

  testWidgets("D03's board: a second card's menu opens it in a new tab", (
    tester,
  ) async {
    await board(tester);
    expect(find.byKey(const ValueKey('sidebar-space-count')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('sidebar-new-note')),
        matching: find.text('New note'),
      ),
      findsOneWidget,
    );
    final filter = find.byKey(const ValueKey('sidebar-notes-filter'));
    expect(
      tester
          .widget<Container>(
            find.descendant(of: filter, matching: find.byType(Container)).first,
          )
          .decoration,
      isNull,
    );
    expect(
      tester
          .widget<Container>(find.byKey(const ValueKey('sidebar-view-switch')))
          .decoration,
      isNull,
    );
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

  // The board picks Fri 21 in the week: its note opens and is lit in the
  // whole list, under Upcoming, which opens to show it above Today.
  testWidgets("D04's board: the day after tomorrow picked in the week opens "
      'its note, lit under Upcoming above Today', (tester) async {
    await board(tester);
    final now = notes.now();
    final friday = DateTime(now.year, now.month, now.day + 2);
    final list = find.byType(Sidebar);
    final upcoming = find.byKey(const ValueKey('sidebar-group-Upcoming'));
    final today = find.byKey(const ValueKey('sidebar-group-Today'));
    expect(tester.widget<NotesGroupHeading>(upcoming).folded, isTrue);
    expect(
      tester.getTopLeft(upcoming).dy,
      lessThan(tester.getTopLeft(today).dy),
    );
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
    expect(tester.widget<NotesGroupHeading>(upcoming).folded, isFalse);
    expect(
      tester
          .getRect(
            find.descendant(
              of: upcoming,
              matching: findKapyIcon(KapyIcons.chevronDownRounded),
            ),
          )
          .left,
      greaterThan(
        tester
            .getRect(find.descendant(of: upcoming, matching: find.text('1')))
            .right,
      ),
    );
    expect(
      tester
          .widget<NoteCardFace>(
            find.descendant(
              of: row('Renewal notes'),
              matching: find.byType(NoteCardFace),
            ),
          )
          .date,
      SidebarTimestamp.weekdayAndDay(friday),
    );
    final ring = tester.widget<ChecklistPie>(
      find.descendant(
        of: row('Renewal notes'),
        matching: find.byType(ChecklistPie),
      ),
    );
    expect((ring.done, ring.total), (0, 2));
    expect(today, findsOneWidget, reason: 'the list stays whole');
    final renewal = tester.widget<NoteRow>(row('Renewal notes'));
    expect(renewal.selected, isTrue);
    expect(renewal.ofPickedDay, isTrue);
    expect(
      tester.getTopLeft(row('Renewal notes')).dy,
      lessThan(tester.getTopLeft(today).dy),
    );
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
    await boardShot(tester, 'd04-friday-upcoming');
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
}
