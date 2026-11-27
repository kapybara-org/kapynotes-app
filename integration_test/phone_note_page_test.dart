// The phone note page, for KAPY-35 to hold against M07, M08, M11, M12 and
// M15, and a day's notes as tabs against KAP-345's A boards: the whole app
// over notes kept in memory, dark, on the week M09 draws, with each state
// also read off the device's own screen, keyboard included.
//
//   flutter drive --driver test_driver/integration_test.dart \
//     --target integration_test/phone_note_page_test.dart -d <device> \
//     --dart-define=KAPYNOTES_SYNC=false
//
// The Phones workflow runs it through tool/ci/phone_screenshots.sh, and the
// device shots land as build/screenshots/note-page-<board>-device.png.
//
// M08 and M11 keep the format bar on the keyboard, as the Captain ruled on
// KAPY-35's item 27; the boards leave it out.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/appearance.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/data/day_tabs.dart';
import 'package:kapy_notes/data/folders.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note_days.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/tags.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/ui/day_strip.dart' show DayPicker;
import 'package:kapy_notes/ui/editor/note_editor.dart' show NoteEditor;
import 'package:kapy_notes/ui/editor/note_field.dart'
    show NoteField, NoteFieldState;
import 'package:kapy_notes/ui/sidebar.dart' show NoteRow;
import 'package:material_ui/material_ui.dart';

import 'keyboard_support.dart';
import 'rates_support.dart';
import 'screenshot.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'phone-note-page-integration.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

/// Wed 19 Nov 2025, 9:41: the week the boards draw, Mon 17 to Sun 23.
final _now = DateTime(2025, 11, 19, 9, 41);

