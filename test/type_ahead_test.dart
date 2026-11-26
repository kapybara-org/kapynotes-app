import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/type_ahead.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/sync/sync_state.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';

class _Store extends LocalStore {
  _Store() : super(fileName: 'type-ahead-test.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
}

const _list = 'Groceries milk eggs';

/// KAP-388: keys typed right after a shortcut that opens a field go into that
/// field, however long the frame that builds it takes, and never into the
/// text the keyboard was in before.
///
/// Nothing pumps between the shortcut and the typing, as on a slow frame:
/// each key reaches the app, and one the app leaves alone goes on to the
/// field holding the keyboard as typing, the way the platform passes it on.
void main() {
  late _Store store;
  late NotesStore notes;
  late TaskLibrary tasks;
  late LayoutPrefs prefs;
  late ShortcutPrefs shortcuts;
  late String listId;

  setUpAll(loadTestFonts);

  setUp(() {
    store = _Store();
    store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
    notes = NotesStore(store, now: () => DateTime(2026, 11, 26, 9, 30));
    tasks = TaskLibrary(
      notes: notes,
      store: store,
      state: SyncState(store),
      storage: MemoryDocStorage(),
    );
    prefs = LayoutPrefs(store);
    shortcuts = ShortcutPrefs(store);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('kapynotes/window_material'),
          (call) async => false,
        );
  });

