import 'package:flutter/services.dart' show TextSelection;

import '../data/note_format.dart';
import '../ui/editor/editor_formatting.dart'
    show bulletPrefixes, checkedPrefix, uncheckedPrefix;
import '../ui/editor/markdown_editing.dart'
    show MarkdownLinePrefix, markdownLinePrefix;
import 'markdown_text.dart' show cleanPastedText;
import 'paste_tree.dart';

/// What the note holds where a paste lands, as far as it changes what the
/// paste may write there.
enum PasteTarget {
  /// Ordinary writing.
  text,

  /// Inside a fenced code block: only the clipboard's own text, as is.
  code,

  /// A table row: only words, with line breaks as <br>.
  table,
}

/// A paste worked out against the note it lands in: the range of the note
/// it replaces, and what replaces it.
class PasteInsertion {
  const PasteInsertion({
    required this.start,
    required this.end,
    required this.text,
    this.formats = const [],
    this.images = const [],
  });

  final int start;
  final int end;
  final String text;

  /// Plain-format styles over [text], relative to [start].
  final List<NoteFormatRange> formats;

  /// Pictures, relative to [start].
  final List<PastedImage> images;
}

/// Fits [output] into [note] at [selection] the way Notion does, so that a
/// paste reads as if it had been written there.
///
/// The first pasted line joins the words before the caret and takes on its
/// line's kind — pasting a heading into a list item adds words to the item —
/// and the last pasted line joins the words after it. Lines pasted into a
/// list become more items of it, as Return would make them, and lines pasted
/// into a quote stay in the quote. A block that can't share a line (a
/// fence, a table row, a picture) gets a line of its own.
PasteInsertion planPaste({
  required String note,
  required TextSelection selection,
  required PasteOutput output,
  required bool markdown,
  PasteTarget target = PasteTarget.text,
  String? clipboardText,
}) {
  final start = selection.start.clamp(0, note.length);
  final end = selection.end.clamp(start, note.length);

  switch (target) {
    case PasteTarget.code:
      return PasteInsertion(
        start: start,
        end: end,
        text: cleanPastedText(clipboardText ?? _words(output.text)),
      );
    case PasteTarget.table:
      final words = cleanPastedText(clipboardText ?? _words(output.text))
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .join('<br>')
          .replaceAllMapped(
            RegExp(r'(\\)?\|'),
            (match) => match[1] == null ? r'\|' : match[0]!,
          );
      return PasteInsertion(start: start, end: end, text: words);
    case PasteTarget.text:
      break;
  }

  final address = (clipboardText ?? output.text).trim();
  if (markdown &&
      end > start &&
      _webAddress.hasMatch(address) &&
      !note.substring(start, end).contains('\n')) {
    return PasteInsertion(
      start: start,
      end: end,
      text:
          '[${note.substring(start, end)}](${address.replaceAll(' ', '%20')})',
    );
  }

  final line = markdown
      ? _MarkdownLine.at(note, start)
      : _PlainLine.at(note, start);
  final lineEnd = note.indexOf('\n', end) < 0
      ? note.length
      : note.indexOf('\n', end);
  final wordsBefore = note
      .substring(line.contentStart, start)
      .trim()
      .isNotEmpty;
  final wordsAfter = note.substring(end, lineEnd).trim().isNotEmpty;

  final pasted = output.text.split('\n');
  final out = StringBuffer();
  // For each pasted line: where it began in the output, where it begins in
  // what is written, and how much was cut from or added to its front.
  final moves = <({int from, int to, int cut, int added})>[];
  var replaceFrom = start;
  var inFence = false;
  var item = 0;
  var from = 0;

  for (var index = 0; index < pasted.length; index++) {
    final source = pasted[index];
    final lineFrom = from;
    from += source.length + 1;
    var cut = 0;
    var added = '';
    final fence = _fence.hasMatch(source);

    if (index == 0) {
      final standsAlone = _standsAlone(source, markdown: markdown);
      if (standsAlone) {
        if (wordsBefore) {
          added = '\n${line.continuation}';
        } else if (line.isItem && !wordsAfter) {
          // An empty item: the block replaces the marker rather than
          // hanging off it.
          replaceFrom = line.continuationEnd;
        }
      } else if (wordsBefore || line.hasStructure) {
        cut = line.structureOf(source);
      }
    } else if (inFence) {
      added = line.continuation;
    } else if (source.trim().isEmpty) {
      if (line.isItem) {
        moves.add((from: lineFrom, to: -1, cut: 0, added: 0));
        continue;
      }
      added = line.continuation.trimRight();
    } else if (_isPictureLine(source)) {
      added = '';
    } else if (line.isItem && line.structureOf(source) == 0 && !fence) {
      added = line.continuation + line.nextMarker(++item);
    } else {
      added = line.continuation;
    }
    if (fence) inFence = !inFence;

    if (index > 0) out.write('\n');
    final to = out.length + added.length;
    out
      ..write(added)
      ..write(source.substring(cut));
    moves.add((from: lineFrom, to: to, cut: cut, added: added.length));
  }
  final lastLine = pasted.last;
  if (wordsAfter && _standsAlone(lastLine, markdown: markdown)) out.write('\n');

  final text = out.toString();
  int? map(int offset) {
    for (var i = moves.length - 1; i >= 0; i--) {
      final move = moves[i];
      if (offset < move.from) continue;
      if (move.to < 0) return null;
      final into = offset - move.from;
      return move.to + (into < move.cut ? 0 : into - move.cut);
    }
    return null;
  }

  final shift = start - replaceFrom;
  final formats = <NoteFormatRange>[];
  for (final range in output.formats) {
    // The first line's own kind gives way to the line it joins.
    if (range.format.isParagraph &&
        range.start < pasted.first.length &&
        (wordsBefore || line.hasStructure)) {
      continue;
    }
    final a = map(range.start);
    final b = map(range.end);
    if (a == null || b == null || b <= a) continue;
    formats.add(
      NoteFormatRange(start: a + shift, end: b + shift, format: range.format),
    );
  }
  final images = <PastedImage>[];
  for (final image in output.images) {
    final at = map(image.offset);
    if (at != null) images.add(PastedImage(at + shift, image.image));
  }
  return PasteInsertion(
    start: replaceFrom,
    end: end,
    text: text,
    formats: formats,
    images: images,
  );
}

