import 'package:flutter/services.dart';

import 'editor_formatting.dart';
import 'markdown_syntax.dart';

/// The structure at the start of one line of a markdown note: indentation,
/// quote markers, a list marker and a task box — everything that belongs to
/// the line's shape rather than to its words.
///
/// Read from the line itself rather than from the parsed note, the way every
/// markdown editor decides what Enter and Tab do. The two can disagree —
/// `2. item` straight under a paragraph is not a list to CommonMark, which
/// only lets a list starting at 1 interrupt one — and on a keypress what the
/// writer plainly meant is the better guide.
class MarkdownLinePrefix {
  const MarkdownLinePrefix._(
    this._text, {
    required this.lineStart,
    required this.lineEnd,
    required this.indentEnd,
    required this.quoteEnd,
    required this.markerStart,
    required this.markerEnd,
    required this.glyph,
    required this.taskBox,
    required this.taskChecked,
    required this.contentStart,
    required this.headingLevel,
    required this.headingEnd,
  });

  /// The whole note. Kept for reading the marker back, never copied.
  final String _text;

  final int lineStart;
  final int lineEnd;

  /// Where the leading whitespace ends.
  final int indentEnd;

  /// Where the quote markers, and the space after each, end. Equal to
  /// [indentEnd] on a line that is not quoted.
  final int quoteEnd;

  /// The list marker — `-`, `*`, `+`, `1.`, `1)`, or one of the app's own
  /// bullets and boxes — or -1 on a line that is not a list item.
  final int markerStart;
  final int markerEnd;

  /// True for the app's own list glyphs, which its own list handling keeps
  /// looking after in a markdown note too.
  final bool glyph;

  /// The offset of a task's `[`, or null.
  final int? taskBox;
  final bool taskChecked;

  /// Where the words begin, after all of the above.
  final int contentStart;

  /// The ATX heading level at [contentStart], or 0.
  final int headingLevel;

  /// Where a heading's words begin; [contentStart] when there is none.
  final int headingEnd;

  bool get isQuoted => quoteEnd > indentEnd;
  bool get isListItem => markerStart >= 0;
  bool get isTask => taskBox != null || (glyph && _isGlyphBox);
  bool get isBullet => isListItem && !isTask && !isOrdered;
  bool get isOrdered => isListItem && !glyph && _isDigit(_marker.codeUnitAt(0));
  bool get isBlank => _text.substring(lineStart, lineEnd).trim().isEmpty;

  String get _marker => _text.substring(markerStart, markerEnd);
  bool get _isGlyphBox => _marker == '☐' || _marker == '☑';

  /// The width of the indentation in front of the list marker.
  int get markerColumn => markerStart - lineStart;

  /// The column the item's words start at, which is where an item nested in
  /// it has to be indented to.
  int get contentColumn => contentStart - lineStart;
}

bool _isDigit(int unit) => unit >= 0x30 && unit <= 0x39;
bool _isSpace(int unit) => unit == 0x20 || unit == 0x09;

final _thematicBreak = RegExp(r'^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$');

/// Reads the structure of the line containing [offset].
MarkdownLinePrefix markdownLinePrefix(String text, int offset) {
  final clipped = offset.clamp(0, text.length);
  final lineStart = clipped == 0 ? 0 : text.lastIndexOf('\n', clipped - 1) + 1;
  final newline = text.indexOf('\n', lineStart);
  final lineEnd = newline < 0 ? text.length : newline;

  var i = lineStart;
  while (i < lineEnd && _isSpace(text.codeUnitAt(i))) {
    i++;
  }
  final indentEnd = i;

  // `>`, `> >`, `>>`: every marker, each with the one space that belongs to it.
  var quoteEnd = indentEnd;
  var cursor = indentEnd;
  while (cursor < lineEnd && text.codeUnitAt(cursor) == 0x3E) {
    cursor++;
    if (cursor < lineEnd && _isSpace(text.codeUnitAt(cursor))) cursor++;
    quoteEnd = cursor;
    var ahead = cursor;
    while (ahead < lineEnd &&
        ahead - cursor < 3 &&
        text.codeUnitAt(ahead) == 0x20) {
      ahead++;
    }
    if (ahead < lineEnd && text.codeUnitAt(ahead) == 0x3E) {
      cursor = ahead;
    } else {
      break;
    }
  }

  var markerStart = -1;
  var markerEnd = -1;
  var glyph = false;
  int? taskBox;
  var taskChecked = false;
  var contentStart = quoteEnd;

  var at = quoteEnd;
  while (at < lineEnd && text.codeUnitAt(at) == 0x20) {
    at++;
  }
  final rest = text.substring(quoteEnd, lineEnd);
  if (!_thematicBreak.hasMatch(rest)) {
    for (final prefix in [...bulletPrefixes, uncheckedPrefix, checkedPrefix]) {
      if (text.startsWith(prefix, at) && at + prefix.length <= lineEnd) {
        markerStart = at;
        markerEnd = at + 1;
        glyph = true;
        contentStart = at + prefix.length;
        break;
      }
    }
    if (markerStart < 0 && at < lineEnd) {
      final unit = text.codeUnitAt(at);
      var end = -1;
      if (unit == 0x2D || unit == 0x2A || unit == 0x2B) {
        end = at + 1;
      } else if (_isDigit(unit)) {
        var digits = at;
        while (digits < lineEnd &&
            digits - at < 9 &&
            _isDigit(text.codeUnitAt(digits))) {
          digits++;
        }
        if (digits < lineEnd &&
            (text.codeUnitAt(digits) == 0x2E ||
                text.codeUnitAt(digits) == 0x29)) {
          end = digits + 1;
        }
      }
      if (end > 0 && (end == lineEnd || _isSpace(text.codeUnitAt(end)))) {
        markerStart = at;
        markerEnd = end;
        var words = end;
        while (words < lineEnd &&
            words - end < 4 &&
            _isSpace(text.codeUnitAt(words))) {
          words++;
        }
        contentStart = words;
        if (words + 3 <= lineEnd &&
            text.codeUnitAt(words) == 0x5B &&
            text.codeUnitAt(words + 2) == 0x5D &&
            (words + 3 == lineEnd || _isSpace(text.codeUnitAt(words + 3)))) {
          final mark = text.codeUnitAt(words + 1);
          if (mark == 0x20 || mark == 0x78 || mark == 0x58) {
            taskBox = words;
            taskChecked = mark != 0x20;
            contentStart = words + 3 == lineEnd ? lineEnd : words + 4;
          }
        }
      }
    }
  }
  if (markerStart < 0) contentStart = at;

  var headingLevel = 0;
  var headingEnd = contentStart;
  var hashes = contentStart;
  while (hashes < lineEnd && text.codeUnitAt(hashes) == 0x23) {
    hashes++;
  }
  final count = hashes - contentStart;
  if (count >= 1 &&
      count <= 6 &&
      (hashes == lineEnd || _isSpace(text.codeUnitAt(hashes)))) {
    headingLevel = count;
    headingEnd = hashes;
    while (headingEnd < lineEnd && _isSpace(text.codeUnitAt(headingEnd))) {
      headingEnd++;
    }
  }

  return MarkdownLinePrefix._(
    text,
    lineStart: lineStart,
    lineEnd: lineEnd,
    indentEnd: indentEnd,
    quoteEnd: quoteEnd,
    markerStart: markerStart,
    markerEnd: markerEnd,
    glyph: glyph,
    taskBox: taskBox,
    taskChecked: taskChecked,
    contentStart: contentStart,
    headingLevel: headingLevel,
    headingEnd: headingEnd,
  );
}

