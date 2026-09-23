import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/calc/highlight.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note_format.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/ui/editor/editor_formatting.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';

/// The editor learning about a note that changed under it — another device,
/// another person — without being remounted, and without losing the caret.
///
/// Under the blob protocol the open editor never heard about a pull at all:
/// it showed stale text until the next keystroke, which then overwrote the
/// other device's words with its own. These tests pin the behaviour that
/// replaced it.

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'note-editor-remote-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

late CalcEngine engine;
late ShortcutPrefs shortcutPrefs;

/// The note store as the page sees it: written by the editor's edits and by
/// other devices, and read by the editor on every edit. A test changes
/// [body] to land somebody else's words, then pumps the harness with it when
/// the page would rebuild — a frame later.
class StoreStandIn {
  StoreStandIn(this.body);

  String body;

  StoredNoteDocument read() =>
      (body: body, formats: const [], attachments: const []);
}

/// Same key across pumps, so a new body reaches `didUpdateWidget` rather
/// than remounting the editor — which is what happens in the app when the
/// store changes and the page rebuilds with the note still selected.
Widget harness(
  String body, {
  List<NoteFormatRange> formats = const [],
  void Function(String body)? onBodyChanged,
  StoreStandIn? store,
}) {
  return MaterialApp(
    theme: KapyTheme.dark(),
    home: Scaffold(
      body: NoteEditor(
        key: const ValueKey('remote-editor'),
        noteId: 'note-1',
        initialBody: body,
        initialFormats: formats,
        engine: engine,
        highlighter: Highlighter(engine.registry),
        gutterWidth: 200,
        resultsVisible: true,
        onDocumentChanged: (body, formats, attachments) {
          store?.body = body;
          onBodyChanged?.call(body);
        },
        storedDocument: store?.read,
        onGutterWidthChanged: (_) {},
        onResultsVisibilityChanged: (_) {},
        onGutterWidthReset: () {},
        onSettingsPressed: () {},
        writingFont: WritingFont.handwritten,
        shortcuts: shortcutPrefs,
        autofocus: true,
      ),
    ),
  );
}

EditableTextState _editable(WidgetTester tester) =>
    tester.state<EditableTextState>(find.byType(EditableText));

/// What the keyboard hands the field: the text, the caret, and the word it
/// is still composing, if any.
void _type(
  WidgetTester tester,
  String text, {
  required int caret,
  TextRange composing = TextRange.empty,
}) => _editable(tester).userUpdateTextEditingValue(
  TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: caret),
    composing: composing,
  ),
  SelectionChangedCause.keyboard,
);

