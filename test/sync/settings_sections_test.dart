import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/sync/account.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/sync/key_store.dart';
import 'package:kapy_notes/sync/sync_state.dart';
import 'package:kapy_notes/ui/settings_dialog.dart';

import 'fake_server.dart';

class _Store extends LocalStore {
  _Store() : super(fileName: 'settings-sections-test.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
  @override
  void putNow(String key, Object? value) => data[key] = value;
}

/// Settings, opened with an account that has been signed in and unlocked —
/// the only state where both halves of an account have anything to show.
Future<void> pumpSettings(
  WidgetTester tester, {
  required Size size,
  required bool asSheet,
  SettingsSection? section,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final server = FakeServer();
  final store = _Store();
  final notes = NotesStore(store);
  final account = Account(
    auth: FakeAuth(
      id: 'user-1',
      email: server.user('user-1').email,
      name: server.user('user-1').name,
      image: server.user('user-1').image,
    ),
    syncApi: (_) => FakeApi(server, device: 'device-1', userId: 'user-1'),
    keys: KeyStore(InMemorySecureStore()),
    notes: notes,
    state: SyncState(store),
    store: store,
    docStorage: MemoryDocStorage(),
  );
  addTearDown(account.dispose);
  await tester.runAsync(() async {
    await notes.load();
    await account.restore();
    await account.signIn(email: 'a@b.co', password: 'x');
    await account.createPassphrase('a good passphrase');
  });

  await tester.pumpWidget(
    MaterialApp(
      theme: KapyTheme.dark(),
      home: Scaffold(
        body: SettingsDialog(
          layoutPrefs: LayoutPrefs(store)..load(),
          shortcuts: ShortcutPrefs(store)..load(),
          rates: RatesRepository(store),
          notes: notes,
          account: account,
          asSheet: asSheet,
          section: section,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('sharing sits inside Profile & sync rather than beside it', (
    tester,
  ) async {
    await pumpSettings(
      tester,
      size: const Size(880, 640),
      asSheet: false,
      section: SettingsSection.sync,
    );

    // One account, one category. Sharing stopped being a rail entry of its
    // own: an account is what both halves need, and the pane that asks for
    // one is where the rest of it belongs.
    expect(find.byKey(const ValueKey('settings-section-sync')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-section-sharing')),
      findsNothing,
    );

    // Both panes are in there, controls and all — not just the heading.
    expect(find.text('Sharing'), findsOneWidget);
    expect(find.byKey(const ValueKey('join-code')), findsOneWidget);
    expect(find.text('Sync now'), findsOneWidget);
  });

  testWidgets('the phone list opens sharing through Profile & sync', (
    tester,
  ) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);

    await pumpSettings(tester, size: const Size(390, 844), asSheet: true);

    expect(
      find.byKey(const ValueKey('settings-section-sharing')),
      findsNothing,
    );
    expect(find.text('Sharing'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('settings-section-sync')));
    await tester.pumpAndSettle();

    expect(find.text('Sharing'), findsOneWidget);
    expect(find.byKey(const ValueKey('join-code')), findsOneWidget);
  });
}
