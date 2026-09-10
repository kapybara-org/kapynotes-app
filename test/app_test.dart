import 'dart:async';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/desktop_integration.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/ui/app_logo.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/editor/note_footer.dart';
import 'package:kapy_notes/ui/editor/results_gutter.dart';
import 'package:kapy_notes/ui/empty_state.dart';
import 'package:kapy_notes/core/window_chrome.dart';
import 'package:kapy_notes/ui/settings_dialog.dart';
import 'package:kapy_notes/ui/sidebar.dart';
import 'package:kapy_notes/ui/sidebar_swipe.dart';
import 'package:kapy_notes/ui/toolbar.dart';
import 'package:kapy_notes/ui/window_drag_area.dart';

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

/// What the window answers when asked to put a blurred desktop behind the
/// Flutter view. True is a runner that can; false is Windows 10 without the
/// composition attribute, or no runner at all.
bool windowGlassAvailable = true;

/// The material the window was last asked for, or null if it was never asked.
bool? windowGlassRequested;

/// The amount that went with it. The window needs this as well as the flag:
/// the blur material has a body of its own, and thinning only the tints
/// Flutter paints leaves it in place.
double? windowGlassAmount;

const _windowMaterialChannel = MethodChannel('kapynotes/window_material');

Future<void> pumpApp(
  WidgetTester tester, {
  Size size = const Size(1100, 760),
  DesktopIntegration? desktopIntegration,
  bool sidebarVisible = true,
  bool firstRun = false,
}) async {
  // Almost everything here speaks for somebody who has opened the app before,
  // and they have already met the welcome note. The tests about a genuinely
  // new install ask for one instead of every other test inheriting it.
  if (!firstRun) store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
  tester.view.physicalSize = size * tester.view.devicePixelRatio;
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);

  await notes.load();
  prefs.load();
  // Most of this suite speaks for somebody who has used the app before, and
  // they have opened the notes list at some point. A new install now starts
  // with it closed, which is asserted where it belongs rather than assumed
  // by every test that happens to look at the sidebar.
  if (prefs.sidebarVisible != sidebarVisible) prefs.toggleSidebar();
  shortcuts.load();
  await tester.pumpWidget(
    KapyNotesApp(
      store: store,
      notes: notes,
      rates: rates,
      prefs: prefs,
      shortcuts: shortcuts,
      desktopIntegration: desktopIntegration,
    ),
  );
  await tester.pumpAndSettle();
}

/// The [TextField] of the note the editor is currently showing.
TextField openNoteField(WidgetTester tester) => tester.widget<TextField>(
  find.descendant(
    of: find.byType(NoteEditor),
    matching: find.byType(TextField),
  ),
);

/// What that note says, without the blank line the editor keeps below it to
/// type into. Leading whitespace is left alone: list indentation is content.
String openNoteBody(WidgetTester tester) =>
    openNoteField(tester).controller!.text.trimRight();

/// The one way into settings on every layout: the notes list's labelled row.
Finder settingsAffordance() => find.byKey(const ValueKey('sidebar-settings'));

/// Puts the notes list on screen, wherever this layout keeps it.
///
/// The toolbar button says which state it is in, and it is the same button on
/// a window with the list closed and on a phone with the drawer shut.
Future<void> showNotesList(WidgetTester tester) async {
  final open = find.byTooltip('Show notes');
  if (open.evaluate().isEmpty) return;
  await tester.tap(open.first);
  await tester.pumpAndSettle();
}

