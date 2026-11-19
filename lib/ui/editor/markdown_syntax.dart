import 'package:dart_markdown/dart_markdown.dart' as md;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show TextRange, TextSelection;

import '../../core/note_link.dart';

/// What a stretch of a markdown note is drawn as.
///
/// Semantic, like the calculator's highlight kinds: the controller decides
/// what each one looks like, so nothing here has to know about a theme.
enum MarkdownStyle {
  heading1,
  heading2,
  heading3,
  heading4,
  heading5,
  heading6,
  strong,
  emphasis,
  strikethrough,

  /// Words between `<u>` and `</u>`, or `<ins>` and `</ins>`.
  underline,

  /// Words between `<sup>` and `</sup>`.
  superscript,

  /// Words between `<sub>` and `</sub>`.
  subscript,

  /// Inline code, its backticks included.
  code,

  /// A fenced or indented code block, fences included.
  codeBlock,

  /// A formula in TeX, its dollar signs included. Drawn as the formula it
  /// writes, and as its TeX in code's face while the caret is at it; see
  /// [MarkdownMath].
  math,

  /// Everything inside a block quote.
  quote,

  /// Punctuation that is markdown rather than writing — `**`, `#`, `>`, a
  /// link's brackets and its address. Hidden, mostly; drawn quietly on the
  /// occasions it is shown. See [MarkdownConceal].
  syntax,

  /// A list item's number.
  listMarker,

  /// A task's `[ ]` or `[x]`, which a checkbox is drawn over.
  taskBox,

  /// The words of a ticked task.
  doneTask,

  /// A link's words.
  link,

  /// The cells of a table's first row.
  tableHeader,

  /// Raw HTML, which markdown passes through rather than reads.
  html,
}

MarkdownStyle _headingStyle(int level) => switch (level) {
  <= 1 => MarkdownStyle.heading1,
  2 => MarkdownStyle.heading2,
  3 => MarkdownStyle.heading3,
  4 => MarkdownStyle.heading4,
  5 => MarkdownStyle.heading5,
  _ => MarkdownStyle.heading6,
};

TextRange _shift(TextRange range, int by) =>
    TextRange(start: range.start + by, end: range.end + by);

/// One style over the half-open range [start, end) of the note.
@immutable
class MarkdownSpan {
  const MarkdownSpan(this.start, this.end, this.style);

  final int start;
  final int end;
  final MarkdownStyle style;

  MarkdownSpan _shifted(int by) => MarkdownSpan(start + by, end + by, style);

  @override
  bool operator ==(Object other) =>
      other is MarkdownSpan &&
      other.start == start &&
      other.end == end &&
      other.style == style;

  @override
  int get hashCode => Object.hash(start, end, style);

  @override
  String toString() => 'MarkdownSpan($start, $end, ${style.name})';
}

/// A link written in markdown: the words that are clicked, and where they go.
///
/// The address is the one the parser resolved, so a reference link
/// (`[words][ref]`) points where its definition says, not at its label.
@immutable
class MarkdownLink {
  const MarkdownLink(this.start, this.end, this.destination);

  final int start;
  final int end;
  final String destination;

  MarkdownLink _shifted(int by) =>
      MarkdownLink(start + by, end + by, destination);

  @override
  bool operator ==(Object other) =>
      other is MarkdownLink &&
      other.start == start &&
      other.end == end &&
      other.destination == destination;

  @override
  int get hashCode => Object.hash(start, end, destination);
}

/// A GFM task: the offset of its `[`, and whether the box is ticked.
@immutable
class MarkdownTask {
  const MarkdownTask(this.box, {required this.checked});

  final int box;
  final bool checked;

  MarkdownTask _shifted(int by) => MarkdownTask(box + by, checked: checked);

  @override
  bool operator ==(Object other) =>
      other is MarkdownTask && other.box == box && other.checked == checked;

  @override
  int get hashCode => Object.hash(box, checked);
}

/// A formula written in TeX between dollar signs: `$…$` among words, or
/// `$$…$$` set apart on lines of its own.
///
/// [start] to [end] takes the dollar signs in, and [tex] is what they hold,
/// trimmed. A formula is literal, the way code is: the calculator does not read
/// it and spelling leaves it alone.
@immutable
class MarkdownMath {
  const MarkdownMath(this.start, this.end, this.tex, {required this.display});

  final int start;
  final int end;
  final String tex;

  /// Set apart on lines of its own rather than written among words.
  final bool display;

  MarkdownMath _shifted(int by) =>
      MarkdownMath(start + by, end + by, tex, display: display);

  /// Whether the formula shows its TeX rather than itself, with the selection
  /// at [selection].
  ///
  /// Only in a note being edited, which is what [revealBlocks] says. A caret
  /// or a selection's end anywhere inside always shows it: that is where the
  /// TeX is typed. Against its edges, display math shows, as a block's syntax
  /// does; inline math as inline markers do, so only with [revealEdges] — and
  /// a formula whose closing `$` has just been typed is drawn at once. A
  /// selection reaching over the whole of one leaves it drawn.
  bool revealedAt(
    TextSelection? selection, {
    required bool revealBlocks,
    required bool revealEdges,
  }) {
    if (!revealBlocks || selection == null || !selection.isValid) return false;
    bool inside(int offset) => offset > start && offset < end;
    if (inside(selection.baseOffset) || inside(selection.extentOffset)) {
      return true;
    }
    if (!selection.isCollapsed) return false;
    final caret = selection.baseOffset;
    if (caret != start && caret != end) return false;
    return display || revealEdges;
  }

  @override
  bool operator ==(Object other) =>
      other is MarkdownMath &&
      other.start == start &&
      other.end == end &&
      other.tex == tex &&
      other.display == display;

  @override
  int get hashCode => Object.hash(start, end, tex, display);

  @override
  String toString() =>
      'MarkdownMath($start, $end, ${display ? 'display' : 'inline'}: $tex)';
}

/// A fenced code block whose info string names a language, for colouring the
/// code the way that language reads.
@immutable
class MarkdownCodeBlock {
  const MarkdownCodeBlock(this.language, this.code);

  /// The info string's first word, as written: `python`, `ts`, `C++`.
  final String language;

  /// Where the code sits, fences left out. In more than one piece when the
  /// block is indented or quoted, since a line's indentation or `>` is not
  /// code.
  final List<TextRange> code;

  MarkdownCodeBlock _shifted(int by) => MarkdownCodeBlock(language, [
    for (final range in code) _shift(range, by),
  ]);

  @override
  bool operator ==(Object other) =>
      other is MarkdownCodeBlock &&
      other.language == language &&
      listEquals(other.code, code);

  @override
  int get hashCode => Object.hash(language, Object.hashAll(code));
}

enum MarkdownBlockKind { code, quote, rule }

/// A block that is drawn behind the text as well as in it: the panel under a
/// code block, the bar beside a quote, the line of a thematic break.
@immutable
class MarkdownBlock {
  const MarkdownBlock(this.kind, this.start, this.end, {this.depth = 0});

  final MarkdownBlockKind kind;
  final int start;
  final int end;

  /// How many quotes this one sits inside, counting itself. Zero for the
  /// other kinds.
  final int depth;

  MarkdownBlock _shifted(int by) =>
      MarkdownBlock(kind, start + by, end + by, depth: depth);

  @override
  bool operator ==(Object other) =>
      other is MarkdownBlock &&
      other.kind == kind &&
      other.start == start &&
      other.end == end &&
      other.depth == depth;

  @override
  int get hashCode => Object.hash(kind, start, end, depth);
}

/// When a piece of hidden syntax is shown again.
enum MarkdownReveal {
  /// While the caret sits against the syntax: at an edge of the element it
  /// marks, on either side of its markers. `**bold**` shows its asterisks
  /// with the caret before or after the word — so a writer can see which side
  /// of them they are typing on — and not with the caret in the middle of it.
  edges,

  /// While the caret or a selection is anywhere in the element: a code
  /// block's fences, a thematic break, a heading's underline, a reference
  /// definition. Each of those takes lines of its own, so showing it moves
  /// nothing else on the page.
  block,

  /// Never. The structure at the start of a line — a heading's `#`, a
  /// quote's `>`, a task's bullet — is drawn as what it means instead, and
  /// the caret steps over it. See [MarkdownAnalysis.atomicPrefixes].
  never,
}

/// Syntax the editor hides: [start, end), shown again as [reveal] says.
///
/// [scopeStart] to [scopeEnd] is the element the syntax belongs to, and for
/// [MarkdownReveal.edges], [innerStart] to [innerEnd] is what it wraps.
@immutable
class MarkdownConceal {
  const MarkdownConceal(
    this.start,
    this.end,
    this.reveal, {
    required this.scopeStart,
    required this.scopeEnd,
    int? innerStart,
    int? innerEnd,
  }) : innerStart = innerStart ?? scopeStart,
       innerEnd = innerEnd ?? scopeEnd;

  final int start;
  final int end;
  final MarkdownReveal reveal;
  final int scopeStart;
  final int scopeEnd;
  final int innerStart;
  final int innerEnd;

  MarkdownConceal _shifted(int by) => MarkdownConceal(
    start + by,
    end + by,
    reveal,
    scopeStart: scopeStart + by,
    scopeEnd: scopeEnd + by,
    innerStart: innerStart + by,
    innerEnd: innerEnd + by,
  );

  /// Whether a collapsed caret at [caret] sits against this syntax.
  bool _touchedAt(int caret) =>
      (caret >= scopeStart && caret <= innerStart) ||
      (caret >= innerEnd && caret <= scopeEnd);

  @override
  bool operator ==(Object other) =>
      other is MarkdownConceal &&
      other.start == start &&
      other.end == end &&
      other.reveal == reveal &&
      other.scopeStart == scopeStart &&
      other.scopeEnd == scopeEnd &&
      other.innerStart == innerStart &&
      other.innerEnd == innerEnd;

  @override
  int get hashCode => Object.hash(
    start,
    end,
    reveal,
    scopeStart,
    scopeEnd,
    innerStart,
    innerEnd,
  );

  @override
  String toString() =>
      'MarkdownConceal($start, $end, ${reveal.name}, '
      '$scopeStart-$innerStart-$innerEnd-$scopeEnd)';
}

enum MarkdownOrnamentKind {
  /// A list item's `-`, `*` or `+` and the spaces after it, drawn as a
  /// bullet.
  bullet,

  /// A task's `[ ]`, drawn as a checkbox.
  checkbox,

  /// Inline code's words, drawn on a tinted pill.
  codeSpan,
}

/// Something drawn behind the text rather than in it, over [start, end).
///
/// Bullets and checkboxes are drawn in the room their own characters take,
/// which are left there but made invisible: that keeps the words of the item
/// where the reader expects them, and the box where a click finds it.
@immutable
class MarkdownOrnament {
  const MarkdownOrnament(
    this.kind,
    this.start,
    this.end, {
    this.depth = 0,
    this.checked = false,
  });

  final MarkdownOrnamentKind kind;
  final int start;
  final int end;