void main() {
  setUpAll(loadTestFonts);
  setUp(() {
    engine = CalcEngine(ratesPerUsd: const {'EUR': 0.86});
    shortcutPrefs = ShortcutPrefs(_MemoryStore())..load();
  });

  group('mapSelectionAcrossEdit', () {
    test('an insert before the caret shifts it; one after leaves it', () {
      const sel = TextSelection.collapsed(offset: 5);
      expect(
        mapSelectionAcrossEdit('hello world', 'XXhello world', sel).baseOffset,
        7,
      );
      expect(
        mapSelectionAcrossEdit('hello world', 'hello worldXX', sel).baseOffset,
        5,
      );
    });

    test('a delete around the caret lands it at the start of the change', () {
      const sel = TextSelection.collapsed(offset: 5);
      expect(
        mapSelectionAcrossEdit('hello world', 'heworld', sel).baseOffset,
        2,
      );
    });

    test('a replacement over the caret keeps it inside the new text', () {
      const sel = TextSelection.collapsed(offset: 3);
      final mapped = mapSelectionAcrossEdit('abcdef', 'abXYZef', sel);
      expect(mapped.baseOffset, 3);
      expect(mapped.baseOffset, lessThanOrEqualTo('abXYZef'.length));
    });

    test('a range selection maps both ends', () {
      const sel = TextSelection(baseOffset: 2, extentOffset: 8);
      final mapped = mapSelectionAcrossEdit('0123456789', 'AB0123456789', sel);
      expect(mapped.baseOffset, 4);
      expect(mapped.extentOffset, 10);
    });

    test('never lands outside the new text', () {
      const sel = TextSelection.collapsed(offset: 9);
      final mapped = mapSelectionAcrossEdit('0123456789', '01', sel);
      expect(mapped.baseOffset, 2);
    });
  });

  testWidgets('a remote change replaces the text and keeps the caret', (
    tester,
  ) async {
    final sent = <String>[];
    await tester.pumpWidget(
      harness('coffee 4\ntea 3', onBodyChanged: sent.add),
    );
    await tester.pumpAndSettle();

    // The user is on the second line.
    _editable(tester).userUpdateTextEditingValue(
      const TextEditingValue(
        text: 'coffee 4\ntea 3',
        selection: TextSelection.collapsed(offset: 12),
      ),
      SelectionChangedCause.tap,
    );
    await tester.pump();

    // Somebody else adds a line at the top.
    await tester.pumpWidget(
      harness('milk 2\ncoffee 4\ntea 3', onBodyChanged: sent.add),
    );
    await tester.pump();

    final value = _editable(tester).textEditingValue;
    expect(value.text, 'milk 2\ncoffee 4\ntea 3');
    // Seven characters landed above the caret; it is still after "tea".
    expect(value.selection.baseOffset, 19);
    expect(value.text.substring(value.selection.baseOffset), ' 3');
    // Applied, not typed: the store is not told about its own change.
    expect(sent, isEmpty);
  });

  testWidgets('typing after a remote change builds on the new text', (
    tester,
  ) async {
    final sent = <String>[];
    await tester.pumpWidget(harness('a', onBodyChanged: sent.add));
    await tester.pumpAndSettle();

    await tester.pumpWidget(harness('a\nb', onBodyChanged: sent.add));
    await tester.pump();

    _editable(tester).userUpdateTextEditingValue(
      const TextEditingValue(
        text: 'a\nbc',
        selection: TextSelection.collapsed(offset: 4),
      ),
      SelectionChangedCause.keyboard,
    );
    await tester.pump();
    expect(sent, ['a\nbc']);
  });

  testWidgets('a remote change carries its formats', (tester) async {
    await tester.pumpWidget(harness('hello'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      harness(
        'XX hello',
        formats: const [
          NoteFormatRange(start: 3, end: 8, format: NoteFormat.bold),
        ],
      ),
    );
    await tester.pump();

    final state = tester.state<NoteEditorState>(find.byType(NoteEditor));
    expect(state.formatsForTest, [
      const NoteFormatRange(start: 3, end: 8, format: NoteFormat.bold),
    ]);
  });

  testWidgets('the same body arriving again is not treated as a change', (
    tester,
  ) async {
    final sent = <String>[];
    await tester.pumpWidget(harness('same', onBodyChanged: sent.add));
    await tester.pumpAndSettle();
    _editable(tester).userUpdateTextEditingValue(
      const TextEditingValue(
        text: 'same',
        selection: TextSelection.collapsed(offset: 2),
      ),
      SelectionChangedCause.tap,
    );
    await tester.pump();

    // The page rebuilt for some other reason; the note did not change.
    await tester.pumpWidget(harness('same', onBodyChanged: sent.add));
    await tester.pump();
    expect(_editable(tester).textEditingValue.selection.baseOffset, 2);
    expect(sent, isEmpty);
  });

  testWidgets('a remote change waits for an open composition to end', (
    tester,
  ) async {
    await tester.pumpWidget(harness('hel'));
    await tester.pumpAndSettle();

    // The IME is mid-word.
    _editable(tester).userUpdateTextEditingValue(
      const TextEditingValue(
        text: 'hel',
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange(start: 0, end: 3),
      ),
      SelectionChangedCause.keyboard,
    );
    await tester.pump();

    await tester.pumpWidget(harness('REMOTE\nhel'));
    await tester.pump();
    // Held back: replacing the text under a composition confuses the IME.
    expect(_editable(tester).textEditingValue.text, 'hel');

    // The word is committed.
    _editable(tester).userUpdateTextEditingValue(
      const TextEditingValue(
        text: 'hel',
        selection: TextSelection.collapsed(offset: 3),
      ),
      SelectionChangedCause.keyboard,
    );
    await tester.pump();
    expect(_editable(tester).textEditingValue.text, 'REMOTE\nhel');
  });

  group('an edit made before the editor has shown what arrived', () {
    /// A note with a word being composed at its end, and another device's
    /// line landed above it while it is.
    Future<StoreStandIn> composingUnderRemote(WidgetTester tester) async {
      final store = StoreStandIn('hel');
      await tester.pumpWidget(harness(store.body, store: store));
      await tester.pumpAndSettle();
      _type(tester, 'hel', caret: 3, composing: const TextRange(start: 0, end: 3));
      await tester.pump();
      store.body = 'REMOTE\nhel';
      await tester.pumpWidget(harness(store.body, store: store));
      await tester.pump();
      expect(
        _editable(tester).textEditingValue.text,
        'hel',
        reason: 'held back while the word is composed',
      );
      return store;
    }

    testWidgets('typing on under a composition keeps the words that arrived', (
      tester,
    ) async {
      final store = await composingUnderRemote(tester);

      _type(tester, 'hell', caret: 4, composing: const TextRange(start: 0, end: 4));
      await tester.pump();

      expect(store.body, 'REMOTE\nhell');
    });

    testWidgets('the keystroke that ends a composition is kept', (
      tester,
    ) async {
      final store = await composingUnderRemote(tester);

      // A space ends the word.
      _type(tester, 'hel ', caret: 4);
      await tester.pump();

      expect(store.body, 'REMOTE\nhel ');
      final value = _editable(tester).textEditingValue;
      expect(value.text, 'REMOTE\nhel ');
      expect(value.selection.baseOffset, 11);
    });

    testWidgets('a page that cannot say what the store holds still gets '
        'merged edits', (tester) async {
      final sent = <String>[];
      await tester.pumpWidget(harness('hel', onBodyChanged: sent.add));
      await tester.pumpAndSettle();
      _type(tester, 'hel', caret: 3, composing: const TextRange(start: 0, end: 3));
      await tester.pump();
      await tester.pumpWidget(harness('REMOTE\nhel', onBodyChanged: sent.add));
      await tester.pump();

      _type(tester, 'hell', caret: 4, composing: const TextRange(start: 0, end: 4));
      await tester.pump();
      expect(sent.last, 'REMOTE\nhell');

      // The word ends before the page has rebuilt with what was written.
      _type(tester, 'hell ', caret: 5);
      await tester.pump();
      expect(sent.last, 'REMOTE\nhell ');
      expect(_editable(tester).textEditingValue.text, 'REMOTE\nhell ');
    });

    testWidgets('a keystroke in the frame before the page rebuilds is '
        'carried onto the store', (tester) async {
      final store = StoreStandIn('a\nb');
      await tester.pumpWidget(harness(store.body, store: store));
      await tester.pumpAndSettle();
      _type(tester, 'a\nb', caret: 3);
      await tester.pump();

      // Another device's line reaches the store; the page has not rebuilt.
      store.body = 'X\na\nb';
      _type(tester, 'a\nbc', caret: 4);
      await tester.pump();
      expect(store.body, 'X\na\nbc');

      await tester.pumpWidget(harness(store.body, store: store));
      await tester.pump();
      final value = _editable(tester).textEditingValue;
      expect(value.text, 'X\na\nbc');
      expect(value.selection.baseOffset, 6);
    });

    testWidgets('an edit the keyboard built on the text before a remote '
        'change does not undo it', (tester) async {
      final store = StoreStandIn('a\nb');
      await tester.pumpWidget(harness(store.body, store: store));
      await tester.pumpAndSettle();
      _type(tester, 'a\nb', caret: 3);
      await tester.pump();
      store.body = 'X\na\nb';
      await tester.pumpWidget(harness(store.body, store: store));
      await tester.pump();
      expect(_editable(tester).textEditingValue.text, 'X\na\nb');

      // A keystroke the platform applied to its own copy of the text before
      // the new text reached it: built on "a\nb", not on what is shown.
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'a\nbc',
          selection: TextSelection.collapsed(offset: 4),
        ),
      );
      await tester.pump();

      expect(_editable(tester).textEditingValue.text, 'X\na\nbc');
      expect(store.body, 'X\na\nbc');
    });
  });
}
