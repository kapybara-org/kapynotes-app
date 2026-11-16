import 'dart:convert';

import 'package:dart_markdown/dart_markdown.dart' as md;

import 'html_reader.dart';
import 'paste_tree.dart';

final _strongSignals = [
  RegExp(r'^ {0,3}(`{3,}|~{3,})', multiLine: true),
  RegExp(
    r'^ {0,3}\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$',
    multiLine: true,
  ),
  RegExp(r'!\[[^\]\n]*\]\([^)\s]+\)'),
];
final _headingLine = RegExp(r'^#{1,6} \S', multiLine: true);
final _listLine = RegExp(r'^ {0,8}([-*+]|\d{1,3}[.)]) \S', multiLine: true);
final _quoteLine = RegExp(r'^ {0,3}> ', multiLine: true);
final _strong = RegExp(r'(\*\*|__)\S[^*\n]*?\S?\1');
final _inlineLink = RegExp(r'\[[^\]\n]+\]\((https?://|mailto:|/|#)[^)\s]*\)');
final _codeSpan = RegExp(r'`[^`\n]+`');
final _texMath = RegExp(r'\$\$|\\\[|\\\(');

/// Whether plain text was written in markdown — an AI's copy button, a
/// README, another markdown app — rather than merely containing a star.
///
/// One unmistakable sign is enough (a fence, a table's delimiter row, a
/// linked picture); otherwise the signs have to add up, so that a pasted
/// "- 5" or a lone *word* stays the plain text it was.
bool looksLikeMarkdown(String text) {
  final sample = text.length > 200000 ? text.substring(0, 200000) : text;
  if (_strongSignals.any((signal) => signal.hasMatch(sample))) return true;
  var score = 0;
  score += _headingLine.allMatches(sample).take(2).length * 2;
  score += _listLine.allMatches(sample).take(3).length;
  score += _quoteLine.allMatches(sample).take(2).length;
  score += _strong.allMatches(sample).take(2).length * 2;
  score += _inlineLink.allMatches(sample).take(2).length * 2;
  score += _codeSpan.allMatches(sample).take(2).length;
  score += _texMath.hasMatch(sample) ? 1 : 0;
  return score >= 3;
}

md.Markdown _parser() => md.Markdown(
  enableTaskList: true,
  enableEmoji: false,
  enableFencedBlockquote: false,
);

/// Markdown text as it goes into a markdown note: as written, except that
/// the pictures it links become the note's own, each on a line of its own,
/// and the \(…\) and \[…\] math ChatGPT writes becomes the $…$ and $$…$$
/// the editor draws. Code is never touched.
PasteOutput normalizeMarkdownPaste(String source) {
  final text = cleanPastedText(source);
  final ({List<(int, int)> kept, Map<int, PasteImage> pictures}) ranges;
  try {
    ranges = _readRanges(text);
  } on Object {
    return PasteOutput(text: text);
  }

  final out = StringBuffer();
  final images = <PasteImage>[];
  var cursor = 0;
  void prose(int end) {
    if (end <= cursor) return;
    out.write(_withDollarMath(text.substring(cursor, end)));
    cursor = end;
  }

  for (final (from, to) in ranges.kept) {
    if (from < cursor) continue;
    prose(from);
    final picture = ranges.pictures[from];
    if (picture == null) {
      out.write(text.substring(from, to));
    } else {
      final written = out.toString();
      final lineStart = written.lastIndexOf('\n') + 1;
      if (written.substring(lineStart).trim().isNotEmpty) out.write('\n');
      out.write('\uFFFC');
      images.add(picture);
      final lineEnd = text.indexOf('\n', to);
      final rest = text.substring(to, lineEnd < 0 ? text.length : lineEnd);
      if (rest.trim().isNotEmpty) out.write('\n');
    }
    cursor = to;
  }
  prose(text.length);
  final result = out.toString();
  return PasteOutput(text: result, images: placeImages(result, images));
}

/// Where markdown [text] is not prose, as parsed: code, raw HTML, autolinks
/// and linked pictures, whose characters are never rewritten, in order. The
/// pictures a note can hold are also kept by where they start.
({List<(int, int)> kept, Map<int, PasteImage> pictures}) _readRanges(
  String text,
) {
  final kept = <(int, int)>[];
  final pictures = <int, PasteImage>{};
  void visit(md.Node node) {
    if (node is! md.Element) return;
    switch (node.type) {
      case 'codeSpan' ||
          'fencedCodeBlock' ||
          'indentedCodeBlock' ||
          'htmlBlock' ||
          'rawHtml' ||
          'autolink':
        kept.add((node.start.offset, node.end.offset));
        return;
      case 'image':
        final image = _linkedImage(
          node.attributes['destination'],
          node.attributes['description'] ?? '',
        );
        if (image != null) pictures[node.start.offset] = image;
        kept.add((node.start.offset, node.end.offset));
        return;
    }
    for (final child in node.children) {
      visit(child);
    }
  }

  for (final node in _parser().parse(text)) {
    visit(node);
  }
  kept.sort((a, b) => a.$1.compareTo(b.$1));
  return (kept: kept, pictures: pictures);
}