/// The marker Enter puts on the next line: the same bullet, the next number,
/// and a fresh box for a task.
String _nextMarker(String text, MarkdownLinePrefix line) {
  final marker = text.substring(line.markerStart, line.markerEnd);
  final spacing = text.substring(
    line.markerEnd,
    line.taskBox ?? line.contentStart,
  );
  final gap = spacing.isEmpty ? ' ' : spacing;
  // A new item starts unticked, in the app's own boxes as in markdown's.
  var next = marker == '☑' ? '☐' : marker;
  if (line.isOrdered) {
    final number = int.parse(marker.substring(0, marker.length - 1));
    final bumped = number + 1;
    if (bumped <= 999999999) {
      next = '$bumped${marker.substring(marker.length - 1)}';
    }
  }
  return line.taskBox == null ? '$next$gap' : '$next$gap[ ] ';
}

/// What Enter does on a markdown list item or quote line.
///
/// Null leaves the keypress to the note's own list handling — a line in the
/// app's own bullets, or a line with no list or quote at all.
///
/// On an item with words, the next line gets the same structure: the same
/// quote markers, the same bullet or the next number, an empty box. On an
/// empty item the keypress is the writer backing out, and the newline is
/// swallowed: a nested item steps out to its parent's level, an item at the
/// margin stops being one, and an empty quote line loses one level of quote.
TextEditingValue? continueMarkdownLine(
  TextEditingValue oldValue,
  TextEditingValue newValue,
) {
  final selection = oldValue.selection;
  if (!selection.isValid || !selection.isCollapsed) return null;
  final caret = selection.extentOffset;
  final text = oldValue.text;
  if (newValue.text != text.replaceRange(caret, caret, '\n')) return null;

  final line = markdownLinePrefix(text, caret);
  if (line.glyph) return null;
  if (!line.isListItem && !line.isQuoted) return null;
  // Enter in front of the words — before the marker, inside the quote
  // markers — moves the whole line down, structure and all.
  if (caret < line.contentStart) return newValue;

  final words = text.substring(line.contentStart, line.lineEnd);
  if (words.trim().isNotEmpty) {
    var continuation = text.substring(line.lineStart, line.quoteEnd);
    if (line.isListItem) {
      continuation +=
          text.substring(line.quoteEnd, line.markerStart) +
          _nextMarker(text, line);
    }
    return newValue.copyWith(
      text: newValue.text.replaceRange(caret + 1, caret + 1, continuation),
      selection: TextSelection.collapsed(
        offset: caret + 1 + continuation.length,
      ),
      composing: TextRange.empty,
    );
  }

  if (line.isListItem) {
    final parent = line.isQuoted ? null : _parentItem(text, line);
    if (line.markerColumn > 0 && !line.isQuoted) {
      // Step out one level: to where the item this one is nested in sits,
      // continuing that item's list.
      final indent = ' ' * (parent?.markerColumn ?? 0);
      final marker = parent == null
          ? text.substring(line.markerStart, line.contentStart)
          : _nextMarker(text, parent);
      final replacement = '$indent$marker';
      return TextEditingValue(
        text: text.replaceRange(line.lineStart, line.contentStart, replacement),
        selection: TextSelection.collapsed(
          offset: line.lineStart + replacement.length,
        ),
      );
    }
    return TextEditingValue(
      text: text.replaceRange(line.markerStart, line.contentStart, ''),
      selection: TextSelection.collapsed(offset: line.markerStart),
    );
  }

  // An empty quote line: out of the innermost quote.
  final lastMarker = text.lastIndexOf('>', line.quoteEnd - 1);
  final kept = text.substring(line.lineStart, lastMarker).trimRight();
  final replacement = kept.isEmpty ? '' : '$kept ';
  return TextEditingValue(
    text: text.replaceRange(line.lineStart, line.lineEnd, replacement),
    selection: TextSelection.collapsed(
      offset: line.lineStart + replacement.length,
    ),
  );
}

/// The lines above [line], nearest first, as far as its list can reach.
///
/// Blank lines are passed over — a list goes on across them — and so are
/// words indented under an item, which still belong to it, and words at the
/// margin straight under an item's own, which markdown reads as more of that
/// item. Anything else at the margin ends the list, and the walk with it.
Iterable<MarkdownLinePrefix> _itemsAbove(
  String text,
  MarkdownLinePrefix line,
) sync* {
  var start = line.lineStart;
  while (start > 0) {
    start = text.lastIndexOf('\n', start - 2) + 1;
    final above = markdownLinePrefix(text, start);
    if (above.isBlank) continue;
    if (above.isListItem && !above.isQuoted) {
      yield above;
    } else if (above.indentEnd == above.lineStart &&
        !_continuesParagraph(text, above)) {
      return;
    }
  }
}

/// Whether a line at the margin could be a paragraph going on from the line
/// above it — CommonMark's lazy continuation, which lets `- item` be followed
/// by `more words` without the list ending.
///
/// Only plain words qualify, and only straight under another line: a blank
/// line ends the paragraph first, and a heading, a quote, a fence or a rule
/// starts a block of its own.
bool _continuesParagraph(String text, MarkdownLinePrefix line) {
  if (line.lineStart == 0 || line.isQuoted || line.headingLevel > 0) {
    return false;
  }
  final words = text.substring(line.lineStart, line.lineEnd);
  if (_thematicBreak.hasMatch(words) ||
      words.startsWith('```') ||
      words.startsWith('~~~')) {
    return false;
  }
  final above = text.lastIndexOf('\n', line.lineStart - 2) + 1;
  return !markdownLinePrefix(text, above).isBlank;
}

/// The item [line] is nested in: the nearest item above it whose marker sits
/// further left, or null at the margin.
MarkdownLinePrefix? _parentItem(String text, MarkdownLinePrefix line) {
  for (final above in _itemsAbove(text, line)) {
    if (above.markerColumn < line.markerColumn) return above;
  }
  return null;
}

/// The item [line] would be nested into by Tab: the nearest item above at
/// its own level, or null if its parent comes first and there is nothing to
/// go under.
MarkdownLinePrefix? _previousSibling(String text, MarkdownLinePrefix line) {
  for (final above in _itemsAbove(text, line)) {
    if (above.markerColumn == line.markerColumn) return above;
    if (above.markerColumn < line.markerColumn) return null;
  }
  return null;
}

/// How deep [line] is nested: how many items it sits inside.
int _depthOf(String text, MarkdownLinePrefix line) {
  var depth = 0;
  var current = line;
  while (true) {
    final parent = _parentItem(text, current);
    if (parent == null) return depth;
    depth++;
    current = parent;
  }
}

/// Every line the selection touches, by where each one starts.
///
/// A selection ending just after a newline does not take in the line below:
/// selecting two whole lines by dragging to the start of the third is
/// selecting two lines.
List<int> _selectedLineStarts(String text, TextSelection selection) {
  final first = selection.start.clamp(0, text.length);
  var last = selection.end.clamp(0, text.length);
  if (!selection.isCollapsed && last > first && text[last - 1] == '\n') {
    last--;
  }
  final firstStart = first == 0 ? 0 : text.lastIndexOf('\n', first - 1) + 1;
  final starts = <int>[firstStart];
  var cursor = firstStart;
  while (true) {
    final newline = text.indexOf('\n', cursor);
    if (newline < 0 || newline + 1 > last) break;
    cursor = newline + 1;
    starts.add(cursor);
  }
  return starts;
}

