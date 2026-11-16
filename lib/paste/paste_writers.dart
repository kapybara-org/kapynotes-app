import '../data/note_format.dart';
import '../ui/editor/editor_formatting.dart'
    show bulletPrefixForDepth, checkedPrefix, listIndentUnit, uncheckedPrefix;
import 'paste_tree.dart';

const _picture = '\uFFFC';

/// Writes a paste as the markdown a note is written in.
///
/// What the source meant is said in the editor's own dialect — CommonMark
/// with GitHub's tables, task lists and strikethrough, plus $…$ math and
/// <u> underline — and only what would otherwise be read as markdown it
/// never was is escaped, so the text stays the text. Every picture is one
/// U+FFFC on a line of its own, which is how a note holds pictures.
PasteOutput writeMarkdownPaste(List<PasteBlock> blocks) {
  final writer = _MarkdownWriter();
  final text = _withoutEdgeBlankLines(writer.blocks(blocks)).join('\n');
  return PasteOutput(text: text, images: placeImages(text, writer.images));
}

/// Writes a paste in the editor's own plain format, for a note written
/// without markdown.
///
/// Bullets and boxes become the glyphs the editor draws, headings and
/// bold and italic become its own styles beside the text, a table stays a
/// table (tables draw as grids either way), and everything else is its
/// words. No markdown syntax appears.
PasteOutput writePlainPaste(List<PasteBlock> blocks) {
  final writer = _PlainWriter();
  writer.blocks(blocks, depth: 0);
  return writer.finish();
}

List<String> _withoutEdgeBlankLines(List<String> lines) {
  var start = 0;
  var end = lines.length;
  while (start < end && lines[start].trim().isEmpty) {
    start++;
  }
  while (end > start && lines[end - 1].trim().isEmpty) {
    end--;
  }
  return lines.sublist(start, end);
}

bool _isPictureLine(String line) =>
    line.isNotEmpty && line.replaceAll(_picture, '').isEmpty;

/// One line of a block's words, or a row of pictures.
class _Line {
  const _Line(this.inlines) : pictures = const [];
  const _Line.pictures(this.pictures) : inlines = const [];

  final List<PasteInline> inlines;
  final List<PasteImage> pictures;

  bool get isPictures => pictures.isNotEmpty;
}

/// Cuts a block's words into lines: at its line breaks, and around its
/// pictures, which a note keeps on lines of their own — side by side when
/// they came side by side.
List<_Line> _linesOf(List<PasteInline> inlines, {bool oneLine = false}) {
  final lines = <_Line>[];
  var words = <PasteInline>[];
  var pictures = <PasteImage>[];
  void endWords() {
    if (_hasWords(words)) lines.add(_Line(words));
    words = [];
  }

  void endPictures() {
    if (pictures.isNotEmpty) lines.add(_Line.pictures(pictures));
    pictures = [];
  }

  for (final inline in inlines) {
    switch (inline) {
      case PasteImageInline(:final image):
        endWords();
        pictures.add(image);
      case PasteBreak():
        if (pictures.isNotEmpty) {
          endPictures();
        } else if (oneLine) {
          words.add(const PasteText(' '));
        } else {
          endWords();
        }
      case PasteText(:final text)
          when text.trim().isEmpty && pictures.isNotEmpty:
        break;
      default:
        endPictures();
        words.add(inline);
    }
  }
  endWords();
  endPictures();
  return lines;
}

bool _hasWords(List<PasteInline> inlines) => inlines.any(
  (inline) => switch (inline) {
    PasteText(:final text) => text.trim().isNotEmpty,
    PasteCodeSpan(:final code) => code.isNotEmpty,
    PasteMath(:final tex) => tex.trim().isNotEmpty,
    _ => false,
  },
);

// -------------------------------------------------------------------------
// Markdown

class _MarkdownWriter {
  final images = <PasteImage>[];

  List<String> blocks(List<PasteBlock> blocks, {bool inItem = false}) {
    final lines = <String>[];
    PasteBlock? previous;
    for (final block in blocks) {
      final written = _block(block);
      if (written.isEmpty) continue;
      // A list straight under its item's words is part of the item; a
      // blank line there would make the whole list loose.
      final tight = inItem && block is PasteList && previous is PasteParagraph;
      if (lines.isNotEmpty && !tight) lines.add('');
      lines.addAll(written);
      previous = block;
    }
    return lines;
  }

