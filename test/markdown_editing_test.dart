import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ui/editor/editor_formatting.dart';
import 'package:kapy_notes/ui/editor/markdown_editing.dart';
import 'package:kapy_notes/ui/editor/markdown_syntax.dart';

/// [text] with the caret at the `|` in it, or the selection between two.
TextEditingValue at(String text) {
  final first = text.indexOf('|');
  final last = text.lastIndexOf('|');
  final clean = text.replaceAll('|', '');
  return TextEditingValue(
    text: clean,
    selection: first == last
        ? TextSelection.collapsed(offset: first)
        : TextSelection(baseOffset: first, extentOffset: last - 1),
  );
}

/// [value] written back out with its caret or selection marked by `|`.
String shown(TextEditingValue value) {
  final selection = value.selection;
  final text = value.text;
  if (selection.isCollapsed) {
    return text.replaceRange(selection.start, selection.start, '|');
  }
  return text
      .replaceRange(selection.end, selection.end, '|')
      .replaceRange(selection.start, selection.start, '|');
}

/// What pressing Enter at the caret in [marked] leaves.
String enter(String marked) {
  final before = at(marked);
  final caret = before.selection.start;
  final typed = TextEditingValue(
    text: before.text.replaceRange(caret, caret, '\n'),
    selection: TextSelection.collapsed(offset: caret + 1),
  );
  final after = continueMarkdownLine(before, typed);
  return after == null ? 'untouched' : shown(after);
}

String bold(String marked, {bool strong = true}) {
  final value = at(marked);
  final analysis = MarkdownAnalyzer.analyzeWhole(value.text);
  return shown(toggleMarkdownEmphasis(value, analysis, strong: strong).value);
}

/// One keystroke through the markdown formatters, in the order the editor
/// runs them: [typed] is what the field would have made of it.
TextEditingValue keystroke(
  TextEditingValue before,
  TextEditingValue typed,
  MarkdownTyping typing,
) {
  final analysis = MarkdownAnalyzer.analyzeWhole(before.text);
  final afterTyping =
      markdownTypingEdit(before, typed, analysis, typing) ?? typed;
  return markdownStructureEdit(before, afterTyping, analysis) ?? afterTyping;
}

/// What typing [keys] one at a time at the caret in [marked] leaves.
String type(String marked, String keys, {MarkdownTyping? typing}) {
  var value = at(marked);
  final state = typing ?? MarkdownTyping();
  for (final key in keys.split('')) {
    final caret = value.selection.start;
    value = keystroke(
      value,
      TextEditingValue(
        text: value.text.replaceRange(caret, caret, key),
        selection: TextSelection.collapsed(offset: caret + 1),
      ),
      state,
    );
  }
  return shown(value);
}

/// What Backspace at the caret in [marked] leaves.
String backspace(String marked) {
  final value = at(marked);
  final caret = value.selection.start;
  return shown(
    keystroke(
      value,
      TextEditingValue(
        text: value.text.replaceRange(caret - 1, caret, ''),
        selection: TextSelection.collapsed(offset: caret - 1),
      ),
      MarkdownTyping(),
    ),
  );
}

/// What Delete at the caret in [marked] leaves.
String deleteForward(String marked) {
  final value = at(marked);
  final caret = value.selection.start;
  return shown(
    keystroke(
      value,
      TextEditingValue(
        text: value.text.replaceRange(caret, caret + 1, ''),
        selection: TextSelection.collapsed(offset: caret),
      ),
      MarkdownTyping(),
    ),
  );
}