  /// A bullet's nesting level, which chooses how it is drawn.
  final int depth;

  /// Whether a checkbox is ticked.
  final bool checked;

  MarkdownOrnament _shifted(int by) => MarkdownOrnament(
    kind,
    start + by,
    end + by,
    depth: depth,
    checked: checked,
  );

  @override
  bool operator ==(Object other) =>
      other is MarkdownOrnament &&
      other.kind == kind &&
      other.start == start &&
      other.end == end &&
      other.depth == depth &&
      other.checked == checked;

  @override
  int get hashCode => Object.hash(kind, start, end, depth, checked);
}

/// A list item drawn as one: where its marker is, where its words begin, and
/// how deep it is nested, for giving every marker the same room.
@immutable
class MarkdownListItem {
  const MarkdownListItem({
    required this.lineStart,
    required this.markerStart,
    required this.markerEnd,
    required this.wordsStart,
    required this.depth,
    this.box,
    this.ordered = false,
    this.quoted = false,
  });

  final int lineStart;

  /// The bullet or number. A task's bullet is hidden, and its [box] is what
  /// is drawn in its place.
  final int markerStart;
  final int markerEnd;

  /// A task's `[`.
  final int? box;
  final int wordsStart;

  /// How many items this one is nested inside.
  final int depth;
  final bool ordered;

  /// Inside a quote, whose hidden markers share the line's indentation.
  final bool quoted;

  MarkdownListItem _shifted(int by) => MarkdownListItem(
    lineStart: lineStart + by,
    markerStart: markerStart + by,
    markerEnd: markerEnd + by,
    wordsStart: wordsStart + by,
    depth: depth,
    box: box == null ? null : box! + by,
    ordered: ordered,
    quoted: quoted,
  );

  @override
  bool operator ==(Object other) =>
      other is MarkdownListItem &&
      other.lineStart == lineStart &&
      other.markerStart == markerStart &&
      other.markerEnd == markerEnd &&
      other.wordsStart == wordsStart &&
      other.depth == depth &&
      other.box == box &&
      other.ordered == ordered &&
      other.quoted == quoted;

  @override
  int get hashCode => Object.hash(
    lineStart,
    markerStart,
    markerEnd,
    wordsStart,
    depth,
    box,
    ordered,
    quoted,
  );

  @override
  String toString() =>
      'MarkdownListItem($lineStart, $markerStart-$markerEnd, box: $box, '
      'words: $wordsStart, depth: $depth, ordered: $ordered, quoted: $quoted)';
}

/// Words drawn in one style: [styles] are the inline markdown over them.
typedef MarkdownRun = ({String text, Set<MarkdownStyle> styles});

enum MarkdownCellAlign { start, center, end }

@immutable
class MarkdownTableCell {
  const MarkdownTableCell(this.start, this.end, this.text);

  final int start;
  final int end;

  /// What the cell says, without its markdown: `**42**` is `42`.
  final String text;

  MarkdownTableCell _shifted(int by) =>
      MarkdownTableCell(start + by, end + by, text);

  @override
  bool operator ==(Object other) =>
      other is MarkdownTableCell &&
      other.start == start &&
      other.end == end &&
      other.text == text;

  @override
  int get hashCode => Object.hash(start, end, text);
}

@immutable
class MarkdownTableRow {
  const MarkdownTableRow(
    this.start,
    this.end,
    this.cells, {
    this.header = false,
  });

  final int start;
  final int end;
  final List<MarkdownTableCell> cells;
  final bool header;

  MarkdownTableRow _shifted(int by) => MarkdownTableRow(start + by, end + by, [
    for (final cell in cells) cell._shifted(by),
  ], header: header);

  @override
  bool operator ==(Object other) =>
      other is MarkdownTableRow &&
      other.start == start &&
      other.end == end &&
      other.header == header &&
      listEquals(other.cells, cells);

  @override
  int get hashCode => Object.hash(start, end, header, Object.hashAll(cells));
}

/// A GFM table, always drawn as a grid over its hidden source text.
@immutable
class MarkdownTable {
  const MarkdownTable(
    this.start,
    this.end, {
    required this.rows,
    required this.aligns,
    required this.delimiterStart,
    required this.delimiterEnd,
  });

  final int start;
  final int end;

  /// The header first, then the body, each on its own line.
  final List<MarkdownTableRow> rows;
  final List<MarkdownCellAlign> aligns;

  /// The `|---|:--|` line under the header.
  final int delimiterStart;
  final int delimiterEnd;

  MarkdownTable _shifted(int by) => MarkdownTable(
    start + by,
    end + by,
    rows: [for (final row in rows) row._shifted(by)],
    aligns: aligns,
    delimiterStart: delimiterStart + by,
    delimiterEnd: delimiterEnd + by,
  );

  @override
  bool operator ==(Object other) =>
      other is MarkdownTable &&
      other.start == start &&
      other.end == end &&
      other.delimiterStart == delimiterStart &&
      other.delimiterEnd == delimiterEnd &&
      listEquals(other.rows, rows) &&
      listEquals(other.aligns, aligns);

  @override
  int get hashCode => Object.hash(
    start,
    end,
    delimiterStart,
    delimiterEnd,
    Object.hashAll(rows),
    Object.hashAll(aligns),
  );
}

/// What the editor draws of the note for one caret position: which syntax is
/// hidden, which characters keep their room but are not drawn, and which
/// tables show as written.
@immutable
class MarkdownConcealment {
  const MarkdownConcealment._({
    required this.hidden,
    required this.transparent,
    required this.formulas,
    required this.key,
  });

  static const none = MarkdownConcealment._(
    hidden: [],
    transparent: [],
    formulas: [],
    key: 0,
  );

  /// Collapsed to nothing. Sorted, and never overlapping.
  final List<TextRange> hidden;

  /// Laid out as usual but not drawn, because something is drawn in their
  /// place: a bullet, a checkbox, a table's grid. Sorted, never overlapping.
  final List<TextRange> transparent;

  /// The formulas drawn as formulas rather than as their TeX. Each is in
  /// [hidden] whole; the editor draws the formula in the place of its first
  /// character. Sorted.
  final List<MarkdownMath> formulas;

  /// Changes whenever what is shown does, for anything that caches a layout.
  final int key;

  /// Whether all of [start, end) is hidden.
  bool hides(int start, int end) {
    var low = 0;
    var high = hidden.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (hidden[middle].end <= start) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low < hidden.length &&
        hidden[low].start <= start &&
        hidden[low].end >= end;
  }
}

/// A fenced code block's fences: the opening one's line and the language it
/// names, and the closing one's line when the block is closed.
typedef MarkdownCodeFences = ({
  TextRange open,
  String language,
  TextRange? close,
});

/// Everything the editor needs to know about a note read as markdown.
///
/// Every offset is into [text] itself. The markers stay in the note — the
/// point of writing markdown is that the note is still plain text — so a
/// heading is `# Title` with its `#` hidden, not a `Title` with a style
/// beside it.
class MarkdownAnalysis {
  MarkdownAnalysis._(this.text, this._parts);

  final String text;
  final _Parts _parts;

  /// Sorted by [MarkdownSpan.start]. Spans nest — a bold word in a heading is
  /// covered by both — but never cross, so a sweep from left to right always
  /// knows which ones are open.
  List<MarkdownSpan> get spans => _parts.spans;

  List<MarkdownLink> get links => _parts.links;
  List<MarkdownTask> get tasks => _parts.tasks;
  List<MarkdownBlock> get blocks => _parts.blocks;

  /// [block]'s fences, when it is a fenced code block.
  MarkdownCodeFences? fencesOf(MarkdownBlock block) {
    if (block.kind != MarkdownBlockKind.code) return null;
    var end = block.end;
    if (end > block.start && text.codeUnitAt(end - 1) == 0x0A) end--;
    final newline = text.indexOf('\n', block.start);
    final openEnd = newline < 0 || newline > end ? end : newline;
    final opening = text.substring(block.start, openEnd).trimLeft();
    final marker = opening.startsWith('```')
        ? '`'
        : opening.startsWith('~~~')
        ? '~'
        : null;
    if (marker == null) return null;
    final fence =
        opening.length - opening.replaceFirst(RegExp('^[`~]+'), '').length;
    final lastStart = text.lastIndexOf('\n', end - 1) + 1;
    final closing = text.substring(lastStart, end).trim();
    final closed =
        lastStart > block.start &&
        closing.length >= fence &&
        closing.split('').every((c) => c == marker);
    return (
      open: TextRange(start: block.start, end: openEnd),
      language: opening.substring(fence).trim().split(RegExp(r'\s')).first,
      close: closed ? TextRange(start: lastStart, end: end) : null,
    );
  }

  /// The syntax the editor hides, and when it shows it. Sorted by start.
  List<MarkdownConceal> get conceals => _parts.conceals;

  /// What is drawn behind the text: bullets, checkboxes, code pills.
  List<MarkdownOrnament> get ornaments => _parts.ornaments;

  List<MarkdownTable> get tables => _parts.tables;

  /// Every list item drawn as one, in order.
  List<MarkdownListItem> get listItems => _parts.listItems;

  /// The hidden structure at the start of each line that has some, from the
  /// line's first character to where its words begin. The caret is kept out
  /// of these: there is nothing on screen there to put it next to.
  List<TextRange> get atomicPrefixes => _parts.atomicPrefixes;

  /// Fenced and indented code blocks, which the calculator does not read.
  List<TextRange> get codeBlocks => _parts.codeBlocks;

  /// The fenced code blocks that name a language, for colouring their code.
  List<MarkdownCodeBlock> get fencedCode => _parts.fencedCode;

  /// Every formula outside a table, in order. One in a table's cell is drawn
  /// as its TeX, in the grid.
  List<MarkdownMath> get maths => _parts.maths;

  /// `<br>` tags, which a table's cell draws as the line break they ask for.
  /// Anywhere else a tag is shown as written, as any other inline HTML is.
  List<TextRange> get lineBreaks => _parts.lineBreaks;

  /// The rest of what the calculator does not read: struck-through text, the
  /// `*` and `_` around emphasis — the markers only, not the words — and
  /// the backslash of an escape.
  List<TextRange> get unread => _parts.unread;

  /// Where the text is literal rather than prose: code, code blocks, HTML.
  /// Neither spelling nor link detection belongs in there.
  List<TextRange> get literals => _parts.literals;

  /// Link destinations written out in the text, such as `(https://…)`: part
  /// of a markdown link, and so never a link of their own.
  List<TextRange> get addresses => _parts.addresses;

  /// Addresses written as themselves, bare or in `<…>`. Kept off spelling,
  /// and otherwise left to the note's own link detection.
  List<TextRange> get urls => _parts.urls;

  /// Bullets, numbers, task boxes and quote markers: the structure at the
  /// start of a line rather than the words on it.
  List<TextRange> get containerMarkers => _parts.containerMarkers;

