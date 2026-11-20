import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/semantics.dart'
    show CustomSemanticsAction, SemanticsAction, SemanticsNode;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/ui/context_menu.dart';
import 'package:kapy_notes/ui/editor_panes.dart';
import 'package:kapy_notes/ui/hidden_notes_gate.dart';
import 'package:kapy_notes/ui/notes_list.dart';
import 'package:kapy_notes/ui/sidebar.dart';
import 'package:material_ui/material_ui.dart';

import 'app_test.dart' show MemoryStore;
import 'test_fonts.dart';

/// Picking many notes in the desktop list, and acting on them together.

late MemoryStore store;
late NotesStore notes;
late LayoutPrefs prefs;

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

/// The desktop app, on a Mac unless [platform] says otherwise, with the list
/// beside the page, holding [bodies] newest last: the list reads them bottom
/// up.
Future<void> _pump(
  WidgetTester tester, {
  List<String> bodies = const ['First', 'Second', 'Third', 'Fourth'],
  TargetPlatform platform = TargetPlatform.macOS,
  Size size = const Size(1100, 760),
}) async {
  AppPlatform.debugTargetPlatformOverride = platform;
  addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
  store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await notes.load();
  for (final body in bodies) {
    notes.create();
    notes.updateBody(notes.notes.first.id, body);
  }
  prefs.load();
  if (!prefs.sidebarVisible) prefs.toggleSidebar();
  await tester.pumpWidget(
    KapyNotesApp(
      store: store,
      notes: notes,
      rates: RatesRepository(store),
      prefs: prefs,
      shortcuts: ShortcutPrefs(store)..load(),
      hiddenNotesGate: _OpenGate(),
    ),
  );
  await tester.pumpAndSettle();
}

/// The app on a phone with the notes list open over the page.
Future<void> _pumpPhone(WidgetTester tester, TargetPlatform platform) async {
  await _pump(tester, platform: platform, size: const Size(390, 760));
  await tester.tap(find.byKey(const ValueKey('toolbar-notes-toggle')));
  await tester.pumpAndSettle();
}

/// Starts picking on a phone the way a reader does: Select in the menu a
/// long press on [title] opens.
Future<void> _selectFromMenu(WidgetTester tester, String title) async {
  await tester.longPress(_row(title));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('select-note-${_note(title).id}')));
  await tester.pumpAndSettle();
}

Note _note(String title) => notes.allNotes.singleWhere((n) => n.title == title);

Finder _row(String title) => find.widgetWithText(NoteRow, title);

/// The picked rows, top to bottom.
List<String> _picked(WidgetTester tester) => [
  for (final row in tester.widgetList<NoteRow>(find.byType(NoteRow)))
    if (row.selecting && row.checked) row.note.title,
];

bool _open(WidgetTester tester, String title) =>
    tester.widget<NoteRow>(_row(title)).selected;

bool _tabbed(WidgetTester tester, String title) =>
    tester.widget<NoteRow>(_row(title)).tabbed;

Future<void> _click(
  WidgetTester tester,
  String title, {
  LogicalKeyboardKey? holding,
}) async {
  if (holding != null) await tester.sendKeyDownEvent(holding);
  await tester.tap(_row(title));
  if (holding != null) await tester.sendKeyUpEvent(holding);
  await tester.pumpAndSettle();
}

Future<void> _chord(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pumpAndSettle();
}

Future<void> _rightClick(WidgetTester tester, String title) async {
  await tester.tap(_row(title), buttons: kSecondaryButton);
  await tester.pumpAndSettle();
}

Finder _item(String action, Note note) =>
    find.byKey(ValueKey('picked-$action-note-${note.id}'));

String _label(WidgetTester tester, Finder item) => tester
    .widget<KapyMenuActionRow>(
      find.descendant(of: item, matching: find.byType(KapyMenuActionRow)),
    )
    .action
    .label;

