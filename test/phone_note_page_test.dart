import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/semantics.dart'
    show CustomSemanticsAction, SemanticsAction, SemanticsNode;
import 'package:flutter_test/flutter_test.dart';
import 'package:hugeicons/hugeicons.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/audio/voice_recording_controller.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/day_tabs.dart';
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
import 'package:kapy_notes/ui/day_tabs_row.dart' show DayTabsRow;
import 'package:kapy_notes/ui/editor/note_editor.dart'
    show NoteEditor, NoteEditorState;
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
late DayTabsStore dayTabs;
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
    dayTabs = DayTabsStore(store, now: () => _now);
    await dayTabs.load();
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
    VoiceRecordingController? recording,
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
        dayTabs: dayTabs,
        tasks: withTasks ? tasks : null,
        account: account,
        recording: recording,
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

    testWidgets(
      'a screen reader hears Home and the day in plain words, and presses '
      'each as a tap does (KAP-361)',
      (tester) async {
        final semantics = tester.ensureSemantics();
        AppPlatform.debugTargetPlatformOverride = defaultTargetPlatform;
        seed();
        await pump(tester);
        SemanticsNode node(String key) =>
            tester.getSemantics(find.byKey(ValueKey(key)));
        Future<void> press(String key) async {
          final id = node(key).id;
          tester.semantics.tap(find.semantics.byPredicate((n) => n.id == id));
          await tester.pumpAndSettle();
        }

        expect(
          node('page-day'),
          isSemantics(
            label: 'Hide the week',
            isButton: true,
            hasToggledState: true,
            isToggled: true,
            hasTapAction: true,
          ),
        );
        await press('page-day');
        expect(day(19), findsNothing);
        expect(tasksLine, findsNothing);
        expect(
          node('page-day'),
          isSemantics(
            label: 'Show the week',
            isButton: true,
            hasToggledState: true,
            isToggled: false,
            hasTapAction: true,
          ),
        );
        await press('page-day');
        expect(day(19), findsOneWidget);
        expect(tasksLine, findsOneWidget);

        expect(
          node('page-home'),
          isSemantics(label: 'Home', isButton: true, hasTapAction: true),
        );
        await press('page-home');
        expect(header, findsNothing);
        expect(find.byKey(const ValueKey('home-title-notes')), findsOneWidget);
        semantics.dispose();
      },
      variant: TargetPlatformVariant(const {
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );

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

    testWidgets('a day with one note opens it, a day with two opens them as '
        'tabs, and a day with none opens a page to write on it', (
      tester,
    ) async {
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
      expect(openNoteBody(tester), startsWith('Gym plan'));
      await tester.tap(find.byKey(const ValueKey('day-tab-mon-b')));
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

    /// The days the week shows, by their keys' dates, oldest first.
    List<String> shown() => [
      for (final element
          in find
              .byWidgetPredicate(
                (widget) => switch (widget.key) {
                  ValueKey<String>(:final value) => value.startsWith(
                    'day-strip-2',
                  ),
                  _ => false,
                },
              )
              .evaluate())
        (element.widget.key! as ValueKey<String>).value.substring(
          'day-strip-'.length,
        ),
    ];

    /// The seven days from [sunday], as [shown] gives them.
    List<String> weekFrom(DateTime sunday) => [
      for (var index = 0; index < 7; index++)
        switch (DateTime(sunday.year, sunday.month, sunday.day + index)) {
          final day => '${day.year}-${day.month}-${day.day}',
        },
    ];

    testWidgets('a swipe on the days turns them under the finger, and let go '
        'they rest on the nearest whole week (KAP-340)', (tester) async {
      seed();
      await pump(tester);
      final slot = tester.getRect(day(16));
      final gesture = await tester.startGesture(tester.getCenter(day(19)));
      await gesture.moveBy(const Offset(-30, 0));
      await gesture.moveBy(const Offset(-100, 0));
      await tester.pump();
      expect(tester.getRect(day(16)).left, moreOrLessEquals(slot.left - 100));
      expect(day(23), findsOneWidget, reason: 'the next week follows it in');

      // Let go short of half a week, it goes back.
      await gesture.up();
      await tester.pumpAndSettle();
      expect(shown(), weekFrom(DateTime(2025, 11, 16)));
      expect(tester.getRect(day(16)), slot);

      // Past half a week, it goes on to the next, and the note stays.
      await tester.drag(day(19), const Offset(-220, 0));
      await tester.pumpAndSettle();
      expect(shown(), weekFrom(DateTime(2025, 11, 23)));
      expect(tester.getRect(day(23)), slot);
      expect(openNoteBody(tester), startsWith('Call with Arjun'));

      await tester.drag(day(26), const Offset(220, 0));
      await tester.pumpAndSettle();
      expect(shown(), weekFrom(DateTime(2025, 11, 16)));
    });

    testWidgets(
      'a fling carries the days on a week or a few, as hard as it is, to '
      'rest on a whole one (KAP-340)',
      (tester) async {
        seed();
        await pump(tester);
        final slot = tester.getRect(day(16));
        await tester.fling(day(19), const Offset(-150, 0), 3000);
        await tester.pumpAndSettle();
        expect(shown(), weekFrom(DateTime(2025, 11, 30)));
        expect(tester.getRect(day(30)), slot);

        // The hardest fling there is goes four weeks on, not months.
        await tester.fling(day(30), const Offset(-150, 0), 8000);
        await tester.pumpAndSettle();
        expect(shown(), weekFrom(DateTime(2025, 12, 28)));
        expect(
          tester.getRect(find.byKey(const ValueKey('day-strip-2025-12-28'))),
          slot,
        );
      },
      variant: TargetPlatformVariant(const {
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );

    testWidgets(
      'a short slow fling still turns one week, either way (KAP-340)',
      (tester) async {
        seed();
        await pump(tester);
        await tester.fling(day(19), const Offset(-60, 0), 400);
        await tester.pumpAndSettle();
        expect(shown(), weekFrom(DateTime(2025, 11, 23)));
        await tester.fling(day(26), const Offset(60, 0), 400);
        await tester.pumpAndSettle();
        expect(shown(), weekFrom(DateTime(2025, 11, 16)));
      },
      variant: TargetPlatformVariant(const {
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );

    testWidgets('a day on the week a swipe turned to opens its note, and the '
        "note moved to another week brings that week", (tester) async {
      seed();
      days.setDay('tue', DateTime(2025, 11, 25));
      await pump(tester);
      await tester.drag(day(19), const Offset(-220, 0));
      await tester.pumpAndSettle();
      await open(tester, 25);
      expect(openNoteBody(tester), startsWith('Standup notes'));
      expect(shown(), weekFrom(DateTime(2025, 11, 23)));
      expect(tester.getSemantics(day(25)), isSemantics(isSelected: true));

      await openMore(tester);
      await tester.tap(find.byKey(const ValueKey('page-more-day')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('day-month-2025-11-14')));
      await tester.pumpAndSettle();
      expect(openNoteBody(tester), startsWith('Standup notes'));
      expect(shown(), weekFrom(DateTime(2025, 11, 9)));
      expect(tester.getSemantics(day(14)), isSemantics(isSelected: true));
    });

    testWidgets('a swipe that starts on an arrow turns the week too, and a '
        'drag up or down leaves it', (tester) async {
      seed();
      await pump(tester);
      await tester.drag(
        find.byKey(const ValueKey('day-strip-forward')),
        const Offset(-220, 0),
      );
      await tester.pumpAndSettle();
      expect(shown(), weekFrom(DateTime(2025, 11, 23)));
      await tester.drag(
        find.byKey(const ValueKey('day-strip-back')),
        const Offset(220, 0),
      );
      await tester.pumpAndSettle();
      expect(shown(), weekFrom(DateTime(2025, 11, 16)));

      await tester.drag(day(19), const Offset(0, 150));
      await tester.pumpAndSettle();
      expect(shown(), weekFrom(DateTime(2025, 11, 16)));
      expect(find.byKey(const ValueKey('day-list-errands')), findsNothing);
      expect(openNoteBody(tester), startsWith('Call with Arjun'));
    });

    testWidgets('on an iPhone, a swipe in from the left edge over the week '
        'goes back, and one just inside it turns the week', (tester) async {
      seed();
      await pump(tester);
      await open(tester, 18);
      expect(openNoteBody(tester), startsWith('Standup notes'));
      final y = tester.getCenter(day(18)).dy;

      // From the edge: back to the note the week opened it from.
      await tester.dragFrom(Offset(4, y), const Offset(300, 0));
      await tester.pumpAndSettle();
      expect(openNoteBody(tester), startsWith('Call with Arjun'));
      expect(shown(), weekFrom(DateTime(2025, 11, 16)));

      // Just inside it, on ‹: the week before, on the same note.
      await tester.dragFrom(Offset(24, y), const Offset(220, 0));
      await tester.pumpAndSettle();
      expect(shown(), weekFrom(DateTime(2025, 11, 9)));
      expect(openNoteBody(tester), startsWith('Call with Arjun'));

      // From the edge again: Home.
      await tester.dragFrom(Offset(4, y), const Offset(300, 0));
      await tester.pumpAndSettle();
      expect(header, findsNothing);
      expect(find.byKey(const ValueKey('home-title-notes')), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('quick taps on › turn a week each, and with animations off '
        'a tap turns at once', (tester) async {
      seed();
      await pump(tester);
      final forward = find.byKey(const ValueKey('day-strip-forward'));
      await tester.tap(forward);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(forward);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(forward);
      await tester.pumpAndSettle();
      expect(shown(), weekFrom(DateTime(2025, 12, 7)));

      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('day-strip-back')));
      await tester.pump();
      expect(shown(), weekFrom(DateTime(2025, 11, 30)));
    });

    testWidgets('a screen reader turns the weeks with a scroll over the days, '
        'and finds no ‹ or › to press', (tester) async {
      final semantics = tester.ensureSemantics();
      seed();
      await pump(tester);
      for (final arrow in ['day-strip-back', 'day-strip-forward']) {
        final node = tester.getSemantics(find.byKey(ValueKey(arrow)));
        expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
      }

      final strip = tester.getSemantics(find.byType(PageView));
      final weeks = find.semantics.byPredicate((node) => node.id == strip.id);
      tester.semantics.scrollLeft(scrollable: weeks);
      await tester.pumpAndSettle();
      expect(shown(), weekFrom(DateTime(2025, 11, 23)));
      tester.semantics.scrollRight(scrollable: weeks);
      await tester.pumpAndSettle();
      expect(shown(), weekFrom(DateTime(2025, 11, 16)));
      semantics.dispose();
    });

    testWidgets('at large text the days stay whole, and a swipe still turns '
        'the week', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      seed();
      await pump(tester, width: 375);
      expect(tester.takeException(), isNull);
      final strip = tester.getRect(find.byType(PageView));
      expect(tester.getSize(day(19)).height, strip.height);
      expect(strip.height, greaterThan(52));
      await tester.drag(day(19), const Offset(-200, 0));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(shown(), weekFrom(DateTime(2025, 11, 23)));
    });
  });

  group('a day of several, as tabs (KAP-345)', () {
    Finder tab(String id) => find.byKey(ValueKey('day-tab-$id'));
    final row = find.byKey(const ValueKey('day-tabs'));
    final monday = DateTime(2025, 11, 17);

    /// Every note on Monday once Renewal notes is on it, earliest first.
    const wholeMonday = ['mon-a', 'mon-b', 'renewal'];

    /// [ids] as the row shows them, from the left.
    List<String> shown(WidgetTester tester, List<String> ids) => [...ids]
      ..sort(
        (a, b) =>
            tester.getRect(tab(a)).left.compareTo(tester.getRect(tab(b)).left),
      );

    testWidgets('open under the week, earliest first, on the first; a tab '
        "opens its note in place, and Back leaves the day for the note it "
        'was picked on (A1, A2)', (tester) async {
      seed();
      await pump(tester);
      expect(openNoteBody(tester), startsWith('Call with Arjun'));
      expect(row, findsNothing);
      expect(tasksLine, findsOneWidget);

      await open(tester, 17);
      expect(openNoteBody(tester), startsWith('Gym plan'));
      expect(shown(tester, ['mon-b', 'mon-a']), ['mon-a', 'mon-b']);
      expect(
        tester.getRect(row).top,
        greaterThanOrEqualTo(tester.getRect(find.byType(PageView)).bottom),
      );
      expect(tester.getSemantics(tab('mon-a')), isSemantics(isSelected: true));
      expect(tasksLine, findsNothing, reason: "today's tasks, not Mon 17's");

      final week = tester.getRect(find.byType(PageView));
      await tester.tap(tab('mon-b'));
      await tester.pumpAndSettle();
      expect(openNoteBody(tester), startsWith('Budget'));
      expect(tester.getSemantics(tab('mon-b')), isSemantics(isSelected: true));
      expect(tester.getRect(find.byType(PageView)), week);
      expect(dayTabs.owed, isEmpty, reason: 'only a drag or a pin orders');

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(openNoteBody(tester), startsWith('Call with Arjun'));
      expect(row, findsNothing);
      expect(tasksLine, findsOneWidget);
    });

    testWidgets("picked on one of the day's own notes, the tabs come in place, "
        "and today's keep the tasks line", (tester) async {
      seed();
      await pump(tester);
      await open(tester, 19);
      expect(openNoteBody(tester), startsWith('Call with Arjun'));
      expect(shown(tester, ['arjun', 'errands']), ['errands', 'arjun']);
      expect(tester.getSemantics(tab('arjun')), isSemantics(isSelected: true));
      expect(tasksLine, findsOneWidget);
      expect(
        tester.getRect(row).top,
        greaterThanOrEqualTo(tester.getRect(tasksLine).bottom),
      );
    });

    testWidgets('picking another day of several swaps in its tabs, and Back '
        'still goes to the note the first was picked on', (tester) async {
      await pump(tester);
      await open(tester, 17);
      expect(openNoteBody(tester), startsWith('Gym plan'));
      await open(tester, 19);
      expect(openNoteBody(tester), startsWith('Errands'));
      expect(tab('mon-a'), findsNothing);
      expect(shown(tester, ['arjun', 'errands']), ['errands', 'arjun']);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(openNoteBody(tester), startsWith('Call with Arjun'));
      expect(row, findsNothing);
    });

    testWidgets('+ starts a note on the day as a tab at the end, ready to '
        'type, and its first words give it the day (A8)', (tester) async {
      seed();
      await pump(tester);
      await open(tester, 17);
      await tester.tap(find.byKey(const ValueKey('day-tabs-new')));
      await tester.pumpAndSettle();
      expect(openNoteBody(tester), isEmpty);
      final fresh = find.descendant(of: row, matching: find.text('New Note'));
      expect(fresh, findsOneWidget);
      expect(
        tester.getRect(fresh).left,
        greaterThan(tester.getRect(tab('mon-b')).right),
      );
      expect(FocusManager.instance.primaryFocus, isNotNull);

      await tester.enterNote('Lunch');
      await tester.pumpAndSettle();
      final lunch = notes
          .search('')
          .singleWhere((note) => note.body.startsWith('Lunch'));
      expect(days.dayOf(lunch.id), monday);
      expect(shown(tester, ['mon-b', lunch.id, 'mon-a']), [
        'mon-a',
        'mon-b',
        lunch.id,
      ]);
      expect(tester.getSemantics(tab(lunch.id)), isSemantics(isSelected: true));
    });

    testWidgets('a hold, let go, offers Pin tab, which moves the tab to the '
        'front with a pin, and held again Unpin tab (A5, A7)', (tester) async {
      seed();
      await pump(tester);
      await open(tester, 17);
      await tester.longPress(tab('mon-b'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pin tab'));
      await tester.pumpAndSettle();
      expect(shown(tester, ['mon-a', 'mon-b']), ['mon-b', 'mon-a']);
      expect(
        find.descendant(
          of: tab('mon-b'),
          matching: findKapyIcon(KapyIcons.pinOutlined),
        ),
        findsOneWidget,
      );
      expect(dayTabs.arrange(monday, ['mon-a', 'mon-b']).pinned, 1);
      expect(openNoteBody(tester), startsWith('Gym plan'));

      await tester.longPress(tab('mon-b'));
      await tester.pumpAndSettle();
      expect(find.text('Pin tab'), findsNothing);
      await tester.tap(find.text('Unpin tab'));
      await tester.pumpAndSettle();
      expect(findKapyIcon(KapyIcons.pinOutlined), findsNothing);
      expect(dayTabs.arrange(monday, ['mon-a', 'mon-b']).pinned, 0);
    });

    testWidgets('a hold and a slide drags a tab along the row, and the day '
        'keeps that order, opening on its new first tab (A6)', (tester) async {
      seed();
      await pump(tester);
      await open(tester, 17);
      final gesture = await tester.startGesture(tester.getCenter(tab('mon-b')));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      for (var i = 0; i < 7; i++) {
        await gesture.moveBy(const Offset(-20, 0));
        await tester.pump();
      }
      expect(find.byKey(const ValueKey('day-tab-dragged')), findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('Pin tab'), findsNothing, reason: 'a drag has no menu');
      expect(shown(tester, ['mon-a', 'mon-b']), ['mon-b', 'mon-a']);
      expect(dayTabs.arrange(monday, ['mon-a', 'mon-b']).order, [
        'mon-b',
        'mon-a',
      ]);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await open(tester, 17);
      expect(openNoteBody(tester), startsWith('Budget'));
    });

    /// Monday with Renewal notes on it too, its tabs given [pins] through the
    /// store, and the list filtered to Gym, which only [tagged] have: the
    /// first of them open, and Monday's row showing just those.
    Future<void> filteredToGym(
      WidgetTester tester, {
      List<String> tagged = const ['mon-a', 'mon-b'],
      List<String> pins = const [],
    }) async {
      seed();
      final gym = tags.create('Gym')!.id;
      for (final id in tagged) {
        tags.setTags(id, [gym]);
      }
      days.setDay('renewal', monday);
      for (final id in pins.reversed) {
        dayTabs.pin(monday, wholeMonday, id);
      }
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('page-home')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('phone-filters')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('phone-filter-row')),
          matching: find.text('Gym'),
        ),
      );
      await tester.pumpAndSettle();
      final first = const {
        'mon-a': 'Gym plan',
        'mon-b': 'Budget',
        'renewal': 'Renewal notes',
      }[tagged.first]!;
      await tester.tap(find.widgetWithText(NoteRow, first));
      await tester.pumpAndSettle();
      await open(tester, 17);
      for (final id in wholeMonday) {
        expect(tab(id), tagged.contains(id) ? findsOne : findsNothing);
      }
      expect(openNoteBody(tester), startsWith(first));
    }

    /// Holds [id]'s tab and slides it [by] in steps of 20, then lets go.
    Future<void> drag(WidgetTester tester, String id, List<double> by) async {
      final gesture = await tester.startGesture(tester.getCenter(tab(id)));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      for (final dx in by) {
        await gesture.moveBy(Offset(dx, 0));
        await tester.pump();
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('Pin tab'), findsNothing, reason: 'a drag has no menu');
    }

    void expectMonday(List<String> order, int pinned) {
      final tabs = dayTabs.arrange(monday, wholeMonday);
      expect(tabs.order, order);
      expect(tabs.pinned, pinned);
    }

    Future<void> hold(WidgetTester tester, String id, String action) async {
      await tester.longPress(tab(id));
      await tester.pumpAndSettle();
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
    }

    testWidgets('with the list filtered, a pin keeps the pin and the place '
        "of a note the filter leaves out of the day's tabs", (tester) async {
      await filteredToGym(tester, pins: ['renewal']);
      expect(shown(tester, ['mon-a', 'mon-b']), ['mon-a', 'mon-b']);

      await hold(tester, 'mon-b', 'Pin tab');
      expect(shown(tester, ['mon-a', 'mon-b']), ['mon-b', 'mon-a']);
      expectMonday(['mon-b', 'renewal', 'mon-a'], 2);
    });

    testWidgets('with the list filtered, an unpin keeps the day, and the pin '
        'of a note the filter leaves out', (tester) async {
      await filteredToGym(tester, pins: ['mon-a', 'renewal']);
      expectMonday(['mon-a', 'renewal', 'mon-b'], 2);

      await hold(tester, 'mon-a', 'Unpin tab');
      expectMonday(['renewal', 'mon-a', 'mon-b'], 1);
    });

    testWidgets('with the list filtered, a drag moves a tab past the tabs it '
        'shows, and a note the filter leaves out keeps its place', (
      tester,
    ) async {
      await filteredToGym(tester, pins: ['renewal']);
      await drag(tester, 'mon-b', List.filled(7, -20));
      expect(shown(tester, ['mon-a', 'mon-b']), ['mon-b', 'mon-a']);
      expectMonday(['renewal', 'mon-b', 'mon-a'], 1);
    });

    testWidgets('with the list filtered, a tab dragged to the front of the row '
        'lands just before the tab it passed, after a note the filter leaves '
        'out', (tester) async {
      await filteredToGym(tester, tagged: ['mon-b', 'renewal']);
      await drag(tester, 'renewal', List.filled(7, -20));
      expect(shown(tester, ['mon-b', 'renewal']), ['renewal', 'mon-b']);
      expectMonday(['mon-a', 'renewal', 'mon-b'], 0);
    });

    testWidgets('with the list filtered, a drag let go where it began changes '
        'nothing, beside a note the filter leaves out', (tester) async {
      await filteredToGym(tester, tagged: ['mon-a', 'renewal']);
      await drag(tester, 'mon-a', [20, 20, 20, -20, -20, -20]);
      expect(shown(tester, ['mon-a', 'renewal']), ['mon-a', 'renewal']);
      expectMonday(wholeMonday, 0);
      expect(dayTabs.owed, isEmpty);
    });

    testWidgets("Back from a day's one note, picked over a day's tabs, comes "
        'back to the tabs on the tab that was open', (tester) async {
      seed();
      await pump(tester);
      await open(tester, 17);
      await tester.tap(tab('mon-b'));
      await tester.pumpAndSettle();
      final tabs = tester.state(find.byType(DayTabsRow));

      await open(tester, 18);
      expect(openNoteBody(tester), startsWith('Standup notes'));
      expect(row, findsNothing);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(openNoteBody(tester), startsWith('Budget'));
      expect(shown(tester, ['mon-a', 'mon-b']), ['mon-a', 'mon-b']);
      expect(tester.getSemantics(tab('mon-b')), isSemantics(isSelected: true));
      expect(
        tester.state(find.byType(DayTabsRow)),
        same(tabs),
        reason: 'the same page, kept under the note picked over it',
      );
    });

    testWidgets('a tab pinned from far along a crowded row comes to the '
        'front in view, as it opens there (A7)', (tester) async {
      store.data['notes.v1'] = [
        ...store.data['notes.v1']! as List,
        for (var i = 0; i < 12; i++)
          _note('crowd-$i', 'Crowd $i', DateTime(2025, 11, 17, 8 + i)),
      ];
      seed();
      await pump(tester);
      await open(tester, 17);
      await tester.tap(find.byKey(const ValueKey('day-tabs-count')));
      await tester.pumpAndSettle();
      final sheet = find.byKey(const ValueKey('day-notes-sheet'));
      final last = find.byKey(const ValueKey('day-notes-crowd-11'));
      await tester.scrollUntilVisible(
        last,
        100,
        scrollable: find.descendant(
          of: sheet,
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(last);
      await tester.pumpAndSettle();
      expect(tester.getRect(tab('mon-a')).right, lessThan(0));

      await tester.longPress(tab('crowd-11'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pin tab'));
      await tester.pumpAndSettle();
      final pinned = tester.getRect(tab('crowd-11'));
      expect(pinned.left, greaterThanOrEqualTo(tester.getRect(row).left));
      expect(
        pinned.right,
        lessThanOrEqualTo(tester.getRect(tab('mon-a')).left),
      );
      expect(openNoteBody(tester), startsWith('Crowd 11'));
    });

    testWidgets("a crowded day's row glides to keep the open tab in view, and "
        'its count lists every note in tab order, the open one ticked '
        '(A3, A4)', (tester) async {
      store.data['notes.v1'] = [
        ...store.data['notes.v1']! as List,
        for (var i = 0; i < 12; i++)
          _note('crowd-$i', 'Crowd $i', DateTime(2025, 11, 17, 8 + i)),
      ];
      seed();
      await pump(tester);
      await open(tester, 17);
      final count = find.byKey(const ValueKey('day-tabs-count'));
      expect(find.descendant(of: count, matching: find.text('14')), findsOne);
      final rowRect = tester.getRect(row);
      expect(tester.getRect(tab('crowd-11')).left, greaterThan(rowRect.right));

      await tester.tap(count);
      await tester.pumpAndSettle();
      final sheet = find.byKey(const ValueKey('day-notes-sheet'));
      expect(sheet, findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('day-notes-mon-a')),
          matching: findKapyIcon(KapyIcons.checkRounded),
        ),
        findsOneWidget,
      );
      final last = find.byKey(const ValueKey('day-notes-crowd-11'));
      await tester.scrollUntilVisible(
        last,
        100,
        scrollable: find.descendant(
          of: sheet,
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(last);
      await tester.pumpAndSettle();
      expect(sheet, findsNothing);
      expect(openNoteBody(tester), startsWith('Crowd 11'));
      final shownTab = tester.getRect(tab('crowd-11'));
      expect(shownTab.right, lessThanOrEqualTo(tester.getRect(count).left));
      expect(shownTab.left, greaterThan(rowRect.left));

      await tester.tap(count);
      await tester.pumpAndSettle();
      final ticked = tester.getRect(
        find.byKey(const ValueKey('day-notes-crowd-11')),
      );
      expect(ticked.bottom, lessThanOrEqualTo(tester.getRect(sheet).bottom));
    });

    testWidgets("on a crowded day, a new tab stays in view as its title is "
        'typed (A8)', (tester) async {
      store.data['notes.v1'] = [
        ...store.data['notes.v1']! as List,
        for (var i = 0; i < 12; i++)
          _note('crowd-$i', 'Crowd $i', DateTime(2025, 11, 17, 8 + i)),
      ];
      seed();
      await pump(tester);
      await open(tester, 17);
      await tester.tap(find.byKey(const ValueKey('day-tabs-new')));
      await tester.pumpAndSettle();
      await tester.enterNote('Call the plumber about the kitchen sink');
      await tester.pumpAndSettle();
      final typed = notes
          .search('')
          .singleWhere((note) => note.body.startsWith('Call the plumber'));
      final shownTab = tester.getRect(tab(typed.id));
      final count = find.byKey(const ValueKey('day-tabs-count'));
      expect(shownTab.right, lessThanOrEqualTo(tester.getRect(count).left));
      expect(shownTab.left, greaterThan(tester.getRect(row).left));
    });

    testWidgets("an earlier day's tab keeps its place, on the same page, as "
        'its first words move its note to today, and the page keeps its '
        "day's tabs as Back comes to it from another day", (tester) async {
      seed();
      await pump(tester);
      await open(tester, 17);
      final headers = find.byKey(
        const ValueKey('phone-note-header'),
        skipOffstage: false,
      );
      await tester.showNoteKeyboard();
      tester.testTextInput.enterText('Gym plan\nLegs and arms');
      for (var frame = 0; frame < 25; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
        expect(
          headers,
          findsNWidgets(2),
          reason: 'the page is not pushed again',
        );
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(shown(tester, ['mon-b', 'mon-a']), ['mon-a', 'mon-b']);
      expect(tester.getSemantics(tab('mon-a')), isSemantics(isSelected: true));
      expect(tasksLine, findsNothing, reason: "today's tasks, not Mon 17's");

      await open(tester, 21);
      expect(openNoteBody(tester), startsWith('Renewal notes'));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(openNoteBody(tester), 'Gym plan\nLegs and arms');
      expect(shown(tester, ['mon-b', 'mon-a']), ['mon-a', 'mon-b']);
      await tester.tap(tab('mon-b'));
      await tester.pumpAndSettle();
      await tester.enterNote('Budget\nRent and bills');
      await tester.pumpAndSettle();
      await tester.tap(tab('mon-a'));
      await tester.pumpAndSettle();
      expect(openNoteBody(tester), 'Gym plan\nLegs and arms');
      expect(shown(tester, ['mon-b', 'mon-a']), ['mon-a', 'mon-b']);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(openNoteBody(tester), startsWith('Call with Arjun'));
      await open(tester, 19);
      expect(shown(tester, ['arjun', 'errands', 'mon-b', 'mon-a']), [
        'mon-a',
        'mon-b',
        'errands',
        'arjun',
      ]);
    });

    testWidgets("a tab whose note's first words moved it to today stays for a "
        'drag, a pin, its day tapped again and another tab, till another day '
        'leaves the day, which then skips it', (tester) async {
      seed();
      await pump(tester);
      await open(tester, 17);
      await tester.enterNote('Gym plan\nLegs and arms');
      await tester.pumpAndSettle();

      await open(tester, 17);
      expect(openNoteBody(tester), startsWith('Gym plan'));
      await drag(tester, 'mon-b', List.filled(7, -20));
      expect(shown(tester, ['mon-a', 'mon-b']), ['mon-b', 'mon-a']);
      await hold(tester, 'mon-b', 'Pin tab');
      await hold(tester, 'mon-b', 'Unpin tab');
      expect(shown(tester, ['mon-a', 'mon-b']), ['mon-b', 'mon-a']);

      await tester.tap(tab('mon-b'));
      await tester.pumpAndSettle();
      expect(openNoteBody(tester), startsWith('Budget'));
      expect(shown(tester, ['mon-a', 'mon-b']), ['mon-b', 'mon-a']);
      await tester.tap(tab('mon-a'));
      await tester.pumpAndSettle();
      expect(openNoteBody(tester), startsWith('Gym plan'));
      expect(
        find.byKey(const ValueKey('phone-note-header'), skipOffstage: false),
        findsNWidgets(2),
      );
      await tester.tap(tab('mon-b'));
      await tester.pumpAndSettle();

      await open(tester, 21);
      expect(openNoteBody(tester), startsWith('Renewal notes'));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(openNoteBody(tester), startsWith('Budget'));
      expect(tab('mon-a'), findsNothing);
      expect(tab('mon-b'), findsOneWidget);
    });

    testWidgets('a note that came to the day after its tabs opened keeps its '
        'tab while open, though it is moved to another day', (tester) async {
      seed();
      await pump(tester);
      await open(tester, 17);
      days.setDay('tue', monday);
      await tester.pumpAndSettle();
      await tester.tap(tab('tue'));
      await tester.pumpAndSettle();
      days.setDay('tue', DateTime(2025, 11, 21));
      await tester.pumpAndSettle();
      await tester.enterNote('Standup notes\nShip it today');
      await tester.pumpAndSettle();
      expect(openNoteBody(tester), startsWith('Standup notes'));
      expect(tester.getSemantics(tab('tue')), isSemantics(isSelected: true));
    });

    testWidgets('a note opened over the day from its tasks, and Back, keeps '
        'a tab whose note has left the day', (tester) async {
      seed();
      await pump(tester);
      await open(tester, 19);
      days.setDay('errands', DateTime(2025, 11, 21));
      await tester.pumpAndSettle();
      expect(shown(tester, ['arjun', 'errands']), ['errands', 'arjun']);

      await tester.tap(tasksLine);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tasks-later')));
      await tester.pumpAndSettle();
      expect(openNoteBody(tester), isNot(startsWith('Call with Arjun')));

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(openNoteBody(tester), startsWith('Call with Arjun'));
      expect(shown(tester, ['arjun', 'errands']), ['errands', 'arjun']);
    });

    /// Twelve more notes on Monday, more than its row shows at once.
    void crowdMonday() => store.data['notes.v1'] = [
      ...store.data['notes.v1']! as List,
      for (var i = 0; i < 12; i++)
        _note('crowd-$i', 'Crowd $i', DateTime(2025, 11, 17, 8 + i)),
    ];
    final rowScroll = find.descendant(
      of: row,
      matching: find.byType(SingleChildScrollView),
    );

    testWidgets('a crowded row scrolled by hand stays put as the open note '
        'changes under its title, and follows a title typed', (tester) async {
      crowdMonday();
      seed();
      days.setDay('mon-a', monday);
      await pump(tester);
      await open(tester, 17);
      Future<Rect> scrollAway() async {
        await tester.drag(rowScroll, const Offset(-3000, 0));
        await tester.pumpAndSettle();
        final away = tester.getRect(tab('mon-a'));
        expect(away.right, lessThan(tester.getRect(row).left));
        return away;
      }

      var away = await scrollAway();
      await tester.enterNote('Gym plan\nLegs and arms');
      await tester.pumpAndSettle();
      expect(tester.getRect(tab('mon-a')), away);

      await tester.enterNote('Gym plan for the week\nLegs and arms');
      await tester.pumpAndSettle();
      expect(
        tester.getRect(tab('mon-a')).left,
        greaterThan(tester.getRect(row).left),
      );

      away = await scrollAway();
      await tester.enterNote('Gym plan for the week\nLegs, arms and back');
      await tester.pumpAndSettle();
      expect(tester.getRect(tab('mon-a')), away);
    });

    testWidgets('on a crowded day, the row follows the open tab as an earlier '
        'tab grows and pushes it along', (tester) async {
      crowdMonday();
      seed();
      days.setDay('crowd-10', monday);
      await pump(tester);
      await open(tester, 17);
      await tester.drag(rowScroll, const Offset(-3000, 0));
      await tester.pumpAndSettle();
      await tester.tap(tab('crowd-11'));
      await tester.pumpAndSettle();
      notes.updateBody(
        'crowd-10',
        'Crowd 10, and a much longer title than it had',
      );
      await tester.pumpAndSettle();
      final count = find.byKey(const ValueKey('day-tabs-count'));
      expect(
        tester.getRect(tab('crowd-11')).right,
        lessThanOrEqualTo(tester.getRect(count).left),
      );
    });

    testWidgets(
      'at 320 and large text, a new tab with its fades wider than the '
      'row glides one way as its title is typed',
      (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = 1.3;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        crowdMonday();
        seed();
        await pump(tester, width: 320);
        await open(tester, 17);
        await tester.tap(find.byKey(const ValueKey('day-tabs-new')));
        await tester.pumpAndSettle();
        final scroll = tester
            .widget<SingleChildScrollView>(rowScroll)
            .controller!;
        const title = 'Call the plumber about the kitchen sink';
        final offsets = <double>[];
        for (var typed = 1; typed <= title.length; typed++) {
          await tester.enterNote(title.substring(0, typed));
          await tester.pumpAndSettle();
          offsets.add(scroll.offset);
        }
        expect(offsets, [...offsets]..sort());
      },
    );

    testWidgets("a tab tells a screen reader it's open, and offers Pin tab "
        'and a move', (tester) async {
      final semantics = tester.ensureSemantics();
      seed();
      await pump(tester);
      await open(tester, 17);
      expect(
        tester.getSemantics(tab('mon-a')),
        isSemantics(
          label: 'Gym plan',
          isButton: true,
          isSelected: true,
          hasTapAction: true,
          customActions: const [
            CustomSemanticsAction(label: 'Pin tab'),
            CustomSemanticsAction(label: 'Move right'),
          ],
        ),
      );
      semantics.dispose();
    });

    testWidgets(
      "a screen reader hears a crowded day's count in plain words, and opens "
      'the list from it as a tap does (KAP-361)',
      (tester) async {
        final semantics = tester.ensureSemantics();
        AppPlatform.debugTargetPlatformOverride = defaultTargetPlatform;
        crowdMonday();
        seed();
        await pump(tester);
        await open(tester, 17);
        final count = tester.getSemantics(
          find.byKey(const ValueKey('day-tabs-count')),
        );
        expect(
          count,
          isSemantics(
            label: 'All 14 notes on this day',
            isButton: true,
            hasTapAction: true,
          ),
        );
        tester.semantics.tap(
          find.semantics.byPredicate((node) => node.id == count.id),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('day-notes-sheet')), findsOneWidget);
        expect(find.byKey(const ValueKey('day-notes-mon-a')), findsOneWidget);
        semantics.dispose();
      },
      variant: TargetPlatformVariant(const {
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );
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

    testWidgets("a note moved to a later day leaves Home's list, and its "
        "day in the week opens it", (tester) async {
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
      expect(find.byKey(const ValueKey('folders-upcoming-tile')), findsNothing);
      await tap(tester, 'bar-notes');

      await tester.tap(find.byType(NoteRow).first);
      await tester.pumpAndSettle();
      if (day(25).evaluate().isEmpty) await tap(tester, 'day-strip-forward');
      await open(tester, 25);
      expect(openNoteBody(tester), startsWith('Call with Arjun'));
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
  group('Back (KAP-305)', () {
    Future<void> tap(WidgetTester tester, String key) async {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
    }

    Future<void> back(WidgetTester tester, {required bool swipe}) async {
      if (swipe) {
        await tester.dragFrom(const Offset(5, 400), const Offset(300, 0));
      } else {
        await tester.binding.handlePopRoute();
      }
      await tester.pumpAndSettle();
    }

    for (final swipe in [false, true]) {
      final how = swipe ? "an iPhone's edge swipe" : "Android's Back";
      final TestVariant<Object?> variant = swipe
          ? TargetPlatformVariant.only(TargetPlatform.iOS)
          : const DefaultTestVariant();

      testWidgets('$how from a note the week opened comes back to the note '
          'it was opened from, one at a time, then Home', (tester) async {
        if (!swipe) {
          AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
        }
        seed();
        await pump(tester);
        expect(openNoteBody(tester), startsWith('Call with Arjun'));
        await open(tester, 18);
        await open(tester, 21);
        expect(openNoteBody(tester), startsWith('Renewal notes'));

        await back(tester, swipe: swipe);
        expect(openNoteBody(tester), startsWith('Standup notes'));
        await back(tester, swipe: swipe);
        expect(openNoteBody(tester), startsWith('Call with Arjun'));
        await back(tester, swipe: swipe);
        expect(header, findsNothing);
        expect(find.byKey(const ValueKey('home-title-notes')), findsOneWidget);
      }, variant: variant);
    }

    testWidgets('Back to the note a note was opened from keeps its editor '
        '(KAP-306)', (tester) async {
      seed();
      await pump(tester);
      final arjun = tester.state<NoteEditorState>(find.byType(NoteEditor));
      await open(tester, 18);
      expect(openNoteBody(tester), startsWith('Standup notes'));

      await back(tester, swipe: false);
      expect(openNoteBody(tester), startsWith('Call with Arjun'));
      expect(
        tester.state<NoteEditorState>(find.byType(NoteEditor)),
        same(arjun),
      );
    });

    group('Back while a recording into the note left finishes (KAP-306)', () {
      late _LateRecording recording;

      // The recording's bar keeps a frame waiting, so time goes on by hand.
      Future<void> settle(WidgetTester tester) async {
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      // Call with Arjun, then Standup notes from its week, recording into
      // it, then Back, which waits for the recording to land.
      Future<void> backWhileRecording(WidgetTester tester) async {
        seed();
        recording = _LateRecording('tue');
        addTearDown(recording.dispose);
        await pump(tester, recording: recording);
        await open(tester, 18);
        expect(openNoteBody(tester), startsWith('Standup notes'));
        await tester.binding.handlePopRoute();
        await settle(tester);
        expect(openNoteBody(tester), startsWith('Call with Arjun'));
      }

      Future<void> land(WidgetTester tester) async {
        recording.finish.complete();
        await tester.pumpAndSettle();
      }

      testWidgets('a note chosen meanwhile opens on top of the one Back went '
          'to', (tester) async {
        await backWhileRecording(tester);
        await tester.tap(day(21));
        await tester.pump();
        await land(tester);
        expect(openNoteBody(tester), startsWith('Renewal notes'));

        await back(tester, swipe: false);
        expect(openNoteBody(tester), startsWith('Call with Arjun'));
        await back(tester, swipe: false);
        expect(header, findsNothing);
      });

      testWidgets('a second Back leaves the page Back went to, and it stays '
          'gone once the recording lands', (tester) async {
        await backWhileRecording(tester);
        await tester.binding.handlePopRoute();
        await settle(tester);
        expect(header, findsNothing);

        await land(tester);
        expect(header, findsNothing);
        expect(find.byKey(const ValueKey('home-title-notes')), findsOneWidget);
      });
    });

    testWidgets('on an iPhone, a part swipe from the left edge of a note the '
        'week opened follows the finger over the note it came from, and let '
        'go early it stays (KAP-306)', (tester) async {
      seed();
      await pump(tester);
      await open(tester, 18);
      expect(openNoteBody(tester), startsWith('Standup notes'));
      final left = tester.getTopLeft(header).dx;

      final gesture = await tester.startGesture(const Offset(5, 400));
      await gesture.moveBy(
        const Offset(20, 0),
        timeStamp: const Duration(milliseconds: 100),
      );
      await gesture.moveBy(
        const Offset(100, 0),
        timeStamp: const Duration(milliseconds: 900),
      );
      await tester.pump();
      expect(header, findsNWidgets(2), reason: 'its own page is under it');
      expect(tester.getTopLeft(header.last).dx, greaterThan(left + 80));
      expect(tester.getTopLeft(header.last).dx, lessThan(left + 125));

      await gesture.up(timeStamp: const Duration(milliseconds: 1700));
      await tester.pumpAndSettle();
      expect(header, findsOneWidget);
      expect(tester.getTopLeft(header).dx, left);
      expect(openNoteBody(tester), startsWith('Standup notes'));
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets("Home from a note the week opened goes Home, past the notes "
        'behind it', (tester) async {
      seed();
      await pump(tester);
      await open(tester, 18);
      await tap(tester, 'page-home');
      expect(header, findsNothing);
      expect(find.byKey(const ValueKey('home-title-notes')), findsOneWidget);
    });

    testWidgets('on an iPhone, a stroke in from the left edge of a drawing '
        "draws rather than leaving, and Back and the page's Home still "
        'leave', (tester) async {
      (store.data['notes.v1']! as List).add({
        'id': 'sketch',
        'body': 'Floor plan',
        'createdAt': DateTime(2025, 11, 19, 9, 30).millisecondsSinceEpoch,
        'updatedAt': DateTime(2025, 11, 19, 9, 30).millisecondsSinceEpoch,
        'drawing': {'elements': <Object?>[]},
      });
      seed();
      await pump(tester);
      await tap(tester, 'page-home');
      await tap(tester, 'bar-folders');
      await tap(tester, 'folders-drawings-tile');
      await tester.tap(find.widgetWithText(NoteRow, 'Floor plan'));
      await tester.pumpAndSettle();
      expect(header, findsOneWidget);

      await back(tester, swipe: true);
      expect(header, findsOneWidget);

      await back(tester, swipe: false);
      expect(header, findsNothing);

      await tester.tap(find.widgetWithText(NoteRow, 'Floor plan'));
      await tester.pumpAndSettle();
      await tap(tester, 'page-home');
      expect(header, findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
    testWidgets('after Home, a note opened from the list has nothing behind '
        'it', (tester) async {
      seed();
      await pump(tester);
      await open(tester, 18);
      await tap(tester, 'page-home');
      await tester.tap(find.widgetWithText(NoteRow, 'Errands'));
      await tester.pumpAndSettle();
      expect(openNoteBody(tester), startsWith('Errands'));

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(header, findsNothing);
      expect(find.byKey(const ValueKey('home-title-notes')), findsOneWidget);
    });

    testWidgets("Back closes the slash menu on a note the week opened, and "
        'keeps that note', (tester) async {
      seed();
      await pump(tester);
      await open(tester, 18);
      final field = openNoteField(tester);
      field.focusNode.requestFocus();
      await tester.pump();
      const text = 'Standup notes\nShip it\n/';
      field.controller.selection = const TextSelection.collapsed(
        offset: text.length - 2,
      );
      await tester.pump();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        ),
      );
      await tester.pump();
      await tester.pump();
      final menu = find.byKey(const ValueKey('slash-command-menu'));
      expect(menu, findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(menu, findsNothing);
      expect(openNoteBody(tester), startsWith('Standup notes'));
    });

    testWidgets('Back skips a note behind that has since been deleted', (
      tester,
    ) async {
      seed();
      await pump(tester);
      await open(tester, 18);
      await open(tester, 21);
      notes.delete('tue');
      await tester.pumpAndSettle();
      expect(openNoteBody(tester), startsWith('Renewal notes'));

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(openNoteBody(tester), startsWith('Call with Arjun'));
    });

    testWidgets('after a shared note goes from under its page, the next note '
        'from the list has nothing behind it', (tester) async {
      final data = store.data['notes.v1']! as List;
      final tue = data.indexWhere((note) => (note as Map)['id'] == 'tue');
      final synced = data[tue] as Map<String, Object?>;
      data[tue] = {
        ...synced,
        'spaceId': 'space-1',
        'syncedAt': synced['updatedAt'],
      };
      seed();
      await pump(tester);
      await open(tester, 18);
      expect(openNoteBody(tester), startsWith('Standup notes'));
      notes.forgetSpace('space-1');
      await tester.pumpAndSettle();
      expect(header, findsNothing);

      await tester.tap(find.widgetWithText(NoteRow, 'Errands'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(header, findsNothing);
      expect(find.byKey(const ValueKey('home-title-notes')), findsOneWidget);
    });

    testWidgets('on an iPhone, a drawing with words opened from Home opens '
        'as its words and keeps the back swipe', (tester) async {
      (store.data['notes.v1']! as List).add({
        'id': 'sketch',
        'body': 'Floor plan\nMeasure the hall',
        'createdAt': DateTime(2025, 11, 19, 9, 30).millisecondsSinceEpoch,
        'updatedAt': DateTime(2025, 11, 19, 9, 30).millisecondsSinceEpoch,
        'drawing': {'elements': <Object?>[]},
      });
      seed();
      await pump(tester);
      await tap(tester, 'page-home');
      await tester.tap(find.widgetWithText(NoteRow, 'Floor plan'));
      await tester.pumpAndSettle();
      expect(header, findsOneWidget);

      await back(tester, swipe: true);
      expect(header, findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  });

  group('a day turn (KAP-429)', () {
    Future<void> turn(WidgetTester tester, Offset from, double dx) async {
      await tester.timedDragFrom(
        from,
        Offset(dx, 0),
        const Duration(milliseconds: 400),
      );
      await tester.pumpAndSettle();
    }

    Offset onHeader(WidgetTester tester) =>
        tester.getCenter(find.byKey(const ValueKey('page-day'))) +
        const Offset(60, 0);
    Offset onText(WidgetTester tester) =>
        tester.getCenter(find.byType(NoteEditor)) + const Offset(0, 120);

    void keyboardDown() => FocusManager.instance.primaryFocus?.unfocus();

    testWidgets('a drag on the header turns to the day before and after, as '
        'the week picks them, in place, so Back still goes Home', (
      tester,
    ) async {
      seed();
      await pump(tester);
      expect(openNoteBody(tester), startsWith('Call with Arjun'));

      await turn(tester, onHeader(tester), 200);
      expect(openNoteBody(tester), startsWith('Standup notes'));

      await turn(tester, onHeader(tester), 200);
      expect(openNoteBody(tester), startsWith('Gym plan'));
      expect(find.byKey(const ValueKey('day-tabs')), findsOneWidget);

      await turn(tester, onHeader(tester), -200);
      await turn(tester, onHeader(tester), -200);
      expect(openNoteBody(tester), startsWith('Errands'));

      await turn(tester, onHeader(tester), -200);
      expect(openNoteBody(tester), isEmpty);
      expect(find.text('Start typing…'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('page-day')),
          matching: find.text('20'),
        ),
        findsOneWidget,
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(header, findsNothing);
      expect(find.widgetWithText(NoteRow, 'Call with Arjun'), findsOneWidget);
    });

    testWidgets('the page follows the finger with the day coming in beside '
        'it, which becomes the page as it was drawn', (tester) async {
      seed();
      await pump(tester);
      keyboardDown();
      await tester.pumpAndSettle();
      final left = tester.getTopLeft(header).dx;
      final drag = await tester.startGesture(onHeader(tester));
      await drag.moveBy(const Offset(30, 0));
      await drag.moveBy(const Offset(70, 0));
      await tester.pump();
      expect(tester.getTopLeft(header.first).dx, isNot(left));
      expect(
        tester
            .widgetList<NoteEditor>(find.byType(NoteEditor))
            .map((editor) => editor.initialBody.split('\n').first),
        containsAll(['Call with Arjun', 'Standup notes']),
      );
      final editors = tester
          .stateList<NoteEditorState>(find.byType(NoteEditor))
          .toList();
      expect(editors, hasLength(2));
      await drag.moveBy(const Offset(60, 0));
      await drag.up();
      await tester.pumpAndSettle();
      expect(openNoteBody(tester), startsWith('Standup notes'));
      expect(
        tester.state<NoteEditorState>(find.byType(NoteEditor)),
        isIn(editors),
        reason: 'the page coming in is kept, not drawn again',
      );
    });

    testWidgets('a short slow drag springs back on the same day', (
      tester,
    ) async {
      seed();
      await pump(tester);
      await tester.timedDragFrom(
        onHeader(tester),
        const Offset(70, 0),
        const Duration(milliseconds: 700),
      );
      await tester.pumpAndSettle();
      expect(openNoteBody(tester), startsWith('Call with Arjun'));
      expect(find.byType(NoteEditor), findsOneWidget);
    });

    testWidgets('with the keyboard down, a drag on the text turns the day', (
      tester,
    ) async {
      seed();
      await pump(tester);
      keyboardDown();
      await tester.pumpAndSettle();
      await turn(tester, onText(tester), 200);
      expect(openNoteBody(tester), startsWith('Standup notes'));
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets("on Android, a drag on the text is the text's own, which "
        'Android claims at once, and the header still turns the day', (
      tester,
    ) async {
      seed();
      await pump(tester);
      keyboardDown();
      await tester.pumpAndSettle();
      await turn(tester, onText(tester), 200);
      expect(openNoteBody(tester), startsWith('Call with Arjun'));
      await turn(tester, onHeader(tester), 200);
      expect(openNoteBody(tester), startsWith('Standup notes'));
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('with the caret in the text, a drag on the text stays the '
        "text's, and the header still turns the day", (tester) async {
      seed();
      await pump(tester);
      await tester.tap(find.byType(NoteEditor));
      await tester.pumpAndSettle();
      expect(
        tester.state<NoteEditorState>(find.byType(NoteEditor)).writing,
        isTrue,
      );
      await turn(tester, onText(tester), 200);
      expect(openNoteBody(tester), startsWith('Call with Arjun'));
      await turn(tester, onHeader(tester), 200);
      expect(openNoteBody(tester), startsWith('Standup notes'));
    });

    testWidgets('with the keyboard up, only the header turns the day', (
      tester,
    ) async {
      seed();
      await pump(tester);
      keyboardDown();
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      await turn(tester, onText(tester) - const Offset(0, 120), 200);
      expect(openNoteBody(tester), startsWith('Call with Arjun'));
      await turn(tester, onHeader(tester), 200);
      expect(openNoteBody(tester), startsWith('Standup notes'));
    });

    testWidgets('a scroll down the note, drifting sideways, never turns', (
      tester,
    ) async {
      seed();
      await pump(tester);
      keyboardDown();
      await tester.pumpAndSettle();
      await tester.timedDragFrom(
        onText(tester),
        const Offset(150, -200),
        const Duration(milliseconds: 400),
      );
      await tester.pumpAndSettle();
      expect(openNoteBody(tester), startsWith('Call with Arjun'));
    });

    testWidgets("on an iPhone, a drag from the left edge is iOS's back, not "
        'a turn', (tester) async {
      seed();
      await pump(tester);
      await turn(tester, Offset(4, tester.getCenter(header).dy), 300);
      expect(header, findsNothing);
      expect(find.widgetWithText(NoteRow, 'Call with Arjun'), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  });
}

/// A recording into [noteId] that lands only when [finish] completes, as a
/// long one being written out does.
class _LateRecording extends VoiceRecordingController {
  _LateRecording(this.noteId);

  String? noteId;
  final finish = Completer<void>();

  @override
  bool get isRecording => noteId != null;

  @override
  VoiceRecordingSession? get session => switch (noteId) {
    final id? => VoiceRecordingSession(noteId: id),
    null => null,
  };

  @override
  Future<void> finishRecordingAndFlush() => finish.future.then((_) {
    noteId = null;
    notifyListeners();
  });
}
