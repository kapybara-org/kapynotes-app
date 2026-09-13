import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/update_checker.dart';
import 'package:kapy_notes/data/voice_prefs.dart';
import 'package:kapy_notes/ui/settings_dialog.dart';
import 'package:kapy_notes/ui/settings_search.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Finding a setting by typing its name — or any of the other words people
/// use for it — and landing on its row.

class SearchTestStore extends LocalStore {
  SearchTestStore() : super(fileName: 'settings-search-test.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
}

late SearchTestStore store;
late NotesStore notes;
late LayoutPrefs prefs;
late ShortcutPrefs shortcuts;

/// Settings as a desktop or a phone opens it, from a button, with every
/// category this build can have: voice notes and updates included.
Future<void> _open(
  WidgetTester tester, {
  required TargetPlatform platform,
  Size size = const Size(1000, 800),
  SettingsSection? section,
}) async {
  AppPlatform.debugTargetPlatformOverride = platform;
  addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  store.put('updates.v1', {
    'available': null,
    'checkedAt': DateTime.now().toIso8601String(),
  });
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
              layoutPrefs: prefs,
              shortcuts: shortcuts,
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

Finder get _field => find.byKey(const ValueKey('settings-search'));

Future<void> _type(WidgetTester tester, String query) async {
  await tester.enterText(_field, query);
  await tester.pumpAndSettle();
}

Finder _result(String target) =>
    find.byKey(ValueKey('settings-search-result-$target'));

/// Every result row on screen, as the key of the setting it leads to.
List<String> _resultTargets(WidgetTester tester) => [
  for (final element
      in find
          .byWidgetPredicate(
            (widget) =>
                widget.key is ValueKey<String> &&
                (widget.key! as ValueKey<String>).value.startsWith(
                  'settings-search-result-',
                ),
          )
          .evaluate())
    (element.widget.key! as ValueKey<String>).value.substring(
      'settings-search-result-'.length,
    ),
];

/// Whether [finder]'s widget sits inside the visible part of the pane — on
/// screen, not merely built somewhere below the fold.
bool _onScreen(WidgetTester tester, Finder finder) {
  final rect = tester.getRect(finder);
  final dialog = tester.getRect(find.byType(AlertDialog));
  return rect.top >= dialog.top && rect.bottom <= dialog.bottom;
}

SettingsSearchEntry<String> _entry(
  String title, {
  String section = 'General',
  String? group,
  List<String> keywords = const [],
  String? description,
}) => SettingsSearchEntry(
  section: section,
  sectionLabel: section,
  title: title,
  icon: KapyIcons.settingsOutlined,
  target: title.toLowerCase(),
  group: group,
  keywords: keywords,
  description: description,
);

void main() {
  setUp(() async {
    store = SearchTestStore();
    notes = NotesStore(store);
    await notes.load();
    prefs = LayoutPrefs(store)..load();
    shortcuts = ShortcutPrefs(store)..load();
  });

  group('the match', () {
    final entries = [
      _entry('Theme', section: 'Appearance', keywords: ['dark mode']),
      _entry(
        'Check spelling',
        group: 'Writing',
        description: 'Underline possible misspellings',
      ),
      _entry('Time zone', group: 'Writing', keywords: ['clock']),
      _entry('Panel widths', group: 'Window', keywords: ['reset', 'resize']),
      _entry('Paper', section: 'Appearance', keywords: ['ruled']),
    ];
    List<String> titles(String query) => [
      for (final entry in searchSettings(entries, query)) entry.title,
    ];

    test('finds a setting by the word people use for it', () {
      expect(titles('dark'), ['Theme']);
      expect(titles('Dark Mode'), ['Theme']);
      expect(titles('ruled'), ['Paper']);
    });

    test('ranks a title above a heading, and a heading above small print', () {
      expect(titles('writing').first, 'Check spelling');
      expect(titles('spel'), ['Check spelling']);
      expect(titles('time'), ['Time zone']);
    });

    test('needs every word typed, so a second word narrows', () {
      expect(titles('reset'), ['Panel widths']);
      expect(titles('reset spelling'), isEmpty);
      expect(titles('appearance'), ['Theme', 'Paper']);
      expect(titles('appearance ruled'), ['Paper']);
    });

    test('only trusts the middle of a word from three letters on', () {
      // "ark" is inside "dark"; "ar" is inside too much to mean anything.
      expect(titles('ark'), ['Theme']);
      expect(titles('ar'), isEmpty);
      expect(titles('misspell'), ['Check spelling']);
    });

    test('ignores case, punctuation and an empty query', () {
      expect(titles('  '), isEmpty);
      expect(titles('TIME-ZONE'), ['Time zone']);
    });

    test('says where a result lives, and what a category holds', () {
      expect(entries[1].place, 'General · Writing');
      expect(
        _entry('Theme', section: 'Appearance', group: 'Theme').place,
        'Appearance',
      );
      const category = SettingsSearchEntry(
        section: 'Appearance',
        sectionLabel: 'Appearance',
        title: 'Appearance',
        icon: KapyIcons.settingsOutlined,
        description: 'Theme, writing font, paper',
      );
      expect(category.place, 'Theme, writing font, paper');
    });
  });

  group('on a desktop', () {
    testWidgets('uses a compact search glyph', (tester) async {
      await _open(tester, platform: TargetPlatform.macOS);

      final icon = tester.widget<KapyIcon>(
        find.descendant(
          of: _field,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is KapyIcon && widget.icon == KapyIcons.searchRounded,
          ),
        ),
      );
      expect(icon.size, AppControlMetrics.iconAdornment - 2);
    });

    testWidgets('is waiting in the field when settings opens, and Return '
        'goes to the best match', (tester) async {
      await _open(tester, platform: TargetPlatform.macOS);
      final field = tester.widget<TextField>(_field);
      expect(field.focusNode!.hasFocus, isTrue);

      await _type(tester, 'dark');
      expect(_resultTargets(tester).first, 'theme-setting');
      // Where it lives, without repeating a heading that shares its name.
      expect(
        find.descendant(
          of: _result('theme-setting'),
          matching: find.text('Appearance'),
        ),
        findsOneWidget,
      );

      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      // The pane it belongs to, scrolled to it, and the search let go.
      expect(find.byKey(const ValueKey('theme-setting')), findsOneWidget);
      expect(
        _onScreen(tester, find.byKey(const ValueKey('theme-setting'))),
        isTrue,
      );
      expect(find.text('WRITING FONT'), findsOneWidget);
      expect(tester.widget<TextField>(_field).controller!.text, isEmpty);
    });

    testWidgets('lights the row it lands on for a moment', (tester) async {
      await _open(tester, platform: TargetPlatform.macOS);
      await _type(tester, 'shortcut defaults');
      await tester.tap(_result('restore-shortcut-defaults'));
      await tester.pump();

      // The scroll to it first, then the light.
      final light = tester.renderObject(find.byType(SettingsFlashLayer));
      var lit = false;
      for (var frame = 0; frame < 20 && !lit; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
        lit = ((paints..rrect()) as Matcher).matches(light, {});
      }
      expect(lit, isTrue, reason: 'the row it led to was never lit');
      await tester.pumpAndSettle();
      expect(light, isNot(paints..rrect()));
      expect(
        _onScreen(
          tester,
          find.byKey(const ValueKey('restore-shortcut-defaults')),
        ),
        isTrue,
        reason: 'the last row of a long pane, scrolled into view',
      );
    });

    testWidgets('Escape empties the field before it closes anything', (
      tester,
    ) async {
      await _open(tester, platform: TargetPlatform.macOS);
      await _type(tester, 'font');
      expect(
        find.byKey(const ValueKey('settings-search-results')),
        findsOneWidget,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(_field).controller!.text, isEmpty);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.byKey(const ValueKey('settings-search-results')),
        findsNothing,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('says so when nothing matches', (tester) async {
      await _open(tester, platform: TargetPlatform.macOS);
      await _type(tester, 'xylophone');
      expect(
        find.byKey(const ValueKey('settings-search-empty')),
        findsOneWidget,
      );
      expect(find.textContaining('No settings match'), findsOneWidget);
    });

    testWidgets('a category from the rail takes over from the results', (
      tester,
    ) async {
      await _open(tester, platform: TargetPlatform.macOS);
      await _type(tester, 'export');
      await tester.tap(
        find.byKey(const ValueKey('settings-section-shortcuts')),
      );
      await tester.pumpAndSettle();

      expect(tester.widget<TextField>(_field).controller!.text, isEmpty);
      expect(find.text('SYSTEM-WIDE'), findsOneWidget);
    });

    testWidgets('⌘F goes back to the field from anywhere in settings', (
      tester,
    ) async {
      await _open(tester, platform: TargetPlatform.macOS);
      final focus = tester.widget<TextField>(_field).focusNode!;
      focus.unfocus();
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isFalse);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isTrue);
    });

    testWidgets('leaves the keyboard alone when sent to one pane', (
      tester,
    ) async {
      await _open(
        tester,
        platform: TargetPlatform.macOS,
        section: SettingsSection.voice,
      );
      expect(tester.widget<TextField>(_field).focusNode!.hasFocus, isFalse);
    });

    testWidgets('every setting a search offers is really there', (
      tester,
    ) async {
      await _open(tester, platform: TargetPlatform.macOS);
      // Each category's name finds everything filed under it; each result
      // is then looked up again by the title it shows, the way a person
      // would, and followed.
      final titles = <String, String>{};
      for (final section in [
        'General',
        'Appearance',
        'Voice notes',
        'Shortcuts',
        'Updates',
      ]) {
        await _type(tester, section);
        for (final target in _resultTargets(tester)) {
          if (target.startsWith('section-')) continue;
          titles[target] = tester
              .widget<Text>(
                find
                    .descendant(
                      of: _result(target),
                      matching: find.byType(Text),
                    )
                    .first,
              )
              .data!;
        }
      }
      expect(titles.length, greaterThan(40));

      for (final MapEntry(key: target, value: title) in titles.entries) {
        await _type(tester, title);
        expect(
          _result(target),
          findsOneWidget,
          reason: 'searching "$title" does not find it again',
        );
        await tester.tap(_result(target));
        await tester.pumpAndSettle();
        expect(
          find.byKey(ValueKey(target)),
          findsOneWidget,
          reason: '"$target" is offered by search but not drawn',
        );
        expect(
          _onScreen(tester, find.byKey(ValueKey(target))),
          isTrue,
          reason: '"$target" was not scrolled into view',
        );
      }
    });
  });

  group('on a phone', () {
    testWidgets('searches from the list of categories, and back returns to '
        'the results', (tester) async {
      await _open(
        tester,
        platform: TargetPlatform.iOS,
        size: const Size(390, 844),
      );
      // A keyboard that rose on its own would cover the list it searches.
      expect(tester.widget<TextField>(_field).focusNode!.hasFocus, isFalse);

      await _type(tester, 'spell');
      expect(
        find.byKey(const ValueKey('settings-section-general')),
        findsNothing,
      );
      await tester.tap(_result('spell-check-toggle'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('spell-check-toggle')), findsOneWidget);
      expect(find.text('General'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('settings-sheet-back')));
      await tester.pumpAndSettle();
      expect(_result('spell-check-toggle'), findsOneWidget);
    });

    testWidgets('offers nothing a phone does not have', (tester) async {
      await _open(
        tester,
        platform: TargetPlatform.iOS,
        size: const Size(390, 844),
      );
      await _type(tester, 'shortcut');
      expect(
        _resultTargets(tester).where((t) => t.startsWith('shortcut-row-')),
        isEmpty,
      );
      await _type(tester, 'menu bar');
      expect(_result('keep-running-toggle'), findsNothing);
    });
  });
}
