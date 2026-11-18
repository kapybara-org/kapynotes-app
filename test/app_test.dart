import 'dart:async';

import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/appearance.dart';
import 'package:kapy_notes/core/desktop_integration.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/auto_titles.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/editor_workspace.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/note_drawing.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/tags.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/stamped.dart';
import 'package:kapy_notes/images/image_picker.dart';
import 'package:kapy_notes/speech/summarizer.dart';
import 'package:kapy_notes/speech/transcriber.dart';
import 'package:kapy_notes/sync/account.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/sync/key_store.dart';
import 'package:kapy_notes/sync/sync_state.dart';
import 'package:kapy_notes/ui/draw/drawing_canvas.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/editor/note_field.dart';
import 'package:kapy_notes/ui/editor/note_footer.dart';
import 'package:kapy_notes/ui/editor/results_gutter.dart';
import 'package:kapy_notes/ui/editor_panes.dart';
import 'package:kapy_notes/ui/empty_state.dart';
import 'package:kapy_notes/ui/hidden_notes_gate.dart';
import 'package:kapy_notes/ui/home_page.dart';
import 'package:kapy_notes/ui/keycap.dart';
import 'package:kapy_notes/core/window_chrome.dart';
import 'package:kapy_notes/ui/settings_dialog.dart';
import 'package:kapy_notes/ui/settings_rows.dart';
import 'package:kapy_notes/ui/notes_list.dart';
import 'package:kapy_notes/ui/sidebar.dart';
import 'package:kapy_notes/ui/sidebar_swipe.dart';
import 'package:kapy_notes/ui/spaces_rail.dart';
import 'package:kapy_notes/ui/compact_icon_button.dart';
import 'package:kapy_notes/ui/tag_ui.dart';
import 'package:kapy_notes/ui/tonal_button.dart';
import 'package:kapy_notes/ui/page_card.dart';
import 'package:kapy_notes/ui/page_toolbar.dart';
import 'package:kapy_notes/ui/window_drag_area.dart';

import 'kapy_icon_finder.dart';
import 'quick_capture_test.dart' show stubLaunchIntent;
import 'support/note_driver.dart';
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
  TagStore? tags,
  TitleModel titleModel = const NoTitleModel('Not in tests'),
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
      tags: tags,
      titleModel: titleModel,
    ),
  );
  await tester.pumpAndSettle();
}

/// Names every note the same, at once.
class _InstantTitles implements TitleModel {
  _InstantTitles(this.title);

  final String title;
  int asked = 0;

  @override
  Future<String?> unavailableReason() async => null;

  @override
  Future<String> name({
    required String instructions,
    required String prompt,
  }) async {
    asked++;
    return title;
  }
}

/// A model whose answer arrives when the test gives it.
class _LaterTitles implements TitleModel {
  final List<Completer<String>> asked = [];

  @override
  Future<String?> unavailableReason() async => null;

  @override
  Future<String> name({required String instructions, required String prompt}) {
    asked.add(Completer<String>());
    return asked.last.future;
  }
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

  @override
  Future<bool> usesPin() async => false;

  @override
  Future<bool> changePin(BuildContext context) async => false;
}

/// The [TextField] of the note the editor is currently showing.
NoteField openNoteField(WidgetTester tester) => tester.widget<NoteField>(
  find.descendant(of: find.byType(NoteEditor), matching: noteField),
);

/// What that note says, without the blank line the editor keeps below it to
/// type into. Leading whitespace is left alone: list indentation is content.
String openNoteBody(WidgetTester tester) =>
    openNoteField(tester).controller.text.trimRight();

/// The text field of the note in the pane at [index], counting from the left.
NoteField fieldInPane(WidgetTester tester, int index) =>
    tester.widget<NoteField>(
      find.descendant(
        of: find.byType(EditorPaneFrame).at(index),
        matching: noteField,
      ),
    );

/// What the note in the pane at [index] says, read as [openNoteBody] reads.
String bodyInPane(WidgetTester tester, int index) =>
    fieldInPane(tester, index).controller.text.trimRight();

/// The way into settings on every layout: the rail's gear beside a wide
/// window's notes list, and the notes list's labelled row everywhere else.
Finder settingsAffordance() => find.byWidgetPredicate(
  (widget) =>
      widget.key == const ValueKey('rail-settings') ||
      widget.key == const ValueKey('sidebar-settings'),
);

/// The empty state's own New note, rather than the one over the notes list.
Finder emptyStateNewNote() => find.descendant(
  of: find.byType(EmptyState),
  matching: find.widgetWithText(FilledButton, 'New note'),
);

/// The name of the space the notes list is showing, in the bar over it.
String? spaceTitle(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('sidebar-space-title'))).data;

/// How many notes that space holds, beside its name.
String? spaceCount(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('sidebar-space-count'))).data;

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
  // A phone's list is under the page it opened on.
  final back = find.byKey(const ValueKey('page-back'));
  if (back.evaluate().isNotEmpty) {
    await tester.tap(back);
    await tester.pumpAndSettle();
    return;
  }
  final open = notesToggleWithLabel('Show notes');
  if (open.evaluate().isEmpty) return;
  await tester.tap(open.first);
  await tester.pumpAndSettle();
}

/// Rests the pointer on a note in the list, where the desktop list shows the
/// note's actions button.
Future<TestGesture> hoverNote(WidgetTester tester, String noteId) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(
    location: tester.getCenter(
      find.byWidgetPredicate((w) => w is NoteRow && w.note.id == noteId),
    ),
  );
  await tester.pumpAndSettle();
  return mouse;
}

/// Opens the page's More menu and picks [value] from it.
Future<void> pickPageAction(WidgetTester tester, String value) async {
  await tester.tap(find.byKey(const ValueKey('page-more')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('page-more-$value')));
  await tester.pumpAndSettle();
}

/// Chooses [show] in the notes filter over the list.
Future<void> showInFilter(WidgetTester tester, NotesShow show) async {
  await tester.tap(find.byKey(const ValueKey('sidebar-notes-filter')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('notes-filter-${show.name}')));
  await tester.pumpAndSettle();
}

