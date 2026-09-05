import '../data/note_format.dart';

/// Converts between a note's `(body, formats)` pair and markdown.
///
/// The body is plain text with a parallel list of half-open ranges. Markdown
/// says the same thing with inline syntax, which shifts every offset after it
/// and cannot express everything the app can — a `heading` covering half a
/// line, for one. So the archive carries both: the manifest holds the exact
/// ranges and is what import trusts, and the `.md` file holds a rendering a
/// human can read in any editor. This file is the bridge, and the parser here
/// is only the fallback for a file somebody has hand-edited.
///
/// It is deliberately not a CommonMark implementation. It reads the subset
/// this app can produce, plus enough of the surrounding rules — no emphasis
/// opening before a space, no intraword `_` — that a line of arithmetic like
/// `daily * 7` survives being read back.

/// What [renderNoteMarkdown] emits for a range, and what
/// [parseNoteMarkdown] recognises.
const _markers = {NoteFormat.bold: '**', NoteFormat.italic: '*'};

/// Bold opens before italic wherever both start at once, so nesting is the
/// same every time and the parser's greedy split mirrors it exactly.
const _inlineOrder = [NoteFormat.bold, NoteFormat.italic];

const _linePrefixes = {NoteFormat.heading: '# ', NoteFormat.subtitle: '## '};

/// Renders [body] and [formats] as markdown.
///
/// `heading` and `subtitle` widen to every line they touch, because markdown
/// has no way to say "the second half of this line is a heading". That loss is
/// one-way: the manifest still carries the exact range, so a normal import
/// never sees it.
String renderNoteMarkdown(String body, List<NoteFormatRange> formats) {
  final normalized = normalizeNoteFormats(formats, body.length);
  final out = StringBuffer();

  var lineStart = 0;
  var first = true;
  while (true) {
    final newline = body.indexOf('\n', lineStart);
    final lineEnd = newline < 0 ? body.length : newline;

    if (!first) out.write('\n');
    first = false;
    out.write(_renderLine(body, lineStart, lineEnd, normalized));

    if (newline < 0) break;
    lineStart = newline + 1;
  }
  return out.toString();
}

String _renderLine(
  String body,
  int lineStart,
  int lineEnd,
  List<NoteFormatRange> formats,
) {
  bool touches(NoteFormatRange range) =>
      range.start < lineEnd && range.end > lineStart;

  final out = StringBuffer();

  // A line can only be one kind of heading. `heading` is the louder of the
  // two, so it wins where both somehow overlap the same line. An empty line
  // gets no prefix: a bare `# ` says nothing and reads as a mistake.
  if (lineEnd > lineStart) {
    for (final format in [NoteFormat.heading, NoteFormat.subtitle]) {
      if (formats.any((r) => r.format == format && touches(r))) {
        out.write(_linePrefixes[format]);
        break;
      }
    }
  }

  final inline = <NoteFormatRange>[];
  for (final range in formats) {
    if (!range.format.isInline || !touches(range)) continue;
    final trimmed = _trimToText(
      body,
      range.start < lineStart ? lineStart : range.start,
      range.end > lineEnd ? lineEnd : range.end,
    );
    if (trimmed != null) {
      inline.add(
        NoteFormatRange(
          start: trimmed.$1,
          end: trimmed.$2,
          format: range.format,
        ),
      );
    }
  }

  // Every start and end becomes a cut, so each rendered span carries one
  // unchanging set of styles. That is what keeps output properly nested:
  // markers only ever close in the order they opened, so the `**a*b**c*` that
  // a naive emitter produces cannot arise.
  final cuts = <int>{lineStart, lineEnd};
  for (final range in inline) {
    cuts.add(range.start);
    cuts.add(range.end);
  }
  final points = cuts.toList()..sort();

  final open = <NoteFormat>[];
  // Whitespace at the end of a segment is held back rather than written, so
  // that a marker closing at that boundary lands against the last real
  // character. Markdown ignores `** bold **`, and a parser reading it back
  // would too.
  var held = '';

  for (var i = 0; i + 1 < points.length; i++) {
    final start = points[i];
    final end = points[i + 1];
    if (end <= start) continue;

    final active = {
      for (final range in inline)
        if (range.start <= start && range.end >= end) range.format,
    };

    var keep = 0;
    while (keep < open.length && active.contains(open[keep])) {
      keep++;
    }
    while (open.length > keep) {
      out.write(_markers[open.removeLast()]);
    }

    out.write(held);
    held = '';

    final text = _escape(body, start, end, guarded: inline.isNotEmpty);
    // Anything opening here opens after the segment's own leading whitespace,
    // for the same reason.
    var from = 0;
    while (from < text.length && _isSpace(text.codeUnitAt(from))) {
      from++;
    }
    out.write(text.substring(0, from));

    for (final format in _inlineOrder) {
      if (active.contains(format) && !open.contains(format)) {
        open.add(format);
        out.write(_markers[format]);
      }
    }

    var to = text.length;
    while (to > from && _isSpace(text.codeUnitAt(to - 1))) {
      to--;
    }
    out.write(text.substring(from, to));
    held = text.substring(to);
  }

  while (open.isNotEmpty) {
    out.write(_markers[open.removeLast()]);
  }
  out.write(held);

  return out.toString();
}

