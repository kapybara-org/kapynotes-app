import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:material_ui/material_ui.dart';

import 'support/desk.dart';
import 'test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);

  group('smoke', () {
    testWidgets('typing: Backspace, Delete, Enter mid-line, typing over a '
        'selection', (tester) async {
      final desk = Desk(tester);
      await desk.open('alpha beta\ngamma');
      await desk.click(desk.on('gamma'));
      expect(desk.selection, TextSelection.collapsed(offset: 11));
      await desk.key(LogicalKeyboardKey.backspace);
      expect(desk.text, 'alpha betagamma');
      expect(desk.selection, const TextSelection.collapsed(offset: 10));
      await desk.enter();
      expect(desk.text, 'alpha beta\ngamma');
      await desk.click(desk.on('beta', 4));
      await desk.key(LogicalKeyboardKey.delete);
      expect(desk.text, 'alpha betagamma');
      await desk.click(desk.on('beta', 2));
      await desk.enter();
      expect(desk.text, 'alpha be\ntagamma');
      await desk.click(desk.on('alpha', 1), times: 2);
      expect(desk.selection.textInside(desk.text), 'alpha');
      await desk.type('one');
      expect(desk.text, 'one be\ntagamma');
    }, variant: desktopPlatforms);

    testWidgets('caret: arrows, word and line jumps, shift to extend', (
      tester,
    ) async {
      final desk = Desk(tester);
      await desk.open('one two three\nfour five');
      await desk.click(desk.on('two'));
      await desk.key(LogicalKeyboardKey.arrowRight);
      expect(desk.selection.baseOffset, 5);
      await desk.key(LogicalKeyboardKey.arrowLeft);
      await desk.wordKey(LogicalKeyboardKey.arrowRight);
      expect(desk.selection.baseOffset, 7);
      await desk.lineKey(end: true);
      expect(desk.selection.baseOffset, 13);
      await desk.lineKey(end: false);
      expect(desk.selection.baseOffset, 0);
      await desk.key(LogicalKeyboardKey.arrowDown);
      expect(desk.selection.baseOffset, 14);
      await desk.wordKey(LogicalKeyboardKey.arrowRight, shift: true);
      expect(desk.selection.textInside(desk.text), 'four');
      await desk.key(LogicalKeyboardKey.arrowRight, shift: true);
      expect(desk.selection.textInside(desk.text), 'four ');
      final end = desk.note.caretRect(const TextPosition(offset: 13));
      await desk.click(desk.note.toGlobal(end.center + const Offset(200, 0)));
      expect(desk.selection.isCollapsed, isTrue);
      expect(desk.selection.baseOffset, 13);
    }, variant: desktopPlatforms);

    testWidgets('selection: double, triple, drag, shift-click, select all', (
      tester,
    ) async {
      final desk = Desk(tester);
      await desk.open('first line here\nsecond line\nthird');
      await desk.click(desk.on('line', 1), times: 2);
      expect(desk.selection.textInside(desk.text), 'line');
      await desk.click(desk.on('second', 2), times: 3);
      expect(desk.selection.textInside(desk.text).trim(), 'second line');
      await desk.drag(desk.on('line here'), desk.on('third', 2));
      expect(
        desk.selection.textInside(desk.text),
        'line here\nsecond line\nth',
      );
      await desk.click(desk.on('first'));
      await desk.click(desk.on('line', 2), shift: true);
      expect(desk.selection.textInside(desk.text), 'first li');
      await desk.key(LogicalKeyboardKey.keyA, primary: true);
      expect(desk.selection.textInside(desk.text), desk.text);
    }, variant: desktopPlatforms);

    testWidgets('a double click takes the whole of the last word of a line, '
        'the title included', (tester) async {
      final desk = Desk(tester);
      await desk.open('cat dog bird\nfish');
      await desk.click(desk.on('bird', 1), times: 2);
      expect(desk.selection.textInside(desk.text), 'bird');
      await desk.click(desk.on('fish', 1), times: 2);
      expect(desk.selection.textInside(desk.text), 'fish');
    }, variant: desktopPlatforms);

    testWidgets('the bubble: double-click a word, then every button', (
      tester,
    ) async {
      final desk = Desk(tester);
      await desk.open('Some words to format');
      for (final (name, wrapped) in [
        ('bold', '**words**'),
        ('italic', '*words*'),
        ('strikethrough', '~~words~~'),
        ('code', '`words`'),
      ]) {
        await desk.click(desk.on('words', 1), times: 2);
        expect(find.byKey(const ValueKey('selection-bubble')), findsOneWidget);
        await desk.clickKey('selection-$name');
        expect(desk.text, contains(wrapped), reason: name);
        await desk.clickKey('selection-$name');
        expect(desk.text, 'Some words to format', reason: '$name off');
      }
      await desk.click(desk.on('Some', 1), times: 2);
      await desk.clickKey('selection-block');
      await desk.clickKey('selection-block-Heading 1');
      expect(desk.text, '# Some words to format');
    }, variant: desktopPlatforms);

    testWidgets('shortcuts: bold, italic, strikethrough, code', (tester) async {
      final desk = Desk(tester);
      await desk.open('Some words to format');
      for (final (action, wrapped) in [
        (ShortcutAction.formatBold, '**words**'),
        (ShortcutAction.formatItalic, '*words*'),
        (ShortcutAction.formatStrikethrough, '~~words~~'),
        (ShortcutAction.formatCode, '`words`'),
      ]) {
        await desk.click(desk.on('words', 1), times: 2);
        await desk.chord(action);
        expect(desk.text, contains(wrapped), reason: action.name);
        await desk.chord(action);
        expect(desk.text, 'Some words to format', reason: '${action.name} off');
      }
    }, variant: desktopPlatforms);

    testWidgets('lists: Enter continues, Enter on an empty item ends, Tab '
        'indents', (tester) async {
      final desk = Desk(tester);
      await desk.open('- one');
      await desk.click(desk.on('one', 3));
      await desk.lineKey(end: true);
      await desk.enter();
      expect(desk.text, '- one\n- ');
      await desk.key(LogicalKeyboardKey.tab);
      await desk.settle();
      expect(desk.text, '- one\n  - ');
      await desk.key(LogicalKeyboardKey.tab, shift: true);
      await desk.settle();
      expect(desk.text, '- one\n- ');
      await desk.type('two');
      await desk.enter();
      expect(desk.text, '- one\n- two\n- ');
      await desk.enter();
      expect(desk.text, '- one\n- two\n');
      await desk.open('- [ ] task');
      await desk.click(desk.on('task', 4));
      await desk.enter();
      expect(desk.text, '- [ ] task\n- [ ] ');
    }, variant: desktopPlatforms);

    testWidgets('undo and redo across typing, formatting and paste', (
      tester,
    ) async {
      final desk = Desk(tester);
      await desk.open('hello');
      await desk.click(desk.on('hello', 4));
      await desk.lineKey(end: true);
      await desk.type(' world');
      expect(desk.text, 'hello world');
      await desk.undo();
      expect(desk.text, 'hello');
      await desk.redo();
      expect(desk.text, 'hello world');
      await desk.click(desk.on('world', 1), times: 2);
      await desk.chord(ShortcutAction.formatBold);
      expect(desk.text, 'hello **world**');
      await desk.undo();
      expect(desk.text, 'hello world');
      desk.clipboard = {'text': '!'};
      await desk.lineKey(end: true);
      await desk.paste();
      expect(desk.text, 'hello world!');
      await desk.undo();
      expect(desk.text, 'hello world');
    }, variant: desktopPlatforms);

    testWidgets('clipboard: copy, cut, paste over a selection, multi-line and '
        'rich paste', (tester) async {
      final desk = Desk(tester);
      await desk.open('cat dog bird');
      await desk.click(desk.on('dog', 1), times: 2);
      await desk.copy();
      expect(desk.clipboard['text'], 'dog');
      await desk.click(desk.on('bird', 1), times: 2);
      debugPrint(
        'SEL ${desk.selection} ${desk.selection.textInside(desk.text)}',
      );
      await desk.paste();
      expect(desk.text, 'cat dog dog');
      await desk.click(desk.on('cat', 1), times: 2);
      await desk.cut();
      expect(desk.clipboard['text'], 'cat');
      expect(desk.text, ' dog dog');
      desk.clipboard = {'text': 'one\ntwo\nthree'};
      await desk.paste();
      expect(desk.text, 'one\ntwo\nthree dog dog');
      desk.clipboard = {'text': 'big news', 'html': '<p><b>big</b> news</p>'};
      await desk.key(LogicalKeyboardKey.keyA, primary: true);
      await desk.paste();
      expect(desk.text, '**big** news');
    }, variant: desktopPlatforms);
  });
}