  /// The note as the calculator should read it.
  ///
  /// The same length as [text], line for line, so results and highlight
  /// offsets need no translating back. What differs:
  ///
  /// * Code blocks are blanked. What is in one is code, and a result beside
  ///   `x = run(3)` would be the calculator misreading it.
  /// * A list or quote marker becomes the bullet this app draws for its own
  ///   lists. `- 5 + 3` is an item that says "5 + 3", not minus five plus
  ///   three, and `+ 12` is an item rather than a running tally. Turning the
  ///   marker into `•` gives a markdown list exactly the reading the app's
  ///   own bulleted lines have always had.
  /// * Emphasis markers are blanked and their words kept, so `**5 + 3**` is
  ///   read as the 5 + 3 on screen. A `*` between two operands never gets
  ///   this far: the parser is not shown it as emphasis in the first place.
  /// * Struck-through text is blanked, words and all: crossed out is not
  ///   counted, and `Total ~~12~~ 14` is 14.
  /// * Formulas are blanked, dollar signs and all. `$x^2 + 1$` is written to
  ///   be read, not worked out, and a price never gets this far: `$5 and $10`
  ///   is not a formula, by the rules [MarkdownMath] is read by.
  /// * A table's rows are blanked. `| 2+2 | 4 |` is a row of a grid rather than
  ///   a sum, and a result chip beside a tall wrapped row reads as a mistake.
  late final String calculatorText = _neutralise();

  /// The same note read for its tables and nothing else.
  ///
  /// A table is drawn as a grid on every device, whatever "Markdown in notes" is
  /// set to. That setting is kept per device, so a table written on one would
  /// otherwise be a wall of pipes on another — which is no way to read a note,
  /// let alone edit one. Everything else markdown does stays behind the setting.
  ///
  /// Kept here are the tables, the inline styles inside their cells and the
  /// markers those styles hide, which is all [runsIn] reads to draw a cell.
  ///
  /// Lazy and remembered, because both the concealment cache and the table
  /// geometry ask whether they have been handed the very same analysis as last
  /// time.
  late final MarkdownAnalysis tablesOnly = MarkdownAnalysis._(
    text,
    _parts.tables.isEmpty ? _Parts.empty : _parts._tablesOnly(),
  );

  /// The task whose `[` is at [box], if there is one.
  MarkdownTask? taskAt(int box) {
    for (final task in tasks) {
      if (task.box == box) return task;
      if (task.box > box) break;
    }
    return null;
  }

  /// The words of [start, end) with every marker in it hidden, trimmed, and
  /// cut wherever their inline markdown changes: what a table's cell shows
  /// when the table is drawn as a grid rather than as its text.
  ///
  /// A `<br>` becomes the line break it asks for, the spaces either side of
  /// it dropped, since a cell has nowhere else to put one.
  List<MarkdownRun> runsIn(int start, int end) {
    final hidden = [
      for (final conceal in conceals)
        if (conceal.start < end && conceal.end > start) conceal,
    ];
    final styled = [
      for (final span in spans)
        if (span.start < end &&
            span.end > start &&
            _runStyles.contains(span.style))
          span,
    ];
    final breaks = [
      for (final tag in lineBreaks)
        if (tag.start >= start && tag.end <= end) tag,
    ];
    final cuts = <int>{start, end};
    for (final conceal in hidden) {
      cuts
        ..add(conceal.start.clamp(start, end))
        ..add(conceal.end.clamp(start, end));
    }
    for (final span in styled) {
      cuts
        ..add(span.start.clamp(start, end))
        ..add(span.end.clamp(start, end));
    }
    for (final tag in breaks) {
      cuts
        ..add(tag.start)
        ..add(tag.end);
    }
    final sorted = cuts.toList()..sort();

    final runs = <MarkdownRun>[];
    for (var i = 0; i < sorted.length - 1; i++) {
      final from = sorted[i];
      final to = sorted[i + 1];
      if (to <= from ||
          hidden.any((conceal) => conceal.start <= from && to <= conceal.end)) {
        continue;
      }
      final lineBreak = breaks.any((tag) => tag.start <= from && to <= tag.end);
      final styles = {
        for (final span in styled)
          if (span.start <= from &&
              to <= span.end &&
              !(lineBreak && span.style == MarkdownStyle.html))
            span.style,
      };
      final words = lineBreak ? '\n' : text.substring(from, to);
      if (runs.isNotEmpty && setEquals(runs.last.styles, styles)) {
        final last = runs.removeLast();
        runs.add((text: last.text + words, styles: styles));
      } else {
        runs.add((text: words, styles: styles));
      }
    }
    if (breaks.isNotEmpty) {
      for (var i = 0; i < runs.length; i++) {
        final run = runs[i];
        runs[i] = (
          text: run.text.replaceAll(_spacedBreak, '\n'),
          styles: run.styles,
        );
      }
    }

    while (runs.isNotEmpty && runs.first.text.trimLeft().isEmpty) {
      runs.removeAt(0);
    }
    while (runs.isNotEmpty && runs.last.text.trimRight().isEmpty) {
      runs.removeLast();
    }
    if (runs.isEmpty) return const [];
    final first = runs.first;
    runs[0] = (text: first.text.trimLeft(), styles: first.styles);
    final last = runs.last;
    runs[runs.length - 1] = (text: last.text.trimRight(), styles: last.styles);
    return runs;
  }

  static final _spacedBreak = RegExp(r'[ \t]*\n[ \t]*');

  /// The markdown that styles words wherever they are drawn.
  static const _runStyles = {
    MarkdownStyle.strong,
    MarkdownStyle.emphasis,
    MarkdownStyle.strikethrough,
    MarkdownStyle.underline,
    MarkdownStyle.superscript,
    MarkdownStyle.subscript,
    MarkdownStyle.code,
    MarkdownStyle.math,
    MarkdownStyle.link,
    MarkdownStyle.html,
  };

  /// The hidden prefix of the line [offset] is on, if it has one and the
  /// offset is inside it or at its end.
  TextRange? atomicPrefixAt(int offset) {
    for (final prefix in atomicPrefixes) {
      if (prefix.start > offset) break;
      if (offset <= prefix.end) return prefix;
    }
    return null;
  }

  /// What is hidden and what is shown, with the caret at [selection].
  ///
  /// [revealBlocks] is false while the note is not being edited — not
  /// focused, or view-only — which is when nothing is shown as written.
  /// [revealEdges] is false in the same cases and also while the writer is
  /// typing, so markers they have just completed disappear as they complete
  /// them rather than lingering beside the caret.
  ///
  /// A formula is drawn as itself unless [MarkdownMath.revealedAt] says
  /// otherwise, or [drawable] says it cannot be: TeX the editor cannot draw
  /// stays in sight as written.
  MarkdownConcealment concealFor(
    TextSelection? selection, {
    required bool revealBlocks,
    required bool revealEdges,
    bool Function(MarkdownMath math)? drawable,
  }) {
    final valid = selection != null && selection.isValid;
    final caret = valid && selection.isCollapsed ? selection.baseOffset : null;
    bool touchesBlock(int start, int end) =>
        valid && selection.start <= end && selection.end >= start;

    // An element whose markers the caret is against, and any element wrapped
    // round it whose own markers sit against those: `***both***` shows all
    // six asterisks, not the inner four.
    final revealedScopes = <(int, int)>{};
    if (revealEdges && caret != null) {
      for (final conceal in conceals) {
        if (conceal.reveal == MarkdownReveal.edges &&
            conceal._touchedAt(caret)) {
          revealedScopes.add((conceal.scopeStart, conceal.scopeEnd));
        }
      }
      var grew = revealedScopes.isNotEmpty;
      while (grew) {
        grew = false;
        for (final conceal in conceals) {
          if (conceal.reveal != MarkdownReveal.edges) continue;
          final scope = (conceal.scopeStart, conceal.scopeEnd);
          if (revealedScopes.contains(scope)) continue;
          final wraps = revealedScopes.any(
            (inner) =>
                inner.$1 == conceal.innerStart || inner.$2 == conceal.innerEnd,
          );
          if (wraps) {
            revealedScopes.add(scope);
            grew = true;
          }
        }
      }
    }

    final hidden = <TextRange>[];
    var key = 17;
    for (var i = 0; i < conceals.length; i++) {
      final conceal = conceals[i];
      final shown = switch (conceal.reveal) {
        MarkdownReveal.never => false,
        MarkdownReveal.block =>
          revealBlocks && touchesBlock(conceal.scopeStart, conceal.scopeEnd),
        MarkdownReveal.edges => revealedScopes.contains((
          conceal.scopeStart,
          conceal.scopeEnd,
        )),
      };
      if (shown) {
        key = Object.hash(key, i);
      } else {
        hidden.add(TextRange(start: conceal.start, end: conceal.end));
      }
    }

    final formulas = <MarkdownMath>[];
    for (var i = 0; i < maths.length; i++) {
      final math = maths[i];
      final drawn =
          (drawable?.call(math) ?? true) &&
          !math.revealedAt(
            selection,
            revealBlocks: revealBlocks,
            revealEdges: revealEdges,
          );
      if (drawn) {
        formulas.add(math);
        hidden.add(TextRange(start: math.start, end: math.end));
      } else {
        key = Object.hash(key, conceals.length + i);
      }
    }

    final transparent = <TextRange>[
      for (final ornament in ornaments)
        if (ornament.kind != MarkdownOrnamentKind.codeSpan)
          TextRange(start: ornament.start, end: ornament.end),
    ];
    // A table is drawn as a grid wherever the caret is. Showing the pipes as
    // soon as somebody tried to edit one was the whole of what made a table
    // unusable: a grid turned back into markdown under the hand that touched it.
    //
    // Its rows and the `|---|` line under them are hidden rather than left
    // transparent, so a row collapses to nothing and takes exactly one line of
    // the note whatever its words are — which is what lets the grid painted over
    // it line up with one row. The newlines between the rows are left alone:
    // they are what makes them separate lines at all.
    for (final table in tables) {
      for (final row in table.rows) {
        hidden.add(TextRange(start: row.start, end: row.end));
      }
      hidden.add(
        TextRange(start: table.delimiterStart, end: table.delimiterEnd),
      );
    }

    return MarkdownConcealment._(
      hidden: _merged(hidden),
      transparent: _merged(transparent),
      formulas: List.unmodifiable(formulas),
      key: key,
    );
  }

  /// [found] minus the web addresses markdown already accounts for, plus the
  /// markdown links that go somewhere this app will open.
  ///
  /// An address inside `[words](address)` is the link's destination, not a
  /// second link, and one inside code is not a link at all.
  ///
  /// [found] is in the order it starts, as [findNoteLinks] gives it.
  List<NoteLink> linksWith(List<NoteLink> found) {
    final taken = _merged([
      ...literals,
      ...addresses,
      for (final link in links) TextRange(start: link.start, end: link.end),
    ]);
    var next = 0;
    bool free(NoteLink link) {
      while (next < taken.length && taken[next].end <= link.start) {
        next++;
      }
      return next == taken.length || taken[next].start >= link.end;
    }

    final result = <NoteLink>[
      for (final link in found)
        if (free(link)) link,
      for (final link in links)
        if (_launchable(link.destination) case final uri?)
          NoteLink(
            start: link.start,
            end: link.end,
            text: link.destination.trim(),
            uri: uri,
          ),
    ]..sort((a, b) => a.start.compareTo(b.start));
    return List.unmodifiable(result);
  }

