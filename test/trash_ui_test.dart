import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/data/folders.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/tags.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/core/toast.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/hidden_notes_gate.dart';
import 'package:kapy_notes/ui/notes_list.dart';
import 'package:kapy_notes/ui/sidebar.dart';
import 'package:material_ui/material_ui.dart';

import 'app_test.dart' show MemoryStore;
import 'test_fonts.dart';

/// Recently deleted: where a deleted note waits for 30 days, on a desktop
/// and on a phone.

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

/// The app holding First, Second and Third, newest last, on a Mac with the
/// list beside the page, or on an iPhone.
Future<void> _pump(
  WidgetTester tester, {
  TargetPlatform platform = TargetPlatform.macOS,
}) async {
  AppPlatform.debugTargetPlatformOverride = platform;
  addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
  store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
  tester.view.physicalSize = platform == TargetPlatform.iOS
      ? const Size(390, 844)
      : const Size(1100, 760);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final phone = platform == TargetPlatform.iOS;
  if (phone) {
    // Notes written this morning, as a phone's Home lists them.
    final now = DateTime(2025, 11, 19, 9, 41);
    notes = NotesStore(store, now: () => now);
    final at = DateTime(2025, 11, 19, 9).millisecondsSinceEpoch;
    store.data['notes.v1'] = [
      for (final (index, body) in ['Third', 'Second', 'First'].indexed)
        {
          'id': body.toLowerCase(),
          'body': body,
          'createdAt': at - index,
          'updatedAt': at - index,
        },
    ];
  }
  await notes.load();
  if (!phone) {
    for (final body in ['First', 'Second', 'Third']) {
      notes.create();
      notes.updateBody(notes.notes.first.id, body);
    }
  }
  prefs.load();
  if (!prefs.sidebarVisible) prefs.toggleSidebar();
  final folders = phone ? FolderStore(store) : null;
  await folders?.load();
  await tester.pumpWidget(
    KapyNotesApp(
      store: store,
      notes: notes,
      rates: RatesRepository(store),
      prefs: prefs,
      shortcuts: ShortcutPrefs(store)..load(),
      hiddenNotesGate: _OpenGate(),
      tags: TagStore(store),
      folders: folders,
      tasks: phone
          ? TaskLibrary(notes: notes, store: store, storage: MemoryDocStorage())
          : null,
    ),
  );
  await tester.pumpAndSettle();
}

Note _note(String title) => notes.allNotes.singleWhere((n) => n.title == title);

Finder _row(String title) => find.widgetWithText(NoteRow, title);

Finder _item(String action, Note note) =>
    find.byKey(ValueKey('$action-note-${note.id}'));

Finder _filter(NotesShow show) =>
    find.byKey(ValueKey('notes-filter-${show.name}'));

Future<void> _choose(WidgetTester tester, String title, String action) async {
  final note = _note(title);
  await tester.tap(_row(title), buttons: kSecondaryButton);
  await tester.pumpAndSettle();
  await tester.tap(_item(action, note));
  await tester.pumpAndSettle();
}

Future<void> _show(WidgetTester tester, NotesShow show) async {
  await tester.tap(find.byKey(const ValueKey('sidebar-notes-filter')));
  await tester.pumpAndSettle();
  await tester.tap(_filter(show));
  await tester.pumpAndSettle();
}

Future<void> _confirm(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('confirm-delete')));
  await tester.pumpAndSettle();
}