Future<void> _show(WidgetTester tester, NotesShow show) async {
  await tester.tap(find.byKey(const ValueKey('sidebar-notes-filter')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('notes-filter-${show.name}')));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadTestFonts);

  setUp(() {
    store = MemoryStore();
    notes = NotesStore(store);
    prefs = LayoutPrefs(store);
  });

  testWidgets('with nothing picked, a click with Cmd opens the note in a tab '
      'behind and picks nothing; a note with a tab stays where it is', (
    tester,
  ) async {
    await _pump(tester);
    await _click(tester, 'Second');

    await _click(tester, 'Fourth', holding: LogicalKeyboardKey.metaLeft);
    expect(_picked(tester), isEmpty);
    expect(find.textContaining('selected'), findsNothing);
    expect(_tabbed(tester, 'Fourth'), isTrue);
    expect(_open(tester, 'Second'), isTrue);
    expect(_open(tester, 'Fourth'), isFalse);

    await _click(tester, 'Second', holding: LogicalKeyboardKey.metaLeft);
    expect(_picked(tester), isEmpty);
    expect(_open(tester, 'Second'), isTrue);
    expect(_open(tester, 'Fourth'), isFalse);
  });

  testWidgets('with nothing picked, a click with Shift picks from the open '
      'note to the one clicked, and opens no tab', (tester) async {
    await _pump(tester);
    await _click(tester, 'Second');

    await _click(tester, 'Fourth', holding: LogicalKeyboardKey.shiftLeft);
    expect(_picked(tester), ['Fourth', 'Third', 'Second']);
    expect(find.text('3 selected'), findsOneWidget);
    expect(_tabbed(tester, 'Fourth'), isFalse);
    expect(_open(tester, 'Second'), isTrue);
  });

  testWidgets('once notes are picked, a click with Cmd picks or lets go of '
      'one and opens no tab; a plain click picks too, and Esc lets them go', (
    tester,
  ) async {
    await _pump(tester);
    await _click(tester, 'Second');
    await _click(tester, 'Third', holding: LogicalKeyboardKey.shiftLeft);
    expect(_picked(tester), ['Third', 'Second']);

    await _click(tester, 'Fourth', holding: LogicalKeyboardKey.metaLeft);
    expect(_picked(tester), ['Fourth', 'Third', 'Second']);
    expect(_tabbed(tester, 'Fourth'), isFalse);

    await _click(tester, 'Second', holding: LogicalKeyboardKey.metaLeft);
    expect(_picked(tester), ['Fourth', 'Third']);

    await _click(tester, 'First');
    expect(_picked(tester), ['Fourth', 'Third', 'First']);
    // Picking is not opening: the open note stays open.
    expect(_open(tester, 'Second'), isTrue);
    expect(_open(tester, 'First'), isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(_picked(tester), isEmpty);
    expect(find.text('3 selected'), findsNothing);
    expect(_open(tester, 'Second'), isTrue);
  });

  testWidgets('on Windows Ctrl does what Cmd does on a Mac, and a click with '
      'the Windows key only opens the note', (tester) async {
    await _pump(tester, platform: TargetPlatform.windows);
    await _click(tester, 'Second');

    await _click(tester, 'Fourth', holding: LogicalKeyboardKey.metaLeft);
    expect(_picked(tester), isEmpty);
    expect(_open(tester, 'Fourth'), isTrue);

    await _click(tester, 'Second', holding: LogicalKeyboardKey.controlLeft);
    expect(_picked(tester), isEmpty);
    expect(_tabbed(tester, 'Second'), isTrue);
    expect(_open(tester, 'Fourth'), isTrue);

    await _click(tester, 'Third', holding: LogicalKeyboardKey.shiftLeft);
    await _click(tester, 'First', holding: LogicalKeyboardKey.controlLeft);
    expect(_picked(tester), ['Fourth', 'Third', 'First']);
    expect(find.text('3 selected'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(_picked(tester), isEmpty);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text('4 selected'), findsOneWidget);
  });

  testWidgets('a row hands a ⌘-click with nothing picked to its one handler, '
      'every click to picking once notes are picked, and Shift to a range '
      'either way', (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    await notes.load();
    final note = notes.create(body: 'Row');
    final calls = <String>[];
    Future<void> click({
      required bool selecting,
      LogicalKeyboardKey? holding,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: KapyTheme.dark(),
          home: Material(
            child: NoteRow(
              note: note,
              query: '',
              displayTime: (time) => time,
              selected: false,
              selecting: selecting,
              onTap: () => calls.add('open'),
              onToggleChecked: () => calls.add('pick'),
              onCommandClick: () => calls.add('command'),
              onPickTo: () => calls.add('range'),
            ),
          ),
        ),
      );
      await _click(tester, 'Row', holding: holding);
    }

    await click(selecting: false, holding: LogicalKeyboardKey.metaLeft);
    await click(selecting: false, holding: LogicalKeyboardKey.shiftLeft);
    await click(selecting: false);
    await click(selecting: true, holding: LogicalKeyboardKey.metaLeft);
    await click(selecting: true, holding: LogicalKeyboardKey.shiftLeft);
    await click(selecting: true);
    expect(calls, ['command', 'range', 'open', 'pick', 'range', 'pick']);
  });

  testWidgets('a row offers its menu choices as accessibility actions, so '
      'VoiceOver can delete a note without the ⋯ button', (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    await notes.load();
    final note = notes.create(body: 'Row');
    final calls = <String>[];
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Material(
          child: NoteRow(
            note: note,
            query: '',
            displayTime: (time) => time,
            selected: false,
            selecting: false,
            onTap: () => calls.add('open'),
            onDelete: () => calls.add('delete'),
            onTogglePin: () => calls.add('pin'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final row = tester.semantics.find(find.text('Row'));
    final actions = <String, int>{};
    for (final id
        in row.getSemanticsData().customSemanticsActionIds ?? const <int>[]) {
      final action = CustomSemanticsAction.getAction(id);
      if (action?.label != null) actions[action!.label!] = id;
    }
    expect(actions.keys, containsAll(['Pin note', 'Delete note…']));
    expect(
      row.getSemanticsData().hasAction(SemanticsAction.tap),
      isTrue,
      reason: 'the row still opens on a press',
    );

    // The bindings moved the pipeline owner in 3.10; a widget test still has
    // the one.
    // ignore: deprecated_member_use
    tester.binding.pipelineOwner.semanticsOwner!.performAction(
      row.id,
      SemanticsAction.customAction,
      actions['Delete note…'],
    );
    await tester.pumpAndSettle();
    expect(calls, ['delete']);
    semantics.dispose();
  });

  testWidgets('a click with Shift picks from the open note, and the next one '
      'moves the end of that range, keeping picks outside it', (tester) async {
    await _pump(tester);
    await _click(tester, 'Fourth');

    await _click(tester, 'Second', holding: LogicalKeyboardKey.shiftLeft);
    expect(_picked(tester), ['Fourth', 'Third', 'Second']);
    await _click(tester, 'Third', holding: LogicalKeyboardKey.shiftLeft);
    expect(_picked(tester), ['Fourth', 'Third']);

    await _click(tester, 'First', holding: LogicalKeyboardKey.metaLeft);
    await _click(tester, 'Second', holding: LogicalKeyboardKey.shiftLeft);
    expect(_picked(tester), ['Fourth', 'Third', 'Second', 'First']);
  });

  testWidgets('a press dragged down the rows picks each one it crosses and '
      'back up lets them go; dragged sideways it still carries the note', (
    tester,
  ) async {
    await _pump(tester);

    final sweep = await tester.startGesture(
      tester.getCenter(_row('Fourth')),
      kind: PointerDeviceKind.mouse,
    );
    await sweep.moveBy(const Offset(0, 6));
    await tester.pump();
    await sweep.moveTo(tester.getCenter(_row('Second')));
    await tester.pump();
    expect(_picked(tester), ['Fourth', 'Third', 'Second']);
    await sweep.moveTo(tester.getCenter(_row('Third')));
    await tester.pump();
    expect(_picked(tester), ['Fourth', 'Third']);
    expect(find.byType(NoteDragFeedback), findsNothing);
    await sweep.up();
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    final carry = await tester.startGesture(
      tester.getCenter(_row('First')),
      kind: PointerDeviceKind.mouse,
    );
    await carry.moveBy(const Offset(12, 2));
    await tester.pump();
    expect(find.byType(NoteDragFeedback), findsOneWidget);
    await carry.moveTo(tester.getCenter(_row('Third')));
    await tester.pump();
    expect(_picked(tester), isEmpty);
    await carry.up();
    await tester.pumpAndSettle();
  });

  testWidgets('Cmd+A picks every note in the list, and Shift with an arrow '
      'grows and shrinks a range from the open note', (tester) async {
    await _pump(tester);
    await _click(tester, 'Fourth');

    await _chord(tester, LogicalKeyboardKey.keyA);
    expect(find.text('4 selected'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(_picked(tester), ['Fourth', 'Third', 'Second']);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(_picked(tester), ['Fourth', 'Third']);
    expect(_open(tester, 'Fourth'), isTrue);
  });

  testWidgets('picked rows are what is lit, and say so to assistive tech', (
    tester,
  ) async {
    await _pump(tester);
    await _click(tester, 'Second');
    await _click(tester, 'Third', holding: LogicalKeyboardKey.shiftLeft);
    await _click(tester, 'Second');

    SemanticsNode row(String title) => tester.getSemantics(
      find
          .descendant(of: _row(title), matching: find.byType(GestureDetector))
          .first,
    );
    expect(_picked(tester), ['Third']);
    expect(row('Third'), isSemantics(isSelected: true));
    // Open but not picked: not one of what an action would act on.
    expect(row('Second'), isSemantics(isSelected: false));
  });

  testWidgets('right-clicking a picked note opens a menu for every picked '
      'note, with how many; an unpicked one joins them first', (tester) async {
    await _pump(tester);
    await _click(tester, 'Fourth');
    await _click(tester, 'Third', holding: LogicalKeyboardKey.shiftLeft);

    await _rightClick(tester, 'First');
    final first = _note('First');
    expect(_picked(tester), ['Fourth', 'Third', 'First']);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('kapy-context-menu')),
        matching: find.text('3 notes'),
      ),
      findsOneWidget,
    );
    expect(_label(tester, _item('pin', first)), 'Pin');
    expect(_label(tester, _item('hide', first)), 'Move to Hidden Notes');
    expect(_label(tester, _item('archive', first)), 'Archive');
    expect(_label(tester, _item('delete', first)), 'Delete 3 notes…');
    // A note's own items are not on offer for many.
    expect(find.byKey(ValueKey('share-note-${first.id}')), findsNothing);

    await tester.tap(_item('pin', first));
    await tester.pumpAndSettle();
    expect(
      [
        for (final title in ['Fourth', 'Third', 'Second', 'First'])
          notes.isPinned(_note(title).id),
      ],
      [true, true, false, true],
    );
    expect(find.text('3 notes pinned'), findsOneWidget);
    expect(_picked(tester), isEmpty);

    // The open note has its tab already, so a click with Cmd on it changes
    // nothing.
    await _click(tester, 'Fourth', holding: LogicalKeyboardKey.metaLeft);
    expect(_picked(tester), isEmpty);
    expect(find.text('Select notes'), findsNothing);
    await _click(tester, 'Third', holding: LogicalKeyboardKey.shiftLeft);
    await _rightClick(tester, 'Fourth');
    expect(_label(tester, _item('unpin', _note('Fourth'))), 'Unpin');
  });

  testWidgets('every item of the menu for many notes fits it', (tester) async {
    await _pump(tester, bodies: [for (var i = 1; i <= 12; i++) 'Note $i']);
    await _click(tester, 'Note 12');
    await _chord(tester, LogicalKeyboardKey.keyA);
    expect(find.text('12 selected'), findsOneWidget);

    await _rightClick(tester, 'Note 12');
    final rows = tester.widgetList<KapyMenuActionRow>(
      find.byType(KapyMenuActionRow),
    );
    expect(
      [for (final row in rows) row.action.label],
      [
        'Open in tabs',
        'Pin',
        'Move to Hidden Notes',
        'Archive',
        'Delete 12 notes…',
      ],
    );
    for (final row in rows) {
      final label = row.action.label;
      final text = find.descendant(
        of: find.byKey(const ValueKey('kapy-context-menu')),
        matching: find.text(label),
      );
      expect(
        tester.renderObject<RenderParagraph>(text).didExceedMaxLines,
        isFalse,
        reason: '$label fits the menu',
      );
    }
  });

  testWidgets('the bar archives every picked note in one change, and the open '
      "one's place goes to the next note down", (tester) async {
    await _pump(tester);
    await _click(tester, 'Third');
    await _click(tester, 'Second', holding: LogicalKeyboardKey.shiftLeft);
    var changes = 0;
    notes.addListener(() => changes++);

    await tester.tap(find.byKey(const ValueKey('picked-archive')));
    await tester.pumpAndSettle();

    expect(notes.archivedNotes.map((n) => n.title), ['Third', 'Second']);
    expect(notes.notes.map((n) => n.title), ['Fourth', 'First']);
    expect(changes, 1);
    expect(find.text('Moved 2 notes to Archive'), findsOneWidget);
    expect(_picked(tester), isEmpty);
    expect(_open(tester, 'First'), isTrue);
  });

  testWidgets('the archive shortcut files every picked note away', (
    tester,
  ) async {
    await _pump(tester);
    await _click(tester, 'Fourth');
    await _click(tester, 'Third', holding: LogicalKeyboardKey.shiftLeft);

    await _chord(tester, LogicalKeyboardKey.backspace);

    expect(
      notes.archivedNotes.map((n) => n.title),
      unorderedEquals(['Fourth', 'Third']),
    );
    expect(find.text('Moved 2 notes to Archive'), findsOneWidget);
  });

  testWidgets('deleting several picked notes always asks with how many, even '
      'after Don’t ask again; one picked note deletes as its row does', (
    tester,
  ) async {
    await _pump(tester);
    prefs.askBeforeDeleting = false;
    await _click(tester, 'Fourth');
    await _click(tester, 'Third', holding: LogicalKeyboardKey.shiftLeft);

    await tester.tap(find.byKey(const ValueKey('picked-delete')));
    await tester.pumpAndSettle();
    expect(find.text('Delete 2 notes?'), findsOneWidget);
    expect(find.byKey(const ValueKey('delete-stop-asking')), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(notes.notes, hasLength(4));
    expect(_picked(tester), ['Fourth', 'Third']);

    await tester.tap(find.byKey(const ValueKey('picked-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-delete')));
    await tester.pumpAndSettle();
    expect(notes.notes.map((n) => n.title), ['Second', 'First']);
    expect(notes.tombstones, hasLength(2));
    expect(find.text('2 notes deleted'), findsOneWidget);
    expect(_picked(tester), isEmpty);

    await _click(tester, 'First', holding: LogicalKeyboardKey.shiftLeft);
    await _click(tester, 'Second');
    expect(_picked(tester), ['First']);
    await tester.tap(find.byKey(const ValueKey('picked-delete')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(notes.notes.map((n) => n.title), ['Second']);
  });

  testWidgets('picked notes move to Hidden Notes together, and back', (
    tester,
  ) async {
    await _pump(tester);
    await _click(tester, 'Fourth');
    await _click(tester, 'Third', holding: LogicalKeyboardKey.shiftLeft);
    await _rightClick(tester, 'Third');
    await tester.tap(_item('hide', _note('Third')));
    await tester.pumpAndSettle();
    expect(
      notes.hiddenNotes.map((n) => n.title),
      unorderedEquals(['Fourth', 'Third']),
    );
    expect(
      find.textContaining('Moved 2 notes to Hidden Notes.'),
      findsOneWidget,
    );

    await _show(tester, NotesShow.hidden);
    await _click(tester, 'Third');
    await _chord(tester, LogicalKeyboardKey.keyA);
    await tester.tap(find.byKey(const ValueKey('picked-unhide')));
    await tester.pumpAndSettle();
    expect(notes.hiddenNotes, isEmpty);
    expect(find.text('Moved 2 notes to Notes'), findsOneWidget);
  });

  testWidgets('in the archive a click with Cmd picks too, the bar restores '
      'them, and leaving the archive lets picks go', (tester) async {
    await _pump(tester);
    notes.archiveAll([for (final note in notes.notes) note.id]);
    await tester.pumpAndSettle();
    await _show(tester, NotesShow.archive);
    await _click(tester, 'Fourth');

    await _click(tester, 'Second', holding: LogicalKeyboardKey.metaLeft);
    expect(find.text('2 selected'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('picked-restore')));
    await tester.pumpAndSettle();
    expect(
      notes.notes.map((n) => n.title),
      unorderedEquals(['Fourth', 'Second']),
    );
    expect(find.text('2 notes restored'), findsOneWidget);

    await _click(tester, 'First', holding: LogicalKeyboardKey.metaLeft);
    expect(_picked(tester), isNotEmpty);
    await _show(tester, NotesShow.all);
    expect(_picked(tester), isEmpty);
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('on a phone, Select in a long press menu picks the note, '
        'taps pick more or let go, and the bar archives them '
        '(${platform.name})', (tester) async {
      await _pumpPhone(tester, platform);
      await _selectFromMenu(tester, 'Second');
      expect(_picked(tester), ['Second']);
      expect(find.text('1 selected'), findsOneWidget);

      await _click(tester, 'Fourth');
      await _click(tester, 'First');
      await _click(tester, 'First');
      expect(_picked(tester), ['Fourth', 'Second']);
      expect(_row('Third').hitTestable(), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('picked-archive')));
      await tester.pumpAndSettle();
      expect(_note('Fourth').isArchived, isTrue);
      expect(_note('Second').isArchived, isTrue);
      expect(_note('Third').isArchived, isFalse);
      expect(find.text('2 selected'), findsNothing);
      expect(_picked(tester), isEmpty);
    });

    testWidgets('on a phone, a long press while picking opens the menu for '
        'every picked note, and deleting them asks with how many '
        '(${platform.name})', (tester) async {
      await _pumpPhone(tester, platform);
      await _selectFromMenu(tester, 'Second');
      await tester.longPress(_row('Third'));
      await tester.pumpAndSettle();
      expect(_picked(tester), ['Third', 'Second']);
      final delete = _item('delete', _note('Third'));
      expect(_label(tester, delete), 'Delete 2 notes…');

      await tester.tap(delete);
      await tester.pumpAndSettle();
      expect(find.text('Delete 2 notes?'), findsOneWidget);
      expect(find.byKey(const ValueKey('delete-stop-asking')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('confirm-delete')));
      await tester.pumpAndSettle();
      expect(
        notes.allNotes.map((note) => note.title),
        unorderedEquals(['First', 'Fourth']),
      );
    });
  }

  testWidgets('on Android, Back lets go of the picks and leaves the list '
      'open, and closing the list lets go of them too', (tester) async {
    await _pumpPhone(tester, TargetPlatform.android);
    await _selectFromMenu(tester, 'Second');
    expect(find.text('1 selected'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_picked(tester), isEmpty);
    expect(find.text('1 selected'), findsNothing);
    expect(_row('Third').hitTestable(), findsOneWidget);

    await _selectFromMenu(tester, 'Third');
    expect(find.text('1 selected'), findsOneWidget);
    await tester.tapAt(const Offset(380, 400));
    await tester.pumpAndSettle();
    expect(_row('Third').hitTestable(), findsNothing);
    await tester.tap(find.byKey(const ValueKey('toolbar-notes-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsNothing);
    expect(_picked(tester), isEmpty);
  });
}