  /// Whether the half-open range touches literal text or a written address,
  /// where spelling suggestions and link detection do not belong.
  bool isLiteral(int start, int end) =>
      _overlaps(start, end, literals) ||
      _overlaps(start, end, addresses) ||
      _overlaps(start, end, urls);

  String _neutralise() {
    if (codeBlocks.isEmpty &&
        unread.isEmpty &&
        maths.isEmpty &&
        containerMarkers.isEmpty &&
        tables.isEmpty) {
      return text;
    }
    final units = List<int>.of(text.codeUnits);
    // A table is not arithmetic. Its rows are blanked, the newlines between them
    // kept and the length with them, so no result is ever drawn beside a grid.
    for (final table in tables) {
      for (var i = table.start; i < table.end && i < units.length; i++) {
        final unit = units[i];
        if (unit != 0x0A && unit != 0x0D) units[i] = 0x20;
      }
    }
    for (final range in [
      ...codeBlocks,
      ...unread,
      for (final math in maths) TextRange(start: math.start, end: math.end),
    ]) {
      for (var i = range.start; i < range.end && i < units.length; i++) {
        final unit = units[i];
        if (unit != 0x0A && unit != 0x0D) units[i] = 0x20;
      }
    }
    for (final marker in containerMarkers) {
      if (marker.start >= units.length || marker.end <= marker.start) continue;
      units[marker.start] = 0x2022; // •
      for (var i = marker.start + 1; i < marker.end && i < units.length; i++) {
        units[i] = 0x20;
      }
    }
    return String.fromCharCodes(units);
  }

  static bool _overlaps(int start, int end, List<TextRange> ranges) {
    for (final range in ranges) {
      if (start < range.end && end > range.start) return true;
    }
    return false;
  }

  /// Sorted ranges, with any that touch or overlap joined.
  static List<TextRange> _merged(List<TextRange> ranges) {
    if (ranges.length < 2) return ranges;
    ranges.sort((a, b) => a.start.compareTo(b.start));
    final merged = <TextRange>[ranges.first];
    for (final range in ranges.skip(1)) {
      final last = merged.last;
      if (range.start <= last.end) {
        if (range.end > last.end) {
          merged[merged.length - 1] = TextRange(
            start: last.start,
            end: range.end,
          );
        }
      } else {
        merged.add(range);
      }
    }
    return merged;
  }

  /// A destination this app is willing to open: the same web addresses it
  /// finds in plain text, by the same rules, and mail links.
  static Uri? _launchable(String destination) {
    final trimmed = destination.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.toLowerCase().startsWith('mailto:')) {
      final uri = Uri.tryParse(trimmed);
      return uri != null && uri.path.contains('@') ? uri : null;
    }
    final found = findNoteLinks(trimmed);
    if (found.length == 1 &&
        found.first.start == 0 &&
        found.first.end == trimmed.length) {
      return found.first.uri;
    }
    return null;
  }
}

/// Reads a note as CommonMark with the GitHub extensions — tables,
/// strikethrough, task lists — and remembers what it read.
///
/// Parsing a long note on every keystroke would cost more than everything else
/// the editor does per keystroke put together, so the note is cut into
/// pieces the parser is guaranteed to read the same way on their own as it
/// would in place, and only the piece that changed is read again. See
/// [_chunkStarts] for where the cuts go and [_continuesInto] for why one is
/// sometimes taken back.
class MarkdownAnalyzer {
  String? _text;
  MarkdownAnalysis? _analysis;
  Map<String, _Parts> _chunks = const {};

  MarkdownAnalysis analyze(String text) {
    final cached = _analysis;
    if (cached != null && _text == text) return cached;
    final analysis = _analyzeChunked(text);
    _text = text;
    _analysis = analysis;
    return analysis;
  }

  /// The same answer read in one go, for tests that prove the cutting changes
  /// nothing.
  @visibleForTesting
  static MarkdownAnalysis analyzeWhole(String text) =>
      MarkdownAnalysis._(text, _parse(text));

  /// Beyond this many pieces taken back in a row, the rest of the note is read
  /// in one go. Only something the cutting cannot see — a long HTML comment
  /// with blank lines in it — gets here, and reading the rest once is cheaper
  /// than reading a growing piece again and again.
  static const _maxMerges = 8;

  MarkdownAnalysis _analyzeChunked(String text) {
    final starts = _chunkStarts(text);
    final used = <String, _Parts>{};
    final pieces = <(int, _Parts)>[];

    var index = 0;
    while (index < starts.length) {
      final start = starts[index];
      var next = index + 1;
      var end = next < starts.length ? starts[next] : text.length;
      var chunk = _chunkFor(text.substring(start, end));
      var merges = 0;
      while (end < text.length && _continuesInto(chunk, text, end)) {
        if (chunk.tail == _Tail.list) {
          // A loose list is one piece per item. Every piece that opens with
          // an item goes in at once, rather than one read per item.
          do {
            next++;
          } while (next < starts.length &&
              _listItemStart.matchAsPrefix(text, starts[next]) != null);
        } else {
          merges++;
          next = merges > _maxMerges ? starts.length : next + 1;
        }
        end = next < starts.length ? starts[next] : text.length;
        chunk = _chunkFor(text.substring(start, end));
      }
      // A link reference definition reaches every link in the note, in
      // pieces it is not part of. Rare enough in a note to simply read the
      // whole thing at once.
      if (chunk.hasReferences) {
        final whole = _chunkFor(text);
        _chunks = {text: whole};
        return MarkdownAnalysis._(text, whole);
      }
      used[text.substring(start, end)] = chunk;
      pieces.add((start, chunk));
      index = next;
    }

    _chunks = used;
    return MarkdownAnalysis._(text, _Parts.join(pieces));
  }

  _Parts _chunkFor(String source) => _chunks[source] ?? _parse(source);

  /// [text] read with [line] left blank, so the table it would finish or
  /// grow is read without it. Blanked rather than cut, which leaves every
  /// offset where it was.
  MarkdownAnalysis analyzeHolding(String text, TextRange line) {
    final read = analyze(
      text.replaceRange(line.start, line.end, ' ' * (line.end - line.start)),
    );
    return MarkdownAnalysis._(text, read._parts);
  }

  /// Whether the piece before [boundary] is still open there, so that the
  /// text after it would be read differently in place than on its own.
  ///
  /// Every piece but the last ends on a blank line, which closes paragraphs,
  /// quotes and tables, and the next begins flush left, which closes
  /// indented code and any list item's content. What is left:
  ///
  /// * a fence that has not been closed runs on to the end of the note;
  /// * HTML blocks of several kinds run on across blank lines;
  /// * a list takes in the next item even across a blank line.
  static bool _continuesInto(_Parts chunk, String text, int boundary) =>
      switch (chunk.tail) {
        _Tail.closed => false,
        _Tail.open => true,
        _Tail.list => _listItemStart.matchAsPrefix(text, boundary) != null,
      };

  /// A line that could be a list item, from its first column. Generous on
  /// purpose: `* * *` is a rule, not an item, and taking a piece back for it
  /// costs a little time, where missing an item would cost correctness.
  static final _listItemStart = RegExp(r'(?:[-+*]|[0-9]{1,9}[.)])(?:[ \t]|$)');
}

enum _Tail { closed, list, open }

/// A note, or a piece of one, as read: every list sorted by where its entries
/// start, offsets relative to the start of the piece.
class _Parts {
  const _Parts({
    required this.spans,
    required this.links,
    required this.tasks,
    required this.blocks,
    required this.conceals,
    required this.ornaments,
    required this.tables,
    required this.listItems,
    required this.atomicPrefixes,
    required this.codeBlocks,
    required this.fencedCode,
    required this.maths,
    required this.lineBreaks,
    required this.unread,
    required this.literals,
    required this.addresses,
    required this.urls,
    required this.containerMarkers,
    this.tail = _Tail.closed,
    this.hasReferences = false,
  });

  static const empty = _Parts(
    spans: [],
    links: [],
    tasks: [],
    blocks: [],
    conceals: [],
    ornaments: [],
    tables: [],
    listItems: [],
    atomicPrefixes: [],
    codeBlocks: [],
    fencedCode: [],
    maths: [],
    lineBreaks: [],
    unread: [],
    literals: [],
    addresses: [],
    urls: [],
    containerMarkers: [],
  );

  final List<MarkdownSpan> spans;
  final List<MarkdownLink> links;
  final List<MarkdownTask> tasks;
  final List<MarkdownBlock> blocks;
  final List<MarkdownConceal> conceals;
  final List<MarkdownOrnament> ornaments;
  final List<MarkdownTable> tables;
  final List<MarkdownListItem> listItems;
  final List<TextRange> atomicPrefixes;
  final List<TextRange> codeBlocks;
  final List<MarkdownCodeBlock> fencedCode;
  final List<MarkdownMath> maths;
  final List<TextRange> lineBreaks;
  final List<TextRange> unread;
  final List<TextRange> literals;
  final List<TextRange> addresses;
  final List<TextRange> urls;
  final List<TextRange> containerMarkers;
  final _Tail tail;
  final bool hasReferences;

  /// The pieces of one note, each moved to where it sits in it.
  static _Parts join(List<(int, _Parts)> pieces) {
    if (pieces.length == 1 && pieces.first.$1 == 0) return pieces.first.$2;
    List<T> all<T>(List<T> Function(_Parts) of, T Function(T, int) shift) => [
      for (final (offset, parts) in pieces)
        for (final item in of(parts)) shift(item, offset),
    ];
    return _Parts(
      spans: all((p) => p.spans, (s, by) => s._shifted(by)),
      links: all((p) => p.links, (l, by) => l._shifted(by)),
      tasks: all((p) => p.tasks, (t, by) => t._shifted(by)),
      blocks: all((p) => p.blocks, (b, by) => b._shifted(by)),
      conceals: all((p) => p.conceals, (c, by) => c._shifted(by)),
      ornaments: all((p) => p.ornaments, (o, by) => o._shifted(by)),
      tables: all((p) => p.tables, (t, by) => t._shifted(by)),
      listItems: all((p) => p.listItems, (i, by) => i._shifted(by)),
      atomicPrefixes: all((p) => p.atomicPrefixes, _shift),
      codeBlocks: all((p) => p.codeBlocks, _shift),
      fencedCode: all((p) => p.fencedCode, (c, by) => c._shifted(by)),
      maths: all((p) => p.maths, (m, by) => m._shifted(by)),
      lineBreaks: all((p) => p.lineBreaks, _shift),
      unread: all((p) => p.unread, _shift),
      literals: all((p) => p.literals, _shift),
      addresses: all((p) => p.addresses, _shift),
      urls: all((p) => p.urls, _shift),
      containerMarkers: all((p) => p.containerMarkers, _shift),
    );
  }

