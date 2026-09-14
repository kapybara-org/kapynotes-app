import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ui/editor/slash_commands.dart';

void main() {
  group('slash command invocation', () {
    test('starts only at the beginning of the current line', () {
      final first = slashCommandInvocation(
        const TextEditingValue(
          text: '/table',
          selection: TextSelection.collapsed(offset: 6),
        ),
      );
      expect(first?.range, const TextRange(start: 0, end: 6));
      expect(first?.query, 'table');

      final second = slashCommandInvocation(
        const TextEditingValue(
          text: 'above\n/todo',
          selection: TextSelection.collapsed(offset: 11),
        ),
      );
      expect(second?.range, const TextRange(start: 6, end: 11));
      expect(second?.query, 'todo');
    });

    test('does not claim division, URLs, or a moved caret', () {
      for (final value in [
        const TextEditingValue(
          text: '10 / 2',
          selection: TextSelection.collapsed(offset: 7),
        ),
        const TextEditingValue(
          text: 'https://example.com',
          selection: TextSelection.collapsed(offset: 19),
        ),
        const TextEditingValue(
          text: '/table later',
          selection: TextSelection.collapsed(offset: 6),
        ),
        const TextEditingValue(
          text: '/table',
          selection: TextSelection(baseOffset: 0, extentOffset: 6),
        ),
      ]) {
        expect(slashCommandInvocation(value), isNull, reason: value.text);
      }
    });
  });

  test('table template counts content rows and columns', () {
    expect(
      markdownTableTemplate(rows: 2, columns: 3),
      '| Column 1 | Column 2 | Column 3 |\n'
      '| --- | --- | --- |\n'
      '|  |  |  |',
    );
  });

  test('block insertion keeps surrounding prose on its own lines', () {
    final result = replaceWithSlashCommandBlock(
      const TextEditingValue(
        text: 'beforeafter',
        selection: TextSelection.collapsed(offset: 6),
      ),
      const TextRange.collapsed(6),
      '```\n\n```',
      selectionInBlock: const TextSelection.collapsed(offset: 4),
    );

    expect(result.text, 'before\n```\n\n```\nafter');
    expect(result.selection, const TextSelection.collapsed(offset: 11));
  });
}
