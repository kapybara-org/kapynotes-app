import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/folders.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/tags.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/ui/back_entry.dart';
import 'package:kapy_notes/ui/note_row_swipe.dart';
import 'package:kapy_notes/ui/notes_list.dart' show NotesShow;
import 'package:kapy_notes/ui/sidebar.dart' show NoteRow;
import 'package:kapy_notes/ui/tasks/tasks_screen.dart';
import 'package:material_ui/material_ui.dart';

import 'app_test.dart' show MemoryStore;
import 'test_fonts.dart';

/// Wed 19 Nov 2025, 9:41.
final _now = DateTime(2025, 11, 19, 9, 41);

late MemoryStore store;
late NotesStore notes;
late LayoutPrefs prefs;
late FolderStore folders;
late TaskLibrary tasks;

Map<String, Object?> _note(String id, String body, DateTime edited) => {
  'id': id,
  'body': body,
  'createdAt': edited.millisecondsSinceEpoch,
  'updatedAt': edited.millisecondsSinceEpoch,
};

Finder _row(String title) => find.widgetWithText(NoteRow, title);
Finder _button(String key, String id) => find.byKey(ValueKey('swipe-$key-$id'));

/// The titles of the rows on screen, top to bottom.
List<String> _titles(WidgetTester tester) => [
  for (final row in tester.widgetList<NoteRow>(find.byType(NoteRow)))
    row.note.title,
];

Future<void> _drag(WidgetTester tester, Finder row, double dx) async {
  await tester.drag(row, Offset(dx, 0));
  await tester.pumpAndSettle();
}

/// A short swipe: past half the buttons, short of the full swipe.
Future<void> _open(WidgetTester tester, String title) =>
    _drag(tester, _row(title), -120);

/// A swipe all the way across.
Future<void> _swipeAcross(WidgetTester tester, String title) =>
    _drag(tester, _row(title), -330);

/// [title]'s row, as VoiceOver and TalkBack see it.
SemanticsNode _rowNode(WidgetTester tester, String title) =>
    tester.semantics.find(find.text(title));

Map<String, int> _actions(WidgetTester tester, String title) => {
  for (final id
      in _rowNode(tester, title).getSemanticsData().customSemanticsActionIds ??
          const <int>[])
    CustomSemanticsAction.getAction(id)!.label!: id,
};

