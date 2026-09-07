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

/// Same key across pumps, so a new body reaches `didUpdateWidget` rather
/// than remounting the editor — which is what happens in the app when the
/// store changes and the page rebuilds with the note still selected.
Widget harness(
  String body, {
  List<NoteFormatRange> formats = const [],
  void Function(String body)? onBodyChanged,
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
        onDocumentChanged: (body, formats, attachments) =>
            onBodyChanged?.call(body),
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
}
