import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'support/desk.dart';
import 'test_fonts.dart';

/// Composes [steps] one marked text at a time, as an input method shows
/// them, then commits [commit].
Future<void> _compose(Desk desk, List<String> steps, String commit) async {
  for (final step in steps) {
    await desk.input.setMarkedText(step);
    await desk.tester.pump();
  }
  await desk.input.insertText(commit);
  await desk.settle();
}

Future<void> _openAtEnd(Desk desk, String body) async {
  await desk.open(body);
  await desk.click(desk.at(0));
  await desk.key(
    desk.mac ? LogicalKeyboardKey.arrowDown : LogicalKeyboardKey.end,
    primary: true,
  );
  expect(desk.selection.baseOffset, body.length);
}

void _expectCommitted(Desk desk, String text, int caret) {
  expect(desk.text, text);
  expect(desk.selection.isCollapsed, isTrue);
  expect(desk.selection.baseOffset, caret);
  expect(
    desk.note.value.composing.isCollapsed || !desk.note.value.composing.isValid,
    isTrue,
  );
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('a dead-key accent becomes one letter, and undo takes it back', (
    tester,
  ) async {
    final desk = Desk(tester);
    await _openAtEnd(desk, 'Title\ncaf');
    await desk.input.setMarkedText('´');
    await tester.pump();
    expect(desk.text, 'Title\ncaf´');
    await desk.input.insertText('é');
    await desk.settle();
    _expectCommitted(desk, 'Title\ncafé', 10);
    await desk.type(' au lait');
    await desk.undo();
    expect(desk.text, 'Title\ncafé');
    await desk.undo();
    expect(desk.text, 'Title\ncaf');
  }, variant: desktopPlatforms);

  testWidgets('the press-and-hold picker replaces the letter held', (
    tester,
  ) async {
    final desk = Desk(tester);
    await _openAtEnd(desk, 'Title\nresum');
    await desk.type('e');
    final held = TextRange(start: desk.text.length - 1, end: desk.text.length);
    await desk.input.setMarkedText('e', replacement: held);
    await tester.pump();
    await desk.input.insertText('é', replacement: held);
    await desk.settle();
    _expectCommitted(desk, 'Title\nresumé', 12);
    await desk.undo();
    expect(desk.text, 'Title\nresume');
  }, variant: desktopPlatforms);

  testWidgets('Japanese converts and commits its candidate mid-line', (
    tester,
  ) async {
    final desk = Desk(tester);
    await desk.open('Title\nab');
    await desk.click(desk.on('b'));
    await _compose(desk, ['k', 'か', 'かn', 'かん', 'かんj', 'かんじ', '漢字'], '漢字');
    _expectCommitted(desk, 'Title\na漢字b', 9);
    await desk.undo();
    expect(desk.text, 'Title\nab');
  }, variant: desktopPlatforms);

  testWidgets('Chinese pinyin commits its candidate', (tester) async {
    final desk = Desk(tester);
    await _openAtEnd(desk, 'Title\nsay ');
    await _compose(desk, ['n', 'ni', 'nih', 'niha', 'nihao', '你好'], '你好');
    _expectCommitted(desk, 'Title\nsay 你好', 12);
  }, variant: desktopPlatforms);

  testWidgets('a Hindi transliteration commits whole', (tester) async {
    final desk = Desk(tester);
    await _openAtEnd(desk, 'Title\n');
    await _compose(desk, [
      'n',
      'na',
      'nam',
      'nama',
      'namas',
      'namast',
      'namaste',
      'नमस्ते',
    ], 'नमस्ते');
    _expectCommitted(desk, 'Title\nनमस्ते', 6 + 'नमस्ते'.length);
    await desk.undo();
    expect(desk.text, 'Title\n');
  }, variant: desktopPlatforms);

  testWidgets('a composition on a list line stays in the item, and Return '
      'after it continues the list', (tester) async {
    final desk = Desk(tester);
    await _openAtEnd(desk, 'Title\n- milk and ');
    await _compose(desk, ['t', 'た', 'たm', 'たま', 'たまg', 'たまご', '卵'], '卵');
    _expectCommitted(desk, 'Title\n- milk and 卵', 18);
    await desk.enter();
    expect(desk.text, 'Title\n- milk and 卵\n- ');
  }, variant: desktopPlatforms);

  testWidgets('markdown waits for the composition to commit', (tester) async {
    final desk = Desk(tester);
    await _openAtEnd(desk, 'Title\n');
    for (final step in ['[', '[ ', '[ ]']) {
      await desk.input.setMarkedText(step);
      await tester.pump();
      expect(desk.text, 'Title\n$step');
    }
    await desk.input.insertText('[ ]');
    await desk.settle();
    expect(desk.text, 'Title\n[ ]');
    await desk.type(' ');
    expect(desk.text, 'Title\n- [ ] ');
    expect(desk.selection.baseOffset, 12);
  }, variant: desktopPlatforms);

  testWidgets('a composition in a table cell commits into the cell', (
    tester,
  ) async {
    const body = 'Title\n\n| a | b |\n| --- | --- |\n| Tea | 4 |\n\nafter';
    final cell = find.byKey(const ValueKey('table-cell-editor'));
    final desk = Desk(tester);
    await desk.open(body);
    await desk.click(desk.at(body.indexOf('| Tea')));
    expect(cell, findsOneWidget);
    final field = tester.widget<TextField>(cell).controller!;
    for (final step in [' k', ' か', ' かn', ' かん', ' 漢']) {
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: 'Tea$step',
          selection: TextSelection.collapsed(offset: 3 + step.length),
          composing: TextRange(start: 4, end: 3 + step.length),
        ),
      );
      await tester.pump();
      expect(field.text, 'Tea$step');
    }
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'Tea 漢',
        selection: TextSelection.collapsed(offset: 5),
      ),
    );
    await desk.settle();
    expect(field.text, 'Tea 漢');
    expect(field.selection.baseOffset, 5);
    expect(desk.text, contains('| Tea 漢 | 4 |'));
    expect(desk.text, endsWith('| Tea 漢 | 4 |\n\nafter'));
  }, variant: desktopPlatforms);
}