Future<void> _act(WidgetTester tester, String title, String label) async {
  final row = _rowNode(tester, title);
  final id = _actions(tester, title)[label];
  expect(id, isNotNull, reason: '$title offers $label');
  row.owner!.performAction(row.id, SemanticsAction.customAction, id);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadTestFonts);

  setUp(() async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    store = MemoryStore();
    store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
    store.data['notes.v1'] = [
      _note('groceries', 'Groceries\nOat milk', DateTime(2025, 11, 19, 9, 30)),
      _note('offsite', 'Team offsite\nLisbon', DateTime(2025, 11, 19, 9)),
      _note('budget', 'Budget\nRent', DateTime(2025, 11, 19, 8)),
      _note('standup', 'Standup notes\nShip it', DateTime(2025, 11, 18, 10)),
    ];
    notes = NotesStore(store, now: () => _now);
    prefs = LayoutPrefs(store);
    folders = FolderStore(store, now: () => _now);
    await folders.load();
    tasks = TaskLibrary(
      notes: notes,
      store: store,
      storage: MemoryDocStorage(),
      now: () => _now,
    );
  });

  tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(390, 844),
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await notes.load();
    prefs.load();
    if (!prefs.sidebarVisible) prefs.toggleSidebar();
    await tester.pumpWidget(
      KapyNotesApp(
        store: store,
        notes: notes,
        rates: RatesRepository(store),
        prefs: prefs,
        shortcuts: ShortcutPrefs(store)..load(),
        tags: TagStore(store, now: () => _now),
        folders: folders,
        tasks: tasks,
      ),
    );
    await tester.runAsync(tasks.reconcileNow);
    await tester.pumpAndSettle();
    // A phone opens on a note's page; the lists are under it.
    final home = find.byKey(const ValueKey('page-home'));
    if (home.evaluate().isNotEmpty) {
      await tester.tap(home);
      await tester.pumpAndSettle();
    }
  }

  group('a short swipe', () {
    testWidgets("shows Pin and Delete at the row's end, with room to tap", (
      tester,
    ) async {
      await pump(tester);
      expect(_button('pin', 'groceries'), findsNothing);

      await _open(tester, 'Groceries');
      for (final key in ['pin', 'delete']) {
        final button = _button(key, 'groceries');
        expect(button.hitTestable(), findsOneWidget, reason: key);
        expect(tester.getSize(button).height, greaterThanOrEqualTo(44));
      }
      expect(
        tester.getTopRight(_button('delete', 'groceries')).dx,
        tester
            .getTopRight(
              find.descendant(
                of: _row('Groceries'),
                matching: find.byType(NoteRowSwipe),
              ),
            )
            .dx,
        reason: 'the buttons sit where the row slid from',
      );
      expect(find.text('Pin'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      expect(_button('archive', 'groceries'), findsNothing);
      expect(notes.byId('groceries')!.isArchived, isFalse);
    });

    testWidgets('closes on a swipe back, and opens one row at a time', (
      tester,
    ) async {
      await pump(tester);
      await _open(tester, 'Groceries');
      await _drag(tester, _row('Groceries'), 200);
      expect(_button('pin', 'groceries').hitTestable(), findsNothing);
      expect(tester.getTopLeft(_row('Groceries')).dx, 0);

      await _open(tester, 'Groceries');
      await _open(tester, 'Budget');
      expect(_button('pin', 'budget').hitTestable(), findsOneWidget);
      expect(_button('pin', 'groceries').hitTestable(), findsNothing);
      expect(tester.getTopLeft(_row('Groceries')).dx, 0);
    });

    testWidgets('closes on a tap elsewhere', (tester) async {
      await pump(tester);
      await _open(tester, 'Groceries');
      await tester.tap(find.byKey(const ValueKey('home-title-notes')));
      await tester.pumpAndSettle();
      expect(_button('pin', 'groceries').hitTestable(), findsNothing);
      expect(tester.getTopLeft(_row('Groceries')).dx, 0);

      // A tap on the open row itself closes it rather than opening the note.
      await _open(tester, 'Groceries');
      await tester.tap(_row('Groceries'));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(_row('Groceries')).dx, 0);
      expect(find.byKey(const ValueKey('page-home')), findsNothing);
    });

    testWidgets('closes when its list scrolls', (tester) async {
      await pump(tester);
      await _open(tester, 'Groceries');
      // From the open row itself, so no tap lands outside it.
      await tester.drag(_row('Groceries'), const Offset(0, -80));
      await tester.pumpAndSettle();
      expect(_button('pin', 'groceries').hitTestable(), findsNothing);
      expect(tester.getTopLeft(_row('Groceries')).dx, 0);
    });
  });

  group('Pin', () {
    testWidgets('pins from a row, which then waits under Pinned, and the '
        'Pinned list offers Unpin', (tester) async {
      await pump(tester);
      await _open(tester, 'Budget');
      await tester.tap(_button('pin', 'budget'));
      await tester.pumpAndSettle();
      expect(notes.isPinned('budget'), isTrue);
      expect(find.text('Note pinned'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('sidebar-view-all-pinned')));
      await tester.pumpAndSettle();
      await _open(tester, 'Budget');
      expect(find.text('Unpin'), findsOneWidget);
      await tester.tap(_button('pin', 'budget'));
      await tester.pumpAndSettle();
      expect(notes.isPinned('budget'), isFalse);
      expect(find.text('Note unpinned'), findsOneWidget);
    });
  });

  group('Delete', () {
    testWidgets("asks first, as the row's menu does, and closes the row", (
      tester,
    ) async {
      await pump(tester);
      await _open(tester, 'Budget');
      await tester.tap(_button('delete', 'budget'));
      await tester.pumpAndSettle();
      expect(find.text('Delete note?'), findsOneWidget);
      expect(
        find.text('Permanently deletes "Budget" from every synced device.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(notes.byId('budget'), isNotNull);
      expect(tester.getTopLeft(_row('Budget')).dx, 0);

      await _open(tester, 'Budget');
      await tester.tap(_button('delete', 'budget'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-delete')));
      await tester.pumpAndSettle();
      expect(notes.byId('budget'), isNull);
      expect(_row('Budget'), findsNothing);
      expect(find.text('Note deleted'), findsOneWidget);
    });

    testWidgets('goes straight through once the question is turned off', (
      tester,
    ) async {
      prefs.askBeforeDeleting = false;
      await pump(tester);
      await _open(tester, 'Budget');
      await tester.tap(_button('delete', 'budget'));
      await tester.pumpAndSettle();
      expect(find.text('Delete note?'), findsNothing);
      expect(notes.byId('budget'), isNull);
      expect(find.text('Note deleted'), findsOneWidget);
    });
  });

  group('a full swipe', () {
    testWidgets('archives the note, says so with Undo, and Undo puts it back '
        'where it was', (tester) async {
      await pump(tester);
      final before = _titles(tester);
      expect(before, ['Groceries', 'Team offsite', 'Budget', 'Standup notes']);
      final edited = notes.byId('offsite')!.updatedAt;

      final count = find.descendant(
        of: find.byKey(const ValueKey('home-title-notes')),
        matching: find.byType(Text),
      );
      expect(tester.widgetList<Text>(count).map((t) => t.data), contains('4'));

      await _swipeAcross(tester, 'Team offsite');
      expect(notes.byId('offsite')!.isArchived, isTrue);
      expect(_row('Team offsite'), findsNothing);
      expect(find.text('Archived “Team offsite”'), findsOneWidget);
      expect(
        tester.widgetList<Text>(count).map((t) => t.data),
        contains('3'),
        reason: "Home's count drops by the note",
      );

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(notes.byId('offsite')!.isArchived, isFalse);
      expect(tester.widgetList<Text>(count).map((t) => t.data), contains('4'));
      expect(notes.byId('offsite')!.updatedAt, edited);
      expect(_titles(tester), before);
      expect(tester.getTopLeft(_row('Team offsite')).dx, 0);
    });

    testWidgets('ticks once on iOS as it passes the point of no return, and '
        'not at all short of it', (tester) async {
      final ticks = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            ticks.add(call.arguments);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await pump(tester);
      await _open(tester, 'Budget');
      expect(ticks, isEmpty);
      await _drag(tester, _row('Budget'), 200);

      await _swipeAcross(tester, 'Budget');
      expect(ticks, ['HapticFeedbackType.lightImpact']);
      expect(notes.byId('budget')!.isArchived, isTrue);
    });

    testWidgets('has no tick on Android', (tester) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
      final ticks = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            ticks.add(call.arguments);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await pump(tester);
      await _swipeAcross(tester, 'Budget');
      expect(notes.byId('budget')!.isArchived, isTrue);
      expect(ticks, isEmpty);
    });

    testWidgets('a second drag while the row slides out still archives', (
      tester,
    ) async {
      await pump(tester);
      final row = _row('Team offsite');
      await tester.drag(row, const Offset(-330, 0));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.drag(row, const Offset(-60, 0));
      await tester.pump(const Duration(seconds: 2));
      expect(notes.byId('offsite')!.isArchived, isTrue);
      expect(_row('Team offsite'), findsNothing);
    });

    testWidgets('a swipe let go short of the point opens the row instead', (
      tester,
    ) async {
      await pump(tester);
      await _drag(tester, _row('Budget'), -200);
      expect(notes.byId('budget')!.isArchived, isFalse);
      expect(_button('delete', 'budget').hitTestable(), findsOneWidget);
    });
  });

  testWidgets('a drag while notes are picked shows no buttons', (tester) async {
    await pump(tester);
    await tester.longPress(_row('Budget'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('select-note-budget')));
    await tester.pumpAndSettle();
    expect(find.byType(NoteRowSwipe), findsNothing);
    await _drag(tester, _row('Groceries'), -200);
    expect(_button('pin', 'groceries'), findsNothing);
    expect(_button('delete', 'groceries'), findsNothing);
  });

  group('the widget alone', () {
    var archived = 0;

    Future<void> pumpRow(WidgetTester tester, {required bool full}) async {
      archived = 0;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      NoteRowSwipeAction action(String key) => (
        key: key,
        label: key,
        icon: KapyIcons.pinOutlined,
        background: const Color(0xFF333333),
        foreground: const Color(0xFFFFFFFF),
        onPressed: () {},
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: KapyTheme.light(),
          home: Scaffold(
            body: ListView(
              children: [
                NoteRowSwipe(
                  id: 'row',
                  actions: [action('pin'), action('delete')],
                  // An archive that keeps the note, as a refusal does.
                  full: full
                      ? (
                          key: 'archive',
                          label: 'Archive',
                          icon: KapyIcons.archiveOutlined,
                          background: const Color(0xFF333333),
                          foreground: const Color(0xFFFFFFFF),
                          onPressed: () => archived++,
                        )
                      : null,
                  child: const SizedBox(height: 72, child: Text('Row')),
                ),
              ],
            ),
          ),
        ),
      );
    }

    double slid(WidgetTester tester) => -tester.getTopLeft(find.text('Row')).dx;

    testWidgets('a row with no full swipe stops at its buttons', (
      tester,
    ) async {
      await pumpRow(tester, full: false);
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Row')),
      );
      await gesture.moveBy(const Offset(-20, 0));
      await gesture.moveBy(const Offset(-320, 0));
      await tester.pump();
      expect(slid(tester), NoteRowSwipe.actionWidth * 2);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(slid(tester), NoteRowSwipe.actionWidth * 2);
    });

    testWidgets('a full swipe whose note stays brings the row back', (
      tester,
    ) async {
      await pumpRow(tester, full: true);
      await _drag(tester, find.text('Row'), -330);
      expect(archived, 1);
      expect(slid(tester), 0);
      expect(find.byKey(const ValueKey('swipe-archive-row')), findsNothing);
    });
  });

  group('VoiceOver and TalkBack', () {
    testWidgets('offer Pin, Archive and Delete on the row, which do what '
        'the swipe does', (tester) async {
      final semantics = tester.ensureSemantics();
      await pump(tester);
      expect(
        _actions(tester, 'Budget').keys,
        containsAll(['Pin note', 'Archive note', 'Delete note…']),
      );

      await _act(tester, 'Budget', 'Pin note');
      expect(notes.isPinned('budget'), isTrue);
      final before = _titles(tester);
      final edited = notes.byId('offsite')!.updatedAt;
      await _act(tester, 'Team offsite', 'Archive note');
      expect(notes.byId('offsite')!.isArchived, isTrue);
      expect(find.text('Archived “Team offsite”'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(notes.byId('offsite')!.isArchived, isFalse);
      expect(notes.byId('offsite')!.updatedAt, edited);
      expect(_titles(tester), before);

      await _act(tester, 'Standup notes', 'Delete note…');
      expect(find.text('Delete note?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('confirm-delete')));
      await tester.pumpAndSettle();
      expect(notes.byId('standup'), isNull);
      semantics.dispose();
    });

    testWidgets("see none of the swipe's own buttons", (tester) async {
      final semantics = tester.ensureSemantics();
      await pump(tester);
      await _open(tester, 'Budget');
      expect(find.bySemanticsLabel('Pin'), findsNothing);
      expect(find.bySemanticsLabel('Delete'), findsNothing);
      semantics.dispose();
    });
  });

  group('Back', () {
    Future<String> openFolder(WidgetTester tester) async {
      final work = folders.create('Work')!;
      folders.file(['offsite', 'budget'], work.id);
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('bar-folders')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('folder-${work.id}')));
      await tester.pumpAndSettle();
      return 'phone-folder-${work.id}';
    }

    testWidgets("Android's Back closes an open row before the page goes", (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
      final page = find.byKey(ValueKey(await openFolder(tester)));
      await _open(tester, 'Budget');
      expect(_button('pin', 'budget').hitTestable(), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_button('pin', 'budget').hitTestable(), findsNothing);
      expect(tester.getTopLeft(_row('Budget')).dx, 0);
      expect(page, findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(page, findsNothing);
      expect(find.byKey(const ValueKey('phone-folders')), findsOneWidget);
    });

    testWidgets('a row that goes while open leaves Back as it was', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
      final page = find.byKey(ValueKey(await openFolder(tester)));
      await _open(tester, 'Budget');
      expect(BackEntry.anyOpen, isTrue);

      // The bar takes the folder's page away under the open row.
      await tester.tap(find.byKey(const ValueKey('bar-notes')));
      await tester.pumpAndSettle();
      expect(page, findsNothing);
      expect(BackEntry.anyOpen, isFalse);

      await tester.tap(find.byKey(const ValueKey('bar-folders')));
      await tester.pumpAndSettle();
      if (page.evaluate().isEmpty) {
        await tester.tap(
          find.byWidgetPredicate(
            (widget) =>
                widget.key is ValueKey<String> &&
                (widget.key! as ValueKey<String>).value.startsWith('folder-'),
          ),
        );
        await tester.pumpAndSettle();
      }
      expect(page, findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(page, findsNothing);
    });

    testWidgets("Back with no row open leaves the folder's page", (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
      final page = find.byKey(ValueKey(await openFolder(tester)));
      await _open(tester, 'Budget');
      await _drag(tester, _row('Budget'), 200);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(page, findsNothing);
    });

    testWidgets("on an iPhone, the left edge's swipe over a row still goes "
        'back, and a left drag from it opens nothing', (tester) async {
      final page = find.byKey(ValueKey(await openFolder(tester)));
      final y = tester.getCenter(_row('Budget')).dy;

      await tester.dragFrom(Offset(10, y), const Offset(-200, 0));
      await tester.pumpAndSettle();
      expect(_button('pin', 'budget'), findsNothing);
      expect(page, findsOneWidget);

      await tester.dragFrom(Offset(10, y), const Offset(300, 0));
      await tester.pumpAndSettle();
      expect(page, findsNothing);
      expect(find.byKey(const ValueKey('phone-folders')), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('on an iPhone, a row swipe from 24 pt in opens the row on '
        "a folder's page, where the edge goes back", (tester) async {
      final page = find.byKey(ValueKey(await openFolder(tester)));
      await tester.dragFrom(
        Offset(24, tester.getCenter(_row('Budget')).dy),
        const Offset(-200, 0),
      );
      await tester.pumpAndSettle();
      expect(_button('pin', 'budget').hitTestable(), findsOneWidget);
      expect(page, findsOneWidget);
    });
  });

  group("Home's page swipe", () {
    final tasksPage = find.byType(TasksScreen);

    testWidgets('a drag on a row opens the row and stays on Notes', (
      tester,
    ) async {
      await pump(tester);
      await _drag(tester, _row('Budget'), -200);
      expect(_button('pin', 'budget').hitTestable(), findsOneWidget);
      expect(tasksPage, findsNothing);
    });

    testWidgets('a drag on the header turns to Tasks', (tester) async {
      await pump(tester);
      await _drag(tester, find.byKey(const ValueKey('home-title-notes')), -200);
      expect(tasksPage, findsOneWidget);
    });

    testWidgets('a drag on the empty space under the rows turns to Tasks', (
      tester,
    ) async {
      await pump(tester);
      final below = tester.getBottomLeft(_row('Standup notes')).dy + 40;
      expect(below, lessThan(700));
      await tester.dragFrom(Offset(200, below), const Offset(-200, 0));
      await tester.pumpAndSettle();
      expect(tasksPage, findsOneWidget);
    });
  });

  group('every phone list', () {
    Future<void> expectSwipes(
      WidgetTester tester,
      String title,
      String id,
    ) async {
      expect(
        find.descendant(of: _row(title), matching: find.byType(NoteRowSwipe)),
        findsOneWidget,
        reason: title,
      );
      await _drag(tester, _row(title), -100);
      expect(
        _button('delete', id).hitTestable(),
        findsOneWidget,
        reason: title,
      );
      await _drag(tester, _row(title), 200);
    }

    testWidgets("Home's day list", (tester) async {
      await pump(tester);
      await expectSwipes(tester, 'Groceries', 'groceries');
      await expectSwipes(tester, 'Standup notes', 'standup');
    });

    testWidgets("Pinned, but not Home's pinned cards", (tester) async {
      await notes.load();
      notes.togglePinned('budget');
      await pump(tester);
      final cards = find.byKey(const ValueKey('phone-pinned-cards'));
      expect(
        find.descendant(of: cards, matching: _row('Budget')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: cards, matching: find.byType(NoteRowSwipe)),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('sidebar-view-all-pinned')));
      await tester.pumpAndSettle();
      await expectSwipes(tester, 'Budget', 'budget');
    });

    testWidgets("a folder's notes, a subfolder's, and Not in a folder", (
      tester,
    ) async {
      final work = folders.create('Work')!;
      final clients = folders.create('Clients', parentId: work.id)!;
      folders.file(['offsite'], work.id);
      folders.file(['budget'], clients.id);
      prefs.setFolderOpen(work.id, true);
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('bar-folders')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('folders-loose-heading')), findsOne);
      await expectSwipes(tester, 'Groceries', 'groceries');

      await tester.tap(find.byKey(ValueKey('folder-${clients.id}')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey('phone-folder-${clients.id}')),
        findsOneWidget,
      );
      await expectSwipes(tester, 'Budget', 'budget');

      await tester.tap(find.byKey(const ValueKey('page-back')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('folder-${work.id}')));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('phone-folder-${work.id}')), findsOneWidget);
      await expectSwipes(tester, 'Team offsite', 'offsite');
      await expectSwipes(tester, 'Budget', 'budget');
    });

    testWidgets("Drawings' rows", (tester) async {
      await notes.load();
      final drawing = notes.create(drawing: true);
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('bar-folders')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('folders-drawings-tile')));
      await tester.pumpAndSettle();
      final row = find.byWidgetPredicate(
        (widget) => widget is NoteRow && widget.note.id == drawing.id,
      );
      expect(
        find.descendant(of: row, matching: find.byType(NoteRowSwipe)),
        findsOneWidget,
      );
      await _drag(tester, row, -100);
      expect(_button('pin', drawing.id).hitTestable(), findsOneWidget);
      expect(_button('delete', drawing.id).hitTestable(), findsOneWidget);
      await _drag(tester, row, 200);

      await _drag(tester, row, -340);
      expect(notes.byId(drawing.id)!.isArchived, isTrue);
      expect(row, findsNothing);
    });

    testWidgets('not Archive, where Restore and the delete that cannot be '
        'undone stay in the menu', (tester) async {
      await notes.load();
      notes.archiveAll(['budget']);
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('phone-filters')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sidebar-notes-filter')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey('notes-filter-${NotesShow.archive.name}')),
      );
      await tester.pumpAndSettle();
      expect(_row('Budget'), findsOneWidget);
      expect(find.byType(NoteRowSwipe), findsNothing);
      await _drag(tester, _row('Budget'), -200);
      expect(_button('delete', 'budget'), findsNothing);
      expect(notes.byId('budget')!.isArchived, isTrue);

      await tester.longPress(_row('Budget'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('restore-note-budget')), findsOneWidget);
      expect(find.byKey(const ValueKey('delete-note-budget')), findsOneWidget);
    });

    testWidgets('not on a desktop', (tester) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
      await pump(tester, size: const Size(1100, 760));
      expect(_row('Budget'), findsOneWidget);
      expect(find.byType(NoteRowSwipe), findsNothing);
      await _drag(tester, _row('Budget'), -200);
      expect(_button('delete', 'budget'), findsNothing);
    });

    testWidgets('not on a tablet, which keeps the list beside the page', (
      tester,
    ) async {
      await pump(tester, size: const Size(1024, 1366));
      expect(_row('Budget'), findsOneWidget);
      expect(find.byType(NoteRowSwipe), findsNothing);
    });
  });

  group('undoArchive', () {
    test('puts the note back at its place and time, unsent', () async {
      await notes.load();
      final index = notes.indexOf('offsite');
      notes.markSynced(notes: [notes.byId('offsite')!]);
      final before = notes.byId('offsite')!;
      expect(before.isDirty, isFalse);

      notes.archiveAll(['offsite']);
      notes.undoArchive(before, index);
      final back = notes.byId('offsite')!;
      expect(back.isArchived, isFalse);
      expect(notes.indexOf('offsite'), index);
      expect(back.isDirty, isTrue, reason: 'the server heard the archive');
      expect(
        back.updatedAt.difference(before.updatedAt),
        const Duration(milliseconds: 1),
      );
    });

    test('keeps the exact time when the server holds another', () async {
      await notes.load();
      final before = notes.byId('offsite')!;
      final index = notes.indexOf('offsite');
      notes.archiveAll(['offsite']);
      notes.markSynced(notes: [notes.byId('offsite')!]);
      notes.undoArchive(before, index);
      final back = notes.byId('offsite')!;
      expect(back.updatedAt, before.updatedAt);
      expect(back.isDirty, isTrue);
    });

    test('leaves a note restored or deleted since', () async {
      await notes.load();
      final before = notes.byId('offsite')!;
      final index = notes.indexOf('offsite');
      notes.archiveAll(['offsite']);
      notes.restoreAll(['offsite']);
      final restored = notes.byId('offsite')!;
      notes.undoArchive(before, index);
      expect(notes.byId('offsite')!.updatedAt, restored.updatedAt);
      notes.deleteAll({'offsite'});
      notes.undoArchive(before, index);
      expect(notes.byId('offsite'), isNull);
    });
  });
}