/// The selected lines worth restyling. A run of lines skips its blank ones —
/// a blank line in the middle of a list is a gap, not an item — while a lone
/// blank line is kept, so a style can be switched on before typing. A line
/// holding an attachment is never one of them.
List<MarkdownLinePrefix> _selectedLines(String text, TextSelection selection) {
  final lines = [
    for (final start in _selectedLineStarts(text, selection))
      if (markdownLinePrefix(text, start) case final line
          when !_holdsAttachment(line))
        line,
  ];
  if (lines.length <= 1) return lines;
  final filled = lines.where((line) => !line.isBlank).toList();
  return filled.isEmpty ? lines : filled;
}

class _Edit {
  const _Edit(this.start, this.end, this.replacement);

  final int start;
  final int end;
  final String replacement;
}

/// Non-overlapping [_Edit]s made to one text, and how offsets move across
/// them.
class _Rewrite {
  _Rewrite(String original, List<_Edit> edits)
    : _edits = [...edits]..sort((a, b) => a.start.compareTo(b.start)) {
    var result = original;
    for (final edit in _edits.reversed) {
      result = result.replaceRange(edit.start, edit.end, edit.replacement);
    }
    text = result;
  }

  final List<_Edit> _edits;
  late final String text;

  /// Where [offset] lands. One inside a replaced stretch goes to the end of
  /// what replaced it — so a caret stays with the words after new syntax,
  /// rather than being left in front of it — unless [before], which keeps it
  /// in front.
  int map(int offset, {bool before = false}) {
    var delta = 0;
    for (final edit in _edits) {
      if (offset < edit.start) break;
      if (offset <= edit.end) {
        final landing = edit.start + delta;
        return (before ? landing : landing + edit.replacement.length).clamp(
          0,
          text.length,
        );
      }
      delta += edit.replacement.length - (edit.end - edit.start);
    }
    return (offset + delta).clamp(0, text.length);
  }
}

/// A change a formatting control made, and where it moved everything else.
///
/// The map is the point. An attachment or a style kept beside the text is
/// anchored to an offset, and the editor's usual way of carrying one across
/// an edit — find the one stretch that changed — cannot describe markers
/// added at both ends of a word, or at the start of five lines: everything in
/// between reads as replaced, and a picture in there would be lost.
class MarkdownEdit {
  MarkdownEdit._(this.value, this._rewrite) : pending = false;

  MarkdownEdit._unchanged(this.value) : _rewrite = null, pending = false;

  /// Only the caret moves: out past a word's markers, say.
  MarkdownEdit._moving(TextEditingValue value, int caret)
    : value = value.copyWith(selection: TextSelection.collapsed(offset: caret)),
      _rewrite = null,
      pending = false;

  /// Nothing changes yet: the style is for the next word typed at the caret.
  MarkdownEdit._pending(this.value) : _rewrite = null, pending = true;

  final TextEditingValue value;
  final _Rewrite? _rewrite;

  /// Whether the style belongs to whatever is typed next, where the caret is,
  /// rather than to anything already written. See [MarkdownTyping].
  final bool pending;

  bool get changesText => _rewrite != null;

  /// Where [offset] in the text before the edit is now. [before] keeps an
  /// offset in front of anything inserted exactly there.
  int map(int offset, {bool before = false}) =>
      _rewrite?.map(offset, before: before) ?? offset;
}

/// Applies non-overlapping [edits] and carries the selection across them.
MarkdownEdit _applyEdits(TextEditingValue value, List<_Edit> edits) {
  if (edits.isEmpty) return MarkdownEdit._unchanged(value);
  final rewrite = _Rewrite(value.text, edits);
  final selection = value.selection.isValid
      ? value.selection
      : TextSelection.collapsed(offset: value.text.length);
  return MarkdownEdit._(
    TextEditingValue(
      text: rewrite.text,
      selection: TextSelection(
        baseOffset: rewrite.map(selection.baseOffset),
        extentOffset: rewrite.map(selection.extentOffset),
        affinity: selection.affinity,
        isDirectional: selection.isDirectional,
      ),
    ),
    rewrite,
  );
}

/// Whether a line holds an attachment. The formatting controls leave such a
/// line alone: a picture's line holds nothing else, and markers are
/// something else.
bool _holdsAttachment(MarkdownLinePrefix line) =>
    line._text.substring(line.lineStart, line.lineEnd).contains('￼');

/// Whether every line the selection touches is already in [style].
bool markdownSelectionHasLineStyle(
  TextEditingValue value,
  NoteLineStyle style,
) {
  if (!value.selection.isValid) return false;
  final lines = _selectedLines(value.text, value.selection);
  return lines.isNotEmpty &&
      lines.every(
        (line) => switch (style) {
          NoteLineStyle.bullet => line.isBullet,
          NoteLineStyle.checklist => line.isTask,
        },
      );
}

/// The bullet and checklist buttons, writing markdown.
///
/// Lines already in the style lose it; otherwise every line gets it, a
/// numbered or bulleted line changing marker rather than gaining a second
/// one. A task keeps its tick when a list of them is made into tasks again.
MarkdownEdit toggleMarkdownLineStyle(
  TextEditingValue value,
  NoteLineStyle style,
) {
  final text = value.text;
  final selection = value.selection.isValid
      ? value.selection
      : TextSelection.collapsed(offset: text.length);
  final lines = _selectedLines(text, selection);
  if (lines.isEmpty) return MarkdownEdit._unchanged(value);
  final allStyled = lines.every(
    (line) => style == NoteLineStyle.bullet ? line.isBullet : line.isTask,
  );

  final edits = <_Edit>[];
  for (final line in lines) {
    if (allStyled) {
      edits.add(_Edit(line.markerStart, line.contentStart, ''));
      continue;
    }
    final String replacement;
    switch (style) {
      case NoteLineStyle.bullet:
        if (line.isBullet) continue;
        replacement = '- ';
      case NoteLineStyle.checklist:
        if (line.isTask) continue;
        final bullet = line.isBullet && !line.glyph
            ? text.substring(line.markerStart, line.markerEnd)
            : '-';
        replacement = '$bullet [ ] ';
    }
    final from = line.isListItem ? line.markerStart : line.contentStart;
    edits.add(_Edit(from, line.contentStart, replacement));
  }
  return _applyEdits(value, edits);
}

/// The heading level every selected line shares — 0 for body text — or null
/// when they differ.
int? markdownHeadingLevelForSelection(String text, TextSelection selection) {
  if (!selection.isValid) return 0;
  int? common;
  for (final line in _selectedLines(text, selection)) {
    final level = line.headingLevel;
    if (common == null) {
      common = level;
    } else if (common != level) {
      return null;
    }
  }
  return common ?? 0;
}

/// The level the style button goes to next: body text, then headings one to
/// three, then back. A mixed selection becomes body text first, the way the
/// rich styles do.
int nextMarkdownHeadingLevel(int? current) => switch (current) {
  null => 0,
  0 => 1,
  1 => 2,
  2 => 3,
  _ => 0,
};

/// What the text-style control calls [level] in a markdown note.
String markdownHeadingLabel(int? level) => switch (level) {
  null => 'Mixed',
  0 => 'Text',
  final heading => 'Heading $heading',
};

/// The same, as the two characters the footer has room for.
String markdownHeadingShortLabel(int? level) => switch (level) {
  null || 0 => 'Aa',
  final heading => 'H$heading',
};