  List<String> _block(PasteBlock block) => switch (block) {
    PasteParagraph(:final inlines) => _paragraph(inlines),
    PasteHeading(:final level, :final inlines) => _heading(level, inlines),
    PasteList() => _list(block),
    PasteQuote(:final blocks) => _quote(blocks),
    PasteCode(:final text, :final language) => _code(text, language),
    PasteTable() => _table(block),
    PasteRule() => const ['---'],
    PasteMathBlock(:final tex) => _mathBlock(tex),
  };

  List<String> _paragraph(List<PasteInline> inlines) {
    final result = <String>[];
    var afterWords = false;
    for (final line in _linesOf(inlines)) {
      if (line.isPictures) {
        images.addAll(line.pictures);
        result.add(_picture * line.pictures.length);
        afterWords = false;
        continue;
      }
      var text = _renderInlines(line.inlines);
      if (!afterWords) text = text.trimLeft();
      if (text.isEmpty) continue;
      result.add(_escapeLineStart(text, afterWords: afterWords));
      afterWords = true;
    }
    return result;
  }

  List<String> _heading(int level, List<PasteInline> inlines) {
    final words = <String>[];
    final pictures = <String>[];
    for (final line in _linesOf(inlines, oneLine: true)) {
      if (line.isPictures) {
        images.addAll(line.pictures);
        pictures.add(_picture * line.pictures.length);
      } else {
        words.add(_renderInlines(line.inlines).trim());
      }
    }
    var text = words.where((word) => word.isNotEmpty).join(' ');
    // A heading's closing run of #s is not part of its words.
    text = text.replaceFirstMapped(
      RegExp(r'(^|\s)(#+)$'),
      (match) => '${match[1]}\\${match[2]}',
    );
    return [
      if (text.isNotEmpty) '${'#' * level.clamp(1, 6)} $text',
      ...pictures,
    ];
  }

  List<String> _list(PasteList list) {
    final lines = <String>[];
    for (var i = 0; i < list.items.length; i++) {
      final item = list.items[i];
      final marker = list.ordered ? '${list.start + i}. ' : '- ';
      final box = switch (item.checked) {
        null => '',
        true => '[x] ',
        false => '[ ] ',
      };
      final indent = ' ' * marker.length;
      final body = blocks(item.blocks, inItem: true);
      if (body.isEmpty) {
        if (box.isNotEmpty) lines.add('$marker$box');
        continue;
      }
      for (var j = 0; j < body.length; j++) {
        final line = body[j];
        if (j == 0) {
          if (_isPictureLine(line)) {
            lines
              ..add('$marker$box'.trimRight())
              ..add(line);
          } else {
            lines.add('$marker$box$line');
          }
        } else if (line.isEmpty || _isPictureLine(line)) {
          lines.add(line);
        } else {
          lines.add('$indent$line');
        }
      }
    }
    return lines;
  }

  List<String> _quote(List<PasteBlock> blocks) => [
    for (final line in this.blocks(blocks))
      if (line.isEmpty) '>' else if (_isPictureLine(line)) line else '> $line',
  ];

  List<String> _code(String text, String? language) {
    final code = text.replaceAll(_picture, '');
    final fence = '`' * _fenceLength(code, '`');
    final info = language == null
        ? ''
        : language.trim().split(RegExp(r'\s+')).first.replaceAll('`', '');
    return ['$fence$info', ...code.split('\n'), fence];
  }

  List<String> _table(PasteTable table) {
    final cellPictures = <PasteImage>[];
    String cell(List<PasteInline> inlines) {
      final parts = <String>[];
      for (final line in _linesOf(inlines)) {
        if (line.isPictures) {
          cellPictures.addAll(line.pictures);
        } else {
          parts.add(_renderInlines(line.inlines, table: true).trim());
        }
      }
      return parts.where((part) => part.isNotEmpty).join('<br>');
    }

    String row(List<List<PasteInline>> cells) =>
        '| ${cells.map(cell).join(' | ')} |';

    final lines = [
      row(table.rows.first),
      '| ${table.aligns.map(_delimiter).join(' | ')} |',
      for (final cells in table.rows.skip(1)) row(cells),
    ];
    if (cellPictures.isNotEmpty) {
      images.addAll(cellPictures);
      lines
        ..add('')
        ..add(_picture * cellPictures.length);
    }
    return lines;
  }

  static String _delimiter(PasteAlign align) => switch (align) {
    PasteAlign.none => '---',
    PasteAlign.center => ':-:',
    PasteAlign.right => '--:',
  };

