import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/note_format.dart';
import 'package:kapy_notes/paste/paste_insertion.dart';
import 'package:kapy_notes/paste/paste_tree.dart';

/// Pastes [pasted] at the | in [note] and returns the note with the caret
/// shown as | again.
String paste(
  String note,
  String pasted, {
  bool markdown = true,
  PasteTarget target = PasteTarget.text,
  List<NoteFormatRange> formats = const [],
}) {
  final start = note.indexOf('|');
  final end = note.lastIndexOf('|');
  final text = note.replaceAll('|', '');
  final selection = TextSelection(
    baseOffset: start,
    extentOffset: end == start ? start : end - 1,
  );
  final insertion = planPaste(
    note: text,
    selection: selection,
    output: PasteOutput(text: pasted, formats: formats),
    markdown: markdown,
    target: target,
    clipboardText: target == PasteTarget.text ? null : pasted,
  );
  return '${text.substring(0, insertion.start)}${insertion.text}|'
      '${text.substring(insertion.end)}';
}

void main() {
  group('markdown note', () {
    test('a paste into an empty note goes in as written', () {
      expect(paste('|', '# Title\n\n- one\n- two'), '# Title\n\n- one\n- two|');
    });

    test('words pasted mid-line join the line on both sides', () {
      expect(paste('abc|def', 'one\n\ntwo'), 'abcone\n\ntwo|def');
    });

    test("the first pasted line takes on the line's kind", () {
      expect(paste('abc|', '# Title\n\npara'), 'abcTitle\n\npara|');
      expect(paste('- |', '- one\n- two'), '- one\n- two|');
      expect(paste('- |', '# Big'), '- Big|');
    });

    test('lines pasted into a list become more of its items', () {
      expect(paste('- apples|', 'pears\nplums'), '- applespears\n- plums|');
      expect(paste('1. a|', 'x\ny\nz'), '1. ax\n2. y\n3. z|');
      expect(paste('  - [ ] a|', 'b\nc'), '  - [ ] ab\n  - [ ] c|');
      expect(paste('- a|', 'b\n\nc'), '- ab\n- c|');
    });

    test('pasted items keep their nesting inside a nested item', () {
      expect(paste('  - |', '- one\n  - two'), '  - one\n    - two|');
    });

    test('lines pasted into a quote stay in it', () {
      expect(paste('> a|', 'b\n\nc'), '> ab\n>\n> c|');
    });

    test('a block that cannot share a line gets its own', () {
      expect(
        paste('abc|', '| a | b |\n| --- | --- |\n| 1 | 2 |'),
        'abc\n| a | b |\n| --- | --- |\n| 1 | 2 ||',
      );
      expect(paste('|def', '```\ncode\n```'), '```\ncode\n```\n|def');
      expect(paste('- |', '￼'), '￼|');
    });

    test('a web address pasted over words links them', () {
      expect(
        paste('see |the docs|', ' https://example.com/a_b\n'),
        'see [the docs](https://example.com/a_b)|',
      );
      expect(paste('see |two\nlines|', 'https://e.com'), 'see https://e.com|');
    });

    test('code and table cells take only the words', () {
      expect(
        paste('|', '**bold**\nline', target: PasteTarget.code),
        '**bold**\nline|',
      );
      expect(
        paste('|', 'a | b\nnext', target: PasteTarget.table),
        r'a \| b<br>next|',
      );
    });
  });

  group('plain note', () {
    test('lines pasted into a list become more of its items', () {
      expect(
        paste('• apples|', 'pears\nplums', markdown: false),
        '• applespears\n• plums|',
      );
      expect(paste('☑ a|', 'b\nc', markdown: false), '☑ ab\n☐ c|');
    });

    test('a heading joining a line gives up its style', () {
      final formats = [
        const NoteFormatRange(start: 0, end: 5, format: NoteFormat.heading),
        const NoteFormatRange(start: 7, end: 11, format: NoteFormat.bold),
      ];
      final insertion = planPaste(
        note: 'abc',
        selection: const TextSelection.collapsed(offset: 3),
        output: PasteOutput(text: 'Title\n\nbold', formats: formats),
        markdown: false,
      );
      expect(insertion.text, 'Title\n\nbold');
      expect(insertion.formats, [
        const NoteFormatRange(start: 7, end: 11, format: NoteFormat.bold),
      ]);
    });
  });

  test('pictures keep their offsets through the planning', () {
    final insertion = planPaste(
      note: '- a',
      selection: const TextSelection.collapsed(offset: 3),
      output: const PasteOutput(
        text: 'b\n￼\nc',
        images: [PastedImage(2, PasteImage(src: 'https://e.com/x.png'))],
      ),
      markdown: true,
    );
    expect(insertion.text, 'b\n￼\n- c');
    expect(insertion.images.single.offset, 2);
  });
}
