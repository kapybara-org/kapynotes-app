import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/ui/app_logo.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/editor/results_gutter.dart';
import 'package:kapy_notes/ui/empty_state.dart';
import 'package:kapy_notes/core/window_chrome.dart';
import 'package:kapy_notes/ui/settings_dialog.dart';
import 'package:kapy_notes/ui/sidebar.dart';
import 'package:kapy_notes/ui/toolbar.dart';

import 'test_fonts.dart';

/// A store that never touches the filesystem, so tests stay hermetic.
class MemoryStore extends LocalStore {
  MemoryStore() : super(fileName: 'test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  /// Writes straight through: no debounce timer to outlive the test.
  @override
  void put(String key, Object? value) => data[key] = value;
}

class DeferredMemoryStore extends MemoryStore {
  final Completer<void> _loadCompleter = Completer<void>();

  @override
  Future<void> load() => _loadCompleter.future;

  void completeLoad() => _loadCompleter.complete();
}

late MemoryStore store;
late NotesStore notes;
late LayoutPrefs prefs;
late RatesRepository rates;
late ShortcutPrefs shortcuts;

Future<void> pumpApp(
  WidgetTester tester, {
  Size size = const Size(1100, 760),
}) async {
  tester.view.physicalSize = size * tester.view.devicePixelRatio;
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);

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
}

