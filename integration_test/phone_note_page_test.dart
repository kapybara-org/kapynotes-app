// The phone note page, for KAPY-35 to hold against M07, M08, M11, M12 and
// M15: the whole app over notes kept in memory, dark, on the week M09 draws,
// with each state also read off the device's own screen, keyboard included.
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
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/appearance.dart';
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
import 'package:material_ui/material_ui.dart';

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
    ];
    final prefs = LayoutPrefs(store)..load();
    prefs.appearance = AppearanceMode.dark;
    final notes = NotesStore(store, now: () => _now);
    final tags = TagStore(store, now: () => _now);
    final folders = FolderStore(store, now: () => _now);
    final days = NoteDayStore(store, now: () => _now);
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
        tasks: library,
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    Future<void> keyboard({required bool up}) async {
      for (var i = 0; i < 100; i++) {
        if ((tester.view.viewInsets.bottom > 0) == up) break;
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle(const Duration(milliseconds: 500));
      expect(tester.view.viewInsets.bottom > 0, up, reason: 'keyboard');
    }

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
    await keyboard(up: false);
    expect(field().controller.text, startsWith('Call with Arjun'));
    expect(find.byKey(const ValueKey('page-tasks-line')), findsOneWidget);
    expect(find.byKey(const ValueKey('note-path')), findsOneWidget);
    await shot('m07-a-note');

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
    await keyboard(up: true);
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
    await keyboard(up: false);
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
    await keyboard(up: true);
    expect(find.byKey(const ValueKey('day-strip-2025-11-21')), findsOneWidget);
    await shot('m11-another-day-blank-page');
  });
}
