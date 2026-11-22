import 'package:flutter_test/flutter_test.dart';
import 'package:hugeicons/hugeicons.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/folders.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/note_days.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/tags.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/account.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/sync/key_store.dart';
import 'package:kapy_notes/sync/sync_state.dart';
import 'package:kapy_notes/ui/day_strip.dart' show DayPicker;
import 'package:kapy_notes/ui/editor/note_header.dart' show NoteMetaRow;
import 'package:kapy_notes/ui/hidden_notes_gate.dart';
import 'package:kapy_notes/ui/home_page.dart' show HomePage;
import 'package:kapy_notes/ui/phone_note_header.dart';
import 'package:kapy_notes/ui/settings_dialog.dart';
import 'package:kapy_notes/ui/sidebar.dart' show NoteRow;
import 'package:kapy_notes/ui/spaces_rail.dart' show PhoneSpaces, PhoneTab;
import 'package:kapy_notes/ui/tag_ui.dart' show TagPicker;
import 'package:kapy_notes/ui/tasks/tasks_screen.dart';
import 'package:material_ui/material_ui.dart';

import 'app_test.dart' show MemoryStore, openNoteBody, openNoteField;
import 'kapy_icon_finder.dart';
import 'support/note_driver.dart';
import 'sync/fake_server.dart';
import 'test_fonts.dart';

/// Wed 19 Nov 2025, 9:41, the week M09's phone draws.
final _now = DateTime(2025, 11, 19, 9, 41);

late MemoryStore store;
late NotesStore notes;
late LayoutPrefs prefs;
late TagStore tags;
late FolderStore folders;
late NoteDayStore days;
late TaskLibrary tasks;

Map<String, Object?> _note(String id, String body, DateTime edited) => {
  'id': id,
  'body': body,
  'createdAt': edited.millisecondsSinceEpoch,
  'updatedAt': edited.millisecondsSinceEpoch,
};

final header = find.byKey(const ValueKey('phone-note-header'));
final tasksLine = find.byKey(const ValueKey('page-tasks-line'));

class _OpenGate implements HiddenNotesGate {
  @override
  Future<bool> ensureConfigured(BuildContext context) async => true;

  @override
  Future<bool> unlock(BuildContext context) async => true;

  @override
  Future<bool> usesPin() async => false;

  @override
  Future<bool> changePin(BuildContext context) async => false;
}

Finder day(int date) => find.byKey(ValueKey('day-strip-2025-11-$date'));

