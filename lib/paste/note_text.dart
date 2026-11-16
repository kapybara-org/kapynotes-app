import '../data/note_format.dart';
import '../ui/editor/editor_formatting.dart'
    show bulletPrefixes, checkedPrefix, listIndentUnit, uncheckedPrefix;
import 'html_writer.dart';
import 'markdown_text.dart';
import 'paste_tree.dart';
import 'paste_writers.dart';

/// What a note's [text] looks like to the documents, mail and web editors it
/// is copied into: its HTML, read the way the note's editor reads it. That is
/// as markdown when [markdown], and otherwise as the editor's own plain
/// format, with the bold, italic, heading and subtitle [formats] it keeps
/// beside the text.
///
/// Each U+FFFC an attachment holds its place with is written as the HTML
/// [embeds] gives for its offset, and left out where it gives none.
String noteHtml(
  String text, {
  required bool markdown,
  List<NoteFormatRange> formats = const [],
  Map<int, String> embeds = const {},
}) {
  final anchored = _Anchored(text);
  return writeHtml(
    _readNote(anchored.text, markdown: markdown, formats: formats),
    embeds: {
      for (var i = 0; i < anchored.offsets.length; i++)
        anchored.token(i): embeds[anchored.offsets[i]] ?? '',
    },
  );
}

/// A note's [text] rewritten for a note of the other kind, through the same
/// writers a paste goes through: as markdown when [toMarkdown], and otherwise
/// in the editor's own plain format, with the styles it keeps beside the
/// text.
///
/// The attachments keep their places: [anchors] maps the offset of each
/// U+FFFC in [text] to where it is in the rewritten text.
({String text, List<NoteFormatRange> formats, Map<int, int> anchors})
convertNote(
  String text, {
  required bool toMarkdown,
  List<NoteFormatRange> formats = const [],
}) {
  final anchored = _Anchored(text);
  final blocks = _readNote(
    anchored.text,
    markdown: !toMarkdown,
    formats: formats,
  );
  // Pictures a note's markdown only links to have no attachment to become.
  final written =
      (toMarkdown ? writeMarkdownPaste(blocks) : writePlainPaste(blocks))
          .withoutPictures();
  final units = List<int>.of(written.text.codeUnits);
  final anchors = <int, int>{};
  for (var i = 0; i < units.length; i++) {
    final index = anchored.indexOf(units[i]);
    if (index == null) continue;
    anchors[anchored.offsets[index]] = i;
    units[i] = 0xFFFC;
  }
  return (
    text: String.fromCharCodes(units),
    formats: written.formats,
    anchors: anchors,
  );
}

List<PasteBlock> _readNote(
  String text, {
  required bool markdown,
  required List<NoteFormatRange> formats,
}) =>
    markdown ? readNoteMarkdown(text) : _PlainNoteReader(text, formats).read();

/// A note's text with the U+FFFC of each attachment swapped for a private-use
/// character of its own, which every reader and writer carries as one more
/// character of the words. One for one, so every offset stays where it was.
class _Anchored {
  factory _Anchored(String source) {
    final offsets = [
      for (var i = 0; i < source.length; i++)
        if (source.codeUnitAt(i) == 0xFFFC) i,
    ];
    var base = _firstToken;
    bool taken(int base) => source.codeUnits.any(
      (unit) => unit >= base && unit < base + offsets.length,
    );
    while (offsets.isNotEmpty &&
        base + offsets.length * 2 <= _lastToken &&
        taken(base)) {
      base += offsets.length;
    }
    final units = List<int>.of(source.codeUnits);
    for (var i = 0; i < offsets.length; i++) {
      units[offsets[i]] = base + i;
    }
    return _Anchored._(String.fromCharCodes(units), offsets, base);
  }

  _Anchored._(this.text, this.offsets, this._base);

  /// Past the private-use characters the markdown reader marks with.
  static const _firstToken = 0xE100;
  static const _lastToken = 0xF8FF;

  final String text;

  /// Where each U+FFFC was, in order.
  final List<int> offsets;
  final int _base;

  String token(int index) => String.fromCharCode(_base + index);

  /// Which attachment [unit] stands for, or null when it is a character of
  /// the words.
  int? indexOf(int unit) =>
      unit >= _base && unit < _base + offsets.length ? unit - _base : null;
}

/// A note written without markdown, read into blocks: its paragraphs and
/// line breaks, its heading and subtitle lines, its bold and italic, the
/// lists it writes with glyphs and numbers, and its tables, which draw as
/// grids with the setting off too.
class _PlainNoteReader {
  _PlainNoteReader(this.text, List<NoteFormatRange> formats)
    : _inline = [
        for (final range in formats)
          if (range.format.isInline) range,
      ],
      _paragraph = [
        for (final range in formats)
          if (range.format.isParagraph) range,
      ];

  final String text;
  final List<NoteFormatRange> _inline;
  final List<NoteFormatRange> _paragraph;
  final _blocks = <PasteBlock>[];
  final _lists = <_ListBuilder>[];
  List<PasteInline>? _words;

  static final _number = RegExp(r'^(\d{1,9})\. ');