Map<String, Object?> _note(String id, String body, DateTime edited) => {
  'id': id,
  'body': body,
  'createdAt': edited.millisecondsSinceEpoch,
  'updatedAt': edited.millisecondsSinceEpoch,
};

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the note page: a note, typing, the day calendar and another '
      "day's blank page", (tester) async {
    final store = _MemoryStore();
    store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
    store.data['notes.v1'] = [
      _note('gym', 'Gym plan\nLegs', DateTime(2025, 11, 17, 7, 30)),
      _note('budget', 'Budget\nRent', DateTime(2025, 11, 17, 18, 10)),
      _note('standup', 'Standup\nShip it', DateTime(2025, 11, 18, 9, 5)),
      _note('lunch', 'Lunch ideas\nSoup', DateTime(2025, 11, 18, 12, 40)),
      _note(
        'lisbon',
        'Lisbon trip\n☐ Book the Sintra train tickets\n'
            '☐ Ask Ana which Sintra palace to skip',
        DateTime(2025, 11, 18, 20, 15),
      ),
      _note(
        'errands',
        'Errands\n☐ Pay the electricity bill\n☐ Buy milk',
        DateTime(2025, 11, 19, 7, 50),
      ),
      _note(
        'ideas',
        'Ideas\nA calmer week view',
        DateTime(2025, 11, 19, 8, 20),
      ),
      _note(
        'arjun',
        'Call with Arjun\nPricing page by Friday. He wants the annual plan '
            'shown first, and the invoice split across two months so the '
            'first one is smaller.\n☐ Send the deck',
        DateTime(2025, 11, 19, 8, 55),
      ),
      // KAP-345's crowded day, five weeks back, out of every calendar the
      // other boards draw: seven notes, more than a phone's tabs show.
      for (final (id, body, hour, minute) in [
        ('run', 'Morning run\n5 km by the river', 6, 45),
        ('standup', 'Standup\nDemo on Monday', 9, 0),
        ('design', 'Design review\nThe tabs on a phone', 10, 30),
        ('lunch', 'Lunch with Maya\nThe new place on Rua Augusta', 12, 15),
        ('invoices', 'Invoices\nOctober for Acme', 14, 0),
        ('reading', 'Reading list\nThe Overstory', 16, 40),
        ('dinner', 'Dinner plan\nPasta and a salad', 19, 20),
      ])
        _note('oct-$id', body, DateTime(2025, 10, 17, hour, minute)),
    ];
    final prefs = LayoutPrefs(store)..load();
    prefs.appearance = AppearanceMode.dark;
    final notes = NotesStore(store, now: () => _now);
    final tags = TagStore(store, now: () => _now);
    final folders = FolderStore(store, now: () => _now);
    final days = NoteDayStore(store, now: () => _now);
    final dayTabs = DayTabsStore(store, now: () => _now);
    final library = TaskLibrary(
      notes: notes,
      store: store,
      storage: MemoryDocStorage(),
      now: () => _now,
    );
    await notes.load();
    await tags.load();
    await folders.load();
    await days.load();
    await dayTabs.load();
    String? parent;
    for (final name in ['Work', 'Clients', 'Acme']) {
      parent = folders.create(name, parentId: parent)!.id;
    }
    folders.file(['arjun'], parent);
    tags.setTags('arjun', [tags.create('Work')!.id, tags.create('Acme')!.id]);
    await library.reconcileNow();

    await tester.pumpWidget(
      KapyNotesApp(
        store: store,
        notes: notes,
        rates: offlineRates(store),
        prefs: prefs,
        shortcuts: ShortcutPrefs(store)..load(),
        tags: tags,
        folders: folders,
        days: days,
        dayTabs: dayTabs,
        tasks: library,
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    Future<void> shot(String board) async {
      expect(tester.takeException(), isNull, reason: board);
      await screenshot('note-page-$board', device: true);
    }

    // The open note's text lives in its field, not in a Text a finder sees.
    final fieldFinder = find.descendant(
      of: find.byType(NoteEditor),
      matching: find.byType(NoteField),
    );
    NoteField field() => tester.widget<NoteField>(fieldFinder);
    String timeLine() =>
        tester.widget<Text>(find.byKey(const ValueKey('note-edited'))).data!;

    Future<void> tap(Finder target) async {
      await tester.tap(target);
      await tester.pumpAndSettle();
    }

    // M07: the note at rest, the week open and the day's tasks under it.
    FocusManager.instance.primaryFocus?.unfocus();
    await settleKeyboard(tester, up: false);
    expect(field().controller.text, startsWith('Call with Arjun'));
    expect(find.byKey(const ValueKey('page-tasks-line')), findsOneWidget);
    expect(find.byKey(const ValueKey('note-path')), findsOneWidget);
    await shot('m07-a-note');

    // KAP-340: a swipe on the week turns it, and it comes to rest on the
    // whole next week; ‹ turns it back. Then the same light, with text at the
    // most the header takes, 1.3×.
    Future<void> swipeWeek(String name) async {
      await shot('week-swipe-${name}before');
      await tester.drag(
        find.byKey(const ValueKey('day-strip-2025-11-19')),
        const Offset(-220, 0),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('day-strip-2025-11-19')), findsNothing);
      expect(
        find.byKey(const ValueKey('day-strip-2025-11-26')),
        findsOneWidget,
      );
      await shot('week-swipe-${name}after');
      await tap(find.byKey(const ValueKey('day-strip-back')));
      expect(
        find.byKey(const ValueKey('day-strip-2025-11-19')),
        findsOneWidget,
      );
    }

    await swipeWeek('');
    prefs.appearance = AppearanceMode.light;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    await tester.pumpAndSettle();
    await swipeWeek('large-text-light-');
    prefs.appearance = AppearanceMode.dark;
    tester.platformDispatcher.clearTextScaleFactorTestValue();
    await tester.pumpAndSettle();

    // M08: typing at the end of the first paragraph, as the board does, the
    // keyboard up. The header's buttons step back, the path and the title
    // stay in view, and the line keeps the note's own time.
    const typed = ' Then send the draft to Finance';
    final paragraphEnd =
        field().controller.text.indexOf('smaller.') + 'smaller.'.length;
    final caret = tester
        .state<NoteFieldState>(fieldFinder)
        .caretRectAt(TextPosition(offset: paragraphEnd))!;
    final box = tester.getRect(fieldFinder);
    await tester.tapAt(
      Offset(
        box.right - 4,
        box.top + caret.center.dy - field().scrollController.offset,
      ),
    );
    await settleKeyboard(tester, up: true);
    expect(field().controller.selection.baseOffset, paragraphEnd);
    final controller = field().controller;
    controller.value = TextEditingValue(
      text: controller.text.replaceRange(paragraphEnd, paragraphEnd, typed),
      selection: TextSelection.collapsed(offset: paragraphEnd + typed.length),
    );
    await tester.pumpAndSettle();
    expect(timeLine(), '8:55');
    final header = tester.getRect(
      find.byKey(const ValueKey('phone-note-header')),
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('note-path'))).top,
      greaterThanOrEqualTo(header.bottom),
      reason: 'the path stays in view while typing',
    );
    await shot('m08-a-note-typing');

    // M12: More › Move to another day, the calendar open over the note.
    FocusManager.instance.primaryFocus?.unfocus();
    await settleKeyboard(tester, up: false);
    await tap(find.byKey(const ValueKey('page-more')));
    await tap(find.byKey(const ValueKey('page-more-day')));
    expect(find.byType(DayPicker), findsOneWidget);
    await shot('m12-move-to-another-day');
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    expect(find.byType(DayPicker), findsNothing);

    // M15: the day's tasks line opens the Tasks sheet over the note, here
    // with a task chosen, so it shows Today, Do now and Up next.
    await tap(find.byKey(const ValueKey('page-tasks-line')));
    expect(find.byKey(const ValueKey('phone-tasks-sheet')), findsOneWidget);
    await tap(find.byKey(const ValueKey('tasks-pair-right')));
    // Five tasks take more than one pair: Start sits under the half-height
    // sheet's fold, so it is brought into view before it is pressed.
    final start = find.byKey(const ValueKey('tasks-start'));
    await tester.ensureVisible(start);
    await tester.pumpAndSettle();
    await tap(start);
    expect(find.byKey(const ValueKey('tasks-do-now')), findsOneWidget);
    // Back to the top of the list, so the shot opens on Today and Do now.
    final sheet = find.byKey(const ValueKey('phone-tasks-sheet'));
    final today = find.descendant(of: sheet, matching: find.text('Today'));
    await tester.ensureVisible(today);
    await tester.pumpAndSettle();
    await shot('m15-tasks-sheet');
    await tap(find.byKey(const ValueKey('phone-tasks-sheet-close')));
    expect(find.byKey(const ValueKey('phone-tasks-sheet')), findsNothing);

    // M11: Fri 21 in the week, a blank page for that day, ready to type, the
    // week still open.
    await tap(find.byKey(const ValueKey('day-strip-2025-11-21')));
    await settleKeyboard(tester, up: true);
    expect(find.byKey(const ValueKey('day-strip-2025-11-21')), findsOneWidget);
    await shot('m11-another-day-blank-page');
    // Back while typing (KAP-305): the words are kept and the keyboard
    // doesn't stay up over the list. On Android the first Back belongs to
    // the keyboard, so the page is still there; the second leaves it. On an
    // iPhone the swipe in from the edge leaves it.
    const words = 'Pick up the keys';
    field().controller.value = const TextEditingValue(
      text: words,
      selection: TextSelection.collapsed(offset: words.length),
    );
    await tester.pumpAndSettle();
    final written = field().controller;
    if (AppPlatform.isAndroid) {
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      await settleKeyboard(tester, up: false);
      expect(find.byType(NoteEditor), findsOneWidget);
      await tester.binding.handlePopRoute();
    } else {
      await tester.timedDragFrom(
        const Offset(2, 420),
        const Offset(300, 0),
        const Duration(milliseconds: 300),
      );
    }
    await tester.pumpAndSettle();
    await settleKeyboard(tester, up: false);
    expect(find.byType(NoteEditor), findsNothing);
    expect(find.byKey(const ValueKey('home-title-notes')), findsOneWidget);
    expect(written.text, words);
    expect(notes.notes.any((note) => note.body.startsWith(words)), isTrue);

    // KAP-345: Fri 17 Oct, five weeks back, a day of several, opens its
    // notes as tabs under the week, the earliest written first, on the first.
    await tap(find.widgetWithText(NoteRow, 'Call with Arjun'));
    expect(find.byKey(const ValueKey('day-strip-2025-11-19')), findsOneWidget);
    for (var week = 0; week < 5; week++) {
      await tap(find.byKey(const ValueKey('day-strip-back')));
    }
    await tap(find.byKey(const ValueKey('day-strip-2025-10-17')));
    Finder tab(String id) => find.byKey(ValueKey('day-tab-$id'));
    final count = find.byKey(const ValueKey('day-tabs-count'));
    final dayNotes = find.byKey(const ValueKey('day-notes-sheet'));
    Future<void> pick(String id) async {
      final listed = find.byKey(ValueKey('day-notes-$id'));
      await tester.ensureVisible(listed);
      await tester.pumpAndSettle();
      await tap(listed);
      expect(dayNotes, findsNothing);
    }

    expect(field().controller.text, startsWith('Morning run'));
    expect(find.descendant(of: count, matching: find.text('7')), findsOne);
    // A3 and A4: the count lists the day's notes in their tabs' order, and
    // the one picked opens in its tab, which the row glides into view, faded
    // at both ends. Opened again, the list is at the note, ticked.
    await tap(count);
    await pick('oct-lunch');
    expect(field().controller.text, startsWith('Lunch with Maya'));
    await shot('tabs-crowded-day');
    await tap(count);
    expect(dayNotes, findsOneWidget);
    await shot('tabs-day-list');
    await pick('oct-reading');
    expect(field().controller.text, startsWith('Reading list'));
    // A5 and A7: a hold, let go, offers Pin tab, which puts the tab first
    // with a pin; held again, here in light, it offers Unpin tab.
    await tester.longPress(tab('oct-reading'));
    await tester.pumpAndSettle();
    await shot('tabs-hold-menu-dark');
    await tap(find.text('Pin tab'));
    expect(
      tester.getRect(tab('oct-reading')).left,
      lessThan(tester.getRect(tab('oct-run')).left),
    );
    await shot('tabs-pinned');
    prefs.appearance = AppearanceMode.light;
    await tester.pumpAndSettle();
    await tester.longPress(tab('oct-reading'));
    await tester.pumpAndSettle();
    expect(find.text('Unpin tab'), findsOneWidget);
    await shot('tabs-hold-menu-light');
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    expect(find.text('Unpin tab'), findsNothing);
    // A8: + starts a note on the day as the last tab, ready to type.
    await tap(find.byKey(const ValueKey('day-tabs-new')));
    await settleKeyboard(tester, up: true);
    const plumber = 'Call the plumber';
    field().controller.value = const TextEditingValue(
      text: plumber,
      selection: TextSelection.collapsed(offset: plumber.length),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('day-tabs')),
        matching: find.text(plumber),
      ),
      findsOneWidget,
    );
    await shot('tabs-new-typing');
    // An earlier day's tab keeps its place, its pin too, till the day is
    // left, though its note's first words move it to today.
    await tester.ensureVisible(tab('oct-reading'));
    await tester.pumpAndSettle();
    await tap(tab('oct-reading'));
    const reading = 'Reading list for the trip';
    field().controller.value = const TextEditingValue(
      text: reading,
      selection: TextSelection.collapsed(offset: reading.length),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: tab('oct-reading'), matching: find.text(reading)),
      findsOneWidget,
    );
    expect(
      tester.getRect(tab('oct-reading')).left,
      lessThan(tester.getRect(tab('oct-run')).left),
    );
    await shot('tabs-earlier-typing');
    await tester.ensureVisible(tab('oct-run'));
    await tester.pumpAndSettle();
    await tap(tab('oct-run'));
    expect(field().controller.text, startsWith('Morning run'));
    expect(
      tester.getRect(tab('oct-reading')).left,
      lessThan(tester.getRect(tab('oct-run')).left),
    );
  });
}