  Future<void> pump(WidgetTester tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1500, 800);
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await notes.load();
      listId = notes.create(body: _list).id;
      await tasks.load();
      await tasks.reconcileNow();
    });
    prefs.load();
    prefs.lastOpenedNoteId = listId;
    shortcuts.load();
    await tester.pumpWidget(
      KapyNotesApp(
        store: store,
        notes: notes,
        rates: RatesRepository(store),
        prefs: prefs,
        shortcuts: shortcuts,
        tasks: tasks,
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> chord(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool shift = false,
  }) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  }

  Future<void> press(WidgetTester tester, ShortcutAction action) async {
    final binding = shortcuts.bindingFor(action)!;
    expect(binding.control, isTrue);
    expect(binding.alt || binding.meta, isFalse);
    await chord(tester, binding.logicalKey, shift: binding.shift);
  }

  /// Types [text] with no frame in between.
  Future<void> type(WidgetTester tester, String text) async {
    for (final character in text.split('')) {
      final handled = await tester.sendKeyEvent(
        character == ' '
            ? LogicalKeyboardKey.space
            : LogicalKeyboardKey(character.toLowerCase().codeUnitAt(0)),
        character: character,
      );
      final input = tester.testTextInput;
      final state = input.editingState;
      if (handled || state == null) continue;
      final value = TextEditingValue.fromJSON(state);
      final typed = value.replaced(value.selection, character);
      input.editingState = typed.toJSON();
      input.updateEditingValue(typed);
      await tester.idle();
    }
  }

  /// Into the list's text with all of it selected.
  Future<void> selectAllOfTheList(WidgetTester tester) async {
    tester.state<NoteEditorState>(find.byType(NoteEditor).first).focusAtEnd();
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'note-editor:$listId',
    );
    await chord(tester, LogicalKeyboardKey.keyA);
    await tester.pumpAndSettle();
  }

  String focusedText(WidgetTester tester) => tester
      .widgetList<EditableText>(find.byType(EditableText))
      .firstWhere((field) => field.focusNode.hasPrimaryFocus)
      .controller
      .text;

  testWidgets('what is typed right after a new note goes into it', (
    tester,
  ) async {
    await pump(tester);
    await selectAllOfTheList(tester);

    await press(tester, ShortcutAction.newNote);
    await type(tester, 'zz');
    await tester.pumpAndSettle();

    expect(notes.byId(listId)!.body, _list);
    final made = notes.notes.firstWhere((note) => note.id != listId);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'note-editor:${made.id}',
    );
    expect(notes.byId(made.id)!.body, startsWith('zz'));
  });

  for (final (name, key, selected) in [
    ('the menu', LogicalKeyboardKey.keyK, false),
    ("find's own chord", LogicalKeyboardKey.keyF, true),
  ]) {
    testWidgets('what is typed right after $name opens goes into its field', (
      tester,
    ) async {
      await pump(tester);
      await selectAllOfTheList(tester);
      if (!selected) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
      }

      await chord(tester, key);
      await type(tester, 'milk');
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('command-menu')), findsOneWidget);
      expect(focusedText(tester), 'milk');
      expect(notes.byId(listId)!.body, _list);
    });
  }

  testWidgets('what is typed right after Link goes into its address', (
    tester,
  ) async {
    await pump(tester);
    await selectAllOfTheList(tester);

    await press(tester, ShortcutAction.formatLink);
    await type(tester, 'kapy');
    await tester.pumpAndSettle();

    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Link address');
    expect(focusedText(tester), 'kapy');
    expect(notes.byId(listId)!.body, _list);
  });

  testWidgets('what is typed right after a new task goes into it', (
    tester,
  ) async {
    await pump(tester);
    await selectAllOfTheList(tester);

    await press(tester, ShortcutAction.newTask);
    await type(tester, 'call');
    await tester.pumpAndSettle();

    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Add a task');
    expect(focusedText(tester), 'call');
    expect(notes.byId(listId)!.body, _list);
  });

  group('the hold itself', () {
    final first = TextEditingController();
    final second = TextEditingController();
    final firstFocus = FocusNode(debugLabel: 'first');
    final secondFocus = FocusNode(debugLabel: 'second');

    Future<void> fields(WidgetTester tester) async {
      first.value = const TextEditingValue(
        text: _list,
        selection: TextSelection(baseOffset: 0, extentOffset: _list.length),
      );
      second.clear();
      await tester.pumpWidget(
        MaterialApp(
          home: Material(
            child: Column(
              children: [
                TextField(controller: first, focusNode: firstFocus),
                TextField(controller: second, focusNode: secondFocus),
              ],
            ),
          ),
        ),
      );
      firstFocus.requestFocus();
      await tester.pumpAndSettle();
    }

    /// What a shortcut that opens [secondFocus]'s field does.
    void open() {
      TypeAhead.hold();
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => secondFocus.requestFocus(),
      );
    }

    Future<void> withControl(WidgetTester tester, LogicalKeyboardKey key) =>
        chord(tester, key);

    testWidgets('keeps letters, takes back what ⌫ erases, and pastes', (
      tester,
    ) async {
      await fields(tester);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => call.method == 'Clipboard.getData'
            ? <String, Object?>{'text': ' eggs'}
            : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      open();
      await type(tester, 'milx');
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await type(tester, 'k');
      await withControl(tester, LogicalKeyboardKey.keyV);
      await type(tester, '.');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await withControl(tester, LogicalKeyboardKey.keyX);
      await withControl(tester, LogicalKeyboardKey.keyZ);
      await tester.pumpAndSettle();

      expect(first.text, _list);
      expect(secondFocus.hasPrimaryFocus, isTrue);
      expect(second.text, 'milk eggs.');
      expect(second.selection, const TextSelection.collapsed(offset: 10));
    });

    testWidgets('lets go once the field has the keyboard', (tester) async {
      await fields(tester);
      open();
      await tester.pumpAndSettle();

      await type(tester, 'go');
      await tester.pumpAndSettle();
      expect(second.text, 'go');
      expect(first.text, _list);
    });

    testWidgets('gives the keys back to the field that kept the keyboard', (
      tester,
    ) async {
      await fields(tester);
      TypeAhead.hold();
      await type(tester, 'oat');
      expect(first.text, _list);

      await tester.pumpAndSettle();
      expect(firstFocus.hasPrimaryFocus, isTrue);
      expect(first.text, 'oat');
    });
  });
}
