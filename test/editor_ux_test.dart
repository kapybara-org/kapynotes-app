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
      await desk.paste();
      expect(desk.text, 'cat dog dog');
      await desk.click(desk.on('cat', 1), times: 2);
      await desk.cut();
      expect(desk.clipboard['text'], 'cat');
      expect(desk.text, ' dog dog');
      desk.clipboard = {'text': 'one\ntwo\nthree'};
      await desk.paste();
      expect(desk.text, ' one\n two\n threedog dog');
      desk.clipboard = {'text': 'big news', 'html': '<p><b>big</b> news</p>'};
      await desk.key(LogicalKeyboardKey.keyA, primary: true);
      await desk.paste();
      expect(desk.text, '**big** news');
    }, variant: desktopPlatforms);
  });

  group('caret and selection', () {
    testWidgets('to the start and end of the note', (tester) async {
      final desk = Desk(tester);
      await desk.open('one\ntwo\nthree');
      await desk.click(desk.on('two', 1));
      final mac = desk.mac;
      await desk.key(
        mac ? LogicalKeyboardKey.arrowDown : LogicalKeyboardKey.end,
        primary: true,
      );
      expect(
        desk.selection,
        isA<TextSelection>().having((s) => s.baseOffset, 'offset', 13),
      );
      await desk.key(
        mac ? LogicalKeyboardKey.arrowUp : LogicalKeyboardKey.home,
        primary: true,
        shift: true,
      );
      expect(desk.selection.textInside(desk.text), desk.text);
    }, variant: desktopPlatforms);

    testWidgets('a drag across a heading and a list takes both, and the '
        'bubble formats each line', (tester) async {
      final desk = Desk(tester);
      await desk.open('Title\n## Plan\n- milk\n- eggs');
      await desk.drag(desk.on('Plan'), desk.on('eggs', 4));
      expect(desk.selection.textInside(desk.text), 'Plan\n- milk\n- eggs');
      expect(find.byKey(const ValueKey('selection-bubble')), findsOneWidget);
      await desk.clickKey('selection-bold');
      expect(desk.text, 'Title\n## **Plan**\n- **milk**\n- **eggs**');
      await desk.clickKey('selection-bold');
      expect(desk.text, 'Title\n## Plan\n- milk\n- eggs');
    }, variant: desktopPlatforms);
  });

  group('blocks', () {
    testWidgets('numbered lists and quotes continue, and an empty one ends', (
      tester,
    ) async {
      final desk = Desk(tester);
      await desk.open('Title\n1. a');
      await desk.click(desk.on('a', 1));
      await desk.enter();
      expect(desk.text, 'Title\n1. a\n2. ');
      await desk.enter();
      expect(desk.text, 'Title\n1. a\n');
      await desk.type('> q');
      await desk.enter();
      expect(desk.text, 'Title\n1. a\n> q\n> ');
      await desk.enter();
      expect(desk.text, 'Title\n1. a\n> q\n');
    }, variant: desktopPlatforms);

    testWidgets(
      'a heading ends at Enter, and a divider typed under words keeps a blank line above it',
      (tester) async {
        final desk = Desk(tester);
        await desk.open('Title\n');
        await desk.key(
          desk.mac ? LogicalKeyboardKey.arrowDown : LogicalKeyboardKey.end,
          primary: true,
        );
        await desk.type('## Plan');
        await desk.enter();
        await desk.type('body');
        expect(desk.text, 'Title\n## Plan\nbody');
        await desk.enter();
        await desk.type('---');
        await desk.enter();
        await desk.type('after');
        expect(desk.text, 'Title\n## Plan\nbody\n\n---\nafter');
      },
      variant: desktopPlatforms,
    );

    testWidgets('clicking a checkbox ticks it and leaves the caret', (
      tester,
    ) async {
      final desk = Desk(tester);
      await desk.open('Title\n- [ ] milk\nnotes here');
      await desk.click(desk.on('here', 2));
      final caret = desk.selection;
      await desk.click(desk.on('[ ]', 1));
      expect(desk.text, 'Title\n- [x] milk\nnotes here');
      expect(desk.selection, caret);
      await desk.click(desk.on('[x]', 1));
      expect(desk.text, 'Title\n- [ ] milk\nnotes here');
      expect(desk.selection, caret);
    }, variant: desktopPlatforms);

    testWidgets('the link shortcut links the selection', (tester) async {
      final desk = Desk(tester);
      await desk.open('Read the docs today');
      await desk.click(desk.on('docs', 1), times: 2);
      await desk.chord(ShortcutAction.formatLink);
      expect(
        find.byKey(const ValueKey('selection-link-field')),
        findsOneWidget,
      );
      await desk.tester.enterText(
        find.byKey(const ValueKey('selection-link-field')),
        'https://kapynotes.app',
      );
      await desk.tester.testTextInput.receiveAction(TextInputAction.done);
      await desk.settle();
      expect(desk.text, 'Read the [docs](https://kapynotes.app) today');
    }, variant: desktopPlatforms);

    for (final (address, written, destination) in [
      (
        'https://kapynotes.app/docs',
        'https://kapynotes.app/docs',
        'https://kapynotes.app/docs',
      ),
      (
        'https://example.com/my notes',
        'https://example.com/my%20notes',
        'https://example.com/my%20notes',
      ),
      (
        'https://en.wikipedia.org/wiki/Foo_(bar)',
        '<https://en.wikipedia.org/wiki/Foo_(bar)>',
        'https://en.wikipedia.org/wiki/Foo_(bar)',
      ),
      ('https://x.com/a)b', '<https://x.com/a)b>', 'https://x.com/a)b'),
    ]) {
      testWidgets('a link to $address stays one link', (tester) async {
        final desk = Desk(tester);
        await desk.open('Read the docs today');
        await desk.click(desk.on('docs', 1), times: 2);
        await desk.chord(ShortcutAction.formatLink);
        await desk.tester.enterText(
          find.byKey(const ValueKey('selection-link-field')),
          address,
        );
        await desk.tester.testTextInput.receiveAction(TextInputAction.done);
        await desk.settle();
        expect(desk.text, 'Read the [docs]($written) today');
        final links = desk.note.controller.markdownFor(desk.text).links;
        expect(links.single.destination, destination);
      }, variant: desktopPlatforms);
    }

    testWidgets('a formula shows its result as it is typed', (tester) async {
      final desk = Desk(tester);
      await desk.open('Sums\n', results: true);
      await desk.key(
        desk.mac ? LogicalKeyboardKey.arrowDown : LogicalKeyboardKey.end,
        primary: true,
      );
      await desk.type('12 + 30');
      expect(find.textContaining('42'), findsWidgets);
      await desk.key(LogicalKeyboardKey.backspace);
      await desk.settle();
      expect(find.textContaining('15'), findsWidgets);
    }, variant: desktopPlatforms);
  });

  group('a caret in front of a hidden marker', () {
    for (final (line, typed) in [
      ('- item', '- xitem'),
      ('## Heading', '## xHeading'),
      ('> quote', '> xquote'),
      ('- [ ] task', '- [ ] xtask'),
      ('  - nested', '  - xnested'),
    ]) {
      testWidgets('typing at the start of $line goes in after its marker', (
        tester,
      ) async {
        final desk = Desk(tester);
        await desk.open('Title\n$line');
        await desk.click(desk.on(line.trim().split(' ').last, 2));
        await desk.lineKey(end: false);
        await desk.type('x');
        expect(desk.text, 'Title\n$typed', reason: 'from the line key');
        await desk.open('Title\n$line\n');
        desk.place(6);
        await desk.settle();
        await desk.type('x');
        expect(desk.text, 'Title\n$typed\n', reason: 'from offset 0');
      }, variant: desktopPlatforms);
    }
  });

  group('shortcuts and undo', () {
    testWidgets('the text-style, bullet and checklist shortcuts', (
      tester,
    ) async {
      final desk = Desk(tester);
      await desk.open('Title\nmilk');
      await desk.click(desk.on('milk', 2));
      await desk.chord(ShortcutAction.formatBullets);
      expect(desk.text, 'Title\n- milk');
      await desk.chord(ShortcutAction.formatBullets);
      expect(desk.text, 'Title\nmilk');
      await desk.chord(ShortcutAction.formatChecklist);
      expect(desk.text, 'Title\n- [ ] milk');
      await desk.chord(ShortcutAction.formatChecklist);
      expect(desk.text, 'Title\nmilk');
      final styles = <String>[];
      for (var i = 0; i < 4; i++) {
        await desk.chord(ShortcutAction.cycleTextStyle);
        styles.add(desk.text);
      }
      expect(styles.first, startsWith('Title\n#'));
      expect(styles.toSet().length, greaterThan(1));
    }, variant: desktopPlatforms);

    testWidgets('undo steps back over list continuation and a multi-line '
        'paste', (tester) async {
      final desk = Desk(tester);
      await desk.open('Title\n- one');
      await desk.click(desk.on('one', 3));
      await desk.enter();
      expect(desk.text, 'Title\n- one\n- ');
      await desk.undo();
      expect(desk.text, 'Title\n- one');
      await desk.redo();
      expect(desk.text, 'Title\n- one\n- ');
      desk.clipboard = {'text': 'two\nthree'};
      await desk.paste();
      expect(desk.text, 'Title\n- one\n- two\n- three');
      await desk.undo();
      expect(desk.text, 'Title\n- one\n- ');
      await desk.redo();
      expect(desk.text, 'Title\n- one\n- two\n- three');
    }, variant: desktopPlatforms);

    testWidgets('redo is also Ctrl+Y on Windows', (tester) async {
      final desk = Desk(tester);
      await desk.open('hello');
      await desk.click(desk.on('hello', 4));
      await desk.lineKey(end: true);
      await desk.type('!');
      await desk.undo();
      expect(desk.text, 'hello');
      await desk.key(LogicalKeyboardKey.keyY, primary: true);
      await desk.settle();
      expect(desk.text, 'hello!');
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  });
}
