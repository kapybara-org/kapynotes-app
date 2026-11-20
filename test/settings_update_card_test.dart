import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:kapy_notes/core/appearance.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/update_checker.dart';
import 'package:kapy_notes/data/update_installer.dart';
import 'package:kapy_notes/ui/settings_dialog.dart';
import 'package:kapy_notes/ui/settings_update_card.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'fake_update_installer.dart';
import 'test_fonts.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore({bool changelog = true})
    : super(fileName: 'settings-update-card-test.json') {
    data[Onboarding.storeKey] = Onboarding.welcomeRevision;
    if (!changelog) return;
    data['changelog.v1'] = {
      'fetchedAt': DateTime.now().toIso8601String(),
      'releases': [
        {
          'version': '1.0.1',
          'date': '2026-09-10',
          'summary': 'Not the one running.',
          'changes': ['A later release.'],
        },
        {
          'version': '1.0.0',
          'date': '2026-09-02',
          'summary': 'The build these tests are running.',
          'changes': ['Everything, in long form.'],
          'highlights': [
            'Tasks keeps one list across every note.',
            'Press # in the command menu to filter by tag.',
            'Typing keeps up in notes of thousands of lines.',
            'A fourth line that the card leaves for the changelog.',
          ],
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

  @override
  void putNow(String key, Object? value) => data[key] = value;
}

UpdateChecker _checker(
  LocalStore store, {
  UpdateInstaller? installer,
  String version = '1.0.0',
}) => UpdateChecker(
  store,
  client: MockClient((_) async => throw StateError('no network in this test')),
  packageInfo: PackageInfo(
    appName: 'Kapy Notes',
    packageName: 'com.kapybara.kapynotes',
    version: version,
    buildNumber: '1',
  ),
  installer: installer,
);

Future<(UpdateChecker, FakeUpdateInstaller)> _readyChecker(
  LocalStore store,
) async {
  store.put('updates.v1', {
    'available': {
      'version': '1.0.1',
      'build': 2,
      'notesUrl': 'https://example.test/notes',
    },
    'checkedAt': DateTime.now().toIso8601String(),
  });
  final installer = FakeUpdateInstaller()
    ..onDisk = const StagedUpdate(version: '1.0.1', build: 2);
  final checker = _checker(store, installer: installer)
    ..onBeforeQuitForUpdate = () async {};
  await checker.checkIfDue();
  return (checker, installer);
}

const _card = ValueKey('settings-update-card');

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS);
  tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

  Future<void> pumpCard(
    WidgetTester tester,
    UpdateChecker updates, {
    LayoutPrefs? prefs,
    ThemeData? theme,
  }) async {
    final layoutPrefs = prefs ?? (LayoutPrefs(_MemoryStore())..load());
    tester.view.physicalSize = const Size(260, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? KapyTheme.dark(),
        home: Scaffold(
          body: Builder(
            builder: (context) => RepaintBoundary(
              key: const ValueKey('rail'),
              child: ColoredBox(
                color: context.palette.sidebarBackground,
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: SettingsUpdateCard(
                      updates: updates,
                      layoutPrefs: layoutPrefs,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('says what the running version brought, three lines of it and '
      'a link to the rest', (tester) async {
    await pumpCard(tester, _checker(_MemoryStore()));

    expect(find.text("What's new in 1.0.0"), findsOneWidget);
    expect(find.text('Tasks keeps one list across every note.'), findsOne);
    expect(
      find.text('Typing keeps up in notes of thousands of lines.'),
      findsOne,
    );
    expect(find.textContaining('A fourth line'), findsNothing);
    expect(find.textContaining('later release'), findsNothing);
    expect(find.byKey(const ValueKey('settings-update-changelog')), findsOne);
    expect(find.byKey(const ValueKey('settings-update-restart')), findsNothing);
    expect(find.byKey(const ValueKey('settings-whats-new-hide')), findsOneWidget);
  });

  testWidgets('with no changelog cached yet it is quiet about it', (
    tester,
  ) async {
    await pumpCard(tester, _checker(_MemoryStore(changelog: false)));

    expect(find.text("What's new in 1.0.0"), findsOneWidget);
    expect(find.textContaining('Could not'), findsNothing);
    expect(find.byKey(const ValueKey('settings-update-changelog')), findsOne);
  });

  testWidgets('a downloaded update is a Restart that goes through the '
      'installer', (tester) async {
    final (updates, installer) = await _readyChecker(_MemoryStore());
    await pumpCard(tester, updates);

    expect(find.text('Restart to update to 1.0.1'), findsOneWidget);
    expect(find.textContaining("What's new"), findsNothing);
    expect(find.byKey(const ValueKey('settings-whats-new-hide')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('settings-update-restart')));
    await tester.pumpAndSettle();
    expect(installer.installs, 1);
  });

  testWidgets(
    'a phone updates through its store, so it only says what is new',
    (tester) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      final (updates, _) = await _readyChecker(_MemoryStore());
      await pumpCard(tester, updates);

      expect(find.text("What's new in 1.0.0"), findsOneWidget);
      expect(
        find.byKey(const ValueKey('settings-update-restart')),
        findsNothing,
      );
    },
  );

  testWidgets('in Settings it takes the place of the changed list', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = _MemoryStore();
    final notes = NotesStore(store);
    await notes.load();
    final prefs = LayoutPrefs(store)..dailySeparatorsEnabled = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Scaffold(
          body: SettingsDialog(
            layoutPrefs: prefs,
            shortcuts: ShortcutPrefs(store)..load(),
            rates: RatesRepository(store),
            notes: notes,
            updates: _checker(store),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(_card), findsOneWidget);
    expect(find.text('Changed from default'), findsNothing);
    expect(find.byKey(const ValueKey('settings-changed')), findsNothing);
  });

  // A category more than there are today (another PR adds one) leaves the
  // card the room of a window one rail row shorter, so that is tested too.
  for (final (extra, ready) in [(0, false), (0, true), (1, false), (1, true)]) {
    testWidgets('in a short window every category stays reachable, with '
        '${extra == 0 ? 'the rail as it is' : 'one more item in it'} and the '
        'card ${ready ? 'ready to restart' : "on What's new"}', (tester) async {
      tester.view.physicalSize = Size(760, 520.0 - 34 * extra);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = _MemoryStore();
      final notes = NotesStore(store);
      await notes.load();
      final updates = ready ? (await _readyChecker(store)).$1 : _checker(store);
      await tester.pumpWidget(
        MaterialApp(
          theme: KapyTheme.dark(),
          home: Scaffold(
            body: SettingsDialog(
              layoutPrefs: LayoutPrefs(store),
              shortcuts: ShortcutPrefs(store)..load(),
              rates: RatesRepository(store),
              notes: notes,
              updates: updates,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final items = find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('settings-section-'),
      );
      expect(items, findsWidgets);
      expect(items.hitTestable(), findsNWidgets(items.evaluate().length));
      final card = find.byKey(_card);
      if (card.evaluate().isNotEmpty) {
        final lowestItem = tester.getBottomLeft(items.last).dy;
        expect(tester.getTopLeft(card).dy, greaterThanOrEqualTo(lowestItem));
      }
    });
  }

  // At 520 px the card is down to its one-line form and shows no error; the
  // taller window gets the whole card, where a long error must stop at the two
  // lines its height estimate allows.
  for (final height in [520.0, 760.0]) {
    testWidgets('a long update error in a window ${height.toInt()} px high '
        'takes two lines at most and leaves every category reachable', (
      tester,
    ) async {
      tester.view.physicalSize = Size(760, height);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = _MemoryStore();
      final notes = NotesStore(store);
      await notes.load();
      final (updates, installer) = await _readyChecker(store);
      installer.installError = UpdateInstallerException(
        List.filled(40, 'The installer could not be started').join('. '),
      );
      await updates.installAndRestart();
      await tester.pumpWidget(
        MaterialApp(
          theme: KapyTheme.dark(),
          home: Scaffold(
            body: SettingsDialog(
              layoutPrefs: LayoutPrefs(store),
              shortcuts: ShortcutPrefs(store)..load(),
              rates: RatesRepository(store),
              notes: notes,
              updates: updates,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final items = find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('settings-section-'),
      );
      expect(items.hitTestable(), findsNWidgets(items.evaluate().length));
      final card = find.byKey(_card);
      if (card.evaluate().isNotEmpty) {
        expect(
          tester.getTopLeft(card).dy,
          greaterThanOrEqualTo(tester.getBottomLeft(items.last).dy),
        );
      }
      final error = find.descendant(
        of: card,
        matching: find.textContaining('The installer could not be started'),
      );
      if (height < 600) {
        expect(error, findsNothing);
        return;
      }
      expect(error, findsOneWidget);
      expect(tester.widget<Text>(error).maxLines, 2);
      expect(tester.getSize(card).height, lessThanOrEqualTo(122));
    });
  }

  // main.dart builds no UpdateChecker on a phone, so Settings gets updates:
  // null there. The row must not depend on one.
  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('on ${platform.name}, with no update checker, the index opens '
        'with one quiet row for the changelog, and nothing to update', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = platform;
      PackageInfo.setMockInitialValues(
        appName: 'Kapy Notes',
        packageName: 'com.kapybara.kapynotes',
        version: '1.0.0',
        buildNumber: '1',
        buildSignature: '',
      );
      tester.view.physicalSize = const Size(400, 860);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = _MemoryStore();
      final notes = NotesStore(store);
      await notes.load();
      await tester.pumpWidget(
        MaterialApp(
          theme: KapyTheme.dark(),
          home: Scaffold(
            body: SettingsDialog(
              layoutPrefs: LayoutPrefs(store),
              shortcuts: ShortcutPrefs(store)..load(),
              rates: RatesRepository(store),
              notes: notes,
              asSheet: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final row = find.byKey(const ValueKey('settings-whats-new-row'));
      expect(find.text("What's new in 1.0.0"), findsOneWidget);
      expect(tester.getSize(row).height, greaterThanOrEqualTo(44));
      expect(
        tester.getTopLeft(row).dy,
        lessThan(tester.getTopLeft(find.byType(TextField).first).dy),
        reason: 'above the search',
      );
      expect(find.byKey(_card), findsNothing);
      expect(find.text('About & updates'), findsNothing);

      final launched = <Object?>[];
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'launch') launched.add(call.arguments);
            return true;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(
        launched.single,
        containsPair('url', 'https://kapynotes.com/changelog'),
      );
    });
  }

  const hideKey = ValueKey('settings-whats-new-hide');

  testWidgets('close hides this version, and the changelog link still opens '
      'when close is not pressed', (tester) async {
    final store = _MemoryStore();
    final prefs = LayoutPrefs(store)..load();
    final updates = _checker(store);
    await pumpCard(tester, updates, prefs: prefs);

    final launched = <Object?>[];
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'launch') launched.add(call.arguments);
          return true;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    await tester.tap(find.byKey(const ValueKey('settings-update-changelog')));
    await tester.pumpAndSettle();
    expect(launched, hasLength(1));
    expect(find.text("What's new in 1.0.0"), findsOneWidget);

    launched.clear();
    await tester.tap(
      find.descendant(of: find.byKey(hideKey), matching: find.byType(IconButton)),
    );
    await tester.pumpAndSettle();
    expect(launched, isEmpty);
    expect(find.text("What's new in 1.0.0"), findsNothing);
    expect(find.byKey(_card), findsNothing);
    expect(store.data['whatsNewDismissed.v1'], '1.0.0');
  });

  testWidgets('the close button is keyboard focusable and named', (
    tester,
  ) async {
    final store = _MemoryStore();
    final prefs = LayoutPrefs(store)..load();
    await pumpCard(tester, _checker(store), prefs: prefs);

    expect(find.byTooltip("Hide what's new"), findsOneWidget);
    final semanticsHandle = tester.ensureSemantics();
    final semantics = tester.getSemantics(find.bySemanticsLabel("Hide what's new"));
    semanticsHandle.dispose();
    expect(semantics.flagsCollection.isButton, isTrue);
    expect(semantics.label, "Hide what's new");

    bool hideIsFocused() {
      final context = tester.binding.focusManager.primaryFocus?.context;
      if (context == null) return false;
      if (context.widget.key == hideKey) return true;
      var found = false;
      context.visitAncestorElements((ancestor) {
        if (ancestor.widget.key == hideKey) {
          found = true;
          return false;
        }
        return true;
      });
      return found;
    }

    for (var i = 0; i < 8 && !hideIsFocused(); i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(
      hideIsFocused(),
      isTrue,
      reason: 'focused ${tester.binding.focusManager.primaryFocus?.debugLabel}',
    );
  });

  testWidgets('a closed notice stays closed, and comes back for a newer '
      'version that has notes', (tester) async {
    final store = _MemoryStore();
    final prefs = LayoutPrefs(store)..load();
    await pumpCard(tester, _checker(store), prefs: prefs);
    await tester.tap(
      find.descendant(of: find.byKey(hideKey), matching: find.byType(IconButton)),
    );
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox.shrink());
    final reloaded = LayoutPrefs(store)..load();
    expect(reloaded.showWhatsNew('1.0.0'), isFalse);
    await pumpCard(tester, _checker(store), prefs: reloaded);
    expect(find.textContaining("What's new"), findsNothing);

    store.put('changelog.v1', <String, Object?>{
      'fetchedAt': DateTime.now().toIso8601String(),
      'releases': [
        <String, Object?>{
          'version': '1.2.0',
          'date': '2026-10-01',
          'summary': 'A newer build.',
          'highlights': ['Notes come back with the new version.'],
          'changes': ['The rest of the notes.'],
        },
      ],
    });
    final nextPrefs = LayoutPrefs(store)..load();
    final next = _checker(store, version: '1.2.0');
    await next.history.load();
    expect(next.history.releases, isNotEmpty);
    await pumpCard(tester, next, prefs: nextPrefs);
    expect(find.text("What's new in 1.2.0"), findsOneWidget);
    expect(find.text('Notes come back with the new version.'), findsOneWidget);
    expect(find.byKey(hideKey), findsOneWidget);
  });

  testWidgets('on a phone the close button is at least 44 pt and does not '
      'open the row', (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    PackageInfo.setMockInitialValues(
      appName: 'Kapy Notes',
      packageName: 'com.kapybara.kapynotes',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    final store = _MemoryStore();
    final prefs = LayoutPrefs(store)..load();
    tester.view.physicalSize = const Size(390, 200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final launched = <Object?>[];
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'launch') launched.add(call.arguments);
          return true;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    Future<void> pumpRow(LayoutPrefs rowPrefs) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: KapyTheme.dark(),
          home: Scaffold(body: SettingsWhatsNewRow(prefs: rowPrefs)),
        ),
      );
      await tester.pumpAndSettle();
    }

    await pumpRow(prefs);
    expect(find.text("What's new in 1.0.0"), findsOneWidget);
    final hide = find.byKey(hideKey);
    final hideButton = find.descendant(
      of: hide,
      matching: find.byType(IconButton),
    );
    expect(tester.getSize(hideButton).shortestSide, greaterThanOrEqualTo(44));

    await tester.tap(find.byKey(const ValueKey('settings-whats-new-row')));
    await tester.pumpAndSettle();
    expect(launched, hasLength(1));
    expect(find.text("What's new in 1.0.0"), findsOneWidget);

    launched.clear();
    await tester.tap(hideButton);
    await tester.pumpAndSettle();
    expect(launched, isEmpty);
    expect(find.textContaining("What's new"), findsNothing);
    expect(store.data['whatsNewDismissed.v1'], '1.0.0');

    await tester.pumpWidget(const SizedBox.shrink());
    await pumpRow(LayoutPrefs(store)..load());
    expect(find.textContaining("What's new"), findsNothing);

    PackageInfo.setMockInitialValues(
      appName: 'Kapy Notes',
      packageName: 'com.kapybara.kapynotes',
      version: '1.2.0',
      buildNumber: '2',
      buildSignature: '',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpRow(LayoutPrefs(store)..load());
    expect(find.text("What's new in 1.2.0"), findsOneWidget);
  });

  testWidgets('the close button uses each theme’s quiet text color', (
    tester,
  ) async {
    for (final theme in AppTheme.values) {
      for (final dark in [false, true]) {
        final data = dark
            ? KapyTheme.dark(theme: theme)
            : KapyTheme.light(theme: theme);
        await pumpCard(tester, _checker(_MemoryStore()), theme: data);
        final icon = tester.widget<KapyIcon>(
          find.descendant(of: find.byKey(hideKey), matching: find.byType(KapyIcon)),
        );
        final palette = tester.element(find.byKey(hideKey)).palette;
        expect(icon.color, palette.textTertiary, reason: '${theme.name} dark=$dark');
      }
    }
  });

  for (final (name, theme) in [
    ('dark', KapyTheme.dark()),
    ('light', KapyTheme.light()),
  ]) {
    testWidgets("golden: what's new, $name", (tester) async {
      await pumpCard(tester, _checker(_MemoryStore()), theme: theme);
      await expectLater(
        find.byKey(const ValueKey('rail')),
        matchesGoldenFile('goldens/settings_update_card_whats_new_$name.png'),
      );
    });

    testWidgets('golden: restart to update, $name', (tester) async {
      final (updates, _) = await _readyChecker(_MemoryStore());
      await pumpCard(tester, updates, theme: theme);
      await expectLater(
        find.byKey(const ValueKey('rail')),
        matchesGoldenFile('goldens/settings_update_card_restart_$name.png'),
      );
    });
  }
}
