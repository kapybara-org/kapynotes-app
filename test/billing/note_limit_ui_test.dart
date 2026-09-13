import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/billing/note_limit.dart';
import 'package:kapy_notes/billing/plan_terms.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/sync/account.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/sync/key_store.dart';
import 'package:kapy_notes/sync/sync_state.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/sidebar.dart';

import '../sync/fake_server.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'note-limit-ui-test.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
  @override
  void putNow(String key, Object? value) => data[key] = value;
}

class _TermsApi implements PlanTermsApi {
  @override
  Future<PlanTermsAnswer> fetch() async =>
      const PlanTermsAnswer(enforced: true, trialDays: 14, freeNoteLimit: 5);
}

void main() {
  late _MemoryStore store;
  late NotesStore notes;
  late Account account;
  late List<Note> written;

  /// A signed-out device whose own fourteen days ran out a week ago, with
  /// seven notes: the two oldest are past the limit.
  Future<void> pumpOverTheLimit(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1100, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    store = _MemoryStore();
    store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
    final now = DateTime.now();
    store.data['plans.v1'] = {
      'enforced': true,
      'enforcedSince': now
          .subtract(const Duration(days: 21))
          .millisecondsSinceEpoch,
      'checkedAt': now.millisecondsSinceEpoch,
      'trialDays': 14,
      'freeNoteLimit': 5,
    };
    var tick = 0;
    notes = NotesStore(
      store,
      now: () => now
          .subtract(const Duration(days: 1))
          .add(Duration(minutes: tick++)),
    );
    await notes.load();
    written = [for (var i = 0; i < 7; i++) notes.create(body: 'Note $i')];

    account = Account(
      auth: FakeAuth(),
      syncApi: (_) => FakeApi(FakeServer()),
      keys: KeyStore(InMemorySecureStore()),
      notes: notes,
      state: SyncState(store),
      store: store,
      docStorage: MemoryDocStorage(),
    );
    final terms = PlanTerms(store: store, api: _TermsApi());
    account.planTerms = terms;
    account.noteLimit = NoteLimit(notes: notes, account: account, terms: terms);
    addTearDown(account.dispose);

    final prefs = LayoutPrefs(store)..load();
    if (!prefs.sidebarVisible) prefs.toggleSidebar();
    await tester.pumpWidget(
      KapyNotesApp(
        store: store,
        notes: notes,
        rates: RatesRepository(store),
        prefs: prefs,
        shortcuts: ShortcutPrefs(store)..load(),
        account: account,
      ),
    );
    await tester.pumpAndSettle();
  }

  NoteEditor editor(WidgetTester tester) =>
      tester.widget<NoteEditor>(find.byType(NoteEditor));

  testWidgets('a note past the limit opens read-only, and says why', (
    tester,
  ) async {
    await pumpOverTheLimit(tester);
    expect(account.state, AccountState.signedOut);
    expect(account.noteLimit!.lockedIds, {written[0].id, written[1].id});

    await tester.tap(find.byKey(ValueKey(written[0].id)));
    await tester.pumpAndSettle();

    expect(editor(tester).readOnly, isTrue);
    expect(find.text('Read-only on Free'), findsOneWidget);
    // Not the sharing role's words: nobody else owns this note.
    expect(find.text('View only'), findsNothing);
    // Marked in the list before it is ever opened.
    expect(
      find.descendant(
        of: find.byType(Sidebar),
        matching: find.byIcon(Icons.lock_outline_rounded),
      ),
      findsNWidgets(2),
    );

    await tester.tap(find.text('Read-only on Free'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('note-limit-dialog')), findsOneWidget);
    expect(find.text('This note is read-only on Free'), findsOneWidget);
    expect(find.textContaining('Pin this note'), findsOneWidget);
    // This build sells nothing, so there is nothing to press but OK.
    expect(find.byKey(const ValueKey('note-limit-get-pro')), findsNothing);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
  });

  testWidgets('a note at the top of the list stays editable', (tester) async {
    await pumpOverTheLimit(tester);
    await tester.tap(find.byKey(ValueKey(written[6].id)));
    await tester.pumpAndSettle();

    expect(editor(tester).readOnly, isFalse);
    expect(find.text('Read-only on Free'), findsNothing);
  });

  testWidgets('no new note starts over the limit, and it says what to do', (
    tester,
  ) async {
    await pumpOverTheLimit(tester);
    final before = notes.allNotes.length;

    await tester.tap(find.byKey(const ValueKey('sidebar-new-note')));
    await tester.pumpAndSettle();

    expect(notes.allNotes, hasLength(before));
    expect(find.text('Free keeps up to five notes'), findsOneWidget);
    expect(find.textContaining('delete a note you no longer need'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
  });

  testWidgets('pinning a note past the limit makes it the editable one', (
    tester,
  ) async {
    await pumpOverTheLimit(tester);
    notes.togglePinned(written[0].id);
    await tester.pumpAndSettle();

    expect(account.noteLimit!.isLocked(written[0]), isFalse);
    expect(account.noteLimit!.lockedIds, {written[1].id, written[2].id});
    await tester.tap(find.byKey(ValueKey(written[0].id)));
    await tester.pumpAndSettle();
    expect(editor(tester).readOnly, isFalse);
  });
}