/// Makes every selected line a heading at [level], or body text at 0.
MarkdownEdit applyMarkdownHeading(TextEditingValue value, int level) {
  final text = value.text;
  if (!value.selection.isValid) return MarkdownEdit._unchanged(value);
  final marker = level <= 0 ? '' : '${'#' * level.clamp(1, 6)} ';
  return _applyEdits(value, [
    for (final line in _selectedLines(text, value.selection))
      if (text.substring(line.contentStart, line.headingEnd) != marker)
        _Edit(line.contentStart, line.headingEnd, marker),
  ]);
}

/// Whether the selection sits in markdown of [style] — inside `**…**` for
/// bold, say — which is what lights its button.
bool markdownSelectionHas(
  MarkdownAnalysis analysis,
  TextSelection selection,
  MarkdownStyle style,
) {
  if (!selection.isValid) return false;
  final range = _trimmed(analysis.text, selection.start, selection.end);
  for (final span in analysis.spans) {
    if (span.start > range.end) break;
    if (span.style != style) continue;
    if (selection.isCollapsed) {
      if (span.start < selection.start && selection.start < span.end) {
        return true;
      }
    } else if (span.start <= range.start && range.end <= span.end) {
      return true;
    }
  }
  return false;
}

final _wordCharacter = RegExp(r"[\p{L}\p{N}_'’]", unicode: true);

bool _isWordAt(String text, int index) =>
    index >= 0 &&
    index < text.length &&
    !_isSurrogate(text.codeUnitAt(index)) &&
    _wordCharacter.hasMatch(text[index]);

bool _isSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDFFF;

TextRange _trimmed(String text, int start, int end) {
  var from = start;
  var to = end;
  while (from < to && text[from].trim().isEmpty) {
    from++;
  }
  while (to > from && text[to - 1].trim().isEmpty) {
    to--;
  }
  return TextRange(start: from, end: to);
}

/// Widens a range that starts or ends inside a word to the whole word.
///
/// Markdown will not open emphasis in the middle of a word — this editor
/// holds `*` to the rule `_` has always had — so `fo**o**bar` would show its
/// asterisks rather than a bold letter. Taking in the word gives the writer
/// something that works.
TextRange _toWordEdges(String text, TextRange range) {
  var from = range.start;
  var to = range.end;
  while (from > 0 && _isWordAt(text, from - 1) && _isWordAt(text, from)) {
    from--;
  }
  while (to < text.length && _isWordAt(text, to) && _isWordAt(text, to - 1)) {
    to++;
  }
  return TextRange(start: from, end: to);
}

/// Bold or italic, written as markdown.
///
/// A selection is wrapped, trimmed of the spaces markdown will not emphasise
/// across and widened to whole words; each line of a selection is wrapped on
/// its own, since emphasis cannot cross a paragraph, and a stretch that runs
/// into bold already there joins it rather than nesting markers inside
/// markers. A selection inside bold already has the markers come off — all
/// of them, the way the button reads the whole run as bold.
///
/// With nothing selected it behaves as a word processor's button does. In
/// the middle of bold text it takes the bold off; at either end of it, it
/// steps the caret out so the next words are plain, and just outside it,
/// steps the caret in; in the middle of a plain word it bolds the word;
/// anywhere else the style is [MarkdownEdit.pending], for whatever is typed
/// next.
MarkdownEdit toggleMarkdownEmphasis(
  TextEditingValue value,
  MarkdownAnalysis analysis, {
  required bool strong,
}) {
  final text = value.text;
  final selection = value.selection;
  if (!selection.isValid || analysis.text != text) {
    return MarkdownEdit._unchanged(value);
  }
  final style = strong ? MarkdownStyle.strong : MarkdownStyle.emphasis;
  final marker = strong ? '**' : '*';
  final length = marker.length;
  final styled = [
    for (final span in analysis.spans)
      if (span.style == style) span,
  ];

  /// The innermost run of this style holding all of `[start, end)`.
  MarkdownSpan? enclosing(int start, int end) {
    MarkdownSpan? found;
    for (final span in styled) {
      if (span.start > start) break;
      if (end <= span.end) found = span;
    }
    return found;
  }

  List<_Edit> unwrap(MarkdownSpan span) => [
    _Edit(span.start, span.start + length, ''),
    _Edit(span.end - length, span.end, ''),
  ];

  if (selection.isCollapsed) {
    final caret = selection.start;
    // Strictly inside: a caret just past the closing markers is after the
    // bold, not in it.
    MarkdownSpan? inside;
    for (final span in styled) {
      if (span.start >= caret) break;
      if (caret < span.end) inside = span;
    }
    if (inside != null) {
      final wordsStart = inside.start + length;
      final wordsEnd = inside.end - length;
      // At the end of a bold word the key means "no more bold", the way it
      // does in any word processor: the caret steps out past the markers
      // and what is typed next is plain. Likewise at the start.
      if (caret >= wordsEnd) return MarkdownEdit._moving(value, inside.end);
      if (caret <= wordsStart) return MarkdownEdit._moving(value, inside.start);
      return _applyEdits(value, unwrap(inside));
    }
    // Right against bold from outside it, switching bold on joins it: the
    // caret steps in past the markers, and what is typed next is part of it
    // rather than a second bold beside the first.
    for (final span in styled) {
      if (span.start > caret) break;
      if (span.end == caret) return MarkdownEdit._moving(value, caret - length);
      if (span.start == caret) {
        return MarkdownEdit._moving(value, caret + length);
      }
    }
    if (_isWordAt(text, caret - 1) && _isWordAt(text, caret)) {
      final word = _toWordEdges(text, TextRange(start: caret, end: caret));
      final rewrite = _Rewrite(text, [
        _Edit(word.start, word.start, marker),
        _Edit(word.end, word.end, marker),
      ]);
      return MarkdownEdit._(
        TextEditingValue(
          text: rewrite.text,
          selection: TextSelection.collapsed(offset: rewrite.map(caret)),
        ),
        rewrite,
      );
    }
    // No word to wrap: the style waits for the next one typed here. Writing
    // an empty `****` now would put four asterisks on the page until then.
    return MarkdownEdit._pending(value);
  }

  // One stretch per selected line, after that line's structure.
  final segments = <TextRange>[];
  for (final start in _selectedLineStarts(text, selection)) {
    final line = markdownLinePrefix(text, start);
    if (_holdsAttachment(line)) continue;
    final from = selection.start > line.headingEnd
        ? selection.start
        : line.headingEnd;
    final to = selection.end < line.lineEnd ? selection.end : line.lineEnd;
    if (to <= from) continue;
    final trimmed = _trimmed(text, from, to);
    if (!trimmed.isCollapsed) segments.add(_toWordEdges(text, trimmed));
  }
  if (segments.isEmpty) return MarkdownEdit._unchanged(value);

  final enclosed = [
    for (final segment in segments) enclosing(segment.start, segment.end),
  ];
  if (enclosed.every((span) => span != null)) {
    final spans = {...enclosed.whereType<MarkdownSpan>()};
    return _applyEdits(value, [for (final span in spans) ...unwrap(span)]);
  }

  // Each stretch, grown to take in any run of this style it touches, so the
  // old markers can come out and one pair can go round the lot. Stretches
  // that end up touching — a run that crossed a line — become one.
  final groups = <({int start, int end, List<MarkdownSpan> spans})>[];
  for (final segment in segments) {
    var from = segment.start;
    var to = segment.end;
    final touched = <MarkdownSpan>[];
    for (final span in styled) {
      if (span.start < to && span.end > from) touched.add(span);
    }
    for (final span in touched) {
      if (span.start < from) from = span.start;
      if (span.end > to) to = span.end;
    }
    if (groups.isNotEmpty && groups.last.end >= from) {
      final last = groups.removeLast();
      groups.add((
        start: last.start < from ? last.start : from,
        end: last.end > to ? last.end : to,
        spans: {...last.spans, ...touched}.toList(),
      ));
    } else {
      groups.add((start: from, end: to, spans: touched));
    }
  }

  final edits = <_Edit>[];
  final opensAt = <int, bool>{};
  final closesAt = <int, bool>{};
  for (final group in groups) {
    // A run already starting where the group starts keeps its opening
    // markers as the group's; likewise at the end. Every other marker of a
    // run inside the group comes out.
    final keepsOpen = group.spans.any((span) => span.start == group.start);
    final keepsClose = group.spans.any((span) => span.end == group.end);
    for (final span in group.spans) {
      if (span.start != group.start) {
        edits.add(_Edit(span.start, span.start + length, ''));
      }
      if (span.end != group.end) {
        edits.add(_Edit(span.end - length, span.end, ''));
      }
    }
    if (!keepsOpen) edits.add(_Edit(group.start, group.start, marker));
    if (!keepsClose) edits.add(_Edit(group.end, group.end, marker));
    opensAt[group.start] = keepsOpen;
    closesAt[group.end] = keepsClose;
  }

  // The words stay selected, inside their markers, so a second press finds
  // them in the style and takes it off again.
  final rewrite = _Rewrite(text, edits);
  final first = groups.first.start;
  final last = groups.last.end;
  return MarkdownEdit._(
    TextEditingValue(
      text: rewrite.text,
      selection: TextSelection(
        baseOffset: opensAt[first]!
            ? rewrite.map(first + length)
            : rewrite.map(first),
        extentOffset: closesAt[last]!
            ? rewrite.map(last - length, before: true)
            : rewrite.map(last, before: true),
      ),
    ),
    rewrite,
  );
}