/// Shrinks a range off its surrounding whitespace, or null if nothing is left.
///
/// `** bold **` is not bold in any markdown renderer. The manifest keeps the
/// user's actual range; this only decides where the markers are printed.
(int, int)? _trimToText(String body, int start, int end) {
  var from = start;
  var to = end;
  while (from < to && _isSpace(body.codeUnitAt(from))) {
    from++;
  }
  while (to > from && _isSpace(body.codeUnitAt(to - 1))) {
    to--;
  }
  return to > from ? (from, to) : null;
}

bool _isSpace(int unit) =>
    unit == 0x20 || unit == 0x09 || unit == 0x0a || unit == 0x0d;

/// Backslash-escapes what would otherwise read back as formatting nobody
/// applied.
///
/// Not every occurrence: this app's notes are full of arithmetic, and turning
/// `daily * 7` into `daily \* 7` would spoil the readable half of the archive
/// for exactly the lines people most want to read. A `*` with whitespace on
/// both sides can neither open nor close emphasis under any markdown rule, and
/// an intraword `_` cannot either, so both are left alone.
///
/// That reasoning only holds while the line's rendered neighbours are its body
/// neighbours. On a line that also carries bold or italic, a marker can land
/// against one of these characters and change what it looks like, so
/// [guarded] escapes every one of them instead. A line with formatting on it
/// is not a line of arithmetic.
String _escape(String body, int start, int end, {required bool guarded}) {
  final out = StringBuffer();
  for (var i = start; i < end; i++) {
    final char = body[i];
    if (_needsEscape(body, i, char, guarded)) out.write(r'\');
    out.write(char);
  }
  return out.toString();
}

bool _needsEscape(String body, int index, String char, bool guarded) {
  switch (char) {
    case r'\':
    case '`':
    case '[':
      return true;
    case '*':
      if (guarded) return true;
      return !(_spaceAt(body, index - 1) && _spaceAt(body, index + 1));
    case '_':
      if (guarded) return true;
      if (_wordAt(body, index - 1) && _wordAt(body, index + 1)) return false;
      return !(_spaceAt(body, index - 1) && _spaceAt(body, index + 1));
    case '#':
      // Only a `#` that opens a line can become a heading, and the parser
      // only looks there. Escaping `issue #42` mid-sentence would be noise.
      return index == 0 || body[index - 1] == '\n';
    default:
      return false;
  }
}

/// Treats the ends of the body as whitespace, which is what they are for the
/// purpose of deciding whether emphasis could start there.
bool _spaceAt(String body, int index) =>
    index < 0 || index >= body.length || _isSpace(body.codeUnitAt(index));

bool _wordAt(String body, int index) {
  if (index < 0 || index >= body.length) return false;
  final unit = body.codeUnitAt(index);
  return (unit >= 0x30 && unit <= 0x39) ||
      (unit >= 0x41 && unit <= 0x5a) ||
      (unit >= 0x61 && unit <= 0x7a) ||
      unit > 0x7f;
}

/// Reads markdown back into a body and its ranges.
///
/// Used when a note's `.md` file no longer hashes to what the manifest
/// recorded — the user edited it — and, later, for importing markdown that
/// never came from here at all.
({String body, List<NoteFormatRange> formats}) parseNoteMarkdown(
  String markdown,
) {
  final out = StringBuffer();
  final formats = <NoteFormatRange>[];
  final lines = markdown.replaceAll('\r\n', '\n').split('\n');

  for (var index = 0; index < lines.length; index++) {
    if (index > 0) out.write('\n');
    final lineStart = out.length;

    var line = lines[index];
    NoteFormat? paragraph;
    // Exactly one space, not a run of them. `#   Title` is a heading in
    // CommonMark, but eating those spaces here would lose them from a body
    // that had them, and this parser's first duty is an exact round trip.
    final prefix = RegExp(r'^(#{1,2}) ').firstMatch(line);
    if (prefix != null) {
      paragraph = prefix.group(1)!.length == 1
          ? NoteFormat.heading
          : NoteFormat.subtitle;
      line = line.substring(prefix.end);
    }

    final parsed = _parseInline(line);
    out.write(parsed.text);
    for (final range in parsed.formats) {
      formats.add(
        NoteFormatRange(
          start: lineStart + range.start,
          end: lineStart + range.end,
          format: range.format,
        ),
      );
    }
    if (paragraph != null && parsed.text.isNotEmpty) {
      formats.add(
        NoteFormatRange(
          start: lineStart,
          end: lineStart + parsed.text.length,
          format: paragraph,
        ),
      );
    }
  }

  final body = out.toString();
  return (body: body, formats: normalizeNoteFormats(formats, body.length));
}

/// One emitted piece of a run of `*` or `_`.
///
/// A run is not always one marker: `***` closing a bold inside an italic is a
/// `*` and then a `**`. Splitting it needs to know what is currently open, so
/// it happens during matching rather than while scanning.
class _Part {
  _Part(this.length, {required this.opens});

  final int length;
  final bool opens;
  _Part? peer;
  int position = 0;

  bool get matched => peer != null;
}

class _Run {
  _Run(this.char, this.length, {required this.canOpen, required this.canClose});

  final String char;
  final int length;
  final bool canOpen;
  final bool canClose;
  final parts = <_Part>[];
}

({String text, List<NoteFormatRange> formats}) _parseInline(String line) {
  final tokens = <Object>[];
  final literal = StringBuffer();

  void flush() {
    if (literal.isEmpty) return;
    tokens.add(literal.toString());
    literal.clear();
  }

  var i = 0;
  while (i < line.length) {
    final char = line[i];
    if (char == r'\' && i + 1 < line.length) {
      literal.write(line[i + 1]);
      i += 2;
      continue;
    }
    if (char != '*' && char != '_') {
      literal.write(char);
      i++;
      continue;
    }

    var end = i;
    while (end < line.length && line[end] == char) {
      end++;
    }
    final before = i > 0 ? line[i - 1] : null;
    final after = end < line.length ? line[end] : null;
    var canOpen = after != null && !_isSpace(after.codeUnitAt(0));
    var canClose = before != null && !_isSpace(before.codeUnitAt(0));
    if (char == '_' &&
        _wordAt(line, i - 1) &&
        end < line.length &&
        _wordAt(line, end)) {
      // `snake_case` is a word, not emphasis. This is why export leaves an
      // intraword underscore unescaped.
      canOpen = false;
      canClose = false;
    }

    flush();
    tokens.add(_Run(char, end - i, canOpen: canOpen, canClose: canClose));
    i = end;
  }
  flush();

  // One stack per delimiter character. `*` and `_` never interleave in
  // anything this app writes, and keeping them apart means a stray `_` cannot
  // swallow a `**` that was meant to close a bold.
  final open = <String, List<_Part>>{'*': [], '_': []};
  for (final token in tokens) {
    if (token is! _Run) continue;
    _resolve(token, open[token.char]!);
  }

  final text = StringBuffer();
  final opened = <_Part>[];
  for (final token in tokens) {
    if (token is String) {
      text.write(token);
      continue;
    }
    final run = token as _Run;
    for (final part in run.parts) {
      if (!part.matched) {
        text.write(run.char * part.length);
        continue;
      }
      part.position = text.length;
      if (part.opens) opened.add(part);
    }
  }

  final formats = <NoteFormatRange>[];
  for (final part in opened) {
    final close = part.peer!;
    if (close.position <= part.position) continue;
    formats.add(
      NoteFormatRange(
        start: part.position,
        end: close.position,
        format: part.length == 2 ? NoteFormat.bold : NoteFormat.italic,
      ),
    );
  }

  return (text: text.toString(), formats: formats);
}

/// Decides what a run of markers is: some closes, then some opens.
///
/// This mirrors [renderNoteMarkdown] exactly, and it has to. A run like `**`
/// with an italic already open is genuinely ambiguous — it could close that
/// italic and open another, or it could open a bold inside it — and reading it
/// the first way turns `*a**b***` into stray asterisks in somebody's note.
///
/// The renderer only ever emits closes in stack order followed by opens in a
/// fixed order, so the run is read by trying to close the top *k* delimiters
/// for k = 0, 1, 2 … and taking the first k whose leftover length is exactly
/// what an opening sequence could be. A run that fits nothing is text, which
/// is how `2 * 3 * 4` survives.
void _resolve(_Run run, List<_Part> open) {
  for (var k = 0; k <= open.length; k++) {
    if (k > 0 && !run.canClose) break;

    var consumed = 0;
    for (var i = 0; i < k; i++) {
      consumed += open[open.length - 1 - i].length;
    }
    if (consumed > run.length) break;

    final leftover = run.length - consumed;
    final rest = open.length - k;
    final hasBold = _isOpen(open, rest, 2);
    final hasItalic = _isOpen(open, rest, 1);

    final List<int>? opens;
    if (leftover == 0) {
      opens = const [];
    } else if (!run.canOpen) {
      continue;
    } else if (leftover == 1 && !hasItalic) {
      opens = const [1];
    } else if (leftover == 2 && !hasBold) {
      opens = const [2];
    } else if (leftover == 3 && !hasBold && !hasItalic) {
      // Bold outside italic, the one order the renderer uses.
      opens = const [2, 1];
    } else {
      continue;
    }

    for (var i = 0; i < k; i++) {
      final match = open.removeLast();
      final part = _Part(match.length, opens: false);
      part.peer = match;
      match.peer = part;
      run.parts.add(part);
    }
    for (final length in opens) {
      final part = _Part(length, opens: true);
      run.parts.add(part);
      open.add(part);
    }
    return;
  }

  // Nothing this run could be. It is text, and so is anything it might have
  // closed — those stay open and become text at the end of the line.
  run.parts.add(_Part(run.length, opens: false));
}

bool _isOpen(List<_Part> open, int depth, int length) {
  for (var i = 0; i < depth; i++) {
    if (open[i].length == length) return true;
  }
  return false;
}
