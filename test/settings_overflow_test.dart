import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/update_checker.dart';
import 'package:kapy_notes/data/voice_prefs.dart';
import 'package:kapy_notes/ui/settings_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Settings at the smallest windows the app allows: a layout overflow is a
/// yellow and black stripe on the screen, and the framework reports it as an
/// exception, so a window size at which nothing is reported is one where
/// nothing overflows.

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'settings-overflow-test.json') {
    data[Onboarding.storeKey] = Onboarding.welcomeRevision;
  }

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

Future<void> _open(
  WidgetTester tester, {
  required TargetPlatform platform,
  required Size size,
  SettingsSection? section,
}) async {
  AppPlatform.debugTargetPlatformOverride = platform;
  addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final store = _MemoryStore();
  final notes = NotesStore(store);
  await notes.load();
  final updates = UpdateChecker(
    store,
    client: MockClient((_) async => throw StateError('no network here')),
    packageInfo: PackageInfo(
      appName: 'Kapy Notes',
      packageName: 'com.kapybara.kapynotes',
      version: '1.0.0',
      buildNumber: '1',
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: KapyTheme.dark(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSettings(
              context,
              layoutPrefs: LayoutPrefs(store),
              shortcuts: ShortcutPrefs(store)..load(),
              rates: RatesRepository(store),
              notes: notes,
              voicePrefs: VoicePrefs(store)..load(),
              updates: platform == TargetPlatform.macOS ? updates : null,
              section: section,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// Collects every overflow the framework reports, each as how far it
/// overflowed and the line that built the widget.
class _Overflows {
  _Overflows() {
    addTearDown(() => FlutterError.onError = _original);
    _watch();
  }

  final _original = FlutterError.onError;
  final _found = <String>{};

  void _watch() {
    FlutterError.onError = (details) {
      final text = details.toString();
      if (!text.contains('overflowed by')) {
        FlutterError.presentError(details);
        return;
      }
      final amount = RegExp(
        r'overflowed by [\d.]+ pixels',
      ).firstMatch(text)![0];
      final site = RegExp(r'lib/[\w/]+\.dart:\d+:\d+').firstMatch(text)?[0];
      _found.add('$amount at $site');
    };
  }

  void expectNone([String? reason]) {
    FlutterError.onError = _original;
    expect(_found, isEmpty, reason: reason);
    _watch();
  }
}

void main() {
  final windows = {
    'an 880 by 640 window': const Size(880, 640),
    'the smallest window': LayoutPrefs.minimumWindowSize,
  };

  for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
    for (final MapEntry(key: name, value: size) in windows.entries) {
      testWidgets('on ${platform.name}, in $name, no section overflows', (
        tester,
      ) async {
        final overflows = _Overflows();
        for (final section in SettingsSection.values) {
          await _open(tester, platform: platform, size: size, section: section);
          await tester.tapAt(Offset.zero);
          await tester.pumpAndSettle();
          overflows.expectNone('${section.name} at $size');
        }
      });

      testWidgets('on ${platform.name}, in $name, search results and their '
          'hints do not overflow', (tester) async {
        final overflows = _Overflows();
        await _open(tester, platform: platform, size: size);
        await tester.enterText(
          find.byKey(const ValueKey('settings-search')),
          'a',
        );
        await tester.pumpAndSettle();
        overflows.expectNone();
      });
    }
  }

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('on ${platform.name}, the sheet fits the smallest phone', (
      tester,
    ) async {
      final overflows = _Overflows();
      for (final section in [null, ...SettingsSection.values]) {
        await _open(
          tester,
          platform: platform,
          size: const Size(320, 568),
          section: section,
        );
        overflows.expectNone('${section?.name}');
      }
    });
  }
}
