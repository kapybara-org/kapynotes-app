import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/ui/settings_dialog.dart';
import 'package:material_ui/material_ui.dart';

class MemoryFakeStore extends LocalStore {
  MemoryFakeStore() : super(fileName: 'settings-sheet-test.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
}

late MemoryFakeStore store;
late NotesStore notes;
late LayoutPrefs prefs;
late ShortcutPrefs shortcuts;

/// A phone-sized surface with nothing on it but the button that opens
/// settings, which is all any of this needs.
Future<void> _pumpPhone(
  WidgetTester tester, {
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

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
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openSettings(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _openCategory(WidgetTester tester, String name) async {
  await tester.tap(find.byKey(ValueKey('settings-section-$name')));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() async {
    // These tests run on a desktop host, so the phone has to be declared.
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    store = MemoryFakeStore();
    notes = NotesStore(store);
    await notes.load();
    prefs = LayoutPrefs(store)..load();
    shortcuts = ShortcutPrefs(store)..load();
  });

  testWidgets('opens on its categories rather than on every pane at once', (
    tester,
  ) async {
    await _pumpPhone(tester);
    await _openSettings(tester);

    expect(
      find.byKey(const ValueKey('settings-section-general')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('settings-section-appearance')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('settings-section-numbers')),
      findsOneWidget,
    );
    // Each category says what is behind it before it is opened.
    expect(find.text('Writing font and paper'), findsOneWidget);

    // Shortcuts belong to a keyboard, and phones are updated by their store.
    expect(
      find.byKey(const ValueKey('settings-section-shortcuts')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('settings-section-updates')),
      findsNothing,
    );

    // The whole point of the list: none of the panes are on this screen.
    expect(find.text('Daily separators'), findsNothing);
    expect(find.text('NUMBER FORMAT'), findsNothing);
  });

  testWidgets('pushes one category and comes back to the list', (tester) async {
    await _pumpPhone(tester);
    await _openSettings(tester);
    await _openCategory(tester, 'appearance');

    // The title says where you are, and only that category is here.
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('WRITING FONT'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-section-numbers')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('settings-sheet-back')));
    await tester.pumpAndSettle();

    expect(find.text('WRITING FONT'), findsNothing);
    expect(
      find.byKey(const ValueKey('settings-section-numbers')),
      findsOneWidget,
    );
  });

  testWidgets('a switch inside a pushed category still changes the setting', (
    tester,
  ) async {
    await _pumpPhone(tester);
    await _openSettings(tester);
    await _openCategory(tester, 'general');

    expect(prefs.dailySeparatorsEnabled, isTrue);
    await tester.tap(find.byKey(const ValueKey('daily-separators-toggle')));
    await tester.pumpAndSettle();

    expect(prefs.dailySeparatorsEnabled, isFalse);
  });

  testWidgets('the back gesture leaves the category before the sheet', (
    tester,
  ) async {
    await _pumpPhone(tester);
    await _openSettings(tester);
    await _openCategory(tester, 'numbers');

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('settings-section-numbers')),
      findsOneWidget,
      reason: 'the first back is out of the category, not out of settings',
    );

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('settings-section-numbers')),
      findsNothing,
    );
  });

  testWidgets('Done closes the whole sheet from inside a category', (
    tester,
  ) async {
    await _pumpPhone(tester);
    await _openSettings(tester);
    await _openCategory(tester, 'general');

    await tester.tap(find.byKey(const ValueKey('settings-sheet-done')));
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsNothing);
    expect(
      find.byKey(const ValueKey('settings-section-general')),
      findsNothing,
    );
  });

  testWidgets('gives every row a thumb to aim at', (tester) async {
    await _pumpPhone(tester);
    await _openSettings(tester);

    // The list itself first.
    expect(
      tester
          .getSize(find.byKey(const ValueKey('settings-section-general')))
          .height,
      greaterThanOrEqualTo(44),
    );

    await _openCategory(tester, 'general');
    for (final key in ['daily-separators-toggle', 'export-notes']) {
      expect(
        tester.getSize(find.byKey(ValueKey(key))).height,
        greaterThanOrEqualTo(44),
        reason: '$key is smaller than a fingertip',
      );
    }
  });

  testWidgets('lifts clear of the keyboard rather than sitting under it', (
    tester,
  ) async {
    await _pumpPhone(tester);
    await _openSettings(tester);

    final sheet = find.byKey(const ValueKey('settings-sheet'));
    expect(tester.getRect(sheet).bottom, closeTo(844, 0.5));
    final top = tester.getRect(sheet).top;

    // Signing in happens in here, so a keyboard is not a hypothetical.
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();

    final lifted = tester.getRect(sheet);
    expect(lifted.bottom, closeTo(544, 0.5));
    expect(
      lifted.top,
      closeTo(top, 0.5),
      reason: 'the sheet shortens from the bottom; its top edge stays put',
    );
  });

  testWidgets('a pointer still gets the rail dialog, however narrow', (
    tester,
  ) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
    // Narrower than the rail breakpoint: what decides the shape is the input,
    // not the width, so a shrunk desktop window keeps its dialog.
    await _pumpPhone(tester, size: const Size(560, 720));
    await _openSettings(tester);

    expect(find.byType(AlertDialog), findsOneWidget);
    // The dialog shows a pane outright; there is no list to push through.
    expect(find.text('Daily separators'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-sheet-done')), findsNothing);
  });
}