/// Opens settings from the note footer and selects [section].
Future<void> openSettings(
  WidgetTester tester, {
  SettingsSection section = SettingsSection.general,
}) async {
  await tester.tap(find.byTooltip('Settings'));
  await tester.pumpAndSettle();
  if (section == SettingsSection.general) return;
  await tester.tap(find.byKey(ValueKey('settings-section-${section.name}')));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadTestFonts);

  setUp(() {
    store = MemoryStore();
    notes = NotesStore(store);
    prefs = LayoutPrefs(store);
    rates = RatesRepository(store);
    shortcuts = ShortcutPrefs(store);
  });

  testWidgets(
    'is ready to type before storage loads and preserves the launch text',
    (tester) async {
      final deferredStore = DeferredMemoryStore();
      final deferredNotes = NotesStore(deferredStore);
      final deferredPrefs = LayoutPrefs(deferredStore);
      final deferredRates = RatesRepository(deferredStore);
      final deferredShortcuts = ShortcutPrefs(deferredStore);

      await tester.pumpWidget(
        KapyNotesApp(
          store: deferredStore,
          notes: deferredNotes,
          rates: deferredRates,
          prefs: deferredPrefs,
          shortcuts: deferredShortcuts,
        ),
      );
      await tester.pump();

      final launchEditor = find.byKey(const ValueKey('instant-capture-editor'));
      expect(launchEditor, findsOneWidget);
      final editable = tester.widget<EditableText>(launchEditor);
      expect(editable.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);

      await tester.enterText(launchEditor, 'Call the dentist at 9');
      deferredStore.completeLoad();
      await tester.pumpAndSettle();

      expect(deferredNotes.notes, hasLength(1));
      expect(deferredNotes.notes.single.body, 'Call the dentist at 9');
      final hydratedEditor = tester.widget<TextField>(
        find.descendant(
          of: find.byType(NoteEditor),
          matching: find.byType(TextField),
        ),
      );
      expect(hydratedEditor.controller!.text, 'Call the dentist at 9\n\n');
      expect(hydratedEditor.focusNode!.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
    },
  );

  testWidgets('opens on the empty state and builds a note from it', (
    tester,
  ) async {
    await pumpApp(tester);

    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.byKey(const ValueKey('toolbar-app-wordmark')), findsOneWidget);
    expect(find.text('No notes yet'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'New Note'));
    await tester.pumpAndSettle();

    expect(find.byType(EmptyState), findsNothing);
    expect(find.byType(NoteEditor), findsOneWidget);
    expect(notes.notes, hasLength(1));
  });

  testWidgets('keeps exchange-rate status out of the toolbar', (tester) async {
    await pumpApp(tester);

    final toolbar = find.byType(NoteToolbar);
    final wordmark = find.byKey(const ValueKey('toolbar-app-wordmark'));
    final add = find.byIcon(Icons.add_rounded).first;
    final menu = find.byIcon(Icons.menu_rounded);

    expect(toolbar, findsOneWidget);
    expect(find.textContaining('Rates'), findsNothing);
    expect(
      find.descendant(of: toolbar, matching: find.text(AppWordmark.name)),
      findsOneWidget,
    );
    expect(
      tester.getCenter(wordmark).dx,
      closeTo(tester.getCenter(toolbar).dx, 0.5),
    );
    expect(tester.getCenter(add).dx, lessThan(tester.getCenter(menu).dx));
    expect(
      find.descendant(
        of: toolbar,
        matching: find.byIcon(Icons.more_horiz_rounded),
      ),
      findsNothing,
    );
  });

  testWidgets('uses compact icon surfaces and note rows on desktop', (
    tester,
  ) async {
    await pumpApp(tester);
    notes.create();
    await tester.pumpAndSettle();

    final toolbar = find.byType(NoteToolbar);
    Finder toolbarButton(IconData icon) => find
        .ancestor(
          of: find.descendant(of: toolbar, matching: find.byIcon(icon)),
          matching: find.byType(IconButton),
        )
        .first;

    expect(
      tester.getSize(toolbarButton(Icons.add_rounded)),
      const Size.square(24),
    );
    expect(
      tester.getSize(toolbarButton(Icons.menu_rounded)),
      const Size.square(24),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('note-settings'))),
      const Size.square(24),
    );

    final noteRow = find.byType(NoteRow).first;
    expect(tester.getSize(noteRow).height, 54);
    expect(
      tester
          .getSize(
            find
                .descendant(
                  of: noteRow,
                  matching: find.byType(AnimatedContainer),
                )
                .first,
          )
          .height,
      52,
    );
  });

  testWidgets('types into a note, calculates, and derives its title', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'New Note'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(EditableText).last,
      'Weekend budget\ndinner = 64\ndinner * 3',
    );
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ResultChip, '192'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('note-total')))
          .textSpan!
          .toPlainText(),
      'Total: 256',
    );
    expect(find.byTooltip('Settings'), findsOneWidget);
    // Note identity stays in the note list instead of being repeated in the
    // app-level toolbar.
    expect(notes.notes.single.title, 'Weekend budget');
    expect(find.widgetWithText(NoteRow, 'Weekend budget'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(NoteToolbar),
        matching: find.text('Weekend budget'),
      ),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('toolbar-app-wordmark')), findsOneWidget);
  });

  testWidgets('opens footer settings and resets desktop panel widths', (
    tester,
  ) async {
    store.data['gutter.v1'] = 320.0;
    store.data['sidebar.v1'] = 360.0;
    await pumpApp(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'New Note'));
    await tester.pumpAndSettle();

    await openSettings(tester);

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Desktop sidebar'), findsOneWidget);
    final dailyToggle = find.byKey(const ValueKey('daily-separators-toggle'));
    final compactSwitch = find.descendant(
      of: dailyToggle,
      matching: find.byKey(const ValueKey('compact-switch-indicator')),
    );
    expect(prefs.dailySeparatorsEnabled, isTrue);
    expect(tester.getSize(compactSwitch), const Size(34, 18));

    await tester.tap(find.byKey(const ValueKey('sidebar-toggle')));
    await tester.pumpAndSettle();
    expect(prefs.sidebarVisible, isFalse);

    final reset = find.text('Reset panel widths');
    await tester.ensureVisible(reset);
    await tester.tap(reset);
    await tester.pumpAndSettle();
    expect(prefs.gutterWidth, LayoutPrefs.defaultGutterWidth);
    expect(prefs.sidebarWidth, LayoutPrefs.defaultSidebarWidth);
  });

  testWidgets('selects and persists the note time zone from settings', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'New Note'));
    await tester.pumpAndSettle();
    await openSettings(tester);

    final setting = find.byKey(const ValueKey('time-zone-setting'));
    await tester.ensureVisible(setting);
    expect(find.text('System time zone'), findsOneWidget);
    await tester.tap(setting);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('time-zone-search')),
      'Kolkata',
    );
    await tester.pumpAndSettle();
    final kolkata = find.byKey(const ValueKey('time-zone-option-Asia/Kolkata'));
    expect(kolkata, findsOneWidget);
    await tester.tap(kolkata);
    await tester.pumpAndSettle();

    expect(prefs.timeZoneId, 'Asia/Kolkata');
    expect(find.text('Asia/Kolkata'), findsOneWidget);
    expect(find.text('New separators · UTC+05:30'), findsOneWidget);
    expect((LayoutPrefs(store)..load()).timeZoneId, 'Asia/Kolkata');
  });

  testWidgets('credits and links the provider of the active rate snapshot', (
    tester,
  ) async {
    expect(RateProvider.frankfurter.attributionLabel, 'Rates by Frankfurter');
    expect(
      RateProvider.frankfurter.attributionUrl.toString(),
      'https://frankfurter.dev',
    );
    // Keep the fallback's required exact credit pinned as well.
    expect(
      RateProvider.exchangeRateApi.attributionLabel,
      'Rates By Exchange Rate API',
    );
    expect(
      RateProvider.exchangeRateApi.attributionUrl.toString(),
      'https://www.exchangerate-api.com',
    );

    final launched = <String>[];
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      final url = (call.arguments as Map?)?['url'];
      if (url is String) launched.add(url);
      return true;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );

    store.data['rates.v1'] = RateSnapshot(
      base: 'USD',
      date: '01 Sep 2026',
      fetchedAt: DateTime(2026, 9, 1, 12),
      rates: const {'EUR': 0.86},
      provider: RateProvider.frankfurter,
    ).toJson();

    await pumpApp(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'New Note'));
    await tester.pumpAndSettle();
    await openSettings(tester, section: SettingsSection.numbers);

    final credit = find.byKey(const ValueKey('rate-attribution'));
    expect(find.text('Rates by Frankfurter'), findsOneWidget);
    expect(find.text('Currency rates refreshed 01 Sep 2026'), findsOneWidget);

    await tester.ensureVisible(credit);
    await tester.tap(credit);
    await tester.pumpAndSettle();

    expect(launched, ['https://frankfurter.dev']);
  });

  testWidgets('switches the number system and reformats live', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'New Note'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).last, 'rev = 7000000');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ResultChip, '7,000,000'), findsOneWidget);

    await openSettings(tester, section: SettingsSection.numbers);
    expect(find.text('1,23,45,678'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('number-system-indian')));
    await tester.pumpAndSettle();
    expect(prefs.numberSystem, NumberSystem.indian);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    // The open note re-evaluates against the new engine without being touched.
    expect(find.widgetWithText(ResultChip, '70,00,000'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('note-total')))
          .textSpan!
          .toPlainText(),
      'Total: 70,00,000',
    );
  });

  testWidgets('changes the writing font live and persists it', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'New Note'));
    await tester.pumpAndSettle();

    TextField editor() => tester.widget<TextField>(
      find.descendant(
        of: find.byType(NoteEditor),
        matching: find.byType(TextField),
      ),
    );

    expect(prefs.writingFont, WritingFont.handwritten);
    expect(editor().style?.fontFamily, 'Kalam');

    await openSettings(tester, section: SettingsSection.appearance);
    expect(find.text('WRITING FONT'), findsOneWidget);
    for (final font in WritingFont.values) {
      expect(find.byKey(ValueKey('writing-font-${font.name}')), findsOneWidget);
    }

    await tester.tap(find.byKey(const ValueKey('writing-font-monospace')));
    await tester.pumpAndSettle();
    expect(prefs.writingFont, WritingFont.monospace);
    expect(editor().style?.fontFamily, WritingFont.monospace.fontFamily);

    final restored = LayoutPrefs(store)..load();
    expect(restored.writingFont, WritingFont.monospace);
  });

  testWidgets('shows and records every editable desktop shortcut', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'New Note'));
    await tester.pumpAndSettle();
    await openSettings(tester, section: SettingsSection.shortcuts);

    expect(find.text('FORMATTING'), findsOneWidget);
    expect(find.text('APP'), findsOneWidget);
    // The rail shows one pane at a time, so the general options are gone.
    expect(find.text('Daily separators'), findsNothing);
    for (final action in ShortcutAction.values) {
      expect(find.text(action.label), findsWidgets);
    }

    final findButton = find.byKey(const ValueKey('shortcut-findNotes'));
    await tester.ensureVisible(findButton);
    await tester.tap(findButton);
    await tester.pumpAndSettle();
    expect(find.text('Press your new shortcut'), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    final recorded = shortcuts.bindingFor(ShortcutAction.findNotes);
    expect(recorded.logicalKey, LogicalKeyboardKey.keyP);
    expect(recorded.meta, isTrue);
    expect(recorded.shift, isTrue);
  });

  testWidgets('searches note bodies and shows the matching line', (
    tester,
  ) async {
    await pumpApp(tester);
    notes.create();
    notes.updateBody(notes.notes.first.id, 'Groceries\nolive oil 12.50');
    notes.create();
    notes.updateBody(notes.notes.first.id, 'Car\ntyres 240');
    await tester.pumpAndSettle();

    expect(find.byType(NoteRow), findsNWidgets(2));

    await tester.enterText(find.byType(EditableText).first, 'olive');
    await tester.pumpAndSettle();

    expect(find.byType(NoteRow), findsOneWidget);
    // Search temporarily replaces the updated timestamp with the matching
    // line, so a body-only result still explains why it appeared.
    expect(find.widgetWithText(NoteRow, 'olive oil 12.50'), findsOneWidget);
  });

  testWidgets('shows updated times and keeps the latest note at the top', (
    tester,
  ) async {
    final olderAt = DateTime.utc(2026, 9, 1, 12);
    final latestAt = DateTime.utc(2026, 9, 2, 8, 5);
    final editedAt = DateTime.utc(2026, 9, 3, 9, 10);
    store.data['timeZone.v1'] = 'UTC';
    store.data['notes.v1'] = [
      {
        'id': 'older',
        'body': 'Older\nolder details',
        'createdAt': olderAt.millisecondsSinceEpoch,
        'updatedAt': olderAt.millisecondsSinceEpoch,
      },
      {
        'id': 'latest',
        'body': 'Latest\nlatest details',
        'createdAt': latestAt.millisecondsSinceEpoch,
        'updatedAt': latestAt.millisecondsSinceEpoch,
      },
    ];
    notes = NotesStore(store, now: () => editedAt);

    await pumpApp(tester);

    List<String> rowTitles() => tester
        .widgetList<NoteRow>(find.byType(NoteRow))
        .map((row) => row.note.title)
        .toList();
    expect(rowTitles(), ['Latest', 'Older']);
    expect(find.text('2 Sep 2026 · 08:05'), findsOneWidget);
    expect(find.text('1 Sep 2026 · 12:00'), findsOneWidget);
    expect(find.widgetWithText(NoteRow, 'latest details'), findsNothing);

    await tester.tap(find.widgetWithText(NoteRow, 'Older'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(EditableText).last,
      'Older\nchanged details',
    );
    await tester.pumpAndSettle();

    expect(rowTitles(), ['Older', 'Latest']);
    expect(notes.notes.map((note) => note.id), ['older', 'latest']);
    expect(find.text('3 Sep 2026 · 09:10'), findsOneWidget);
  });

  testWidgets('deletes a note and selects its neighbour', (tester) async {
    await pumpApp(tester);
    for (final body in ['First', 'Second', 'Third']) {
      notes.create();
      notes.updateBody(notes.notes.first.id, body);
    }
    await tester.pumpAndSettle();

    // Notes are newest-first; pick the top one, then delete it.
    await tester.tap(find.widgetWithText(NoteRow, 'Third'));
    await tester.pumpAndSettle();

    final third = notes.notes.singleWhere((note) => note.title == 'Third');
    await tester.tap(find.byKey(ValueKey('delete-note-${third.id}')));
    await tester.pumpAndSettle();

    expect(notes.notes.map((n) => n.title), ['Second', 'First']);
    expect(find.widgetWithText(NoteRow, 'Third'), findsNothing);
    expect(find.byType(NoteEditor), findsOneWidget);
  });

  group('compact editor', () {
    testWidgets(
      'opens the last edited note with the caret and focus at its end',
      (tester) async {
        store.data['notes.v1'] = [
          {
            'id': 'created-last',
            'body': 'Created last\n2 + 2',
            'createdAt': 3000,
            'updatedAt': 3000,
          },
          {
            'id': 'edited-last',
            'body': 'Edited last\nfirst line\nfinal line',
            'createdAt': 1000,
            'updatedAt': 5000,
          },
        ];
        // Compact startup follows edit recency, not the previously selected id.
        store.data['selectedNote.v1'] = 'created-last';

        await pumpApp(tester, size: const Size(420, 800));

        expect(find.byType(NoteEditor), findsOneWidget);
        expect(
          find.byKey(const ValueKey('toolbar-app-wordmark')),
          findsOneWidget,
        );
        expect(find.text('Edited last'), findsNothing);
        expect(find.byType(NoteRow), findsNothing);

        final field = tester.widget<TextField>(find.byType(TextField));
        expect(
          field.controller!.text,
          'Edited last\nfirst line\nfinal line\n\n',
        );
        expect(
          notes.byId('edited-last')!.body,
          'Edited last\nfirst line\nfinal line',
        );
        expect(
          field.controller!.selection.baseOffset,
          field.controller!.text.length,
        );
        expect(field.focusNode!.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);
      },
    );

    testWidgets('keeps search and notes in a drawer and switches in place', (
      tester,
    ) async {
      store.data['notes.v1'] = [
        {
          'id': 'first',
          'body': 'First note\n10 + 5',
          'createdAt': 1000,
          'updatedAt': 1000,
        },
        {
          'id': 'second',
          'body': 'Second note\n6 * 7',
          'createdAt': 2000,
          'updatedAt': 2000,
        },
      ];

      await pumpApp(tester, size: const Size(420, 800));
      expect(find.widgetWithText(ResultChip, '42'), findsOneWidget);
      expect(find.byType(NoteRow), findsNothing);

      await tester.tap(find.byTooltip('Show notes'));
      await tester.pumpAndSettle();

      expect(find.byType(AppLogo), findsNWidgets(2));
      expect(find.byType(NoteRow), findsNWidgets(2));
      expect(find.byType(TextField), findsNWidgets(2));

      await tester.tap(find.widgetWithText(NoteRow, 'First note'));
      await tester.pumpAndSettle();

      expect(find.byType(NoteRow), findsNothing);
      expect(find.byType(NoteEditor), findsOneWidget);
      expect(find.widgetWithText(ResultChip, '15'), findsOneWidget);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, 'First note\n10 + 5\n\n');
      expect(notes.byId('first')!.body, 'First note\n10 + 5');
      expect(
        field.controller!.selection.baseOffset,
        field.controller!.text.length,
      );
      expect(field.focusNode!.hasFocus, isTrue);
    });

    testWidgets('creates a ready-to-type note when the store is empty', (
      tester,
    ) async {
      await pumpApp(tester, size: const Size(420, 800));

      expect(notes.notes, hasLength(1));
      expect(find.byType(NoteEditor), findsOneWidget);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, isEmpty);
      expect(field.focusNode!.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
    });

    testWidgets('restores editor focus and the keyboard on app resume', (
      tester,
    ) async {
      await pumpApp(tester, size: const Size(420, 800));

      tester.testTextInput.hide();
      tester.testTextInput.log.clear();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.focusNode!.hasFocus, isTrue);
      expect(
        tester.testTextInput.log.map((call) => call.method),
        contains('TextInput.show'),
      );
    });
  });

  group('window chrome', () {
    testWidgets(
      'keeps the compact desktop toolbar clear of macOS window controls',
      (tester) async {
        await pumpApp(tester, size: const Size(600, 630));
        notes.create();
        await tester.pumpAndSettle();

        expect(find.byType(NoteToolbar), findsOneWidget);
        expect(
          tester.getTopLeft(find.byTooltip('Show notes')).dx,
          greaterThanOrEqualTo(WindowChrome.trafficLightsWidth),
          reason: 'the compact toolbar overlapped the macOS traffic lights',
        );
      },
      skip: !WindowChrome.overlaysContent,
    );

    testWidgets('keeps toolbar content clear of the macOS window controls', (
      tester,
    ) async {
      await pumpApp(tester);
      notes.create();
      await tester.pumpAndSettle();

      final toolbar = find.byType(NoteToolbar);
      final wordmark = find.byKey(const ValueKey('toolbar-app-wordmark'));
      final add = find.byTooltip('New note  ⌘N');
      final menu = find.byTooltip('Hide notes');

      // One title bar spans both panes, so native controls sit over an inert
      // drag region instead of forcing a second, taller sidebar header.
      expect(tester.getTopLeft(toolbar).dx, 0);
      expect(tester.getRect(toolbar).width, 1100);
      expect(
        tester.getCenter(wordmark).dx,
        closeTo(tester.getCenter(toolbar).dx, 0.5),
      );
      expect(tester.getTopLeft(add).dx, lessThan(tester.getTopLeft(menu).dx));
      expect(
        tester.getTopLeft(add).dx,
        greaterThan(WindowChrome.trafficLightsWidth),
      );

      prefs.toggleSidebar();
      await tester.pumpAndSettle();

      expect(tester.getTopLeft(toolbar).dx, 0);
      expect(find.byTooltip('Show notes'), findsOneWidget);
    }, skip: !WindowChrome.overlaysContent);

    testWidgets('starts both panes below one seamless macOS title bar', (
      tester,
    ) async {
      await pumpApp(tester);
      notes.create();
      await tester.pumpAndSettle();

      final toolbar = find.byType(NoteToolbar);
      final search = find.byType(TextField).first;
      expect(tester.getTopLeft(toolbar), Offset.zero);
      expect(
        tester.getRect(search).top,
        greaterThanOrEqualTo(tester.getRect(toolbar).bottom),
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('toolbar-app-wordmark'))).left,
        greaterThan(WindowChrome.trafficLightsWidth),
      );
    }, skip: !WindowChrome.overlaysContent);

    testWidgets('keeps both panes inside the display safe area', (
      tester,
    ) async {
      const safeTop = 59.0;
      const safeBottom = 34.0;
      tester.view.padding = const FakeViewPadding(
        top: safeTop,
        bottom: safeBottom,
      );
      addTearDown(tester.view.reset);

      const size = Size(1100, 800);
      await pumpApp(tester, size: size);
      notes.create();
      notes.updateBody(notes.notes.first.id, 'Budget\n2 + 2');
      await tester.pumpAndSettle();

      // The unified title stays below the status bar; both panes begin after it.
      expect(
        tester.getTopLeft(find.text(AppWordmark.name)).dy,
        greaterThanOrEqualTo(safeTop),
      );
      expect(
        tester.getRect(find.byType(ListView)).bottom,
        lessThanOrEqualTo(size.height - safeBottom),
      );

      // Toolbar: contents below the status bar, background still behind it.
      expect(tester.getTopLeft(find.byType(NoteToolbar)).dy, 0);
      expect(
        tester.getTopLeft(find.byIcon(Icons.add_rounded).last).dy,
        greaterThanOrEqualTo(safeTop),
      );

      // Editor: text stops short of the home indicator.
      expect(
        tester.getRect(find.byType(TextField).last).bottom,
        lessThanOrEqualTo(size.height - safeBottom),
      );

      // Footer: the running total sits above it as well. A tablet reaches
      // this layout, where nothing else reserves that strip.
      expect(
        tester.getRect(find.byKey(const ValueKey('note-total'))).bottom,
        lessThanOrEqualTo(size.height - safeBottom),
      );
    });

    testWidgets('lifts the two-pane layout clear of a software keyboard', (
      tester,
    ) async {
      // The two-pane layout is not a Scaffold, so nothing resizes it for the
      // keyboard on a tablet unless the layout does it itself.
      const keyboard = 336.0;
      tester.view.viewInsets = const FakeViewPadding(bottom: keyboard);
      addTearDown(tester.view.reset);

      const size = Size(1100, 800);
      await pumpApp(tester, size: size);
      notes.create();
      notes.updateBody(notes.notes.first.id, 'Budget\n2 + 2');
      await tester.pumpAndSettle();

      expect(find.byType(Sidebar), findsOneWidget);
      expect(
        tester.getRect(find.byKey(const ValueKey('note-total'))).bottom,
        lessThanOrEqualTo(size.height - keyboard),
      );
    });
  });
}
