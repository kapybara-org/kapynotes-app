import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/appearance.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/ui/settings_dialog.dart';
import 'package:kapy_notes/ui/settings_rows.dart';
import 'package:kapy_notes/ui/theme_cards.dart';
import 'package:material_ui/material_ui.dart';

class _Store extends LocalStore {
  _Store() : super(fileName: 'settings-appearance-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;

  @override
  void putNow(String key, Object? value) => data[key] = value;
}

void main() {
  Future<LayoutPrefs> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1100, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = _Store();
    final notes = NotesStore(store);
    await notes.load();
    final prefs = LayoutPrefs(store)..load();
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Scaffold(
          body: SettingsDialog(
            layoutPrefs: prefs,
            shortcuts: ShortcutPrefs(store)..load(),
            rates: RatesRepository(store),
            notes: notes,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return prefs;
  }

  testWidgets('the dialog closes with a round button, and groups its rail', (
    tester,
  ) async {
    await open(tester);

    expect(find.text('Done'), findsNothing);
    expect(find.text('esc'), findsNothing);
    expect(find.text('Follow your computer, or choose one.'), findsNothing);
    expect(find.byTooltip('Close'), findsOneWidget);
    expect(find.text('General'), findsOneWidget);
    // No account and no updater in this harness, so that group has nothing
    // to list and stays out.
    expect(find.text('Account'), findsNothing);
    expect(find.text('Paper and text'), findsOneWidget);
    expect(find.text('PAPER AND TEXT'), findsNothing);
    expect(find.text('Changed from default'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('settings-done')));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsDialog), findsNothing);
  });

  testWidgets('Appearance shows mode windows, theme swatches and a capsule', (
    tester,
  ) async {
    final prefs = await open(tester);

    expect(find.byType(AppearanceModes), findsOneWidget);
    expect(find.byType(ThemeSwatches), findsOneWidget);
    expect(find.text('Riverbank'), findsWidgets);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('increase-contrast-setting')),
        matching: find.byWidgetPredicate(
          (widget) => widget is KapyIcon && widget.icon == KapyIcons.visibilityOutlined,
        ),
      ),
      findsOneWidget,
    );

    final indicator = find.byKey(const ValueKey('compact-switch-indicator'));
    expect(tester.getSize(indicator.first), const Size(36, 16));

    await tester.tap(find.byKey(const ValueKey('night-theme-setting')));
    await tester.pumpAndSettle();
    expect(prefs.nightTheme.enabled, isTrue);
    expect(find.byKey(const ValueKey('night-theme-button')), findsOneWidget);
    final night = tester.widget<SettingsRow>(
      find.descendant(
        of: find.byKey(const ValueKey('night-theme-choice-setting')),
        matching: find.byType(SettingsRow),
      ),
    );
    expect(night.icon, isNull);
    expect(night.iconSlot, isTrue);

    await tester.tap(find.byKey(const ValueKey('appearance-dark')));
    await tester.pumpAndSettle();
    expect(prefs.appearance, AppearanceMode.dark);
  });
}
