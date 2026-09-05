import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/note_format.dart';
import 'package:kapy_notes/ui/editor/editor_formatting.dart';

void main() {
  _nestingTests();
  _plainTextTests();
  test('adds, removes, and rebases overlapping inline formats', () {
    final bold = toggleNoteFormat(
      const [],
      const TextSelection(baseOffset: 0, extentOffset: 4),
      NoteFormat.bold,
      9,
    );
    expect(bold, const [
      NoteFormatRange(start: 0, end: 4, format: NoteFormat.bold),
    ]);

    final extended = rebaseNoteFormats(
      oldText: 'Bold text',
      newText: 'Bold! text',
      formats: bold,
      insertedFormats: const {NoteFormat.bold},
    );
    expect(extended, const [
      NoteFormatRange(start: 0, end: 5, format: NoteFormat.bold),
    ]);

    final removed = toggleNoteFormat(
      extended,
      const TextSelection(baseOffset: 1, extentOffset: 4),
      NoteFormat.bold,
      10,
    );
    expect(removed, const [
      NoteFormatRange(start: 0, end: 1, format: NoteFormat.bold),
      NoteFormatRange(start: 4, end: 5, format: NoteFormat.bold),
    ]);
  });

  test('toggles line styles and checkbox state', () {
    const initial = TextEditingValue(
      text: 'First\nSecond',
      selection: TextSelection(baseOffset: 0, extentOffset: 12),
    );
    final checklist = toggleLineStyle(initial, NoteLineStyle.checklist);
    expect(checklist.text, '☐ First\n☐ Second');
    expect(selectionHasLineStyle(checklist, NoteLineStyle.checklist), isTrue);

    final completed = toggleCheckboxAt(checklist, 0);
    expect(completed.text, '☑ First\n☐ Second');

    final reopened = toggleCheckboxAt(completed, 0);
    expect(reopened.text, '☐ First\n☐ Second');

    final removed = toggleLineStyle(
      reopened.copyWith(
        selection: TextSelection(
          baseOffset: 0,
          extentOffset: reopened.text.length,
        ),
      ),
      NoteLineStyle.checklist,
    );
    expect(removed.text, 'First\nSecond');

    final bullets = toggleLineStyle(initial, NoteLineStyle.bullet);
    expect(bullets.text, '• First\n• Second');
  });

  test('paragraph presets style whole lines and switch mutually', () {
    const text = 'Project title\nA supporting thought\nBody text';
    final heading = applyParagraphStyle(
      const [NoteFormatRange(start: 0, end: 7, format: NoteFormat.bold)],
      text,
      const TextSelection(baseOffset: 2, extentOffset: 7),
      NoteParagraphStyle.heading,
    );
    expect(heading, const [
      NoteFormatRange(start: 0, end: 7, format: NoteFormat.bold),
      NoteFormatRange(start: 0, end: 13, format: NoteFormat.heading),
    ]);
    expect(
      paragraphStyleForSelection(
        text,
        heading,
        const TextSelection.collapsed(offset: 5),
      ),
      NoteParagraphStyle.heading,
    );

    final subtitle = applyParagraphStyle(
      heading,
      text,
      const TextSelection.collapsed(offset: 5),
      NoteParagraphStyle.subtitle,
    );
    expect(subtitle, const [
      NoteFormatRange(start: 0, end: 7, format: NoteFormat.bold),
      NoteFormatRange(start: 0, end: 13, format: NoteFormat.subtitle),
    ]);

    final plain = applyParagraphStyle(
      subtitle,
      text,
      const TextSelection.collapsed(offset: 5),
      NoteParagraphStyle.text,
    );
    expect(plain, const [
      NoteFormatRange(start: 0, end: 7, format: NoteFormat.bold),
    ]);
  });

  test(
    'paragraph presets span selected lines but leave list markers plain',
    () {
      const text = '• First\n☐ Second\nThird';
      final formats = applyParagraphStyle(
        const [],
        text,
        TextSelection(baseOffset: 2, extentOffset: text.length),
        NoteParagraphStyle.subtitle,
      );
      expect(formats, const [
        NoteFormatRange(start: 2, end: 7, format: NoteFormat.subtitle),
        NoteFormatRange(start: 10, end: 16, format: NoteFormat.subtitle),
        NoteFormatRange(start: 17, end: 22, format: NoteFormat.subtitle),
      ]);
      expect(
        paragraphStyleForSelection(
          text,
          formats,
          TextSelection(baseOffset: 0, extentOffset: text.length),
        ),
        NoteParagraphStyle.subtitle,
      );
    },
  );

  test('cycles paragraph styles directly without a menu', () {
    expect(
      nextParagraphStyle(NoteParagraphStyle.text),
      NoteParagraphStyle.heading,
    );
    expect(
      nextParagraphStyle(NoteParagraphStyle.heading),
      NoteParagraphStyle.subtitle,
    );
    expect(
      nextParagraphStyle(NoteParagraphStyle.subtitle),
      NoteParagraphStyle.text,
    );
    expect(nextParagraphStyle(null), NoteParagraphStyle.text);
  });

  test(
    'reports mixed paragraph selections and detects inserted line breaks',
    () {
      const text = 'Heading\nBody';
      const formats = [
        NoteFormatRange(start: 0, end: 7, format: NoteFormat.heading),
      ];
      expect(
        paragraphStyleForSelection(
          text,
          formats,
          const TextSelection(baseOffset: 0, extentOffset: 12),
        ),
        isNull,
      );
      expect(insertedTextForChange('Heading', 'Heading\n'), '\n');
      expect(insertedTextForChange('Body', 'Body text'), ' text');
    },
  );
}

