import 'package:flutter/services.dart';

/// Everything the editor's slash menu can do.
///
/// These are commands, not document nodes. Kapy Notes remains one editable
/// string; a command either changes the current line, inserts ordinary text,
/// or enters an attachment through the editor's existing path.
enum SlashCommandType {
  checklist,
  bulletedList,
  image,
  voiceNote,
  table,
  divider,
  video,
  file,
  numberedList,
  quote,
  codeBlock,
}

/// A chosen command. Tables carry the size picked in the menu.
class SlashCommandChoice {
  const SlashCommandChoice(this.type) : tableRows = null, tableColumns = null;

  const SlashCommandChoice.table({required int rows, required int columns})
    : type = SlashCommandType.table,
      tableRows = rows,
      tableColumns = columns;

  final SlashCommandType type;
  final int? tableRows;
  final int? tableColumns;
}

/// The slash-led part of the current line that acts as a command search.
class SlashCommandInvocation {
  const SlashCommandInvocation({required this.range, required this.query});

  final TextRange range;
  final String query;
}

final _slashQuery = RegExp(r'^[\p{L}\p{N} _-]*$', unicode: true);

/// Finds a slash command only when `/` begins the current line.
///
/// Division is the app's primary language, so a slash after any other
/// character must remain an operator. Requiring the caret at the end of the
/// line also prevents moving through an existing `/something` line from
/// unexpectedly raising a menu.
SlashCommandInvocation? slashCommandInvocation(TextEditingValue value) {
  final selection = value.selection;
  if (!selection.isValid || !selection.isCollapsed) return null;
  final caret = selection.extentOffset;
  if (caret < 0 || caret > value.text.length) return null;

  final lineStart = caret == 0
      ? 0
      : value.text.lastIndexOf('\n', caret - 1) + 1;
  final nextLine = value.text.indexOf('\n', lineStart);
  final lineEnd = nextLine < 0 ? value.text.length : nextLine;
  if (caret != lineEnd || lineStart >= lineEnd) return null;
  if (value.text.codeUnitAt(lineStart) != 0x2F) return null;

  final query = value.text.substring(lineStart + 1, caret);
  if (query.length > 48 || !_slashQuery.hasMatch(query)) return null;
  return SlashCommandInvocation(
    range: TextRange(start: lineStart, end: caret),
    query: query,
  );
}

/// Plain GFM source for a simple table.
///
/// [rows] counts visible content rows. Markdown's delimiter row is structural
/// and is added in addition to them. The friendly header labels are selected
/// after insertion so typing replaces the first one immediately.
String markdownTableTemplate({required int rows, required int columns}) {
  final rowCount = rows.clamp(1, 6);
  final columnCount = columns.clamp(1, 6);
  String row(Iterable<String> cells) => '| ${cells.join(' | ')} |';

  return [
    row(List.generate(columnCount, (index) => 'Column ${index + 1}')),
    row(List.filled(columnCount, '---')),
    for (var index = 1; index < rowCount; index++)
      row(List.filled(columnCount, '')),
  ].join('\n');
}

/// Replaces a command search (or a collapsed insertion point) in one edit.
TextEditingValue replaceSlashCommandRange(
  TextEditingValue value,
  TextRange range,
  String replacement, {
  TextSelection? selection,
}) {
  if (!range.isValid || range.start < 0 || range.end > value.text.length) {
    return value;
  }
  return TextEditingValue(
    text: value.text.replaceRange(range.start, range.end, replacement),
    selection:
        selection ??
        TextSelection.collapsed(offset: range.start + replacement.length),
  );
}

/// Inserts a block without splicing it into the middle of surrounding prose.
///
/// A slash command already occupies its own line and therefore needs no
/// padding. The mobile insert button can be used in the middle of a line, so
/// that path receives the one newline needed on either side. [selectionInBlock]
/// is relative to [block], before those boundary newlines are added.
TextEditingValue replaceWithSlashCommandBlock(
  TextEditingValue value,
  TextRange range,
  String block, {
  TextSelection? selectionInBlock,
}) {
  if (!range.isValid || range.start < 0 || range.end > value.text.length) {
    return value;
  }
  final leading = range.start > 0 && value.text[range.start - 1] != '\n'
      ? '\n'
      : '';
  final trailing =
      range.end < value.text.length && value.text[range.end] != '\n'
      ? '\n'
      : '';
  final replacement = '$leading$block$trailing';
  final selection = selectionInBlock;
  return replaceSlashCommandRange(
    value,
    range,
    replacement,
    selection: selection == null
        ? null
        : TextSelection(
            baseOffset: range.start + leading.length + selection.baseOffset,
            extentOffset: range.start + leading.length + selection.extentOffset,
            affinity: selection.affinity,
            isDirectional: selection.isDirectional,
          ),
  );
}
