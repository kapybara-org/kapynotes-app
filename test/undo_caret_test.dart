import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/desk.dart';
import 'test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);

  Future<void> toStart(Desk desk) => desk.key(
    desk.mac ? LogicalKeyboardKey.arrowUp : LogicalKeyboardKey.home,
    primary: true,
  );

  Future<void> toEnd(Desk desk) => desk.key(
    desk.mac ? LogicalKeyboardKey.arrowDown : LogicalKeyboardKey.end,
    primary: true,
  );

  testWidgets('undoing typing mid-line puts the caret where it was typed, '
      'and redo after it', (tester) async {
    final desk = Desk(tester);
    await desk.open('Title\nab and more');
    await desk.click(desk.on('b and'));
    await desk.type('xyz');
    expect(desk.text, 'Title\naxyzb and more');
    await toEnd(desk);
    await desk.undo();
    expect(desk.text, 'Title\nab and more');
    expect(desk.selection, const TextSelection.collapsed(offset: 7));
    await toStart(desk);
    await desk.redo();
    expect(desk.text, 'Title\naxyzb and more');
    expect(desk.selection, const TextSelection.collapsed(offset: 10));
  }, variant: desktopPlatforms);

  testWidgets('undoing a deletion selects nothing and puts the caret after '
      'the text it brings back; redo puts it where that text was', (
    tester,
  ) async {
    final desk = Desk(tester);
    await desk.open('Title\nthe cat sat');
    await desk.click(desk.on('cat', 1), times: 2);
    await desk.key(LogicalKeyboardKey.backspace);
    await desk.settle();
    expect(desk.text, 'Title\nthe  sat');
    await toStart(desk);
    await desk.undo();
    expect(desk.text, 'Title\nthe cat sat');
    expect(desk.selection, const TextSelection.collapsed(offset: 13));
    await toEnd(desk);
    await desk.redo();
    expect(desk.text, 'Title\nthe  sat');
    expect(desk.selection, const TextSelection.collapsed(offset: 10));
  }, variant: desktopPlatforms);

  testWidgets('undoing a paste puts the caret where it went, and redo after '
      'it', (tester) async {
    final desk = Desk(tester);
    await desk.open('Title\nbefore after');
    await desk.click(desk.on(' after'));
    desk.clipboard = {'text': 'one\ntwo'};
    await desk.paste();
    expect(desk.text, 'Title\nbeforeone\ntwo after');
    await toStart(desk);
    await desk.undo();
    expect(desk.text, 'Title\nbefore after');
    expect(desk.selection, const TextSelection.collapsed(offset: 12));
    await toStart(desk);
    await desk.redo();
    expect(desk.text, 'Title\nbeforeone\ntwo after');
    expect(desk.selection, const TextSelection.collapsed(offset: 19));
  }, variant: desktopPlatforms);

  testWidgets('undoing a checkbox click leaves the caret where it is', (
    tester,
  ) async {
    final desk = Desk(tester);
    const body = 'Title\n- [ ] milk\nnotes here';
    await desk.open(body);
    await desk.click(desk.on('here', 2));
    final caret = desk.selection;
    await desk.click(desk.on('[ ]', 1));
    expect(desk.text, 'Title\n- [x] milk\nnotes here');
    await desk.undo();
    expect(desk.text, body);
    expect(desk.selection, caret);
    await desk.redo();
    expect(desk.text, 'Title\n- [x] milk\nnotes here');
    expect(desk.selection, caret);
  }, variant: desktopPlatforms);

  group('in a long note', () {
    final body = [
      'Title',
      for (var i = 1; i <= 200; i++) 'Line $i, a few words in it.',
    ].join('\n');

    double scrolled(Desk desk) =>
        desk.note.state.widget.scrollController.position.pixels;

    testWidgets('undoing typing at the end of the note brings the caret '
        'back to it, into view', (tester) async {
      final desk = Desk(tester);
      await desk.open(body);
      await toStart(desk);
      await desk.settle();
      await desk.click(desk.on('Title', 5));
      await desk.type('s');
      await toEnd(desk);
      await desk.type('!!');
      final atEnd = scrolled(desk);
      expect(atEnd, greaterThan(0));
      await toStart(desk);
      expect(scrolled(desk), 0);
      await desk.undo();
      expect(desk.text, 'Titles${body.substring(5)}');
      expect(desk.selection, TextSelection.collapsed(offset: body.length + 1));
      expect(scrolled(desk), greaterThan(atEnd / 2));
    }, variant: desktopPlatforms);

    testWidgets('undoing typing on screen does not scroll', (tester) async {
      final desk = Desk(tester);
      await desk.open(body);
      await toStart(desk);
      await desk.settle();
      await desk.click(desk.on('Line 3,', 4));
      await desk.type('x');
      expect(desk.text, isNot(body));
      await desk.click(desk.on('Line 5,', 4));
      final before = scrolled(desk);
      await desk.undo();
      expect(desk.text, body);
      expect(
        desk.selection,
        TextSelection.collapsed(offset: body.indexOf('Line 3,') + 4),
      );
      expect(scrolled(desk), before);
    }, variant: desktopPlatforms);
  });
}