/// Text from the clipboard with what a note can't hold taken out: CRLF line
/// ends, and the U+FFFC a note reserves for its attachments.
String cleanPastedText(String text) => text
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '\n')
    .replaceAll('\uFFFC', '');

PasteImage? _linkedImage(String? destination, String alt) {
  if (destination == null) return null;
  final source = destination.trim();
  if (source.startsWith('https://') || source.startsWith('http://')) {
    return PasteImage(src: source, alt: alt);
  }
  if (source.startsWith('data:image/')) {
    final comma = source.indexOf(',');
    if (comma < 0 || !source.substring(0, comma).contains(';base64')) {
      return null;
    }
    try {
      final bytes = base64.decode(source.substring(comma + 1));
      if (bytes.isEmpty) return null;
      return PasteImage(
        bytes: bytes,
        mime: source.substring(5, comma).split(';').first,
        alt: alt,
      );
    } on FormatException {
      return null;
    }
  }
  return null;
}

final _displayMath = RegExp(r'\\\[([\s\S]{1,4000}?)\\\]');
final _inlineMath = RegExp(r'\\\(([^\n]{1,1000}?)\\\)');

String _withDollarMath(String prose) {
  if (!prose.contains(r'\[') && !prose.contains(r'\(')) return prose;
  return prose
      .replaceAllMapped(_displayMath, (match) {
        final tex = match[1]!.trim();
        if (tex.isEmpty) return match[0]!;
        return tex.contains('\n') ? '\$\$\n$tex\n\$\$' : '\$\$$tex\$\$';
      })
      .replaceAllMapped(_inlineMath, (match) {
        final tex = match[1]!.trim();
        return tex.isEmpty ? match[0]! : '\$$tex\$';
      });
}

/// Markdown text read into blocks, for a note written without markdown.
///
/// Read through the same HTML reader as everything else, with its line
/// breaks kept: in a note a line ends where it was ended, where CommonMark
/// would run the lines of a paragraph together. Math is set aside before
/// the markdown is read, since TeX is full of what markdown would take as
/// its own escapes and emphasis, and comes back as the math it was.
List<PasteBlock> readMarkdownPaste(String source) {
  final text = cleanPastedText(source).replaceAll(_mathTokenEnds, '');
  final String html;
  try {
    final maths = <({String tex, bool display})>[];
    final masked = StringBuffer();
    var cursor = 0;
    for (final (from, to) in _readRanges(text).kept) {
      if (from < cursor) continue;
      masked
        ..write(_setMathAside(text.substring(cursor, from), maths))
        ..write(text.substring(from, to));
      cursor = to;
    }
    masked.write(_setMathAside(text.substring(cursor), maths));
    html = _parser().parse(masked.toString()).toHtml().replaceAllMapped(
      _mathToken,
      (match) {
        final math = maths[int.parse(match[1]!)];
        final kind = math.display ? 'math-display' : 'math-inline';
        return '<span class="$kind" data-latex="${htmlEscape.convert(math.tex)}"></span>';
      },
    );
  } on Object {
    return [
      for (final paragraph in text.split(RegExp(r'\n{2,}')))
        if (paragraph.trim().isNotEmpty) PasteParagraph([PasteText(paragraph)]),
    ];
  }
  return HtmlPasteReader().read(
    '<div style="white-space:pre-line">$html</div>',
  );
}

final _mathTokenEnds = RegExp('[\uE000\uE001]');
final _mathToken = RegExp('\uE000(\\d+)\uE001');
final _dollarDisplayMath = RegExp(r'\$\$([\s\S]{1,4000}?)\$\$');

/// Pandoc's rule for single-dollar math, which keeps "$5 and $10" money:
/// no space just inside either dollar, and no digit straight after the
/// closing one.
final _dollarMath = RegExp(
  r'(?<![\\$])\$(?![\s$])([^\n$]{0,999}?[^\s\\$])\$(?![$\d])',
);

/// [prose] with each piece of math in it swapped for a token that markdown
/// passes through untouched, the math itself added to [maths].
String _setMathAside(String prose, List<({String tex, bool display})> maths) {
  if (!prose.contains('\$') &&
      !prose.contains(r'\[') &&
      !prose.contains(r'\(')) {
    return prose;
  }
  String Function(Match) aside({required bool display}) => (match) {
    final tex = match[1]!.trim();
    if (tex.isEmpty) return match[0]!;
    maths.add((tex: tex, display: display));
    return '\uE000${maths.length - 1}\uE001';
  };
  return prose
      .replaceAllMapped(_dollarDisplayMath, aside(display: true))
      .replaceAllMapped(_displayMath, aside(display: true))
      .replaceAllMapped(_inlineMath, aside(display: false))
      .replaceAllMapped(_dollarMath, aside(display: false));
}