void main() {
  setUpAll(loadTestFonts);

  setUp(() async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    store = MemoryStore();
    store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
    store.data['notes.v1'] = [
      _note('mon-a', 'Gym plan\nLegs', DateTime(2025, 11, 17, 7, 30)),
      _note('mon-b', 'Budget\nRent', DateTime(2025, 11, 17, 18, 10)),
      _note('tue', 'Standup notes\nShip it', DateTime(2025, 11, 18, 10, 5)),
      _note(
        'renewal',
        'Renewal notes\nScope and contract\n☐ Send the renewal\n'
            '☐ Read the signed copy',
        DateTime(2025, 11, 17, 21, 0),
      ),
      _note('errands', 'Errands\n☐ Buy milk', DateTime(2025, 11, 19, 8, 0)),
      _note(
        'arjun',
        'Call with Arjun\nPricing page by Friday.\n☐ Send the deck',
        DateTime(2025, 11, 19, 8, 55),
      ),
    ];
    notes = NotesStore(store, now: () => _now);
    prefs = LayoutPrefs(store);
    tags = TagStore(store, now: () => _now);
    await tags.load();
    folders = FolderStore(store, now: () => _now);
    await folders.load();
    days = NoteDayStore(store, now: () => _now);
    await days.load();
    tasks = TaskLibrary(
      notes: notes,
      store: store,
      storage: MemoryDocStorage(),
      now: () => _now,
    );
  });

  tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

  /// Files Call with Arjun in Work › Clients › Acme, with two tags, and
  /// gives Renewal notes Fri 21.
  void seed({List<String> path = const ['Work', 'Clients', 'Acme']}) {
    String? parent;
    for (final name in path) {
      parent = folders.create(name, parentId: parent)!.id;
    }
    folders.file(['arjun'], parent);
    tags.setTags('arjun', [tags.create('Work')!.id, tags.create('Acme')!.id]);
    days.setDay('renewal', DateTime(2025, 11, 21));
  }

  Future<void> pump(
    WidgetTester tester, {
    double width = 390,
    bool withTasks = true,
    Account? account,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 844);
    addTearDown(tester.view.reset);
    await notes.load();
    prefs.load();
    await tester.pumpWidget(
      KapyNotesApp(
        store: store,
        notes: notes,
        rates: RatesRepository(store),
        prefs: prefs,
        shortcuts: ShortcutPrefs(store)..load(),
        tags: tags,
        folders: folders,
        days: days,
        tasks: withTasks ? tasks : null,
        account: account,
        hiddenNotesGate: _OpenGate(),
      ),
    );
    if (withTasks) await tester.runAsync(tasks.reconcileNow);
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester, int date) async {
    await tester.tap(day(date));
    await tester.pumpAndSettle();
  }

  Future<void> openMore(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('page-more')));
    await tester.pumpAndSettle();
  }

  group('the header', () {
    testWidgets('has Home, the day, and More, with no Notes back and no '
        'sage Share', (tester) async {
      seed();
      await pump(tester);
      expect(openNoteBody(tester), startsWith('Call with Arjun'));

      final home = find.byKey(const ValueKey('page-home'));
      expect(
        find.descendant(of: home, matching: find.text('Home')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('page-day')),
          matching: find.text('19'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('page-more')), findsOneWidget);
      expect(find.byKey(const ValueKey('page-back')), findsNothing);
      expect(find.byKey(const ValueKey('page-share')), findsNothing);
      expect(find.text('Notes'), findsNothing);
      for (final key in ['page-home', 'page-day', 'page-more']) {
        final size = tester.getSize(find.byKey(ValueKey(key)));
        expect(size.height, greaterThanOrEqualTo(44), reason: key);
        expect(size.width, greaterThanOrEqualTo(44), reason: key);
      }

      // ⌂ is Hugeicons' house, on a code point of its own: #303's chat
      // history took the one it had.
      expect(
        find.descendant(
          of: home,
          matching: findKapyIcon(KapyIcons.homeOutlined),
        ),
        findsOneWidget,
      );
      expect(KapyIcons.homeOutlined.paths, same(HugeIcons.strokeRoundedHome03));
      expect(
        KapyIcons.homeOutlined.codePoint,
        isNot(KapyIcons.chatHistoryOutlined.codePoint),
      );

      await tester.tap(home);
      await tester.pumpAndSettle();
      expect(header, findsNothing);
      expect(find.byKey(const ValueKey('home-title-notes')), findsOneWidget);
    });

    testWidgets("the day is a small chip on the control fill, today's "
        'figure sage, in a 44 pt target', (tester) async {
      seed();
      await pump(tester);
      final palette = tester.element(header).palette;
      final chip = find.byKey(const ValueKey('page-day-chip'));
      Color figure(String date) => tester
          .widget<Text>(find.descendant(of: chip, matching: find.text(date)))
          .style!
          .color!;

      final size = tester.getSize(chip);
      expect(size.width, inInclusiveRange(28, 34));
      expect(size.height, inInclusiveRange(26, 30));
      expect(
        tester.getSize(find.byKey(const ValueKey('page-day'))),
        const Size(44, 44),
      );
      expect(
        (tester.widget<Container>(chip).decoration! as BoxDecoration).color,
        palette.controlBackground,
      );
      expect(figure('19'), palette.accentText);

      await open(tester, 21);
      expect(
        (tester.widget<Container>(chip).decoration! as BoxDecoration).color,
        palette.controlBackground,
      );
      expect(figure('21'), palette.textPrimary);
    });

    testWidgets('the day button hides the week and its tasks line, and '
        'shows them again', (tester) async {
      seed();
      await pump(tester);
      expect(day(19), findsOneWidget);
      expect(tasksLine, findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('page-day')));
      await tester.pumpAndSettle();
      expect(day(19), findsNothing);
      expect(tasksLine, findsNothing);

      await tester.tap(find.byKey(const ValueKey('page-day')));
      await tester.pumpAndSettle();
      expect(day(19), findsOneWidget);
    });

    testWidgets('while the keyboard is up its buttons step back, and the '
        'week, its tasks line and the path stay (M08)', (tester) async {
      seed();
      await pump(tester);
      final row = find.byKey(const ValueKey('phone-note-header-row'));
      double opacity() => tester.widget<AnimatedOpacity>(row).opacity;
      expect(opacity(), 1);

      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      expect(opacity(), 0.5);
      expect(day(19), findsOneWidget);
      expect(tasksLine, findsOneWidget);
      expect(find.byKey(const ValueKey('note-path')), findsOneWidget);

      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pumpAndSettle();
      expect(opacity(), 1);
    });
  });

  group('the week', () {
    testWidgets('is seven days from the first weekday, across the width, '
        'with today marked', (tester) async {
      seed();
      await pump(tester);
      // The app's weeks start on Sunday, as the Mac's calendar does.
      for (var date = 16; date <= 22; date++) {
        expect(
          find.descendant(of: header, matching: day(date)),
          findsOneWidget,
          reason: 'Nov $date',
        );
      }
      expect(day(15), findsNothing);
      expect(day(23), findsNothing);
      expect(
        tester.getSemantics(day(19)),
        isSemantics(label: 'Today, Wednesday, 19 November, 2 notes'),
      );
      final first = tester.getRect(day(16));
      final last = tester.getRect(day(22));
      expect(first.width, greaterThanOrEqualTo(44));
      expect(first.height, greaterThanOrEqualTo(44));
      expect(last.right - first.left, greaterThan(390 - 2 * 28 - 1));
    });

    testWidgets('a day with one note opens it, a day with two lists them, '
        'and a day with none opens a page to write on it', (tester) async {
      seed();
      await pump(tester);

      await open(tester, 18);
      expect(openNoteBody(tester), startsWith('Standup notes'));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('page-day')),
          matching: find.text('18'),
        ),
        findsOneWidget,
      );

      await open(tester, 17);
      expect(find.byKey(const ValueKey('day-list-mon-a')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('day-list-mon-b')));
      await tester.pumpAndSettle();
      expect(openNoteBody(tester), startsWith('Budget'));

      await open(tester, 20);
      expect(openNoteBody(tester), isNot(startsWith('Budget')));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('page-day')),
          matching: find.text('20'),
        ),
        findsOneWidget,
      );
      expect(day(20), findsOneWidget);
    });

    testWidgets('a note given a day in another week opens on that week, '
        'with its day picked and filled', (tester) async {
      seed();
      days.setDay('arjun', DateTime(2025, 11, 14));
      await pump(tester);
      expect(openNoteBody(tester), startsWith('Call with Arjun'));
      expect(find.descendant(of: header, matching: day(14)), findsOneWidget);
      expect(day(19), findsNothing);
      expect(tester.getSemantics(day(14)), isSemantics(isSelected: true));
      final shown = tester.widget(day(14)) as dynamic;
      expect(shown.filled, isTrue);
    });

    testWidgets('the keyboard sliding in rebuilds the page, not the whole '
        'app (M08)', (tester) async {
      seed();
      await pump(tester);
      var rebuilds = 0;
      debugOnRebuildDirtyWidget = (element, _) {
        if (element.widget is HomePage) rebuilds++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = null);
      for (var step = 1; step <= 10; step++) {
        tester.view.viewInsets = FakeViewPadding(bottom: 30.0 * step);
        await tester.pump();
      }
      expect(rebuilds, 0);
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const ValueKey('phone-note-header-row')),
            )
            .opacity,
        0.5,
      );
    });

    testWidgets("a blank day's page keeps the header's buttons at full "
        'strength with the keyboard up, until its first words (M11)', (
      tester,
    ) async {
      seed();
      await pump(tester);
      await open(tester, 20);
      final row = find.byKey(const ValueKey('phone-note-header-row'));
      double opacity() => tester.widget<AnimatedOpacity>(row).opacity;

      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      expect(opacity(), 1);

      await tester.enterNote('Lunch');
      await tester.pumpAndSettle();
      expect(opacity(), 0.5);
    });

    testWidgets('a day with none opens a blank page: no title and no time, '
        'only "Start typing…", and the first words give it that day (M11)', (
      tester,
    ) async {
      seed();
      await pump(tester);
      await open(tester, 20);
      expect(openNoteBody(tester), isEmpty);
      expect(find.text('New Note'), findsNothing);
      expect(find.byKey(const ValueKey('note-edited')), findsNothing);
      expect(find.text('Start typing…'), findsOneWidget);

      await tester.enterNote('Lunch');
      await tester.pumpAndSettle();
      final lunch = notes
          .search('')
          .singleWhere((note) => note.body.startsWith('Lunch'));
      expect(days.dayOf(lunch.id), DateTime(2025, 11, 20));
      expect(find.text('Start typing…'), findsNothing);
    });

    testWidgets('a day with none, tapped while a New Note is still blank, '
        'opens that page empty, with no second note (M11)', (tester) async {
      seed();
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('page-home')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('phone-new')));
      await tester.pumpAndSettle();
      expect(openNoteBody(tester), 'New Note');
      final count = notes.notes.length;

      await open(tester, 20);
      expect(notes.notes.length, count);
      expect(openNoteBody(tester), isEmpty);
      expect(find.text('New Note'), findsNothing);
      expect(find.text('Start typing…'), findsOneWidget);
    });

    testWidgets('at 360 every day keeps 44 to tap, the arrows narrower', (
      tester,
    ) async {
      seed();
      await pump(tester, width: 360);
      expect(tester.takeException(), isNull);
      for (var date = 16; date <= 22; date++) {
        expect(tester.getSize(day(date)).width, greaterThanOrEqualTo(44));
      }
      expect(
        tester.getSize(find.byKey(const ValueKey('day-strip-back'))).width,
        lessThan(28),
      );
    });

    testWidgets('the arrows move a week at a time', (tester) async {
      seed();
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('day-strip-back')));
      await tester.pumpAndSettle();
      expect(day(9), findsOneWidget);
      expect(day(16), findsNothing);
    });
  });

  group('the tasks line', () {
    testWidgets("counts today's tasks and opens the tasks sheet", (
      tester,
    ) async {
      seed();
      await pump(tester);
      // Send the deck and Buy milk; Renewal notes' two wait for Fri 21.
      expect(
        find.descendant(of: tasksLine, matching: find.text('2 tasks today')),
        findsOneWidget,
      );
      expect(tester.getSize(tasksLine).height, greaterThanOrEqualTo(44));

      await tester.tap(tasksLine);
      await tester.pumpAndSettle();
      final sheet = find.byKey(const ValueKey('phone-tasks-sheet'));
      expect(sheet, findsOneWidget);
      expect(
        tester.widget<TasksScreen>(
          find.descendant(of: sheet, matching: find.byType(TasksScreen)),
        ),
        isA<TasksScreen>().having((screen) => screen.sheet, 'sheet', isTrue),
      );
      // Choosing in the sheet reaches Do now over Up next, as M15 shows it.
      await tester.tap(find.byKey(const ValueKey('tasks-pair-right')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tasks-do-now')), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('phone-tasks-sheet-close')));
      await tester.pumpAndSettle();
      expect(sheet, findsNothing);
    });

    testWidgets('on a note given Fri 21 it counts that day\'s tasks', (
      tester,
    ) async {
      seed();
      await pump(tester);
      await open(tester, 21);
      expect(openNoteBody(tester), startsWith('Renewal notes'));
      expect(
        find.descendant(
          of: tasksLine,
          matching: find.text('2 tasks on Fri 21'),
        ),
        findsOneWidget,
      );
    });

    testWidgets("on an earlier day's note it says today, as the list it "
        'counts is today\'s', (tester) async {
      seed();
      await pump(tester);
      await open(tester, 18);
      expect(openNoteBody(tester), startsWith('Standup notes'));
      expect(
        find.descendant(of: tasksLine, matching: find.text('2 tasks today')),
        findsOneWidget,
      );
    });

    testWidgets('is left out on a day with no tasks', (tester) async {
      seed();
      days.setDay('tue', DateTime(2025, 11, 22));
      await pump(tester);
      await open(tester, 22);
      expect(openNoteBody(tester), startsWith('Standup notes'));
      expect(tasksLine, findsNothing);
      expect(day(22), findsOneWidget);
    });

    testWidgets('is left out where the app has no Tasks', (tester) async {
      seed();
      await pump(tester, withTasks: false);
      expect(tasksLine, findsNothing);
      expect(day(19), findsOneWidget);
    });
  });

  group('under the title', () {
    testWidgets('the folder path, then the time and the tags, with no + Tag', (
      tester,
    ) async {
      seed();
      await pump(tester);
      final path = find.byKey(const ValueKey('note-path'));
      for (final name in ['Work', 'Clients', 'Acme']) {
        expect(
          find.descendant(of: path, matching: find.text(name)),
          findsOneWidget,
        );
      }
      final edited = find.byKey(const ValueKey('note-edited'));
      expect(tester.widget<Text>(edited).data, '8:55');
      expect(find.byKey(const ValueKey('note-day-pill')), findsNothing);
      expect(find.byKey(const ValueKey('note-add-tag')), findsNothing);
      expect(find.text('Acme'), findsNWidgets(2));
      expect(tester.getRect(path).bottom, lessThan(tester.getRect(edited).top));
    });

    testWidgets("an earlier day's note says its day and time, and a note "
        'given another day says the day alone', (tester) async {
      seed();
      await pump(tester);
      String edited() =>
          tester.widget<Text>(find.byKey(const ValueKey('note-edited'))).data!;

      await open(tester, 18);
      expect(edited(), 'Tue 18 · 10:05');

      // Written Mon 17 at 21:00 and given Fri 21: that time is not Friday's.
      await open(tester, 21);
      expect(edited(), 'Fri 21');
      expect(find.byKey(const ValueKey('note-path')), findsNothing);
    });

    testWidgets("typing leaves the note's own time on the line, not the "
        'edit (M08)', (tester) async {
      seed();
      await pump(tester);
      String edited() =>
          tester.widget<Text>(find.byKey(const ValueKey('note-edited'))).data!;
      expect(edited(), '8:55');

      await tester.enterNote(
        openNoteField(
          tester,
        ).controller.text.replaceFirst('Friday.', 'Friday. Then Finance.'),
      );
      await tester.pumpAndSettle();
      expect(notes.byId('arjun')!.updatedAt, _now);
      expect(edited(), '8:55');
    });

    testWidgets("a Mac's line keeps the note's last edit, where a phone's "
        'keeps the time it was written (D01)', (tester) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
      final arjun = (store.data['notes.v1']! as List).last as Map;
      arjun['updatedAt'] = DateTime(2025, 11, 19, 9, 30).millisecondsSinceEpoch;
      seed();
      await pump(tester, width: 1400);
      await tester.tap(find.widgetWithText(NoteRow, 'Call with Arjun'));
      await tester.pumpAndSettle();
      final line = tester
          .widget<Text>(find.byKey(const ValueKey('note-edited')))
          .data!;
      expect(line, contains('9:30'));
      expect(line, isNot(contains('8:55')));
    });

    for (final (width, count) in [(360.0, 4), (390.0, 6)]) {
      testWidgets('$count tags at $width wrap onto a line of their own, and '
          'the writing starts under them', (tester) async {
        seed();
        for (final name in ['Travel', 'Money', 'Home', 'Errands']) {
          if (tags.tagsOf('arjun').length >= count) break;
          tags.addTag('arjun', tags.create(name)!.id);
        }
        await pump(tester, width: width);
        expect(tester.takeException(), isNull);
        final facts = tester.getRect(find.byKey(const ValueKey('note-facts')));
        final meta = tester.getRect(find.byType(NoteMetaRow));
        expect(meta.bottom, greaterThan(facts.bottom + 10), reason: 'wrapped');
        expect(meta.right, lessThanOrEqualTo(width));
        final body = openNoteBody(tester);
        final driver = NoteDriver(tester);
        final at = body.indexOf('Pricing');
        final first = driver
            .boxesFor(TextSelection(baseOffset: at, extentOffset: at + 1))
            .first;
        // The gap under the row stays, rather than the second line eating
        // into it.
        expect(
          driver.state.box!.localToGlobal(Offset(0, first.top)).dy -
              meta.bottom,
          greaterThanOrEqualTo(EditorMetrics.metaBottom - 4),
        );
      });
    }

    testWidgets('a long path folds its middle at 375 and nothing overflows', (
      tester,
    ) async {
      seed(
        path: const [
          'Work and everything around it',
          'Clients we look after',
          'Acme Corporation',
          'Renewals for next year',
        ],
      );
      await pump(tester, width: 375);
      expect(find.byKey(const ValueKey('note-path-fold')), findsOneWidget);
      final path = tester.getRect(find.byKey(const ValueKey('note-path')));
      expect(path.right, lessThanOrEqualTo(375));
      expect(tester.takeException(), isNull);
      for (var date = 16; date <= 22; date++) {
        expect(day(date), findsOneWidget);
      }
    });
  });

  group('More', () {
    Future<Account> signedOut(WidgetTester tester) async {
      final syncState = SyncState(store);
      final account = Account(
        auth: FakeAuth(),
        syncApi: (_) =>
            FakeApi(FakeServer(), device: 'device-1', userId: 'user-1'),
        keys: KeyStore(InMemorySecureStore()),
        notes: notes,
        state: syncState,
        store: store,
        tags: tags,
        tasks: tasks,
      );
      addTearDown(account.dispose);
      await tester.runAsync(account.restore);
      expect(account.state, AccountState.signedOut);
      return account;
    }

    const order = [
      'day',
      'undate',
      'pin',
      'share',
      'folder',
      'tags',
      'hide',
      'archive',
      'delete',
    ];
    Finder item(String value) => find.byKey(ValueKey('page-more-$value'));

    testWidgets("lists M09's nine in their four groups, Move to another day "
        'first and Share among them', (tester) async {
      seed();
      await pump(tester, account: await signedOut(tester));
      await open(tester, 21);
      await openMore(tester);

      final tops = [for (final value in order) tester.getRect(item(value)).top];
      expect(tops, orderedEquals([...tops]..sort()));
      expect(find.byType(PopupMenuDivider), findsNWidgets(3));
      double divider(int index) =>
          tester.getRect(find.byType(PopupMenuDivider).at(index)).center.dy;
      expect(divider(0), inExclusiveRange(tops[1], tops[2]));
      expect(divider(1), inExclusiveRange(tops[5], tops[6]));
      expect(divider(2), inExclusiveRange(tops[6], tops[7]));
      for (final (value, label) in [
        ('day', 'Move to another day'),
        ('undate', 'Remove day'),
        ('pin', 'Pin note'),
        ('share', 'Share note'),
        ('folder', 'Move to folder…'),
        ('tags', 'Tags'),
        ('hide', 'Move to Hidden Notes'),
        ('archive', 'Archive note'),
        ('delete', 'Delete note…'),
      ]) {
        expect(
          find.descendant(of: item(value), matching: find.text(label)),
          findsOneWidget,
        );
        expect(tester.getSize(item(value)).height, greaterThanOrEqualTo(44));
      }
    });

    testWidgets('each item does what it says', (tester) async {
      seed();
      await pump(tester, account: await signedOut(tester));
      await open(tester, 21);
      Future<void> pick(String value) async {
        await openMore(tester);
        await tester.tap(item(value));
        await tester.pumpAndSettle();
      }

      await pick('day');
      expect(find.byType(DayPicker), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('day-month-2025-11-25')));
      await tester.pumpAndSettle();
      expect(days.dayOf('renewal'), DateTime(2025, 11, 25));

      await pick('undate');
      expect(days.dayOf('renewal'), isNull);

      await pick('pin');
      expect(notes.isPinned('renewal'), isTrue);

      await pick('tags');
      expect(find.byType(TagPicker), findsOneWidget);
      await tester.tapAt(const Offset(10, 800));
      await tester.pumpAndSettle();

      await pick('folder');
      expect(find.text('Work'), findsWidgets);
      await tester.tapAt(const Offset(10, 800));
      await tester.pumpAndSettle();

      await pick('share');
      expect(find.byType(SettingsDialog), findsOneWidget);
      expect(find.text('Sign in first to share this note'), findsOneWidget);
    });

    testWidgets('Move to another day is a sheet under its name, with the '
        "month, Today, and the note's day filled (M12)", (tester) async {
      seed();
      await pump(tester);
      await open(tester, 21);
      await openMore(tester);
      await tester.tap(item('day'));
      await tester.pumpAndSettle();

      final sheet = find.byKey(const ValueKey('day-sheet'));
      expect(sheet, findsOneWidget);
      expect(
        find.descendant(of: sheet, matching: find.text('Move to another day')),
        findsOneWidget,
      );
      final month = find.byKey(const ValueKey('day-month-name'));
      expect(tester.widget<Text>(month).data, 'November');
      expect(find.byKey(const ValueKey('day-month-back')), findsNothing);
      expect(
        tester.getSemantics(find.byKey(const ValueKey('day-month-2025-11-21'))),
        isSemantics(isSelected: true),
      );

      for (var date = 16; date <= 22; date++) {
        expect(
          tester
              .getSize(find.byKey(ValueKey('day-month-2025-11-$date')))
              .height,
          greaterThanOrEqualTo(44),
        );
      }

      await tester.fling(
        find.byKey(const ValueKey('day-month-2025-11-12')),
        const Offset(-300, 0),
        1000,
      );
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(month).data, 'December');

      await tester.tap(find.byKey(const ValueKey('day-month-today')));
      await tester.pumpAndSettle();
      expect(sheet, findsNothing);
      expect(days.dayOf('renewal'), DateTime(2025, 11, 19));
    });

    testWidgets('a narrow Mac window gives Move to another day the popover, '
        'not the sheet', (tester) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
      seed();
      await pump(tester, width: 600);
      await tester.tap(find.byKey(const ValueKey('page-more')).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('page-more-day')));
      await tester.pumpAndSettle();
      expect(find.byType(DayPicker), findsOneWidget);
      expect(find.byKey(const ValueKey('day-sheet')), findsNothing);
    });

    testWidgets('Archive and Delete note… take the note away', (tester) async {
      seed();
      await pump(tester);
      await openMore(tester);
      await tester.tap(item('archive'));
      await tester.pumpAndSettle();
      expect(notes.byId('arjun')!.isArchived, isTrue);

      await tester.tap(find.text('Errands').first);
      await tester.pumpAndSettle();
      await openMore(tester);
      await tester.tap(item('delete'));
      await tester.pumpAndSettle();
      expect(find.text('Delete note?'), findsOneWidget);
    });

    testWidgets('Move to Hidden Notes hides the note', (tester) async {
      seed();
      await pump(tester);
      await openMore(tester);
      await tester.tap(item('hide'));
      await tester.pumpAndSettle();
      expect(notes.byId('arjun')!.isHidden, isTrue);
    });

    testWidgets('signed out with no account at all, Share is not offered', (
      tester,
    ) async {
      seed();
      await pump(tester);
      await openMore(tester);
      expect(item('share'), findsNothing);
      expect(item('day'), findsOneWidget);
      expect(item('undate'), findsNothing);
    });
  });

  group('Home', () {
    Future<void> tap(WidgetTester tester, String key) async {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
    }

    Future<void> homeFrom(WidgetTester tester, String title) async {
      await tester.tap(find.widgetWithText(NoteRow, title));
      await tester.pumpAndSettle();
      expect(header, findsOneWidget);
      await tap(tester, 'page-home');
      expect(header, findsNothing);
      expect(find.byKey(const ValueKey('home-title-notes')), findsOneWidget);
    }

    for (final filter in ['archive', 'hidden']) {
      testWidgets('from a note in the $filter list goes to Home, not back to '
          'that list', (tester) async {
        seed();
        await pump(tester);
        filter == 'archive' ? notes.archive('mon-a') : notes.hide('mon-a');
        await tap(tester, 'page-home');
        await tap(tester, 'phone-filters');
        await tap(tester, 'sidebar-notes-filter');
        await tap(tester, 'notes-filter-$filter');
        await homeFrom(tester, 'Gym plan');
      });
    }

    testWidgets("from a folder's note in Folders goes to Home, not back to "
        'the folder', (tester) async {
      seed(path: const ['Work']);
      await pump(tester);
      final work = folders.tree.top.single;
      await tap(tester, 'page-home');
      await tap(tester, 'bar-folders');
      await tap(tester, 'folder-${work.id}');
      await homeFrom(tester, 'Call with Arjun');
      expect(find.byKey(ValueKey('phone-folder-${work.id}')), findsNothing);
      expect(
        tester.widget<PhoneSpaces>(find.byType(PhoneSpaces)).tab,
        PhoneTab.notes,
      );
    });

    testWidgets("a note moved to a later day leaves Home's list and waits "
        'under Upcoming', (tester) async {
      seed();
      await pump(tester);
      final arjun = find.widgetWithText(NoteRow, 'Call with Arjun');
      await tap(tester, 'page-home');
      expect(arjun, findsOneWidget);
      await tester.tap(arjun);
      await tester.pumpAndSettle();

      await openMore(tester);
      await tap(tester, 'page-more-day');
      await tap(tester, 'day-month-2025-11-25');
      expect(days.dayOf('arjun'), DateTime(2025, 11, 25));

      await tap(tester, 'page-home');
      expect(arjun, findsNothing);
      await tap(tester, 'bar-folders');
      await tap(tester, 'folders-upcoming-tile');
      expect(find.byKey(const ValueKey('phone-upcoming')), findsOneWidget);
      expect(arjun, findsOneWidget);
    });

    testWidgets('from a drawing goes to Home, not back to Drawings', (
      tester,
    ) async {
      (store.data['notes.v1']! as List).add({
        'id': 'sketch',
        'body': 'Floor plan',
        'createdAt': DateTime(2025, 11, 18, 9).millisecondsSinceEpoch,
        'updatedAt': DateTime(2025, 11, 18, 9).millisecondsSinceEpoch,
        'drawing': {'elements': <Object?>[]},
      });
      seed();
      await pump(tester);
      await tap(tester, 'page-home');
      await tap(tester, 'bar-folders');
      await tap(tester, 'folders-drawings-tile');
      await homeFrom(tester, 'Floor plan');
    });
  });

  group('large text', () {
    for (final scale in [2.0, 3.1]) {
      testWidgets('at $scale× nothing overflows and the title keeps its '
          'words whole', (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        seed();
        await pump(tester, width: 375);
        expect(tester.takeException(), isNull);
        final home = tester.getRect(find.text('Home'));
        expect(home.height, lessThan(2 * 20 * 1.3));
        for (var date = 16; date <= 22; date++) {
          expect(day(date), findsOneWidget);
        }
        final boxes = NoteDriver(
          tester,
        ).boxesFor(const TextSelection(baseOffset: 0, extentOffset: 4));
        expect(
          boxes.map((box) => box.top).toSet(),
          hasLength(1),
          reason: '"Call" sits on one line',
        );

        await openMore(tester);
        expect(tester.takeException(), isNull);
      });
    }
  });

  test('the tasks line says one task, several, and another day', () {
    final wed = DateTime(2025, 11, 19);
    final fri = DateTime(2025, 11, 21);
    expect(PhoneNoteHeader.tasksLine(1, wed, wed), '1 task today');
    expect(PhoneNoteHeader.tasksLine(6, wed, wed), '6 tasks today');
    expect(PhoneNoteHeader.tasksLine(2, fri, wed), '2 tasks on Fri 21');
  });
}
