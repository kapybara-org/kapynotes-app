import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/update_checker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'test_fonts.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'update-ui-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

/// A checker wired to a client that fails the test if it is ever used. Every
/// case here starts from a state the app already knows, so nothing should
/// reach the network while the UI is on screen.
UpdateChecker _offlineChecker(LocalStore store) => UpdateChecker(
  store,
  client: MockClient((_) async => throw StateError('no network in this test')),
  packageInfo: PackageInfo(
    appName: 'Kapy Notes',
    packageName: 'com.kapybara.kapynotes',
    version: '1.0.0',
    buildNumber: '1',
  ),
);

void _seedPendingUpdate(LocalStore store) => store.put('updates.v1', {
  'available': {
    'version': '1.0.1',
    'build': 2,
    'notesUrl': 'https://example.test/notes',
  },
  'checkedAt': DateTime.now().toIso8601String(),
});

void _seedUpToDate(LocalStore store) => store.put('updates.v1', {
  'available': null,
  'checkedAt': DateTime.now().toIso8601String(),
});

Future<UpdateChecker> _pump(WidgetTester tester, LocalStore store) async {
  const size = Size(1100, 760);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final notes = NotesStore(store);
  final prefs = LayoutPrefs(store);
  final shortcuts = ShortcutPrefs(store);
  final rates = RatesRepository(store);
  final updates = _offlineChecker(store);

  await notes.load();
  prefs.load();
  shortcuts.load();
  await tester.pumpWidget(
    KapyNotesApp(
      store: store,
      notes: notes,
      rates: rates,
      prefs: prefs,
      shortcuts: shortcuts,
      updates: updates,
    ),
  );
  await tester.pumpAndSettle();
  return updates;
}

Future<void> _openSettings(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('note-settings')).first);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadTestFonts);

  setUp(() => AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS);
  tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

  testWidgets('a pending update reaches the settings row and its button', (
    tester,
  ) async {
    final store = _MemoryStore();
    _seedPendingUpdate(store);
    await _pump(tester, store);
    await _openSettings(tester);

    expect(find.text('Version 1.0.1 available'), findsOneWidget);
    expect(find.text('Ready to install · you have 1.0.0'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Update'), findsOneWidget);
    expect(find.byKey(const ValueKey('update-release-notes')), findsOneWidget);
  });

  testWidgets('an up-to-date app offers a check and names its version', (
    tester,
  ) async {
    final store = _MemoryStore();
    _seedUpToDate(store);
    await _pump(tester, store);
    await _openSettings(tester);

    expect(find.text('Kapy Notes 1.0.0'), findsOneWidget);
    expect(find.text('Up to date · checked today'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Check'), findsOneWidget);
    expect(find.byKey(const ValueKey('update-release-notes')), findsNothing);
  });

  testWidgets('the sidebar gear announces a pending update', (tester) async {
    final store = _MemoryStore();
    _seedPendingUpdate(store);
    await _pump(tester, store);

    expect(find.byTooltip('Settings — update available'), findsOneWidget);
  });

  testWidgets('the gear says nothing while the app is current', (tester) async {
    final store = _MemoryStore();
    _seedUpToDate(store);
    await _pump(tester, store);

    expect(find.byTooltip('Settings'), findsWidgets);
    expect(find.byTooltip('Settings — update available'), findsNothing);
  });

  testWidgets('the update row is absent where the app cannot update itself', (
    tester,
  ) async {
    final store = _MemoryStore();
    const size = Size(1100, 760);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final notes = NotesStore(store);
    final prefs = LayoutPrefs(store);
    final shortcuts = ShortcutPrefs(store);
    final rates = RatesRepository(store);

    await notes.load();
    prefs.load();
    shortcuts.load();
    await tester.pumpWidget(
      KapyNotesApp(
        store: store,
        notes: notes,
        rates: rates,
        prefs: prefs,
        shortcuts: shortcuts,
      ),
    );
    await tester.pumpAndSettle();
    await _openSettings(tester);

    expect(find.text('UPDATES'), findsNothing);
    expect(find.widgetWithText(TextButton, 'Check'), findsNothing);
  });
}
