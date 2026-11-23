import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/store_updates.dart';
import 'package:kapy_notes/ui/settings_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'support/store_updates.dart';

class _Store extends LocalStore {
  _Store() : super(fileName: 'settings-store-updates-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

final _about = find.byKey(const ValueKey('settings-section-about'));
final _release = find.byKey(const ValueKey('changelog'));
final _storeButton = find.byKey(const ValueKey('store-update-open'));
final _allChanges = find.byKey(const ValueKey('store-release-all-changes'));

Finder _marked(String text) =>
    find.descendant(of: _about, matching: find.text(text));

/// Settings as a phone's sheet on [platform], running 1.35.4, with
/// [updates] for what its store says.
Future<void> _pump(
  WidgetTester tester,
  TargetPlatform platform,
  LocalStore store,
  StoreUpdates updates,
) async {
  AppPlatform.debugTargetPlatformOverride = platform;
  addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
  PackageInfo.setMockInitialValues(
    appName: 'Kapy Notes',
    packageName: StoreUpdates.bundleId,
    version: '1.35.4',
    buildNumber: '46',
    buildSignature: '',
  );
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final notes = NotesStore(store);
  await notes.load();
  await tester.pumpWidget(
    MaterialApp(
      theme: KapyTheme.dark(),
      home: Scaffold(
        body: SettingsDialog(
          layoutPrefs: LayoutPrefs(store)..load(),
          shortcuts: ShortcutPrefs(store)..load(),
          rates: RatesRepository(store),
          notes: notes,
          storeUpdates: updates,
          asSheet: true,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// Every link opened from here on, each opening or not as [opens] says.
List<String> _launches(bool Function(String url) opens) {
  final launched = <String>[];
  const channel = MethodChannel('plugins.flutter.io/url_launcher');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async {
    if (call.method != 'launch') return null;
    final url = (call.arguments as Map)['url'] as String;
    launched.add(url);
    return opens(url);
  });
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  return launched;
}

void main() {
  testWidgets('on iOS, an update in the App Store marks the list until About '
      '& updates is opened', (tester) async {
    final store = _Store();
    final updates = fakeStoreUpdates(
      store,
      releases: aboutReleases(),
      answer: () async =>
          const StoreOffer(version: '1.35.5', released: '2026-11-25T12:00:00Z'),
    );
    await _pump(tester, TargetPlatform.iOS, store, updates);
    expect(_marked('Update available'), findsOneWidget);

    await _tap(tester, _about);
    for (final text in [
      'Version 1.35.5 is out',
      '25 Nov 2026',
      'Swipe actions on notes, a Back that goes where you expect, and a '
          'calmer Home and Folders.',
      'Swipe a note on Home to pin or archive it.',
      'Update on the App Store',
      '1.35.4',
      '23 Nov 2026',
      'Installed',
      'Changelog',
    ]) {
      expect(find.text(text), findsOneWidget, reason: text);
    }
    expect(find.text('Folders open where you left them.'), findsNothing);
    expect(find.textContaining('latest version'), findsNothing);

    await _tap(tester, _allChanges);
    expect(find.text('Folders open where you left them.'), findsOneWidget);

    await _tap(tester, find.byKey(const ValueKey('settings-sheet-back')));
    expect(_marked('Update available'), findsNothing);
    expect(store.data['storeUpdate.seen.v1'], '1.35.5');
  });

  testWidgets('the App Store button opens the App Store, or its page on the '
      'web when that will not open', (tester) async {
    final store = _Store();
    final updates = fakeStoreUpdates(
      store,
      releases: aboutReleases(),
      answer: () async => const StoreOffer(version: '1.35.5'),
    );
    await _pump(tester, TargetPlatform.iOS, store, updates);
    await _tap(tester, _about);

    var opens = (String url) => url.startsWith('https:');
    final launched = _launches((url) => opens(url));
    await _tap(tester, _storeButton);
    expect(launched, [
      'itms-apps://apps.apple.com/app/id6807810082',
      'https://apps.apple.com/app/id6807810082',
    ]);
    expect(find.text('Could not open the App Store'), findsNothing);

    opens = (_) => false;
    launched.clear();
    await tester.tap(_storeButton);
    await tester.pump();
    await tester.pump();
    expect(launched, hasLength(2));
    expect(find.text('Could not open the App Store'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  });

  testWidgets('on Android, an update Google Play offers before the changelog '
      'names its build says a new version is out', (tester) async {
    final store = _Store();
    final updates = fakeStoreUpdates(
      store,
      releases: [aboutReleases().last],
      answer: () async => const StoreOffer(build: 47),
    );
    await _pump(tester, TargetPlatform.android, store, updates);
    expect(_marked('Update available'), findsOneWidget);

    await _tap(tester, _about);
    expect(find.text('A new version is out'), findsOneWidget);
    expect(find.text('Update on Google Play'), findsOneWidget);
    expect(find.textContaining('Swipe'), findsNothing);
    expect(_allChanges, findsNothing);
    expect(find.text('Installed'), findsOneWidget);

    final launched = _launches((_) => true);
    await _tap(tester, _storeButton);
    expect(launched, ['market://details?id=com.kapybara.kapynotes']);
  });

  testWidgets('on Android, the changelog finds what Google Play is offering '
      'by its build', (tester) async {
    final store = _Store();
    final updates = fakeStoreUpdates(
      store,
      releases: aboutReleases(),
      answer: () async => const StoreOffer(build: 47),
    );
    await _pump(tester, TargetPlatform.android, store, updates);
    await _tap(tester, _about);
    expect(find.text('Version 1.35.5 is out'), findsOneWidget);
    expect(find.text('25 Nov 2026'), findsOneWidget);
    expect(
      find.text('Swipe a note on Home to pin or archive it.'),
      findsOneWidget,
    );
    expect(find.text('Update on Google Play'), findsOneWidget);
  });

  testWidgets('the App Store notes stand in until the changelog has the '
      'version', (tester) async {
    final store = _Store();
    final updates = fakeStoreUpdates(
      store,
      releases: [aboutReleases().last],
      answer: () async => const StoreOffer(
        version: '1.35.5',
        notes:
            'Kapy Notes 1.35.5\n\n- Swipe a note to pin it.\n'
            '• Home puts your notes first.\n',
        released: '2026-11-25T12:00:00Z',
      ),
    );
    await _pump(tester, TargetPlatform.iOS, store, updates);
    await _tap(tester, _about);
    expect(find.text('Version 1.35.5 is out'), findsOneWidget);
    expect(find.text('25 Nov 2026'), findsOneWidget);
    expect(find.text('Swipe a note to pin it.'), findsOneWidget);
    expect(find.text('Home puts your notes first.'), findsOneWidget);
    expect(find.textContaining('Kapy Notes 1.35.5'), findsNothing);
    expect(_allChanges, findsNothing);
  });

  testWidgets('the latest version says so, and All changes opens the whole '
      'list in place', (tester) async {
    final store = _Store();
    final updates = fakeStoreUpdates(
      store,
      releases: aboutReleases(),
      answer: () async => const StoreOffer(version: '1.35.4'),
    );
    await _pump(tester, TargetPlatform.iOS, store, updates);
    expect(_marked('Update available'), findsNothing);

    await _tap(tester, _about);
    expect(
      find.descendant(of: _release, matching: find.text('Version 1.35.4')),
      findsOneWidget,
    );
    expect(
      find.text('23 Nov 2026 · You have the latest version'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Undo right after removing someone from a shared note takes it '
        'back, so they keep the note.',
      ),
      findsOneWidget,
    );
    expect(_storeButton, findsNothing);
    expect(find.text('Installed'), findsNothing);
    expect(find.byKey(const ValueKey('changelog-page')), findsOneWidget);

    const later = 'Tasks remember the folder they were made in.';
    expect(find.text(later), findsNothing);
    await _tap(tester, _allChanges);
    expect(find.text(later), findsOneWidget);
    await _tap(tester, _allChanges);
    expect(find.text(later), findsNothing);
  });

  for (final scale in [2.0, 2.35]) {
    testWidgets('an update lays out at ${scale}x text, its button words '
        'wrapping', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final store = _Store();
      final updates = fakeStoreUpdates(
        store,
        releases: aboutReleases(),
        answer: () async => const StoreOffer(version: '1.35.5'),
      );
      await _pump(tester, TargetPlatform.iOS, store, updates);
      await _tap(tester, _about);
      expect(tester.takeException(), isNull);
      expect(find.text('Update on the App Store'), findsOneWidget);
      await _tap(tester, _allChanges);
      expect(tester.takeException(), isNull);
    });
  }

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('on ${platform.name}, a store that did not answer claims '
        'neither an update nor the latest version', (tester) async {
      final store = _Store();
      final updates = fakeStoreUpdates(
        store,
        releases: aboutReleases(),
        answer: () async => throw const SocketException('offline'),
      );
      await _pump(tester, platform, store, updates);
      expect(_marked('Update available'), findsNothing);

      await _tap(tester, _about);
      expect(
        find.descendant(of: _release, matching: find.text('Version 1.35.4')),
        findsOneWidget,
      );
      expect(find.text('23 Nov 2026'), findsOneWidget);
      expect(find.textContaining('latest version'), findsNothing);
      expect(_storeButton, findsNothing);
    });
  }
}
