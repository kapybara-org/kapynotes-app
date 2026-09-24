import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/desktop_integration.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/release_history.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/update_checker.dart';
import 'package:kapy_notes/data/update_installer.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'fake_update_installer.dart';
import 'test_fonts.dart';

class _MemoryStore extends LocalStore {
  /// Every test here is about the update row in an install somebody already
  /// uses, so none of them wants the note a first launch seeds — nor the
  /// request the changelog beside it would otherwise make. The list is on
  /// disk and fresh; the tests that are about it take it away again.
  _MemoryStore() : super(fileName: 'update-ui-test.json') {
    data[Onboarding.storeKey] = Onboarding.welcomeRevision;
    data['changelog.v1'] = {
      'fetchedAt': DateTime.now().toIso8601String(),
      'releases': [
        {
          'version': '1.0.0',
          'date': '2026-09-02',
          'summary': 'The build these tests are running.',
          'changes': ['Nothing that matters to the row above it.'],
        },
      ],
    };
  }

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

/// A checker wired to a client that fails the test if it is ever used. Every
/// case here starts from a state the app already knows — the last check and
/// the changelog are both on disk — so nothing should reach the network while
/// the UI is on screen.
UpdateChecker _offlineChecker(LocalStore store, {UpdateInstaller? installer}) =>
    UpdateChecker(
      store,
      client: MockClient(
        (_) async => throw StateError('no network in this test'),
      ),
      packageInfo: PackageInfo(
        appName: 'Kapy Notes',
        packageName: 'com.kapybara.kapynotes',
        version: '1.0.0',
        buildNumber: '1',
      ),
      installer: installer,
    );

/// A checker whose release is already downloaded and checked, the way a
/// launch finds it: the daily check is not due, and the installer reports
/// what an earlier run left ready.
Future<(UpdateChecker, FakeUpdateInstaller)> _readyChecker(
  LocalStore store, {
  bool quitsTheApp = true,
}) async {
  _seedPendingUpdate(store);
  final installer = FakeUpdateInstaller(quitsTheApp: quitsTheApp)
    ..onDisk = const StagedUpdate(version: '1.0.1', build: 2);
  final checker = _offlineChecker(store, installer: installer);
  await checker.checkIfDue();
  return (checker, installer);
}

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

/// Every native call the test cares about, in the order it was made.
class _ChannelLog {
  final List<String> calls = [];
  final Map<String, Object?> lastArguments = {};

  void watch(String channel, {Map<String, Object?> answers = const {}}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannel(channel), (call) async {
          calls.add('$channel.${call.method}');
          lastArguments['$channel.${call.method}'] = call.arguments;
          return answers[call.method];
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(channel), null),
    );
  }
}

