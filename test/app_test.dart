import 'dart:async';

import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/appearance.dart';
import 'package:kapy_notes/core/desktop_integration.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/editor_workspace.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/images/image_picker.dart';
import 'package:kapy_notes/sync/account.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/sync/key_store.dart';
import 'package:kapy_notes/sync/sync_state.dart';
import 'package:kapy_notes/ui/app_logo.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/editor/note_footer.dart';
import 'package:kapy_notes/ui/editor/results_gutter.dart';
import 'package:kapy_notes/ui/editor_panes.dart';
import 'package:kapy_notes/ui/empty_state.dart';
import 'package:kapy_notes/ui/hidden_notes_gate.dart';
import 'package:kapy_notes/core/window_chrome.dart';
import 'package:kapy_notes/ui/settings_dialog.dart';
import 'package:kapy_notes/ui/sidebar.dart';
import 'package:kapy_notes/ui/sidebar_swipe.dart';
import 'package:kapy_notes/ui/toolbar.dart';
import 'package:kapy_notes/ui/window_drag_area.dart';

import 'kapy_icon_finder.dart';
import 'sync/fake_server.dart';
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
  HiddenNotesGate? hiddenNotesGate,
  ImageFileAcquirer? imageAcquirer,
  Account? account,
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
      hiddenNotesGate: hiddenNotesGate,
      imageAcquirer: imageAcquirer,
      account: account,
    ),
  );
  await tester.pumpAndSettle();
}

class _HiddenGate implements HiddenNotesGate {
  _HiddenGate({this.allowConfigure = true, this.allowUnlock = true});

  bool allowConfigure;
  bool allowUnlock;
  int configureCalls = 0;
  int unlockCalls = 0;

  @override
  Future<bool> ensureConfigured(BuildContext context) async {
    configureCalls++;
    return allowConfigure;
  }