void main() {
  group('Enter', () {
    test('continues a bullet, a number and a task', () {
      expect(enter('- milk|'), '- milk\n- |');
      expect(enter('* milk|'), '* milk\n* |');
      expect(enter('9. nine|'), '9. nine\n10. |');
      expect(enter('1) one|'), '1) one\n2) |');
      expect(enter('- [x] done|'), '- [x] done\n- [ ] |');
      expect(enter('  - nested|'), '  - nested\n  - |');
    });

    test('keeps the words after the caret with the new item', () {
      expect(enter('- milk| and eggs'), '- milk\n- | and eggs');
    });

    test('continues a quote, and a list inside one', () {
      expect(enter('> said|'), '> said\n> |');
      expect(enter('> - item|'), '> - item\n> - |');
      expect(enter('> > deep|'), '> > deep\n> > |');
    });

    test('on an empty item, backs out instead of adding a line', () {
      expect(enter('- milk\n- |'), '- milk\n|');
      expect(enter('- [ ] |'), '|');
      expect(enter('> - |'), '> |');
      expect(enter('> |'), '|');
      expect(enter('> > |'), '> |');
    });

    test('an empty nested item steps out to its parent\'s list', () {
      expect(enter('- a\n  - b\n  - |'), '- a\n  - b\n- |');
      expect(enter('1. a\n   - b\n   - |'), '1. a\n   - b\n2. |');
      expect(enter('- [ ] a\n  - |'), '- [ ] a\n- [ ] |');
      expect(enter('☑ a\n  - |'), '☑ a\n☐ |');
    });

    test('in front of the words, just moves the line down', () {
      expect(enter('|- milk'), '\n|- milk');
      expect(enter('>| said'), '>\n| said');
    });

    test('leaves everything else to the note', () {
      expect(enter('plain|'), 'untouched');
      expect(enter('# Title|'), 'untouched');
      expect(enter('• glyph|'), 'untouched');
      expect(enter('☐ glyph box|'), 'untouched');
      expect(enter('* * *|'), 'untouched');
    });
  });

  group('bold and italic', () {
    test('wrap a selection, and unwrap it on the next press', () {
      expect(bold('a |word| b'), 'a **|word|** b');
      expect(bold('a **|word|** b'), 'a |word| b');
      expect(bold('a |**word**| b'), 'a |word| b');
      expect(bold('a |word| b', strong: false), 'a *|word|* b');
    });

    test('leave the spaces at either end outside the markers', () {
      expect(bold('a| word |b'), 'a **|word|** b');
    });

    test('take in the whole word rather than part of one', () {
      expect(bold('foo|ba|r'), '**|foobar|**');
    });

    test('with no selection, wrap the word the caret is in', () {
      expect(bold('say hel|lo now'), 'say **hel|lo** now');
      expect(bold('say **hel|lo** now'), 'say hel|lo now');
    });

    test('with no word to wrap, wait for the next word typed', () {
      for (final marked in ['say |', 'hello|', '|', 'a | b']) {
        final value = at(marked);
        final edit = toggleMarkdownEmphasis(
          value,
          MarkdownAnalyzer.analyzeWhole(value.text),
          strong: true,
        );
        expect(edit.pending, isTrue, reason: marked);
        expect(edit.changesText, isFalse, reason: marked);
        expect(edit.value, value, reason: marked);
      }
    });

    test('at either end of bold, step out of it; just outside, into it', () {
      expect(bold('say **bold|** now'), 'say **bold**| now');
      expect(bold('say **|bold** now'), 'say |**bold** now');
      expect(bold('say **bold**| now'), 'say **bold|** now');
      expect(bold('say |**bold** now'), 'say **|bold** now');
      expect(bold('a *it*|', strong: false), 'a *it|*');
    });

    test('wrap each line on its own, after its structure', () {
      expect(bold('- |one\n- two|'), '- **|one**\n- **two|**');
      expect(bold('# |Title|'), '# **|Title|**');
    });

    test('join bold the selection runs into', () {
      expect(bold('|a **b** c|'), '**|a b c|**');
      expect(bold('|a **b| c**'), '**|a b c|**');
      // Beside it is not into it: two runs are fine markdown.
      expect(bold('**a** |b c|'), '**a** **|b c|**');
    });

    test('italic inside bold makes both', () {
      expect(bold('**hel|lo**', strong: false), '***hel|lo***');
    });

    test('carry everything after them across the markers', () {
      const text = 'one two\nthree';
      final edit = toggleMarkdownEmphasis(
        at('one |two|\nthree'),
        MarkdownAnalyzer.analyzeWhole(text),
        strong: true,
      );
      expect(edit.value.text, 'one **two**\nthree');
      expect(edit.map(text.indexOf('three')), 'one **two**\n'.length);
      expect(edit.map(4), 6, reason: 'into the word, past the opening');
      expect(edit.map(7, before: true), 9, reason: 'before the closing');
    });
  });

  group('lists', () {
    String toggle(String marked, NoteLineStyle style) =>
        shown(toggleMarkdownLineStyle(at(marked), style).value);

    test('bullets on and off', () {
      expect(toggle('milk|', NoteLineStyle.bullet), '- milk|');
      expect(toggle('- milk|', NoteLineStyle.bullet), 'milk|');
      expect(toggle('1. milk|', NoteLineStyle.bullet), '- milk|');
      expect(toggle('  indented|', NoteLineStyle.bullet), '  - indented|');
      expect(toggle('• glyph|', NoteLineStyle.bullet), 'glyph|');
    });

    test('tasks on and off, keeping a tick and a bullet', () {
      expect(toggle('milk|', NoteLineStyle.checklist), '- [ ] milk|');
      expect(toggle('* milk|', NoteLineStyle.checklist), '* [ ] milk|');
      expect(toggle('- [x] milk|', NoteLineStyle.checklist), 'milk|');
      expect(
        toggle('|- [x] a\n- b|', NoteLineStyle.checklist),
        '|- [x] a\n- [ ] b|',
      );
    });

    test('skip the blank lines in a run, and every picture\'s line', () {
      // The selection stays on the words, past the markers put in front.
      expect(toggle('|a\n\nb|', NoteLineStyle.bullet), '- |a\n\n- b|');
      expect(
        toggle('|a\n\u{FFFC}\nb|', NoteLineStyle.bullet),
        '- |a\n\u{FFFC}\n- b|',
      );
    });

    test('know when a selection is already in a style', () {
      expect(
        markdownSelectionHasLineStyle(at('|- a\n* b|'), NoteLineStyle.bullet),
        isTrue,
      );
      expect(
        markdownSelectionHasLineStyle(at('|- a\nb|'), NoteLineStyle.bullet),
        isFalse,
      );
      expect(
        markdownSelectionHasLineStyle(at('- [ ] a|'), NoteLineStyle.bullet),
        isFalse,
      );
      expect(
        markdownSelectionHasLineStyle(at('☐ a|'), NoteLineStyle.checklist),
        isTrue,
      );
    });

    test('tick and untick a task', () {
      final ticked = toggleMarkdownTask(at('|- [ ] milk'), 2);
      expect(shown(ticked), '- [x] |milk');
      expect(toggleMarkdownTask(ticked, 2).text, '- [ ] milk');
      expect(toggleMarkdownTask(at('|- [X] milk'), 2).text, '- [ ] milk');
    });
  });

  group('headings', () {
    String heading(String marked, int level) =>
        shown(applyMarkdownHeading(at(marked), level).value);

    test('set, change and clear a level', () {
      expect(heading('Title|', 1), '# Title|');
      expect(heading('# Title|', 2), '## Title|');
      expect(heading('### Title|', 0), 'Title|');
      expect(heading('|', 1), '# |');
    });

    test('go after a line\'s quote or list structure', () {
      expect(heading('> Title|', 1), '> # Title|');
      expect(heading('- Title|', 2), '- ## Title|');
    });

    test('step through the levels the button offers', () {
      expect(nextMarkdownHeadingLevel(0), 1);
      expect(nextMarkdownHeadingLevel(1), 2);
      expect(nextMarkdownHeadingLevel(2), 3);
      expect(nextMarkdownHeadingLevel(3), 0);
      expect(nextMarkdownHeadingLevel(5), 0);
      expect(nextMarkdownHeadingLevel(null), 0, reason: 'mixed goes to text');
    });

    test('read the level a selection shares', () {
      expect(markdownHeadingLevelForSelection('# a', at('# a|').selection), 1);
      expect(
        markdownHeadingLevelForSelection(
          '# a\n## b',
          at('|# a\n## b|').selection,
        ),
        isNull,
      );
      expect(
        markdownHeadingLevelForSelection('plain', at('pl|ain').selection),
        0,
      );
    });
  });

  group('nesting', () {
    String nest(String marked, {bool outdent = false}) =>
        shown(indentMarkdownSelection(at(marked), outdent: outdent).value);

    test('goes under the item above, to where its words begin', () {
      expect(nest('- a\n- b|'), '- a\n  - b|');
      expect(nest('1. a\n2. b|'), '1. a\n   2. b|');
      expect(nest('10. a\n11. b|'), '10. a\n    11. b|');
    });

    test('has nowhere to go without an item above at its level', () {
      expect(canIndentMarkdownSelection(at('- a|'), outdent: false), isFalse);
      expect(
        canIndentMarkdownSelection(at('- a\n  - b|'), outdent: false),
        isFalse,
      );
      expect(
        canIndentMarkdownSelection(at('- a\n\n- b|'), outdent: false),
        isTrue,
        reason: 'a blank line does not end the list',
      );
      expect(
        canIndentMarkdownSelection(at('- a\ntext\n- b|'), outdent: false),
        isTrue,
        reason: 'a lazy line is still part of the item above',
      );
      expect(
        canIndentMarkdownSelection(at('- a\n\ntext\n- b|'), outdent: false),
        isFalse,
        reason: 'prose at the margin after a blank line ends the list',
      );
      expect(
        canIndentMarkdownSelection(at('- a\n# Head\n- b|'), outdent: false),
        isFalse,
        reason: 'a heading is a block of its own',
      );
    });

    test('steps out to where its parent sits', () {
      expect(nest('1. a\n   - b|', outdent: true), '1. a\n- b|');
      expect(canIndentMarkdownSelection(at('- a|'), outdent: true), isFalse);
    });

    test('moves a run of items as a block', () {
      expect(nest('- a\n|- b\n  - c|'), '- a\n  |- b\n    - c|');
    });

    test('stops at the deepest level', () {
      const deepest =
          '- 1\n  - 2\n    - 3\n      - 4\n        - 5\n        - 6';
      expect(
        canIndentMarkdownSelection(
          TextEditingValue(
            text: deepest,
            selection: TextSelection.collapsed(offset: deepest.length),
          ),
          outdent: false,
        ),
        isFalse,
      );
    });
  });

  group('reads a line', () {
    test('its indentation, quotes, marker, box and heading', () {
      const text = '  > - [x] # Done';
      final line = markdownLinePrefix(text, 5);
      expect(line.indentEnd, 2);
      expect(line.isQuoted, isTrue);
      expect(line.isListItem, isTrue);
      expect(line.taskBox, text.indexOf('['));
      expect(line.taskChecked, isTrue);
      expect(line.headingLevel, 1);
      expect(text.substring(line.headingEnd), 'Done');
    });

    test('a thematic break as no list at all', () {
      expect(markdownLinePrefix('- - -', 0).isListItem, isFalse);
      expect(markdownLinePrefix('* * *', 0).isListItem, isFalse);
    });

    test('a number that is not followed by a space as no list', () {
      expect(markdownLinePrefix('2.5 kg', 0).isListItem, isFalse);
      expect(markdownLinePrefix('-5', 0).isListItem, isFalse);
    });
  });

  group('typing', () {
    test('a word where bold is waiting is written in bold', () {
      final typing = MarkdownTyping()..togglePending(strong: true, caret: 4);
      expect(type('say |', 'hi', typing: typing), 'say **hi|**');
    });

    test('bold and italic can wait together', () {
      final typing = MarkdownTyping()
        ..togglePending(strong: true, caret: 0)
        ..togglePending(strong: false, caret: 0);
      expect(type('|', 'hi', typing: typing), '***hi|***');
    });

    test('a style switched on twice is off again', () {
      final typing = MarkdownTyping()
        ..togglePending(strong: true, caret: 0)
        ..togglePending(strong: true, caret: 0);
      expect(typing.hasPending, isFalse);
      expect(type('|', 'hi', typing: typing), 'hi|');
    });

    test('spaces before the word leave the style waiting past them', () {
      final typing = MarkdownTyping()..togglePending(strong: true, caret: 0);
      expect(type('|', '  hi', typing: typing), '  **hi|**');
    });

    test(
      'a space at the end of bold goes outside it, until a word follows',
      () {
        expect(type('**bold|**', ' '), '**bold** |');
        expect(type('**bold|**', ' next'), '**bold next|**');
        expect(type('*it|*', ' on'), '*it on|*');
        expect(type('~~gone|~~', ' too'), '~~gone too|~~');
        expect(type('***both|***', ' two'), '***both two|***');
      },
    );

    test('a word typed after bold that was closed stays plain', () {
      expect(type('**bold**|', ' next'), '**bold** next|');
    });

    test('the button after the space leaves the next word plain', () {
      final typing = MarkdownTyping();
      final spaced = type('**bold|**', ' ', typing: typing);
      final caret = spaced.indexOf('|');
      final text = spaced.replaceAll('|', '');
      expect(typing.isHeld(strong: true, caret: caret, text: text), isTrue);
      expect(typing.isHeld(strong: false, caret: caret, text: text), isFalse);
      typing.releaseHeld(strong: true, text: text);
      expect(type(spaced, 'x', typing: typing), '**bold** x|');
    });

    test('taking bold off after bold italic leaves the italic waiting', () {
      final typing = MarkdownTyping();
      final spaced = type('***both|***', ' ', typing: typing);
      final text = spaced.replaceAll('|', '');
      typing.releaseHeld(strong: true, text: text);
      expect(type(spaced, 'x', typing: typing), '***both*** *x|*');
    });

    test('Return at the end of bold goes after it, and on down a list', () {
      expect(type('**bold|**', '\n'), '**bold**\n|');
      expect(type('- **bold|**', '\n'), '- **bold**\n- |');
    });

    test('emptying a styled word takes its markers too', () {
      expect(backspace('say **b|** now'), 'say | now');
      expect(backspace('`x|`'), '|');
      expect(backspace('[x|](https://a.example)'), '|');
      expect(backspace('~~y|~~'), '|');
      expect(backspace('a\\*|b'), 'a|b', reason: 'an escape and its character');
      expect(backspace('**bo|**'), '**b|**', reason: 'not while words remain');
    });
  });

  group('the structure at the start of a line', () {
    test('Backspace at the start of the words takes it off', () {
      expect(backspace('# |Title'), '|Title');
      expect(backspace('### |Three'), '|Three');
      expect(backspace('- |item'), '|item');
      expect(backspace('1. |one'), '|one');
      expect(backspace('- [ ] |task'), '|task');
      expect(backspace('> |quote'), '|quote');
      expect(backspace('> > |deep'), '> |deep');
      expect(backspace('- # |Both'), '- |Both', reason: 'the innermost first');
      expect(backspace('- a\n- |'), '- a\n|');
    });

    test('Backspace anywhere else is only Backspace', () {
      expect(backspace('# T|itle'), '# |itle');
      expect(backspace('plain\n|next'), 'plain|next');
    });

    test('Delete at the end of a line joins the next line\'s words', () {
      expect(deleteForward('one|\n- two'), 'one|two');
      expect(deleteForward('one|\n## Two'), 'one|Two');
      expect(deleteForward('one|\ntwo'), 'one|two');
    });

    test('Return at the start of a heading opens a line above it', () {
      expect(type('# |Title', '\n'), '\n# |Title');
      expect(type('# Ti|tle', '\n'), '# Ti\n|tle');
    });

    test('[] or [ ] and a space makes a task', () {
      expect(type('[]|', ' '), '- [ ] |');
      expect(type('[ ]|', ' '), '- [ ] |');
      expect(type('> []|', ' '), '> - [ ] |');
      expect(type('- []|', ' '), '- [] |', reason: 'already an item');
      expect(type('a []|', ' '), 'a [] |');
    });
  });
}