// Nesting is written into the note as leading spaces before the list prefix.
// Everything that reads a line already skips that whitespace, so a sub-list
// stays plain text and cannot change what the note calculates.
void _nestingTests() {
  TextEditingValue at(String text, int offset) =>
      TextEditingValue(text: text, selection: TextSelection.collapsed(offset: offset));

  group('bullet levels', () {
    test('cycle through the glyph set as they nest', () {
      expect(bulletPrefixForDepth(0), '• ');
      expect(bulletPrefixForDepth(1), '◦ ');
      expect(bulletPrefixForDepth(2), '▪ ');
      // Repeating is easier to follow than a fourth mark distinct enough to
      // tell apart at this size.
      expect(bulletPrefixForDepth(3), '• ');
      expect(bulletPrefixForDepth(4), '◦ ');
    });

    test('every level is still recognised as a bullet', () {
      for (final prefix in bulletPrefixes) {
        expect(isBulletPrefix(prefix), isTrue, reason: prefix);
        final value = at('${prefix}item', prefix.length + 2);
        expect(selectionHasLineStyle(value, NoteLineStyle.bullet), isTrue);
        expect(selectionHasListLine(value), isTrue);
      }
    });

    test('a bullet added to a nested line takes that level', () {
      final value = at('    plan', 8);
      final result = toggleLineStyle(value, NoteLineStyle.bullet);
      expect(result.text, '    ▪ plan');
    });

    test('indenting and outdenting walk the glyphs in step', () {
      var value = at('• one', 5);
      value = indentSelection(value, outdent: false);
      expect(value.text, '  ◦ one');
      value = indentSelection(value, outdent: false);
      expect(value.text, '    ▪ one');
      value = indentSelection(value, outdent: true);
      expect(value.text, '  ◦ one');
      value = indentSelection(value, outdent: true);
      expect(value.text, '• one');
    });

    test('a checkbox keeps its glyph at every depth', () {
      var value = at('☐ milk', 6);
      value = indentSelection(value, outdent: false);
      expect(value.text, '  ☐ milk');
      value = indentSelection(value, outdent: false);
      expect(value.text, '    ☐ milk');
    });

    test('every level exports as the same plain marker', () {
      expect(
        plainTextFrom('• one\n  ◦ two\n    ▪ three\n  ☐ four\n  ☑ five'),
        '- one\n  - two\n    - three\n  - [ ] four\n  - [x] five',
      );
    });
  });

  group('list nesting', () {
    test('indents the line the caret is on', () {
      final result = indentSelection(at('• one\n• two', 8), outdent: false);
      // The bullet becomes the second level's on the way in.
      expect(result.text, '• one\n  ◦ two');
      // The caret keeps its place in the text it was sitting in.
      expect(result.selection.baseOffset, 10);
    });

    test('outdents back to the margin and no further', () {
      var value = at('  ◦ one', 6);
      value = indentSelection(value, outdent: true);
      expect(value.text, '• one');
      expect(indentSelection(value, outdent: true), same(value));
    });

    test('stops at the deepest level', () {
      var value = at('• one', 3);
      for (var i = 0; i < maxListIndentDepth; i++) {
        value = indentSelection(value, outdent: false);
      }
      expect(
        value.text,
        '${listIndentUnit * maxListIndentDepth}'
        '${bulletPrefixForDepth(maxListIndentDepth)}one',
      );
      expect(indentSelection(value, outdent: false), same(value));
    });

    test('moves only the list lines inside a mixed selection', () {
      const body = 'Shopping\n• milk\nplain line\n☐ bread';
      final result = indentSelection(
        const TextEditingValue(
          text: body,
          selection: TextSelection(baseOffset: 0, extentOffset: 34),
        ),
        outdent: false,
      );
      // The checkbox is a checkbox at any depth; only the bullet restyles.
      expect(result.text, 'Shopping\n  ◦ milk\nplain line\n  ☐ bread');
    });

    test('reports what is available, for the toolbar', () {
      expect(canIndentSelection(at('• one', 3), outdent: false), isTrue);
      expect(canIndentSelection(at('• one', 3), outdent: true), isFalse);
      expect(canIndentSelection(at('  ◦ one', 5), outdent: true), isTrue);
      expect(canIndentSelection(at('plain', 3), outdent: false), isFalse);
    });

    test('knows when a list line is in play at all', () {
      expect(selectionHasListLine(at('• one', 3)), isTrue);
      expect(selectionHasListLine(at('  ☐ one', 5)), isTrue);
      expect(selectionHasListLine(at('just prose', 4)), isFalse);
    });

    test('leaves a stray tab indent able to reach the margin', () {
      final result = indentSelection(at('\t◦ one', 4), outdent: true);
      expect(result.text, '• one');
    });
  });
}