/// Ticks or unticks the task whose `[` is at [box].
TextEditingValue toggleMarkdownTask(TextEditingValue value, int box) {
  final text = value.text;
  if (box < 0 || box + 3 > text.length || text[box] != '[') return value;
  final mark = text[box + 1];
  if (mark != ' ' && mark != 'x' && mark != 'X') return value;
  final after = box + 3 < text.length && text[box + 3] == ' '
      ? box + 4
      : box + 3;
  return value.copyWith(
    text: text.replaceRange(box + 1, box + 2, mark == ' ' ? 'x' : ' '),
    selection: TextSelection.collapsed(offset: after),
    composing: TextRange.empty,
  );
}

/// The first selected line that is a list item, if any.
MarkdownLinePrefix? _firstSelectedItem(TextEditingValue value) {
  if (!value.selection.isValid) return null;
  for (final line in _selectedLines(value.text, value.selection)) {
    if (line.isListItem && !line.isQuoted) return line;
  }
  return null;
}

/// True when any selected line is a list item, which is when the nesting
/// controls are worth showing.
bool markdownSelectionHasListLine(TextEditingValue value) =>
    _firstSelectedItem(value) != null;

/// True when the first selected item is one of the app's own bullets or
/// boxes, which nest the app's own way — a unit of indent, and a bullet
/// drawn for the new depth — rather than by markdown's columns.
bool markdownSelectionStartsWithGlyphItem(TextEditingValue value) =>
    _firstSelectedItem(value)?.glyph ?? false;

/// Where Tab or Shift+Tab would move the first selected item, as a change in
/// its indentation, or 0 when it cannot move.
///
/// In markdown an item is nested by indenting it to where the words of the
/// item above begin — two columns under `- `, three under `1. ` — and only
/// under an item at its own level: indentation with nothing to nest under
/// changes nothing a reader would see. Stepping out puts it back where its
/// parent sits.
int _indentShift(TextEditingValue value, {required bool outdent}) {
  final first = _firstSelectedItem(value);
  if (first == null) return 0;
  final text = value.text;
  if (outdent) {
    if (first.markerColumn == 0) return 0;
    final parent = _parentItem(text, first);
    return (parent?.markerColumn ?? 0) - first.markerColumn;
  }
  final sibling = _previousSibling(text, first);
  if (sibling == null) return 0;
  if (_depthOf(text, first) >= maxListIndentDepth) return 0;
  return sibling.contentColumn - first.markerColumn;
}

/// True when [indentMarkdownSelection] would move something.
bool canIndentMarkdownSelection(
  TextEditingValue value, {
  required bool outdent,
}) => _indentShift(value, outdent: outdent) != 0;

/// Nests, or un-nests, the selected items.
///
/// Every selected item moves by the same amount as the first, so a run of
/// items moves as a block and keeps its own nesting inside it.
MarkdownEdit indentMarkdownSelection(
  TextEditingValue value, {
  required bool outdent,
}) {
  final shift = _indentShift(value, outdent: outdent);
  if (shift == 0) return MarkdownEdit._unchanged(value);
  final edits = <_Edit>[];
  for (final line in _selectedLines(value.text, value.selection)) {
    if (!line.isListItem || line.isQuoted) continue;
    if (shift > 0) {
      edits.add(_Edit(line.lineStart, line.lineStart, ' ' * shift));
    } else {
      final removable = (line.indentEnd - line.lineStart).clamp(0, -shift);
      if (removable > 0) {
        edits.add(_Edit(line.lineStart, line.lineStart + removable, ''));
      }
    }
  }
  return _applyEdits(value, edits);
}

/// What the editor remembers between keystrokes about markdown being typed.
///
/// Two things, both there so that bold can be typed the way it is in any word
/// processor rather than by writing asterisks:
///
/// * a style switched on with nothing selected, for the next word typed where
///   the caret is — see [MarkdownEdit.pending];
/// * a space typed at the end of bold text, which went outside the closing
///   markers (markdown does not end bold on a space) and comes back in if a
///   word follows it.
///
/// Anything else the writer does — moving the caret, typing somewhere else —
/// clears both.
class MarkdownTyping {
  bool pendingStrong = false;
  bool pendingEmphasis = false;
  int pendingAt = -1;

  int? _heldStart;
  int? _heldEnd;
  int? _heldCaret;

  bool get hasPending => pendingAt >= 0 && (pendingStrong || pendingEmphasis);

  /// Switches [strong] or emphasis on for the next word typed at [caret], or
  /// off again if it already was.
  void togglePending({required bool strong, required int caret}) {
    if (pendingAt != caret) {
      pendingStrong = false;
      pendingEmphasis = false;
    }
    pendingAt = caret;
    if (strong) {
      pendingStrong = !pendingStrong;
    } else {
      pendingEmphasis = !pendingEmphasis;
    }
    if (!hasPending) pendingAt = -1;
  }

  /// Whether [strong] or emphasis is waiting for a word at [caret].
  bool isPending({required bool strong, required int caret}) =>
      pendingAt == caret && (strong ? pendingStrong : pendingEmphasis);

