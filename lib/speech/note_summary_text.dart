/// Turning what a small model actually said into the shape the note wants.
///
/// The server answers with JSON because we control both ends of that call. A
/// model running on the device answers with prose, and asking it nicely for
/// "a title then bullet points" gets that most of the time and something
/// close to it the rest: a `**Summary**` heading, a "Sure, here you go",
/// numbered lines, a stray blank bullet. None of that should reach a note.
///
/// Everything here is pure string work — no Flutter, no plugins — so it is
/// cheap to test against the real ragged output.
library;

/// A title and its points, after cleaning.
class ParsedSummary {
  const ParsedSummary({required this.title, required this.points});

  final String title;
  final List<String> points;
}

/// The most points a summary keeps.
///
/// Five is what the dialog can show without scrolling, and past that a
/// summary has stopped being one.
const int maxSummaryPoints = 5;

/// The longest a title may be, in words. A model asked for six will
/// occasionally write a sentence.
const int maxTitleWords = 8;

/// Reads [raw] as a title and a list of points.
///
/// Never throws and never returns an empty title: a summary with no heading
/// is worse to look at than one with a heading taken from its first point.
ParsedSummary parseSummaryText(String raw) {
  final lines = _meaningfulLines(raw);

  String? title;
  var sawBullet = false;
  final points = <String>[];

  for (final line in lines) {
    final bullet = _asBullet(line);
    if (bullet != null) {
      sawBullet = true;
      if (bullet.isNotEmpty) points.add(bullet);
      continue;
    }
    // The first line before any bullet is the heading. A line *after* the
    // list is a model carrying on talking, and there is nothing in it.
    if (!sawBullet && title == null) {
      final candidate = _asTitle(line);
      if (candidate.isNotEmpty) title = candidate;
    }
  }

  // No bullets anywhere: the model wrote prose. Sentences become the points,
  // because the alternative is one paragraph pretending to be a summary.
  if (!sawBullet) {
    var body = lines;
    // A preamble introduces the text rather than being part of it.
    while (body.isNotEmpty && _asTitle(body.first).isEmpty) {
      body = body.sublist(1);
    }
    // A short first line among several is a heading. One long line is the
    // whole summary, and taking it as the heading would leave no points.
    final heading = body.length > 1 ? _asTitle(body.first) : '';
    if (heading.isNotEmpty && heading.split(' ').length <= maxTitleWords) {
      title = heading;
      body = body.sublist(1);
    } else {
      title = null;
    }
    points
      ..clear()
      ..addAll(_sentences(body));
  }

  final kept = points.take(maxSummaryPoints).toList();
  return ParsedSummary(
    title: _clampTitle(title ?? (kept.isEmpty ? 'Voice note' : kept.first)),
    points: kept,
  );
}

/// Non-empty lines, with the wrappers a chat-tuned model likes stripped.
List<String> _meaningfulLines(String raw) {
  final lines = <String>[];
  for (var line in raw.split('\n')) {
    line = line.trim();
    if (line.isEmpty) continue;
    // A fenced block: the fence is not content, and neither is its language.
    if (line.startsWith('```')) continue;
    lines.add(line);
  }
  return lines;
}

/// The text of [line] if it is a bullet, else null.
///
/// Handles `-`, `*`, `•`, `–` and `1.` / `1)` numbering, which is the whole
/// vocabulary a model reaches for when asked for a list.
String? _asBullet(String line) {
  const markers = ['- ', '* ', '• ', '– ', '— '];
  for (final marker in markers) {
    if (line.startsWith(marker)) return _clean(line.substring(marker.length));
  }
  // A bare marker on its own line is an empty bullet, not a title.
  if (line == '-' || line == '*' || line == '•') return '';
  final numbered = RegExp(r'^\d{1,2}[.)]\s+').firstMatch(line);
  if (numbered != null) return _clean(line.substring(numbered.end));
  return null;
}

/// A heading, stripped of the decoration models put on it.
String _asTitle(String line) {
  var text = line;
  // Markdown headings, and the label a model adds when told to write one.
  text = text.replaceFirst(RegExp(r'^#{1,6}\s*'), '');
  text = text.replaceFirst(
    RegExp(r'^(title|summary|topic)\s*[:\-–]\s*', caseSensitive: false),
    '',
  );
  text = _clean(text);
  // "Here is a summary of the transcript:" is a preamble, not a title. A
  // line ending in a colon is introducing something else.
  if (text.endsWith(':')) return '';
  return text;
}

/// Strips inline markdown and surrounding quotes, and squeezes whitespace.
String _clean(String text) {
  var out = text.trim();
  out = out.replaceAll(RegExp(r'\*\*|__|`'), '');
  out = out.replaceAll(RegExp(r'\s+'), ' ');
  // A model told to write a title often writes "A title".
  if (out.length > 1 &&
      ((out.startsWith('"') && out.endsWith('"')) ||
          (out.startsWith("'") && out.endsWith("'")))) {
    out = out.substring(1, out.length - 1).trim();
  }
  return out.trim();
}

/// Splits prose into sentence-sized points.
List<String> _sentences(Iterable<String> lines) {
  final out = <String>[];
  for (final line in lines) {
    for (final piece in line.split(RegExp(r'(?<=[.!?])\s+'))) {
      final text = _clean(piece);
      if (text.length < 2) continue;
      out.add(text);
      if (out.length >= maxSummaryPoints) return out;
    }
  }
  return out;
}

String _clampTitle(String title) {
  final clean = _clean(title).replaceFirst(RegExp(r'[.:;,]+$'), '');
  if (clean.isEmpty) return 'Voice note';
  final words = clean.split(' ');
  if (words.length <= maxTitleWords) return clean;
  return '${words.take(maxTitleWords).join(' ')}…';
}