  static List<String> _mathBlock(String tex) {
    final source = tex.trim();
    if (source.isEmpty) return const [];
    return source.contains('\n')
        ? [r'$$', ...source.split('\n'), r'$$']
        : ['\$\$$source\$\$'];
  }
}

int _fenceLength(String code, String mark) {
  final longest = _longestRun(code, mark);
  return longest < 3 ? 3 : longest + 1;
}

int _longestRun(String text, String mark) {
  var longest = 0;
  var run = 0;
  for (var i = 0; i < text.length; i++) {
    run = text[i] == mark ? run + 1 : 0;
    if (run > longest) longest = run;
  }
  return longest;
}

const _styleOrder = [
  PasteStyle.bold,
  PasteStyle.italic,
  PasteStyle.strike,
  PasteStyle.underline,
  PasteStyle.superscript,
  PasteStyle.subscript,
];

String _opener(PasteStyle style) => switch (style) {
  PasteStyle.bold => '**',
  PasteStyle.italic => '*',
  PasteStyle.strike => '~~',
  PasteStyle.underline => '<u>',
  PasteStyle.superscript => '<sup>',
  PasteStyle.subscript => '<sub>',
};

String _closer(PasteStyle style) => switch (style) {
  PasteStyle.bold => '**',
  PasteStyle.italic => '*',
  PasteStyle.strike => '~~',
  PasteStyle.underline => '</u>',
  PasteStyle.superscript => '</sup>',
  PasteStyle.subscript => '</sub>',
};

/// One line's words as markdown.
///
/// Emphasis is opened and closed where the styles change rather than
/// around every run, so bold that turns italic halfway reads as one bold
/// span; and white space is kept outside the markers, where CommonMark
/// needs it to be for them to count.
String _renderInlines(List<PasteInline> inlines, {bool table = false}) {
  final out = StringBuffer();
  final open = <PasteStyle>[];
  String? link;
  var pending = '';

  void closeStyles(int depth) {
    while (open.length > depth) {
      out.write(_closer(open.removeLast()));
    }
  }

  void closeLink() {
    closeStyles(0);
    if (link != null) {
      out.write('](${_destination(link!)})');
      link = null;
    }
  }

  for (final inline in inlines) {
    final String lead;
    final String core;
    final String trail;
    final Set<PasteStyle> styles;
    final String? href;
    switch (inline) {
      case PasteText(:final text, styles: final textStyles, href: final h):
        final (shown, kept) = _scripted(text, textStyles);
        final start = shown.length - shown.trimLeft().length;
        final end = shown.trimRight().length;
        lead = shown.substring(0, start);
        trail = end < start ? '' : shown.substring(end);
        final words = end < start ? '' : shown.substring(start, end);
        if (h != null && words == h && _isWebAddress(h)) {
          closeLink();
          out
            ..write(pending)
            ..write(lead)
            ..write('<$h>');
          pending = trail;
          continue;
        }
        core = _escapeText(words, table: table, inLink: h != null);
        styles = kept;
        href = h;
      case PasteCodeSpan(:final code, styles: final codeStyles, href: final h):
        lead = '';
        trail = '';
        core = _codeSpan(code, table: table);
        styles = codeStyles;
        href = h;
      case PasteMath(:final tex):
        lead = '';
        trail = '';
        final source = tex.trim().replaceAll('\n', ' ');
        core = source.isEmpty ? '' : '\$$source\$';
        styles = open.toSet();
        href = link;
      case PasteBreak() || PasteImageInline():
        continue;
    }
    if (core.isEmpty) {
      pending += lead + trail;
      continue;
    }
    if (href != link) {
      closeLink();
    } else {
      final firstGone = open.indexWhere((style) => !styles.contains(style));
      if (firstGone >= 0) closeStyles(firstGone);
    }
    out
      ..write(pending)
      ..write(lead);
    pending = '';
    if (href != null && link == null) {
      out.write('[');
      link = href;
    }
    for (final style in _styleOrder) {
      if (styles.contains(style) && !open.contains(style)) {
        out.write(_opener(style));
        open.add(style);
      }
    }
    out.write(core);
    pending = trail;
  }
  closeLink();
  return out.toString();
}

bool _isWebAddress(String href) =>
    href.startsWith('https://') || href.startsWith('http://');

String _destination(String href) {
  final spaced = href.replaceAll(' ', '%20');
  if (!RegExp(r'[()<>]').hasMatch(spaced)) return spaced;
  return '<${spaced.replaceAll('<', '%3C').replaceAll('>', '%3E')}>';
}