Future<UpdateChecker> _pump(
  WidgetTester tester,
  LocalStore store, {
  UpdateChecker? checker,
  DesktopIntegration Function(LayoutPrefs prefs)? desktop,
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
  // Built from the same preferences the app is handed, because the pin lives
  // in both: the window level on one side, the toolbar button on the other.
  // Disposed by the app root, so nothing here does it twice.
  final integration = desktop?.call(prefs);
  await tester.pumpWidget(
    KapyNotesApp(
      store: store,
      notes: notes,
      rates: rates,
      prefs: prefs,
      shortcuts: shortcuts,
      updates: updates,
      desktopIntegration: integration,
    ),
  );
  await tester.pumpAndSettle();
  return updates;
}

Future<void> _openSettings(WidgetTester tester) async {
  // Settings is a row in the notes list, and nowhere else, so a layout with
  // the list put away opens it first.
  final open = find.byWidgetPredicate(
    (widget) =>
        widget is Tooltip && (widget.message ?? '').startsWith('Show notes'),
  );
  if (open.evaluate().isNotEmpty) {
    await tester.tap(open.first);
    await tester.pumpAndSettle();
  }
  await tester.tap(find.byKey(const ValueKey('sidebar-settings')).first);
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
    expect(find.text('Current 1.0.0'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Download'), findsOneWidget);
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

  testWidgets('Download fetches the release, then offers the restart', (
    tester,
  ) async {
    final store = _MemoryStore()..put('updates.autoDownload.v1', false);
    _seedPendingUpdate(store);
    final installer = FakeUpdateInstaller();
    await _pump(
      tester,
      store,
      checker: _offlineChecker(store, installer: installer),
    );
    await _openUpdates(tester);

    await tester.tap(find.widgetWithText(TextButton, 'Download'));
    await tester.pump();

    expect(find.text('Downloading version 1.0.1'), findsOneWidget);
    expect(find.text('50% · Current 1.0.0'), findsOneWidget);

    installer.finish();
    await tester.pumpAndSettle();

    expect(find.text('Version 1.0.1 is ready'), findsOneWidget);
    expect(find.text('Ready to install'), findsOneWidget);
    final action = find.byKey(const ValueKey('update-action'));
    expect(
      find.descendant(of: action, matching: find.text('Update and restart')),
      findsOneWidget,
    );

    await tester.tap(action);
    await tester.pump();
    expect(installer.installs, 1);
    expect(find.text('Restarting…'), findsWidgets);
    // Sparkle's quit never comes in a test; let the watchdog run out.
    await tester.pump(UpdateChecker.restartTimeout);
    await tester.pumpAndSettle();
  });

  testWidgets('a downloaded release restarts from the title bar in one '
      'click', (tester) async {
    final store = _MemoryStore();
    final (checker, installer) = await _readyChecker(store, quitsTheApp: false);
    var quits = 0;
    await _pump(tester, store, checker: checker);
    // The app root wires the quit to its own desktop integration; this one
    // has none, so put the test's in.
    checker.onBeforeQuitForUpdate = () async => quits++;

    final restart = find.byKey(const ValueKey('toolbar-update-restart'));
    expect(restart, findsOneWidget);
    expect(
      find.descendant(of: restart, matching: find.text('Update and restart')),
      findsOneWidget,
    );
    expect(find.byTooltip('Install Kapy Notes 1.0.1 and restart'), findsOne);
    // The button says it; the badge that sends people to look would only
    // repeat it.
    expect(find.byKey(const ValueKey('sidebar-update-badge')), findsNothing);

    await tester.tap(restart);
    await tester.pump();

    expect(installer.installs, 1);
    expect(quits, 1);
    expect(
      find.descendant(of: restart, matching: find.text('Restarting…')),
      findsOneWidget,
    );
  });

  testWidgets('a narrow window shortens the button rather than crowding the '
      'title', (tester) async {
    final store = _MemoryStore();
    final (checker, _) = await _readyChecker(store);
    await _pump(tester, store, checker: checker);
    tester.view.physicalSize = const Size(600, 700);
    await tester.pumpAndSettle();

    final restart = find.byKey(const ValueKey('toolbar-update-restart'));
    expect(
      find.descendant(of: restart, matching: find.text('Update')),
      findsOneWidget,
    );
    expect(find.byTooltip('Install Kapy Notes 1.0.1 and restart'), findsOne);
  });

  testWidgets('a download that fails to install says so, and goes back to '
      'Download', (tester) async {
    final store = _MemoryStore();
    final (checker, installer) = await _readyChecker(store);
    installer.installError = const UpdateInstallerException(
      'The downloaded update was damaged',
    );
    await _pump(tester, store, checker: checker);
    installer.onDisk = null;

    await tester.tap(find.byKey(const ValueKey('toolbar-update-restart')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('toolbar-update-restart')), findsNothing);
    expect(find.text('The downloaded update was damaged'), findsWidgets);
    expect(find.byKey(const ValueKey('sidebar-update-badge')), findsOneWidget);
  });

  testWidgets('the gear stays quiet while a download runs by itself', (
    tester,
  ) async {
    final store = _MemoryStore();
    _seedPendingUpdate(store);
    final installer = FakeUpdateInstaller();
    final checker = _offlineChecker(store, installer: installer);
    await checker.checkIfDue();
    await _pump(tester, store, checker: checker);

    expect(checker.isDownloading, isTrue);
    expect(find.byKey(const ValueKey('sidebar-update-badge')), findsNothing);
    expect(find.byKey(const ValueKey('toolbar-update-restart')), findsNothing);

    installer.finish();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('toolbar-update-restart')),
      findsOneWidget,
    );
  });

  testWidgets('automatic downloads can be turned off, and say what that '
      'means', (tester) async {
    final store = _MemoryStore();
    _seedUpToDate(store);
    final checker = await _pump(tester, store);
    await _openUpdates(tester);

    final toggle = find.byKey(const ValueKey('update-auto-download'));
    expect(toggle, findsOneWidget);
    expect(checker.autoDownload, isTrue);
    expect(
      find.textContaining('downloads them in the background'),
      findsOneWidget,
    );

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(checker.autoDownload, isFalse);
    expect(store.data['updates.autoDownload.v1'], isFalse);
    expect(
      find.text(
        'Checks for updates daily. Nothing downloads until you choose '
        'Download.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a check for updates leaves the pin alone', (tester) async {
    final store = _MemoryStore();
    // No update to install, so the button only reaches the manifest. Nothing
    // opens, and a window that gave up its pin for that would be giving it up
    // once a day for nothing.
    final log = _ChannelLog()
      ..watch(
        'window_manager',
        answers: {'isVisible': true, 'isMinimized': false},
      )
      ..watch('tray_manager')
      ..watch(
        'kapynotes/login_item',
        answers: {'isSupported': false, 'isEnabled': false},
      );

    final checker = UpdateChecker(
      store,
      client: MockClient(
        (_) async => http.Response(
          '{"version": "1.0.0", "build": 1, "notesUrl": ""}',
          200,
        ),
      ),
      packageInfo: PackageInfo(
        appName: 'Kapy Notes',
        packageName: 'com.kapybara.kapynotes',
        version: '1.0.0',
        buildNumber: '1',
      ),
    );
    late final DesktopIntegration desktop;
    await _pump(
      tester,
      store,
      checker: checker,
      desktop: (prefs) {
        prefs.alwaysOnTop = true;
        return desktop = DesktopIntegration(layoutPrefs: prefs);
      },
    );

    await _openUpdates(tester);
    log.calls.clear();
    await tester.tap(find.byKey(const ValueKey('update-action')));
    await tester.pumpAndSettle();

    expect(log.calls, isNot(contains('window_manager.setAlwaysOnTop')));
    expect(desktop.layoutPrefs.alwaysOnTop, isTrue);
  });

  testWidgets('the sidebar gear announces a pending update', (tester) async {
    final store = _MemoryStore();
    _seedPendingUpdate(store);
    await _pump(tester, store);

    expect(find.bySemanticsLabel('Settings, update available'), findsOneWidget);
    expect(find.byKey(const ValueKey('sidebar-app-version')), findsOneWidget);
    expect(find.text('v1.0.0'), findsOneWidget);
    expect(find.byKey(const ValueKey('sidebar-update-badge')), findsOneWidget);
    expect(find.text('Update'), findsOneWidget);
  });

  testWidgets('the gear says nothing while the app is current', (tester) async {
    final store = _MemoryStore();
    _seedUpToDate(store);
    await _pump(tester, store);

    expect(find.bySemanticsLabel('Settings'), findsWidgets);
    expect(find.bySemanticsLabel('Settings, update available'), findsNothing);
    expect(find.byKey(const ValueKey('sidebar-app-version')), findsOneWidget);
    expect(find.byKey(const ValueKey('sidebar-update-badge')), findsNothing);
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
    expect(find.text('KAPY NOTES'), findsNothing);
    expect(find.widgetWithText(TextButton, 'Check'), findsNothing);
  });

  group('the changelog', () {
    /// Two releases: the one running and the one before it.
    String body() => jsonEncode({
      'releases': [
        {
          'version': '1.0.0',
          'date': '2026-09-02',
          'summary': 'The first public build.',
          'changes': ['A notebook that does the math.', 'Dark and light.'],
        },
        {
          'version': '0.9.0',
          'date': '2026-08-28',
          'summary': 'Before it had a name.',
          'changes': ['Everything, for the first time.'],
        },
      ],
    });

    /// A store with no changelog on disk, so the pane goes and reads one.
    _MemoryStore emptyStore() => _MemoryStore()..data.remove('changelog.v1');

    testWidgets(
      'a pending Windows update shows only what is new in its version',
      (tester) async {
        AppPlatform.debugTargetPlatformOverride = TargetPlatform.windows;
        final store = _MemoryStore();
        _seedPendingUpdate(store);
        await _pump(
          tester,
          store,
          checker: UpdateChecker(
            store,
            client: MockClient((request) async {
              expect(request.url, ReleaseHistory.url);
              return http.Response(
                jsonEncode({
                  'releases': [
                    {
                      'version': '1.0.1',
                      'date': '2026-09-03',
                      'summary': 'The update waiting to be installed.',
                      'highlights': ['A calmer update experience.'],
                      'changes': [
                        'A much longer explanation for the full history.',
                      ],
                    },
                    {
                      'version': '1.0.0',
                      'date': '2026-09-02',
                      'summary': 'The build already installed.',
                      'changes': ['The first public build.'],
                    },
                  ],
                }),
                200,
              );
            }),
            packageInfo: PackageInfo(
              appName: 'Kapy Notes',
              packageName: 'com.kapybara.kapynotes',
              version: '1.0.0',
              buildNumber: '',
            ),
          ),
        );
        await _openUpdates(tester);

        expect(find.text("WHAT'S NEW"), findsOneWidget);
        expect(find.byKey(const ValueKey('release-1.0.1')), findsOneWidget);
        expect(
          find.text('The update waiting to be installed.'),
          findsOneWidget,
        );
        expect(find.text('A calmer update experience.'), findsOneWidget);
        expect(
          find.text('A much longer explanation for the full history.'),
          findsNothing,
        );
        expect(find.byKey(const ValueKey('release-1.0.0')), findsNothing);
        expect(find.text('The build already installed.'), findsNothing);
        expect(find.byKey(const ValueKey('changelog-page')), findsNothing);
      },
    );

    testWidgets('lists every release, marks the one running, and opens the '
        'newest', (tester) async {
      final store = emptyStore();
      _seedUpToDate(store);
      await _pump(
        tester,
        store,
        checker: UpdateChecker(
          store,
          client: MockClient((request) async {
            expect(request.url, ReleaseHistory.url);
            return http.Response(body(), 200);
          }),
          packageInfo: PackageInfo(
            appName: 'Kapy Notes',
            packageName: 'com.kapybara.kapynotes',
            version: '1.0.0',
            buildNumber: '1',
          ),
        ),
      );
      await _openUpdates(tester);

      expect(find.text('RELEASE NOTES'), findsOneWidget);
      expect(find.byKey(const ValueKey('release-1.0.0')), findsOneWidget);
      expect(find.byKey(const ValueKey('release-0.9.0')), findsOneWidget);
      expect(find.text('2 Sep 2026'), findsOneWidget);
      expect(find.text('Installed'), findsOneWidget);

      // The newest is open; the one below it is a heading and nothing more.
      expect(find.text('The first public build.'), findsOneWidget);
      expect(find.text('A notebook that does the math.'), findsOneWidget);
      expect(find.text('Before it had a name.'), findsNothing);
    });

    testWidgets('opens a release, and closes it again', (tester) async {
      final store = emptyStore();
      _seedUpToDate(store);
      await _pump(
        tester,
        store,
        checker: UpdateChecker(
          store,
          client: MockClient((_) async => http.Response(body(), 200)),
          packageInfo: PackageInfo(
            appName: 'Kapy Notes',
            packageName: 'com.kapybara.kapynotes',
            version: '1.0.0',
            buildNumber: '1',
          ),
        ),
      );
      await _openUpdates(tester);

      await tester.tap(find.byKey(const ValueKey('release-0.9.0')));
      await tester.pumpAndSettle();
      expect(find.text('Everything, for the first time.'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('release-0.9.0')));
      await tester.pumpAndSettle();
      expect(find.text('Everything, for the first time.'), findsNothing);
    });

    testWidgets('says so when it cannot be read, and asks again when told', (
      tester,
    ) async {
      final store = emptyStore();
      _seedUpToDate(store);
      var answer = false;
      await _pump(
        tester,
        store,
        checker: UpdateChecker(
          store,
          client: MockClient(
            (_) async =>
                answer ? http.Response(body(), 200) : http.Response('no', 500),
          ),
          packageInfo: PackageInfo(
            appName: 'Kapy Notes',
            packageName: 'com.kapybara.kapynotes',
            version: '1.0.0',
            buildNumber: '1',
          ),
        ),
      );
      await _openUpdates(tester);

      expect(find.text('Could not read the changelog'), findsOneWidget);
      expect(find.byKey(const ValueKey('release-1.0.0')), findsNothing);
      // The page itself is still offered, which is the whole answer here.
      expect(find.byKey(const ValueKey('changelog-page')), findsOneWidget);

      answer = true;
      await tester.tap(find.byKey(const ValueKey('changelog-retry')));
      await tester.pumpAndSettle();

      expect(find.text('Could not read the changelog'), findsNothing);
      expect(find.byKey(const ValueKey('release-1.0.0')), findsOneWidget);
    });
  });
}
