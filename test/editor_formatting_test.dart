import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/note_format.dart';
import 'package:kapy_notes/ui/editor/editor_formatting.dart';

void main() {
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
