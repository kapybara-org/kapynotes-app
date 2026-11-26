// About & updates on a real phone, drawn for the build being shot: its version
// and build come from the pubspec, and what it brought from the site's
// changelog, the same file the app reads. Only the store's answer is faked,
// so the shots never depend on what either store sells today: this build,
// offered to a phone that runs it and to one on the release before it
// (1E0B-0).
//
//   flutter drive --driver test_driver/integration_test.dart \
//     --target integration_test/phone_about_test.dart -d <device> \
//     --dart-define=KAPYNOTES_SYNC=false
//
// The store's button is left alone: it leaves the app for the store.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/appearance.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/release_history.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/store_updates.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../test/support/store_updates.dart';
import 'rates_support.dart';
import 'screenshot.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'phone-about-integration.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late PackageInfo build;
  late List<ReleaseNote> releases;

  setUpAll(() async {
    build = await PackageInfo.fromPlatform();
    final history = ReleaseHistory(_MemoryStore());
    for (var attempt = 0; attempt < 3 && history.releases.isEmpty; attempt++) {
      if (attempt > 0) await Future<void>.delayed(const Duration(seconds: 2));
      await history.refresh();
    }
    releases = history.releases;
    history.dispose();
    if (releases.isEmpty) {
      fail(
        'phone_about_test could not fetch ${ReleaseHistory.url} in 3 tries. '
        "That's the network or the site, not the app: the About shots need "
        "the changelog for this build's notes.",
      );
    }
  });

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }

  for (final waiting in [false, true]) {
    final state = waiting ? 'update' : 'latest';
    testWidgets('About & updates, $state, dark', (tester) async {
      final version = build.version;
      final number = int.parse(build.buildNumber);
      final listed = releases.any(
        (release) => release.version == version && release.build == number,
      );
      if (!listed) {
        debugPrint(
          '${ReleaseHistory.url} lists no $version ($number) yet, so the '
          'About shots show no notes for it. Shoot them again once it does.',
        );
      }
      final before = releases.firstWhere(
        (release) => (compareVersions(release.version, version) ?? 0) < 0,
      );
      final store = _MemoryStore();
      store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
      final notes = NotesStore(store);
      final prefs = LayoutPrefs(store)..load();
      await notes.load();
      notes.create(body: 'Groceries\nOat milk, lemons');
      prefs.appearance = AppearanceMode.dark;
      final play = AppPlatform.isAndroid;
      if (waiting) {
        PackageInfo.setMockInitialValues(
          appName: build.appName,
          packageName: build.packageName,
          version: before.version,
          buildNumber: '${before.build ?? 0}',
          buildSignature: build.buildSignature,
        );
        addTearDown(
          () => PackageInfo.setMockInitialValues(
            appName: build.appName,
            packageName: build.packageName,
            version: build.version,
            buildNumber: build.buildNumber,
            buildSignature: build.buildSignature,
            installerStore: build.installerStore,
            installTime: build.installTime,
            updateTime: build.updateTime,
          ),
        );
      }

      await tester.pumpWidget(
        KapyNotesApp(
          store: store,
          notes: notes,
          rates: offlineRates(store),
          prefs: prefs,
          shortcuts: ShortcutPrefs(store)..load(),
          storeUpdates: fakeStoreUpdates(
            _MemoryStore(),
            installed: waiting ? before.version : version,
            build: waiting ? before.build ?? 0 : number,
            releases: [for (final release in releases) release.toJson()],
            answer: () async =>
                play ? StoreOffer(build: number) : StoreOffer(version: version),
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));
      final home = find.byKey(const ValueKey('page-home'));
      if (home.evaluate().isNotEmpty) {
        await tester.tap(home);
        await tester.pumpAndSettle();
      }

      await tap(tester, 'phone-account');
      final marked = find.descendant(
        of: find.byKey(const ValueKey('settings-section-about')),
        matching: find.text('Update available'),
      );
      expect(marked, waiting ? findsOneWidget : findsNothing);
      await screenshot('phone-about-$state-list');

      await tap(tester, 'settings-section-about');
      if (listed) {
        final note = releases.firstWhere(
          (release) => release.version == version && release.build == number,
        );
        expect(find.text(note.summary), findsOneWidget);
      }
      expect(
        find.text(
          !waiting
              ? 'Version $version'
              : listed || !play
              ? 'Version $version is out'
              : 'A new version is out',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('You have the latest version'),
        waiting ? findsNothing : findsOneWidget,
      );
      expect(
        find.text(play ? 'Update on Google Play' : 'Update on the App Store'),
        waiting ? findsOneWidget : findsNothing,
      );
      expect(tester.takeException(), isNull);
      await screenshot('phone-about-$state', device: true);

      await tap(tester, 'settings-sheet-back');
      expect(marked, findsNothing, reason: 'seen once it is opened');
    });
  }
}