  List<PasteBlock> read() {
    final lines = <(int, int)>[];
    for (var start = 0; ;) {
      final end = text.indexOf('\n', start);
      if (end < 0) {
        lines.add((start, text.length));
        break;
      }
      lines.add((start, end));
      start = end + 1;
    }
    var i = 0;
    while (i < lines.length) {
      final (start, end) = lines[i];
      if (text.substring(start, end).trim().isEmpty) {
        _endWords();
        _endLists();
        i++;
        continue;
      }
      final table = _tableAt(lines, i);
      if (table != null) {
        _endWords();
        _endLists();
        _blocks.add(table.table);
        i = table.next;
        continue;
      }
      if (_addItem(start, end)) {
        _endWords();
        i++;
        continue;
      }
      _endLists();
      final style = _paragraphStyle(start, end);
      if (style != null) {
        _endWords();
        _blocks.add(
          PasteHeading(
            style == NoteFormat.heading ? 1 : 2,
            _inlines(start, end),
          ),
        );
      } else {
        final words = _words ??= [];
        if (words.isNotEmpty) words.add(const PasteBreak());
        words.addAll(_inlines(start, end));
      }
      i++;
    }
    _endWords();
    _endLists();
    return _blocks;
  }

  /// Rows the note draws as a table, read the way it draws them, starting at
  /// line [i]; null when line [i] does not start one.
  ({PasteTable table, int next})? _tableAt(List<(int, int)> lines, int i) {
    bool row(int at) =>
        at < lines.length &&
        text.substring(lines[at].$1, lines[at].$2).trimLeft().startsWith('|');
    if (!row(i) || !row(i + 1)) return null;
    var next = i;
    while (row(next)) {
      next++;
    }
    final read = readNoteMarkdown(
      text.substring(lines[i].$1, lines[next - 1].$2),
    );
    if (read case [PasteTable table]) return (table: table, next: next);
    return null;
  }

  /// Adds the line from [start] to [end] to the lists being read when it is
  /// a list item, and says whether it was.
  bool _addItem(int start, int end) {
    final line = text.substring(start, end);
    var indent = 0;
    while (indent < line.length &&
        (line[indent] == ' ' || line[indent] == '\t')) {
      indent++;
    }
    final rest = line.substring(indent);
    final number = _number.firstMatch(rest);
    final marker =
        [
          ...bulletPrefixes,
          uncheckedPrefix,
          checkedPrefix,
        ].where(rest.startsWith).firstOrNull ??
        number?[0];
    if (marker == null) return false;
    final depth = indent ~/ listIndentUnit.length;
    final ordered = number != null;
    final words = _inlines(start + indent + marker.length, end);
    final item = (
      blocks: <PasteBlock>[if (words.isNotEmpty) PasteParagraph(words)],
      checked: marker == uncheckedPrefix
          ? false
          : marker == checkedPrefix
          ? true
          : null,
    );
    while (_lists.isNotEmpty && _lists.last.depth > depth) {
      _endList();
    }
    final open = _lists.lastOrNull;
    if (open != null && open.depth == depth) {
      if (open.ordered == ordered) {
        open.items.add(item);
        return true;
      }
      _endList();
    }
    _lists.add(
      _ListBuilder(
        depth: depth,
        ordered: ordered,
        start: number == null ? 1 : int.parse(number[1]!),
      )..items.add(item),
    );
    return true;
  }

  /// The heading or subtitle the line from [start] to [end] is set in.
  NoteFormat? _paragraphStyle(int start, int end) {
    NoteFormat? style;
    for (final range in _paragraph) {
      if (range.start >= end || range.end <= start) continue;
      if (range.format == NoteFormat.heading) return NoteFormat.heading;
      style = range.format;
    }
    return style;
  }

  /// The words from [start] to [end], cut where their bold and italic do.
  List<PasteInline> _inlines(int start, int end) {
    if (end <= start) return const [];
    final cuts = <int>{start, end};
    for (final range in _inline) {
      if (range.start > start && range.start < end) cuts.add(range.start);
      if (range.end > start && range.end < end) cuts.add(range.end);
    }
    final ordered = cuts.toList()..sort();
    return [
      for (var i = 0; i + 1 < ordered.length; i++)
        PasteText(
          text.substring(ordered[i], ordered[i + 1]),
          styles: {
            for (final range in _inline)
              if (range.start <= ordered[i] && range.end >= ordered[i + 1])
                range.format == NoteFormat.bold
                    ? PasteStyle.bold
                    : PasteStyle.italic,
          },
        ),
    ];
  }

  void _endWords() {
    final words = _words;
    if (words != null && words.isNotEmpty) _blocks.add(PasteParagraph(words));
    _words = null;
  }

  void _endList() {
    final list = _lists.removeLast().build();
    final parent = _lists.lastOrNull;
    if (parent == null) {
      _blocks.add(list);
      return;
    }
    if (parent.items.isEmpty) parent.items.add((blocks: [], checked: null));
    parent.items.last.blocks.add(list);
  }

  void _endLists() {
    while (_lists.isNotEmpty) {
      _endList();
    }
  }
}

class _ListBuilder {
  _ListBuilder({
    required this.depth,
    required this.ordered,
    required this.start,
  });

  final int depth;
  final bool ordered;
  final int start;
  final items = <({List<PasteBlock> blocks, bool? checked})>[];

  PasteList build() => PasteList(
    ordered: ordered,
    start: start,
    items: [
      for (final item in items)
        PasteListItem(item.blocks, checked: item.checked),
    ],
  );
}