Future<void> openNoteActions(WidgetTester tester, String noteId) async {
  final mouse = await hoverNote(tester, noteId);
  await tester.tap(find.byKey(ValueKey('note-actions-$noteId')));
  await mouse.removePointer();
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
  SettingsSection section = SettingsSection.appearance,
}) async {
  await showNotesList(tester);
  await tester.tap(settingsAffordance().first);
  await tester.pumpAndSettle();
  if (section == SettingsSection.appearance) return;
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
      final hydratedEditor = tester.widget<NoteField>(
        find.descendant(of: find.byType(NoteEditor), matching: noteField),
      );
      expect(hydratedEditor.controller.text, 'Call the dentist at 9\n\n');
      expect(hydratedEditor.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
    },
  );

  group('voice choices survive a relaunch', () {
    void saveChoices(LocalStore saved) {
      saved.data['voice.transcriptEngine.v1'] = 'device';
      saved.data['voice.summaryEngine.v1'] = 'device';
      saved.data['voice.transcriptionDeclinedVersion.v1'] = 3;
    }

    void expectChoices(WidgetTester tester) {
      final voice = tester.widget<HomePage>(find.byType(HomePage)).voicePrefs!;
      expect(voice.transcriptEngine, TranscriptEngine.device);
      expect(voice.summaryEngine, SummaryEngine.device);
      expect(voice.transcriptionDeclinedVersion, 3);
    }

    testWidgets('when the notes load before the app starts', (tester) async {
      saveChoices(store);
      await pumpApp(tester);
      expectChoices(tester);
    });

    testWidgets('when the notes load behind the first frame', (tester) async {
      final deferredStore = DeferredMemoryStore();
      saveChoices(deferredStore);
      await tester.pumpWidget(
        KapyNotesApp(
          store: deferredStore,
          notes: NotesStore(deferredStore),
          rates: RatesRepository(deferredStore),
          prefs: LayoutPrefs(deferredStore),
          shortcuts: ShortcutPrefs(deferredStore),
        ),
      );
      deferredStore.completeLoad();
      await tester.pumpAndSettle();
      expectChoices(tester);
    });
  });

  testWidgets('a build with no sync keeps its tags across a relaunch', (
    tester,
  ) async {
    final tags = TagStore(store);
    await tags.load();
    await pumpApp(tester, tags: tags);
    final note = notes.create(body: 'Trip to Kochi');
    final shown = tester.widget<HomePage>(find.byType(HomePage)).tags!;
    shown.addTag(note.id, shown.create('Travel')!.id);
    await tester.pumpWidget(const SizedBox());

    notes = NotesStore(store);
    prefs = LayoutPrefs(store);
    rates = RatesRepository(store);
    shortcuts = ShortcutPrefs(store);
    final relaunched = TagStore(store);
    expect(await relaunched.load(), isTrue);
    await pumpApp(tester, tags: relaunched);
    final home = tester.widget<HomePage>(find.byType(HomePage));
    expect(home.account, isNull);
    expect(home.tags, same(relaunched));
    expect(relaunched.tagsOf(note.id).map((t) => t.name.v), ['Travel']);
  });

  group('tags', () {
    late TagStore tags;

    setUp(() async {
      tags = TagStore(store);
      await tags.load();
    });

    List<String> namesOn(String noteId) => [
      for (final tag in tags.tagsOf(noteId)) tag.name.v,
    ];

    Future<void> openPicker(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('note-add-tag')));
      await tester.pumpAndSettle();
    }

    Future<void> typeAndEnter(WidgetTester tester, String text) async {
      await tester.enterText(
        find.byKey(const ValueKey('tag-picker-field')),
        text,
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
    }

    Future<void> openTagsFilter(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('sidebar-notes-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('notes-filter-tags')));
      await tester.pumpAndSettle();
    }

    String countOn(WidgetTester tester, Tag tag) => tester
        .widget<Text>(
          find
              .descendant(
                of: find.byKey(ValueKey('tag-filter-${tag.id}')),
                matching: find.byType(Text),
              )
              .last,
        )
        .data!;

    testWidgets('+ Tag creates a tag, and its name in another case picks it', (
      tester,
    ) async {
      final note = notes.create(body: 'Trip to Kochi');
      await pumpApp(tester, tags: tags);
      await openPicker(tester);
      await typeAndEnter(tester, 'Travel');
      expect(namesOn(note.id), ['Travel']);

      tags.removeTag(note.id, tags.tags.single.id);
      await tester.pumpAndSettle();
      await typeAndEnter(tester, 'TRAVEL');
      expect(tags.tags, hasLength(1));
      expect(namesOn(note.id), ['Travel']);
    });

    testWidgets('a name past 32 characters stops at 32', (tester) async {
      final note = notes.create(body: 'Long names');
      await pumpApp(tester, tags: tags);
      await openPicker(tester);
      await typeAndEnter(tester, 'x' * 33);
      expect(namesOn(note.id), ['x' * 32]);
    });

    testWidgets('a note takes at most 20 tags, and says so', (tester) async {
      final note = notes.create(body: 'Busy');
      tags.setTags(note.id, [
        for (var i = 0; i < noteTagsMax; i++) tags.create('tag $i')!.id,
      ]);
      await pumpApp(tester, tags: tags);
      await openPicker(tester);
      await typeAndEnter(tester, 'One more');
      expect(find.text('A note takes at most 20 tags.'), findsOneWidget);
      expect(tags.tags.map((tag) => tag.name.v), isNot(contains('One more')));
      expect(tags.tagsOf(note.id), hasLength(noteTagsMax));
    });

    testWidgets(
      'while Hidden is locked, no count includes it and no tag gives it away',
      (tester) async {
        final hidden = notes.create(body: 'Private');
        final open = notes.create(body: 'Public');
        notes.hide(hidden.id);
        prefs.load();
        prefs.hiddenFolderVisible = true;
        final work = tags.create('Work')!;
        final secret = tags.create('Secret')!;
        tags.addTag(open.id, work.id);
        tags.addTag(hidden.id, work.id);
        tags.addTag(hidden.id, secret.id);
        await pumpApp(tester, tags: tags, hiddenNotesGate: _HiddenGate());

        await openTagsFilter(tester);
        expect(countOn(tester, work), '1');
        expect(find.byKey(ValueKey('tag-filter-${secret.id}')), findsNothing);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        await openPicker(tester);
        expect(find.byKey(ValueKey('tag-row-${secret.id}')), findsNothing);
        await typeAndEnter(tester, 'secret');
        expect(find.text('Create “secret”'), findsOneWidget);
        expect(find.text(chooseAnotherName), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('tag-picker')),
            matching: find.textContaining(
              RegExp('hidden', caseSensitive: false),
            ),
          ),
          findsNothing,
        );
        expect(namesOn(open.id), ['Work']);
        expect(tags.tags, hasLength(2));
        await tester.tapAt(const Offset(1000, 700));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('sidebar-notes-filter')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('notes-filter-hidden')));
        await tester.pumpAndSettle();
        await openTagsFilter(tester);
        expect(countOn(tester, work), '2');
        expect(countOn(tester, secret), '1');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        await openPicker(tester);
        expect(find.byKey(ValueKey('tag-row-${secret.id}')), findsOneWidget);
        await typeAndEnter(tester, 'secret');
        expect(find.text(chooseAnotherName), findsNothing);
        expect(find.byKey(const ValueKey('tag-create')), findsNothing);
        expect(tags.tags, hasLength(2));
      },
    );

    testWidgets(
      'a name a locked Hidden tag holds is refused like any other clash',
      (tester) async {
        final hidden = notes.create(body: 'Private');
        notes.create(body: 'Public');
        notes.hide(hidden.id);
        prefs.load();
        prefs.hiddenFolderVisible = true;
        final work = tags.create('Work')!;
        tags.create('Home');
        final secret = tags.create('Secret')!;
        tags.addTag(hidden.id, secret.id);
        await pumpApp(tester, tags: tags, hiddenNotesGate: _HiddenGate());

        Future<void> refuses(String name) async {
          final hiddenText = find.textContaining('Hidden');
          final shown = hiddenText.evaluate().length;
          await tester.enterText(
            find.byKey(const ValueKey('tag-name-field')),
            name,
          );
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<Text>(find.byKey(const ValueKey('tag-name-refused')))
                .data,
            chooseAnotherName,
            reason: name,
          );
          expect(hiddenText, findsExactly(shown), reason: name);
        }

        Future<void> rename(String moreKey) async {
          await tester.tap(find.byKey(ValueKey(moreKey)));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('tag-action-rename')));
          await tester.pumpAndSettle();
        }

        await openTagsFilter(tester);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(mouse.removePointer);
        await mouse.addPointer(
          location: tester.getCenter(
            find.byKey(ValueKey('tag-filter-${work.id}')),
          ),
        );
        await tester.pumpAndSettle();
        await rename('tag-filter-more-${work.id}');
        await refuses('secret');
        await refuses('HOME');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        await openSettings(tester, section: SettingsSection.notes);
        final row = find.byKey(ValueKey('settings-tag-${work.id}'));
        await tester.ensureVisible(row);
        await tester.pumpAndSettle();
        await rename('settings-tag-more-${work.id}');
        await refuses('Secret');
        await refuses('home');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(row, findsOneWidget);
        expect(find.byKey(const ValueKey('tag-name-field')), findsNothing);

        await tester.tap(find.byKey(const ValueKey('settings-new-tag')));
        await tester.pumpAndSettle();
        await refuses('secret');
        await refuses('Home');
        expect(tags.tags.map((tag) => tag.name.v), ['Work', 'Home', 'Secret']);
      },
    );

    testWidgets('a synced name arrives cut and sits on one line in Settings', (
      tester,
    ) async {
      final long = Tag.fromPayload(
        't1',
        Tag(
          id: 't1',
          name: Stamped('W' * 40, 1),
          colour: Stamped('teal', 1),
          order: Stamped(0, 1),
          createdAt: 1,
        ).toPayload(),
      )!;
      tags.applyRemoteTag(long, 1);
      await pumpApp(tester, tags: tags);
      await openSettings(tester, section: SettingsSection.notes);

      final name = find.descendant(
        of: find.byKey(const ValueKey('settings-tag-t1')),
        matching: find.text('W' * tagNameMax),
      );
      await tester.ensureVisible(name);
      await tester.pumpAndSettle();
      expect(name, findsOneWidget);
      final text = tester.widget<Text>(name);
      expect(text.maxLines, 1);
      expect(text.overflow, TextOverflow.ellipsis);
      expect(tester.getSize(name).height, lessThan(24));
    });

    testWidgets('ticked tags narrow the list, any or all', (tester) async {
      final both = notes.create(body: 'Both');
      final workOnly = notes.create(body: 'Work only');
      notes.create(body: 'Bare');
      final work = tags.create('Work')!;
      final home = tags.create('Home')!;
      tags.setTags(both.id, [work.id, home.id]);
      tags.setTags(workOnly.id, [work.id]);
      await pumpApp(tester, tags: tags);

      String count() => spaceCount(tester)!;
      expect(count(), contains('3'));
      await openTagsFilter(tester);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('tag-filter-none')),
          matching: find.text('1'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(ValueKey('tag-filter-${work.id}')));
      await tester.pumpAndSettle();
      expect(count(), contains('2'));
      expect(find.byKey(const ValueKey('tag-filter-any')), findsNothing);
      await tester.tap(find.byKey(ValueKey('tag-filter-${home.id}')));
      await tester.pumpAndSettle();
      expect(count(), contains('2'));
      expect(find.byKey(const ValueKey('tag-filter-any')), findsOneWidget);
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('notes-filter-tags-ticked')),
            )
            .data,
        '2',
      );
      await tester.tap(find.byKey(const ValueKey('tag-filter-all')));
      await tester.pumpAndSettle();
      expect(count(), contains('1'));
      await tester.tap(find.byKey(const ValueKey('tag-filter-none')));
      await tester.pumpAndSettle();
      expect(count(), contains('2'));
    });

    testWidgets('delete asks once, and Undo puts the tag back in place', (
      tester,
    ) async {
      final note = notes.create(body: 'Plans');
      final ideas = tags.create('Ideas')!;
      final work = tags.create('Work')!;
      tags.setTags(note.id, [ideas.id, work.id]);
      await pumpApp(tester, tags: tags);

      unawaited(
        deleteTag(tester.element(find.byType(HomePage)), tags, (
          tag: ideas,
          count: 1,
        )),
      );
      await tester.pumpAndSettle();
      expect(find.text('Delete “Ideas”?'), findsOneWidget);
      expect(
        find.textContaining("It's on 1 note. The notes stay as they are"),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('tag-delete-confirm')));
      await tester.pumpAndSettle();
      expect(namesOn(note.id), ['Work']);
      expect(find.text('Deleted “Ideas”'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(namesOn(note.id), ['Ideas', 'Work']);
    });

    testWidgets('Settings › Notes › Tags lists, creates and renames tags', (
      tester,
    ) async {
      final first = notes.create(body: 'One');
      final second = notes.create(body: 'Two');
      final work = tags.create('Work')!;
      tags.addTag(first.id, work.id);
      tags.addTag(second.id, work.id);
      await pumpApp(tester, tags: tags);
      await openSettings(tester, section: SettingsSection.notes);

      final row = find.byKey(ValueKey('settings-tag-${work.id}'));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: row, matching: find.text('2 notes')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(ValueKey('settings-tag-more-${work.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tag-action-rename')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('tag-name-field')),
        'Office',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(tags.byId(work.id)!.name.v, 'Office');

      await tester.tap(find.byKey(const ValueKey('settings-new-tag')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('tag-name-field')),
        'office',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(tags.tags, hasLength(1));
    });

    testWidgets('on a phone the filter is a sheet whose Tags page narrows the '
        'list live', (tester) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      final hidden = notes.create(body: 'Private plan');
      final trip = notes.create(body: 'Trip to Kochi');
      notes.create(body: 'Groceries');
      notes.hide(hidden.id);
      final work = tags.create('Work')!;
      final secret = tags.create('Secret')!;
      tags.addTag(trip.id, work.id);
      tags.addTag(hidden.id, secret.id);
      await pumpApp(tester, size: const Size(390, 760), tags: tags);
      await showNotesList(tester);

      await tester.tap(find.byKey(const ValueKey('sidebar-notes-filter')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('notes-filter-sheet')), findsOneWidget);
      expect(find.byKey(const ValueKey('notes-filter-menu')), findsNothing);
      expect(find.text('Show'), findsOneWidget);
      expect(find.text('Media'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('notes-filter-tags')));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('tag-filter-${work.id}')), findsOneWidget);
      expect(find.byKey(ValueKey('tag-filter-${secret.id}')), findsNothing);
      await tester.tap(find.byKey(ValueKey('tag-filter-${work.id}')));
      await tester.pumpAndSettle();
      expect(find.text('Groceries'), findsNothing);
      expect(find.text('Trip to Kochi'), findsWidgets);

      await tester.tap(find.byKey(const ValueKey('notes-filter-back')));
      await tester.pumpAndSettle();
      expect(find.text('Work'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('notes-filter-done')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('notes-filter-sheet')), findsNothing);
      expect(find.text('Groceries'), findsNothing);
    });

    testWidgets('⌘K # filters by a tag, and Tag note… tags the open note', (
      tester,
    ) async {
      final trip = notes.create(body: 'Trip to Kochi');
      notes.create(body: 'Groceries');
      final work = tags.create('Work')!;
      tags.addTag(trip.id, work.id);
      await pumpApp(tester, tags: tags);

      await pressShortcut(
        tester,
        shortcuts.bindingFor(ShortcutAction.findNotes)!,
      );
      await tester.enterText(
        find.byKey(const ValueKey('command-menu-field')),
        '#wo',
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('command-menu')), findsNothing);
      expect(find.text('Groceries'), findsNothing);
      expect(find.text('Trip to Kochi'), findsWidgets);

      await tester.tap(find.byKey(const ValueKey('sidebar-filter-clear')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Groceries').first);
      await tester.pumpAndSettle();
      await pressShortcut(
        tester,
        shortcuts.bindingFor(ShortcutAction.findNotes)!,
      );
      await tester.enterText(
        find.byKey(const ValueKey('command-menu-field')),
        'tag',
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('command-menu-field')),
        'Errands',
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      final groceries = notes.notes.firstWhere(
        (note) => note.title == 'Groceries',
      );
      expect(namesOn(groceries.id), ['Errands']);
    });
  });

  testWidgets('opens on the empty state and builds a note from it', (
    tester,
  ) async {
    await pumpApp(tester);

    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.byType(PageToolbar), findsOneWidget);
    expect(find.text('No notes yet'), findsOneWidget);

    await tester.tap(emptyStateNewNote());
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

    final field = tester.widget<NoteField>(
      find.descendant(of: find.byType(NoteEditor), matching: noteField),
    );
    expect(field.controller.text, 'Desktop thought\nfinal line\n\n');
    expect(field.controller.selection.baseOffset, field.controller.text.length);
    expect(field.focusNode.hasFocus, isTrue);
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

    final field = tester.widget<NoteField>(
      find.descendant(of: find.byType(NoteEditor), matching: noteField),
    );
    expect(field.controller.text, 'Leave this exactly here');
    expect(field.focusNode.hasFocus, isFalse);

    integration.onOpenRequested!();
    await tester.pump();
    expect(field.controller.text, 'Leave this exactly here');
    expect(field.focusNode.hasFocus, isFalse);

    await tester.tap(findKapyIcon(KapyIcons.addRounded).first);
    await tester.pumpAndSettle();
    final newNoteField = tester.widget<NoteField>(
      find.descendant(of: find.byType(NoteEditor), matching: noteField),
    );
    expect(newNoteField.controller.text, Note.blankBody);
    expect(newNoteField.focusNode.hasFocus, isTrue);
  });

  group('a new note', () {
    const trip =
        'Flights to Lisbon are 900 for two, the hotel near Alfama is 120 a '
        'night, and the train to Sintra is cheap';

    // Naming is off by default; these speak for someone who turned it on.
    setUp(() => prefs.autoTitlesEnabled = true);

    Future<TextEditingController> newNote(WidgetTester tester) async {
      await tester.tap(findKapyIcon(KapyIcons.addRounded).first);
      await tester.pumpAndSettle();
      return tester
          .widget<NoteField>(
            find.descendant(of: find.byType(NoteEditor), matching: noteField),
          )
          .controller;
    }

    testWidgets('opens on the line below New Note when it will be named', (
      tester,
    ) async {
      await pumpApp(tester, titleModel: _InstantTitles('Unused'));
      final field = await newNote(tester);
      expect(field.text, Note.blankBody);
      expect(field.selection, const TextSelection.collapsed(offset: 9));
      expect(notes.notes.first.title, 'New Note');
    });

    testWidgets('opens on New Note, selected, where nothing will name it', (
      tester,
    ) async {
      await pumpApp(tester);
      final field = await newNote(tester);
      expect(field.text, Note.blankBody);
      expect(
        field.selection,
        const TextSelection(baseOffset: 0, extentOffset: 8),
      );

      field.value = const TextEditingValue(
        text: 'Groceries\n',
        selection: TextSelection.collapsed(offset: 9),
      );
      await tester.pumpAndSettle();
      expect(
        notes.notes.first.title,
        'Groceries',
        reason: 'typed, it names it',
      );
    });

    testWidgets('with the setting off, opens on New Note, selected', (
      tester,
    ) async {
      prefs.autoTitlesEnabled = false;
      await pumpApp(tester, titleModel: _InstantTitles('Unused'));
      final field = await newNote(tester);
      expect(
        field.selection,
        const TextSelection(baseOffset: 0, extentOffset: 8),
      );
    });

    testWidgets('a caret in New Note takes all of it', (tester) async {
      await pumpApp(tester, titleModel: _InstantTitles('Unused'));
      final field = await newNote(tester);

      field.selection = const TextSelection.collapsed(offset: 3);
      await tester.pump();
      expect(
        field.selection,
        const TextSelection(baseOffset: 0, extentOffset: 8),
      );

      field.selection = const TextSelection.collapsed(offset: 8);
      await tester.pump();
      expect(
        field.selection,
        const TextSelection.collapsed(offset: 9),
        reason: 'right out of the title goes to the line below',
      );

      field.selection = const TextSelection(baseOffset: 0, extentOffset: 8);
      field.value = const TextEditingValue(
        text: 'Trip\n',
        selection: TextSelection.collapsed(offset: 4),
      );
      await tester.pumpAndSettle();
      expect(notes.notes.first.title, 'Trip');
      field.selection = const TextSelection.collapsed(offset: 2);
      await tester.pump();
      expect(
        field.selection,
        const TextSelection.collapsed(offset: 2),
        reason: 'a title they wrote is edited like any line',
      );
    });

    testWidgets('left alone, it is let go like any blank note', (tester) async {
      await pumpApp(tester);
      final before = notes.notes.length;
      await newNote(tester);
      expect(notes.notes.length, before + 1);
      await newNote(tester);
      expect(notes.notes.length, before + 1, reason: 'the blank one is reused');
    });

    testWidgets('is named by the model on this device after a pause', (
      tester,
    ) async {
      final model = _InstantTitles('lisbon trip budget.');
      await pumpApp(tester, titleModel: model);
      final field = await newNote(tester);
      field.value = const TextEditingValue(
        text: 'New Note\n$trip',
        selection: TextSelection.collapsed(offset: 9 + trip.length),
      );
      await tester.pump();
      expect(model.asked, 0);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(model.asked, 1);
      expect(notes.notes.first.title, 'Lisbon trip budget');
      expect(field.text, 'Lisbon trip budget\n$trip');
    });

    testWidgets('a title the model sends once the person is in New Note '
        'loses to what they type', (tester) async {
      final model = _LaterTitles();
      await pumpApp(tester, titleModel: model);
      final field = await newNote(tester);
      field.value = const TextEditingValue(
        text: 'New Note\n$trip',
        selection: TextSelection.collapsed(offset: 9 + trip.length),
      );
      await tester.pump(const Duration(seconds: 4));
      expect(model.asked, hasLength(1));
      final editor = tester.state<NoteEditorState>(find.byType(NoteEditor));
      expect(editor.selectionInTitle, isFalse);

      field.selection = const TextSelection.collapsed(offset: 3);
      await tester.pump();
      expect(
        field.selection,
        const TextSelection(baseOffset: 0, extentOffset: 8),
      );
      expect(editor.selectionInTitle, isTrue);

      model.asked.single.complete('Lisbon trip budget');
      await tester.pumpAndSettle();
      expect(field.text, 'New Note\n$trip');
      expect(notes.notes.first.title, 'New Note');

      field.value = const TextEditingValue(
        text: 'Holiday\n$trip',
        selection: TextSelection.collapsed(offset: 7),
      );
      await tester.pumpAndSettle();
      expect(field.text, 'Holiday\n$trip');
      expect(notes.notes.first.body, 'Holiday\n$trip');

      field.value = const TextEditingValue(
        text: 'New Note\n$trip',
        selection: TextSelection.collapsed(offset: 9 + trip.length),
      );
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(
        model.asked,
        hasLength(1),
        reason: 'named by the person for good, even put back to New Note',
      );
    });

    testWidgets('a note from another device is not named here', (tester) async {
      store.data['notes.v1'] = [
        {
          'id': 'from-the-phone',
          'body': 'New Note\n',
          'createdAt': 1000,
          'updatedAt': 2000,
        },
      ];
      final model = _InstantTitles('Lisbon trip');
      await pumpApp(tester, titleModel: model);
      await tester.enterNote('New Note\n$trip');
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(model.asked, 0);
      expect(notes.byId('from-the-phone')!.title, 'New Note');
    });

    testWidgets('with the setting off it stays New Note', (tester) async {
      final model = _InstantTitles('Lisbon trip');
      prefs.autoTitlesEnabled = false;
      await pumpApp(tester, titleModel: model);
      final field = await newNote(tester);
      field.value = const TextEditingValue(
        text: 'New Note\n$trip',
        selection: TextSelection.collapsed(offset: 9 + trip.length),
      );
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(model.asked, 0);
      expect(notes.notes.first.title, 'New Note');
    });
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
    final field = tester.widget<NoteField>(
      find.descendant(of: find.byType(NoteEditor), matching: noteField),
    );
    await tester.enterNote('Earlier thought\n\nMore');
    await tester.pumpAndSettle();
    // Somewhere in the middle, which is the position worth keeping: the end
    // is where an append session would have put it anyway.
    field.controller.selection = const TextSelection.collapsed(offset: 5);
    await tester.pump();
    field.focusNode.unfocus();
    await tester.pump();

    integration.onOpenRequested!();
    await tester.pump();

    // No blank lines appended, and the caret is still where it was left.
    expect(field.controller.text, 'Earlier thought\n\nMore');
    expect(field.controller.selection.baseOffset, 5);
    expect(field.focusNode.hasFocus, isTrue);
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
    final field = tester.widget<NoteField>(
      find.descendant(of: find.byType(NoteEditor), matching: noteField),
    );

    expect(field.controller.text, 'Earlier thought\n\n');
    expect(field.controller.selection.baseOffset, field.controller.text.length);
    // And the blank line is presentation only until something is typed.
    expect(notes.notes.single.body, 'Earlier thought');
  });

  testWidgets('the page pins its note, and More keeps the window on top', (
    tester,
  ) async {
    await pumpApp(tester);
    final note = notes.create(body: 'alpha');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(NoteRow, 'alpha'));
    await tester.pumpAndSettle();

    // A button, so it answers at once rather than after the drag region's
    // double-tap timeout.
    final pin = find.byKey(const ValueKey('page-pin'));
    expect(
      find.ancestor(of: pin, matching: find.byType(WindowDragArea)),
      findsNothing,
    );
    await tester.tap(pin);
    await tester.pumpAndSettle();
    expect(notes.isPinned(note.id), isTrue);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('page-breadcrumb')),
        matching: find.text('Pinned'),
      ),
      findsOneWidget,
    );

    await pickPageAction(tester, 'on-top');
    expect(prefs.alwaysOnTop, isTrue);
    await tester.tap(find.byKey(const ValueKey('page-more')));
    await tester.pumpAndSettle();
    expect(find.text('Stop keeping on top'), findsOneWidget);
  });

  testWidgets('a first run opens on a page, with the notes list closed', (
    tester,
  ) async {
    // pumpApp speaks for an established user by default, so this is the one
    // place that asks for the state a new install actually starts in.
    await pumpApp(tester, sidebarVisible: false);

    expect(prefs.sidebarVisible, isFalse);
    // SplitView keeps the list mounted inside an OverflowBox and collapses
    // the container around it, so the list's own rect keeps its width either
    // way, the hide button in its header included, and geometry says nothing
    // here. The toolbar does: it offers to show the notes rather than to hide
    // them.
    expect(notesToggleWithLabel('Show notes'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(PageToolbar),
        matching: notesToggleWithLabel('Hide notes'),
      ),
      findsNothing,
    );
  });

  testWidgets(
    'a list open over a narrow page stands beside it once the window widens',
    (tester) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);

      final barrier = find.byKey(const ValueKey('sidebar-overlay-barrier'));

      await pumpApp(tester, size: const Size(620, 620), sidebarVisible: false);

      await tester.tap(notesToggleWithLabel('Show notes'));
      await tester.pumpAndSettle();
      expect(find.byType(Sidebar), findsOneWidget);
      expect(barrier, findsOneWidget);

      // Still on screen with room to stand beside the page, so it does.
      tester.view.physicalSize = const Size(760, 620);
      await tester.pumpAndSettle();
      expect(barrier, findsNothing);
      expect(prefs.sidebarVisible, isTrue);
      expect(
        tester.getRect(find.byType(Sidebar)).right,
        lessThanOrEqualTo(tester.getRect(find.byType(PageCard)).left),
      );

      // Narrowed again, the window folds it away and keeps every action.
      tester.view.physicalSize = const Size(622, 620);
      await tester.pumpAndSettle();
      expect(find.byType(Sidebar), findsNothing);
      expect(barrier, findsNothing);
      for (final key in ['page-show-list', 'page-new-note', 'page-share']) {
        expect(find.byKey(ValueKey(key)), findsOneWidget);
      }

      tester.view.physicalSize = const Size(760, 620);
      await tester.pumpAndSettle();
      expect(find.byType(Sidebar), findsOneWidget);
      expect(barrier, findsNothing);
    },
  );

  testWidgets(
    'Keep on top survives every desktop width, and never reaches a phone',
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
        await tester.tap(find.byKey(const ValueKey('page-more')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('page-more-on-top')),
          findsOneWidget,
          reason: 'Keep on top went missing at $size',
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
      }

      // A phone has no window to float, so the control is absent rather than
      // present and inert.
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      await pumpApp(tester, size: const Size(420, 800));
      expect(findKapyIcon(KapyIcons.pinOutlined), findsNothing);
      expect(findKapyIcon(KapyIcons.pinRounded), findsNothing);
      expect(find.byKey(const ValueKey('page-keep-on-top')), findsNothing);
    },
  );

  group('Keep on top button', () {
    final button = find.byKey(const ValueKey('page-keep-on-top'));
    bool lit(WidgetTester tester) =>
        tester.widget<CompactIconButton>(button).selected;

    testWidgets('stands left of More in Notes and Drawings, at every desktop '
        'width and with the list hidden', (tester) async {
      for (final size in [
        const Size(1100, 760),
        const Size(700, 620),
        LayoutPrefs.minimumWindowSize,
      ]) {
        for (final sidebarVisible in [true, false]) {
          await pumpApp(tester, size: size, sidebarVisible: sidebarVisible);
          for (final space in ['notes', 'drawings']) {
            await tester.tap(find.byKey(ValueKey('rail-$space')));
            await tester.pumpAndSettle();
            final reason = 'missing in $space at $size, list $sidebarVisible';
            expect(button, findsOneWidget, reason: reason);
            expect(
              tester.getRect(button).right,
              lessThan(
                tester.getRect(find.byKey(const ValueKey('page-more'))).left,
              ),
              reason: reason,
            );
          }
        }
      }
    });

    testWidgets('floats the window, says so, and keeps More in step', (
      tester,
    ) async {
      await pumpApp(tester);
      notes.create(body: 'alpha');
      await tester.pumpAndSettle();
      final chord = shortcuts
          .bindingFor(ShortcutAction.toggleAlwaysOnTop)!
          .displayLabel;
      expect(find.byTooltip('Keep on top  $chord'), findsOneWidget);
      expect(lit(tester), isFalse);
      expect(prefs.alwaysOnTop, isFalse);

      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(prefs.alwaysOnTop, isTrue);
      expect(lit(tester), isTrue);
      expect(find.byTooltip('Keep on top: on  $chord'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('page-more')));
      await tester.pumpAndSettle();
      expect(find.text('Stop keeping on top'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('page-more-on-top')));
      await tester.pumpAndSettle();
      expect(prefs.alwaysOnTop, isFalse);
      expect(lit(tester), isFalse);
      await tester.tap(find.byKey(const ValueKey('page-more')));
      await tester.pumpAndSettle();
      expect(find.text('Keep on top'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(prefs.alwaysOnTop, isFalse);
      expect(lit(tester), isFalse);
    });

    testWidgets('leaves the editor focused, so typing carries on', (
      tester,
    ) async {
      await pumpApp(tester);
      notes.create(body: 'alpha');
      await tester.pumpAndSettle();
      expect(openNoteField(tester).focusNode.hasFocus, isTrue);

      await tester.tap(button);
      await tester.pumpAndSettle();

      expect(prefs.alwaysOnTop, isTrue);
      expect(openNoteField(tester).focusNode.hasFocus, isTrue);
    });

    testWidgets('the setting set elsewhere lights it', (tester) async {
      await pumpApp(tester);
      prefs.alwaysOnTop = true;
      await tester.pumpAndSettle();
      expect(lit(tester), isTrue);
    });
  });

  testWidgets('keeps exchange-rate status out of the toolbar', (tester) async {
    await pumpApp(tester);

    expect(find.byType(PageToolbar), findsOneWidget);
    expect(find.textContaining('Rates'), findsNothing);
  });

  testWidgets('uses compact toolbar surfaces on desktop', (tester) async {
    await pumpApp(tester);
    notes.create();
    await tester.pumpAndSettle();

    Finder pageButton(String key, Type type) => find.descendant(
      of: find.byKey(ValueKey(key)),
      matching: find.byType(type),
    );
    expect(
      tester.getSize(pageButton('page-pin', IconButton)),
      const Size.square(32),
    );
    expect(
      tester.getSize(pageButton('page-more', IconButton)),
      const Size.square(32),
    );
    expect(tester.getSize(pageButton('page-share', FilledButton)).height, 32);
    expect(
      tester.getSize(find.byType(NoteRow).first).height,
      NoteCardFace.height,
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
    await tester.tap(emptyStateNewNote());
    await tester.pumpAndSettle();

    await tester.enterNote('Weekend budget\ndinner = 64\ndinner * 3');
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
        of: find.byType(PageToolbar),
        matching: find.text('Weekend budget'),
      ),
      findsNothing,
    );
  });

  testWidgets('opens footer settings and resets desktop panel widths', (
    tester,
  ) async {
    store.data['sidebar.v1'] = 360.0;
    await pumpApp(tester);
    await tester.tap(emptyStateNewNote());
    await tester.pumpAndSettle();

    await openSettings(tester, section: SettingsSection.notes);

    // Twice over now: the sidebar row that opened it, and the dialog's title.
    expect(find.text('Settings'), findsWidgets);
    final dailyToggle = find.byKey(const ValueKey('daily-separators-toggle'));
    final compactSwitch = find.descendant(
      of: dailyToggle,
      matching: find.byKey(const ValueKey('compact-switch-indicator')),
    );
    expect(prefs.dailySeparatorsEnabled, isTrue);
    expect(tester.getSize(compactSwitch), const Size(34, 20));

    final readyToType = find.byKey(
      const ValueKey('ready-to-type-on-open-toggle'),
    );
    expect(prefs.readyToTypeOnOpen, isTrue);
    await tester.tap(readyToType);
    await tester.pumpAndSettle();
    expect(prefs.readyToTypeOnOpen, isFalse);

    // The window's own rows have a pane of their own.
    await tester.tap(find.byKey(const ValueKey('settings-section-window')));
    await tester.pumpAndSettle();
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
    expect(prefs.sidebarWidth, LayoutPrefs.defaultSidebarWidth);
  });

  testWidgets('spell check is native, subtle, and can be turned off', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(emptyStateNewNote());
    await tester.pumpAndSettle();

    expect(prefs.spellCheckEnabled, isTrue);
    expect(
      tester.widget<NoteEditor>(find.byType(NoteEditor)).spellCheckEnabled,
      isTrue,
    );
    await tester.tap(
      find.descendant(of: find.byType(NoteEditor), matching: noteField),
    );
    await tester.pump();
    expect(tester.testTextInput.setClientArgs!['autocorrect'], isFalse);

    await openSettings(tester, section: SettingsSection.notes);
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

  testWidgets('settings heads its groups in Shantell and its rows in Figtree', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(emptyStateNewNote());
    await tester.pumpAndSettle();
    await openSettings(tester, section: SettingsSection.notes);

    final settings = find.byType(SettingsDialog);
    TextStyle styleOf(String label) {
      final finder = find.descendant(of: settings, matching: find.text(label));
      return DefaultTextStyle.of(
        tester.element(finder.first),
      ).style.merge(tester.widget<Text>(finder.first).style);
    }

    expect(styleOf('Opening').fontFamily, 'Shantell Sans');
    expect(styleOf('Daily separators').fontFamily, isNot('Shantell Sans'));
    expect(
      styleOf('Add a dated line when a new day begins').fontWeight ??
          FontWeight.w400,
      FontWeight.w400,
    );
  });

  testWidgets('selects and persists the note time zone from settings', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(emptyStateNewNote());
    await tester.pumpAndSettle();
    await openSettings(tester, section: SettingsSection.notes);

    final setting = find.byKey(const ValueKey('time-zone-setting'));
    await tester.ensureVisible(setting);
    // Named for what it is; the zone in use is on its button.
    expect(
      find.descendant(of: setting, matching: find.text('Time zone for dates')),
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
    await tester.tap(emptyStateNewNote());
    await tester.pumpAndSettle();
    await tester.enterNote(
      'Daily log',
      find.descendant(of: find.byType(NoteEditor), matching: noteField),
    );
    await tester.pumpAndSettle();
    final id = notes.notes.single.id;

    await openSettings(tester, section: SettingsSection.notes);
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
    await tester.tap(emptyStateNewNote());
    await tester.pumpAndSettle();
    await openSettings(tester, section: SettingsSection.notes);

    final credit = find.byKey(const ValueKey('rate-attribution'));
    await tester.ensureVisible(credit);
    expect(find.text('Rates by Frankfurter'), findsOneWidget);
    expect(find.text('Exchange rates updated 01 Sep 2026'), findsOneWidget);

    await tester.ensureVisible(credit);
    await tester.tap(credit);
    await tester.pumpAndSettle();

    expect(launched, ['https://frankfurter.dev']);
  });

  testWidgets('switches the number system and reformats live', (tester) async {
    await pumpApp(tester);
    await tester.tap(emptyStateNewNote());
    await tester.pumpAndSettle();
    await tester.enterNote('rev = 7000000');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ResultChip, '7,000,000'), findsOneWidget);
    expect(
      find.byTooltip('Seven million\n7 million\nClick to copy'),
      findsOneWidget,
    );

    await openSettings(tester, section: SettingsSection.notes);
    final indian = find.byKey(const ValueKey('number-system-indian'));
    await tester.ensureVisible(indian);
    await tester.pumpAndSettle();
    await tester.tap(indian);
    await tester.pumpAndSettle();
    expect(prefs.numberSystem, NumberSystem.indian);

    await tester.tap(find.byKey(const ValueKey('settings-done')));
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
    await tester.tap(emptyStateNewNote());
    await tester.pumpAndSettle();

    NoteField editor() => tester.widget<NoteField>(
      find.descendant(of: find.byType(NoteEditor), matching: noteField),
    );

    expect(prefs.writingFont, WritingFont.clean);
    expect(editor().style.fontFamily, WritingFont.clean.fontFamily);

    await openSettings(tester, section: SettingsSection.appearance);
    expect(find.text('Writing font'), findsOneWidget);
    for (final font in WritingFont.values) {
      expect(find.byKey(ValueKey('writing-font-${font.name}')), findsOneWidget);
    }
    // Each choice is named in the type it sets.
    Text labelOf(WritingFont font) => tester.widget<Text>(
      find.descendant(
        of: find.byKey(ValueKey('writing-font-${font.name}')),
        matching: find.byType(Text),
      ),
    );
    expect(
      labelOf(WritingFont.handwritten).style?.fontVariations,
      WritingFont.handwritten.fontVariations,
    );
    expect(
      labelOf(WritingFont.mixed).style?.fontFamily,
      WritingFont.monospace.fontFamily,
      reason: 'Mixed is named in the type its numbers are set in',
    );

    final monospace = find.byKey(const ValueKey('writing-font-monospace'));
    await tester.ensureVisible(monospace);
    await tester.pumpAndSettle();
    await tester.tap(monospace);
    await tester.pumpAndSettle();
    expect(prefs.writingFont, WritingFont.monospace);
    expect(editor().style.fontFamily, WritingFont.monospace.fontFamily);

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

    double editorFontSize() => openNoteField(tester).style.fontSize!;
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
    await tester.tap(emptyStateNewNote());
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
    // One slider whose left end is Off: moving it turns the mode on.
    final slider = find.byKey(const ValueKey('transparency-slider'));
    await tester.ensureVisible(slider);
    await tester.drag(slider, const Offset(40, 0));
    await tester.pumpAndSettle();

    expect(prefs.transparencyEnabled, isTrue);
    expect(windowGlassRequested, isTrue);
    expect(
      windowGlassAmount,
      prefs.transparencyAmount,
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
    expect((LayoutPrefs(store)..load()).transparencyEnabled, isTrue);

    // Further along thins the paint further.
    final amount = prefs.transparencyAmount;
    final partPaperAlpha = paperAlpha();
    await tester.drag(slider, const Offset(60, 0));
    await tester.pumpAndSettle();
    expect(prefs.transparencyAmount, greaterThan(amount));
    expect(paperAlpha(), lessThan(partPaperAlpha));
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

  testWidgets('transparency off is the slider at its Off end', (tester) async {
    await pumpApp(tester);
    await openSettings(tester, section: SettingsSection.appearance);
    final slider = tester.widget<Slider>(
      find.byKey(const ValueKey('transparency-slider')),
    );
    expect(prefs.transparencyEnabled, isFalse);
    expect(slider.value, 0);
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
    await tester.tap(emptyStateNewNote());
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
    await tester.tap(emptyStateNewNote());
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
        find.descendant(of: find.byType(NoteEditor), matching: noteField),
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
    await openSettings(tester, section: SettingsSection.window);

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
    await openSettings(tester, section: SettingsSection.window);

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

    await tester.tap(emptyStateNewNote());
    await tester.pumpAndSettle();
    await tester.enterNote(
      'petrol 40',
      find.descendant(of: find.byType(NoteEditor), matching: noteField),
    );
    await tester.pumpAndSettle();

    expect(integration.onNewNoteRequested, isNotNull);
    integration.onNewNoteRequested!();
    await tester.pumpAndSettle();

    expect(notes.notes, hasLength(2));
    // The new note is the one being edited, and the old one is untouched.
    final editor = tester.widget<NoteField>(
      find.descendant(of: find.byType(NoteEditor), matching: noteField),
    );
    expect(editor.controller.text, Note.blankBody);
    expect(notes.notes.last.body, startsWith('petrol 40'));
  });

  testWidgets('shows and records every editable desktop shortcut', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(emptyStateNewNote());
    await tester.pumpAndSettle();
    await openSettings(tester, section: SettingsSection.shortcuts);

    // The shortcuts another app can refuse lead the pane, then the in-app
    // keys by what they act on: the list, the panes beside it, the window,
    // what goes into a note, and how it is formatted.
    Finder label(String text) => find.byWidgetPredicate(
      (widget) => widget is SettingsLabel && widget.text == text,
    );
    const headings = [
      'From anywhere',
      'Notes and search',
      'Panes',
      'Window',
      'Writing',
      'Formatting',
    ];
    for (final heading in headings) {
      expect(label(heading), findsOneWidget);
    }
    for (var index = 1; index < headings.length; index++) {
      expect(
        tester.getTopLeft(label(headings[index - 1])).dy,
        lessThan(tester.getTopLeft(label(headings[index])).dy),
      );
    }
    // The rail shows one pane at a time, so the general options are gone.
    expect(find.text('Daily separators'), findsNothing);
    for (final action in ShortcutAction.values) {
      if (action == ShortcutAction.toggleKapyAi && !kapyAiAvailable) continue;
      expect(find.text(action.label), findsWidgets);
    }

    final findButton = find.byKey(const ValueKey('shortcut-findNotes'));
    await tester.ensureVisible(findButton);
    await tester.tap(findButton);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('shortcut-recording-note')),
      findsOneWidget,
    );

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

  testWidgets('Keep on top answers from More in a narrow window', (
    tester,
  ) async {
    // The size a fresh install opens at.
    await pumpApp(tester, size: LayoutPrefs.defaultWindowSize);
    notes.create(body: 'alpha');
    await tester.pumpAndSettle();

    await pickPageAction(tester, 'on-top');
    expect(prefs.alwaysOnTop, isTrue);

    await pickPageAction(tester, 'on-top');
    expect(prefs.alwaysOnTop, isFalse);
  });

  testWidgets('rebinding a shortcut updates the hints already on screen', (
    tester,
  ) async {
    await pumpApp(tester);
    notes.create(body: 'alpha');
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byType(SpacesRail),
        matching: find.byTooltip(
          'Settings · ${shortcuts.bindingFor(ShortcutAction.openSettings)!.displayLabel}',
        ),
      ),
      findsOneWidget,
    );

    // More spells out Keep on top's shortcut, and keeps up with a new one.
    Finder onTopHint(String label) => find.descendant(
      of: find.byKey(const ValueKey('page-more-on-top')),
      matching: find.text(label),
    );
    final pin = shortcuts.bindingFor(ShortcutAction.toggleAlwaysOnTop)!;
    await tester.tap(find.byKey(const ValueKey('page-more')));
    await tester.pumpAndSettle();
    expect(onTopHint(pin.displayLabel), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

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

    await tester.tap(find.byKey(const ValueKey('page-more')));
    await tester.pumpAndSettle();
    expect(onTopHint('Cmd + Shift + J'), findsOneWidget);
  });

  testWidgets('a shortcut can be removed, and then answers nothing', (
    tester,
  ) async {
    await pumpApp(tester);
    notes.create(body: '2 + 2');
    await tester.pumpAndSettle();
    expect(prefs.resultsVisible, isTrue);

    await openSettings(tester, section: SettingsSection.shortcuts);
    final row = find.byKey(const ValueKey('shortcut-row-toggleResults'));
    final keys = find.byKey(const ValueKey('shortcut-toggleResults'));
    await tester.ensureVisible(keys);
    await tester.tap(keys);
    await tester.pumpAndSettle();

    // Backspace on its own takes it away.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();

    expect(shortcuts.bindingFor(ShortcutAction.toggleResults), isNull);
    // The row stays where it was — it is also the way to give the key back.
    expect(
      find.descendant(of: row, matching: find.text('None')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('settings-done')));
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
    expect(find.byKey(const ValueKey('shortcut-recording-note')), findsNothing);
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
      expect(openNoteField(tester).focusNode.hasFocus, isTrue);
      expect(sidebarOrder(), ['charlie', 'bravo', 'alpha']);

      // The first session has no usage history yet, so it falls back to the
      // visible list after the note already open. Further Tabs preview against
      // one frozen order while Control remains down.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tabWhileControlIsDown();
      expect(openNoteBody(tester), 'charlie');
      expect(openNoteField(tester).focusNode.hasFocus, isFalse);
      expect(sidebarOrder(), ['charlie', 'bravo', 'alpha']);
      await tabWhileControlIsDown();
      expect(openNoteBody(tester), 'bravo');
      expect(openNoteField(tester).focusNode.hasFocus, isFalse);
      expect(prefs.lastOpenedNoteId, openedBeforeSwitch);
      expect(sidebarOrder(), ['charlie', 'bravo', 'alpha']);

      // Releasing the switching modifier is the commit: the previewed editor
      // gets focus, and this note becomes the most recently used one without
      // disturbing the content store's newest-edited ordering.
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(openNoteField(tester).focusNode.hasFocus, isTrue);
      expect(prefs.lastOpenedNoteId, bravo.id);
      expect(notes.notes.map((note) => note.id), [
        charlie.id,
        bravo.id,
        alpha.id,
      ]);
      expect({
        for (final note in notes.notes) note.id: note.updatedAt,
      }, updatedAt);
      expect(sidebarOrder(), ['charlie', 'bravo', 'alpha']);

      // The note just left is now second in MRU order, so one more Ctrl+Tab is
      // a true two-note toggle rather than another step through the sidebar.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tabWhileControlIsDown();
      expect(openNoteBody(tester), 'alpha');
      expect(openNoteField(tester).focusNode.hasFocus, isFalse);
      expect(sidebarOrder(), ['charlie', 'bravo', 'alpha']);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(openNoteBody(tester), 'alpha');
      expect(openNoteField(tester).focusNode.hasFocus, isTrue);
      expect(prefs.lastOpenedNoteId, alpha.id);
      expect(sidebarOrder(), ['charlie', 'bravo', 'alpha']);

      // Shift only reverses direction. Letting go of it must not accidentally
      // commit a Ctrl+Shift+Tab session while Control is still held.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(openNoteBody(tester), 'charlie');
      expect(openNoteField(tester).focusNode.hasFocus, isFalse);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(openNoteField(tester).focusNode.hasFocus, isFalse);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(openNoteField(tester).focusNode.hasFocus, isTrue);
      expect(sidebarOrder(), ['charlie', 'bravo', 'alpha']);
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
      openNoteField(tester).controller.selection =
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
    expect(openNoteField(tester).focusNode.hasFocus, isFalse);

    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(openNoteField(tester).focusNode.hasFocus, isTrue);
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
    await pickPageAction(tester, 'split');
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
    expect(fieldInPane(tester, 0).focusNode.hasFocus, isTrue);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tab();

    // An already-visible note participates normally. Preview only activates
    // its pane; it does not duplicate it or leave the caret in the old pane.
    expect(panes(), ['Alpha', 'Bravo']);
    expect(selectedRow(), 'Bravo');
    expect(fieldInPane(tester, 0).focusNode.hasFocus, isFalse);
    expect(fieldInPane(tester, 1).focusNode.hasFocus, isFalse);

    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(prefs.lastOpenedNoteId, bravo.id);
    expect(fieldInPane(tester, 1).focusNode.hasFocus, isTrue);
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
    expect(fieldInPane(tester, 0).focusNode.hasFocus, isFalse);
    expect(fieldInPane(tester, 1).focusNode.hasFocus, isFalse);

    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(prefs.lastOpenedNoteId, charlie.id);
    expect(fieldInPane(tester, 0).focusNode.hasFocus, isTrue);
    expect(panes(), ['Charlie', 'Bravo']);

    // The next completed gesture returns to the note just replaced, while the
    // neighbouring pane is still untouched.
    await pressShortcut(tester, shortcuts.bindingFor(ShortcutAction.nextNote)!);
    expect(prefs.lastOpenedNoteId, alpha.id);
    expect(fieldInPane(tester, 0).focusNode.hasFocus, isTrue);
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

    // More's Split view opens an empty pane beside the note, and
    // the list fills whichever pane has the focus: the new one.
    await pickPageAction(tester, 'split');
    expect(find.byType(EditorPaneFrame), findsNWidgets(2));
    expect(find.text('Choose a note'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('page-more')));
    await tester.pumpAndSettle();
    expect(
      find.text('Choose a note for this pane first'),
      findsOneWidget,
      reason: 'no second blank beside the first',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

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
    expect(fieldInPane(tester, 0).focusNode.hasFocus, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(fieldInPane(tester, 0).focusNode.hasFocus, isTrue);
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
    expect(fieldInPane(tester, 1).focusNode.hasFocus, isTrue);

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
    await tester.tap(find.byKey(const ValueKey('page-more')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<PopupMenuItem<String>>(
            find.byKey(const ValueKey('page-more-split')),
          )
          .enabled,
      isFalse,
    );
    expect(find.text('Up to three notes side by side'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await press(ShortcutAction.focusSecondPane);
    expect(fieldInPane(tester, 1).focusNode.hasFocus, isTrue);
    await press(ShortcutAction.focusThirdPane);
    expect(fieldInPane(tester, 2).focusNode.hasFocus, isTrue);
    await press(ShortcutAction.focusFirstPane);
    expect(fieldInPane(tester, 0).focusNode.hasFocus, isTrue);

    // Every pane is a live editor on its own note.
    await tester.enterNote(
      'Middle note, edited',
      find.descendant(
        of: find.byType(EditorPaneFrame).at(1),
        matching: noteField,
      ),
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
    expect(fieldInPane(tester, 1).focusNode.hasFocus, isTrue);

    // A pane that is not there cannot take the focus.
    await press(ShortcutAction.focusThirdPane);
    expect(fieldInPane(tester, 1).focusNode.hasFocus, isTrue);
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

  testWidgets('results have a shortcut like the notes list', (tester) async {
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

    // Cmd+R hides the results at the ends of their lines and brings them
    // back; Cmd+S does the same for the list on the left. Notes autosave, so
    // the conventional save chord is free for the pane itself.
    expect(find.widgetWithText(ResultChip, '4'), findsOneWidget);
    await press(LogicalKeyboardKey.keyR);
    expect(prefs.resultsVisible, isFalse);
    expect(find.byType(ResultChip), findsNothing);

    await press(LogicalKeyboardKey.keyR);
    expect(prefs.resultsVisible, isTrue);
    expect(find.widgetWithText(ResultChip, '4'), findsOneWidget);

    await press(LogicalKeyboardKey.keyS);
    expect(prefs.sidebarVisible, isFalse);
  });

  testWidgets('the notes shortcut opens and closes the list over a narrow page', (
    tester,
  ) async {
    await pumpApp(tester, size: const Size(600, 700));
    notes.create(body: 'Narrow note');
    await tester.pumpAndSettle();

    final binding = shortcuts.bindingFor(ShortcutAction.toggleSidebar)!;
    expect(find.byType(Sidebar), findsNothing);

    await pressShortcut(tester, binding);
    expect(find.byType(Sidebar), findsOneWidget);
    // The list takes the keyboard, so nothing typed lands in the note under it.
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'sidebar-overlay');

    await pressShortcut(tester, binding);
    expect(find.byType(Sidebar), findsNothing);
    // A wide window's list is a choice of its own, and stays as it was.
    expect(prefs.sidebarVisible, isTrue);
  });

  testWidgets('the show-list tooltip includes its current shortcut', (
    tester,
  ) async {
    await pumpApp(tester, sidebarVisible: false);

    final tooltip = tester.widget<Tooltip>(
      find
          .descendant(
            of: find.byKey(const ValueKey('page-show-list')),
            matching: find.byType(Tooltip),
          )
          .first,
    );
    expect(
      tooltip.message,
      contains(
        shortcuts.bindingFor(ShortcutAction.toggleSidebar)!.displayLabel,
      ),
    );
  });

  testWidgets('a phone opens Settings from the end of its bar', (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    await pumpApp(tester, size: const Size(390, 844));
    await showNotesList(tester);

    final bar = tester.getRect(find.byKey(const ValueKey('phone-bar')));
    final settings = find.byKey(const ValueKey('bar-settings'));
    expect(tester.getRect(settings).right, closeTo(bar.right - 4, 1));

    await tester.tap(settings);
    await tester.pumpAndSettle();
    expect(find.byType(SettingsDialog), findsOneWidget);
  });

  testWidgets('desktop Settings has room for a calm two-pane layout', (
    tester,
  ) async {
    await pumpApp(tester, size: const Size(1100, 860));
    await openSettings(tester);

    expect(
      tester.getSize(find.byKey(const ValueKey('settings-dialog-content'))),
      const Size(940, 760),
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
    final rowRect = tester.getRect(find.byType(Sidebar));
    expect(menuRect.width, lessThanOrEqualTo(208));
    expect(menuRect.left, greaterThanOrEqualTo(rowRect.left));
    expect(menuRect.right, lessThanOrEqualTo(rowRect.right));
  });

  group('search', () {
    Finder menuField() => find.byKey(const ValueKey('command-menu-field'));
    Finder menuRow(String title) =>
        find.byKey(ValueKey('command-menu-row-$title'));

    Future<void> search(WidgetTester tester, String text) async {
      await tester.enterText(menuField(), text);
      await tester.pumpAndSettle();
    }

    testWidgets('the field opens the menu, and the list is never narrowed', (
      tester,
    ) async {
      await pumpApp(tester);
      notes.create(body: 'Groceries\nolive oil 12.50');
      notes.create(body: 'Car\ntyres 240');
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('sidebar-search-field')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: menuField(),
          matching: find.byWidgetPredicate(
            (widget) => widget is EditableText && widget.focusNode.hasFocus,
          ),
        ),
        findsOneWidget,
      );
      await search(tester, 'olive');

      expect(menuRow('Groceries'), findsOneWidget);
      expect(menuRow('Car'), findsNothing);
      // The matching line explains a result whose title does not.
      expect(
        find.descendant(
          of: menuRow('Groceries'),
          matching: find.textContaining('oil 12.50', findRichText: true),
        ),
        findsOneWidget,
      );
      expect(find.byType(NoteRow), findsNWidgets(2));

      await tester.tap(menuRow('Groceries'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('command-menu')), findsNothing);
      expect(
        tester
            .widget<NoteRow>(find.widgetWithText(NoteRow, 'Groceries'))
            .selected,
        isTrue,
      );
    });

    testWidgets('a setting it finds opens Settings on that pane', (
      tester,
    ) async {
      await pumpApp(tester);
      await tester.tap(find.byKey(const ValueKey('sidebar-search-field')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('command-menu-field')),
        'text size',
      );
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('command-menu')), findsNothing);
      expect(find.byType(SettingsDialog), findsOneWidget);
    });

    testWidgets('its shortcut, and Find\'s, open it over a hidden list, and '
        'it finds nested content', (tester) async {
      await pumpApp(tester, sidebarVisible: false);
      notes.create(
        body:
            '# Launch plan\n- Website\n  - Accessibility\n    - Check contrast tokens',
      );
      notes.create(body: 'Weekend errands\n- Buy coffee');
      await tester.pumpAndSettle();

      final binding = shortcuts.bindingFor(ShortcutAction.findNotes)!;
      expect(binding.logicalKey, LogicalKeyboardKey.keyK);
      await pressShortcut(tester, binding);
      expect(find.byKey(const ValueKey('command-menu')), findsOneWidget);
      expect(prefs.sidebarVisible, isFalse);

      await search(tester, 'launch contrast');
      expect(menuRow('Launch plan'), findsOneWidget);
      expect(menuRow('Weekend errands'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('command-menu')), findsNothing);

      await pressShortcut(
        tester,
        ShortcutBinding(
          logicalKey: LogicalKeyboardKey.keyF,
          physicalKey: PhysicalKeyboardKey.keyF,
          meta: binding.meta,
          control: binding.control,
        ),
      );
      expect(find.byKey(const ValueKey('command-menu')), findsOneWidget);
    });

    testWidgets('the words become a note, or a search Archive keeps', (
      tester,
    ) async {
      await pumpApp(tester);
      notes.archive(notes.create(body: 'Old Sintra plan').id);
      notes.create(body: 'Something else');
      await tester.pumpAndSettle();

      await pressShortcut(
        tester,
        shortcuts.bindingFor(ShortcutAction.findNotes)!,
      );
      await search(tester, 'sintra');
      await tester.tap(menuRow('1 more in Archive'));
      await tester.pumpAndSettle();

      expect(spaceTitle(tester), 'Archive');
      expect(
        tester
            .widgetList<NoteRow>(find.byType(NoteRow))
            .map((row) => row.note.title),
        ['Old Sintra plan'],
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('sidebar-search-field')),
          matching: find.text('sintra'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('sidebar-search-field')),
          matching: find.text('Search'),
        ),
        findsOneWidget,
      );

      await pressShortcut(
        tester,
        shortcuts.bindingFor(ShortcutAction.findNotes)!,
      );
      await search(tester, 'Call the garage');
      await tester.tap(menuRow('New note: Call the garage'));
      await tester.pumpAndSettle();
      expect(notes.notes.first.body, 'Call the garage');
      expect(notes.notes.first.isArchived, isFalse);
    });

    testWidgets('with words selected in a note, its key links instead', (
      tester,
    ) async {
      await pumpApp(tester);
      notes.create(body: 'Read the tram timetable');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(NoteRow, 'Read the tram timetable'));
      await tester.pumpAndSettle();

      final editor = find.descendant(
        of: find.byType(NoteEditor),
        matching: noteField,
      );
      await tester.tap(editor);
      await tester.pumpAndSettle();
      tester.widget<NoteField>(editor).controller.selection =
          const TextSelection(baseOffset: 9, extentOffset: 23);
      await tester.pump();
      await pressShortcut(
        tester,
        shortcuts.bindingFor(ShortcutAction.findNotes)!,
      );
      expect(find.byKey(const ValueKey('command-menu')), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      tester.widget<NoteField>(editor).controller.selection =
          const TextSelection.collapsed(offset: 4);
      await tester.pump();
      await pressShortcut(
        tester,
        shortcuts.bindingFor(ShortcutAction.findNotes)!,
      );
      expect(find.byKey(const ValueKey('command-menu')), findsOneWidget);
    });

    testWidgets('New drawing and the Go to keys work from anywhere', (
      tester,
    ) async {
      await pumpApp(tester);
      notes.create(body: 'Plain note');
      await tester.pumpAndSettle();

      await pressShortcut(
        tester,
        shortcuts.bindingFor(ShortcutAction.newDrawing)!,
      );
      expect(notes.notes.first.isDrawing, isTrue);
      expect(spaceTitle(tester), 'Drawings');

      await pressShortcut(
        tester,
        shortcuts.bindingFor(ShortcutAction.showArchive)!,
      );
      expect(spaceTitle(tester), 'Archive');
      await pressShortcut(
        tester,
        shortcuts.bindingFor(ShortcutAction.showNotes)!,
      );
      expect(spaceTitle(tester), 'My notes');
    });
  });

  testWidgets('creates a note from the plus beside search', (tester) async {
    // A phone's notes drawer. Beside the rail, New note sits in the bar over
    // the list instead; see the spaces rail group.
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    await notes.load();
    notes.create(body: 'Something written');
    await pumpApp(tester, size: const Size(390, 844));
    await showNotesList(tester);
    final before = notes.notes.length;
    final search = find.byKey(const ValueKey('sidebar-search-field'));
    final add = find.byKey(const ValueKey('sidebar-new-note'));

    expect(add, findsOneWidget);
    expect(tester.getCenter(add).dx, greaterThan(tester.getRect(search).right));

    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(notes.notes, hasLength(before + 1));
  });

  testWidgets('the list over a narrow page is the list beside a wide one', (
    tester,
  ) async {
    await notes.load();
    notes.create(body: 'Something written');
    await pumpApp(tester, size: const Size(600, 760));
    await showNotesList(tester);

    final rail = tester.getRect(find.byType(SpacesRail));
    final sidebar = tester.getRect(find.byType(Sidebar));
    final bar = tester.getRect(find.byType(SidebarWindowBar));
    final search = tester.getRect(
      find.byKey(const ValueKey('sidebar-search-field')),
    );

    expect(sidebar.left, rail.right);
    expect(sidebar.width, LayoutPrefs.defaultSidebarWidth);
    expect(bar.top, sidebar.top);
    expect(search.top, greaterThanOrEqualTo(bar.bottom));
    expect(search.left - sidebar.left, greaterThanOrEqualTo(12));
    expect(sidebar.right - search.right, greaterThanOrEqualTo(12));
    // New note sits in the bar, as it does beside the page.
    expect(
      find.descendant(
        of: find.byType(SidebarWindowBar),
        matching: find.byKey(const ValueKey('sidebar-new-note')),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'the search shortcut is a keycap that leaves the placeholder room',
    (tester) async {
      await pumpApp(tester);

      final binding = shortcuts.bindingFor(ShortcutAction.findNotes)!;
      final search = find.byKey(const ValueKey('sidebar-search-box'));
      final field = tester.getRect(search);
      final searchKeycap = find.descendant(
        of: search,
        matching: find.byType(Keycap),
      );
      final keycap = tester.getRect(searchKeycap);

      expect(
        find.descendant(
          of: searchKeycap,
          matching: find.text(binding.keycapLabel),
        ),
        findsOneWidget,
      );
      expect(keycap.right, lessThan(field.right));
      expect(field.right - keycap.right, lessThanOrEqualTo(12));
      expect(keycap.center.dy, closeTo(field.center.dy, 1));
      // The hint used to fill the field and leave the placeholder no width.
      expect(tester.getSize(find.text('Search')).width, greaterThan(40));
    },
  );

  group('draw mode', () {
    Finder plus() => find.byKey(const ValueKey('sidebar-new-note'));
    Finder draw() => find.byKey(const ValueKey('note-mode-draw'));

    testWidgets('a stroke across a drawing on a phone stays a stroke', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      store.data['notes.v1'] = [
        {
          'id': 'phone-drawing',
          'body': 'Sketch',
          'createdAt': 1000,
          'updatedAt': 1000,
          'drawing': {'elements': <Object?>[]},
        },
      ];
      await pumpApp(tester, size: const Size(420, 800));
      expect(find.byType(DrawingCanvas), findsOneWidget);

      // Long and sideways: the shape of a page swipe, which opened the notes
      // drawer or made a new note instead of leaving the line drawn.
      final surface = tester.getRect(
        find.byKey(const ValueKey('drawing-surface')),
      );
      await tester.dragFrom(
        surface.center - const Offset(120, 0),
        const Offset(240, 0),
      );
      await tester.pumpAndSettle();
      expect(find.byType(NoteRow), findsNothing);
      expect(notes.notes, hasLength(1));
      expect(notes.byId('phone-drawing')!.drawing!.elements, hasLength(1));
    });

    test('restoring an archive over a drawing keeps the canvas', () async {
      await notes.load();
      final note = notes.create();
      notes.setDrawingMode(note.id, drawing: true);
      notes.updateDrawing(
        note.id,
        NoteDrawing([
          DrawElement(
            id: 'r',
            kind: DrawKind.rect,
            points: const [0, 0, 40, 30],
            z: 0,
          ),
        ]),
      );
      // An archive holds no drawings yet: the note comes back as its title.
      final restored = notes
          .byId(note.id)!
          .copyWith(drawing: null, body: 'Plan');
      notes.importNotes([restored]);
      expect(notes.byId(note.id)!.drawing!.elements, hasLength(1));
      expect(notes.byId(note.id)!.body, 'Plan');
    });

    testWidgets('a new note can become a drawing, and back while blank', (
      tester,
    ) async {
      await pumpApp(tester);
      await tester.tap(plus());
      await tester.pumpAndSettle();
      final id = notes.notes.first.id;
      expect(draw(), findsOneWidget);

      await tester.tap(draw());
      await tester.pumpAndSettle();
      expect(notes.byId(id)!.isDrawing, isTrue);
      expect(find.byType(DrawingCanvas), findsOneWidget);
      expect(find.byType(NoteEditor), findsNothing);
      expect(notes.byId(id)!.title, 'Drawing');

      await tester.tap(find.byKey(const ValueKey('note-mode-write')));
      await tester.pumpAndSettle();
      expect(notes.byId(id)!.isDrawing, isFalse);
      expect(find.byType(NoteEditor), findsOneWidget);
    });

    testWidgets('strokes and a title are saved to the note', (tester) async {
      await pumpApp(tester);
      await tester.tap(plus());
      await tester.pumpAndSettle();
      final id = notes.notes.first.id;
      await tester.tap(draw());
      await tester.pumpAndSettle();

      final surface = tester.getRect(
        find.byKey(const ValueKey('drawing-surface')),
      );
      final gesture = await tester.startGesture(
        surface.center,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(40, 30));
      await gesture.moveBy(const Offset(40, -10));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(notes.byId(id)!.drawing!.elements, hasLength(1));
      // Something is in it now, so the choice has been made.
      expect(find.byKey(const ValueKey('note-mode-switch')), findsNothing);

      await tester.enterText(
        find.byKey(const ValueKey('drawing-title')),
        'Garden plan',
      );
      await tester.pumpAndSettle();
      expect(notes.byId(id)!.title, 'Garden plan');
      expect(notes.byId(id)!.drawing!.elements, hasLength(1));
    });

    testWidgets('a note with words in it offers no switch', (tester) async {
      await pumpApp(tester);
      await tester.tap(plus());
      await tester.pumpAndSettle();
      expect(draw(), findsOneWidget);

      await tester.enterNote(
        'Groceries',
        find.descendant(of: find.byType(NoteEditor), matching: noteField),
      );
      await tester.pumpAndSettle();
      expect(draw(), findsNothing);
      expect(notes.notes.first.isDrawing, isFalse);
    });
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

    testWidgets('an empty note from an older build is reused as New Note', (
      tester,
    ) async {
      store.data['notes.v1'] = [
        {'id': 'old-blank', 'body': '', 'createdAt': 1000, 'updatedAt': 2000},
      ];
      prefs.autoTitlesEnabled = true;
      await pumpApp(tester, titleModel: _InstantTitles('Unused'));
      await tester.tap(plus());
      await tester.pumpAndSettle();
      expect(notes.notes, hasLength(1));
      expect(notes.byId('old-blank')!.body, Note.blankBody);
      final field = tester
          .widget<NoteField>(
            find.descendant(of: find.byType(NoteEditor), matching: noteField),
          )
          .controller;
      expect(field.text, Note.blankBody);
      expect(
        field.selection,
        const TextSelection(baseOffset: 0, extentOffset: 8),
        reason: 'not made here, so nothing names it and the person does',
      );
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
      await pumpApp(tester, sidebarVisible: false);
      await tester.tap(find.byKey(const ValueKey('page-new-note')));
      await tester.pumpAndSettle();
      final made = notes.notes.length;

      await tester.tap(find.byKey(const ValueKey('page-new-note')));
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
      await showInFilter(tester, NotesShow.archive);
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
    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.text('Tue'), findsOneWidget);
    expect(find.widgetWithText(NoteRow, 'latest details'), findsOneWidget);

    await tester.tap(find.widgetWithText(NoteRow, 'Older'));
    await tester.pumpAndSettle();
    await tester.enterNote('Older\nchanged details');
    await tester.pumpAndSettle();

    expect(rowTitles(), ['Older', 'Latest']);
    expect(notes.notes.map((note) => note.id), ['older', 'latest']);
    expect(
      tester
          .widget<NoteCardFace>(
            find.byWidgetPredicate(
              (widget) => widget is NoteCardFace && widget.note.id == 'older',
            ),
          )
          .date,
      'Today, 09:10',
    );
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
    expect(
      find.descendant(of: find.byType(Sidebar), matching: find.text('Pinned')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.byType(Sidebar), matching: find.text('Notes')),
      findsOneWidget,
    );
    expect(rowTitles(), ['Reference', 'Today']);
    expect(notes.isPinned(reference.id), isTrue);

    await openNoteActions(tester, reference.id);
    expect(find.text('Unpin note'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('pin-note-${reference.id}')));
    await tester.pumpAndSettle();

    expect(find.text('Pinned'), findsNothing);
    // Back in the list, Reference takes its last-edited place again: opening
    // it does not lift it above Today.
    expect(rowTitles(), ['Today', 'Reference']);
    expect(notes.isPinned(reference.id), isFalse);
  });

  group('the notes list stays in last-edited order', () {
    final base = DateTime(2026, 11, 1, 9);

    Future<void> pumpSyncedNotes(WidgetTester tester) async {
      store = MemoryStore();
      store.data['notes.v1'] = [
        for (final (index, body) in ['Oldest', 'Middle', 'Newest'].indexed)
          {
            'id': body.toLowerCase(),
            'body': body,
            'createdAt': base.millisecondsSinceEpoch,
            'updatedAt': base
                .add(Duration(hours: index))
                .millisecondsSinceEpoch,
            'syncedAt': base.add(Duration(hours: index)).millisecondsSinceEpoch,
          },
      ];
      notes = NotesStore(store, now: () => DateTime(2026, 11, 18, 12));
      prefs = LayoutPrefs(store);
      rates = RatesRepository(store);
      shortcuts = ShortcutPrefs(store);
      await pumpApp(tester);
    }

    List<String> rowTitles(WidgetTester tester) => tester
        .widgetList<NoteRow>(find.byType(NoteRow))
        .map((row) => row.note.title)
        .toList();

    Map<String, DateTime> stamps() => {
      for (final note in notes.notes) note.id: note.updatedAt,
    };

    Future<void> open(WidgetTester tester, String title) async {
      await tester.tap(find.widgetWithText(NoteRow, title));
      await tester.pumpAndSettle();
      expect(openNoteBody(tester), startsWith(title));
    }

    testWidgets('opening and leaving notes neither moves nor syncs them', (
      tester,
    ) async {
      await pumpSyncedNotes(tester);
      final before = stamps();
      expect(rowTitles(tester), ['Newest', 'Middle', 'Oldest']);
      expect(notes.dirtyNotes, isEmpty);

      for (final title in ['Oldest', 'Middle', 'Newest', 'Oldest']) {
        await open(tester, title);
        expect(rowTitles(tester), ['Newest', 'Middle', 'Oldest']);
      }
      await open(tester, 'Newest');

      expect(stamps(), before);
      expect(notes.dirtyNotes, isEmpty);
    });

    testWidgets('switching between two notes keeps their places', (
      tester,
    ) async {
      await pumpSyncedNotes(tester);

      for (var round = 0; round < 3; round++) {
        await open(tester, 'Oldest');
        expect(rowTitles(tester), ['Newest', 'Middle', 'Oldest']);
        await open(tester, 'Middle');
        expect(rowTitles(tester), ['Newest', 'Middle', 'Oldest']);
      }
      expect(notes.dirtyNotes, isEmpty);
    });

    testWidgets('a real edit moves the note to the top, and only that', (
      tester,
    ) async {
      await pumpSyncedNotes(tester);
      await open(tester, 'Oldest');

      final field = openNoteField(tester);
      final edited = '${field.controller.text.trimRight()}\nmore';
      field.controller.value = TextEditingValue(
        text: edited,
        selection: TextSelection.collapsed(offset: edited.length),
      );
      await tester.pumpAndSettle();

      expect(rowTitles(tester), ['Oldest', 'Newest', 'Middle']);
      expect(notes.dirtyNotes.map((note) => note.id), ['oldest']);

      await open(tester, 'Middle');
      expect(rowTitles(tester), ['Oldest', 'Newest', 'Middle']);
      expect(notes.dirtyNotes.map((note) => note.id), ['oldest']);
    });
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

    await showInFilter(tester, NotesShow.archive);
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

      await openNoteActions(tester, private.id);
      await tester.tap(find.byKey(ValueKey('hide-note-${private.id}')));
      await tester.pumpAndSettle();
      expect(gate.configureCalls, 1);
      expect(notes.hiddenNotes.single.id, private.id);
      expect(notes.search('Private'), isEmpty);
      expect(
        find.text(
          'Moved to Hidden Notes. Press ${hiddenShortcut.displayLabel} to '
          'find it.',
        ),
        findsOneWidget,
      );

      // The shortcut opens Notes with Hidden chosen, behind the gate.
      await pressShortcut(tester, hiddenShortcut);
      expect(gate.unlockCalls, 1);
      expect(spaceTitle(tester), 'Hidden');
      expect(spaceCount(tester), '1');
      expect(find.widgetWithText(NoteRow, 'Private note'), findsOneWidget);
      expect(openNoteBody(tester), 'Private note');
      expect(
        find.byKey(const ValueKey('sidebar-hidden-locks-again')),
        findsOneWidget,
      );

      // Pressed again, it leaves Hidden, and Hidden locks behind it.
      await pressShortcut(tester, hiddenShortcut);
      expect(find.widgetWithText(NoteRow, 'Private note'), findsNothing);
      await showInFilter(tester, NotesShow.hidden);
      expect(gate.unlockCalls, 2, reason: 'entering again must authenticate');
      expect(find.widgetWithText(NoteRow, 'Private note'), findsOneWidget);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(NoteRow, 'Private note'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(NoteRow, 'Private note'), findsNothing);
      expect(gate.unlockCalls, 2);
    },
  );

  testWidgets('desktop Settings can list Hidden in the notes filter', (
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
    await tester.tap(find.byKey(const ValueKey('sidebar-notes-filter')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('notes-filter-hidden')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('notes-filter-all')));
    await tester.pumpAndSettle();

    await openSettings(tester, section: SettingsSection.notes);
    final toggle = find.byKey(const ValueKey('hidden-notes-sidebar-toggle'));
    final settingsScrollable = find.descendant(
      of: find.byType(Scrollbar),
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
          shortcuts.bindingFor(ShortcutAction.toggleHiddenFolder)!.keycapLabel,
        ),
      ),
      findsOneWidget,
    );
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(prefs.hiddenFolderVisible, isTrue);

    await tester.tap(find.byKey(const ValueKey('settings-done')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sidebar-notes-filter')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('notes-filter-hidden')), findsOneWidget);
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

    await showInFilter(tester, NotesShow.hidden);
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
      final syncState = SyncState(store);
      final account = Account(
        auth: FakeAuth(),
        syncApi: (_) =>
            FakeApi(FakeServer(), device: 'device-1', userId: 'user-1'),
        keys: KeyStore(InMemorySecureStore()),
        notes: notes,
        state: syncState,
        store: store,
        tags: TagStore(store),
        tasks: TaskLibrary(
          notes: notes,
          store: store,
          state: syncState,
          storage: MemoryDocStorage(),
        ),
      );
      addTearDown(account.dispose);
      await tester.runAsync(account.restore);
      expect(account.state, AccountState.signedOut);
      await notes.load();
      notes.create(body: 'Trip plan');
      await pumpApp(tester, account: account);

      await tester.tap(find.byKey(const ValueKey('page-share')));
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
          section: SettingsSection.notes,
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

    await showInFilter(tester, NotesShow.hidden);

    expect(gate.unlockCalls, 1);
    expect(find.widgetWithText(NoteRow, 'Still private'), findsNothing);
    expect(find.text('Hidden Notes is empty'), findsNothing);
  });

  testWidgets('a phone reaches Hidden and Archive from the filter, with no '
      'footer button or pull-down for them', (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    await notes.load();
    for (var index = 0; index < 30; index++) {
      notes.create(body: 'Note $index');
    }
    notes.hide(notes.create(body: 'Only private note').id);
    final gate = _HiddenGate();
    await pumpApp(tester, size: const Size(390, 844), hiddenNotesGate: gate);
    await showNotesList(tester);

    expect(find.byKey(const ValueKey('sidebar-hidden-notes')), findsNothing);
    expect(find.byKey(const ValueKey('sidebar-archive')), findsNothing);
    expect(find.text('Archived Notes'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('sidebar-notes-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notes-filter-hidden')));
    await tester.pumpAndSettle();

    expect(gate.unlockCalls, 1);
    expect(find.widgetWithText(NoteRow, 'Only private note'), findsOneWidget);
  });

  testWidgets('a phone says where to find a note after hiding it', (
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
    expect(notes.hiddenNotes.single.id, private.id);
    expect(
      find.text(
        'Moved to Hidden Notes. Choose Hidden in the notes filter to find it.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Pull down'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('sidebar-notes-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notes-filter-hidden')));
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
      await showInFilter(tester, NotesShow.archive);
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
    /// is the state these are about, and the one a click on the note already
    /// open leaves behind with the setting on.
    Future<void> listHasTheKeyboard(
      WidgetTester tester, {
      TargetPlatform platform = TargetPlatform.macOS,
    }) async {
      AppPlatform.debugTargetPlatformOverride = platform;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      store.data['readyToTypeOnOpen.v1'] = false;
      await pumpApp(tester);
    }

    /// Three notes, newest first, with the list showing them.
    Future<void> threeNotes(
      WidgetTester tester, {
      TargetPlatform platform = TargetPlatform.macOS,
    }) async {
      await listHasTheKeyboard(tester, platform: platform);
      for (final body in ['First', 'Second', 'Third']) {
        notes.create();
        notes.updateBody(notes.notes.first.id, body);
      }
      await tester.pumpAndSettle();
    }

    /// [key] with [modifiers] held: the archive shortcut, Cmd+Delete on a
    /// Mac, unless a test says otherwise.
    Future<void> chord(
      WidgetTester tester, {
      List<LogicalKeyboardKey> modifiers = const [LogicalKeyboardKey.metaLeft],
      LogicalKeyboardKey key = LogicalKeyboardKey.backspace,
    }) async {
      for (final modifier in modifiers) {
        await tester.sendKeyDownEvent(modifier);
      }
      await tester.sendKeyEvent(key);
      for (final modifier in modifiers.reversed) {
        await tester.sendKeyUpEvent(modifier);
      }
      await tester.pumpAndSettle();
    }

    testWidgets('never archives the clicked note on its own', (tester) async {
      await threeNotes(tester);

      await tester.tap(find.widgetWithText(NoteRow, 'Third'));
      await tester.pumpAndSettle();
      // Both keys a Mac calls delete: the big one and fn+delete. Nothing on
      // screen says the list has the keyboard, so either one may have been
      // meant for the note's text.
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();

      expect(notes.archivedNotes, isEmpty);
      expect(notes.notes.map((note) => note.title), [
        'Third',
        'Second',
        'First',
      ]);
      expect(find.text('Moved to Archive'), findsNothing);
    });

    testWidgets('archives the clicked note with Cmd+Delete, and the next one '
        'after it', (tester) async {
      await threeNotes(tester);

      await tester.tap(find.widgetWithText(NoteRow, 'Third'));
      await tester.pumpAndSettle();
      await chord(tester);

      expect(notes.archivedNotes.single.title, 'Third');
      expect(find.text('Moved to Archive'), findsOneWidget);

      // The list keeps the keyboard: archiving the open note hands the caret
      // to the note that takes its place, and the next press must still be
      // the list's and not that editor's. A Delete is nobody's there, so the
      // note now open keeps every letter.
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pumpAndSettle();
      expect(notes.notes.map((note) => note.title), ['Second', 'First']);

      await chord(tester);
      expect(
        notes.archivedNotes.map((note) => note.title),
        unorderedEquals(['Third', 'Second']),
      );
      expect(notes.notes.single.title, 'First');
    });

    testWidgets('answers Shift+Delete on Windows, and not Delete on its own', (
      tester,
    ) async {
      await threeNotes(tester, platform: TargetPlatform.windows);

      await tester.tap(find.widgetWithText(NoteRow, 'Third'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      expect(notes.archivedNotes, isEmpty);

      await chord(
        tester,
        modifiers: const [LogicalKeyboardKey.shiftLeft],
        key: LogicalKeyboardKey.delete,
      );
      expect(notes.archivedNotes.single.title, 'Third');
    });

    testWidgets('follows the archive shortcut when it is changed or cleared', (
      tester,
    ) async {
      await threeNotes(tester);
      shortcuts.update(
        ShortcutAction.deleteNote,
        const ShortcutBinding(
          logicalKey: LogicalKeyboardKey.backspace,
          physicalKey: PhysicalKeyboardKey.backspace,
          meta: true,
          shift: true,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(NoteRow, 'Third'));
      await tester.pumpAndSettle();
      await chord(tester);
      expect(notes.archivedNotes, isEmpty);

      const cmdShift = [
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.shiftLeft,
      ];
      await chord(tester, modifiers: cmdShift);
      expect(notes.archivedNotes.single.title, 'Third');

      shortcuts.clear(ShortcutAction.deleteNote);
      await tester.pumpAndSettle();
      await chord(tester, modifiers: cmdShift);
      await chord(tester);
      expect(notes.archivedNotes, hasLength(1));
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
        find.descendant(of: find.byType(NoteEditor), matching: noteField),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();

      expect(notes.archivedNotes, isEmpty);
      expect(notes.notes.first.title, 'Third');
    });

    testWidgets('leaves the note alone while search has the keyboard', (
      tester,
    ) async {
      await threeNotes(tester);
      await tester.tap(find.widgetWithText(NoteRow, 'Third'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('sidebar-search-field')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('command-menu-field')),
        'Third',
      );
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
      await chord(tester);
      expect(notes.notes, isEmpty);

      // The list still holds the keyboard, and now has nothing to answer
      // with. Pressing again must be a press that does nothing.
      await chord(tester);
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
      await showInFilter(tester, NotesShow.archive);

      await tester.tap(find.widgetWithText(NoteRow, 'Third'));
      await tester.pumpAndSettle();
      // Delete on its own asks nothing here either.
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pumpAndSettle();
      expect(find.text('Delete note?'), findsNothing);

      await chord(tester);

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
    expect(rowTitles(), ['Third', 'Second', 'First']);
    expect(openNoteField(tester).focusNode.hasFocus, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(selectedTitle(), 'Third');
    expect(rowTitles(), ['Third', 'Second', 'First']);

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
    expect(editor.focusNode.hasFocus, isTrue);
    expect(editor.controller.selection.isCollapsed, isTrue);
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
      await showInFilter(tester, NotesShow.archive);
      return notes.archivedNotes;
    }

    Future<void> confirm(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('confirm-delete')));
      await tester.pumpAndSettle();
    }

    testWidgets('the way into the archive is named beside its box', (
      tester,
    ) async {
      await pumpApp(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sidebar-notes-filter')));
      await tester.pumpAndSettle();

      // A bare box once sent people looking for a delete, so the word beside
      // it is what this pins, with the icon every archive action shares.
      final entry = find.byKey(const ValueKey('notes-filter-archive'));
      expect(entry, findsOneWidget);
      expect(
        find.descendant(of: entry, matching: find.text('Archive')),
        findsOneWidget,
      );
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

      await tester.tap(find.byKey(const ValueKey('rail-notes')));
      await tester.pumpAndSettle();
      await showInFilter(tester, NotesShow.archive);

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
      final mouse = await hoverNote(tester, note.id);
      expect(find.byKey(ValueKey('note-actions-${note.id}')), findsOneWidget);
      await mouse.removePointer();
    });
  });

  group('compact editor', () {
    testWidgets(
      'puts results at the ends of lines in a narrow desktop window',
      (tester) async {
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
        expect(find.byType(ResultLeader), findsWidgets);
        // The writing keeps the whole pane: nothing beside it but its margin.
        final field = tester.getRect(noteField);
        final pane = tester.getRect(find.byType(NoteEditor));
        expect(
          pane.right - field.right,
          lessThanOrEqualTo(EditorMetrics.padding.right),
        );
      },
    );

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

        expect(find.widgetWithText(ResultChip, '42'), findsOneWidget);
        await pressShortcut(
          tester,
          shortcuts.bindingFor(ShortcutAction.toggleResults)!,
        );

        expect(prefs.resultsVisible, isFalse);
        expect(find.byType(ResultChip), findsNothing);
      },
    );

    testWidgets('keeps results beside their lines on phones', (tester) async {
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
      expect(find.byType(ResultLeader), findsNothing);
    });

    testWidgets('the phone notes filter is a 44 pt target', (tester) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      await pumpApp(tester, size: const Size(390, 844));
      await showNotesList(tester);

      final filter = find.byKey(const ValueKey('sidebar-notes-filter'));
      expect(filter, findsOneWidget);
      expect(tester.getSize(filter).height, greaterThanOrEqualTo(44));
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

      final editable = tester.getRect(noteField);
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

      expect(find.byType(ResultLeader), findsNothing);
      final field = tester.widget<NoteField>(
        find.descendant(of: find.byType(NoteEditor), matching: noteField),
      );
      expect(
        field.controller.text,
        'September 2\nA calm place to keep the whole day.\n\n',
      );
      expect(
        field.controller.selection.baseOffset,
        field.controller.text.length,
      );
      expect(field.focusNode.hasFocus, isTrue);
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
    });

    testWidgets('raises the formatting bar over the phone keyboard', (
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

      final bar = find.byKey(const ValueKey('phone-format-bar'));
      expect(bar, findsNothing);
      expect(find.byType(NoteFooter), findsNothing);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();

      expect(bar, findsOneWidget);
      expect(tester.getRect(bar).bottom, closeTo(720 - 300, 0.01));
      // Settings is at the end of the list's bar, not under the thumb that
      // is writing.
      expect(find.byKey(const ValueKey('note-settings')), findsNothing);
      expect(
        tester
            .widget<SingleChildScrollView>(
              find.byKey(const ValueKey('phone-format-scroll')),
            )
            .scrollDirection,
        Axis.horizontal,
      );
      expect(openNoteField(tester).focusNode.hasFocus, isTrue);

      // A "/" on a new line opens Commands, which hides the keyboard.
      openNoteField(tester).controller.selection =
          const TextSelection.collapsed(offset: 18);
      await tester.pump();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'Phone budget\n6 * 7\n/',
          selection: TextSelection.collapsed(offset: 20),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('slash-command-menu')), findsOneWidget);

      const commandOrder = [
        'checklist',
        'bulletedList',
        'numberedList',
        'heading1',
        'heading2',
        'heading3',
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
      const finalCommandOrder = [
        'quote',
        'codeBlock',
        'formula',
        'table',
        'divider',
      ];
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
      // The inserts are one row of icons under the list, and a drawing is
      // a note of its own rather than something to insert.
      final inserts = tester.getRect(
        find.byKey(const ValueKey('slash-command-inserts')),
      );
      for (final command in ['image', 'video', 'voiceNote']) {
        final icon = tester.getRect(
          find.byKey(ValueKey('slash-command-$command')),
        );
        expect(icon.center.dy, closeTo(inserts.center.dy, 1));
      }
      expect(find.byKey(const ValueKey('slash-command-drawing')), findsNothing);
    });

    testWidgets(
      'holds the note above the home indicator and the bar on the keyboard',
      (tester) async {
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

        expect(find.byType(NoteFooter), findsNothing);
        expect(find.byKey(const ValueKey('phone-format-bar')), findsNothing);
        expect(
          tester.getRect(find.byType(NoteEditor)).bottom,
          closeTo(844, 0.01),
        );

        // The system takes the keyboard's height out of the inset it reports
        // for the home indicator.
        tester.view.padding = FakeViewPadding.zero;
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpAndSettle();
        final bar = tester.getRect(
          find.byKey(const ValueKey('phone-format-bar')),
        );
        expect(bar.height, 44);
        expect(bar.bottom, closeTo(844 - 300, 0.01));
      },
    );

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
        AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
        addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);

        await pumpApp(tester, size: const Size(420, 800));

        expect(find.byType(NoteEditor), findsOneWidget);
        expect(find.text('Edited last'), findsNothing);
        expect(find.byType(NoteRow), findsNothing);

        final field = tester.widget<NoteField>(noteField);
        expect(field.controller.text, 'Created last\n2 + 2\n\n');
        expect(notes.byId('created-last')!.body, 'Created last\n2 + 2');
        expect(
          field.controller.selection.baseOffset,
          field.controller.text.length,
        );
        expect(field.focusNode.hasFocus, isTrue);
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

      final field = tester.widget<NoteField>(noteField);
      expect(field.controller.text, 'Keep my place');
      expect(field.focusNode.hasFocus, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
    });

    testWidgets(
      'archive and hidden folders never raise a keyboard on the list',
      (tester) async {
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

        Future<void> choose(String show) async {
          await tester.tap(find.byKey(const ValueKey('sidebar-notes-filter')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(ValueKey('notes-filter-$show')));
          await tester.pumpAndSettle();
        }

        await choose('archive');
        expect(find.widgetWithText(NoteRow, 'Archived note'), findsOneWidget);
        expect(find.byType(NoteEditor), findsNothing);
        expect(tester.testTextInput.isVisible, isFalse);
        expect(
          tester.testTextInput.log.map((call) => call.method),
          isNot(contains('TextInput.show')),
        );

        tester.testTextInput.log.clear();
        await choose('all');
        await choose('hidden');
        expect(find.widgetWithText(NoteRow, 'Hidden note'), findsOneWidget);
        expect(find.byType(NoteEditor), findsNothing);
        expect(tester.testTextInput.isVisible, isFalse);
        expect(
          tester.testTextInput.log.map((call) => call.method),
          isNot(contains('TextInput.show')),
        );
      },
    );

    testWidgets('takes the formatting bar away with the note it belongs to', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      store.data['notes.v1'] = [
        {
          'id': 'drawer-bar',
          'body': 'Open the list',
          'createdAt': 1000,
          'updatedAt': 1000,
        },
      ];

      await pumpApp(tester, size: const Size(420, 800));
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      final bar = find.byKey(const ValueKey('phone-format-bar'));
      expect(bar, findsOneWidget);

      await showNotesList(tester);
      expect(find.widgetWithText(NoteRow, 'Open the list'), findsOneWidget);
      expect(bar, findsNothing);
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

    testWidgets('creates a ready-to-type note when the store is empty', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      await pumpApp(tester, size: const Size(420, 800));

      expect(notes.notes, hasLength(1));
      expect(find.byType(NoteEditor), findsOneWidget);
      final field = tester.widget<NoteField>(noteField);
      expect(field.controller.text, Note.blankBody);
      expect(field.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
    });

    testWidgets('restores editor focus and the keyboard on app resume', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      // A phone asks on every resume whether a widget was tapped meanwhile.
      // Nothing was.
      stubLaunchIntent(null);
      addTearDown(() => stubLaunchIntent(null, respond: false));
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

      final field = tester.widget<NoteField>(noteField);
      expect(field.focusNode.hasFocus, isTrue);
      expect(
        tester.testTextInput.log.map((call) => call.method),
        contains('TextInput.show'),
      );
    });
  });

  group('phone shell', () {
    setUp(() {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      store.data['notes.v1'] = [
        {
          'id': 'phone-shell',
          'body': 'Lisbon trip\nflights = 2 * 1147.50 eur',
          'createdAt': 1000,
          'updatedAt': 1000,
        },
      ];
    });
    tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

    testWidgets('opens on the note, ready to type, over its list', (
      tester,
    ) async {
      await pumpApp(tester, size: const Size(393, 852));

      expect(openNoteField(tester).focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      expect(find.byKey(const ValueKey('phone-bar')), findsNothing);
      expect(find.text('Notes'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('page-back')));
      await tester.pumpAndSettle();
      expect(find.byType(NoteEditor), findsNothing);
      expect(tester.testTextInput.isVisible, isFalse);
      expect(find.byKey(const ValueKey('phone-bar')), findsOneWidget);

      await tester.tap(find.widgetWithText(NoteRow, 'Lisbon trip'));
      await tester.pumpAndSettle();
      expect(find.byType(NoteEditor), findsOneWidget);
      expect(find.byKey(const ValueKey('phone-bar')), findsNothing);
    });

    testWidgets('the system back gesture leaves the page for the list', (
      tester,
    ) async {
      await pumpApp(tester, size: const Size(393, 852));
      expect(find.byType(NoteEditor), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(NoteEditor), findsNothing);
      expect(find.widgetWithText(NoteRow, 'Lisbon trip'), findsOneWidget);
    });

    testWidgets('the + makes a note and opens it with the keyboard up', (
      tester,
    ) async {
      await pumpApp(tester, size: const Size(393, 852));
      await showNotesList(tester);
      final before = notes.notes.length;

      await tester.tap(find.byKey(const ValueKey('phone-new')));
      await tester.pumpAndSettle();

      expect(notes.notes.length, before + 1);
      final field = openNoteField(tester);
      expect(field.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      expect(field.controller.selection.baseOffset, isNonNegative);
    });

    testWidgets('a long press on the + offers the rest of New', (tester) async {
      await pumpApp(tester, size: const Size(393, 852));
      await showNotesList(tester);

      await tester.longPress(find.byKey(const ValueKey('phone-new')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('phone-new-drawing')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('phone-new-drawing')));
      await tester.pumpAndSettle();
      expect(notes.notes.where((note) => note.isDrawing), hasLength(1));
      expect(find.byType(DrawingCanvas), findsOneWidget);
    });

    testWidgets('the bar moves between spaces and its targets are 44 pt', (
      tester,
    ) async {
      await pumpApp(tester, size: const Size(375, 667));
      await showNotesList(tester);

      for (final item in ['notes', 'drawings', 'settings']) {
        final size = tester.getSize(find.byKey(ValueKey('bar-$item')));
        expect(size.height, greaterThanOrEqualTo(44), reason: item);
        expect(size.width, greaterThanOrEqualTo(44), reason: item);
      }
      expect(
        tester.getSize(find.byKey(const ValueKey('phone-new'))),
        const Size(56, 56),
      );

      await tester.tap(find.byKey(const ValueKey('bar-drawings')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(NoteRow, 'Lisbon trip'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('bar-notes')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(NoteRow, 'Lisbon trip'), findsOneWidget);
    });

    testWidgets('Android uses Material\'s navigation bar and a back arrow', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
      await pumpApp(tester, size: const Size(412, 915));

      expect(find.text('Notes'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('page-back')));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);
    });
  });

  group('spaces rail', () {
    List<String> rowTitles(WidgetTester tester) => tester
        .widgetList<NoteRow>(find.byType(NoteRow))
        .map((row) => row.note.title)
        .toList();

    Future<void> openSpace(WidgetTester tester, String space) async {
      await tester.tap(find.byKey(ValueKey('rail-$space')));
      await tester.pumpAndSettle();
    }

    testWidgets('the bar names the open space and counts all of it', (
      tester,
    ) async {
      await notes.load();
      notes.create(body: 'Groceries');
      notes.create(body: 'Standup');
      await pumpApp(tester);

      expect(spaceTitle(tester), 'My notes');
      expect(spaceCount(tester), '2');
    });

    testWidgets('New note sits in the bar over the search, with its keycap', (
      tester,
    ) async {
      await notes.load();
      notes.create(body: 'Something written');
      await pumpApp(tester);

      final add = find.byKey(const ValueKey('sidebar-new-note'));
      final bar = tester.getRect(find.byType(SidebarWindowBar));
      final search = tester.getRect(
        find.byKey(const ValueKey('sidebar-search-field')),
      );
      expect(add, findsOneWidget);
      expect(tester.getCenter(add).dy, closeTo(bar.center.dy, 0.5));
      expect(tester.getRect(add).bottom, lessThanOrEqualTo(search.top));
      expect(
        find.descendant(
          of: add,
          matching: find.text(
            shortcuts.bindingFor(ShortcutAction.newNote)!.keycapLabel,
          ),
        ),
        findsOneWidget,
      );
      // The search field under it keeps clear of the list's edges.
      final sidebar = tester.getRect(find.byType(Sidebar));
      expect(search.left - sidebar.left, greaterThanOrEqualTo(12));
      expect(sidebar.right - search.right, greaterThanOrEqualTo(12));

      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(notes.notes, hasLength(2));
    });

    testWidgets('a list dragged narrow keeps the name, and New note its plus', (
      tester,
    ) async {
      await notes.load();
      notes.create(body: 'Something written');
      await pumpApp(tester);
      prefs.sidebarWidth = LayoutPrefs.minSidebarWidth;
      await tester.pumpAndSettle();

      final add = find.byKey(const ValueKey('sidebar-new-note'));
      expect(
        find.descendant(of: add, matching: find.text('New note')),
        findsNothing,
      );
      expect(
        find.byTooltip(
          'New note  ${shortcuts.bindingFor(ShortcutAction.newNote)!.displayLabel}',
        ),
        findsOneWidget,
      );
      expect(spaceTitle(tester), 'My notes');

      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(notes.notes, hasLength(2));
    });

    testWidgets('the bar puts the list away with the toolbar\'s own toggle', (
      tester,
    ) async {
      await pumpApp(tester);
      notes.create();
      await tester.pumpAndSettle();

      final binding = shortcuts.bindingFor(ShortcutAction.toggleSidebar)!;
      final hide = find.byKey(const ValueKey('sidebar-hide'));
      expect(
        find.descendant(
          of: find.byType(SidebarWindowBar),
          matching: find.byTooltip('Hide notes  ${binding.displayLabel}'),
        ),
        findsOneWidget,
      );
      // Drawn the way the design draws it: 30pt square, rounded to 8.
      expect(tester.getSize(hide), const Size.square(30));
      final button = tester.widget<IconButton>(
        find.descendant(of: hide, matching: find.byType(IconButton)),
      );
      expect(
        button.style!.shape!.resolve({}),
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      );

      await tester.tap(hide);
      await tester.pumpAndSettle();
      expect(prefs.sidebarVisible, isFalse);
      // The page moves up to the rail, with the canvas's margin on that side
      // too now that no list sits against it.
      expect(
        tester.getRect(find.byType(PageCard)).left,
        tester.getRect(find.byType(SpacesRail)).right + 12,
      );

      await tester.tap(notesToggleWithLabel('Show notes'));
      await tester.pumpAndSettle();
      expect(prefs.sidebarVisible, isTrue);
      expect(
        tester.getRect(find.byType(PageCard)).left,
        tester.getRect(find.byType(Sidebar)).right,
      );
    });

    testWidgets('Drawings lists only drawings, and New there makes one', (
      tester,
    ) async {
      store.data['notes.v1'] = [
        {'id': 'words', 'body': 'Words', 'createdAt': 2000, 'updatedAt': 2000},
        {
          'id': 'sketch',
          'body': 'Sketch',
          'createdAt': 1000,
          'updatedAt': 1000,
          'drawing': {'elements': <Object?>[]},
        },
      ];
      await pumpApp(tester);
      expect(rowTitles(tester), unorderedEquals(['Words', 'Sketch']));

      await openSpace(tester, 'drawings');
      expect(rowTitles(tester), ['Sketch']);
      expect(spaceTitle(tester), 'Drawings');
      expect(spaceCount(tester), '1');

      await openSpace(tester, 'notes');
      expect(rowTitles(tester), unorderedEquals(['Words', 'Sketch']));
      expect(spaceTitle(tester), 'My notes');

      // New in Drawings makes a drawing, so the list stays where it is.
      await openSpace(tester, 'drawings');
      await tester.tap(find.byKey(const ValueKey('sidebar-new-note')));
      await tester.pumpAndSettle();
      expect(spaceTitle(tester), 'Drawings');
      expect(spaceCount(tester), '2');
      expect(notes.notes, hasLength(3));
      expect(notes.notes.where((note) => note.isDrawing), hasLength(2));
      expect(find.byType(DrawingCanvas), findsOneWidget);
    });

    testWidgets('every New in Drawings makes a drawing', (tester) async {
      await notes.load();
      notes.create(body: 'Words');
      await pumpApp(tester);
      await openSpace(tester, 'drawings');

      // Each New opens a fresh drawing; the blank one before it is swept the
      // way a blank note is, so what counts is the drawing that is open.
      final opened = <String>[];
      void expectNewDrawing() {
        final canvas = tester.widget<DrawingCanvas>(find.byType(DrawingCanvas));
        final id = (canvas.key! as ValueKey<String>).value.substring(
          'drawing-'.length,
        );
        expect(opened, isNot(contains(id)));
        expect(notes.byId(id)!.isDrawing, isTrue);
        opened.add(id);
      }

      await tester.tap(find.byKey(const ValueKey('sidebar-empty-new-drawing')));
      await tester.pumpAndSettle();
      expectNewDrawing();

      await tester.tap(find.byKey(const ValueKey('sidebar-new-note')));
      await tester.pumpAndSettle();
      expectNewDrawing();

      await pressShortcut(
        tester,
        shortcuts.bindingFor(ShortcutAction.newNote)!,
      );
      expectNewDrawing();

      await tester.tap(notesToggleWithLabel('Hide notes'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('page-new-note')));
      await tester.pumpAndSettle();
      expectNewDrawing();

      await tester.tap(notesToggleWithLabel('Show notes'));
      await tester.pumpAndSettle();
      expect(spaceTitle(tester), 'Drawings');
      expect(notes.byId(opened.last), isNotNull);
    });

    testWidgets('Drawings has no media filter', (tester) async {
      await notes.load();
      notes.create(body: 'Words');
      await pumpApp(tester);
      Future<Finder> openFilter() async {
        await tester.tap(find.byKey(const ValueKey('sidebar-notes-filter')));
        await tester.pumpAndSettle();
        return find.byKey(const ValueKey('media-filter-voice'));
      }

      Future<void> closeFilter() async {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
      }

      expect(await openFilter(), findsOneWidget);
      await closeFilter();

      await openSpace(tester, 'drawings');
      expect(await openFilter(), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('notes-filter-all')),
          matching: find.text('All drawings'),
        ),
        findsOneWidget,
      );
      await closeFilter();

      await openSpace(tester, 'notes');
      expect(await openFilter(), findsOneWidget);
    });

    testWidgets('Drawings says so while there are none', (tester) async {
      await notes.load();
      notes.create(body: 'Words');
      await pumpApp(tester);

      await openSpace(tester, 'drawings');
      expect(find.byType(NoteRow), findsNothing);
      expect(find.text('No drawings yet'), findsOneWidget);
      expect(spaceCount(tester), '0');
    });

    testWidgets('Drawings never keeps a note on the page, and Notes gets '
        'it back', (tester) async {
      await notes.load();
      notes.create(body: 'Words');
      await pumpApp(tester);
      expect(openNoteBody(tester), 'Words');

      await openSpace(tester, 'drawings');
      expect(find.text('No drawings yet'), findsOneWidget);
      expect(find.byType(EmptyState), findsOneWidget);
      expect(noteField, findsNothing);
      expect(find.byType(DrawingCanvas), findsNothing);

      await openSpace(tester, 'notes');
      expect(openNoteBody(tester), 'Words');
    });

    testWidgets('Drawings opens its own first drawing in place of the note, '
        'and Notes gets the note back', (tester) async {
      store.data['notes.v1'] = [
        {'id': 'words', 'body': 'Words', 'createdAt': 2000, 'updatedAt': 2000},
        {
          'id': 'sketch',
          'body': 'Sketch',
          'createdAt': 1000,
          'updatedAt': 1000,
          'drawing': {'elements': <Object?>[]},
        },
      ];
      prefs.lastOpenedNoteId = 'words';
      await pumpApp(tester);
      expect(openNoteBody(tester), 'Words');

      await openSpace(tester, 'drawings');
      expect(noteField, findsNothing);
      expect(find.byType(DrawingCanvas), findsOneWidget);

      await openSpace(tester, 'notes');
      expect(find.byType(DrawingCanvas), findsNothing);
      expect(openNoteBody(tester), 'Words');
    });

    for (final leave in ['hidden', 'archived']) {
      testWidgets('a note $leave while Drawings has it parked does not come '
          'back on the page in Notes', (tester) async {
        store.data['notes.v1'] = [
          {
            'id': 'words',
            'body': 'Words',
            'createdAt': 2000,
            'updatedAt': 2000,
          },
          {
            'id': 'sketch',
            'body': 'Sketch',
            'createdAt': 1000,
            'updatedAt': 1000,
            'drawing': {'elements': <Object?>[]},
          },
        ];
        prefs.lastOpenedNoteId = 'words';
        await pumpApp(tester);
        expect(openNoteBody(tester), 'Words');

        await openSpace(tester, 'drawings');
        expect(find.byType(DrawingCanvas), findsOneWidget);
        if (leave == 'hidden') {
          notes.hide('words');
        } else {
          notes.archive('words');
        }
        await tester.pumpAndSettle();

        await openSpace(tester, 'notes');
        expect(noteField, findsNothing);
        expect(find.text('Words'), findsNothing);
        expect(find.byType(DrawingCanvas), findsOneWidget);
      });
    }

    testWidgets('Drawings with nothing to open offers no action on the note '
        'it is not showing', (tester) async {
      await notes.load();
      notes.create(body: 'Words');
      await pumpApp(tester);
      VoidCallback? press(String key) =>
          tester.widget<CompactIconButton>(find.byKey(ValueKey(key))).onPressed;
      Future<void> openMore() async {
        await tester.tap(find.byKey(const ValueKey('page-more')));
        await tester.pumpAndSettle();
      }

      expect(press('page-pin'), isNotNull);
      await openMore();
      expect(find.byKey(const ValueKey('page-more-hide')), findsOneWidget);
      expect(find.byKey(const ValueKey('page-more-archive')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      await openSpace(tester, 'drawings');
      expect(press('page-pin'), isNull);
      expect(
        tester
            .widget<TonalButton>(find.byKey(const ValueKey('page-share')))
            .onPressed,
        isNull,
      );
      await openMore();
      expect(find.byKey(const ValueKey('page-more-hide')), findsNothing);
      expect(find.byKey(const ValueKey('page-more-archive')), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Words'), findsNothing);
    });

    testWidgets('the archive opens from the filter, and its ✕ leaves it', (
      tester,
    ) async {
      await notes.load();
      notes.create(body: 'Kept');
      final done = notes.create(body: 'Done with');
      notes.archive(done.id);
      await pumpApp(tester);

      await showInFilter(tester, NotesShow.archive);
      expect(rowTitles(tester), ['Done with']);
      expect(spaceTitle(tester), 'Archive');
      expect(spaceCount(tester), '1');

      await tester.tap(find.byKey(const ValueKey('sidebar-filter-clear')));
      await tester.pumpAndSettle();
      expect(rowTitles(tester), ['Kept']);
      expect(spaceTitle(tester), 'My notes');
      expect(
        tester.getSemantics(find.byKey(const ValueKey('rail-notes'))),
        isSemantics(isSelected: true),
      );
    });

    testWidgets('the rail\'s gear teaches its shortcut and opens settings', (
      tester,
    ) async {
      await pumpApp(tester);

      final gear = find.byKey(const ValueKey('rail-settings'));
      final binding = shortcuts.bindingFor(ShortcutAction.openSettings)!;
      expect(gear, findsOneWidget);
      expect(
        find.byTooltip('Settings · ${binding.displayLabel}'),
        findsOneWidget,
      );
      // One way in: the page's toolbar no longer carries a second gear.
      expect(
        find.descendant(
          of: find.byType(PageToolbar),
          matching: findKapyIcon(KapyIcons.settingsOutlined),
        ),
        findsNothing,
      );

      await tester.tap(gear);
      await tester.pumpAndSettle();
      expect(find.byType(SettingsDialog), findsOneWidget);
    });

    testWidgets('the streak moves to the rail, and still says what it means', (
      tester,
    ) async {
      await notes.load();
      notes.create(body: 'Written today');
      await pumpApp(tester);

      final streak = find.byKey(const ValueKey('rail-streak'));
      expect(
        find.descendant(of: streak, matching: find.text('1 day')),
        findsOneWidget,
      );
      expect(find.byTooltip('1-day writing streak'), findsOneWidget);
      expect(find.byKey(const ValueKey('sidebar-streak')), findsNothing);
    });

    testWidgets(
      'the media filter keeps the notes holding a kind still ticked',
      (tester) async {
        await notes.load();
        final at = DateTime(2026, 11, 16, 9);
        notes.importNotes([
          Note(id: 'plain', body: 'Groceries', createdAt: at, updatedAt: at),
          Note(
            id: 'sketch',
            body: 'Floor plan',
            drawing: NoteDrawing.empty,
            createdAt: at,
            updatedAt: at,
          ),
        ]);
        await pumpApp(tester);
        final filter = find.byKey(const ValueKey('sidebar-notes-filter'));
        Future<void> tick(String kind) async {
          await tester.tap(find.byKey(ValueKey('media-filter-$kind')));
          await tester.pumpAndSettle();
        }

        await tester.tap(filter);
        await tester.pumpAndSettle();
        await tick('voice');
        await tick('video');
        await tick('image');
        expect(rowTitles(tester), ['Floor plan']);
        expect(
          find.descendant(of: filter, matching: find.text('Drawing')),
          findsOneWidget,
        );

        // The last kind ticked stays ticked: nothing ticked would read as a
        // library that had lost its notes.
        await tick('drawing');
        expect(rowTitles(tester), ['Floor plan']);

        await tick('all');
        expect(rowTitles(tester).toSet(), {'Groceries', 'Floor plan'});
        expect(
          find.descendant(of: filter, matching: find.text('All notes')),
          findsOneWidget,
        );
        expect(spaceCount(tester), '2');
      },
    );

    testWidgets('Pinned shows four notes, and See all the rest', (
      tester,
    ) async {
      await notes.load();
      for (var i = 1; i <= 6; i++) {
        notes.togglePinned(notes.create(body: 'Pinned $i').id);
      }
      await pumpApp(tester);

      expect(rowTitles(tester), hasLength(4));
      await tester.tap(find.byKey(const ValueKey('sidebar-see-all-pinned')));
      await tester.pumpAndSettle();
      expect(rowTitles(tester), hasLength(6));

      await tester.tap(find.byKey(const ValueKey('sidebar-pinned-back')));
      await tester.pumpAndSettle();
      expect(rowTitles(tester), hasLength(4));
    });

    testWidgets('the list and cards switch holds for the whole list', (
      tester,
    ) async {
      await notes.load();
      notes.togglePinned(notes.create(body: 'Pinned').id);
      notes.create(body: 'Loose');
      await pumpApp(tester);
      List<NoteRowStyle> styles() => tester
          .widgetList<NoteRow>(find.byType(NoteRow))
          .map((row) => row.style)
          .toList();

      expect(styles(), [NoteRowStyle.card, NoteRowStyle.card]);
      await tester.tap(find.byKey(const ValueKey('sidebar-view-list')));
      await tester.pumpAndSettle();
      expect(styles(), [NoteRowStyle.row, NoteRowStyle.row]);
      expect(prefs.noteCards, isFalse);
    });
  });

  group('narrow window', () {
    final barrier = find.byKey(const ValueKey('sidebar-overlay-barrier'));

    testWidgets('keeps the rail and the page, and folds the list away', (
      tester,
    ) async {
      await notes.load();
      notes.create(body: 'Narrow note');
      // The size every new window opens at.
      await pumpApp(tester, size: LayoutPrefs.defaultWindowSize);

      expect(find.byType(SpacesRail), findsOneWidget);
      expect(find.byType(Scaffold), findsNothing);
      // Shown, as far as a window with room for it is concerned.
      expect(prefs.sidebarVisible, isTrue);
      expect(find.byType(Sidebar), findsNothing);
      expect(notesToggleWithLabel('Show notes'), findsOneWidget);
      // The page stands a margin in from the rail, as in Paper's window with
      // the list hidden.
      expect(
        tester.getRect(find.byType(PageCard)).left,
        tester.getRect(find.byType(SpacesRail)).right + 12,
      );
    });

    testWidgets('opens the list over the page, and puts it away again', (
      tester,
    ) async {
      await notes.load();
      notes.create(body: 'First note');
      notes.create(body: 'Second note');
      await pumpApp(tester, size: const Size(600, 720));
      final page = tester.getRect(find.byType(PageCard));

      Future<void> open() async {
        await tester.tap(notesToggleWithLabel('Show notes'));
        await tester.pumpAndSettle();
        expect(find.byType(Sidebar), findsOneWidget);
        expect(barrier, findsOneWidget);
      }

      // Over the page, which keeps its place and its width.
      await open();
      expect(tester.getRect(find.byType(PageCard)), page);

      // A click on the page beside it.
      await tester.tapAt(Offset(page.right - 8, page.center.dy));
      await tester.pumpAndSettle();
      expect(find.byType(Sidebar), findsNothing);

      await open();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(Sidebar), findsNothing);

      await open();
      await tester.tap(find.byKey(const ValueKey('sidebar-hide')));
      await tester.pumpAndSettle();
      expect(find.byType(Sidebar), findsNothing);

      // A note chosen from it opens ready to type.
      await open();
      await tester.tap(find.widgetWithText(NoteRow, 'First note'));
      await tester.pumpAndSettle();
      expect(find.byType(Sidebar), findsNothing);
      expect(barrier, findsNothing);
      final field = tester.widget<NoteField>(
        find.descendant(of: find.byType(NoteEditor), matching: noteField),
      );
      expect(field.controller.text, startsWith('First note'));
      expect(field.focusNode.hasFocus, isTrue);

      // So does a new one.
      await open();
      final before = notes.notes.length;
      await tester.tap(find.byKey(const ValueKey('sidebar-new-note')));
      await tester.pumpAndSettle();
      expect(notes.notes, hasLength(before + 1));
      expect(find.byType(Sidebar), findsNothing);

      // None of it touched the list a wide window shows.
      expect(prefs.sidebarVisible, isTrue);
    });
  });

  group('window chrome', () {
    testWidgets(
      'keeps a narrow window\'s toolbar clear of macOS window controls',
      (tester) async {
        await pumpApp(tester, size: const Size(600, 630));
        notes.create();
        await tester.pumpAndSettle();

        // The rail still runs down the window's left edge and takes the
        // traffic lights, as it does in a wide window.
        expect(tester.getRect(find.byType(SpacesRail)).topLeft, Offset.zero);
        expect(
          tester.getTopLeft(notesToggleWithLabel('Show notes')).dx,
          greaterThanOrEqualTo(WindowChrome.trafficLightsWidth),
          reason: 'the toolbar overlapped the macOS traffic lights',
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

      final rail = tester.getRect(find.byType(SpacesRail));

      // The rail runs down the window's left edge, and its spaces start below
      // the strip the traffic lights are drawn in, which it keeps clear.
      expect(rail.topLeft, Offset.zero);
      expect(
        tester.getRect(find.byKey(const ValueKey('rail-notes'))).top,
        greaterThanOrEqualTo(WindowChrome.trafficLightsHeight),
      );
      // Everything else starts beside it, so the page's toolbar never steps
      // aside for controls that are not over it.
      expect(tester.getRect(find.byType(Sidebar)).left, rail.right);
      expect(
        tester.getRect(find.byType(PageCard)).left,
        greaterThanOrEqualTo(rail.right),
      );

      prefs.toggleSidebar();
      await tester.pumpAndSettle();

      expect(
        tester.getTopLeft(find.byKey(const ValueKey('page-show-list'))).dx,
        greaterThanOrEqualTo(WindowChrome.trafficLightsWidth),
      );
      expect(notesToggleWithLabel('Show notes'), findsOneWidget);
    }, skip: !WindowChrome.overlaysContent);

    testWidgets('runs one title bar across the rail and the notes list', (
      tester,
    ) async {
      await pumpApp(tester);
      notes.create();
      await tester.pumpAndSettle();

      final bar = tester.getRect(find.byType(SidebarWindowBar));
      expect(bar.top, 0);
      expect(bar.height, SpacesRail.titleBarHeight);
      expect(
        tester.getRect(find.byKey(const ValueKey('rail-notes'))).top,
        greaterThanOrEqualTo(bar.bottom),
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('sidebar-search-field'))).top,
        greaterThanOrEqualTo(bar.bottom),
      );
      // The page stands on the canvas, a margin in from the window's edges.
      final page = tester.getRect(find.byType(PageCard));
      expect(page.top, 12);
      expect(page.right, 1100 - 12);
    }, skip: !WindowChrome.overlaysContent);

    testWidgets('keeps every pane inside the display safe area', (
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

      // The rail, the bar over the list and the page all begin below the
      // status bar, while the canvas they stand on runs up behind it.
      expect(
        tester.getRect(find.byKey(const ValueKey('rail-notes'))).top,
        greaterThanOrEqualTo(safeTop),
      );
      expect(
        tester.getRect(find.byType(SidebarWindowBar)).top,
        greaterThanOrEqualTo(safeTop),
      );
      expect(tester.getTopLeft(find.byType(PageCard)).dy, safeTop + 12);
      expect(
        tester.getTopLeft(findKapyIcon(KapyIcons.addRounded).last).dy,
        greaterThanOrEqualTo(safeTop),
      );
      expect(
        tester.getRect(find.byType(ListView)).bottom,
        lessThanOrEqualTo(size.height - safeBottom),
      );

      // Editor: text stops short of the home indicator.
      expect(
        tester.getRect(noteField).bottom,
        lessThanOrEqualTo(size.height - safeBottom),
      );

      // Footer: the running total sits above it as well. A tablet reaches
      // this layout, where nothing else reserves that strip.
      expect(
        tester.getRect(find.byKey(const ValueKey('note-total'))).bottom,
        lessThanOrEqualTo(size.height - safeBottom),
      );
      // The page itself runs down to the canvas's margin, and its footer holds
      // the controls above the indicator rather than the page stopping short
      // over a band of canvas.
      expect(tester.getRect(find.byType(PageCard)).bottom, size.height - 12);
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