  /// Whether [strong] or emphasis goes on past a space just typed at the end
  /// of it, to take in the next word typed at [caret] in [text].
  bool isHeld({
    required bool strong,
    required int caret,
    required String text,
  }) {
    final start = _heldStart;
    final end = _heldEnd;
    if (start == null || end == null || _heldCaret != caret) return false;
    if (end > text.length || start > end) return false;
    final markers = text.substring(start, end);
    // `***` closes both; `**` and `__` close strong; an odd count of
    // single markers closes emphasis.
    if (strong) return markers.contains('**') || markers.contains('__');
    return '*'.allMatches(markers).length.isOdd ||
        '_'.allMatches(markers).length.isOdd;
  }

  /// Switches [strong] or emphasis off for the word a held space is waiting
  /// for. Whichever of the two was held as well stays on, as pending.
  void releaseHeld({required bool strong, required String text}) {
    final caret = _heldCaret;
    if (caret == null) return;
    final keepStrong =
        !strong && isHeld(strong: true, caret: caret, text: text);
    final keepEmphasis =
        strong && isHeld(strong: false, caret: caret, text: text);
    clear();
    if (keepStrong || keepEmphasis) {
      pendingStrong = keepStrong;
      pendingEmphasis = keepEmphasis;
      pendingAt = caret;
    }
  }

  void clear() {
    pendingStrong = false;
    pendingEmphasis = false;
    pendingAt = -1;
    _heldStart = null;
    _heldEnd = null;
    _heldCaret = null;
  }
}

bool _isWhitespace(String text) =>
    text.isNotEmpty && text.trim().isEmpty && !text.contains('\n');

/// Where the closing markers that end at-or-after [caret] finish, if the
/// caret is where some bold, italic or struck text's words end — or [caret]
/// itself if it is not. `***both***` has two sets there, and both count.
int _closingMarkersEnd(MarkdownAnalysis analysis, int caret) {
  var end = caret;
  var grew = true;
  while (grew) {
    grew = false;
    for (final span in analysis.spans) {
      if (span.start >= end) break;
      final width = switch (span.style) {
        MarkdownStyle.strong || MarkdownStyle.strikethrough => 2,
        MarkdownStyle.emphasis => 1,
        _ => 0,
      };
      if (width > 0 && span.end > end && span.end - width == end) {
        end = span.end;
        grew = true;
      }
    }
  }
  return end;
}

/// What a keystroke becomes in a markdown note, where the note's own
/// markdown would otherwise get in the way of typing naturally. Null leaves
/// the keystroke as it was.
///
/// * A word typed where a style is pending is wrapped in its markers.
/// * A space or a Return at the end of bold, italic or struck text goes after
///   the closing markers: markdown cannot end emphasis on a space, and would
///   otherwise show the asterisks of `**bold **` until the next letter. A
///   word typed straight after the space takes the markers back past it.
/// * Deleting the last of a styled word or a link's words deletes its
///   markers with it, rather than leaving `****` or `[](…)` behind.
TextEditingValue? markdownTypingEdit(
  TextEditingValue oldValue,
  TextEditingValue newValue,
  MarkdownAnalysis analysis,
  MarkdownTyping typing,
) {
  final selection = oldValue.selection;
  final old = oldValue.text;
  final text = newValue.text;
  if (!selection.isValid || analysis.text != old) {
    typing.clear();
    return null;
  }
  // An IME composing a word owns the text until it commits.
  if (newValue.composing.isValid && !newValue.composing.isCollapsed) {
    return null;
  }

  if (selection.isCollapsed && text.length > old.length) {
    final caret = selection.start;
    final inserted = text.substring(caret, caret + text.length - old.length);
    if (text == old.replaceRange(caret, caret, inserted)) {
      final wrapped = _typedAtCaret(old, caret, inserted, analysis, typing);
      if (wrapped != null) return wrapped;
      typing.clear();
      return null;
    }
  }

  if (text.length < old.length) {
    // One stretch removed: [from, to) of the old text.
    var from = 0;
    while (from < text.length &&
        old.codeUnitAt(from) == text.codeUnitAt(from)) {
      from++;
    }
    final to = from + old.length - text.length;
    if (text == old.replaceRange(from, to, '')) {
      for (final conceal in analysis.conceals) {
        if (conceal.reveal != MarkdownReveal.edges) continue;
        // All of an element's words, or the one character an escape's
        // backslash was there for.
        if (conceal.innerStart == from &&
            conceal.innerEnd == to &&
            conceal.scopeStart < from &&
            conceal.scopeEnd >= to) {
          typing.clear();
          return TextEditingValue(
            text: old.replaceRange(conceal.scopeStart, conceal.scopeEnd, ''),
            selection: TextSelection.collapsed(offset: conceal.scopeStart),
          );
        }
      }
    }
  }
  typing.clear();
  return null;
}

TextEditingValue? _typedAtCaret(
  String old,
  int caret,
  String inserted,
  MarkdownAnalysis analysis,
  MarkdownTyping typing,
) {
  final heldStart = typing._heldStart;
  final heldEnd = typing._heldEnd;
  if (heldStart != null &&
      heldEnd != null &&
      typing._heldCaret == caret &&
      inserted.trim().isNotEmpty &&
      inserted == inserted.trimLeft() &&
      heldEnd <= caret &&
      RegExp(r'^[*_~]+$').hasMatch(old.substring(heldStart, heldEnd))) {
    // The word after the held space: the markers move back past both.
    final markers = old.substring(heldStart, heldEnd);
    final space = old.substring(heldEnd, caret);
    typing.clear();
    final landing = heldStart + space.length + inserted.length;
    return TextEditingValue(
      text: old.replaceRange(heldStart, caret, '$space$inserted$markers'),
      selection: TextSelection.collapsed(offset: landing),
    );
  }

  if (typing.hasPending && typing.pendingAt == caret) {
    if (inserted.trim().isEmpty && !inserted.contains('\n')) {
      // Spaces before the word: the style waits on past them.
      typing.pendingAt = caret + inserted.length;
      return TextEditingValue(
        text: old.replaceRange(caret, caret, inserted),
        selection: TextSelection.collapsed(offset: caret + inserted.length),
      );
    }
    final open =
        '${typing.pendingStrong ? '**' : ''}${typing.pendingEmphasis ? '*' : ''}';
    final close =
        '${typing.pendingEmphasis ? '*' : ''}${typing.pendingStrong ? '**' : ''}';
    final word = inserted.trimRight();
    final after = inserted.substring(word.length);
    final wordEnd = caret + open.length + word.length;
    typing.clear();
    if (after.isEmpty) {
      return TextEditingValue(
        text: old.replaceRange(caret, caret, '$open$word$close'),
        selection: TextSelection.collapsed(offset: wordEnd),
      );
    }
    final landing = wordEnd + close.length + after.length;
    typing
      .._heldStart = wordEnd
      .._heldEnd = wordEnd + close.length
      .._heldCaret = landing;
    return TextEditingValue(
      text: old.replaceRange(caret, caret, '$open$word$close$after'),
      selection: TextSelection.collapsed(offset: landing),
    );
  }

  final markersEnd = _closingMarkersEnd(analysis, caret);
  if (markersEnd > caret && (inserted == '\n' || _isWhitespace(inserted))) {
    typing.clear();
    if (inserted == '\n') {
      // Out of the bold, then on as Return goes anywhere — continuing a
      // list, if this is one.
      final atEnd = TextEditingValue(
        text: old,
        selection: TextSelection.collapsed(offset: markersEnd),
      );
      final broken = TextEditingValue(
        text: old.replaceRange(markersEnd, markersEnd, '\n'),
        selection: TextSelection.collapsed(offset: markersEnd + 1),
      );
      return continueMarkdownLine(atEnd, broken) ?? broken;
    }
    final landing = markersEnd + inserted.length;
    typing
      .._heldStart = caret
      .._heldEnd = markersEnd
      .._heldCaret = landing;
    return TextEditingValue(
      text: old.replaceRange(markersEnd, markersEnd, inserted),
      selection: TextSelection.collapsed(offset: landing),
    );
  }
  return null;
}