/// Answers yes to the question, and lets the notice that follows run out
/// its time.
Future<void> _confirmAndLetNoticeGo(WidgetTester tester) async {
  Toast.debugAnimateLifetimeInTests = true;
  addTearDown(() => Toast.debugAnimateLifetimeInTests = false);
  await tester.tap(find.byKey(const ValueKey('confirm-delete')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(Toast.actionLifetime);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadTestFonts);

  setUp(() {
    store = MemoryStore();
    notes = NotesStore(store);
    prefs = LayoutPrefs(store);
  });

  group('on a desktop', () {
    testWidgets('Delete moves a note to Recently deleted, and Undo puts it '
        'back', (tester) async {
      await _pump(tester);
      final second = _note('Second');

      await _choose(tester, 'Second', 'delete');
      expect(find.text('Delete note?'), findsOneWidget);
      expect(
        find.text(
          'Moves "Second" to Recently deleted. You can put it back for 30 '
          'days.',
        ),
        findsOneWidget,
      );
      await _confirm(tester);

      expect(find.text('Moved to Recently deleted'), findsOneWidget);
      expect(_row('Second'), findsNothing);
      expect(notes.trashedNotes.single.id, second.id);
      expect(notes.tombstones, isEmpty);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(_row('Second'), findsOneWidget);
      expect(notes.trashedNotes, isEmpty);
      expect(notes.byId(second.id)!.isArchived, isFalse);

      await _choose(tester, 'Second', 'delete');
      await _confirmAndLetNoticeGo(tester);
      expect(notes.trashedNotes.single.id, second.id);
      expect(notes.tombstones, isEmpty);
    });

    testWidgets('the Show menu lists Recently deleted under Archive, with its '
        'count, and its rows say how long is left', (tester) async {
      await _pump(tester);
      notes.trashAll([_note('First').id]);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('sidebar-notes-filter')));
      await tester.pumpAndSettle();
      final trash = _filter(NotesShow.trash);
      expect(
        tester.getTopLeft(trash).dy,
        greaterThan(tester.getTopLeft(_filter(NotesShow.archive)).dy),
      );
      expect(
        find.descendant(of: trash, matching: find.text('Recently deleted')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: trash, matching: find.text('1')),
        findsOneWidget,
      );
      await tester.tap(trash);
      await tester.pumpAndSettle();

      expect(_row('First'), findsOneWidget);
      expect(_row('Second'), findsNothing);
      expect(
        find.descendant(of: _row('First'), matching: find.text('30 days left')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('trash-empty')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('trash-start-selecting')),
        findsOneWidget,
      );
    });

    testWidgets('a deleted note opens read-only under its bar, whose Put back '
        'returns it to the notes', (tester) async {
      await _pump(tester);
      final first = _note('First');
      notes.trashAll([first.id]);
      await tester.pumpAndSettle();
      await _show(tester, NotesShow.trash);
      await tester.tap(_row('First'));
      await tester.pumpAndSettle();

      final bar = find.byKey(const ValueKey('trashed-note-bar'));
      expect(bar, findsOneWidget);
      expect(
        find.descendant(of: bar, matching: find.text('In Recently deleted')),
        findsOneWidget,
      );
      expect(
        tester.widget<NoteEditor>(find.byType(NoteEditor)).readOnly,
        isTrue,
      );

      await tester.tap(find.byKey(const ValueKey('trashed-note-put-back')));
      await tester.pumpAndSettle();
      expect(find.text('Put back in Notes'), findsOneWidget);
      expect(notes.trashedNotes, isEmpty);
      expect(notes.notes.map((note) => note.id), contains(first.id));
    });

    testWidgets("a row's menu offers Put back and Delete now…, which always "
        'asks, and goes for good once its notice has gone', (tester) async {
      await _pump(tester);
      prefs.askBeforeDeleting = false;
      final first = _note('First');
      final second = _note('Second');
      notes.trashAll([first.id, second.id]);
      await tester.pumpAndSettle();
      await _show(tester, NotesShow.trash);

      await tester.tap(_row('First'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(_item('put-back', first), findsOneWidget);
      expect(
        find.descendant(
          of: _item('delete', first),
          matching: find.text('Delete now…'),
        ),
        findsOneWidget,
      );
      expect(_item('archive', first), findsNothing);
      expect(_item('pin', first), findsNothing);
      await tester.tap(_item('put-back', first));
      await tester.pumpAndSettle();
      expect(notes.byId(first.id)!.isTrashed, isFalse);
      expect(notes.byId(first.id)!.isArchived, isFalse);

      await _choose(tester, 'Second', 'delete');
      expect(find.text('Delete note for good?'), findsOneWidget);
      expect(find.byKey(const ValueKey('delete-stop-asking')), findsNothing);
      await _confirm(tester);
      expect(find.text('Note deleted'), findsOneWidget);
      expect(_row('Second'), findsNothing);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(_row('Second'), findsOneWidget);

      await _choose(tester, 'Second', 'delete');
      await _confirmAndLetNoticeGo(tester);
      expect(notes.byId(second.id), isNull);
      expect(notes.tombstones.single.id, second.id);
    });

    testWidgets('the Delete key asks first, and Empty asks with how many', (
      tester,
    ) async {
      store.data['readyToTypeOnOpen.v1'] = false;
      await _pump(tester);
      notes.trashAll([for (final note in notes.notes) note.id]);
      await tester.pumpAndSettle();
      await _show(tester, NotesShow.trash);

      await tester.tap(_row('Third'));
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(find.text('Delete note for good?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(notes.trashedNotes, hasLength(3));

      await tester.tap(find.byKey(const ValueKey('trash-empty')));
      await tester.pumpAndSettle();
      expect(find.text('Delete 3 notes for good?'), findsOneWidget);
      await _confirmAndLetNoticeGo(tester);
      expect(notes.allNotes, isEmpty);
      expect(notes.tombstones, hasLength(3));
      expect(find.text('Recently deleted is empty'), findsOneWidget);
      expect(find.byKey(const ValueKey('trash-empty')), findsNothing);
    });
  });

  group('on a phone', () {
    testWidgets('Home lists Recently deleted with its count, and a row swipes '
        'to Put back, or to Delete now, which asks', (tester) async {
      await _pump(tester, platform: TargetPlatform.iOS);
      // The phone opens on the latest note; Home is its list.
      await tester.tap(find.text('Home'));
      await tester.pumpAndSettle();
      final first = _note('First');
      final second = _note('Second');
      notes.trashAll([first.id, second.id]);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('phone-filters')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sidebar-notes-filter')));
      await tester.pumpAndSettle();
      final trash = _filter(NotesShow.trash);
      expect(
        find.descendant(of: trash, matching: find.text('2')),
        findsOneWidget,
      );
      await tester.tap(trash);
      await tester.pumpAndSettle();
      expect(_row('First'), findsOneWidget);

      await tester.drag(_row('Second'), const Offset(-120, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('swipe-delete-${second.id}')));
      await tester.pumpAndSettle();
      expect(find.text('Delete note for good?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await tester.drag(_row('First'), const Offset(-330, 0));
      await tester.pumpAndSettle();
      expect(notes.byId(first.id)!.isTrashed, isFalse);
      expect(_row('First'), findsNothing);
    });
  });
}