String _codeSpan(String code, {required bool table}) {
  var text = code.replaceAll('\n', ' ').replaceAll(_picture, '');
  if (text.isEmpty) return '';
  if (table) text = text.replaceAll('|', r'\|');
  final fence = '`' * (_longestRun(text, '`') + 1);
  final pad =
      text.startsWith('`') ||
          text.endsWith('`') ||
          (text.startsWith(' ') && text.endsWith(' ') && text.trim().isNotEmpty)
      ? ' '
      : '';
  return '$fence$pad$text$pad$fence';
}

/// Words with superscript and subscript turned into Unicode where every
/// character has a form, which reads the same everywhere (H₂O, x²); the
/// styles left are the ones markup still has to say.
(String, Set<PasteStyle>) _scripted(String text, Set<PasteStyle> styles) {
  for (final (style, table) in [
    (PasteStyle.superscript, _superscripts),
    (PasteStyle.subscript, _subscripts),
  ]) {
    if (!styles.contains(style)) continue;
    final words = text.trim();
    if (words.isEmpty || !words.split('').every(table.containsKey)) continue;
    final converted = text.split('').map((c) => table[c] ?? c).join();
    return (converted, {...styles}..remove(style));
  }
  return (text, styles);
}

const _superscripts = {
  '0': '⁰', '1': '¹', '2': '²', '3': '³', '4': '⁴', '5': '⁵', '6': '⁶', //
  '7': '⁷', '8': '⁸', '9': '⁹', '+': '⁺', '-': '⁻', '=': '⁼', '(': '⁽', //
  ')': '⁾', 'n': 'ⁿ', 'i': 'ⁱ',
};

const _subscripts = {
  '0': '₀', '1': '₁', '2': '₂', '3': '₃', '4': '₄', '5': '₅', '6': '₆', //
  '7': '₇', '8': '₈', '9': '₉', '+': '₊', '-': '₋', '=': '₌', '(': '₍', //
  ')': '₎', 'a': 'ₐ', 'e': 'ₑ', 'o': 'ₒ', 'x': 'ₓ', 'h': 'ₕ', 'k': 'ₖ', //
  'l': 'ₗ', 'm': 'ₘ', 'n': 'ₙ', 'p': 'ₚ', 's': 'ₛ', 't': 'ₜ',
};

final _mathPair = RegExp(r'\$(?![\s$])[^$]*?(?<![\s$\\])\$(?!\d)');
final _entity = RegExp(
  r'^&(?:#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});',
);
final _linkAhead = RegExp(r'^\[[^\]]*\]\s*[(\[]');
final _boxAhead = RegExp(r'^\[[ xX]\]');

/// Escapes what would be read as markdown in [text]: as little as keeps it
/// literal, so a note's source stays readable.
String _escapeText(String text, {required bool table, required bool inLink}) {
  final dollars = _mathPair.hasMatch(text);
  final out = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    final before = i == 0 ? ' ' : text[i - 1];
    final after = i + 1 < text.length ? text[i + 1] : ' ';
    switch (c) {
      case r'\':
        out.write(_isAsciiPunctuation(after) ? r'\\' : r'\');
      case '`':
        out.write(r'\`');
      case '*':
        final loose = _isSpace(before) && _isSpace(after);
        final operator = _endsOperand(before) && _startsOperand(after);
        out.write(loose || operator ? '*' : r'\*');
      case '_':
        final inWord = _isWordCharacter(before) && _isWordCharacter(after);
        final loose = _isSpace(before) && _isSpace(after);
        out.write(inWord || loose ? '_' : r'\_');
      case '~':
        out.write(before == '~' || after == '~' ? r'\~' : '~');
      case '[':
        final rest = text.substring(i);
        out.write(
          _linkAhead.hasMatch(rest) || _boxAhead.hasMatch(rest) ? r'\[' : '[',
        );
      case ']':
        out.write(inLink ? r'\]' : ']');
      case '<':
        out.write(RegExp(r'[A-Za-z/!?]').hasMatch(after) ? r'\<' : '<');
      case '&':
        out.write(_entity.hasMatch(text.substring(i)) ? r'\&' : '&');
      case r'$':
        out.write(dollars ? r'\$' : r'$');
      case '|':
        out.write(table ? r'\|' : '|');
      case _picture:
        break;
      default:
        out.write(c);
    }
  }
  return out.toString();
}