/// What a keystroke does at the hidden structure starting a line, which the
/// writer cannot see and so should never find themselves editing a character
/// of. Null leaves the keystroke as it was.
///
/// * Backspace at the start of a heading's, an item's or a quote's words
///   takes the formatting off — the heading becomes text, the item stops
///   being one, the quote loses a level — as it does in any block editor,
///   rather than deleting the hidden space and leaving a stray `#`.
/// * Delete at the end of a line joins the next line's words to it, without
///   the next line's hidden structure.
/// * Return at the start of a heading's words opens a line above it, rather
///   than splitting the heading from its own words.
/// * `[] ` or `[ ] ` typed at the start of a line makes a task, as it always
///   has in this app.
TextEditingValue? markdownStructureEdit(
  TextEditingValue oldValue,
  TextEditingValue newValue,
  MarkdownAnalysis analysis,
) {
  final selection = oldValue.selection;
  if (!selection.isValid || !selection.isCollapsed) return null;
  final old = oldValue.text;
  final text = newValue.text;
  if (analysis.text != old) return null;
  final caret = selection.start;

  // Backspace at the start of the words.
  if (caret > 0 && text == old.replaceRange(caret - 1, caret, '')) {
    final prefix = analysis.atomicPrefixAt(caret);
    if (prefix != null && prefix.end == caret && prefix.start < caret) {
      final line = markdownLinePrefix(old, caret);
      final int from;
      final int to;
      if (line.headingLevel > 0 && line.headingEnd == caret) {
        from = line.contentStart;
        to = line.headingEnd;
      } else if (line.isListItem) {
        from = line.markerStart;
        to = line.contentStart;
      } else if (line.isQuoted) {
        from = old.lastIndexOf('>', line.quoteEnd - 1);
        to = line.quoteEnd;
      } else {
        return null;
      }
      if (to <= from) return null;
      return TextEditingValue(
        text: old.replaceRange(from, to, ''),
        selection: TextSelection.collapsed(offset: from),
      );
    }
  }

  // Delete at the end of a line.
  if (caret < old.length &&
      old.codeUnitAt(caret) == 0x0A &&
      text == old.replaceRange(caret, caret + 1, '')) {
    final prefix = analysis.atomicPrefixAt(caret + 1);
    if (prefix != null && prefix.start == caret + 1) {
      return TextEditingValue(
        text: old.replaceRange(caret, prefix.end, ''),
        selection: TextSelection.collapsed(offset: caret),
      );
    }
  }

  // Return at the start of a heading's words.
  if (text == old.replaceRange(caret, caret, '\n')) {
    final prefix = analysis.atomicPrefixAt(caret);
    final line = markdownLinePrefix(old, caret);
    if (prefix != null &&
        prefix.end == caret &&
        line.headingLevel > 0 &&
        line.headingEnd == caret &&
        old.substring(caret, line.lineEnd).trim().isNotEmpty) {
      return TextEditingValue(
        text: old.replaceRange(prefix.start, prefix.start, '\n'),
        selection: TextSelection.collapsed(offset: caret + 1),
      );
    }
  }

  // `[] ` and `[ ] ` at the start of a line.
  if (text == old.replaceRange(caret, caret, ' ')) {
    final line = markdownLinePrefix(old, caret);
    if (!line.isListItem) {
      final typed = old.substring(line.contentStart, caret);
      if (typed == '[]' || typed == '[ ]') {
        const task = '- [ ] ';
        return TextEditingValue(
          text: old.replaceRange(line.contentStart, caret, task),
          selection: TextSelection.collapsed(
            offset: line.contentStart + task.length,
          ),
        );
      }
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Tables
//
// Every operation here rewrites the pipes themselves, because the note is its
// text and a table is lines of it. Offsets come from [MarkdownTable], where a
// row runs from the start of its line to the end of it, and a cell covers only
// its trimmed words — never the spaces padding it out. The delimiter row is not
// one of [MarkdownTable.rows]; it is addressed on its own.
// ---------------------------------------------------------------------------

/// How many columns a table has.
///
/// Read from the widest row as well as the delimiter, which agree in a table
/// this app wrote and need not in one somebody typed by hand.
int markdownTableColumnCount(MarkdownTable table) {
  var count = table.aligns.length;
  for (final row in table.rows) {
    if (row.cells.length > count) count = row.cells.length;
  }
  return count;
}

/// The table [offset] is in, if it is in one.
MarkdownTable? markdownTableAt(MarkdownAnalysis analysis, int offset) {
  for (final table in analysis.tables) {
    if (offset >= table.start && offset <= table.end) return table;
  }
  return null;
}

/// Which cell [offset] is in, as a row and a column index.
///
/// Indexes rather than offsets, because a row with fewer fields than the table
/// has columns is reported as several empty cells at the very same offset: a
/// position cannot tell those apart and an index can. An offset on a divider or
/// in a cell's padding belongs to the nearest cell to its left, so that a tap
/// anywhere on the grid edits something. Returns null on the delimiter row,
/// which has no cell to edit.
({int row, int column})? markdownTableCellAt(MarkdownTable table, int offset) {
  for (var r = 0; r < table.rows.length; r++) {
    final row = table.rows[r];
    if (offset < row.start || offset > row.end) continue;
    for (var c = 0; c < row.cells.length; c++) {
      final cell = row.cells[c];
      if (offset >= cell.start && offset <= cell.end) {
        return (row: r, column: c);
      }
    }
    var column = 0;
    for (var c = 0; c < row.cells.length; c++) {
      if (row.cells[c].start <= offset) column = c;
    }
    return (row: r, column: column);
  }
  return null;
}

/// The cell Tab moves to, or null past the last one — where the caller adds a
/// row rather than leaving the table.
({int row, int column})? nextMarkdownTableCell(
  MarkdownTable table, {
  required int row,
  required int column,
  bool backwards = false,
}) {
  final columns = markdownTableColumnCount(table);
  if (columns <= 0) return null;
  var r = row;
  var c = column + (backwards ? -1 : 1);
  if (c < 0) {
    r -= 1;
    c = columns - 1;
  } else if (c >= columns) {
    r += 1;
    c = 0;
  }
  if (r < 0 || r >= table.rows.length) return null;
  return (row: r, column: c);
}

/// Replaces one cell's words.
///
/// A row that already has this column keeps every other character it has: the
/// narrowest edit is the kindest to a shared note and to anyone else's caret.
/// A short row is written out in full instead, since its missing cells all sit
/// at one offset and an edit there would be guesswork.
MarkdownEdit setMarkdownTableCell(
  TextEditingValue value,
  MarkdownTable table, {
  required int row,
  required int column,
  required String text,
}) {
  if (row < 0 || row >= table.rows.length) {
    return MarkdownEdit._unchanged(value);
  }
  final columns = markdownTableColumnCount(table);
  if (column < 0 || column >= columns) return MarkdownEdit._unchanged(value);
  final source = value.text;
  final line = table.rows[row];
  final words = _cellWords(text);
  final fields = _rowFields(source.substring(line.start, line.end));
  if (fields.length == columns) {
    final cell = line.cells[column];
    if (source.substring(cell.start, cell.end) == words) {
      return MarkdownEdit._unchanged(value);
    }
    return _applyEdits(value, [_Edit(cell.start, cell.end, words)]);
  }
  final padded = _paddedFields(source, line, columns);
  padded[column] = words;
  return _applyEdits(value, [_Edit(line.start, line.end, _rowSource(padded))]);
}

/// Adds an empty row under row [after], or under the last one past the end.
MarkdownEdit insertMarkdownTableRow(
  TextEditingValue value,
  MarkdownTable table, {
  required int after,
}) {
  final columns = markdownTableColumnCount(table);
  if (columns <= 0 || table.rows.isEmpty) {
    return MarkdownEdit._unchanged(value);
  }
  final index = after < 0 || after >= table.rows.length
      ? table.rows.length - 1
      : after;
  final at = _tableRowEnd(table, index);
  return _applyEdits(value, [
    _Edit(at, at, '\n${_rowSource(List.filled(columns, ''))}'),
  ]);
}

/// Adds an empty row at the bottom, which is what Tab past the last cell does.
MarkdownEdit appendMarkdownTableRow(
  TextEditingValue value,
  MarkdownTable table,
) => insertMarkdownTableRow(value, table, after: table.rows.length - 1);

/// Takes a body row out. The header stays: without one it is not a table.
MarkdownEdit removeMarkdownTableRow(
  TextEditingValue value,
  MarkdownTable table, {
  required int row,
}) {
  if (row <= 0 || row >= table.rows.length) {
    return MarkdownEdit._unchanged(value);
  }
  final line = table.rows[row];
  // The newline in front of it goes as well, or the table keeps a blank line
  // where the row was and stops being one table.
  final from = line.start > 0 ? line.start - 1 : line.start;
  return _applyEdits(value, [_Edit(from, line.end, '')]);
}

/// Adds an empty column after column [after], or at the front past the start.
MarkdownEdit insertMarkdownTableColumn(
  TextEditingValue value,
  MarkdownTable table, {
  required int after,
}) => _rewriteTableColumns(
  value,
  table,
  insertAt: (after + 1).clamp(0, markdownTableColumnCount(table)),
);

/// Takes a column out. The last one stays.
MarkdownEdit removeMarkdownTableColumn(
  TextEditingValue value,
  MarkdownTable table, {
  required int column,
}) {
  final columns = markdownTableColumnCount(table);
  if (columns <= 1 || column < 0 || column >= columns) {
    return MarkdownEdit._unchanged(value);
  }
  return _rewriteTableColumns(value, table, removeAt: column);
}

/// Sets one column's alignment, which is written in the delimiter row.
MarkdownEdit setMarkdownTableColumnAlign(
  TextEditingValue value,
  MarkdownTable table, {
  required int column,
  required MarkdownCellAlign align,
}) {
  final columns = markdownTableColumnCount(table);
  if (column < 0 || column >= columns) return MarkdownEdit._unchanged(value);
  final aligns = _paddedAligns(table, columns);
  if (aligns[column] == align) return MarkdownEdit._unchanged(value);
  aligns[column] = align;
  return _applyEdits(value, [
    _Edit(table.delimiterStart, table.delimiterEnd, _delimiterSource(aligns)),
  ]);
}

/// Every row and the delimiter written out again, as one edit: a column belongs
/// to all of them at once, and half a table is not one.
MarkdownEdit _rewriteTableColumns(
  TextEditingValue value,
  MarkdownTable table, {
  int? insertAt,
  int? removeAt,
}) {
  final columns = markdownTableColumnCount(table);
  if (columns <= 0) return MarkdownEdit._unchanged(value);
  final source = value.text;
  final edits = <_Edit>[];
  for (final row in table.rows) {
    final fields = _paddedFields(source, row, columns);
    if (insertAt != null) fields.insert(insertAt, '');
    if (removeAt != null) fields.removeAt(removeAt);
    edits.add(_Edit(row.start, row.end, _rowSource(fields)));
  }
  final aligns = _paddedAligns(table, columns);
  if (insertAt != null) aligns.insert(insertAt, MarkdownCellAlign.start);
  if (removeAt != null) aligns.removeAt(removeAt);
  edits.add(
    _Edit(table.delimiterStart, table.delimiterEnd, _delimiterSource(aligns)),
  );
  return _applyEdits(value, edits);
}

/// Where a row ends for the purpose of putting another one after it. The header
/// owns the delimiter under it, so a row added "after the header" goes below
/// that and not between the two.
int _tableRowEnd(MarkdownTable table, int index) {
  final row = table.rows[index];
  return row.header ? table.delimiterEnd : row.end;
}

/// The fields of one row's source, split on its unescaped pipes.
///
/// The outer pipes are the fence around the row rather than separators, and a
/// `\|` is a pipe in the words and never a divider.
List<String> _rowFields(String source) {
  var from = 0;
  var to = source.length;
  while (from < to && _isSpace(source.codeUnitAt(from))) {
    from++;
  }
  while (to > from && _isSpace(source.codeUnitAt(to - 1))) {
    to--;
  }
  if (from < to && source.codeUnitAt(from) == 0x7C) from++;
  if (to > from && source.codeUnitAt(to - 1) == 0x7C) to--;

  final fields = <String>[];
  final field = StringBuffer();
  var escaped = false;
  for (var i = from; i < to; i++) {
    final unit = source.codeUnitAt(i);
    if (escaped) {
      field.writeCharCode(unit);
      escaped = false;
      continue;
    }
    if (unit == 0x5C) {
      field.writeCharCode(unit);
      escaped = true;
      continue;
    }
    if (unit == 0x7C) {
      fields.add(field.toString().trim());
      field.clear();
      continue;
    }
    field.writeCharCode(unit);
  }
  fields.add(field.toString().trim());
  return fields;
}

/// [row]'s fields padded out to [columns], so a short row gains the empty cells
/// it was missing and a long one is cut to fit.
List<String> _paddedFields(String text, MarkdownTableRow row, int columns) {
  final fields = _rowFields(text.substring(row.start, row.end));
  if (fields.length >= columns) return fields.sublist(0, columns);
  return [...fields, for (var i = fields.length; i < columns; i++) ''];
}

List<MarkdownCellAlign> _paddedAligns(MarkdownTable table, int columns) => [
  for (var c = 0; c < columns; c++)
    table.aligns.elementAtOrNull(c) ?? MarkdownCellAlign.start,
];

/// One row written out, in the shape [markdownTableTemplate] writes.
String _rowSource(List<String> cells) => '| ${cells.join(' | ')} |';

String _delimiterSource(List<MarkdownCellAlign> aligns) =>
    '| ${aligns.map(_alignSource).join(' | ')} |';

/// Left is written as the bare `---`, the way a table is written by hand and by
/// [markdownTableTemplate]: it is the default, and `:---` says nothing more.
String _alignSource(MarkdownCellAlign align) => switch (align) {
  MarkdownCellAlign.start => '---',
  MarkdownCellAlign.center => ':---:',
  MarkdownCellAlign.end => '---:',
};

/// Words as they can live inside a cell: no line breaks, and a pipe escaped so
/// it stays in the words instead of becoming another divider.
///
/// Deliberately not trimmed. This runs on every keystroke of a cell being
/// edited, and dropping a trailing space would stop a second word being typed.
String _cellWords(String text) => text
    .replaceAll('\r\n', ' ')
    .replaceAll('\n', ' ')
    .replaceAll(RegExp(r'(?<!\\)\|'), r'\|');
