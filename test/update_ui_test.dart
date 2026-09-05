import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
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

Future<UpdateChecker> _pump(
  WidgetTester tester,
  LocalStore store, {
  UpdateChecker? checker,
}) async {
  const size = Size(1100, 760);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final notes = NotesStore(store);
  final prefs = LayoutPrefs(store);
  final shortcuts = ShortcutPrefs(store);
  final rates = RatesRepository(store);
  final updates = checker ?? _offlineChecker(store);

  await notes.load();
  prefs.load();
  // The update row lives in the notes list, which a new install starts with
  // closed. These tests are about the row, not about the default.
  if (!prefs.sidebarVisible) prefs.toggleSidebar();
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

/// Updates have their own rail section, so every assertion about them starts
/// by selecting it.
Future<void> _openUpdates(WidgetTester tester) async {
  await _openSettings(tester);
  await tester.tap(find.byKey(const ValueKey('settings-section-updates')));
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
    await _openUpdates(tester);

    expect(find.text('Version 1.0.1 available'), findsOneWidget);
    expect(find.text('Ready to install · you have 1.0.0'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Update'), findsOneWidget);
    expect(find.byKey(const ValueKey('update-release-notes')), findsOneWidget);
  });

  testWidgets('a badged gear opens straight onto the updates pane', (
    tester,
  ) async {
    final store = _MemoryStore();
    _seedPendingUpdate(store);
    await _pump(tester, store);
    await _openSettings(tester);

    // No rail tap: the pending update is what the gear was announcing.
    expect(find.text('Version 1.0.1 available'), findsOneWidget);
    expect(find.text('Daily separators'), findsNothing);
  });

  testWidgets('an up-to-date app offers a check and names its version', (
    tester,
  ) async {
    final store = _MemoryStore();
    _seedUpToDate(store);
    await _pump(tester, store);
    await _openUpdates(tester);

    expect(find.text('Kapy Notes 1.0.0'), findsOneWidget);
    expect(find.text('Build 1'), findsOneWidget);
    expect(find.text('Up to date'), findsOneWidget);
    expect(find.text('Checked today'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Check'), findsOneWidget);
    expect(find.byKey(const ValueKey('update-release-notes')), findsNothing);
  });

  testWidgets('an app that has never checked claims nothing', (tester) async {
    final store = _MemoryStore();
    await _pump(tester, store);
    await _openUpdates(tester);

    // A check that never reached the manifest must not read as "up to date".
    expect(find.text('Up to date'), findsNothing);
    expect(find.text('Check for updates'), findsOneWidget);
    expect(find.text('Checks once a day'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Check'), findsOneWidget);
  });

  testWidgets('the check button reaches the manifest and dates the answer', (
    tester,
  ) async {
    final store = _MemoryStore();
    var requests = 0;
    final checker = UpdateChecker(
      store,
      client: MockClient((_) async {
        requests++;
        return http.Response(
          '{"version": "1.0.0", "build": 1, "notesUrl": ""}',
          200,
        );
      }),
      packageInfo: PackageInfo(
        appName: 'Kapy Notes',
        packageName: 'com.kapybara.kapynotes',
        version: '1.0.0',
        buildNumber: '1',
      ),
    );
    await _pump(tester, store, checker: checker);
    await _openUpdates(tester);

    // Nothing has been checked yet, so the row offers the check rather than
    // a verdict.
    expect(find.text('Check for updates'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('update-action')));
    await tester.pumpAndSettle();

    expect(requests, 1);
    expect(checker.available, isNull);
    expect(find.text('Up to date'), findsOneWidget);
    expect(find.text('Checked today'), findsOneWidget);
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
  // The update row lives in the notes list, which a new install starts with
  // closed. These tests are about the row, not about the default.
  if (!prefs.sidebarVisible) prefs.toggleSidebar();
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

    expect(
      find.byKey(const ValueKey('settings-section-updates')),
      findsNothing,
    );
    expect(find.text('SOFTWARE UPDATE'), findsNothing);
    expect(find.widgetWithText(TextButton, 'Check'), findsNothing);
  });
}