final _webAddress = RegExp(r'^(https?://|mailto:)\S+$');
final _fence = RegExp(r'^\s*(`{3,}|~{3,})');

String _words(String text) => text.replaceAll('￼', '');

bool _isPictureLine(String line) =>
    line.isNotEmpty && line.replaceAll('￼', '').isEmpty;

/// A line that can't share its line with other words: a fence, a table
/// row, a rule, display math, a picture.
bool _standsAlone(String line, {required bool markdown}) {
  if (_isPictureLine(line)) return true;
  final trimmed = line.trimLeft();
  if (trimmed.startsWith('|')) return true;
  if (!markdown) return false;
  return _fence.hasMatch(line) ||
      trimmed.startsWith(r'$$') ||
      RegExp(r'^([-*_])(\s*\1){2,}\s*$').hasMatch(trimmed);
}

/// The structure of the line a paste lands on.
abstract class _Line {
  /// Where the line's words begin, after its structure.
  int get contentStart;

  /// What a pasted line keeps in front of it to stay in this line's
  /// container: indentation and quote markers.
  String get continuation;

  /// Where [continuation] ends in the note.
  int get continuationEnd;

  bool get isItem;

  /// Whether the line is a list item, a quote or a heading — anything with a
  /// kind of its own for pasted words to take on.
  bool get hasStructure;

  /// The marker for the item [count] after this one.
  String nextMarker(int count);

  /// How much of a pasted [line] is its own structure, to cut when it joins
  /// this one.
  int structureOf(String line);
}

final _pastedMarkdownStructure = RegExp(
  r'^[ \t]*((>[ \t]?)+)?([-*+][ \t]+|\d{1,9}[.)][ \t]+)?(\[[ xX]\][ \t]+)?(#{1,6}[ \t]+)?',
);

class _MarkdownLine implements _Line {
  _MarkdownLine._(this._note, this._prefix);

  factory _MarkdownLine.at(String note, int offset) =>
      _MarkdownLine._(note, markdownLinePrefix(note, offset));

  final String _note;
  final MarkdownLinePrefix _prefix;

  @override
  int get contentStart => _prefix.headingEnd;

  @override
  bool get isItem => _prefix.isListItem;

  @override
  bool get hasStructure =>
      isItem || _prefix.isQuoted || _prefix.headingLevel > 0;

  @override
  int get continuationEnd => isItem ? _prefix.markerStart : _prefix.quoteEnd;

  @override
  String get continuation =>
      _note.substring(_prefix.lineStart, continuationEnd);

  @override
  String nextMarker(int count) {
    final marker = _note.substring(_prefix.markerStart, _prefix.markerEnd);
    final box = _prefix.isTask && !_prefix.glyph ? '[ ] ' : '';
    if (_prefix.isOrdered) {
      final digits = RegExp(r'^\d+').firstMatch(marker)![0]!;
      final delimiter = marker.substring(digits.length);
      return '${int.parse(digits) + count}$delimiter $box';
    }
    if (marker == '☑') return '☐ ';
    return '$marker $box';
  }

  @override
  int structureOf(String line) =>
      _pastedMarkdownStructure.firstMatch(line)?.end ?? 0;
}

final _plainNumber = RegExp(r'^\d{1,9}\. ');

class _PlainLine implements _Line {
  _PlainLine._({
    required this.lineStart,
    required this.indent,
    required this.marker,
    required this.note,
  });

  factory _PlainLine.at(String note, int offset) {
    final lineStart = offset == 0 ? 0 : note.lastIndexOf('\n', offset - 1) + 1;
    var indent = lineStart;
    while (indent < note.length &&
        (note[indent] == ' ' || note[indent] == '\t')) {
      indent++;
    }
    final rest = note.substring(indent);
    final marker =
        _glyphPrefixes.where(rest.startsWith).firstOrNull ??
        _plainNumber.firstMatch(rest)?[0] ??
        '';
    return _PlainLine._(
      lineStart: lineStart,
      indent: indent,
      marker: marker,
      note: note,
    );
  }

  final String note;
  final int lineStart;
  final int indent;
  final String marker;

  @override
  int get contentStart => indent + marker.length;

  @override
  bool get isItem => marker.isNotEmpty;

  @override
  bool get hasStructure => isItem;

  @override
  int get continuationEnd => indent;

  @override
  String get continuation => note.substring(lineStart, indent);

  @override
  String nextMarker(int count) {
    if (marker == checkedPrefix) return uncheckedPrefix;
    final number = _plainNumber.firstMatch(marker);
    if (number != null) {
      return '${int.parse(marker.substring(0, marker.length - 2)) + count}. ';
    }
    return marker;
  }

  @override
  int structureOf(String line) {
    var at = 0;
    while (at < line.length && (line[at] == ' ' || line[at] == '\t')) {
      at++;
    }
    final rest = line.substring(at);
    final glyph =
        _glyphPrefixes.where(rest.startsWith).firstOrNull ??
        _plainNumber.firstMatch(rest)?[0];
    return glyph == null ? 0 : at + glyph.length;
  }
}

final _glyphPrefixes = [...bulletPrefixes, uncheckedPrefix, checkedPrefix];