// The note stores its list markers as literal glyphs, so they leave with an
// ordinary copy. This is the conversion that keeps a pasted checklist legible
// in a mail composer.
void _plainTextTests() {
  group('plainTextFrom', () {
    test('turns the drawn list glyphs into ASCII markers', () {
      expect(
        plainTextFrom('${bulletPrefix}one\n${uncheckedPrefix}two\n${checkedPrefix}three'),
        '- one\n- [ ] two\n- [x] three',
      );
    });

    test('keeps the indentation that carries a nested list', () {
      expect(
        plainTextFrom('${bulletPrefix}top\n$listIndentUnit${uncheckedPrefix}under'),
        '- top\n$listIndentUnit- [ ] under',
      );
    });

    test('leaves ordinary lines, blank lines and gaps exactly as written', () {
      const note = 'Q3 invoice\n\n120 * 3\n  indented thought\n\n\ntotal';
      expect(plainTextFrom(note), note);
    });

    test('only rewrites a marker that opens its line', () {
      // A glyph someone typed mid-sentence is their text, not our list.
      expect(
        plainTextFrom('rated 4 ${checkedPrefix}out of 5'),
        'rated 4 ${checkedPrefix}out of 5',
      );
    });

    test('leaves a bare glyph with no space after it alone', () {
      expect(plainTextFrom('☐'), '☐');
    });
  });
}
