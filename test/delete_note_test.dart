import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/ui/context_menu.dart';
import 'package:kapy_notes/ui/hidden_notes_gate.dart';
import 'package:kapy_notes/ui/notes_list.dart';
import 'package:kapy_notes/ui/sidebar.dart';
import 'package:material_ui/material_ui.dart';

import 'app_test.dart' show MemoryStore;
import 'test_fonts.dart';

/// Delete in a note's right-click menu, and the question in front of it.

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

/// The desktop app on a Mac with the list beside the page, holding [bodies]
/// newest last: First, Second, Third reads Third, Second, First down the
/// list.
Future<void> _pump(
  WidgetTester tester, {
  List<String> bodies = const ['First', 'Second', 'Third'],
  TargetPlatform platform = TargetPlatform.macOS,
}) async {
  AppPlatform.debugTargetPlatformOverride = platform;
  addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
  store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
  tester.view.physicalSize = const Size(1100, 760);
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

Note _note(String title) => notes.allNotes.singleWhere((n) => n.title == title);

Finder _row(String title) => find.widgetWithText(NoteRow, title);

Finder _item(String action, Note note) =>
    find.byKey(ValueKey('$action-note-${note.id}'));

Future<void> _rightClick(WidgetTester tester, String title) async {
  await tester.tap(_row(title), buttons: kSecondaryButton);
  await tester.pumpAndSettle();
}

/// Right-clicks [title] and chooses its delete.
Future<void> _delete(WidgetTester tester, String title) async {
  final note = _note(title);
  await _rightClick(tester, title);
  await tester.tap(_item('delete', note));
  await tester.pumpAndSettle();
}

Future<void> _show(WidgetTester tester, NotesShow show) async {
  await tester.tap(find.byKey(const ValueKey('sidebar-notes-filter')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('notes-filter-${show.name}')));
  await tester.pumpAndSettle();
}

KapyMenuAction _action(WidgetTester tester, Finder item) => tester
    .widget<KapyMenuActionRow>(
      find.descendant(of: item, matching: find.byType(KapyMenuActionRow)),
    )
    .action;

void main() {
  setUpAll(loadTestFonts);

  setUp(() {
    store = MemoryStore();
    notes = NotesStore(store);
    prefs = LayoutPrefs(store);
  });

  testWidgets("a row's right-click menu ends with Delete note…, in the "
      'warning colour, after Archive note', (tester) async {
    await _pump(tester);
    final second = _note('Second');

    await _rightClick(tester, 'Second');

    final delete = _item('delete', second);
    final archive = _item('archive', second);
    expect(delete, findsOneWidget);
    expect(_action(tester, delete).label, 'Delete note…');
    expect(_action(tester, delete).destructive, isTrue);
    // Only destruction takes the warning colour; archiving is its own
    // quiet action, in T1 with a T2 icon.
    expect(_action(tester, archive).destructive, isFalse);
    // The key archives in the list, so only Archive names it.
    expect(_action(tester, delete).hint, isNull);
    expect(_action(tester, archive).hint, '⌘⌫');
    expect(
      tester.getTopLeft(delete).dy,
      greaterThan(tester.getTopLeft(archive).dy),
    );
    final text = find.descendant(
      of: delete,
      matching: find.text('Delete note…'),
    );
    expect(
      tester.renderObject<RenderParagraph>(text).didExceedMaxLines,
      isFalse,
    );
  });

  testWidgets('a pinned row offers it too', (tester) async {
    await _pump(tester);
    final first = _note('First');
    notes.togglePinned(first.id);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('sidebar-pinned-heading')),
      findsOneWidget,
    );

    await _rightClick(tester, 'First');

    expect(_action(tester, _item('delete', first)).label, 'Delete note…');
  });

  testWidgets('asks first, and deletes for good once the answer is yes', (
    tester,
  ) async {
    await _pump(tester);
    final second = _note('Second');

    await _delete(tester, 'Second');

    expect(find.text('Delete note?'), findsOneWidget);
    expect(
      find.text('Permanently deletes "Second" from every synced device.'),
      findsOneWidget,
    );
    final box = find.byKey(const ValueKey('delete-stop-asking'));
    expect(
      find.descendant(of: box, matching: find.text('Don’t ask again')),
      findsOneWidget,
    );
    expect(tester.widget<CheckboxListTile>(box).value, isFalse);
    // Nothing has gone before the answer.
    expect(notes.byId(second.id), isNotNull);

    await tester.tap(find.byKey(const ValueKey('confirm-delete')));
    await tester.pumpAndSettle();

    expect(notes.byId(second.id), isNull);
    expect(notes.archivedNotes, isEmpty);
    expect(notes.tombstones.map((stone) => stone.id), [second.id]);
    expect(find.text('Note deleted'), findsOneWidget);
    expect(prefs.askBeforeDeleting, isTrue);

    // Unticked, so the next one asks again.
    await _delete(tester, 'First');
    expect(find.text('Delete note?'), findsOneWidget);
  });

  testWidgets('Don’t ask again, ticked and answered yes, stops the question '
      'for single deletes', (tester) async {
    await _pump(tester);
    final second = _note('Second');
    final first = _note('First');

    await _delete(tester, 'Second');
    await tester.tap(find.byKey(const ValueKey('delete-stop-asking')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const ValueKey('delete-stop-asking')),
          )
          .value,
      isTrue,
    );
    await tester.tap(find.byKey(const ValueKey('confirm-delete')));
    await tester.pumpAndSettle();

    expect(notes.byId(second.id), isNull);
    expect(prefs.askBeforeDeleting, isFalse);
    expect(store.data['askBeforeDeleting.v1'], isFalse);

    // No question to follow, so no ellipsis either.
    await _rightClick(tester, 'First');
    expect(_action(tester, _item('delete', first)).label, 'Delete note');
    await tester.tap(_item('delete', first));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(notes.byId(first.id), isNull);
    expect(find.text('Note deleted'), findsOneWidget);
  });

  testWidgets('Don’t ask again counts only with a yes', (tester) async {
    await _pump(tester);
    final second = _note('Second');

    await _delete(tester, 'Second');
    await tester.tap(find.byKey(const ValueKey('delete-stop-asking')));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(notes.byId(second.id), isNotNull);
    expect(notes.tombstones, isEmpty);
    expect(prefs.askBeforeDeleting, isTrue);
    await _delete(tester, 'Second');
    expect(find.text('Delete note?'), findsOneWidget);
  });

  testWidgets('the open note gives way to the next one down, as archiving it '
      'would', (tester) async {
    await _pump(tester);
    prefs.askBeforeDeleting = false;
    await tester.tap(_row('Second'));
    await tester.pumpAndSettle();
    expect(tester.widget<NoteRow>(_row('Second')).selected, isTrue);

    await _delete(tester, 'Second');

    expect(_row('Second'), findsNothing);
    expect(tester.widget<NoteRow>(_row('First')).selected, isTrue);
    expect(tester.widget<NoteRow>(_row('Third')).selected, isFalse);
  });

  testWidgets('deleting several archived notes asks with the count even '
      'with the question turned off, and never offers to stop asking', (
    tester,
  ) async {
    await _pump(tester);
    prefs.askBeforeDeleting = false;
    for (final note in [...notes.notes]) {
      notes.archive(note.id);
    }
    await tester.pumpAndSettle();
    await _show(tester, NotesShow.archive);

    await tester.tap(find.byKey(const ValueKey('archive-start-selecting')));
    await tester.pumpAndSettle();
    await tester.tap(_row('First'));
    await tester.tap(_row('Second'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('picked-delete')));
    await tester.pumpAndSettle();

    expect(find.text('Delete 2 notes?'), findsOneWidget);
    expect(find.byKey(const ValueKey('delete-stop-asking')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('confirm-delete')));
    await tester.pumpAndSettle();
    expect(notes.archivedNotes.map((note) => note.title), ['Third']);

    await tester.tap(find.byKey(const ValueKey('archive-delete-all')));
    await tester.pumpAndSettle();
    expect(find.text('Empty Archived Notes?'), findsOneWidget);
    expect(find.byKey(const ValueKey('delete-stop-asking')), findsNothing);
  });

  testWidgets('in the archive, with the question off, the key deletes at once '
      'and the list keeps the keyboard for the next press', (tester) async {
    store.data['readyToTypeOnOpen.v1'] = false;
    await _pump(tester);
    prefs.askBeforeDeleting = false;
    for (final note in [...notes.notes]) {
      notes.archive(note.id);
    }
    await tester.pumpAndSettle();
    await _show(tester, NotesShow.archive);
    await tester.tap(_row('Third'));
    await tester.pumpAndSettle();

    Future<void> press() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
    }

    await press();
    expect(find.byType(AlertDialog), findsNothing);
    expect(notes.archivedNotes, hasLength(2));
    await press();
    expect(notes.archivedNotes, hasLength(1));
  });

  for (final (platform, binding, label) in [
    (
      TargetPlatform.macOS,
      const ShortcutBinding(
        logicalKey: LogicalKeyboardKey.keyD,
        physicalKey: PhysicalKeyboardKey.keyD,
        meta: true,
        shift: true,
      ),
      '⇧⌘D',
    ),
    (
      TargetPlatform.windows,
      const ShortcutBinding(
        logicalKey: LogicalKeyboardKey.backspace,
        physicalKey: PhysicalKeyboardKey.backspace,
        control: true,
      ),
      'Ctrl+Backspace',
    ),
    (
      TargetPlatform.linux,
      const ShortcutBinding(
        logicalKey: LogicalKeyboardKey.backspace,
        physicalKey: PhysicalKeyboardKey.backspace,
        control: true,
      ),
      'Ctrl+Backspace',
    ),
  ]) {
    testWidgets('on ${platform.name}, Archive note names the chord the '
        'person bound, as the menu names Open in new tab', (tester) async {
      (ShortcutPrefs(store)..load()).update(ShortcutAction.deleteNote, binding);
      await _pump(tester, platform: platform);
      final second = _note('Second');

      await _rightClick(tester, 'Second');

      expect(_action(tester, _item('archive', second)).hint, label);
      expect(
        _action(tester, _item('open-tab', second)).hint,
        platform == TargetPlatform.macOS ? '⌘↵' : 'Ctrl+Enter',
      );
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();

      await tester.tap(_row('Second'));
      await tester.pumpAndSettle();
      final modifier = binding.meta
          ? LogicalKeyboardKey.metaLeft
          : LogicalKeyboardKey.controlLeft;
      await tester.sendKeyDownEvent(modifier);
      if (binding.shift) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      }
      await tester.sendKeyEvent(binding.logicalKey);
      if (binding.shift) {
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      }
      await tester.sendKeyUpEvent(modifier);
      await tester.pumpAndSettle();
      expect(notes.archivedNotes.single.title, 'Second');
    });
  }

  testWidgets('the archive and Hidden Notes keep their permanent delete, '
      'named with the question', (tester) async {
    await _pump(tester);
    final third = _note('Third');
    notes.archive(third.id);
    await tester.pumpAndSettle();
    await _show(tester, NotesShow.archive);

    await _rightClick(tester, 'Third');
    final delete = _item('delete', third);
    expect(_action(tester, delete).label, 'Delete permanently…');
    // There the key deletes, so the item names it, after Restore.
    expect(_action(tester, delete).hint, '⌘⌫');
    expect(
      tester.getTopLeft(delete).dy,
      greaterThan(tester.getTopLeft(_item('restore', third)).dy),
    );
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    await _show(tester, NotesShow.all);
    final second = _note('Second');
    await _rightClick(tester, 'Second');
    await tester.tap(_item('hide', second));
    await tester.pumpAndSettle();
    await _show(tester, NotesShow.hidden);

    await _rightClick(tester, 'Second');
    expect(
      _action(tester, _item('delete', second)).label,
      'Delete permanently…',
    );
  });
}