  /// Just the tables, and only what [MarkdownAnalysis.runsIn] needs to draw
  /// their cells: the inline styles inside them, the markers those hide, and
  /// the `<br>` tags that break their lines.
  ///
  /// Everything else is dropped rather than emptied by its reader, so that one
  /// answer covers every part of the editor at once — nothing can quietly read
  /// a heading or a list out of a note whose device has markdown switched off.
  _Parts _tablesOnly() {
    bool inside(int start, int end) {
      for (final table in tables) {
        if (start >= table.start && end <= table.end) return true;
      }
      return false;
    }

    return _Parts(
      spans: [
        for (final span in spans)
          if (inside(span.start, span.end)) span,
      ],
      links: const [],
      tasks: const [],
      blocks: const [],
      conceals: [
        for (final conceal in conceals)
          if (inside(conceal.start, conceal.end)) conceal,
      ],
      ornaments: const [],
      tables: tables,
      listItems: const [],
      atomicPrefixes: const [],
      codeBlocks: const [],
      fencedCode: const [],
      maths: const [],
      lineBreaks: lineBreaks,
      unread: const [],
      literals: const [],
      addresses: const [],
      urls: const [],
      containerMarkers: const [],
    );
  }
}

/// Where a piece of the note may begin: the first line, and every flush-left
/// line after a blank one that is not inside a fenced code block.
///
/// Those are the lines at which the parser has nothing open — the blank line
/// closed whatever was — with the exceptions [MarkdownAnalyzer._continuesInto]
/// checks once the piece before has been read. Fences are tracked here as
/// well as checked there, because a long code block with blank lines in it
/// would otherwise be taken back one piece at a time.
List<int> _chunkStarts(String text) {
  final starts = <int>[0];
  var lineStart = 0;
  var previousBlank = false;
  int? fenceChar;
  var fenceLength = 0;

  while (true) {
    final newline = text.indexOf('\n', lineStart);
    final lineEnd = newline < 0 ? text.length : newline;

    if (fenceChar != null) {
      if (_closesFence(text, lineStart, lineEnd, fenceChar, fenceLength)) {
        fenceChar = null;
      }
      previousBlank = false;
    } else {
      final blank = _isBlankLine(text, lineStart, lineEnd);
      if (!blank &&
          previousBlank &&
          lineStart > 0 &&
          lineStart < text.length &&
          !_isIndentOrBreak(text.codeUnitAt(lineStart))) {
        starts.add(lineStart);
      }
      final opener = _fenceOpener(text, lineStart, lineEnd);
      if (opener != null) {
        fenceChar = opener.$1;
        fenceLength = opener.$2;
      }
      previousBlank = blank;
    }

    if (newline < 0) break;
    lineStart = newline + 1;
  }
  return starts;
}

bool _isShortDashes(String underline) {
  final dashes = underline.trim();
  return dashes.length < 3 && dashes.replaceAll('-', '').isEmpty;
}

bool _isIndentOrBreak(int unit) =>
    unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D;

bool _isSpaceOrTab(int unit) => unit == 0x20 || unit == 0x09;

bool _isBlankLine(String text, int start, int end) {
  for (var i = start; i < end; i++) {
    final unit = text.codeUnitAt(i);
    if (unit == 0x20 || unit == 0x09) continue;
    // A carriage return ends a line for the parser, so only a trailing one
    // is part of a blank line's ending. Anywhere else, calling the line
    // not blank only costs a cut, never a wrong one.
    if (unit == 0x0D && i == end - 1) continue;
    return false;
  }
  return true;
}

/// The fence character and run length if the line opens a fenced code block.
(int, int)? _fenceOpener(String text, int start, int end) {
  var i = start;
  while (i < end && i - start < 3 && text.codeUnitAt(i) == 0x20) {
    i++;
  }
  if (i >= end) return null;
  final char = text.codeUnitAt(i);
  if (char != 0x60 && char != 0x7E) return null;
  var run = i;
  while (run < end && text.codeUnitAt(run) == char) {
    run++;
  }
  final length = run - i;
  if (length < 3) return null;
  // A backtick fence's info string may not hold a backtick; if it does, the
  // line is an inline code span instead.
  if (char == 0x60 && text.substring(run, end).contains('`')) return null;
  return (char, length);
}

bool _closesFence(String text, int start, int end, int char, int length) {
  var i = start;
  while (i < end && i - start < 3 && text.codeUnitAt(i) == 0x20) {
    i++;
  }
  var run = i;
  while (run < end && text.codeUnitAt(run) == char) {
    run++;
  }
  if (run - i < length) return false;
  for (var j = run; j < end; j++) {
    final unit = text.codeUnitAt(j);
    if (unit != 0x20 && unit != 0x09 && unit != 0x0D) return false;
  }
  return true;
}

/// Stands in for a `*` the parser must not see. A private-use character: no
/// markdown meaning, not whitespace, not punctuation, one code unit wide.
const _asteriskMask = 0xE000;

/// Hides every run of `*` that sits between two operands, where it can only
/// be a multiplication sign.
///
/// CommonMark lets `*` open emphasis inside a word, which is what turns
/// `2*3*4` into a two, an italic three and a four — in a note where every
/// line is a calculator. `_` has never been allowed to do that, for the same
/// reason `snake_case` needs it not to, and this holds `*` to the same rule.
/// Brackets count as operands too, so `(2+3)*4*(5)` stays arithmetic rather
/// than becoming an italic four that the calculator would then be told to
/// read past. It costs `un*frigging*believable`, which is a price worth
/// paying here.
///
/// Each hidden `*` becomes [mask], one code unit for one, so every offset
/// stays where it was.
String maskOperatorAsterisks(String source, {int mask = _asteriskMask}) {
  if (!source.contains('*')) return source;
  List<int>? units;
  var i = 0;
  while (i < source.length) {
    if (source.codeUnitAt(i) != 0x2A) {
      i++;
      continue;
    }
    var end = i;
    while (end < source.length && source.codeUnitAt(end) == 0x2A) {
      end++;
    }
    if (i > 0 &&
        end < source.length &&
        _endsOperand(source.codeUnitAt(i - 1)) &&
        _startsOperand(source.codeUnitAt(end))) {
      units ??= List<int>.of(source.codeUnits);
      units.fillRange(i, end, mask);
    }
    i = end;
  }
  return units == null ? source : String.fromCharCodes(units);
}

bool _endsOperand(int unit) =>
    _isWordUnit(unit) ||
    unit == 0x29 || // )
    unit == 0x5D || // ]
    unit == 0x25; // %

bool _startsOperand(int unit) =>
    _isWordUnit(unit) ||
    unit == 0x28 || // (
    unit == 0x5B; // [

final _wordCharacter = RegExp(r'[\p{L}\p{N}]', unicode: true);

bool _isWordUnit(int unit) {
  if ((unit >= 0x30 && unit <= 0x39) ||
      (unit >= 0x41 && unit <= 0x5A) ||
      (unit >= 0x61 && unit <= 0x7A)) {
    return true;
  }
  if (unit < 0x80 || (unit >= 0xD800 && unit <= 0xDFFF)) return false;
  return _wordCharacter.hasMatch(String.fromCharCode(unit));
}

String _unmask(String value) =>
    value.contains('') ? value.replaceAll('', '*') : value;

/// A link's address with its masked `*` restored, which the parser has by
/// then percent-encoded as it does any character outside ASCII.
String _unmaskAddress(String address) =>
    _unmask(address).replaceAll('%EE%80%80', '*');

_Parts _parse(String source) {
  if (source.isEmpty) return _Parts.empty;
  final document = md.Markdown(
    enableTaskList: true,
    // Extensions beyond CommonMark and GitHub's: `:smile:` shortcodes, and a
    // `>>>` quote fence nothing else reads.
    enableEmoji: false,
    enableFencedBlockquote: false,
    extensions: [const _DisplayMathSyntax(), _InlineMathSyntax(), _WordRun()],
  );
  final List<md.Node> nodes;
  try {
    nodes = document.parse(maskOperatorAsterisks(source));
  } catch (error, stack) {
    // A parser fault must cost the note its styling, never its text: the
    // piece simply draws as plain writing.
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'Kapy Notes editor',
        context: ErrorDescription('while reading a note as markdown'),
      ),
    );
    return _Parts.empty;
  }

  final collector = _Collector(source);
  for (final node in nodes) {
    collector.visit(node, quoteDepth: 0, listDepth: 0);
  }
  return collector.finish(
    tail: _tailOf(nodes),
    hasReferences: document.linkReferences.isNotEmpty,
  );
}

_Tail _tailOf(List<md.Node> nodes) {
  if (nodes.isEmpty) return _Tail.closed;
  final last = nodes.last;
  if (last is! md.Element) return _Tail.closed;
  return switch (last.type) {
    'fencedCodeBlock' => last.markers.length < 2 ? _Tail.open : _Tail.closed,
    'htmlBlock' => _Tail.open,
    'bulletList' || 'orderedList' => _Tail.list,
    _ => _Tail.closed,
  };
}

const _dollar = 0x24;
const _backslash = 0x5C;

bool _isWhitespace(int unit) =>
    unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D;

/// Math among words, by pandoc's rules: `$…$`, and `$$…$$`.
///
/// The opening `$` of `$…$` has something other than a space after it, and
/// the closing one something other than a space before it and no digit after
/// it, which is what keeps `$5 and $10` two prices rather than one formula.
/// A backslash keeps the character after it, so `\$` inside a formula is a
/// dollar sign rather than its end, and `\text{…}` may hold dollar signs of
/// its own. `$$…$$` ends at the next `$$`.
class _InlineMathSyntax extends md.InlineSyntax {
  _InlineMathSyntax() : super(RegExp(r'\$'), startCharacter: _dollar);

  @override
  md.InlineObject? parse(md.InlineParser parser, Match match) {
    final start = parser.position;
    final doubled =
        start + 1 < parser.length && parser.charAt(start + 1) == _dollar;
    final marker = doubled ? 2 : 1;
    final close = doubled
        ? _doubledClose(parser, start + 2)
        : _close(parser, start + 1);
    // Left where it was, the parser goes on to read the `$` as text.
    if (close == null) return null;
    final markers = parser.consumeBy(marker);
    final content = parser.consumeBy(close - start - marker);
    markers.addAll(parser.consumeBy(marker));
    return md.InlineElement(
      'math',
      markers: markers,
      children: [for (final span in content) md.Text.fromSpan(span)],
      start: markers.first.start,
      end: markers.last.end,
    );
  }

  static int? _close(md.InlineParser parser, int from) {
    final length = parser.length;
    if (from >= length || _isWhitespace(parser.charAt(from))) return null;
    var i = from;
    while (i < length) {
      final unit = parser.charAt(i);
      if (unit == _dollar) {
        if (i + 1 < length && _isDigit(parser.charAt(i + 1))) return null;
        return i;
      }
      if (unit == _backslash) {
        i = _afterEscape(parser, i);
      } else if (_isWhitespace(unit)) {
        while (i < length && _isWhitespace(parser.charAt(i))) {
          i++;
        }
        if (i < length && parser.charAt(i) == _dollar) return null;
      } else {
        i++;
      }
    }
    return null;
  }