  @override
  Future<bool> unlock(BuildContext context) async {
    unlockCalls++;
    return allowUnlock;
  }
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

/// The text field of the note in the pane at [index], counting from the left.
TextField fieldInPane(WidgetTester tester, int index) =>
    tester.widget<TextField>(
      find.descendant(
        of: find.byType(EditorPaneFrame).at(index),
        matching: find.byType(TextField),
      ),
    );

/// What the note in the pane at [index] says, read as [openNoteBody] reads.
String bodyInPane(WidgetTester tester, int index) =>
    fieldInPane(tester, index).controller!.text.trimRight();

/// The one way into settings on every layout: the notes list's labelled row.
Finder settingsAffordance() => find.byKey(const ValueKey('sidebar-settings'));

/// Finds the notes-list toolbar action without coupling tests to the shortcut
/// suffix that its hover tooltip now teaches.
Finder notesToggleWithLabel(String label) => find.byWidgetPredicate(
  (widget) => widget is Tooltip && (widget.message ?? '').startsWith(label),
);

/// Puts the notes list on screen, wherever this layout keeps it.
///
/// The toolbar button says which state it is in, and it is the same button on
/// a window with the list closed and on a phone with the drawer shut.
Future<void> showNotesList(WidgetTester tester) async {
  final open = notesToggleWithLabel('Show notes');
  if (open.evaluate().isEmpty) return;
  await tester.tap(open.first);
  await tester.pumpAndSettle();
}

Future<void> openNoteActions(WidgetTester tester, String noteId) async {
  await tester.tap(find.byKey(ValueKey('note-actions-$noteId')));
  await tester.pumpAndSettle();
}

Future<void> pressShortcut(
  WidgetTester tester,
  ShortcutBinding binding, {
  bool settle = true,
}) async {
  if (binding.meta) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  }
  if (binding.control) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  }
  if (binding.alt) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  }
  if (binding.shift) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  }
  await tester.sendKeyDownEvent(binding.logicalKey);
  await tester.sendKeyUpEvent(binding.logicalKey);
  if (binding.shift) {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  }
  if (binding.alt) {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  }
  if (binding.control) {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  }
  if (binding.meta) {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  }
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
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

    await tester.tap(find.widgetWithText(FilledButton, 'New note'));
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

    await tester.tap(findKapyIcon(KapyIcons.addRounded).first);
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

    final pin = findKapyIcon(KapyIcons.pinOutlined);
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
    expect(findKapyIcon(KapyIcons.pinRounded), findsOneWidget);
    expect(findKapyIcon(KapyIcons.pinOutlined), findsNothing);
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
    expect(notesToggleWithLabel('Show notes'), findsOneWidget);
    expect(notesToggleWithLabel('Hide notes'), findsNothing);
  });

  testWidgets(
    'keeps Windows header actions after returning to a compact width',
    (tester) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);

      Finder toolbarIcon(KapyIconData icon) => find.descendant(
        of: find.byType(NoteToolbar),
        matching: findKapyIcon(icon),
      );

      await pumpApp(tester, size: const Size(620, 620), sidebarVisible: false);

      // Open the compact drawer, then let the window cross into the wide
      // layout while it is open. The new compact Scaffold starts closed when
      // the window is narrowed again, so its header actions must come back.
      await tester.tap(notesToggleWithLabel('Show notes'));
      await tester.pumpAndSettle();
      expect(toolbarIcon(KapyIcons.menuRounded), findsNothing);

      tester.view.physicalSize = const Size(760, 620);
      await tester.pumpAndSettle();
      expect(toolbarIcon(KapyIcons.menuRounded), findsOneWidget);

      tester.view.physicalSize = const Size(622, 620);
      await tester.pumpAndSettle();

      expect(toolbarIcon(KapyIcons.menuRounded), findsOneWidget);
      expect(toolbarIcon(KapyIcons.addRounded), findsOneWidget);
      expect(toolbarIcon(KapyIcons.peopleOutlined), findsOneWidget);
    },
  );

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
          findKapyIcon(KapyIcons.pinOutlined),
          findsOneWidget,
          reason: 'the pin went missing at $size',
        );
      }

      // The drawer hides the note actions while it covers them. The pin is
      // about the window, not the note, so it stays.
      await pumpApp(tester, size: const Size(700, 620));
      await tester.tap(notesToggleWithLabel('Show notes'));
      await tester.pumpAndSettle();
      expect(
        findKapyIcon(KapyIcons.pinOutlined),
        findsOneWidget,
        reason: 'the pin went with the drawer',
      );

      // A phone has no window to float, so the control is absent rather than
      // present and inert.
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      await pumpApp(tester, size: const Size(420, 800));
      expect(findKapyIcon(KapyIcons.pinOutlined), findsNothing);
      expect(findKapyIcon(KapyIcons.pinRounded), findsNothing);
    },
  );

  testWidgets('keeps exchange-rate status out of the toolbar', (tester) async {
    await pumpApp(tester);

    final toolbar = find.byType(NoteToolbar);
    final wordmark = find.byKey(const ValueKey('toolbar-app-wordmark'));
    final add = findKapyIcon(KapyIcons.addRounded).first;
    final menu = findKapyIcon(KapyIcons.menuRounded);

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
        matching: findKapyIcon(KapyIcons.moreRounded),
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
    Finder toolbarButton(KapyIconData icon) => find
        .ancestor(
          of: find.descendant(of: toolbar, matching: findKapyIcon(icon)),
          matching: find.byType(IconButton),
        )
        .first;

    expect(
      tester.getSize(toolbarButton(KapyIcons.addRounded)),
      const Size.square(24),
    );
    expect(
      tester.getSize(toolbarButton(KapyIcons.menuRounded)),
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
    final video = tester.getRect(footerButton('insert-video'));
    final mic = tester.getRect(footerButton('record-voice'));
    final formatting = tester.getRect(footerButton('formatting-toggle'));
    await tester.tap(footerButton('formatting-toggle'));
    await tester.pumpAndSettle();
    final style = tester.getRect(footerButton('format-style'));
    expect(video.left - image.right, 4);
    expect(mic.left - video.right, 4);
    expect(formatting.left - mic.right, 12);
    expect(style.left - formatting.right, 4);
    // The row starts at the bar's own edge inset: nothing precedes the three
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
    expect(notesToggleWithLabel('Show notes'), findsOneWidget);
  });

  testWidgets('types into a note, calculates, and derives its title', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'New note'));
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
    await tester.tap(find.widgetWithText(FilledButton, 'New note'));
    await tester.pumpAndSettle();

    await openSettings(tester);

    // Twice over now: the sidebar row that opened it, and the dialog's title.
    expect(find.text('Settings'), findsWidgets);
    expect(find.text('Notes list'), findsOneWidget);
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

    // With the window's own rows, at the foot of the pane.
    final sidebarToggle = find.byKey(const ValueKey('sidebar-toggle'));
    await tester.ensureVisible(sidebarToggle);
    await tester.pumpAndSettle();
    await tester.tap(sidebarToggle);
    await tester.pumpAndSettle();
    expect(prefs.sidebarVisible, isFalse);

    final reset = find.byKey(const ValueKey('reset-panel-widths'));
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
    await tester.tap(find.widgetWithText(FilledButton, 'New note'));
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

  testWidgets('settings keeps system labels regular or lighter', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'New note'));
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

    expect(weightOf('Settings'), FontWeight.w400);
    expect(weightOf('General'), FontWeight.w400);
    expect(weightOf('Appearance'), FontWeight.w400);
    expect(weightOf('OPENING'), FontWeight.w400);
    expect(weightOf('Daily separators'), FontWeight.w400);
    expect(weightOf('Done'), FontWeight.w400);
  });

  testWidgets('selects and persists the note time zone from settings', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'New note'));
    await tester.pumpAndSettle();
    await openSettings(tester);

    final setting = find.byKey(const ValueKey('time-zone-setting'));
    await tester.ensureVisible(setting);
    // Named for what it is; the zone in use is the line under the name.
    expect(
      find.descendant(of: setting, matching: find.text('Time zone')),
      findsOneWidget,
    );
    expect(find.textContaining('System time zone · UTC'), findsOneWidget);
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
    expect(find.text('Asia/Kolkata · UTC+05:30'), findsOneWidget);
    expect((LayoutPrefs(store)..load()).timeZoneId, 'Asia/Kolkata');
  });

  testWidgets('chooses a fixed startup note and can return to last opened', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'New note'));
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
    await tester.tap(find.widgetWithText(FilledButton, 'New note'));
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
    await tester.tap(find.widgetWithText(FilledButton, 'New note'));
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
    await tester.tap(find.widgetWithText(FilledButton, 'New note'));
    await tester.pumpAndSettle();

    TextField editor() => tester.widget<TextField>(
      find.descendant(
        of: find.byType(NoteEditor),
        matching: find.byType(TextField),
      ),
    );

    expect(prefs.writingFont, WritingFont.clean);
    expect(editor().style?.fontFamily, WritingFont.clean.fontFamily);

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

    final monospace = find.byKey(const ValueKey('writing-font-monospace'));
    await tester.ensureVisible(monospace);
    await tester.pumpAndSettle();
    await tester.tap(monospace);
    await tester.pumpAndSettle();
    expect(prefs.writingFont, WritingFont.monospace);
    expect(editor().style?.fontFamily, WritingFont.monospace.fontFamily);

    final restored = LayoutPrefs(store)..load();
    expect(restored.writingFont, WritingFont.monospace);
  });

  testWidgets('changes app text size live and persists it', (tester) async {
    await pumpApp(tester);
    notes.create(body: 'Readable everywhere');
    await tester.pumpAndSettle();

    final editor = find.byType(NoteEditor).first;
    expect(MediaQuery.textScalerOf(tester.element(editor)).scale(10), 10);

    await openSettings(tester, section: SettingsSection.appearance);
    final large = find.byKey(const ValueKey('app-text-size-large'));
    await tester.ensureVisible(large);
    await tester.tap(large);
    await tester.pumpAndSettle();

    expect(prefs.appTextSize, AppTextSize.large);
    expect(MediaQuery.textScalerOf(tester.element(editor)).scale(10), 12);
    expect(MediaQuery.textScalerOf(tester.element(large)).scale(10), 12);
    expect((LayoutPrefs(store)..load()).appTextSize, AppTextSize.large);
  });

  testWidgets('editor text shortcuts change, persist, and reset its size', (
    tester,
  ) async {
    await pumpApp(tester);
    notes.create(body: 'Zoom this note\n2 + 2');
    await tester.pumpAndSettle();

    double editorFontSize() => openNoteField(tester).style!.fontSize!;
    expect(editorFontSize(), WritingFont.clean.editorSize);

    await pressShortcut(
      tester,
      shortcuts.bindingFor(ShortcutAction.increaseEditorTextSize)!,
    );
    expect(prefs.editorTextScale, 1.1);
    expect(
      editorFontSize(),
      closeTo(WritingFont.clean.editorSize * 1.1, 0.001),
    );
    expect((LayoutPrefs(store)..load()).editorTextScale, 1.1);

    await pressShortcut(
      tester,
      shortcuts.bindingFor(ShortcutAction.decreaseEditorTextSize)!,
    );
    expect(prefs.editorTextScale, 1);

    await pressShortcut(
      tester,
      shortcuts.bindingFor(ShortcutAction.increaseEditorTextSize)!,
    );
    await pressShortcut(
      tester,
      shortcuts.bindingFor(ShortcutAction.resetEditorTextSize)!,
    );
    expect(prefs.editorTextScale, 1);
    expect(editorFontSize(), WritingFont.clean.editorSize);
  });

  testWidgets('transparency thins the whole window, and persists', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'New note'));
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
    await tester.tap(find.widgetWithText(FilledButton, 'New note'));
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
    await tester.tap(find.widgetWithText(FilledButton, 'New note'));
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

    await tester.tap(find.widgetWithText(FilledButton, 'New note'));
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
    await tester.tap(find.widgetWithText(FilledButton, 'New note'));
    await tester.pumpAndSettle();
    await openSettings(tester, section: SettingsSection.shortcuts);

    // The shortcuts another app can refuse lead the pane, then the in-app
    // keys by what they act on: the list, the panes beside it, the window,
    // what goes into a note, and how it is formatted.
    const headings = [
      'SYSTEM-WIDE',
      'NOTES',
      'SPLIT VIEW',
      'WINDOW',
      'EDITOR',
      'INSERT',
      'FORMATTING',
    ];
    for (final heading in headings) {
      expect(find.text(heading), findsOneWidget);
    }
    for (var index = 1; index < headings.length; index++) {
      expect(
        tester.getTopLeft(find.text(headings[index - 1])).dy,
        lessThan(tester.getTopLeft(find.text(headings[index])).dy),
      );
    }
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
    expect(findKapyIcon(KapyIcons.pinOutlined), findsOneWidget);

    await tester.tap(findKapyIcon(KapyIcons.pinOutlined));
    await tester.pumpAndSettle();

    // The window really did go on top; the icon has to say so in the same
    // frame, without waiting for something else to redraw the page.
    expect(prefs.alwaysOnTop, isTrue);
    expect(findKapyIcon(KapyIcons.pinRounded), findsOneWidget);

    await tester.tap(findKapyIcon(KapyIcons.pinRounded));
    await tester.pumpAndSettle();

    expect(prefs.alwaysOnTop, isFalse);
    expect(findKapyIcon(KapyIcons.pinOutlined), findsOneWidget);
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

  testWidgets(
    'Ctrl+Tab previews, commits on Ctrl-up, and toggles recent notes',
    (tester) async {
      await pumpApp(tester);
      final alpha = notes.create(body: 'alpha');
      final bravo = notes.create(body: 'bravo');
      final charlie = notes.create(body: 'charlie');
      await tester.pumpAndSettle();

      // Switching is its own recency order. It must not forge an edit merely to
      // move a note to the front of that order.
      expect(notes.notes.map((note) => note.body), [
        'charlie',
        'bravo',
        'alpha',
      ]);
      final updatedAt = {
        for (final note in notes.notes) note.id: note.updatedAt,
      };
      final openedBeforeSwitch = prefs.lastOpenedNoteId;

      Future<void> tabWhileControlIsDown({bool shift = false}) async {
        if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.tab);
        if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pumpAndSettle();
      }

      List<String> sidebarOrder() => tester
          .widgetList<NoteRow>(find.byType(NoteRow))
          .map((row) => row.note.body)
          .toList();

      expect(openNoteBody(tester), 'alpha');
      expect(openNoteField(tester).focusNode?.hasFocus, isTrue);
      expect(sidebarOrder(), ['alpha', 'charlie', 'bravo']);

      // The first session has no usage history yet, so it falls back to the
      // visible list after the note already open. Further Tabs preview against
      // one frozen order while Control remains down.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tabWhileControlIsDown();
      expect(openNoteBody(tester), 'charlie');
      expect(openNoteField(tester).focusNode?.hasFocus, isFalse);
      expect(sidebarOrder(), ['alpha', 'charlie', 'bravo']);
      await tabWhileControlIsDown();
      expect(openNoteBody(tester), 'bravo');
      expect(openNoteField(tester).focusNode?.hasFocus, isFalse);
      expect(prefs.lastOpenedNoteId, openedBeforeSwitch);
      expect(sidebarOrder(), ['alpha', 'charlie', 'bravo']);

      // Releasing the switching modifier is the commit: the previewed editor
      // gets focus, and this note becomes the most recently used one without
      // disturbing the content store's newest-edited ordering.
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(openNoteField(tester).focusNode?.hasFocus, isTrue);
      expect(prefs.lastOpenedNoteId, bravo.id);
      expect(notes.notes.map((note) => note.id), [
        charlie.id,
        bravo.id,
        alpha.id,
      ]);
      expect({
        for (final note in notes.notes) note.id: note.updatedAt,
      }, updatedAt);
      expect(sidebarOrder(), ['bravo', 'alpha', 'charlie']);

      // The note just left is now second in MRU order, so one more Ctrl+Tab is
      // a true two-note toggle rather than another step through the sidebar.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tabWhileControlIsDown();
      expect(openNoteBody(tester), 'alpha');
      expect(openNoteField(tester).focusNode?.hasFocus, isFalse);
      expect(sidebarOrder(), ['bravo', 'alpha', 'charlie']);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(openNoteBody(tester), 'alpha');
      expect(openNoteField(tester).focusNode?.hasFocus, isTrue);
      expect(prefs.lastOpenedNoteId, alpha.id);
      expect(sidebarOrder(), ['alpha', 'bravo', 'charlie']);

      // Shift only reverses direction. Letting go of it must not accidentally
      // commit a Ctrl+Shift+Tab session while Control is still held.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(openNoteBody(tester), 'charlie');
      expect(openNoteField(tester).focusNode?.hasFocus, isFalse);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(openNoteField(tester).focusNode?.hasFocus, isFalse);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(openNoteField(tester).focusNode?.hasFocus, isTrue);
      expect(sidebarOrder(), ['charlie', 'alpha', 'bravo']);
    },
  );

  testWidgets('Ctrl+Tab follows the visible row below a pinned note', (
    tester,
  ) async {
    await pumpApp(tester);
    final alpha = notes.create(body: 'alpha');
    notes.create(body: 'bravo');
    final charlie = notes.create(body: 'charlie');
    await tester.pumpAndSettle();

    await openNoteActions(tester, alpha.id);
    await tester.tap(find.byKey(ValueKey('pin-note-${alpha.id}')));
    await tester.pumpAndSettle();

    // Opening Charlie makes the underlying MRU order Charlie, Alpha, Bravo,
    // while the pinned section visibly paints Alpha, Charlie, Bravo. Scrubbing
    // back to Alpha preserves that disagreement until the switch commits.
    await tester.tap(find.widgetWithText(NoteRow, 'charlie'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(openNoteBody(tester), 'alpha');
    expect(
      tester
          .widgetList<NoteRow>(find.byType(NoteRow))
          .map((row) => row.note.body)
          .toList(),
      ['alpha', 'charlie', 'bravo'],
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();

    expect(openNoteBody(tester), 'charlie');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(prefs.lastOpenedNoteId, charlie.id);
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

    // The same key carrying Ctrl belongs to switching between notes. It has to
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

  testWidgets('a Command-based custom note switch commits on Command-up', (
    tester,
  ) async {
    shortcuts.load();
    shortcuts.update(
      ShortcutAction.nextNote,
      const ShortcutBinding(
        logicalKey: LogicalKeyboardKey.keyJ,
        physicalKey: PhysicalKeyboardKey.keyJ,
        meta: true,
      ),
    );
    await pumpApp(tester);
    notes.create(body: 'alpha');
    notes.create(body: 'bravo');
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyJ);
    await tester.pumpAndSettle();
    expect(openNoteBody(tester), 'bravo');
    expect(openNoteField(tester).focusNode?.hasFocus, isFalse);

    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(openNoteField(tester).focusNode?.hasFocus, isTrue);
  });

  testWidgets('Ctrl+Tab keeps split panes stable while switching every note', (
    tester,
  ) async {
    await pumpApp(tester);
    final alpha = notes.create(body: 'Alpha');
    final bravo = notes.create(body: 'Bravo');
    final charlie = notes.create(body: 'Charlie');
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(NoteRow, 'Alpha'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('toolbar-split-view')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(NoteRow, 'Bravo'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pane-title-0')));
    await tester.pumpAndSettle();

    List<String> panes() => [
      for (var index = 0; index < 2; index++) bodyInPane(tester, index),
    ];
    String selectedRow() => tester
        .widgetList<NoteRow>(find.byType(NoteRow))
        .singleWhere((row) => row.selected)
        .note
        .body;
    Future<void> tab() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
    }

    expect(panes(), ['Alpha', 'Bravo']);
    expect(selectedRow(), 'Alpha');
    expect(fieldInPane(tester, 0).focusNode!.hasFocus, isTrue);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tab();

    // An already-visible note participates normally. Preview only activates
    // its pane; it does not duplicate it or leave the caret in the old pane.
    expect(panes(), ['Alpha', 'Bravo']);
    expect(selectedRow(), 'Bravo');
    expect(fieldInPane(tester, 0).focusNode!.hasFocus, isFalse);
    expect(fieldInPane(tester, 1).focusNode!.hasFocus, isFalse);

    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(prefs.lastOpenedNoteId, bravo.id);
    expect(fieldInPane(tester, 1).focusNode!.hasFocus, isTrue);
    expect(panes(), ['Alpha', 'Bravo']);

    // Begin again in the left pane to exercise a longer held session.
    await tester.tap(find.byKey(const ValueKey('pane-title-0')));
    await tester.pumpAndSettle();
    expect(prefs.lastOpenedNoteId, alpha.id);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tab();

    await tab();

    // Cycling onward previews an unopened note in the pane where the gesture
    // began. The other pane remains Bravo instead of being progressively
    // replaced as focus moves through the preview sequence.
    expect(panes(), ['Charlie', 'Bravo']);
    expect(selectedRow(), 'Charlie');
    expect(fieldInPane(tester, 0).focusNode!.hasFocus, isFalse);
    expect(fieldInPane(tester, 1).focusNode!.hasFocus, isFalse);

    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(prefs.lastOpenedNoteId, charlie.id);
    expect(fieldInPane(tester, 0).focusNode!.hasFocus, isTrue);
    expect(panes(), ['Charlie', 'Bravo']);

    // The next completed gesture returns to the note just replaced, while the
    // neighbouring pane is still untouched.
    await pressShortcut(tester, shortcuts.bindingFor(ShortcutAction.nextNote)!);
    expect(prefs.lastOpenedNoteId, alpha.id);
    expect(fieldInPane(tester, 0).focusNode!.hasFocus, isTrue);
    expect(panes(), ['Alpha', 'Bravo']);
    expect(notes.byId(bravo.id), isNotNull);
  });

  testWidgets('each pane holds one note, and a note is never open twice', (
    tester,
  ) async {
    await pumpApp(tester);
    final first = notes.create(body: 'First note');
    final second = notes.create(body: 'Second note');
    final third = notes.create(body: 'Third note');
    await tester.pumpAndSettle();

    // A list click shows the note in place of the one on screen. Nothing
    // piles up behind it, and a lone pane has no title bar: it looks exactly
    // as the editor always has.
    await tester.tap(find.widgetWithText(NoteRow, 'Second note'));
    await tester.pumpAndSettle();
    expect(openNoteBody(tester), 'Second note');
    expect(find.byType(EditorPaneFrame), findsOneWidget);
    expect(find.byKey(const ValueKey('pane-title-0')), findsNothing);

    // The title bar's split button opens an empty pane beside the note, and
    // the list fills whichever pane has the focus: the new one.
    await tester.tap(find.byKey(const ValueKey('toolbar-split-view')));
    await tester.pumpAndSettle();
    expect(find.byType(EditorPaneFrame), findsNWidgets(2));
    expect(find.text('Choose a note'), findsOneWidget);
    expect(
      find.byTooltip('Choose a note for this pane first'),
      findsOneWidget,
      reason: 'no second blank beside the first',
    );

    await tester.tap(find.widgetWithText(NoteRow, 'Third note'));
    await tester.pumpAndSettle();
    expect(bodyInPane(tester, 0), 'Second note');
    expect(bodyInPane(tester, 1), 'Third note');

    // A note already on screen is selected where it is, never opened again,
    // and the list rings the one open beside it. The sidebar keeps the
    // keyboard until Right hands it to that editor.
    await tester.tap(find.widgetWithText(NoteRow, 'Second note'));
    await tester.pumpAndSettle();
    expect(find.byType(NoteEditor), findsNWidgets(2));
    expect(bodyInPane(tester, 1), 'Third note');
    expect(fieldInPane(tester, 0).focusNode!.hasFocus, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(fieldInPane(tester, 0).focusNode!.hasFocus, isTrue);
    NoteRow row(String title) =>
        tester.widget<NoteRow>(find.widgetWithText(NoteRow, title));
    expect(row('Third note').openElsewhere, isTrue);
    expect(row('Second note').openElsewhere, isFalse);

    // The menu offers the side only to a note that is not on screen.
    await tester.tap(
      find.widgetWithText(NoteRow, 'Third note'),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('Open to the side'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await tester.tap(
      find.widgetWithText(NoteRow, 'First note'),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('Open in New Tab'), findsNothing);
    await tester.tap(find.text('Open to the side'));
    await tester.pumpAndSettle();
    expect(
      [for (var index = 0; index < 3; index++) bodyInPane(tester, index)],
      ['Second note', 'First note', 'Third note'],
    );
    expect(fieldInPane(tester, 1).focusNode!.hasFocus, isTrue);

    // Closing a pane takes the note off the screen and nothing else.
    await tester.tap(find.byKey(const ValueKey('close-pane-2')));
    await tester.pumpAndSettle();
    expect(find.byType(NoteEditor), findsNWidgets(2));
    expect(notes.byId(third.id)?.body, 'Third note');
    expect(notes.byId(first.id)?.isArchived, isFalse);
    expect(notes.byId(second.id)?.isArchived, isFalse);
  });

  testWidgets('three panes answer the split, focus and close shortcuts', (
    tester,
  ) async {
    await pumpApp(tester, size: const Size(1400, 800));
    notes.create(body: 'Left note');
    final middle = notes.create(body: 'Middle note');
    final right = notes.create(body: 'Right note');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(NoteRow, 'Left note'));
    await tester.pumpAndSettle();

    Future<void> press(ShortcutAction action) =>
        pressShortcut(tester, shortcuts.bindingFor(action)!);

    // With one pane there is nothing for the close chord to close.
    await press(ShortcutAction.closePane);
    expect(find.byType(EditorPaneFrame), findsOneWidget);

    await press(ShortcutAction.splitEditor);
    await tester.tap(find.widgetWithText(NoteRow, 'Middle note'));
    await tester.pumpAndSettle();
    await press(ShortcutAction.splitEditor);
    await tester.tap(find.widgetWithText(NoteRow, 'Right note'));
    await tester.pumpAndSettle();
    expect(
      [for (var index = 0; index < 3; index++) bodyInPane(tester, index)],
      ['Left note', 'Middle note', 'Right note'],
    );

    // Three is as many as there are.
    await press(ShortcutAction.splitEditor);
    expect(find.byType(EditorPaneFrame), findsNWidgets(3));
    expect(find.byTooltip('Up to three notes side by side'), findsOneWidget);

    await press(ShortcutAction.focusSecondPane);
    expect(fieldInPane(tester, 1).focusNode!.hasFocus, isTrue);
    await press(ShortcutAction.focusThirdPane);
    expect(fieldInPane(tester, 2).focusNode!.hasFocus, isTrue);
    await press(ShortcutAction.focusFirstPane);
    expect(fieldInPane(tester, 0).focusNode!.hasFocus, isTrue);

    // Every pane is a live editor on its own note.
    await tester.enterText(
      find.descendant(
        of: find.byType(EditorPaneFrame).at(1),
        matching: find.byType(TextField),
      ),
      'Middle note, edited',
    );
    await tester.pumpAndSettle();
    expect(notes.byId(middle.id)?.body, 'Middle note, edited');
    expect(bodyInPane(tester, 0), 'Left note');
    expect(bodyInPane(tester, 2), 'Right note');

    List<num> savedWeights() =>
        ((store.data[EditorWorkspace.storeKey] as Map)['weights'] as List)
            .cast<num>();

    // A divider resizes the two panes either side of it, and is remembered.
    final before = savedWeights();
    await tester.drag(
      find.byKey(const ValueKey('editor-split-divider-0')),
      const Offset(60, 0),
    );
    await tester.pumpAndSettle();
    final after = savedWeights();
    expect(after[0], greaterThan(before[0]));
    expect(after[1], lessThan(before[1]));
    expect(after[2], closeTo(before[2], 1e-9));

    // A double click evens every pane out.
    final divider = find.byKey(const ValueKey('editor-split-divider-1'));
    await tester.tap(divider);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(divider);
    await tester.pumpAndSettle();
    for (final weight in savedWeights()) {
      expect(weight, closeTo(1 / 3, 1e-9));
    }

    // Closing the focused pane hands the focus to the pane beside it, and
    // leaves its note exactly as it was.
    await press(ShortcutAction.focusThirdPane);
    await press(ShortcutAction.closePane);
    expect(find.byType(EditorPaneFrame), findsNWidgets(2));
    expect(notes.byId(right.id)?.body, 'Right note');
    expect(fieldInPane(tester, 1).focusNode!.hasFocus, isTrue);

    // A pane that is not there cannot take the focus.
    await press(ShortcutAction.focusThirdPane);
    expect(fieldInPane(tester, 1).focusNode!.hasFocus, isTrue);
  });

  testWidgets('dragging a note opens it beside a pane, in place, or moves it', (
    tester,
  ) async {
    await pumpApp(tester, size: const Size(1400, 800));
    final alpha = notes.create(body: 'Alpha');
    notes.create(body: 'Bravo');
    notes.create(body: 'Charlie');
    notes.create(body: 'Delta');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(NoteRow, 'Alpha'));
    await tester.pumpAndSettle();

    List<String> panes() => [
      for (
        var index = 0;
        index < find.byType(EditorPaneFrame).evaluate().length;
        index++
      )
        bodyInPane(tester, index),
    ];

    Offset spot(int pane, PaneDropZone zone) {
      final rect = tester.getRect(find.byType(EditorPaneFrame).at(pane));
      return switch (zone) {
        PaneDropZone.left => rect.centerLeft + const Offset(24, 0),
        PaneDropZone.center => rect.center,
        PaneDropZone.right => rect.centerRight - const Offset(24, 0),
      };
    }

    // Drags with a mouse, and reads what the highlight promises before
    // letting go: a drop is never a guess.
    Future<void> dragTo(
      Finder from,
      Offset to, {
      required String promise,
    }) async {
      final gesture = await tester.startGesture(
        tester.getCenter(from),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(12, 0));
      await tester.pump();
      await gesture.moveTo(to);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text(promise), findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text(promise), findsNothing);
    }

    // Beside a pane: a new pane, in that half of it.
    await dragTo(
      find.widgetWithText(NoteRow, 'Bravo'),
      spot(0, PaneDropZone.right),
      promise: 'Open on the right',
    );
    expect(panes(), ['Alpha', 'Bravo']);

    await dragTo(
      find.widgetWithText(NoteRow, 'Charlie'),
      spot(0, PaneDropZone.left),
      promise: 'Open on the left',
    );
    expect(panes(), ['Charlie', 'Alpha', 'Bravo']);

    // Three open leave no room beside, so an edge means the pane itself.
    await dragTo(
      find.widgetWithText(NoteRow, 'Delta'),
      spot(1, PaneDropZone.right),
      promise: 'Open here',
    );
    expect(panes(), ['Charlie', 'Delta', 'Bravo']);
    expect(notes.byId(alpha.id)?.isArchived, isFalse);

    // A pane moves by its title bar.
    await dragTo(
      find.byKey(const ValueKey('pane-title-2')),
      spot(0, PaneDropZone.left),
      promise: 'Move to the left',
    );
    expect(panes(), ['Bravo', 'Charlie', 'Delta']);

    // A note already open trades places with the one it lands on.
    await dragTo(
      find.widgetWithText(NoteRow, 'Delta'),
      spot(0, PaneDropZone.center),
      promise: 'Swap places',
    );
    expect(panes(), ['Delta', 'Charlie', 'Bravo']);
    expect(find.byType(NoteEditor), findsNWidgets(3));

    // Over its own pane a note promises nothing, and changes nothing.
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('pane-title-1'))),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    for (final promise in ['Open here', 'Swap places', 'Move here']) {
      expect(find.text(promise), findsNothing);
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(panes(), ['Delta', 'Charlie', 'Bravo']);
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

  testWidgets('the notes shortcut opens and closes the compact drawer', (
    tester,
  ) async {
    await pumpApp(tester, size: const Size(600, 700));
    notes.create(body: 'Compact note');
    await tester.pumpAndSettle();

    final scaffold = tester.state<ScaffoldState>(find.byType(Scaffold).first);
    final binding = shortcuts.bindingFor(ShortcutAction.toggleSidebar)!;
    expect(scaffold.isDrawerOpen, isFalse);

    await pressShortcut(tester, binding);
    expect(scaffold.isDrawerOpen, isTrue);

    await pressShortcut(tester, binding);
    expect(scaffold.isDrawerOpen, isFalse);
  });

  testWidgets('the hamburger tooltip includes its current shortcut', (
    tester,
  ) async {
    await pumpApp(tester);

    final menu = findKapyIcon(KapyIcons.menuRounded).first;
    final tooltip = tester.widget<Tooltip>(
      find.ancestor(of: menu, matching: find.byType(Tooltip)).first,
    );
    expect(
      tooltip.message,
      contains(
        shortcuts.bindingFor(ShortcutAction.toggleSidebar)!.displayLabel,
      ),
    );
  });

  testWidgets(
    'toolbar settings sits beside notes, teaches its shortcut, and opens',
    (tester) async {
      await pumpApp(tester);

      final toolbar = find.byType(NoteToolbar);
      final menu = find.descendant(
        of: toolbar,
        matching: findKapyIcon(KapyIcons.menuRounded),
      );
      final settings = find.descendant(
        of: toolbar,
        matching: findKapyIcon(KapyIcons.settingsOutlined),
      );
      expect(settings, findsOneWidget);
      expect(
        tester.getCenter(settings).dx,
        greaterThan(tester.getCenter(menu).dx),
      );
      final tooltip = tester.widget<Tooltip>(
        find.ancestor(of: settings, matching: find.byType(Tooltip)).first,
      );
      expect(
        tooltip.message,
        contains(
          shortcuts.bindingFor(ShortcutAction.openSettings)!.displayLabel,
        ),
      );

      await tester.tap(settings);
      await tester.pumpAndSettle();
      expect(find.byType(SettingsDialog), findsOneWidget);
    },
  );

  testWidgets('desktop Settings has room for a calm two-pane layout', (
    tester,
  ) async {
    await pumpApp(tester, size: const Size(1100, 760));
    await openSettings(tester);

    expect(
      tester.getSize(find.byKey(const ValueKey('settings-dialog-content'))),
      const Size(600, 520),
    );
  });

  testWidgets('note actions fade in inside a sidebar that can hold them', (
    tester,
  ) async {
    await pumpApp(tester, size: const Size(760, 520));
    notes.create(body: 'Context menu');
    await tester.pumpAndSettle();
    final note = notes.notes.single;

    await openNoteActions(tester, note.id);

    final menu = find.byKey(const ValueKey('kapy-context-menu'));
    expect(menu, findsOneWidget);
    expect(
      find.ancestor(of: menu, matching: find.byType(FadeTransition)),
      findsOneWidget,
    );
    final menuRect = tester.getRect(menu);
    final rowRect = tester.getRect(find.byType(NoteRow).first);
    expect(menuRect.width, lessThanOrEqualTo(208));
    expect(menuRect.left, greaterThanOrEqualTo(rowRect.left));
    expect(menuRect.right, lessThanOrEqualTo(rowRect.right));
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

  testWidgets('global search reveals a hidden sidebar and finds nested content', (
    tester,
  ) async {
    await pumpApp(tester, sidebarVisible: false);
    notes.create(
      body:
          '# Launch plan\n- Website\n  - Accessibility\n    - Check contrast tokens',
    );
    notes.create(body: 'Weekend errands\n- Buy coffee');
    await tester.pumpAndSettle();

    final binding = shortcuts.bindingFor(ShortcutAction.findNotes)!;
    await pressShortcut(tester, binding);

    expect(prefs.sidebarVisible, isTrue);
    final search = find.byKey(const ValueKey('sidebar-search-field'));
    expect(search, findsOneWidget);
    expect(tester.widget<TextField>(search).focusNode?.hasFocus, isTrue);
    expect(find.text(binding.displayLabel), findsOneWidget);

    await tester.enterText(search, 'launch contrast');
    await tester.pumpAndSettle();

    expect(find.byType(NoteRow), findsOneWidget);
    expect(
      find.widgetWithText(NoteRow, '- Check contrast tokens'),
      findsOneWidget,
    );
  });

  testWidgets('global search opens and focuses the compact notes drawer', (
    tester,
  ) async {
    await pumpApp(tester, size: const Size(600, 760));
    notes.create(body: 'Compact search result');
    await tester.pumpAndSettle();

    await pressShortcut(
      tester,
      shortcuts.bindingFor(ShortcutAction.findNotes)!,
    );

    final search = find.byKey(const ValueKey('sidebar-search-field'));
    expect(search, findsOneWidget);
    expect(tester.widget<TextField>(search).focusNode?.hasFocus, isTrue);
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

  testWidgets('leaves breathing room around the sidebar search row', (
    tester,
  ) async {
    await pumpApp(tester);

    final sidebar = tester.getRect(find.byType(Sidebar));
    final search = tester.getRect(
      find.byKey(const ValueKey('sidebar-search-field')),
    );
    final add = tester.getRect(find.byKey(const ValueKey('sidebar-new-note')));

    expect(search.top - sidebar.top, greaterThanOrEqualTo(12));
    expect(search.left - sidebar.left, greaterThanOrEqualTo(12));
    expect(sidebar.right - add.right, greaterThanOrEqualTo(12));
    expect(add.center.dy, closeTo(search.center.dy, 0.5));
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

  group('leaving a new note without writing in it', () {
    Finder plus() => find.byKey(const ValueKey('sidebar-new-note'));
    Finder row(String title) =>
        find.widgetWithText(NoteRow, title).hitTestable().first;

    testWidgets('deletes it, so the list keeps only written notes', (
      tester,
    ) async {
      await pumpApp(tester);
      notes.create(body: 'Something written');
      await tester.pumpAndSettle();
      final before = notes.notes.length;

      await tester.tap(plus());
      await tester.pumpAndSettle();
      final blank = notes.notes.first;
      expect(blank.isEmpty, isTrue);
      expect(notes.notes, hasLength(before + 1));

      await tester.tap(row('Something written'));
      await tester.pumpAndSettle();

      expect(notes.byId(blank.id), isNull);
      expect(notes.notes, hasLength(before));
      // Gone everywhere, not only here.
      expect(notes.tombstones.map((stone) => stone.id), contains(blank.id));
    });

    testWidgets('keeps it once anything is written', (tester) async {
      await pumpApp(tester);
      notes.create(body: 'Something written');
      await tester.pumpAndSettle();

      await tester.tap(plus());
      await tester.pumpAndSettle();
      final started = notes.notes.first;
      notes.updateBody(started.id, 'Now it says something');
      await tester.pumpAndSettle();

      await tester.tap(row('Something written'));
      await tester.pumpAndSettle();
      expect(notes.byId(started.id), isNotNull);
    });

    testWidgets('leaves alone a blank note it did not just make', (
      tester,
    ) async {
      await pumpApp(tester);
      // As though it arrived from another device, or was emptied by hand.
      final arrived = notes.create();
      notes.create(body: 'Something written');
      await tester.pumpAndSettle();

      await tester.tap(row('Something written'));
      await tester.pumpAndSettle();
      expect(notes.byId(arrived.id), isNotNull);
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
    await openNoteActions(tester, reference.id);
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

    await openNoteActions(tester, reference.id);
    expect(find.text('Unpin note'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('pin-note-${reference.id}')));
    await tester.pumpAndSettle();

    expect(find.text('Pinned'), findsNothing);
    // Removing the section does not erase open recency: Reference is still
    // the note the user most recently opened, so it remains first.
    expect(rowTitles(), ['Reference', 'Today']);
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
    await openNoteActions(tester, third.id);
    await tester.tap(find.byKey(ValueKey('archive-note-${third.id}')));
    await tester.pumpAndSettle();

    expect(notes.notes.map((n) => n.title), ['Second', 'First']);
    expect(notes.archivedNotes.single.title, 'Third');
    expect(find.widgetWithText(NoteRow, 'Third'), findsNothing);
    expect(find.byType(NoteEditor), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('sidebar-archive')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(NoteRow, 'Third'), findsOneWidget);

    await openNoteActions(tester, third.id);
    await tester.tap(find.byKey(ValueKey('restore-note-${third.id}')));
    await tester.pumpAndSettle();
    expect(notes.archivedNotes, isEmpty);
    expect(notes.notes.first.title, 'Third');
  });

  testWidgets(
    'Hidden Notes authenticates every entry and locks when the app leaves',
    (tester) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      await notes.load();
      notes.create(body: 'Visible note');
      final private = notes.create(body: 'Private note');
      final gate = _HiddenGate();
      await pumpApp(tester, hiddenNotesGate: gate);

      final hiddenShortcut = shortcuts.bindingFor(
        ShortcutAction.toggleHiddenFolder,
      )!;
      expect(prefs.hiddenFolderVisible, isTrue);
      expect(find.byKey(const ValueKey('sidebar-hidden-notes')), findsNothing);

      await openNoteActions(tester, private.id);
      await tester.tap(find.byKey(ValueKey('hide-note-${private.id}')));
      await tester.pumpAndSettle();
      expect(gate.configureCalls, 1);
      expect(notes.hiddenNotes.single.id, private.id);
      expect(notes.search('Private'), isEmpty);
      expect(
        find.text('Moved to Hidden Notes. Open Hidden Notes from the sidebar.'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('sidebar-hidden-notes')),
        findsOneWidget,
      );

      await pressShortcut(tester, hiddenShortcut);
      expect(gate.unlockCalls, 0, reason: 'the shortcut only hides the row');
      expect(prefs.hiddenFolderVisible, isFalse);
      expect(find.byKey(const ValueKey('sidebar-hidden-notes')), findsNothing);

      await pressShortcut(tester, hiddenShortcut);
      expect(prefs.hiddenFolderVisible, isTrue);
      expect(
        find.byKey(const ValueKey('sidebar-hidden-notes')),
        findsOneWidget,
      );
      expect(find.text(hiddenShortcut.displayLabel), findsOneWidget);
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('sidebar-hidden-notes')))
            .dy,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('sidebar-archive'))).dy,
        ),
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('sidebar-hidden-notes')),
          matching: find.text('1'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('sidebar-hidden-notes')));
      await tester.pumpAndSettle();
      expect(gate.unlockCalls, 1);
      expect(find.widgetWithText(NoteRow, 'Private note'), findsOneWidget);
      expect(openNoteBody(tester), 'Private note');

      await tester.tap(find.byKey(const ValueKey('sidebar-all-notes')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sidebar-hidden-notes')));
      await tester.pumpAndSettle();
      expect(gate.unlockCalls, 2, reason: 'entering again must authenticate');

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(NoteRow, 'Private note'), findsNothing);
      expect(
        find.byKey(const ValueKey('sidebar-hidden-notes')),
        findsOneWidget,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      await pressShortcut(tester, hiddenShortcut);
      expect(find.byKey(const ValueKey('sidebar-hidden-notes')), findsNothing);
      expect(gate.unlockCalls, 2, reason: 'hiding the row must not enter it');
      await pressShortcut(tester, hiddenShortcut);
      expect(
        find.byKey(const ValueKey('sidebar-hidden-notes')),
        findsOneWidget,
      );
      expect(
        gate.unlockCalls,
        2,
        reason: 'revealing the row must not enter it',
      );
    },
  );

  testWidgets('desktop Settings can reveal Hidden Notes in the sidebar', (
    tester,
  ) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    await notes.load();
    final private = notes.create(body: 'Private note');
    notes.hide(private.id);
    prefs.load();
    prefs.hiddenFolderVisible = false;
    await pumpApp(tester);

    expect(prefs.hiddenFolderVisible, isFalse);
    expect(find.byKey(const ValueKey('sidebar-hidden-notes')), findsNothing);

    await openSettings(tester);
    final toggle = find.byKey(const ValueKey('hidden-notes-sidebar-toggle'));
    final settingsPane = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(SingleChildScrollView),
    );
    final settingsScrollable = find.descendant(
      of: settingsPane,
      matching: find.byType(Scrollable),
    );
    expect(settingsScrollable, findsOneWidget);
    await tester.scrollUntilVisible(
      toggle,
      180,
      scrollable: settingsScrollable,
    );
    expect(
      find.descendant(
        of: toggle,
        matching: find.textContaining(
          shortcuts.bindingFor(ShortcutAction.toggleHiddenFolder)!.displayLabel,
        ),
      ),
      findsOneWidget,
    );
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(prefs.hiddenFolderVisible, isTrue);

    await tester.tap(find.widgetWithText(TextButton, 'Done'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sidebar-hidden-notes')), findsOneWidget);
  });

  testWidgets('system image UI does not close an unlocked hidden note', (
    tester,
  ) async {
    await notes.load();
    notes.create(body: 'Visible note');
    final private = notes.create(body: 'Private note');
    notes.hide(private.id);
    final picker = Completer<void>();
    await pumpApp(
      tester,
      hiddenNotesGate: _HiddenGate(),
      imageAcquirer: (_) async {
        await picker.future;
        return const [];
      },
    );

    await tester.tap(find.byKey(const ValueKey('sidebar-hidden-notes')));
    await tester.pumpAndSettle();
    expect(openNoteBody(tester), 'Private note');

    await pressShortcut(
      tester,
      shortcuts.bindingFor(ShortcutAction.insertImage)!,
      settle: false,
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(openNoteBody(tester), 'Private note');

    picker.complete();
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(NoteRow, 'Private note'), findsNothing);
  });

  testWidgets(
    'sharing before signing in opens Profile & sync on the sign-in form, and says why',
    (tester) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      final account = Account(
        auth: FakeAuth(),
        syncApi: (_) =>
            FakeApi(FakeServer(), device: 'device-1', userId: 'user-1'),
        keys: KeyStore(InMemorySecureStore()),
        notes: notes,
        state: SyncState(store),
        store: store,
        docStorage: MemoryDocStorage(),
      );
      addTearDown(account.dispose);
      await tester.runAsync(account.restore);
      expect(account.state, AccountState.signedOut);
      await notes.load();
      notes.create(body: 'Trip plan');
      await pumpApp(tester, account: account);

      await tester.tap(find.byTooltip('Share note').first);
      await tester.pumpAndSettle();

      // Not the share sheet, which would have nothing to share with, and not
      // General either: the pane that signs in, and the reason it opened.
      expect(find.byType(SettingsDialog), findsOneWidget);
      expect(find.text('Email me a code'), findsOneWidget);
      expect(find.text('Sign in first to share this note'), findsOneWidget);
    },
  );

  testWidgets('settings does not name a hidden startup note', (tester) async {
    await notes.load();
    final private = notes.create(body: 'Private startup note');
    notes.hide(private.id);
    prefs.load();
    prefs.defaultNoteId = private.id;
    shortcuts.load();
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: SettingsDialog(
          layoutPrefs: prefs,
          shortcuts: shortcuts,
          rates: rates,
          notes: notes,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final setting = find.byKey(const ValueKey('default-note-setting'));
    expect(
      find.descendant(of: setting, matching: find.text('Last opened note')),
      findsOneWidget,
    );
    expect(find.text('Private startup note'), findsNothing);
  });

  testWidgets('a note is not hidden when credential setup is canceled', (
    tester,
  ) async {
    await notes.load();
    final note = notes.create(body: 'Keep this visible');
    final gate = _HiddenGate(allowConfigure: false);
    await pumpApp(tester, hiddenNotesGate: gate);

    await openNoteActions(tester, note.id);
    await tester.tap(find.byKey(ValueKey('hide-note-${note.id}')));
    await tester.pumpAndSettle();

    expect(gate.configureCalls, 1);
    expect(notes.hiddenNotes, isEmpty);
    expect(notes.notes.single.id, note.id);
  });

  testWidgets('phone note actions open as one labeled bottom sheet', (
    tester,
  ) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    await notes.load();
    final note = notes.create(body: 'Mobile actions');
    await pumpApp(tester, size: const Size(390, 844));
    await showNotesList(tester);

    expect(find.byKey(ValueKey('pin-note-${note.id}')), findsNothing);
    expect(find.byKey(ValueKey('archive-note-${note.id}')), findsNothing);
    expect(find.byKey(ValueKey('hide-note-${note.id}')), findsNothing);

    await openNoteActions(tester, note.id);

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('Pin note'), findsOneWidget);
    expect(find.text('Archive note'), findsOneWidget);
    expect(find.text('Move to Hidden Notes'), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('pin-note-${note.id}')));
    await tester.pumpAndSettle();
    expect(notes.isPinned(note.id), isTrue);
  });

  testWidgets('puts hiding above a red Archive note at the bottom', (
    tester,
  ) async {
    await pumpApp(tester);
    final note = notes.create(body: 'Menu order');
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(NoteRow, 'Menu order'));
    await tester.pumpAndSettle();
    await openNoteActions(tester, note.id);

    final hide = find.byKey(ValueKey('hide-note-${note.id}'));
    final archive = find.byKey(ValueKey('archive-note-${note.id}'));
    expect(tester.getCenter(hide).dy, lessThan(tester.getCenter(archive).dy));

    final archiveLabel = find.descendant(
      of: archive,
      matching: find.text('Archive note'),
    );
    final archiveText = tester.widget<Text>(archiveLabel);
    expect(
      archiveText.style?.color,
      Theme.of(tester.element(archiveLabel)).colorScheme.error,
    );
  });

  testWidgets('a failed unlock leaves Hidden Notes closed', (tester) async {
    await notes.load();
    final note = notes.create(body: 'Still private');
    notes.hide(note.id);
    final gate = _HiddenGate(allowUnlock: false);
    await pumpApp(tester, hiddenNotesGate: gate);

    await tester.tap(find.byKey(const ValueKey('sidebar-hidden-notes')));
    await tester.pumpAndSettle();

    expect(gate.unlockCalls, 1);
    expect(find.widgetWithText(NoteRow, 'Still private'), findsNothing);
    expect(find.text('Hidden Notes is empty'), findsNothing);
  });

  testWidgets('a phone reveals Hidden Notes by pulling down below Search', (
    tester,
  ) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    await notes.load();
    for (var index = 0; index < 30; index++) {
      notes.create(body: 'Note $index');
    }
    final gate = _HiddenGate();
    await pumpApp(tester, size: const Size(390, 844), hiddenNotesGate: gate);
    await showNotesList(tester);

    final drawerList = find.descendant(
      of: find.byType(Drawer),
      matching: find.byType(CustomScrollView),
    );
    expect(drawerList, findsOneWidget);
    final hidden = find.byKey(const ValueKey('sidebar-hidden-notes'));
    expect(hidden.hitTestable(), findsNothing);

    await tester.drag(drawerList, Offset(0, NoteFooter.height + 20));
    await tester.pumpAndSettle();

    expect(hidden.hitTestable(), findsOneWidget);
    expect(
      tester.getTopLeft(hidden).dy,
      greaterThanOrEqualTo(
        tester
            .getBottomLeft(find.byKey(const ValueKey('sidebar-search-field')))
            .dy,
      ),
    );
    await tester.tap(hidden);
    await tester.pumpAndSettle();

    expect(gate.unlockCalls, 1);
    expect(find.text('Hidden Notes is empty'), findsOneWidget);

    // A new app session starts at the notes again, never at the revealed
    // pull-down position from the previous one.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    rates = RatesRepository(store);
    await pumpApp(tester, size: const Size(390, 844), hiddenNotesGate: gate);
    await showNotesList(tester);
    expect(
      find.byKey(const ValueKey('sidebar-hidden-notes')).hitTestable(),
      findsNothing,
    );
  });

  testWidgets('a phone explains how to find a note after hiding it', (
    tester,
  ) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    await notes.load();
    final private = notes.create(body: 'Only private note');
    final gate = _HiddenGate();
    await pumpApp(tester, size: const Size(390, 844), hiddenNotesGate: gate);
    await showNotesList(tester);

    await openNoteActions(tester, private.id);
    await tester.tap(find.byKey(ValueKey('hide-note-${private.id}')));
    await tester.pumpAndSettle();

    expect(gate.configureCalls, 1);
    expect(notes.notes.map((note) => note.id), isNot(contains(private.id)));
    expect(notes.hiddenNotes.single.id, private.id);
    expect(
      find.text('Moved to Hidden Notes. Pull down below Search to find it.'),
      findsOneWidget,
    );

    final drawerList = find.descendant(
      of: find.byType(Drawer),
      matching: find.byType(CustomScrollView),
    );
    expect(drawerList, findsOneWidget);
    final hidden = find.byKey(const ValueKey('sidebar-hidden-notes'));
    expect(hidden.hitTestable(), findsNothing);

    await tester.drag(drawerList, Offset(0, NoteFooter.height + 20));
    await tester.pumpAndSettle();
    expect(hidden.hitTestable(), findsOneWidget);
    expect(
      find.descendant(of: hidden, matching: find.text('1')),
      findsOneWidget,
    );

    await tester.tap(hidden);
    await tester.pumpAndSettle();
    expect(gate.unlockCalls, 1);
    expect(find.widgetWithText(NoteRow, 'Only private note'), findsOneWidget);
  });

  testWidgets('keeps all note actions reachable at the narrowest sidebar', (
    tester,
  ) async {
    await pumpApp(tester);
    final note = notes.create(
      body: 'A title long enough that a narrow list has to cut it short',
    );
    await tester.pumpAndSettle();

    prefs.sidebarWidth = LayoutPrefs.minSidebarWidth;
    await tester.pumpAndSettle();

    // Open it as a reader would, then use the one compact menu for both
    // actions without sacrificing the title to a strip of glyphs.
    await tester.tap(find.byType(NoteRow));
    await tester.pumpAndSettle();

    await openNoteActions(tester, note.id);
    await tester.tap(find.byKey(ValueKey('pin-note-${note.id}')));
    await tester.pumpAndSettle();
    expect(notes.isPinned(note.id), isTrue);

    await openNoteActions(tester, note.id);
    await tester.tap(find.byKey(ValueKey('archive-note-${note.id}')));
    await tester.pumpAndSettle();
    expect(notes.archivedNotes.single.id, note.id);
  });

  group('the archive shortcut', () {
    /// Three notes with the newest open and the caret in it, which is where
    /// "Ready to type on open" leaves it.
    Future<void> openNote(WidgetTester tester, TargetPlatform platform) async {
      AppPlatform.debugTargetPlatformOverride = platform;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      await pumpApp(tester);
      for (final body in ['First', 'Second', 'Third']) {
        notes.create();
        notes.updateBody(notes.notes.first.id, body);
      }
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(NoteRow, 'Third'));
      await tester.pumpAndSettle();
    }

    Future<void> press(
      WidgetTester tester,
      LogicalKeyboardKey modifier,
      LogicalKeyboardKey key,
    ) async {
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(modifier);
      await tester.pumpAndSettle();
    }

    testWidgets('is Cmd+Delete on a Mac, and answers with the caret in the '
        'note', (tester) async {
      await openNote(tester, TargetPlatform.macOS);
      expect(
        shortcuts.bindingFor(ShortcutAction.deleteNote)!.displayLabel,
        'Cmd + Delete',
      );

      await press(
        tester,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.backspace,
      );

      expect(notes.archivedNotes.single.title, 'Third');
      expect(notes.notes.map((note) => note.title), ['Second', 'First']);
    });

    testWidgets('is Shift+Delete on Windows', (tester) async {
      await openNote(tester, TargetPlatform.windows);
      expect(
        shortcuts.bindingFor(ShortcutAction.deleteNote)!.displayLabel,
        'Shift + Delete',
      );

      await press(
        tester,
        LogicalKeyboardKey.shiftLeft,
        LogicalKeyboardKey.delete,
      );

      expect(notes.archivedNotes.single.title, 'Third');
    });

    testWidgets('deletes for good inside the archive, once the question is '
        'answered', (tester) async {
      await openNote(tester, TargetPlatform.macOS);
      for (final note in [...notes.notes]) {
        notes.archive(note.id);
      }
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sidebar-archive')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(NoteRow, 'Third'));
      await tester.pumpAndSettle();

      await press(
        tester,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.backspace,
      );

      // Nothing has gone, and nothing has been archived twice either.
      expect(notes.archivedNotes, hasLength(3));
      expect(find.text('Delete note?'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('confirm-delete')));
      await tester.pumpAndSettle();
      expect(
        notes.archivedNotes.map((note) => note.title),
        unorderedEquals(['First', 'Second']),
      );
      expect(notes.tombstones, hasLength(1));
    });

    testWidgets('names itself in the row menu', (tester) async {
      await openNote(tester, TargetPlatform.macOS);

      await tester.longPress(find.widgetWithText(NoteRow, 'Third'));
      await tester.pumpAndSettle();

      expect(find.text('Archive note'), findsOneWidget);
      expect(find.text('Cmd + Delete'), findsOneWidget);
    });
  });

  group('the Delete key in the notes list', () {
    /// The app with the notes list holding the keyboard.
    ///
    /// "Ready to type on open" is what decides where the keyboard goes when a
    /// note is opened: on, and opening one puts the caret in it, which is
    /// where a Delete belongs to the text. Off, and the list keeps it — which
    /// is the state these are about.
    Future<void> listHasTheKeyboard(WidgetTester tester) async {
      store.data['readyToTypeOnOpen.v1'] = false;
      await pumpApp(tester);
    }

    /// Three notes, newest first, with the list showing them.
    Future<void> threeNotes(WidgetTester tester) async {
      await listHasTheKeyboard(tester);
      for (final body in ['First', 'Second', 'Third']) {
        notes.create();
        notes.updateBody(notes.notes.first.id, body);
      }
      await tester.pumpAndSettle();
    }

    testWidgets('archives the note that was clicked, and the next one after '
        'it', (tester) async {
      await threeNotes(tester);

      await tester.tap(find.widgetWithText(NoteRow, 'Third'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();

      expect(notes.archivedNotes.single.title, 'Third');
      expect(find.text('Note moved to Archived Notes'), findsOneWidget);

      // The list keeps the keyboard: archiving the open note hands the caret
      // to the note that takes its place, and a second press must still be
      // the list's and not that editor's.
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      expect(
        notes.archivedNotes.map((note) => note.title),
        unorderedEquals(['Third', 'Second']),
      );
      expect(notes.notes.single.title, 'First');
    });

    testWidgets('answers Cmd+Delete, the way macOS files from a list', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      await threeNotes(tester);

      await tester.tap(find.widgetWithText(NoteRow, 'Third'));
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();

      expect(notes.archivedNotes.single.title, 'Third');
    });

    testWidgets('leaves the note alone once the editor has the keyboard', (
      tester,
    ) async {
      await threeNotes(tester);

      // The list first, so this is the press that has to go back to being a
      // character: clicking into the note is what hands the keyboard over.
      await tester.tap(find.widgetWithText(NoteRow, 'Third'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(NoteEditor),
          matching: find.byType(EditableText),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();

      expect(notes.archivedNotes, isEmpty);
      expect(notes.notes.first.title, 'Third');
    });

    testWidgets('leaves the note alone while the search field has it', (
      tester,
    ) async {
      await threeNotes(tester);
      await tester.tap(find.widgetWithText(NoteRow, 'Third'));
      await tester.pumpAndSettle();

      final search = find.byKey(const ValueKey('sidebar-search-field'));
      await tester.tap(search);
      await tester.enterText(search, 'Third');
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();

      expect(notes.archivedNotes, isEmpty);
      expect(notes.notes, hasLength(3));
    });

    testWidgets('stops when the list has nothing left to archive', (
      tester,
    ) async {
      await listHasTheKeyboard(tester);
      notes.create(body: 'Only');
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(NoteRow, 'Only'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      expect(notes.notes, isEmpty);

      // The list still holds the keyboard, and now has nothing to answer
      // with. Pressing again must be a press that does nothing.
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      expect(notes.notes, isEmpty);
      expect(notes.archivedNotes, hasLength(1));
    });

    testWidgets('asks before it throws an archived note away for good', (
      tester,
    ) async {
      await threeNotes(tester);
      for (final note in [...notes.notes]) {
        notes.archive(note.id);
      }
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sidebar-archive')));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(NoteRow, 'Third'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();

      expect(notes.archivedNotes, hasLength(3));
      expect(find.text('Delete note?'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('confirm-delete')));
      await tester.pumpAndSettle();
      expect(
        notes.archivedNotes.map((note) => note.title),
        unorderedEquals(['First', 'Second']),
      );
      expect(notes.tombstones, hasLength(1));
    });
  });

  testWidgets('sidebar arrows scrub notes until Right enters the editor', (
    tester,
  ) async {
    await pumpApp(tester);
    for (final body in ['First', 'Second', 'Third']) {
      notes.create(body: body);
    }
    await tester.pumpAndSettle();

    String selectedTitle() => tester
        .widgetList<NoteRow>(find.byType(NoteRow))
        .singleWhere((row) => row.selected)
        .note
        .title;
    List<String> rowTitles() => tester
        .widgetList<NoteRow>(find.byType(NoteRow))
        .map((row) => row.note.title)
        .toList();

    await tester.tap(find.widgetWithText(NoteRow, 'Second'));
    await tester.pumpAndSettle();
    expect(selectedTitle(), 'Second');
    expect(rowTitles(), ['Second', 'First', 'Third']);
    expect(openNoteField(tester).focusNode!.hasFocus, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(selectedTitle(), 'Third');
    expect(rowTitles(), ['Second', 'First', 'Third']);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(selectedTitle(), 'Second');

    // The first arrow keeps the keyboard with the list, so another arrow can
    // continue the walk without another click.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(selectedTitle(), 'Third');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    final editor = openNoteField(tester);
    expect(editor.focusNode!.hasFocus, isTrue);
    expect(editor.controller!.selection.isCollapsed, isTrue);
    expect(rowTitles(), ['Third', 'Second', 'First']);
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
        find.descendant(of: entry, matching: findKapyIcon(archiveIcon)),
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

      await openNoteActions(tester, third.id);
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
      await openNoteActions(tester, archived.first.id);
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
      expect(find.text('Empty Archived Notes?'), findsOneWidget);
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
      expect(find.byKey(ValueKey('note-actions-${note.id}')), findsOneWidget);
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

    testWidgets(
      'Windows keeps the results shortcut at its minimum client width',
      (tester) async {
        AppPlatform.debugTargetPlatformOverride = TargetPlatform.windows;
        addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
        store.data['notes.v1'] = [
          {
            'id': 'windows-minimum',
            'body': 'Minimum window\n6 * 7',
            'createdAt': 1000,
            'updatedAt': 1000,
          },
        ];

        // The Windows frame consumes a few pixels of the native minimum
        // width, so Flutter can receive a client area just below 520 px.
        await pumpApp(
          tester,
          size: Size(LayoutPrefs.minimumWindowSize.width - 12, 630),
        );

        expect(find.byType(GutterDivider), findsOneWidget);
        await pressShortcut(
          tester,
          shortcuts.bindingFor(ShortcutAction.toggleResults)!,
        );

        expect(prefs.resultsVisible, isFalse);
        expect(
          find.byKey(const ValueKey('results-restore-handle')),
          findsOneWidget,
        );
      },
    );

    testWidgets('keeps the results divider out of phone-sized layouts', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
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
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
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

    testWidgets('puts the insert menu in a scrollable phone footer', (
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

      expect(find.byKey(const ValueKey('insert-menu')), findsOneWidget);
      expect(find.byKey(const ValueKey('insert-image')), findsNothing);
      expect(find.byKey(const ValueKey('record-voice')), findsNothing);
      final insertMenu = find.byKey(const ValueKey('insert-menu'));
      expect(
        find.descendant(of: insertMenu, matching: find.text('/')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: insertMenu,
          matching: findKapyIcon(KapyIcons.addRounded),
        ),
        findsNothing,
      );
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

      expect(openNoteField(tester).focusNode!.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);

      await tester.tap(insertMenu);
      await tester.pump();
      await tester.pump();
      expect(openNoteField(tester).focusNode!.hasFocus, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);

      const commandOrder = [
        'checklist',
        'bulletedList',
        'image',
        'voiceNote',
        'table',
        'divider',
        'video',
      ];
      final commandTops = [
        for (final command in commandOrder)
          tester.getTopLeft(find.byKey(ValueKey('slash-command-$command'))).dy,
      ];
      for (var index = 1; index < commandTops.length; index++) {
        expect(commandTops[index], greaterThan(commandTops[index - 1]));
      }

      await tester.drag(
        find.byKey(const ValueKey('slash-command-list')),
        const Offset(0, -260),
      );
      await tester.pumpAndSettle();
      const finalCommandOrder = ['video', 'numberedList', 'quote', 'codeBlock'];
      final finalCommandTops = [
        for (final command in finalCommandOrder)
          tester.getTopLeft(find.byKey(ValueKey('slash-command-$command'))).dy,
      ];
      for (var index = 1; index < finalCommandTops.length; index++) {
        expect(
          finalCommandTops[index],
          greaterThan(finalCommandTops[index - 1]),
        );
      }
      expect(find.byKey(const ValueKey('slash-command-heading')), findsNothing);
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
        tester.getRect(find.byKey(const ValueKey('insert-menu'))).bottom,
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

      await tester.tap(notesToggleWithLabel('Show notes'));
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

    testWidgets('archive and hidden folders never raise a keyboard in drawer', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      await notes.load();
      notes.create(body: 'Visible note');
      final archived = notes.create(body: 'Archived note');
      notes.archive(archived.id);
      final hidden = notes.create(body: 'Hidden note');
      notes.hide(hidden.id);

      await pumpApp(
        tester,
        size: const Size(420, 800),
        hiddenNotesGate: _HiddenGate(),
      );
      expect(tester.testTextInput.isVisible, isTrue);

      await showNotesList(tester);
      expect(tester.testTextInput.isVisible, isFalse);
      tester.testTextInput.log.clear();

      await tester.tap(find.byKey(const ValueKey('sidebar-archive')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(NoteRow, 'Archived note'), findsOneWidget);
      expect(openNoteField(tester).focusNode!.hasFocus, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
      expect(
        tester.testTextInput.log.map((call) => call.method),
        isNot(contains('TextInput.show')),
      );

      tester.testTextInput.log.clear();
      await tester.tap(find.byKey(const ValueKey('sidebar-all-notes')));
      await tester.pumpAndSettle();
      final drawerList = find.descendant(
        of: find.byType(Drawer),
        matching: find.byType(Scrollable),
      );
      await tester.drag(drawerList.last, const Offset(0, 200));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('sidebar-hidden-notes')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('sidebar-hidden-notes')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(NoteRow, 'Hidden note'), findsOneWidget);
      expect(openNoteField(tester).focusNode!.hasFocus, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
      expect(
        tester.testTextInput.log.map((call) => call.method),
        isNot(contains('TextInput.show')),
      );
    });

    testWidgets('opening settings directly lowers the mobile keyboard', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      store.data['notes.v1'] = [
        {
          'id': 'mobile-settings',
          'body': 'A focused note',
          'createdAt': 1000,
          'updatedAt': 1000,
        },
      ];

      await pumpApp(tester, size: const Size(420, 800));
      expect(tester.testTextInput.isVisible, isTrue);

      await tester.tap(find.byTooltip('Share note'));
      await tester.pumpAndSettle();

      expect(find.text('Settings'), findsWidgets);
      expect(tester.testTextInput.isVisible, isFalse);
      expect(openNoteField(tester).focusNode!.hasFocus, isFalse);
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
          tester.getTopLeft(notesToggleWithLabel('Show notes')).dx,
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
      final menu = notesToggleWithLabel('Hide notes');

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
      expect(notesToggleWithLabel('Show notes'), findsOneWidget);
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
        tester.getTopLeft(findKapyIcon(KapyIcons.addRounded).last).dy,
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
