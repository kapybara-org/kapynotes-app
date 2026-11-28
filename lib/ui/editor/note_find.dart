import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../compact_icon_button.dart';
import 'markdown_syntax.dart';
import 'table_geometry.dart';

/// Where [query] is in [text], whatever its case, as the note shows the
/// text: [hidden], what the note draws as nothing (markdown's markers, a
/// link's address), is passed over. So every match is words the reader can
/// see, and words a hidden marker splits still match. Sorted, and apart.
///
/// Lower case is as long as the text it comes from, a code unit for each,
/// so an offset into one is the same offset into the other.
List<TextRange> findInText(
  String text,
  String query, {
  List<TextRange> hidden = const [],
}) {
  if (query.isEmpty) return const [];
  // The text as shown, a stretch at a time, and where each stretch starts
  // in it and in [text].
  final shown = StringBuffer();
  final shownAt = <int>[];
  final textAt = <int>[];
  var at = 0;
  void keep(int end) {
    if (end <= at) return;
    shownAt.add(shown.length);
    textAt.add(at);
    shown.write(text.substring(at, end));
  }

  for (final range in [...hidden]..sort((a, b) => a.start.compareTo(b.start))) {
    keep(range.start.clamp(0, text.length));
    if (range.end > at) at = range.end.clamp(0, text.length);
  }
  keep(text.length);

  int inText(int offset) {
    var low = 0;
    var high = shownAt.length - 1;
    while (low < high) {
      final middle = (low + high + 1) >> 1;
      if (shownAt[middle] <= offset) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    return textAt[low] + offset - shownAt[low];
  }

  final haystack = shown.toString().toLowerCase();
  final needle = query.toLowerCase();
  return [
    for (
      var found = haystack.indexOf(needle);
      found >= 0;
      found = haystack.indexOf(needle, found + needle.length)
    )
      TextRange(
        start: inText(found),
        end: inText(found + needle.length - 1) + 1,
      ),
  ];
}

/// Where [query] is in the cells of [analysis]'s tables, whatever its case.
/// A table is drawn as a grid over its source, which the note hides and
/// [findInText] passes over, so each cell is searched on its own, in the
/// words its grid shows: a match never runs from one cell into the next, and
/// the grid's lines are not words. Each match maps back to the cell's source
/// as [TableGeometry.sourcesOf] maps a painted character. Sorted, and apart.
List<TextRange> findInTables(MarkdownAnalysis analysis, String query) {
  final needle = query.toLowerCase();
  if (needle.isEmpty) return const [];
  final found = <TextRange>[];
  for (final table in analysis.tables) {
    for (final row in table.rows) {
      for (final cell in row.cells) {
        final words = [
          for (final run in analysis.runsIn(cell.start, cell.end)) run.text,
        ].join();
        final haystack = words.toLowerCase();
        var at = haystack.indexOf(needle);
        if (at < 0) continue;
        final sources = TableGeometry.sourcesOf(analysis, cell, words);
        for (; at >= 0; at = haystack.indexOf(needle, at + needle.length)) {
          final start = cell.start + sources[at];
          final end = cell.start + sources[at + needle.length - 1] + 1;
          if (end > cell.end) continue;
          found.add(TextRange(start: start, end: end));
        }
      }
    }
  }
  return found;
}

/// A find in one note: the words its bar holds, where they are in the note
/// as it shows, and which of those the reader is on.
class NoteFind {
  final query = TextEditingController();
  final field = FocusNode(debugLabel: 'note-find');

  /// Sorted, and apart.
  List<TextRange> get matches => _matches;
  List<TextRange> _matches = const [];

  /// Which of [matches] the reader is on, or -1 while there are none.
  int get current => _current;
  int _current = -1;

  TextRange? get currentMatch => _current < 0 ? null : _matches[_current];

  String? _text;
  String? _words;
  List<TextRange> _hidden = const [];

  /// Finds the words in the note [analysis] reads again, where it or they or
  /// [hidden] changed, and answers whether it did: in its text as shown, and
  /// in its tables' cells. The reader stays on the match at or after the one
  /// they were on, or, on none, at or after [from].
  bool refresh(
    MarkdownAnalysis analysis,
    List<TextRange> hidden, {
    required int from,
  }) {
    final text = analysis.text;
    final words = query.text;
    if (text == _text && words == _words && listEquals(hidden, _hidden)) {
      return false;
    }
    final at = currentMatch?.start ?? from;
    _text = text;
    _words = words;
    _hidden = hidden;
    _matches = [
      ...findInText(text, words, hidden: hidden),
      ...findInTables(analysis, words),
    ]..sort((a, b) => a.start.compareTo(b.start));
    final next = _matches.indexWhere((match) => match.start >= at);
    _current = _matches.isEmpty ? -1 : (next < 0 ? 0 : next);
    return true;
  }

  /// On to the next match, or with [back] the one before, round from the
  /// last to the first.
  void step({bool back = false}) {
    if (_matches.isEmpty) return;
    _current = (_current + (back ? -1 : 1)) % _matches.length;
  }

  void dispose() {
    query.dispose();
    field.dispose();
  }
}

/// The bar that finds words in a note, one line across the top of the page
/// with a hairline under it: the words, which match the note is on out of
/// how many, and Previous, Next and Close. Enter goes to the next match and
/// Shift+Enter to the one before, and esc closes it.
class NoteFindBar extends StatelessWidget {
  const NoteFindBar({
    super.key,
    required this.find,
    required this.side,
    required this.onNext,
    required this.onPrevious,
    required this.onClose,
  });

  final NoteFind find;

  /// How far in from the page's edges the note's writing is, for the words
  /// to start in line with it and Close's cross to end in line with it.
  final double side;
  final VoidCallback onNext;
  final VoidCallback onPrevious;
  final VoidCallback onClose;

  /// Enter and esc, unless they belong to a word an input method is still
  /// putting together.
  KeyEventResult _key(FocusNode node, KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    if (event is KeyUpEvent ||
        find.query.value.composing.isValid ||
        keyboard.isControlPressed ||
        keyboard.isMetaPressed ||
        keyboard.isAltPressed) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter:
        keyboard.isShiftPressed ? onPrevious() : onNext();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape when event is KeyDownEvent:
        onClose();
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final style = TextStyle(
      color: palette.textPrimary,
      fontSize: AppTypeScale.small,
      fontWeight: AppWeight.font(AppWeight.regular),
      fontVariations: AppWeight.wght(AppWeight.regular),
    );
    final count = find.matches.length;
    Widget button(
      String key,
      String tooltip,
      KapyIconData icon,
      VoidCallback? onPressed,
    ) => CompactIconButton(
      key: ValueKey(key),
      tooltip: tooltip,
      onPressed: onPressed,
      icon: KapyIcon(
        icon,
        size: AppControlMetrics.iconAdornment,
        color: onPressed == null ? palette.textTertiary : null,
      ),
    );
    final inset =
        (AppControlMetrics.iconButtonExtent - AppControlMetrics.iconAdornment) /
        2;
    return TextFieldTapRegion(
      child: DecoratedBox(
        key: const ValueKey('note-find-bar'),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: palette.railBorder)),
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(side, 4, math.max(0, side - inset), 4),
          child: Row(
            children: [
              Expanded(
                child: Focus(
                  canRequestFocus: false,
                  skipTraversal: true,
                  onKeyEvent: _key,
                  child: TextField(
                    key: const ValueKey('note-find-field'),
                    controller: find.query,
                    focusNode: find.field,
                    style: style,
                    cursorHeight: 16,
                    decoration: InputDecoration(
                      hintText: 'Find in note',
                      hintStyle: style.copyWith(color: palette.textTertiary),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: false,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
              ),
              if (find.query.text.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      count == 0
                          ? 'No matches'
                          : '${find.current + 1} of $count',
                      key: const ValueKey('note-find-count'),
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(
                        fontSize: AppTypeScale.caption,
                        color: palette.textTertiary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
              button(
                'note-find-previous',
                'Previous match',
                KapyIcons.chevronUpRounded,
                count == 0 ? null : onPrevious,
              ),
              button(
                'note-find-next',
                'Next match',
                KapyIcons.chevronDownRounded,
                count == 0 ? null : onNext,
              ),
              button(
                'note-find-close',
                'Close',
                KapyIcons.closeRounded,
                onClose,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