final _headingStart = RegExp(r'^#{1,6}(\s|$)');
final _bulletStart = RegExp(r'^[-+*](\s|$)');
final _orderedStart = RegExp(r'^(\d{1,9})([.)])(\s|$)');
final _thematicBreak = RegExp(r'^([-*_])(\s*\1){2,}\s*$');
final _setextUnderline = RegExp(r'^(=+|-+)\s*$');

/// Keeps a line's first words from being read as the start of a block.
String _escapeLineStart(String line, {required bool afterWords}) {
  if (_headingStart.hasMatch(line) ||
      line.startsWith('>') ||
      _bulletStart.hasMatch(line) ||
      _thematicBreak.hasMatch(line) ||
      (afterWords && _setextUnderline.hasMatch(line))) {
    return '\\$line';
  }
  final ordered = _orderedStart.firstMatch(line);
  if (ordered != null) {
    return '${ordered[1]}\\${line.substring(ordered[1]!.length)}';
  }
  return line;
}

bool _isSpace(String c) => c.trim().isEmpty;

bool _isAsciiPunctuation(String c) =>
    RegExp(r'''[!-/:-@\[-`{-~]''').hasMatch(c);

final _wordCharacter = RegExp(r'[\p{L}\p{N}]', unicode: true);

bool _isWordCharacter(String c) => _wordCharacter.hasMatch(c);

bool _endsOperand(String c) =>
    _isWordCharacter(c) || c == ')' || c == ']' || c == '%';

bool _startsOperand(String c) => _isWordCharacter(c) || c == '(' || c == '[';

// -------------------------------------------------------------------------
// Plain

class _PlainWriter {
  final _out = StringBuffer();
  final _formats = <NoteFormatRange>[];
  final _images = <PasteImage>[];
  var _blankPending = false;

  PasteOutput finish() {
    final text = _out.toString();
    return PasteOutput(
      text: text,
      formats: normalizeNoteFormats(_formats, text.length),
      images: placeImages(text, _images),
    );
  }

  void blocks(List<PasteBlock> blocks, {required int depth, String? indent}) {
    for (final block in blocks) {
      _block(block, depth: depth, indent: indent ?? '');
    }
  }

  /// Starts a new line, after a blank one when the previous block asked for
  /// it.
  void _newLine() {
    if (_out.isEmpty) {
      _blankPending = false;
      return;
    }
    _out.write(_blankPending ? '\n\n' : '\n');
    _blankPending = false;
  }

  void _block(PasteBlock block, {required int depth, required String indent}) {
    switch (block) {
      case PasteParagraph(:final inlines):
        _lines(inlines, indent: indent);
        _blankPending = depth == 0;
      case PasteHeading(:final level, :final inlines):
        _lines(
          inlines,
          indent: indent,
          oneLine: true,
          paragraph: level <= 1 ? NoteFormat.heading : NoteFormat.subtitle,
        );
        _blankPending = depth == 0;
      case PasteList(:final ordered, :final items, :final start):
        for (var i = 0; i < items.length; i++) {
          final item = items[i];
          final itemIndent = listIndentUnit * depth;
          final marker = switch (item.checked) {
            true => checkedPrefix,
            false => uncheckedPrefix,
            null => ordered ? '${start + i}. ' : bulletPrefixForDepth(depth),
          };
          var first = true;
          for (final child in item.blocks) {
            if (child is PasteList) {
              _block(child, depth: depth + 1, indent: '');
              continue;
            }
            if (first && (child is PasteParagraph || child is PasteHeading)) {
              final inlines = switch (child) {
                PasteParagraph(:final inlines) => inlines,
                PasteHeading(:final inlines) => inlines,
                _ => const <PasteInline>[],
              };
              _lines(inlines, indent: itemIndent, marker: marker);
            } else {
              if (first) {
                _newLine();
                _out.write('$itemIndent${marker.trimRight()}');
              }
              _block(
                child,
                depth: depth + 1,
                indent: itemIndent + listIndentUnit,
              );
            }
            first = false;
          }
          if (first) {
            _newLine();
            _out.write('$itemIndent${marker.trimRight()}');
          }
        }
        _blankPending = depth == 0;
      case PasteQuote(:final blocks):
        this.blocks(blocks, depth: depth, indent: indent);
        _blankPending = depth == 0;
      case PasteCode(:final text):
        for (final line in text.replaceAll(_picture, '').split('\n')) {
          _newLine();
          _out.write('$indent$line');
        }
        _blankPending = depth == 0;
      case PasteTable():
        _table(block, indent: indent);
        _blankPending = depth == 0;
      case PasteRule():
        _blankPending = true;
      case PasteMathBlock(:final tex):
        for (final line in tex.trim().split('\n')) {
          _newLine();
          _out.write('$indent$line');
        }
        _blankPending = depth == 0;
    }
  }

