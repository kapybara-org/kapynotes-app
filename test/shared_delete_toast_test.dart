import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
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
import 'package:kapy_notes/ui/sidebar.dart';
import 'package:material_ui/material_ui.dart';

import 'share_dialog_test.dart' show Device;
import 'sync/fake_server.dart';
import 'sync/sharing_section_test.dart' show namePeople;
import 'test_fonts.dart';

class _Store extends LocalStore {
  _Store() : super(fileName: 'shared-delete-toast-test.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
}

/// The toast after a picked delete, read the way a person meets it: notes
/// of their own go for everyone, and notes somebody shares with them only
/// leave their own notes.
void main() {
  late FakeServer server;
  late Device priya;
  late _Store store;
  late NotesStore notes;
  late Account account;
  late LayoutPrefs prefs;
  late RatesRepository rates;
  late ShortcutPrefs shortcuts;

  setUpAll(loadTestFonts);

  setUp(() {
    server = FakeServer();
    namePeople(server);
    priya = Device(server, userId: 'user-2', device: 'priya');
    store = _Store();
    notes = NotesStore(store);
    final state = SyncState(store);
    final sam = server.user('user-1');
    account = Account(
      auth: FakeAuth(id: 'user-1', email: sam.email, name: sam.name),
      syncApi: (_) =>
          FakeApi(server, device: 'device-user-1', userId: 'user-1'),
      keys: KeyStore(InMemorySecureStore()),
      notes: notes,
      state: state,
      store: store,
      tags: TagStore(store),
      tasks: TaskLibrary(
        notes: notes,
        store: store,
        state: state,
        storage: MemoryDocStorage(),
      ),
    );
    prefs = LayoutPrefs(store);
    rates = RatesRepository(store);
    shortcuts = ShortcutPrefs(store);
    store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
  });

  tearDown(() {
    account.dispose();
    priya.dispose();
  });

  Future<void> signIn(WidgetTester tester) => tester.runAsync(() async {
    await notes.load();
    await account.restore();
    await account.signIn(email: 'sam@kapy34.test', password: 'x');
    await account.createPassphrase('a good passphrase');
  });

  /// Priya shares two notes with Sam, and Sam shares one of his own with her.
  /// Sam's sync is live, so her notes reach him a moment after it returns.
  Future<void> shareBothWays(WidgetTester tester) => tester.runAsync(() async {
    await priya.boot();
    final theirs = [
      priya.notes.create(body: 'Packing list'),
      priya.notes.create(body: 'Route'),
    ];
    await priya.sync.syncNow();
    for (final note in theirs) {
      await priya.sharing.shareNoteWith(
        note.id,
        email: server.user('user-1').email,
      );
    }
    await account.sharing!.acceptInvite(server.outbox.single.token);
    final mine = notes.create(body: 'Trip budget');
    await account.sync!.syncNow();
    await account.sharing!.shareNoteWith(mine.id, email: priya.email);
    await priya.sharing.acceptInvite(server.outbox.last.token);
    await priya.sync.syncNow();
    await account.sharing!.refresh();
    await account.sync!.syncNow();
    for (var i = 0; i < 200 && notes.allNotes.length < 3; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  });

  Future<void> pumpShared(WidgetTester tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1100, 760);
    addTearDown(tester.view.reset);
    prefs.load();
    if (!prefs.sidebarVisible) prefs.toggleSidebar();
    shortcuts.load();
    await tester.pumpWidget(
      KapyNotesApp(
        store: store,
        notes: notes,
        rates: rates,
        prefs: prefs,
        shortcuts: shortcuts,
        account: account,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rail-shared')));
    await tester.pumpAndSettle();
  }

  /// Opens the first, ⇧-clicks it to start picking, then picks the rest
  /// with plain clicks, as a click picks while notes are picked.
  Future<void> deletePicked(WidgetTester tester, List<String> titles) async {
    final first = find.widgetWithText(NoteRow, titles.first);
    await tester.tap(first);
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(first);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    for (final title in titles.skip(1)) {
      await tester.tap(find.widgetWithText(NoteRow, title));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byKey(const ValueKey('picked-delete')));
    await tester.pumpAndSettle();
  }

  testWidgets('a pick of your own note and one shared with you says which '
      'went for good', (tester) async {
    await signIn(tester);
    await shareBothWays(tester);
    await pumpShared(tester);

    await deletePicked(tester, ['Trip budget', 'Packing list']);
    expect(find.text('Delete 2 notes?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-delete')));
    await tester.pumpAndSettle();
    expect(
      find.text('Note deleted, and 1 removed from your notes'),
      findsOneWidget,
    );
  });

  testWidgets('a pick of notes shared with you only says they left your '
      'notes', (tester) async {
    await signIn(tester);
    await shareBothWays(tester);
    await pumpShared(tester);

    await deletePicked(tester, ['Packing list', 'Route']);
    expect(find.text('Remove from your notes?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-delete')));
    await tester.pumpAndSettle();
    expect(find.text('Removed from your notes'), findsOneWidget);
    expect(find.textContaining('deleted'), findsNothing);
  });
}
