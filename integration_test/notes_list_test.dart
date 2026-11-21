// The desktop Notes list on a real Mac: the whole app over notes kept in
// memory, in a 1100 × 760 window.
//
//   flutter drive --driver test_driver/integration_test.dart \
//     --target integration_test/notes_list_test.dart -d macos \
//     --dart-define=KAPYNOTES_SYNC=false
//
// It runs the device checks that three 1.35 changes still owe:
// - Ask Kapy left of New note in the list's bar (#225): where it sits, its
//   name on hover, and a click that opens Kapy AI on the note shown.
// - New beside show-list while the list is hidden (#254): it makes a note, a
//   drawing, or in Tasks goes to "Add a task", by click and by Tab and Enter.
// - A row's screen-reader actions while notes are picked, and the Upcoming
//   fold (#239). VoiceOver can't run on a CI runner, so the test reads the
//   actions from the app's semantics tree, which is what the Mac hands
//   VoiceOver, and does them from there.
// Each state is taken light and dark, as screenshots in build/screenshots.
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
import 'package:kapy_notes/ui/context_menu.dart';
import 'package:kapy_notes/ui/notes_list.dart';
import 'package:kapy_notes/ui/sidebar.dart';
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

  /// The app with the list beside the page, over [bodies] written a minute
  /// apart, oldest first; [prepare] then tags them or gives them days.
  Future<void> launch(
    WidgetTester tester, {
    required List<String> bodies,
    void Function(TagStore tags, NoteDayStore days)? prepare,
  }) async {
    if (AppPlatform.isDesktop) {
      await windowManager.ensureInitialized();
      await windowManager.setBounds(const Rect.fromLTWH(0, 0, 1100, 760));
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
    for (final body in bodies) {
      clock = clock.add(const Duration(minutes: 1));
      notes.create(body: body);
    }
    clock = DateTime.now();
    prepare?.call(tags, days);
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
    expect(tester.getRect(ask).right + 8, tester.getRect(newNote).left);
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

    await click(tester, find.byKey(const ValueKey('rail-tasks')));
    besideShowList('New task');
    before = notes.notes.length;
    await click(tester, pageNew);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Add a task');
    expect(notes.notes, hasLength(before));
    await shot(tester, 'new-task');

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
    await click(tester, find.byKey(const ValueKey('confirm-delete')));
    expect(notes.notes.map((note) => note.title), ['Second']);
    expect(find.text('4 notes deleted'), findsOneWidget);
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
}
