import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/ui/editor/image_insertion.dart';

/// The character a picture anchors to, spelled out so the cases below read as
/// what somebody would see.
const img = NoteAttachmentRef.placeholder;

TextEditingValue at(String text, int caret) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: caret),
);

/// What the editor would end up with, typing [typed] at [caret] in [before].
TextEditingValue typing(String before, int caret, String typed) =>
    keepImageLinesToThemselves(
      at(before, caret),
      at(before.replaceRange(caret, caret, typed), caret + typed.length),
    );

void main() {
  group('writing next to a picture', () {
    test('a word typed after one goes on the line below it', () {
      final result = typing(img, 1, 'a');

      expect(result.text, '$img\na');
      // And the caret went with it, so typing simply continues.
      expect(result.selection.baseOffset, 3);
    });

    test('a word typed before one goes on the line above it', () {
      final result = typing(img, 0, 'a');

      expect(result.text, 'a\n$img');
      expect(result.selection.baseOffset, 1);
    });

    test('a whole gallery keeps its row and takes the words underneath', () {
      // Three pictures side by side is what makes them a gallery; a character
      // typed between two of them must not break the row.
      final result = typing('$img$img$img', 2, 'hi');

      expect(result.text, '$img$img$img\nhi');
      expect(result.selection.baseOffset, '$img$img$img\nhi'.length);
    });

    test('words on both sides end up above and below', () {
      // Two edits, because two is how anybody gets there: type in front of the
      // picture, then behind it.
      final first = typing(img, 0, 'before');
      expect(first.text, 'before\n$img');

      final second = keepImageLinesToThemselves(
        first,
        at('before\n${img}after', 13),
      );

      expect(second.text, 'before\n$img\nafter');
      expect(second.selection.baseOffset, 'before\n$img\nafter'.length);
    });

    test('the lines around it are left alone', () {
      final result = typing('above\n$img\nbelow', 7, 'x');

      expect(result.text, 'above\n$img\nx\nbelow');
      expect(result.selection.baseOffset, 'above\n$img\nx'.length);
    });
  });

  group('what the rule deliberately does not touch', () {
    test('a note with no pictures is returned untouched', () {
      final typed = at('hello there', 5);

      expect(
        identical(keepImageLinesToThemselves(at('hello', 5), typed), typed),
        isTrue,
      );
    });

    test('typing over a selected picture replaces it', () {
      // The picture is selected and a letter is typed: the placeholder is gone
      // from the result, so there is no picture line left to keep clear.
      final result = keepImageLinesToThemselves(
        TextEditingValue(
          text: 'a${img}b',
          selection: const TextSelection(baseOffset: 1, extentOffset: 2),
        ),
        at('axb', 2),
      );

      expect(result.text, 'axb');
    });

    test('a picture line that this edit never touched is left as it is', () {
      // Somebody else's client, or an older version, wrote a mixed line. It is
      // theirs until somebody edits it.
      final result = typing('$img beside\n\nelsewhere', 10, 'x');

      expect(result.text, '$img beside\n\nxelsewhere');
    });

    test('a paste that brings pictures keeps the arrangement it came with', () {
      // Copied text and images together. The pictures are arriving, not being
      // written beside — the fragment's own shape is the one to honour, and it
      // is what a paste back into the same note has to reproduce.
      final result = keepImageLinesToThemselves(
        at('', 0),
        at('one ${img}two', 8),
      );

      expect(result.text, 'one ${img}two');
    });

    test('deleting the picture itself is allowed', () {
      final result = keepImageLinesToThemselves(
        at('$img\nwords', 1),
        at('\nwords', 0),
      );

      expect(result.text, '\nwords');
    });
  });

  group('merging a line into a picture', () {
    test('backspace under a picture leaves everything where it was', () {
      // The merge it asks for is not a state this editor has, so the key does
      // nothing rather than putting the words beside the picture.
      final before = at('$img\nwords', 2);
      final merged = at('${img}words', 1);

      final result = keepImageLinesToThemselves(before, merged);

      expect(result.text, before.text);
      expect(result.selection.baseOffset, before.selection.baseOffset);
    });

    test('delete at the end of a picture line is the same answer', () {
      final result = keepImageLinesToThemselves(
        at('$img\nwords', 1),
        at('${img}words', 1),
      );

      expect(result.text, '$img\nwords');
      expect(result.selection.baseOffset, 2);
    });
  });
}