  static int? _doubledClose(md.InlineParser parser, int from) {
    final length = parser.length;
    var blank = true;
    var i = from;
    while (i + 1 < length) {
      final unit = parser.charAt(i);
      if (unit == _dollar && parser.charAt(i + 1) == _dollar) {
        return blank ? null : i;
      }
      if (!_isWhitespace(unit)) blank = false;
      i = unit == _backslash ? i + 2 : i + 1;
    }
    return null;
  }

  /// Past the escape at [at]: the backslash and the character after it, or
  /// a whole `\text{…}` with its braces balanced.
  static int _afterEscape(md.InlineParser parser, int at) {
    const text = r'\text{';
    final length = parser.length;
    if (at + text.length <= length &&
        parser.substring(at, at + text.length) == text) {
      var depth = 0;
      for (var i = at + text.length - 1; i < length; i++) {
        final unit = parser.charAt(i);
        if (unit == _backslash) {
          i++;
        } else if (unit == 0x7B) {
          depth++;
        } else if (unit == 0x7D && --depth == 0) {
          return i + 1;
        }
      }
    }
    return at + 2 < length ? at + 2 : length;
  }

  static bool _isDigit(int unit) => unit >= 0x30 && unit <= 0x39;
}

/// Words and the spaces between them, passed over as one run of text.
///
/// The parser does this itself until it is given a syntax of its own, and
/// then goes a word at a time, in case that syntax starts at a space or a
/// letter, which [_InlineMathSyntax] never does. A word at a time, each word
/// of a note is cut out as text of its own, placed by counting from the start
/// of its line, and reading a long note takes more than twice as long.
class _WordRun extends md.InlineSyntax {
  _WordRun() : super(RegExp(r'[ \tA-Za-z0-9]*[A-Za-z0-9](?=\s)'));

  @override
  md.InlineObject? parse(md.InlineParser parser, Match match) {
    parser.advanceBy(match[0]!.length);
    return null;
  }
}

/// Display math: `$$` at the start of a line, and the TeX up to the `$$`
/// that closes it at the end of one, the same line or a later one.
///
/// Pandoc reads `$$…$$` wherever it is written. Read as a block, the lines
/// between are TeX rather than markdown, so the `- b` of an aligned equation
/// stays a line of it rather than starting a list. As in pandoc there is no
/// blank line inside one. A `$$` closed anywhere but the end of a line, as in
/// `$$x$$ and more`, is math among words, and left to [_InlineMathSyntax].
class _DisplayMathSyntax extends md.BlockSyntax {
  const _DisplayMathSyntax();

  static final _opening = RegExp(r'^ {0,3}\$\$');

  @override
  RegExp get pattern => _opening;

  @override
  bool canParse(md.BlockParser parser) => _close(parser) != null;

  @override
  md.BlockElement? parse(md.BlockParser parser) {
    final close = _close(parser);
    if (close == null) return null;
    final (last, column) = close;
    final open = _opening.matchAsPrefix(parser.current.content.text)!;
    final markers = [
      md.Text.fromSpan(parser.current.content).subText(open.end - 2, open.end),
    ];
    final children = <md.Node>[];
    for (var line = 0; line <= last; line++) {
      final content = md.Text.fromSpan(parser.current.content);
      final from = line == 0 ? open.end : 0;
      final to = line == last ? column : content.length;
      if (to > from) children.add(content.subText(from, to));
      if (line == last) markers.add(content.subText(column, column + 2));
      parser.advance();
    }
    return md.BlockElement(
      'displayMath',
      markers: markers,
      children: children,
      start: markers.first.start,
      end: markers.last.end,
    );
  }

  /// The line, counted from the current one, and the column of the `$$` that
  /// closes the formula the current line opens, if it opens one.
  static (int, int)? _close(md.BlockParser parser) {
    final open = _opening.matchAsPrefix(parser.current.content.text);
    if (open == null) return null;
    var blank = true;
    for (var ahead = 0; ; ahead++) {
      final line = parser.peek(ahead);
      if (line == null || (ahead > 0 && line.isBlankLine)) return null;
      final text = line.content.text;
      var i = ahead == 0 ? open.end : 0;
      while (i < text.length) {
        final unit = text.codeUnitAt(i);
        if (unit == _dollar &&
            i + 1 < text.length &&
            text.codeUnitAt(i + 1) == _dollar) {
          if (blank || text.substring(i + 2).trim().isNotEmpty) return null;
          return (ahead, i);
        }
        if (!_isWhitespace(unit)) blank = false;
        i = unit == _backslash ? i + 2 : i + 1;
      }
    }
  }
}

/// Walks the parser's tree and flattens it into what the editor draws.
class _Collector {
  _Collector(this.source);

  final String source;
  final _spans = <MarkdownSpan>[];
  final _links = <MarkdownLink>[];
  final _tasks = <MarkdownTask>[];
  final _blocks = <MarkdownBlock>[];
  final _conceals = <MarkdownConceal>[];
  final _ornaments = <MarkdownOrnament>[];
  final _tables = <MarkdownTable>[];
  final _listItems = <MarkdownListItem>[];
  final _codeBlocks = <TextRange>[];
  final _fencedCode = <MarkdownCodeBlock>[];
  final _maths = <MarkdownMath>[];
  final _lineBreaks = <TextRange>[];
  final _unread = <TextRange>[];
  final _literals = <TextRange>[];
  final _addresses = <TextRange>[];
  final _urls = <TextRange>[];
  final _containerMarkers = <TextRange>[];

  /// Ordered list numbers: shown, but part of the structure the caret steps
  /// over like any other line prefix.
  final _numbers = <TextRange>[];

  /// Where each `<u>`, `<sup>` and the like that is one of a pair starts.
  final _pairedTags = <int>{};

  _Parts finish({required _Tail tail, required bool hasReferences}) {
    _spans.sort((a, b) => a.start.compareTo(b.start));
    _links.sort((a, b) => a.start.compareTo(b.start));
    _tasks.sort((a, b) => a.box.compareTo(b.box));
    _blocks.sort((a, b) => a.start.compareTo(b.start));
    _conceals.sort((a, b) => a.start.compareTo(b.start));
    _ornaments.sort((a, b) => a.start.compareTo(b.start));
    _tables.sort((a, b) => a.start.compareTo(b.start));
    _listItems.sort((a, b) => a.markerStart.compareTo(b.markerStart));
    _maths.sort((a, b) => a.start.compareTo(b.start));
    for (final ranges in [
      _codeBlocks,
      _lineBreaks,
      _unread,
      _literals,
      _addresses,
      _urls,
      _containerMarkers,
    ]) {
      ranges.sort((a, b) => a.start.compareTo(b.start));
    }
    return _Parts(
      spans: List.unmodifiable(_spans),
      links: List.unmodifiable(_links),
      tasks: List.unmodifiable(_tasks),
      blocks: List.unmodifiable(_blocks),
      conceals: List.unmodifiable(_conceals),
      ornaments: List.unmodifiable(_ornaments),
      tables: List.unmodifiable(_tables),
      listItems: List.unmodifiable(_listItems),
      atomicPrefixes: List.unmodifiable(_atomicPrefixes()),
      codeBlocks: List.unmodifiable(_codeBlocks),
      fencedCode: List.unmodifiable(_fencedCode),
      maths: List.unmodifiable(_maths),
      lineBreaks: List.unmodifiable(_lineBreaks),
      unread: List.unmodifiable(_unread),
      literals: List.unmodifiable(_literals),
      addresses: List.unmodifiable(_addresses),
      urls: List.unmodifiable(_urls),
      containerMarkers: List.unmodifiable(_containerMarkers),
      tail: tail,
      hasReferences: hasReferences,
    );
  }

  /// For every line that starts with hidden structure, from the line's start
  /// to where its words begin.
  ///
  /// Walked from the start of the line: whitespace, then each piece of
  /// structure that begins exactly where the last left off — a quote marker,
  /// a bullet, a box, a number, a heading's `#` — until something that is
  /// none of them. That is where the words start, and where the caret goes.
  List<TextRange> _atomicPrefixes() {
    final pieces = <int, int>{
      for (final conceal in _conceals)
        if (conceal.reveal == MarkdownReveal.never) conceal.start: conceal.end,
      for (final ornament in _ornaments)
        if (ornament.kind != MarkdownOrnamentKind.codeSpan)
          ornament.start: ornament.end,
      for (final number in _numbers) number.start: number.end,
    };
    final lines = <int>{
      for (final start in pieces.keys)
        start == 0 ? 0 : source.lastIndexOf('\n', start - 1) + 1,
    }.toList()..sort();

    final prefixes = <TextRange>[];
    for (final lineStart in lines) {
      var at = lineStart;
      var consumed = false;
      while (true) {
        while (at < source.length && _isSpaceOrTab(source.codeUnitAt(at))) {
          at++;
        }
        final end = pieces[at];
        if (end == null || end <= at) break;
        at = end;
        consumed = true;
      }
      if (consumed) prefixes.add(TextRange(start: lineStart, end: at));
    }
    return prefixes;
  }

  int _clamp(int value) => value < 0
      ? 0
      : value > source.length
      ? source.length
      : value;

  TextRange? _range(int start, int end) {
    final from = _clamp(start);
    final to = _clamp(end);
    return to > from ? TextRange(start: from, end: to) : null;
  }

  void _style(int start, int end, MarkdownStyle style) {
    final range = _range(start, end);
    if (range != null) {
      _spans.add(MarkdownSpan(range.start, range.end, style));
    }
  }

  void _record(List<TextRange> into, int start, int end) {
    final range = _range(start, end);
    if (range != null) into.add(range);
  }

  void _conceal(
    int start,
    int end,
    MarkdownReveal reveal, {
    required int scopeStart,
    required int scopeEnd,
    int? innerStart,
    int? innerEnd,
  }) {
    final range = _range(start, end);
    if (range == null) return;
    _conceals.add(
      MarkdownConceal(
        range.start,
        range.end,
        reveal,
        scopeStart: _clamp(scopeStart),
        scopeEnd: _clamp(scopeEnd),
        innerStart: innerStart == null ? null : _clamp(innerStart),
        innerEnd: innerEnd == null ? null : _clamp(innerEnd),
      ),
    );
  }

  /// Hides the markers at either end of an inline element, to be shown with
  /// the caret against them.
  void _concealEnds(md.Element node) {
    final markers = node.markers;
    if (markers.length < 2) return;
    final open = markers.first;
    final close = markers.last;
    for (final marker in [open, close]) {
      _conceal(
        marker.start.offset,
        marker.end.offset,
        MarkdownReveal.edges,
        scopeStart: node.start.offset,
        scopeEnd: node.end.offset,
        innerStart: open.end.offset,
        innerEnd: close.start.offset,
      );
    }
  }