  /// Writes a block's words, line by line, with [marker] in front of the
  /// first and [paragraph] over each.
  void _lines(
    List<PasteInline> inlines, {
    required String indent,
    String marker = '',
    bool oneLine = false,
    NoteFormat? paragraph,
  }) {
    var first = true;
    for (final line in _linesOf(inlines, oneLine: oneLine)) {
      _newLine();
      if (line.isPictures) {
        if (first && marker.isNotEmpty) {
          _out.write('$indent${marker.trimRight()}');
          _newLine();
        }
        _images.addAll(line.pictures);
        _out.write(_picture * line.pictures.length);
        first = false;
        continue;
      }
      _out.write(indent);
      if (first) _out.write(marker);
      final start = _out.length;
      _words(line.inlines, trimStart: true);
      final end = _out.length;
      if (paragraph != null && end > start) {
        _formats.add(
          NoteFormatRange(start: start, end: end, format: paragraph),
        );
      }
      first = false;
    }
  }

  void _words(List<PasteInline> inlines, {bool trimStart = false}) {
    var atStart = trimStart;
    void write(String text, Set<PasteStyle> styles) {
      var words = text.replaceAll(_picture, '');
      if (atStart) words = words.trimLeft();
      if (words.isEmpty) return;
      atStart = false;
      final start = _out.length;
      _out.write(words);
      for (final style in styles) {
        final format = switch (style) {
          PasteStyle.bold => NoteFormat.bold,
          PasteStyle.italic => NoteFormat.italic,
          _ => null,
        };
        if (format != null) {
          _formats.add(
            NoteFormatRange(start: start, end: _out.length, format: format),
          );
        }
      }
    }

    String? openLink;
    final linkWords = StringBuffer();
    void endLink() {
      final href = openLink;
      if (href == null) return;
      final words = linkWords.toString().trim();
      final shown = href.startsWith('mailto:') ? href.substring(7) : href;
      if (words != href && words != shown) write(' ($shown)', const {});
      openLink = null;
      linkWords.clear();
    }

    for (final inline in inlines) {
      final href = switch (inline) {
        PasteText(:final href) || PasteCodeSpan(:final href) => href,
        _ => null,
      };
      if (href != openLink) endLink();
      openLink = href;
      switch (inline) {
        case PasteText(:final text, :final styles):
          final (shown, kept) = _scripted(text, styles);
          if (href != null) linkWords.write(shown);
          write(shown, kept);
        case PasteCodeSpan(:final code, :final styles):
          if (href != null) linkWords.write(code);
          write(code, styles);
        case PasteMath(:final tex):
          write(tex.trim(), const {});
        case PasteBreak() || PasteImageInline():
          break;
      }
    }
    endLink();
    final text = _out.toString();
    final trimmed = text.trimRight().length;
    if (trimmed < text.length) {
      final kept = text.substring(0, trimmed);
      _out
        ..clear()
        ..write(kept);
    }
  }

  void _table(PasteTable table, {required String indent}) {
    final pictures = <PasteImage>[];
    String cell(List<PasteInline> inlines) {
      final parts = <String>[];
      for (final line in _linesOf(inlines)) {
        if (line.isPictures) {
          pictures.addAll(line.pictures);
          continue;
        }
        final words = StringBuffer();
        for (final inline in line.inlines) {
          switch (inline) {
            case PasteText(:final text, :final styles):
              words.write(_scripted(text, styles).$1);
            case PasteCodeSpan(:final code):
              words.write(code);
            case PasteMath(:final tex):
              words.write(tex.trim());
            case PasteBreak() || PasteImageInline():
              break;
          }
        }
        parts.add(words.toString().trim().replaceAll('|', r'\|'));
      }
      return parts.where((part) => part.isNotEmpty).join('<br>');
    }

    final rows = [
      '| ${table.rows.first.map(cell).join(' | ')} |',
      '| ${table.aligns.map(_MarkdownWriter._delimiter).join(' | ')} |',
      for (final cells in table.rows.skip(1))
        '| ${cells.map(cell).join(' | ')} |',
    ];
    for (final row in rows) {
      _newLine();
      _out.write('$indent$row');
    }
    if (pictures.isNotEmpty) {
      _blankPending = true;
      _newLine();
      _images.addAll(pictures);
      _out.write(_picture * pictures.length);
    }
  }
}