/// Opens settings and selects [section].
Future<void> openSettings(
  WidgetTester tester, {
  SettingsSection section = SettingsSection.general,
}) async {
  await showNotesList(tester);
  await tester.tap(settingsAffordance().first);
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
    windowGlassAvailable = true;
    windowGlassRequested = null;
    windowGlassAmount = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_windowMaterialChannel, (call) async {
          if (call.method != 'setGlass') return null;
          final arguments = call.arguments as Map;
          final enabled = arguments['enabled'] as bool;
          windowGlassRequested = enabled;
          windowGlassAmount = arguments['amount'] as double?;
          return enabled && windowGlassAvailable;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_windowMaterialChannel, null);
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

      // A first launch that arrives with text keeps the text in front. The
      // welcome note is still seeded, underneath it in the list rather than
      // in its way, so a stray keystroke at launch does not cost the tour.
      expect(deferredNotes.notes, hasLength(2));
      expect(deferredNotes.notes.first.body, 'Call the dentist at 9');
      expect(deferredNotes.notes.last.body, welcomeNoteBody);
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

  testWidgets('opens a desktop note on a fresh line ready to type', (
    tester,
  ) async {
    store.data['notes.v1'] = [
      {
        'id': 'desktop-latest',
        'body': 'Desktop thought\nfinal line',
        'createdAt': 1000,
        'updatedAt': 2000,
      },
    ];
    await pumpApp(tester);

    final field = tester.widget<TextField>(
      find.descendant(
        of: find.byType(NoteEditor),
        matching: find.byType(TextField),
      ),
    );
    expect(field.controller!.text, 'Desktop thought\nfinal line\n\n');
    expect(
      field.controller!.selection.baseOffset,
      field.controller!.text.length,
    );
    expect(field.focusNode!.hasFocus, isTrue);
    expect(notes.notes.single.body, 'Desktop thought\nfinal line');
  });

  testWidgets('ready-to-type behavior can be disabled on desktop', (
    tester,
  ) async {
    store.data['readyToTypeOnOpen.v1'] = false;
    store.data['notes.v1'] = [
      {
        'id': 'desktop-continue',
        'body': 'Leave this exactly here',
        'createdAt': 1000,
        'updatedAt': 2000,
      },
    ];
    final integration = DesktopIntegration(layoutPrefs: prefs);

    await pumpApp(tester, desktopIntegration: integration);

    final field = tester.widget<TextField>(
      find.descendant(
        of: find.byType(NoteEditor),
        matching: find.byType(TextField),
      ),
    );
    expect(field.controller!.text, 'Leave this exactly here');
    expect(field.focusNode!.hasFocus, isFalse);

    integration.onOpenRequested!();
    await tester.pump();
    expect(field.controller!.text, 'Leave this exactly here');
    expect(field.focusNode!.hasFocus, isFalse);

    await tester.tap(find.byIcon(Icons.add_rounded).first);
    await tester.pumpAndSettle();
    final newNoteField = tester.widget<TextField>(
      find.descendant(
        of: find.byType(NoteEditor),
        matching: find.byType(TextField),
      ),
    );
    expect(newNoteField.controller!.text, isEmpty);
    expect(newNoteField.focusNode!.hasFocus, isTrue);
  });

  testWidgets('coming back the same day leaves the caret where it was', (
    tester,
  ) async {
    store.data['dailySeparators.v1'] = false;
    store.data['notes.v1'] = [
      {
        'id': 'desktop-return',
        'body': 'Earlier thought',
        'createdAt': 1000,
        'updatedAt': 2000,
      },
    ];
    final integration = DesktopIntegration(layoutPrefs: prefs);

    await pumpApp(tester, desktopIntegration: integration);
    final field = tester.widget<TextField>(
      find.descendant(
        of: find.byType(NoteEditor),
        matching: find.byType(TextField),
      ),
    );
    await tester.enterText(
      find.byType(TextField).last,
      'Earlier thought\n\nMore',
    );
    await tester.pumpAndSettle();
    // Somewhere in the middle, which is the position worth keeping: the end
    // is where an append session would have put it anyway.
    field.controller!.selection = const TextSelection.collapsed(offset: 5);
    await tester.pump();
    field.focusNode!.unfocus();
    await tester.pump();

    integration.onOpenRequested!();
    await tester.pump();

    // No blank lines appended, and the caret is still where it was left.
    expect(field.controller!.text, 'Earlier thought\n\nMore');
    expect(field.controller!.selection.baseOffset, 5);
    expect(field.focusNode!.hasFocus, isTrue);
    expect(notes.notes.single.body, 'Earlier thought\n\nMore');
  });

  testWidgets('a caret left on another day starts a new append session', (
    tester,
  ) async {
    store.data['dailySeparators.v1'] = false;
    store.data['notes.v1'] = [
      {
        'id': 'desktop-return',
        'body': 'Earlier thought',
        'createdAt': 1000,
        'updatedAt': 2000,
      },
    ];
    // Yesterday's position, which load() throws away rather than offer back:
    // coming back tomorrow is starting something, not finishing it.
    store.data['caret.v1'] = {
      'desktop-return': [
        5,
        DateTime.now().subtract(const Duration(days: 1)).millisecondsSinceEpoch,
      ],
    };
    final integration = DesktopIntegration(layoutPrefs: prefs);

    await pumpApp(tester, desktopIntegration: integration);
    final field = tester.widget<TextField>(
      find.descendant(
        of: find.byType(NoteEditor),
        matching: find.byType(TextField),
      ),
    );

    expect(field.controller!.text, 'Earlier thought\n\n');
    expect(
      field.controller!.selection.baseOffset,
      field.controller!.text.length,
    );
    // And the blank line is presentation only until something is typed.
    expect(notes.notes.single.body, 'Earlier thought');
  });

  testWidgets('the pin sits beside the lockup, outside its drag region', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.pumpAndSettle();

    final pin = find.byIcon(Icons.push_pin_outlined);
    final wordmark = find.byKey(const ValueKey('toolbar-app-wordmark'));
    expect(pin, findsOneWidget);

    // The lockup is window chrome and drags the window. The pin must not be
    // under that: DragToMoveArea recognises double taps, so it holds the
    // gesture arena for the timeout and a button beneath it answers late on
    // every single click.
    expect(
      find.ancestor(of: pin, matching: find.byType(WindowDragArea)),
      findsNothing,
      reason: 'the pin would answer a double-tap timeout late on every click',
    );
    expect(
      find.ancestor(of: wordmark, matching: find.byType(WindowDragArea)),
      findsOneWidget,
      reason: 'the lockup still has to drag the window',
    );

    // Beside it, and on the trailing side of it.
    expect(
      tester.getCenter(pin).dx,
      greaterThan(tester.getCenter(wordmark).dx),
    );

    await tester.tap(pin);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.push_pin_rounded), findsOneWidget);
    expect(find.byIcon(Icons.push_pin_outlined), findsNothing);
  });

  testWidgets('a first run opens on a page, with the notes list closed', (
    tester,
  ) async {
    // pumpApp speaks for an established user by default, so this is the one
    // place that asks for the state a new install actually starts in.
    await pumpApp(tester, sidebarVisible: false);

    expect(prefs.sidebarVisible, isFalse);
    // SplitView keeps the list mounted inside an OverflowBox and collapses
    // the container around it, so the list's own rect is 260 wide either way
    // and geometry says nothing here. The toolbar does: it offers to show the
    // notes rather than to hide them.
    expect(find.byTooltip('Show notes'), findsOneWidget);
    expect(find.byTooltip('Hide notes'), findsNothing);
  });

  testWidgets(
    'the pin survives every desktop width, and never reaches a phone',
    (tester) async {
      // The bug this replaces: the compact toolbar is a second call site, and
      // it was reached by a narrow desktop window as well as by a phone. The
      // pin went missing on the desktop at small widths as a result.
      for (final size in [
        const Size(1100, 760),
        const Size(700, 620),
        LayoutPrefs.minimumWindowSize,
      ]) {
        await pumpApp(tester, size: size);
        expect(
          find.byIcon(Icons.push_pin_outlined),
          findsOneWidget,
          reason: 'the pin went missing at $size',
        );
      }

      // The drawer hides the note actions while it covers them. The pin is
      // about the window, not the note, so it stays.
      await pumpApp(tester, size: const Size(700, 620));
      await tester.tap(find.byTooltip('Show notes'));
      await tester.pumpAndSettle();
      expect(
        find.byIcon(Icons.push_pin_outlined),
        findsOneWidget,
        reason: 'the pin went with the drawer',
      );

      // A phone has no window to float, so the control is absent rather than
      // present and inert.
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      await pumpApp(tester, size: const Size(420, 800));
      expect(find.byIcon(Icons.push_pin_outlined), findsNothing);
      expect(find.byIcon(Icons.push_pin_rounded), findsNothing);
    },
  );

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
    expect(tester.getCenter(menu).dx, lessThan(tester.getCenter(add).dx));
    expect(
      find.descendant(
        of: toolbar,
        matching: find.byIcon(Icons.more_horiz_rounded),
      ),
      findsNothing,
    );
  });

  testWidgets('uses compact toolbar and roomier footer surfaces on desktop', (
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
    final footerBold = find.descendant(
      of: find.byKey(const ValueKey('format-bold')),
      matching: find.byType(IconButton),
    );
    expect(tester.getSize(footerBold), const Size.square(32));

    Finder footerButton(String key) => find.descendant(
      of: find.byKey(ValueKey(key)),
      matching: find.byType(IconButton),
    );
    final image = tester.getRect(footerButton('insert-image'));
    final mic = tester.getRect(footerButton('record-voice'));
    final formatting = tester.getRect(footerButton('formatting-toggle'));
    final pointer = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      pointer: 91,
    );
    await pointer.addPointer(location: Offset.zero);
    addTearDown(pointer.removePointer);
    await pointer.moveTo(formatting.center);
    await tester.pumpAndSettle();
    final style = tester.getRect(footerButton('format-style'));
    expect(mic.left - image.right, 4);
    expect(formatting.left - mic.right, 12);
    expect(style.left - formatting.right, 4);
    // The row starts at the bar's own edge inset: nothing precedes the two
    // insert actions now that settings is only ever in the notes list.
    expect(
      image.left - tester.getRect(find.byType(NoteFooter)).left,
      closeTo(12, 0.01),
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

  testWidgets('dragging resizes and clicking hides the desktop sidebar', (
    tester,
  ) async {
    await pumpApp(tester);
    notes.create();
    await tester.pumpAndSettle();

    final divider = find.byKey(const ValueKey('sidebar-divider'));
    expect(divider, findsOneWidget);
    expect(
      find.byTooltip('Drag to resize. Click to hide notes.'),
      findsOneWidget,
    );

    await tester.drag(divider, const Offset(-240, 0));
    await tester.pumpAndSettle();

    expect(prefs.sidebarWidth, LayoutPrefs.minSidebarWidth);
    expect(prefs.sidebarVisible, isTrue);

    await tester.tap(find.byKey(const ValueKey('sidebar-divider')));
    await tester.pumpAndSettle();

    expect(prefs.sidebarVisible, isFalse);
    expect(find.byKey(const ValueKey('sidebar-divider')), findsNothing);
    expect(find.byTooltip('Show notes'), findsOneWidget);
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
    expect(settingsAffordance(), findsOneWidget);
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
    store.data['resultsVisible.v1'] = false;
    store.data['sidebar.v1'] = 360.0;
    await pumpApp(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'New Note'));
    await tester.pumpAndSettle();

    await openSettings(tester);

    // Twice over now: the sidebar row that opened it, and the dialog's title.
    expect(find.text('Settings'), findsWidgets);
    expect(find.text('Desktop sidebar'), findsOneWidget);
    final dailyToggle = find.byKey(const ValueKey('daily-separators-toggle'));
    final compactSwitch = find.descendant(
      of: dailyToggle,
      matching: find.byKey(const ValueKey('compact-switch-indicator')),
    );
    expect(prefs.dailySeparatorsEnabled, isTrue);
    expect(tester.getSize(compactSwitch), const Size(34, 18));

    final readyToType = find.byKey(
      const ValueKey('ready-to-type-on-open-toggle'),
    );
    expect(prefs.readyToTypeOnOpen, isTrue);
    await tester.tap(readyToType);
    await tester.pumpAndSettle();
    expect(prefs.readyToTypeOnOpen, isFalse);

    await tester.tap(find.byKey(const ValueKey('sidebar-toggle')));
    await tester.pumpAndSettle();
    expect(prefs.sidebarVisible, isFalse);

    final reset = find.text('Reset panel widths');
    await tester.ensureVisible(reset);
    await tester.tap(reset);
    await tester.pumpAndSettle();
    expect(prefs.gutterWidth, LayoutPrefs.defaultGutterWidth);
    expect(prefs.resultsVisible, isTrue);
    expect(prefs.sidebarWidth, LayoutPrefs.defaultSidebarWidth);
  });

  testWidgets('spell check is native, subtle, and can be turned off', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'New Note'));
    await tester.pumpAndSettle();

    expect(prefs.spellCheckEnabled, isTrue);
    expect(
      tester.widget<NoteEditor>(find.byType(NoteEditor)).spellCheckEnabled,
      isTrue,
    );
    expect(
      openNoteField(tester).spellCheckConfiguration?.spellCheckEnabled,
      isFalse,
      reason: 'the rich editor merges native results into its own span tree',
    );
    expect(openNoteField(tester).autocorrect, isFalse);

    await openSettings(tester);
    final toggle = find.byKey(const ValueKey('spell-check-toggle'));
    expect(
      find.descendant(of: toggle, matching: find.text('Check spelling')),
      findsOneWidget,
    );
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(prefs.spellCheckEnabled, isFalse);
    expect(
      tester.widget<NoteEditor>(find.byType(NoteEditor)).spellCheckEnabled,
      isFalse,
    );
  });

  testWidgets('settings keeps system labels medium or lighter', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'New Note'));
    await tester.pumpAndSettle();
    await openSettings(tester);

    final settings = find.byType(SettingsDialog);
    final textWidgets = find.descendant(
      of: settings,
      matching: find.byType(Text),
    );
    for (final element in textWidgets.evaluate()) {
      final text = element.widget as Text;
      final inherited = DefaultTextStyle.of(element).style;
      final weight = text.style?.fontWeight ?? inherited.fontWeight;
      expect(
        (weight ?? FontWeight.w400).value,
        lessThanOrEqualTo(FontWeight.w500.value),
        reason: '${text.data ?? text.textSpan?.toPlainText()} is too bold',
      );
    }

    FontWeight weightOf(String label) {
      final finder = find.descendant(of: settings, matching: find.text(label));
      final element = tester.element(finder);
      final text = tester.widget<Text>(finder);
      return text.style?.fontWeight ??
          DefaultTextStyle.of(element).style.fontWeight ??
          FontWeight.w400;
    }

    expect(weightOf('Settings'), FontWeight.w500);
    expect(weightOf('General'), FontWeight.w500);
    expect(weightOf('Appearance'), FontWeight.w400);
    expect(weightOf('NOTES'), FontWeight.w500);
    expect(weightOf('Daily separators'), FontWeight.w500);
    expect(weightOf('Done'), FontWeight.w500);
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

  testWidgets('chooses a fixed startup note and can return to last opened', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'New Note'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(NoteEditor),
        matching: find.byType(TextField),
      ),
      'Daily log',
    );
    await tester.pumpAndSettle();
    final id = notes.notes.single.id;

    await openSettings(tester);
    final setting = find.byKey(const ValueKey('default-note-setting'));
    await tester.tap(setting);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('default-note-option-$id')));
    await tester.pumpAndSettle();

    expect(prefs.defaultNoteId, id);
    expect(find.text('Daily log'), findsWidgets);

    await tester.tap(setting);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('default-note-option-last-opened')),
    );
    await tester.pumpAndSettle();
    expect(prefs.defaultNoteId, isNull);
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
    await openSettings(tester, section: SettingsSection.appearance);

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
    expect(
      find.byTooltip('Seven million\n7 million\nClick to copy'),
      findsOneWidget,
    );

    await openSettings(tester, section: SettingsSection.appearance);
    expect(find.text('1,23,45,678'), findsWidgets);
    // Number format shares the Appearance pane with the theme, the writing
    // font and the paper now, so it is below the fold.
    final indian = find.byKey(const ValueKey('number-system-indian'));
    await tester.ensureVisible(indian);
    await tester.pumpAndSettle();
    await tester.tap(indian);
    await tester.pumpAndSettle();
    expect(prefs.numberSystem, NumberSystem.indian);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    // The open note re-evaluates against the new engine without being touched.
    expect(find.widgetWithText(ResultChip, '70,00,000'), findsOneWidget);
    expect(
      find.byTooltip('Seventy lakh\n0.7 crore\nClick to copy'),
      findsOneWidget,
    );
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
    expect(editor().style?.fontFamily, WritingFont.handwritten.fontFamily);

    await openSettings(tester, section: SettingsSection.appearance);
    expect(find.text('WRITING FONT'), findsOneWidget);
    for (final font in WritingFont.values) {
      expect(find.byKey(ValueKey('writing-font-${font.name}')), findsOneWidget);
    }
    final handwritingPreview = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('writing-font-handwritten')),
        matching: find.text(WritingFont.handwritten.preview),
      ),
    );
    expect(
      handwritingPreview.style?.fontVariations,
      WritingFont.handwritten.fontVariations,
    );
    final mixedPreview = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('writing-font-mixed')),
        matching: find.byWidgetPredicate(
          (widget) => widget is Text && widget.textSpan != null,
        ),
      ),
    );
    final mixedSpans = (mixedPreview.textSpan! as TextSpan).children!;
    expect(mixedSpans.first.style?.fontFamily, 'Shantell Sans');
    expect(
      mixedSpans.last.style?.fontFamily,
      isNull,
      reason: 'the number inherits the mixed option\'s monospace base',
    );

    await tester.tap(find.byKey(const ValueKey('writing-font-monospace')));
    await tester.pumpAndSettle();
    expect(prefs.writingFont, WritingFont.monospace);
    expect(editor().style?.fontFamily, WritingFont.monospace.fontFamily);

    final restored = LayoutPrefs(store)..load();
    expect(restored.writingFont, WritingFont.monospace);
  });

  testWidgets('transparency thins the whole window, and persists', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'New Note'));
    await tester.pumpAndSettle();

    CalcPalette palette() => Theme.of(
      tester.element(find.byType(NoteEditor)),
    ).extension<CalcPalette>()!;

    // The fill actually painted behind the note list, rather than the palette
    // it was asked to derive it from.
    double sidebarAlpha() {
      final fill = tester.widget<ColoredBox>(
        find
            .descendant(
              of: find.byType(Sidebar),
              matching: find.byType(ColoredBox),
            )
            .first,
      );
      return fill.color.a;
    }

    // And the fill the page paints under the writing.
    double paperAlpha() {
      final page = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(NoteEditor),
              matching: find.byType(Container),
            )
            .first,
      );
      return page.color!.a;
    }

    final opaque = palette();
    final opaqueSidebarAlpha = sidebarAlpha();
    expect(prefs.transparencyEnabled, isFalse);
    expect(opaque.isGlass, isFalse);
    expect(paperAlpha(), 1);
    expect(
      windowGlassRequested,
      isFalse,
      reason: 'the window is told at launch which material to show',
    );

    await openSettings(tester, section: SettingsSection.appearance);
    final toggle = find.byKey(const ValueKey('transparency-toggle'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(prefs.transparencyEnabled, isTrue);
    expect(windowGlassRequested, isTrue);
    expect(
      windowGlassAmount,
      LayoutPrefs.defaultTransparencyAmount,
      reason: 'the window fades its own material to match the slider',
    );
    expect(palette().isGlass, isTrue);
    expect(
      sidebarAlpha(),
      opaqueSidebarAlpha,
      reason:
          'the notes list is a panel over the glass rather than part of it, '
          'and thinned with the chrome it came out further through than the '
          'paper beside it',
    );
    expect(paperAlpha(), lessThan(1));
    expect(
      paperAlpha(),
      greaterThan(0.25),
      reason:
          'the slider starts near the substantial end: somebody who has just '
          'switched the mode on has not yet said how far they want it taken',
    );
    expect((LayoutPrefs(store)..load()).transparencyEnabled, isTrue);

    // The amount slider appears with the mode and thins the paint further.
    final slider = find.byKey(const ValueKey('transparency-amount'));
    expect(slider, findsOneWidget);
    final defaultPaperAlpha = paperAlpha();
    final sliderWidget = find.descendant(
      of: slider,
      matching: find.byType(Slider),
    );
    await tester.ensureVisible(sliderWidget);
    await tester.drag(sliderWidget, const Offset(200, 0));
    await tester.pumpAndSettle();
    expect(
      prefs.transparencyAmount,
      greaterThan(LayoutPrefs.defaultTransparencyAmount),
    );
    expect(paperAlpha(), lessThan(defaultPaperAlpha));
    expect(
      (LayoutPrefs(store)..load()).transparencyAmount,
      prefs.transparencyAmount,
    );
    expect(
      windowGlassAmount,
      prefs.transparencyAmount,
      reason: 'dragging the slider re-asks the window, not just the theme',
    );

    // The palette's colours are the same values; only the paint derived from
    // them thins. The type never does.
    expect(palette().editorBackground, opaque.editorBackground);
    expect(palette().surfaceBackground, opaque.surfaceBackground);
    expect(palette().textPrimary, opaque.textPrimary);
    expect(palette().textSecondary, opaque.textSecondary);

    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(highContrast: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpAndSettle();

    expect(
      prefs.transparencyEnabled,
      isTrue,
      reason: 'the choice is preserved',
    );
    expect(
      palette().isGlass,
      isFalse,
      reason: 'High Contrast asks for separation, so the window goes solid',
    );
    expect(sidebarAlpha(), opaqueSidebarAlpha);
    expect(paperAlpha(), 1);
  });

  testWidgets('the amount slider is not offered while transparency is off', (
    tester,
  ) async {
    await pumpApp(tester);
    await openSettings(tester, section: SettingsSection.appearance);
    expect(find.byKey(const ValueKey('transparency-toggle')), findsOneWidget);
    expect(find.byKey(const ValueKey('transparency-amount')), findsNothing);
  });

  testWidgets('a window that cannot blur keeps its opaque paint', (
    tester,
  ) async {
    // Windows 10 without the composition attribute answers no. Tints painted
    // over an unblurred window show black through every gap, so the setting
    // is kept but the surfaces are not thinned.
    windowGlassAvailable = false;
    store.data['transparencyEnabled.v1'] = true;
    await pumpApp(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'New Note'));
    await tester.pumpAndSettle();

    final palette = Theme.of(
      tester.element(find.byType(NoteEditor)),
    ).extension<CalcPalette>()!;
    expect(prefs.transparencyEnabled, isTrue);
    expect(windowGlassRequested, isTrue);
    expect(palette.isGlass, isFalse);
  });

  testWidgets('a desktop editor is a text field to assistive tools', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'New Note'));
    await tester.pumpAndSettle();

    // Dictation apps and text expanders do not type: they write into whatever
    // the system reports as the focused accessibility element, and only if it
    // is a text field. Switching that tree on is the runner's job (on macOS,
    // AccessibilityTree.swift; a handle taken here cannot do it, and this
    // binding holds one anyway). What the widgets owe the tree is a focused,
    // writable text-field node for the editor, so the words have a place to
    // land the moment the note is open.
    expect(
      tester.getSemantics(
        find.descendant(
          of: find.byType(NoteEditor),
          matching: find.byType(EditableText),
        ),
      ),
      isSemantics(isTextField: true, isFocused: true, isReadOnly: false),
    );
  });

  testWidgets('desktop can keep the app running and open it at login', (
    tester,
  ) async {
    // Stands in for the runners, which a widget test has none of.
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    void mock(String name, Future<Object?> Function(MethodCall) handler) {
      final channel = MethodChannel(name);
      messenger.setMockMethodCallHandler(channel, handler);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    }

    final native = <String>[];
    for (final name in ['window_manager', 'tray_manager']) {
      mock(name, (call) async {
        native.add(call.method);
        return call.method.startsWith('is') ? false : null;
      });
    }
    var openAtLogin = false;
    mock('kapynotes/login_item', (call) async {
      switch (call.method) {
        case 'isSupported':
          return true;
        case 'isEnabled':
          return openAtLogin;
        case 'setEnabled':
          openAtLogin = (call.arguments as Map)['enabled'] as bool;
          return null;
      }
      return null;
    });

    final integration = DesktopIntegration(layoutPrefs: prefs);
    await pumpApp(tester, desktopIntegration: integration);
    await openSettings(tester);

    final keepRunning = find.byKey(const ValueKey('keep-running-toggle'));
    await tester.ensureVisible(keepRunning);

    // Desktop starts here rather than arriving by being asked.
    expect(prefs.keepRunningInBackground, isTrue);

    await tester.tap(keepRunning);
    await tester.pumpAndSettle();
    expect(prefs.keepRunningInBackground, isFalse);

    await tester.tap(keepRunning);
    await tester.pumpAndSettle();
    expect(prefs.keepRunningInBackground, isTrue);
    // The tray and the close button change meaning together, whichever way
    // the switch was moved.
    expect(native, containsAll(['setPreventClose', 'setIcon']));

    final login = find.byKey(const ValueKey('login-item-toggle'));
    await tester.ensureVisible(login);
    await tester.tap(login);
    await tester.pumpAndSettle();
    expect(openAtLogin, isTrue);

    // The toast that explains what the close button now does.
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('the startup row is absent where the OS has no mechanism', (
    tester,
  ) async {
    final channel = const MethodChannel('kapynotes/login_item');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);

    await pumpApp(
      tester,
      desktopIntegration: DesktopIntegration(layoutPrefs: prefs),
    );
    await openSettings(tester);

    // A switch that cannot do anything is worse than no switch.
    expect(find.byKey(const ValueKey('login-item-toggle')), findsNothing);
    expect(find.byKey(const ValueKey('keep-running-toggle')), findsOneWidget);
  });

  testWidgets('the system-wide new-note shortcut lands on a blank note', (
    tester,
  ) async {
    // Registering the hot key needs a host window manager, so this stands in
    // for the press itself: what the handler calls once the window is up.
    final integration = DesktopIntegration(layoutPrefs: prefs);
    await pumpApp(tester, desktopIntegration: integration);

    await tester.tap(find.widgetWithText(FilledButton, 'New Note'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(NoteEditor),
        matching: find.byType(TextField),
      ),
      'petrol 40',
    );
    await tester.pumpAndSettle();

    expect(integration.onNewNoteRequested, isNotNull);
    integration.onNewNoteRequested!();
    await tester.pumpAndSettle();

    expect(notes.notes, hasLength(2));
    // The new note is the one being edited, and the old one is untouched.
    final editor = tester.widget<TextField>(
      find.descendant(
        of: find.byType(NoteEditor),
        matching: find.byType(TextField),
      ),
    );
    expect(editor.controller!.text, isEmpty);
    expect(notes.notes.last.body, startsWith('petrol 40'));
  });

  testWidgets('shows and records every editable desktop shortcut', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'New Note'));
    await tester.pumpAndSettle();
    await openSettings(tester, section: SettingsSection.shortcuts);

    expect(find.text('SYSTEM-WIDE'), findsOneWidget);
    expect(find.text('APP'), findsOneWidget);
    expect(find.text('FORMATTING'), findsOneWidget);
    // The shortcuts another app can refuse lead the pane, then the in-app
    // keys, then formatting.
    expect(
      tester.getTopLeft(find.text('SYSTEM-WIDE')).dy,
      lessThan(tester.getTopLeft(find.text('APP')).dy),
    );
    expect(
      tester.getTopLeft(find.text('APP')).dy,
      lessThan(tester.getTopLeft(find.text('FORMATTING')).dy),
    );
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

    final recorded = shortcuts.bindingFor(ShortcutAction.findNotes)!;
    expect(recorded.logicalKey, LogicalKeyboardKey.keyP);
    expect(recorded.meta, isTrue);
    expect(recorded.shift, isTrue);
  });

  testWidgets('the pin icon answers the click on a narrow window', (
    tester,
  ) async {
    // The default window is 600 wide, under the two-pane breakpoint, so this
    // is the layout a fresh install actually opens in — and the one where the
    // toolbar was reading a preference nothing was listening to.
    await pumpApp(tester, size: LayoutPrefs.defaultWindowSize);
    notes.create(body: 'alpha');
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.push_pin_outlined), findsOneWidget);

    await tester.tap(find.byIcon(Icons.push_pin_outlined));
    await tester.pumpAndSettle();

    // The window really did go on top; the icon has to say so in the same
    // frame, without waiting for something else to redraw the page.
    expect(prefs.alwaysOnTop, isTrue);
    expect(find.byIcon(Icons.push_pin_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.push_pin_rounded));
    await tester.pumpAndSettle();

    expect(prefs.alwaysOnTop, isFalse);
    expect(find.byIcon(Icons.push_pin_outlined), findsOneWidget);
  });

  testWidgets('rebinding a shortcut updates the hints already on screen', (
    tester,
  ) async {
    await pumpApp(tester);
    notes.create(body: 'alpha');
    await tester.pumpAndSettle();

    final before = shortcuts.bindingFor(ShortcutAction.formatBold)!;
    expect(find.byTooltip('Bold · ${before.displayLabel}'), findsOneWidget);
    expect(
      find.byTooltip(
        'Add an image · ${shortcuts.bindingFor(ShortcutAction.insertImage)!.displayLabel}',
      ),
      findsOneWidget,
    );
    expect(
      find.byTooltip(
        'Record a voice note · ${shortcuts.bindingFor(ShortcutAction.recordVoiceNote)!.displayLabel}',
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(Sidebar),
        matching: find.byTooltip(
          'Settings · ${shortcuts.bindingFor(ShortcutAction.openSettings)!.displayLabel}',
        ),
      ),
      findsOneWidget,
    );

    // What the settings pane does when somebody records a new chord. The
    // pane promises the footer hints keep up with it.
    shortcuts.update(
      ShortcutAction.formatBold,
      const ShortcutBinding(
        logicalKey: LogicalKeyboardKey.keyK,
        physicalKey: PhysicalKeyboardKey.keyK,
        meta: true,
        shift: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('Bold · Cmd + Shift + K'), findsOneWidget);

    // The toolbar spells its pin shortcut out too, from the same source.
    final pin = shortcuts.bindingFor(ShortcutAction.toggleAlwaysOnTop)!;
    expect(find.byTooltip('Keep on top  ${pin.displayLabel}'), findsOneWidget);

    shortcuts.update(
      ShortcutAction.toggleAlwaysOnTop,
      const ShortcutBinding(
        logicalKey: LogicalKeyboardKey.keyJ,
        physicalKey: PhysicalKeyboardKey.keyJ,
        meta: true,
        shift: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('Keep on top  Cmd + Shift + J'), findsOneWidget);
  });

  testWidgets('a shortcut can be removed, and then answers nothing', (
    tester,
  ) async {
    await pumpApp(tester);
    notes.create(body: '2 + 2');
    await tester.pumpAndSettle();
    expect(prefs.resultsVisible, isTrue);

    await openSettings(tester, section: SettingsSection.shortcuts);
    final row = find.byKey(const ValueKey('shortcut-toggleResults'));
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('shortcut-remove')));
    await tester.pumpAndSettle();

    expect(shortcuts.bindingFor(ShortcutAction.toggleResults), isNull);
    // The row stays where it was — it is also the way to give the key back.
    expect(
      find.descendant(of: row, matching: find.text('None')),
      findsOneWidget,
    );

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    expect(prefs.resultsVisible, isTrue, reason: 'the chord is nobody\'s now');
  });

  testWidgets('Backspace on its own clears the shortcut being recorded', (
    tester,
  ) async {
    await pumpApp(tester);
    await openSettings(tester, section: SettingsSection.shortcuts);

    final row = find.byKey(const ValueKey('shortcut-findNotes'));
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();

    // Bare Backspace cannot be recorded as a chord — a binding needs a
    // modifier — so it is free to mean "take this one away".
    await tester.sendKeyDownEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();

    expect(shortcuts.bindingFor(ShortcutAction.findNotes), isNull);
    expect(find.text('Press your new shortcut'), findsNothing);
  });

  testWidgets('Ctrl+Tab walks the notes list, and Shift walks it back', (
    tester,
  ) async {
    await pumpApp(tester);
    notes.create(body: 'alpha');
    notes.create(body: 'bravo');
    notes.create(body: 'charlie');
    await tester.pumpAndSettle();

    // Newest first. Selecting a note never reorders the list — only editing
    // one does — so a walk passes each note exactly once.
    expect(notes.notes.map((note) => note.body), ['charlie', 'bravo', 'alpha']);

    Future<void> tab({bool shift = false}) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.tab);
      if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
    }

    expect(openNoteBody(tester), 'alpha');
    // Off the bottom of the list and round to the top.
    await tab();
    expect(openNoteBody(tester), 'charlie');
    await tab();
    expect(openNoteBody(tester), 'bravo');
    await tab(shift: true);
    expect(openNoteBody(tester), 'charlie');
  });

  testWidgets('Ctrl+Tab leaves a list line alone on its way past', (
    tester,
  ) async {
    await pumpApp(tester);
    notes.create(body: '\u2022 bravo');
    notes.create(body: 'alpha');
    await tester.pumpAndSettle();
    expect(openNoteBody(tester), '\u2022 bravo');

    // Opening a note parks the caret on the blank line underneath, and Tab
    // only claims a line that is actually a list item.
    Future<void> caretOnTheListLine() async {
      openNoteField(tester).controller!.selection =
          const TextSelection.collapsed(offset: 4);
      await tester.pump();
    }

    const ctrl = LogicalKeyboardKey.controlLeft;
    Future<void> tab({bool control = false}) async {
      if (control) await tester.sendKeyDownEvent(ctrl);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.tab);
      if (control) await tester.sendKeyUpEvent(ctrl);
      await tester.pumpAndSettle();
    }

    // Plain Tab nests the item — which is what makes the next assertion mean
    // something, rather than passing because the caret was somewhere inert.
    await caretOnTheListLine();
    await tab();
    expect(openNoteBody(tester), '  \u25e6 bravo');

    // The same key carrying Ctrl belongs to the walk between notes. It has to
    // pass straight through the editor: nesting the item a second time on the
    // way out would be a keystroke nobody asked for.
    await caretOnTheListLine();
    await tab(control: true);
    expect(openNoteBody(tester), 'alpha');
    expect(
      notes.notes.map((note) => note.body.trimRight()),
      contains('  \u25e6 bravo'),
    );
  });

  testWidgets('the results column has a shortcut like the notes list', (
    tester,
  ) async {
    await pumpApp(tester);
    notes.create(body: '2 + 2');
    await tester.pumpAndSettle();
    expect(prefs.resultsVisible, isTrue);
    expect(prefs.sidebarVisible, isTrue);

    Future<void> press(LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(key);
      await tester.sendKeyUpEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
    }

    // Cmd+R folds the right-hand column away, leaving the handle that brings
    // it back; Cmd+S does the same for the list on the left. Notes autosave,
    // so the conventional save chord is free for the pane itself.
    await press(LogicalKeyboardKey.keyR);
    expect(prefs.resultsVisible, isFalse);
    expect(
      find.byKey(const ValueKey('results-restore-handle')),
      findsOneWidget,
    );

    await press(LogicalKeyboardKey.keyR);
    expect(prefs.resultsVisible, isTrue);

    await press(LogicalKeyboardKey.keyS);
    expect(prefs.sidebarVisible, isFalse);
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

  testWidgets('creates a note from the plus beside search', (tester) async {
    await pumpApp(tester);
    final before = notes.notes.length;
    final search = find.byType(TextField).first;
    final add = find.byKey(const ValueKey('sidebar-new-note'));

    expect(add, findsOneWidget);
    expect(tester.getCenter(add).dx, greaterThan(tester.getRect(search).right));

    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(notes.notes, hasLength(before + 1));
  });

  group('asking for a new note while already in one', () {
    Finder plus() => find.byKey(const ValueKey('sidebar-new-note'));

    testWidgets('a blank note is the new note, so no second one appears', (
      tester,
    ) async {
      await pumpApp(tester);
      notes.create(body: 'Something written');
      await tester.pumpAndSettle();

      await tester.tap(plus());
      await tester.pumpAndSettle();
      final made = notes.notes.length;
      final blank = notes.notes.first;
      expect(blank.isEmpty, isTrue);

      // Ask twice more. The blank note is already the new note.
      await tester.tap(plus());
      await tester.pumpAndSettle();
      await tester.tap(plus());
      await tester.pumpAndSettle();

      expect(notes.notes, hasLength(made));
      expect(notes.notes.first.id, blank.id);
      // And the caret is back in it, which is the whole of what plus is for.
      expect(prefs.lastOpenedNoteId, blank.id);
    });

    testWidgets('writing in it makes the next press a real new note', (
      tester,
    ) async {
      await pumpApp(tester);
      await tester.tap(plus());
      await tester.pumpAndSettle();
      final started = notes.notes.first;
      final made = notes.notes.length;

      notes.updateBody(started.id, 'Now it says something');
      await tester.pumpAndSettle();

      await tester.tap(plus());
      await tester.pumpAndSettle();
      expect(notes.notes, hasLength(made + 1));
      expect(notes.notes.first.id, isNot(started.id));
    });

    testWidgets('the toolbar plus answers the same way', (tester) async {
      await pumpApp(tester);
      await tester.tap(find.byTooltip('New note  ⌘N'));
      await tester.pumpAndSettle();
      final made = notes.notes.length;

      await tester.tap(find.byTooltip('New note  ⌘N'));
      await tester.pumpAndSettle();
      expect(notes.notes, hasLength(made));
    });

    testWidgets('a blank note holding a picture is not blank', (tester) async {
      await pumpApp(tester);
      await tester.tap(plus());
      await tester.pumpAndSettle();
      final started = notes.notes.first;
      final made = notes.notes.length;

      // The body is only the character the picture anchors to, so a reading
      // that trusted the text alone would call this note empty.
      notes
          .updateDocument(started.id, NoteAttachmentRef.placeholder, const [], [
            NoteImageRef(
              offset: 0,
              hash: 'abc123',
              key: Uint8List(32),
              mime: 'image/png',
              width: 10,
              height: 20,
              bytes: 100,
            ),
          ]);
      await tester.pumpAndSettle();

      await tester.tap(plus());
      await tester.pumpAndSettle();
      expect(notes.notes, hasLength(made + 1));
    });

    testWidgets('a blank note in the archive is not the one to come back to', (
      tester,
    ) async {
      await pumpApp(tester);
      await tester.tap(plus());
      await tester.pumpAndSettle();
      final blank = notes.notes.first;
      notes.archive(blank.id);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sidebar-archive')));
      await tester.pumpAndSettle();
      final made = notes.notes.length;

      // Asking for a new note from inside the archive leaves the archive, so
      // the blank note sitting in it is not the one being asked for.
      await tester.tap(plus());
      await tester.pumpAndSettle();
      expect(notes.notes, hasLength(made + 1));
      expect(notes.archivedNotes.single.id, blank.id);
    });
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

  testWidgets('pins notes into a top section and allows unpinning', (
    tester,
  ) async {
    await pumpApp(tester);
    final reference = notes.create(body: 'Reference');
    notes.create(body: 'Today');
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(NoteRow, 'Reference'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('pin-note-${reference.id}')));
    await tester.pumpAndSettle();

    List<String> rowTitles() => tester
        .widgetList<NoteRow>(find.byType(NoteRow))
        .map((row) => row.note.title)
        .toList();
    expect(find.text('Pinned'), findsOneWidget);
    expect(find.text('Notes'), findsOneWidget);
    expect(rowTitles(), ['Reference', 'Today']);
    expect(notes.isPinned(reference.id), isTrue);
    expect(find.byTooltip('Unpin note'), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('pin-note-${reference.id}')));
    await tester.pumpAndSettle();

    expect(find.text('Pinned'), findsNothing);
    expect(rowTitles(), ['Today', 'Reference']);
    expect(notes.isPinned(reference.id), isFalse);
  });

  testWidgets('archives a note, then restores it from the archive', (
    tester,
  ) async {
    await pumpApp(tester);
    for (final body in ['First', 'Second', 'Third']) {
      notes.create();
      notes.updateBody(notes.notes.first.id, body);
    }
    await tester.pumpAndSettle();

    // Notes are newest-first; pick the top one, then archive it.
    await tester.tap(find.widgetWithText(NoteRow, 'Third'));
    await tester.pumpAndSettle();

    final third = notes.notes.singleWhere((note) => note.title == 'Third');
    await tester.tap(find.byKey(ValueKey('archive-note-${third.id}')));
    await tester.pumpAndSettle();

    expect(notes.notes.map((n) => n.title), ['Second', 'First']);
    expect(notes.archivedNotes.single.title, 'Third');
    expect(find.widgetWithText(NoteRow, 'Third'), findsNothing);
    expect(find.byType(NoteEditor), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('sidebar-archive')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(NoteRow, 'Third'), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('restore-note-${third.id}')));
    await tester.pumpAndSettle();
    expect(notes.archivedNotes, isEmpty);
    expect(notes.notes.first.title, 'Third');
  });

  group('emptying the archive', () {
    /// Three notes, all archived, with the archive open.
    Future<List<Note>> openArchive(WidgetTester tester) async {
      await pumpApp(tester);
      for (final body in ['First', 'Second', 'Third']) {
        notes.create();
        notes.updateBody(notes.notes.first.id, body);
      }
      await tester.pumpAndSettle();
      for (final note in [...notes.notes]) {
        notes.archive(note.id);
      }
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sidebar-archive')));
      await tester.pumpAndSettle();
      return notes.archivedNotes;
    }

    Future<void> confirm(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('confirm-delete')));
      await tester.pumpAndSettle();
    }

    testWidgets('the way into the archive reads as a bin, not a filing box', (
      tester,
    ) async {
      await pumpApp(tester);
      await tester.pumpAndSettle();

      final entry = find.byKey(const ValueKey('sidebar-archive'));
      expect(entry, findsOneWidget);
      expect(
        find.descendant(of: entry, matching: find.byIcon(archiveIcon)),
        findsOneWidget,
      );
    });

    testWidgets('a note in the archive can be thrown away for good', (
      tester,
    ) async {
      final archived = await openArchive(tester);
      final third = archived.firstWhere((note) => note.title == 'Third');
      // Row actions only show on the row under the pointer or the open one,
      // so open it first, exactly as a reader would.
      await tester.tap(find.widgetWithText(NoteRow, 'Third'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(ValueKey('delete-note-${third.id}')));
      await tester.pumpAndSettle();

      // Nothing is gone until the question is answered.
      expect(notes.archivedNotes, hasLength(3));
      expect(find.text('Delete note?'), findsOneWidget);
      await confirm(tester);

      expect(
        notes.archivedNotes.map((note) => note.title),
        unorderedEquals(['First', 'Second']),
      );
      expect(notes.tombstones.single.id, third.id);
      expect(find.text('Note deleted'), findsOneWidget);
    });

    testWidgets('backing out of the question keeps the note', (tester) async {
      final archived = await openArchive(tester);
      await tester.tap(
        find.byKey(ValueKey('delete-note-${archived.first.id}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(notes.archivedNotes, hasLength(3));
      expect(notes.tombstones, isEmpty);
    });

    testWidgets('delete all empties it in one go', (tester) async {
      await openArchive(tester);

      await tester.tap(find.byKey(const ValueKey('archive-delete-all')));
      await tester.pumpAndSettle();
      expect(find.text('Empty the Archive?'), findsOneWidget);
      await confirm(tester);

      expect(notes.archivedNotes, isEmpty);
      expect(notes.tombstones, hasLength(3));
      expect(find.text('3 notes deleted'), findsOneWidget);
      // The notes that were never archived are untouched.
      expect(notes.notes, isEmpty);
    });

    testWidgets('several can be picked and restored together', (tester) async {
      final archived = await openArchive(tester);

      await tester.tap(find.byKey(const ValueKey('archive-start-selecting')));
      await tester.pumpAndSettle();
      // Picking replaces opening: the row's own actions are gone while it is
      // a checkbox.
      expect(
        find.byKey(ValueKey('delete-note-${archived.first.id}')),
        findsNothing,
      );

      await tester.tap(find.widgetWithText(NoteRow, 'First'));
      await tester.tap(find.widgetWithText(NoteRow, 'Second'));
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('archive-restore-checked')));
      await tester.pumpAndSettle();

      expect(
        notes.notes.map((note) => note.title),
        unorderedEquals(['First', 'Second']),
      );
      expect(notes.archivedNotes.single.title, 'Third');
      expect(find.text('2 notes restored'), findsOneWidget);
    });

    testWidgets('several can be picked and deleted together', (tester) async {
      await openArchive(tester);

      await tester.tap(find.byKey(const ValueKey('archive-start-selecting')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('archive-check-all')));
      await tester.pumpAndSettle();
      expect(find.text('3 selected'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('archive-delete-checked')));
      await tester.pumpAndSettle();
      expect(find.text('Delete 3 notes?'), findsOneWidget);
      await confirm(tester);

      expect(notes.archivedNotes, isEmpty);
      expect(notes.tombstones, hasLength(3));
    });

    testWidgets('leaving the archive puts the picking away', (tester) async {
      await openArchive(tester);
      await tester.tap(find.byKey(const ValueKey('archive-start-selecting')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(NoteRow, 'First'));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('sidebar-all-notes')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sidebar-archive')));
      await tester.pumpAndSettle();

      // Back to opening notes, with nothing held over from last time.
      expect(find.text('1 selected'), findsNothing);
      expect(
        find.byKey(const ValueKey('archive-start-selecting')),
        findsOneWidget,
      );
    });

    testWidgets('the strip still fits a sidebar dragged to its narrowest', (
      tester,
    ) async {
      await openArchive(tester);
      prefs.sidebarWidth = LayoutPrefs.minSidebarWidth;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const ValueKey('archive-start-selecting')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('archive-check-all')));
      await tester.pumpAndSettle();

      // Four actions and a count in 150pt, which is as narrow as the pane goes.
      expect(tester.takeException(), isNull);
      expect(find.text('3 selected'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('archive-delete-checked')),
        findsOneWidget,
      );
    });

    testWidgets('the ordinary list offers no delete at all', (tester) async {
      await pumpApp(tester);
      notes.create();
      notes.updateBody(notes.notes.first.id, 'Keep me');
      await tester.pumpAndSettle();

      final note = notes.notes.single;
      expect(find.byKey(ValueKey('delete-note-${note.id}')), findsNothing);
      expect(find.byKey(const ValueKey('archive-delete-all')), findsNothing);
      expect(find.byKey(ValueKey('archive-note-${note.id}')), findsOneWidget);
    });
  });

  group('compact editor', () {
    testWidgets('keeps the results divider in compact desktop windows', (
      tester,
    ) async {
      store.data['notes.v1'] = [
        {
          'id': 'desktop-compact',
          'body': 'Compact budget\n6 * 7',
          'createdAt': 1000,
          'updatedAt': 1000,
        },
      ];

      await pumpApp(tester, size: const Size(600, 630));

      expect(find.widgetWithText(ResultChip, '42'), findsOneWidget);
      expect(find.byType(GutterDivider), findsOneWidget);
      expect(
        tester
            .widget<MouseRegion>(
              find.byKey(const ValueKey('results-divider-hover')),
            )
            .cursor,
        SystemMouseCursors.resizeLeftRight,
      );
    });

    testWidgets('keeps the results divider out of phone-sized layouts', (
      tester,
    ) async {
      store.data['notes.v1'] = [
        {
          'id': 'phone-compact',
          'body': 'Phone budget\n6 * 7',
          'createdAt': 1000,
          'updatedAt': 1000,
        },
      ];

      await pumpApp(tester, size: const Size(420, 800));

      expect(find.widgetWithText(ResultChip, '42'), findsOneWidget);
      expect(find.byType(GutterDivider), findsNothing);
    });

    testWidgets('gives prose-only phone notes the full writing width', (
      tester,
    ) async {
      store.data['notes.v1'] = [
        {
          'id': 'phone-prose',
          'body': 'Field notes\nA quiet place to keep the whole thought.',
          'createdAt': 1000,
          'updatedAt': 1000,
        },
      ];

      await pumpApp(tester, size: const Size(420, 800));

      expect(find.byType(ResultsGutter), findsNothing);
      final editable = tester.getRect(find.byType(EditableText));
      expect(
        editable.width,
        greaterThan(350),
        reason: 'an empty results rail must not consume a third of the note',
      );
    });

    testWidgets('does not reserve an empty results rail on tablets', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      store.data['notes.v1'] = [
        {
          'id': 'tablet-journal',
          'body': 'September 2\nA calm place to keep the whole day.',
          'createdAt': 1000,
          'updatedAt': 1000,
        },
      ];

      await pumpApp(tester, size: const Size(1100, 760));

      expect(find.byType(ResultsGutter), findsNothing);
      expect(find.byType(GutterDivider), findsNothing);
      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byType(NoteEditor),
          matching: find.byType(TextField),
        ),
      );
      expect(
        field.controller!.text,
        'September 2\nA calm place to keep the whole day.\n\n',
      );
      expect(
        field.controller!.selection.baseOffset,
        field.controller!.text.length,
      );
      expect(field.focusNode!.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
    });

    testWidgets('keeps complete currency results visible on a wide phone', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      store.data['rates.v1'] = RateSnapshot(
        base: 'USD',
        date: '02 Sep 2026',
        fetchedAt: DateTime(2026, 9, 2, 12),
        rates: const {'EUR': 0.86},
        provider: RateProvider.frankfurter,
      ).toJson();
      store.data['notes.v1'] = [
        {
          'id': 'phone-currency',
          'body': 'Trip total\namount = 2288 eur',
          'createdAt': 1000,
          'updatedAt': 1000,
        },
      ];

      await pumpApp(tester, size: const Size(440, 956));

      final result = find.descendant(
        of: find.byType(ResultChip),
        matching: find.text('2,288.00 EUR'),
      );
      expect(result, findsOneWidget);
      expect(
        tester.renderObject<RenderParagraph>(result).didExceedMaxLines,
        isFalse,
        reason: 'the live result is the primary payoff and must not ellipsize',
      );

      expect(find.byKey(const ValueKey('note-total')), findsNothing);
    });

    testWidgets('puts image and mic in a scrollable phone footer', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      store.data['notes.v1'] = [
        {
          'id': 'phone-footer',
          'body': 'Phone budget\n6 * 7',
          'createdAt': 1000,
          'updatedAt': 1000,
        },
      ];

      await pumpApp(tester, size: const Size(320, 720));

      expect(find.byKey(const ValueKey('insert-image')), findsOneWidget);
      expect(find.byKey(const ValueKey('record-voice')), findsOneWidget);
      // Settings is in the notes drawer, not under the thumb that is writing.
      expect(find.byKey(const ValueKey('note-settings')), findsNothing);
      expect(find.byKey(const ValueKey('note-total')), findsNothing);

      final scroller = find.descendant(
        of: find.byType(NoteFooter),
        matching: find.byType(SingleChildScrollView),
      );
      expect(scroller, findsOneWidget);
      expect(
        tester.widget<SingleChildScrollView>(scroller).scrollDirection,
        Axis.horizontal,
      );
    });

    testWidgets('sits the phone footer on the bottom edge of the screen', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      store.data['notes.v1'] = [
        {
          'id': 'home-indicator',
          'body': 'Phone note',
          'createdAt': 1000,
          'updatedAt': 1000,
        },
      ];
      // The strip a phone keeps for its home indicator. Set before pumpApp,
      // which pins the ratio these physical pixels are read at to one and
      // resets the view afterwards.
      tester.view.padding = const FakeViewPadding(bottom: 34);

      await pumpApp(tester, size: const Size(390, 844));

      final footer = tester.getRect(find.byType(NoteFooter));
      expect(
        footer.bottom,
        closeTo(844, 0.01),
        reason: 'the bar belongs on the edge, not floating above it',
      );
      // The background grew into the strip. The controls did not follow it in:
      // a 44pt target under the home indicator is a target the system swipe
      // takes first.
      expect(footer.height, closeTo(56 + 34, 0.01));
      expect(
        tester.getRect(find.byKey(const ValueKey('insert-image'))).bottom,
        lessThanOrEqualTo(844 - 34),
      );
    });

    testWidgets(
      'opens the last opened note with the caret and focus at its end',
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
        // Last opened is the default startup behavior.
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
        expect(field.controller!.text, 'Created last\n2 + 2\n\n');
        expect(notes.byId('created-last')!.body, 'Created last\n2 + 2');
        expect(
          field.controller!.selection.baseOffset,
          field.controller!.text.length,
        );
        expect(field.focusNode!.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);
      },
    );

    testWidgets('ready-to-type behavior can be disabled on mobile', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      store.data['readyToTypeOnOpen.v1'] = false;
      store.data['notes.v1'] = [
        {
          'id': 'mobile-continue',
          'body': 'Keep my place',
          'createdAt': 1000,
          'updatedAt': 2000,
        },
      ];

      await pumpApp(tester, size: const Size(420, 800));

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, 'Keep my place');
      expect(field.focusNode!.hasFocus, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
    });

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

    testWidgets(
      'opens the notes drawer from a right swipe anywhere on Android',
      (tester) async {
        AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
        store.data['notes.v1'] = [
          {
            'id': 'swipe-open',
            'body': 'Swipe from here',
            'createdAt': 1000,
            'updatedAt': 1000,
          },
        ];

        await pumpApp(tester, size: const Size(420, 800));
        expect(find.byType(NoteRow), findsNothing);

        // This begins in the right-hand quarter, far outside Flutter's old
        // left-edge drawer strip, and still has enough deliberate travel.
        await tester.dragFrom(const Offset(330, 400), const Offset(80, 0));
        await tester.pumpAndSettle();

        expect(find.widgetWithText(NoteRow, 'Swipe from here'), findsOneWidget);
      },
    );

    testWidgets('leaves a swipe along the note footer to the footer', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      store.data['notes.v1'] = [
        {
          'id': 'footer-swipe',
          'body': 'Swipe from here',
          'createdAt': 1000,
          'updatedAt': 1000,
        },
      ];

      await pumpApp(tester, size: const Size(420, 800));
      expect(find.byType(NoteRow), findsNothing);

      // The footer's controls scroll sideways when they do not fit, and a
      // thumb rests exactly there. Reaching for the button past the end of the
      // row must not walk out of the note.
      final footer = tester.getRect(find.byType(NoteFooter));
      await tester.dragFrom(footer.center, const Offset(-160, 0));
      await tester.pumpAndSettle();
      expect(find.byType(NoteRow), findsNothing);
      expect(find.text('New note created'), findsNothing);

      await tester.dragFrom(footer.center, const Offset(160, 0));
      await tester.pumpAndSettle();
      expect(find.byType(NoteRow), findsNothing);

      // Above it the page still swipes.
      await tester.dragFrom(const Offset(330, 400), const Offset(80, 0));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(NoteRow, 'Swipe from here'), findsOneWidget);
    });

    testWidgets('two-finger trackpad swipes work in a narrow macOS window', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      store.data['notes.v1'] = [
        {
          'id': 'compact-mac-swipe',
          'body': 'Trackpad note',
          'createdAt': 1000,
          'updatedAt': 1000,
        },
      ];

      await pumpApp(tester, size: const Size(640, 800));
      expect(find.byType(NoteRow), findsNothing);

      final pointer = TestPointer(1, PointerDeviceKind.trackpad);
      const center = Offset(320, 400);
      await tester.sendEventToBinding(pointer.panZoomStart(center));
      await tester.sendEventToBinding(
        pointer.panZoomUpdate(
          center,
          pan: const Offset(-SidebarSwipe.threshold - 20, 0),
        ),
      );
      await tester.sendEventToBinding(pointer.panZoomEnd());
      await tester.pumpAndSettle();

      expect(find.widgetWithText(NoteRow, 'Trackpad note'), findsOneWidget);
    });

    testWidgets('previews and confirms a new note from a left swipe', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      store.data['notes.v1'] = [
        {
          'id': 'swipe-create',
          'body': 'Keep this note',
          'createdAt': 1000,
          'updatedAt': 1000,
        },
      ];

      await pumpApp(tester, size: const Size(420, 800));
      final swipe = await tester.startGesture(const Offset(320, 400));
      await swipe.moveBy(const Offset(-60, 0));
      await tester.pump();
      expect(find.text('Swipe left for new note'), findsOneWidget);
      expect(notes.notes, hasLength(1));

      await swipe.moveBy(const Offset(-100, 0));
      await tester.pump();
      expect(find.text('Release for new note'), findsOneWidget);
      expect(notes.notes, hasLength(1));

      await swipe.up();
      await tester.pump();

      expect(notes.notes, hasLength(2));
      expect(openNoteBody(tester), isEmpty);
      expect(find.text('New note created'), findsOneWidget);
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
      // The drawer's button leads, starting where the traffic lights end.
      expect(tester.getTopLeft(menu).dx, lessThan(tester.getTopLeft(add).dx));
      expect(
        tester.getTopLeft(menu).dx,
        greaterThanOrEqualTo(WindowChrome.trafficLightsWidth),
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
      // The bar it sits in reaches the edge all the same, the way the toolbar
      // reaches the top one: the strip is background of the footer, not a band
      // of empty page below it.
      expect(tester.getRect(find.byType(NoteFooter)).bottom, size.height);
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