  /// Offset of the first character after [from] that is not a space or tab.
  int _skipSpaces(int from) {
    var at = from;
    while (at < source.length && _isSpaceOrTab(source.codeUnitAt(at))) {
      at++;
    }
    return at;
  }

  bool _spaceAfter(int offset) =>
      offset < source.length && _isSpaceOrTab(source.codeUnitAt(offset));

  void visit(md.Node node, {required int quoteDepth, required int listDepth}) {
    if (node is! md.Element) return;
    final start = node.start.offset;
    final end = node.end.offset;
    final markers = node.markers;
    // Markers not claimed below are syntax: that covers every marker of the
    // plain cases and the backslash of every escape, which the parser files
    // under the element the escape sits in. Claimed by where they start,
    // which no two markers share.
    final claimed = <int>{};
    var childQuoteDepth = quoteDepth;
    var childListDepth = listDepth;

    switch (node.type) {
      case 'atxHeading':
        _style(start, end, _headingStyle(_level(node)));
        if (markers.isNotEmpty) {
          final open = markers.first;
          claimed.add(open.start.offset);
          _style(open.start.offset, open.end.offset, MarkdownStyle.syntax);
          // `#` alone is a heading still being typed — or `#hashtag` about
          // to be — and stays in sight. With its space it is a heading, and
          // the `#` and the space go.
          if (_spaceAfter(open.end.offset)) {
            _conceal(
              open.start.offset,
              _skipSpaces(open.end.offset),
              MarkdownReveal.never,
              scopeStart: start,
              scopeEnd: end,
            );
          }
          // A closing run of `#`, if the heading has one.
          final words = node.children;
          final wordsEnd = words.isEmpty
              ? open.end.offset
              : words.last.end.offset;
          for (final marker in markers.skip(1)) {
            if (marker.text != '#' * marker.text.length) continue;
            claimed.add(marker.start.offset);
            _style(
              marker.start.offset,
              marker.end.offset,
              MarkdownStyle.syntax,
            );
            _conceal(
              marker.start.offset,
              marker.end.offset,
              MarkdownReveal.edges,
              scopeStart: wordsEnd,
              scopeEnd: marker.end.offset,
            );
          }
        }
      case 'setextHeading':
        // The underline is the last marker; the heading is what it underlines.
        final underline = markers.isEmpty ? null : markers.last;
        // `-` and `--` under a line of words are a bullet or a divider being
        // typed, not an underline: read as one, the line above would turn
        // into a heading and back with every key.
        if (underline != null && _isShortDashes(underline.text)) {
          claimed.add(underline.start.offset);
          break;
        }
        _style(
          start,
          underline?.start.offset ?? end,
          _headingStyle(_level(node)),
        );
        if (underline != null) {
          claimed.add(underline.start.offset);
          _style(
            underline.start.offset,
            underline.end.offset,
            MarkdownStyle.syntax,
          );
          // Shown with the caret anywhere in the heading: on a line of its
          // own, showing it moves nothing.
          _conceal(
            underline.start.offset,
            underline.end.offset,
            MarkdownReveal.block,
            scopeStart: start,
            scopeEnd: end,
          );
          // Drawn as the rule GitHub puts under its first two levels.
          _blocks.add(
            MarkdownBlock(
              MarkdownBlockKind.rule,
              _clamp(underline.start.offset),
              _clamp(underline.end.offset),
            ),
          );
        }
      case 'blockquote':
        childQuoteDepth = quoteDepth + 1;
        _style(start, end, MarkdownStyle.quote);
        _blocks.add(
          MarkdownBlock(
            MarkdownBlockKind.quote,
            _clamp(start),
            _clamp(end),
            depth: childQuoteDepth,
          ),
        );
        for (final marker in markers) {
          if (marker.text != '>') continue;
          claimed.add(marker.start.offset);
          _style(marker.start.offset, marker.end.offset, MarkdownStyle.syntax);
          _record(_containerMarkers, marker.start.offset, marker.end.offset);
          // The bar beside the quote says what the `>` did.
          _conceal(
            marker.start.offset,
            marker.end.offset + (_spaceAfter(marker.end.offset) ? 1 : 0),
            MarkdownReveal.never,
            scopeStart: start,
            scopeEnd: end,
          );
        }
      case 'bulletList' || 'orderedList':
        // Items take the list's depth; lists inside them go one deeper.
        break;
      case 'listItem':
        childListDepth = listDepth + 1;
        _listItem(node, claimed, depth: listDepth, quoted: quoteDepth > 0);
      case 'fencedCodeBlock' || 'indentedCodeBlock':
        _style(start, end, MarkdownStyle.codeBlock);
        _record(_codeBlocks, start, end);
        _record(_literals, start, end);
        final language = node.attributes['language'];
        if (language != null && language.isNotEmpty) {
          final code = [
            for (final line in node.children)
              ?_range(line.start.offset, line.end.offset),
          ];
          if (code.isNotEmpty) {
            _fencedCode.add(
              MarkdownCodeBlock(_unmask(language), List.unmodifiable(code)),
            );
          }
        }
        _blocks.add(
          MarkdownBlock(MarkdownBlockKind.code, _clamp(start), _clamp(end)),
        );
        for (final marker in markers) {
          claimed.add(marker.start.offset);
          _style(marker.start.offset, marker.end.offset, MarkdownStyle.syntax);
          _conceal(
            marker.start.offset,
            marker.end.offset,
            MarkdownReveal.block,
            scopeStart: start,
            scopeEnd: end,
          );
        }
      case 'thematicBreak':
        _blocks.add(
          MarkdownBlock(MarkdownBlockKind.rule, _clamp(start), _clamp(end)),
        );
        for (final marker in markers) {
          claimed.add(marker.start.offset);
          _style(marker.start.offset, marker.end.offset, MarkdownStyle.syntax);
          _conceal(
            marker.start.offset,
            marker.end.offset,
            MarkdownReveal.block,
            scopeStart: start,
            scopeEnd: end,
          );
        }
      case 'table':
        _table(node);
      case 'tableHeadCell':
        _style(start, end, MarkdownStyle.tableHeader);
      case 'htmlBlock' || 'rawHtml':
        _style(
          start,
          end,
          _pairedTags.contains(start)
              ? MarkdownStyle.syntax
              : MarkdownStyle.html,
        );
        _record(_literals, start, end);
        if (_inTable(start) &&
            _lineBreakTag.hasMatch(
              source.substring(_clamp(start), _clamp(end)),
            )) {
          _record(_lineBreaks, start, end);
        }
      case 'math' || 'displayMath':
        _math(node, claimed);
      case 'linkReferenceDefinition':
        // Bookkeeping, not writing: GitHub shows none of it, and neither does
        // this until the caret is on it.
        _style(start, end, MarkdownStyle.syntax);
        _conceal(
          start,
          end,
          MarkdownReveal.block,
          scopeStart: start,
          scopeEnd: end,
        );
        for (final child in node.children) {
          if (child is md.Element &&
              child.type == 'linkReferenceDefinitionDestination') {
            _record(_addresses, child.start.offset, child.end.offset);
          }
        }
        for (final marker in markers) {
          claimed.add(marker.start.offset);
        }
      case 'emphasis' || 'strongEmphasis':
        _style(
          start,
          end,
          node.type == 'emphasis'
              ? MarkdownStyle.emphasis
              : MarkdownStyle.strong,
        );
        // The delimiters are the first marker and the last; any between are
        // escapes inside the words, which stay.
        if (markers.length >= 2) {
          for (final marker in [markers.first, markers.last]) {
            claimed.add(marker.start.offset);
            _style(
              marker.start.offset,
              marker.end.offset,
              MarkdownStyle.syntax,
            );
            _record(_unread, marker.start.offset, marker.end.offset);
          }
          _concealEnds(node);
        }
      case 'strikethrough':
        _style(start, end, MarkdownStyle.strikethrough);
        _record(_unread, start, end);
        if (markers.length >= 2) {
          for (final marker in [markers.first, markers.last]) {
            claimed.add(marker.start.offset);
            _style(
              marker.start.offset,
              marker.end.offset,
              MarkdownStyle.syntax,
            );
          }
          _concealEnds(node);
        }
      case 'codeSpan':
        _style(start, end, MarkdownStyle.code);
        _record(_literals, start, end);
        if (markers.length >= 2) {
          for (final marker in [markers.first, markers.last]) {
            claimed.add(marker.start.offset);
            _style(
              marker.start.offset,
              marker.end.offset,
              MarkdownStyle.syntax,
            );
          }
          _concealEnds(node);
          final words = _range(
            markers.first.end.offset,
            markers.last.start.offset,
          );
          if (words != null) {
            _ornaments.add(
              MarkdownOrnament(
                MarkdownOrnamentKind.codeSpan,
                words.start,
                words.end,
              ),
            );
          }
        }
      case 'link' || 'image':
        _link(node, claimed);
      case 'autolink':
        if (markers.length >= 2) {
          final from = markers.first.end.offset;
          final to = markers.last.start.offset;
          _style(from, to, MarkdownStyle.link);
          _record(_urls, from, to);
          final destination = node.attributes['destination'];
          if (destination != null && to > from) {
            _links.add(
              MarkdownLink(
                _clamp(from),
                _clamp(to),
                _unmaskAddress(destination),
              ),
            );
          }
          for (final marker in [markers.first, markers.last]) {
            claimed.add(marker.start.offset);
            _style(
              marker.start.offset,
              marker.end.offset,
              MarkdownStyle.syntax,
            );
          }
          _concealEnds(node);
        }
      case 'autolinkExtension':
        // A bare address. The note's own link detection already draws and
        // opens these by rules the app has always used; markdown only needs
        // to keep spelling off it.
        _record(_urls, start, end);
    }

    for (final marker in markers) {
      if (claimed.contains(marker.start.offset)) continue;
      _style(marker.start.offset, marker.end.offset, MarkdownStyle.syntax);
      // What is left is an escape's backslash, or a hard line break's: shown
      // with the caret against it, like any other inline marker, and not
      // read by the calculator, so `\- 5` is the minus five it shows.
      if (marker.text == r'\') {
        _record(_unread, marker.start.offset, marker.end.offset);
        _conceal(
          marker.start.offset,
          marker.end.offset,
          MarkdownReveal.edges,
          scopeStart: marker.start.offset,
          scopeEnd: marker.end.offset + 1,
          innerStart: marker.end.offset,
          innerEnd: marker.end.offset + 1,
        );
      }
    }
    _pairTags(node.children);
    for (final child in node.children) {
      visit(child, quoteDepth: childQuoteDepth, listDepth: childListDepth);
    }
  }

  /// Whether [offset] is in the table being read: a cell's words are drawn by
  /// its grid, which shows a formula as its TeX and a `<br>` as a line break.
  bool _inTable(int offset) =>
      _tables.isNotEmpty &&
      offset >= _tables.last.start &&
      offset < _tables.last.end;

