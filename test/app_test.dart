import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/app.dart';
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
    expect(find.byType(AppLogo), findsNWidgets(2));
    expect(find.text('No notes yet'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'New Note'));
    await tester.pumpAndSettle();

    expect(find.byType(EmptyState), findsNothing);
    expect(find.byType(NoteEditor), findsOneWidget);
    expect(notes.notes, hasLength(1));
  });

  testWidgets('keeps exchange-rate status out of the toolbar', (tester) async {
    await pumpApp(tester);

    expect(find.byType(NoteToolbar), findsOneWidget);
    expect(find.textContaining('Rates'), findsNothing);
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
    // Title and sidebar row both come from the body text.
    expect(notes.notes.single.title, 'Weekend budget');
    expect(find.widgetWithText(NoteRow, 'Weekend budget'), findsOneWidget);
  });

  testWidgets('opens footer settings and resets desktop panel widths', (
    tester,
  ) async {
    store.data['gutter.v1'] = 320.0;
    store.data['sidebar.v1'] = 360.0;
    await pumpApp(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'New Note'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Desktop sidebar'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('sidebar-toggle')),
        matching: find.byType(Switch),
      ),
    );
    await tester.pumpAndSettle();
    expect(prefs.sidebarVisible, isFalse);

    final reset = find.text('Reset panel widths');
    await tester.ensureVisible(reset);
    await tester.tap(reset);
    await tester.pumpAndSettle();
    expect(prefs.gutterWidth, LayoutPrefs.defaultGutterWidth);
    expect(prefs.sidebarWidth, LayoutPrefs.defaultSidebarWidth);
  });

  testWidgets('shows and records every editable desktop shortcut', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'New Note'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('Daily separators'), findsOneWidget);
    expect(find.text('KEYBOARD SHORTCUTS'), findsOneWidget);
    for (final action in ShortcutAction.values) {
      expect(find.text(action.label), findsWidgets);
    }
    final dailySwitch = tester.widget<Switch>(
      find.descendant(
        of: find.byKey(const ValueKey('daily-separators-toggle')),
        matching: find.byType(Switch),
      ),
    );
    expect(dailySwitch.value, isTrue);

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
    // The subtitle becomes the line that matched, not the usual preview.
    expect(find.widgetWithText(NoteRow, 'olive oil 12.50'), findsOneWidget);
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

    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete Note'));
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
        expect(find.text('Edited last'), findsOneWidget);
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

      expect(find.byType(AppLogo), findsOneWidget);
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

        expect(find.byType(AppBar), findsOneWidget);
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

      // With the sidebar showing, it owns the window's left edge and the
      // toolbar starts where it likes.
      final withSidebar = tester.getTopLeft(find.byType(NoteToolbar)).dx;
      expect(withSidebar, greaterThan(0));

      prefs.toggleSidebar();
      await tester.pumpAndSettle();

      // Collapsed, the toolbar runs to the window edge and has to step around
      // the traffic lights itself.
      expect(tester.getTopLeft(find.byType(NoteToolbar)).dx, 0);
      expect(
        tester.getTopLeft(find.byIcon(Icons.menu_rounded)).dx,
        greaterThanOrEqualTo(WindowChrome.trafficLightsWidth),
        reason: 'the first toolbar control overlapped the window controls',
      );
    }, skip: !WindowChrome.overlaysContent);

    testWidgets('starts the sidebar below the macOS window controls', (
      tester,
    ) async {
      await pumpApp(tester);
      notes.create();
      await tester.pumpAndSettle();

      expect(
        tester.getTopLeft(find.text(AppWordmark.name)).dy,
        greaterThanOrEqualTo(WindowChrome.trafficLightsHeight),
        reason: 'the sidebar header overlapped the window controls',
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

      // Sidebar: header below the status bar, list above the home indicator.
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
    });
  });
}