  /// A formula: its TeX shown as code with its dollar signs quiet, and
  /// outside a table the formula itself, which the editor draws in place of
  /// all of it.
  void _math(md.Element node, Set<int> claimed) {
    final start = node.start.offset;
    final end = node.end.offset;
    _style(start, end, MarkdownStyle.math);
    _record(_literals, start, end);
    for (final marker in node.markers) {
      claimed.add(marker.start.offset);
      _style(marker.start.offset, marker.end.offset, MarkdownStyle.syntax);
    }
    final range = _range(start, end);
    if (range == null || _inTable(start)) return;
    final display = node.type == 'displayMath';
    final tex = _unmask(
      node.children.map((piece) => piece.textContent).join(display ? '\n' : ''),
    ).trim();
    if (tex.isEmpty) return;
    _maths.add(MarkdownMath(range.start, range.end, tex, display: display));
  }

  /// `<u>`, `<ins>`, `<sup>` and `<sub>`, opening and closing among the
  /// same words. Their words are drawn the way the tags ask, and the tags are
  /// hidden like any other inline marker. One that crosses another, or is
  /// never closed, stays the HTML it is written as.
  void _pairTags(List<md.Node> nodes) {
    final open = <(String, md.Element)>[];
    for (final node in nodes) {
      if (node is! md.Element || node.type != 'rawHtml') continue;
      final tag = _pairedTag.firstMatch(
        source.substring(_clamp(node.start.offset), _clamp(node.end.offset)),
      );
      if (tag == null) continue;
      final name = tag[2]!.toLowerCase();
      if (tag[1]!.isEmpty) {
        open.add((name, node));
        continue;
      }
      final at = open.lastIndexWhere((opening) => opening.$1 == name);
      if (at < 0) continue;
      final opening = open[at].$2;
      open.removeRange(at, open.length);
      final scopeStart = opening.start.offset;
      final scopeEnd = node.end.offset;
      final innerStart = opening.end.offset;
      final innerEnd = node.start.offset;
      _style(innerStart, innerEnd, switch (name) {
        'sup' => MarkdownStyle.superscript,
        'sub' => MarkdownStyle.subscript,
        _ => MarkdownStyle.underline,
      });
      for (final marker in [opening, node]) {
        _pairedTags.add(marker.start.offset);
        _record(_unread, marker.start.offset, marker.end.offset);
        _conceal(
          marker.start.offset,
          marker.end.offset,
          MarkdownReveal.edges,
          scopeStart: scopeStart,
          scopeEnd: scopeEnd,
          innerStart: innerStart,
          innerEnd: innerEnd,
        );
      }
    }
  }

  static final _pairedTag = RegExp(
    r'^<(/?)(u|ins|sup|sub)>$',
    caseSensitive: false,
  );

  static final _lineBreakTag = RegExp(r'^<br\s*/?>$', caseSensitive: false);

  void _listItem(
    md.Element node,
    Set<int> claimed, {
    required int depth,
    required bool quoted,
  }) {
    final markers = node.markers;
    if (markers.isEmpty) return;
    final marker = markers.first;
    claimed.add(marker.start.offset);
    _record(_containerMarkers, marker.start.offset, marker.end.offset);
    final ordered = node.attributes.containsKey('number');
    // A bare `-` at the end of a line is a list item to CommonMark, and is
    // also the first key of `-5`. Only with its space is it drawn as a list.
    final spaced = _spaceAfter(marker.end.offset);
    final task = node.attributes['taskListItem'];

    if (task != null && markers.length > 1) {
      final box = markers[1];
      claimed.add(box.start.offset);
      _record(_containerMarkers, box.start.offset, box.end.offset);
      _style(box.start.offset, box.end.offset, MarkdownStyle.taskBox);
      _tasks.add(
        MarkdownTask(_clamp(box.start.offset), checked: task == 'checked'),
      );
      _ornaments.add(
        MarkdownOrnament(
          MarkdownOrnamentKind.checkbox,
          _clamp(box.start.offset),
          _clamp(box.end.offset),
          checked: task == 'checked',
        ),
      );
      if (ordered) {
        _style(
          marker.start.offset,
          marker.end.offset,
          MarkdownStyle.listMarker,
        );
        _record(_numbers, marker.start.offset, marker.end.offset);
      } else {
        // A task is its box; the bullet in front of it is not drawn at all.
        _conceal(
          marker.start.offset,
          box.start.offset,
          MarkdownReveal.never,
          scopeStart: node.start.offset,
          scopeEnd: node.end.offset,
        );
      }
      if (task == 'checked') {
        final words = _ownWords(node);
        if (words != null) {
          _style(words.start, words.end, MarkdownStyle.doneTask);
        }
      }
      _recordItem(
        marker.start.offset,
        marker.end.offset,
        wordsStart: _skipSpaces(box.end.offset),
        box: box.start.offset,
        ordered: ordered,
        depth: depth,
        quoted: quoted,
      );
      return;
    }

    if (!spaced) return;
    _recordItem(
      marker.start.offset,
      marker.end.offset,
      wordsStart: _skipSpaces(marker.end.offset),
      ordered: ordered,
      depth: depth,
      quoted: quoted,
    );
    if (ordered) {
      _style(marker.start.offset, marker.end.offset, MarkdownStyle.listMarker);
      _record(_numbers, marker.start.offset, marker.end.offset);
    } else {
      // With the spaces after it, so it ends where the words begin and a
      // bullet can be drawn a set distance before them.
      _ornaments.add(
        MarkdownOrnament(
          MarkdownOrnamentKind.bullet,
          _clamp(marker.start.offset),
          _clamp(_skipSpaces(marker.end.offset)),
          depth: depth,
        ),
      );
    }
  }

  void _recordItem(
    int markerStart,
    int markerEnd, {
    required int wordsStart,
    required bool ordered,
    required int depth,
    required bool quoted,
    int? box,
  }) {
    final start = _clamp(markerStart);
    _listItems.add(
      MarkdownListItem(
        lineStart: start == 0 ? 0 : source.lastIndexOf('\n', start - 1) + 1,
        markerStart: start,
        markerEnd: _clamp(markerEnd),
        wordsStart: _clamp(wordsStart),
        depth: depth,
        box: box == null ? null : _clamp(box),
        ordered: ordered,
        quoted: quoted,
      ),
    );
  }

  void _table(md.Element node) {
    final markers = node.markers;
    final rows = <MarkdownTableRow>[];
    var aligns = <MarkdownCellAlign>[];
    for (final section in node.children) {
      if (section is! md.Element) continue;
      final header = section.type == 'tableHead';
      for (final row in section.children) {
        if (row is! md.Element || row.type != 'tableRow') continue;
        final cells = <MarkdownTableCell>[];
        for (final cell in row.children) {
          if (cell is! md.Element) continue;
          cells.add(
            MarkdownTableCell(
              _clamp(cell.start.offset),
              _clamp(cell.end.offset),
              _unmask(cell.textContent).trim(),
            ),
          );
          if (header) {
            aligns.add(switch (cell.attributes['textAlign']) {
              'center' => MarkdownCellAlign.center,
              'right' => MarkdownCellAlign.end,
              _ => MarkdownCellAlign.start,
            });
          }
        }
        rows.add(
          MarkdownTableRow(
            _clamp(row.start.offset),
            _clamp(row.end.offset),
            List.unmodifiable(cells),
            header: header,
          ),
        );
      }
    }
    if (rows.isEmpty) return;
    final delimiter = markers.isEmpty ? null : markers.first;
    aligns = List.unmodifiable(aligns);
    _tables.add(
      MarkdownTable(
        _clamp(node.start.offset),
        _clamp(node.end.offset),
        rows: List.unmodifiable(rows),
        aligns: aligns,
        delimiterStart: _clamp(delimiter?.start.offset ?? node.start.offset),
        delimiterEnd: _clamp(delimiter?.end.offset ?? node.start.offset),
      ),
    );
  }

  /// `[words](address "title")`, `[words][label]`, `![alt](address)`.
  void _link(md.Element node, Set<int> claimed) {
    final markers = node.markers;
    if (markers.isEmpty) return;
    final isImage = node.type == 'image';

    // Where the words end, and where the address between the parentheses
    // begins and ends, by the brackets around them. The last `)` is the one
    // that closes: a title may hold one of its own.
    int? close;
    int? addressStart;
    int? addressEnd;
    for (final marker in markers.skip(1)) {
      if (close == null && marker.text == ']') {
        close = marker.start.offset;
      } else if (close != null && addressStart == null && marker.text == '(') {
        addressStart = marker.end.offset;
      } else if (addressStart != null && marker.text == ')') {
        addressEnd = marker.start.offset;
      }
    }

    var wordsStart = markers.first.end.offset;
    var wordsEnd = close ?? wordsStart;
    if (isImage) {
      // The parser files an image's alt text as a marker rather than as
      // children. It is the words of this link, not its punctuation.
      for (final marker in markers.skip(1)) {
        if (marker.start.offset == wordsStart &&
            marker.end.offset == wordsEnd) {
          claimed.add(marker.start.offset);
        }
      }
    }
    // Everything but the words is hidden, to be shown with the caret at
    // either end of them.
    for (final marker in markers) {
      if (claimed.contains(marker.start.offset)) continue;
      claimed.add(marker.start.offset);
      _style(marker.start.offset, marker.end.offset, MarkdownStyle.syntax);
      _conceal(
        marker.start.offset,
        marker.end.offset,
        MarkdownReveal.edges,
        scopeStart: node.start.offset,
        scopeEnd: node.end.offset,
        innerStart: wordsStart,
        innerEnd: wordsEnd,
      );
    }
    // A title between the address and the `)` is not a marker of its own.
    if (addressStart != null && addressEnd != null) {
      _record(_addresses, addressStart, addressEnd);
      _conceal(
        addressStart,
        addressEnd,
        MarkdownReveal.edges,
        scopeStart: node.start.offset,
        scopeEnd: node.end.offset,
        innerStart: wordsStart,
        innerEnd: wordsEnd,
      );
    }
    if (wordsEnd <= wordsStart) {
      // `[](address)` has no words to click, so the whole link is the target.
      wordsStart = node.start.offset;
      wordsEnd = node.end.offset;
    } else {
      _style(wordsStart, wordsEnd, MarkdownStyle.link);
    }
    final destination = node.attributes['destination'];
    if (destination != null) {
      final from = _clamp(wordsStart);
      final to = _clamp(wordsEnd);
      if (to > from) {
        _links.add(MarkdownLink(from, to, _unmaskAddress(destination)));
      }
    }
  }

  /// A list item's own words: the text up to where a nested list or any
  /// other block of its own begins.
  TextRange? _ownWords(md.Element item) {
    int? from;
    int? to;
    for (final child in item.children) {
      if (child is md.Text || (child is md.Element && !child.isBlock)) {
        from ??= child.start.offset;
        to = child.end.offset;
        continue;
      }
      if (from == null && child is md.Element && child.type == 'paragraph') {
        from = child.start.offset;
        to = child.end.offset;
      }
      break;
    }
    if (from == null || to == null) return null;
    return _range(from, to);
  }

  static int _level(md.Element heading) =>
      (int.tryParse(heading.attributes['level'] ?? '') ?? 1).clamp(1, 6);
}
