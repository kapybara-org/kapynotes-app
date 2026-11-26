import '../ai/retrieval.dart' show questionTerms;
import '../data/note_attachment.dart';

/// Where in a recording [text] was said: the start of the transcript
/// paragraph that shares the most of its words, or null when none shares
/// enough of them to be sure.
///
/// Scored the way Kapy AI picks notes for a question: [text]'s words that
/// carry meaning, each counted once when the paragraph holds it. A summary
/// point is written in other words than the ones spoken, so a weak overlap
/// says nothing, and a time on it would send somebody to the wrong moment.
/// So a paragraph has to hold at least two of the point's words and at least
/// [minShare] of them, and ties go to the earlier paragraph.
Duration? momentFor(
  String text,
  List<List<TranscriptSegment>> paragraphs, {
  double minShare = 0.4,
}) {
  final terms = questionTerms(text);
  if (terms.length < 2) return null;
  final needed = (terms.length * minShare).ceil().clamp(2, terms.length);
  List<TranscriptSegment>? best;
  var bestScore = 0;
  for (final paragraph in paragraphs) {
    if (paragraph.isEmpty) continue;
    final said = paragraph.map((segment) => segment.t).join(' ').toLowerCase();
    final score = terms.where(said.contains).length;
    if (score > bestScore) {
      best = paragraph;
      bestScore = score;
    }
  }
  if (best == null || bestScore < needed) return null;
  return Duration(milliseconds: best.first.s);
}

/// The silences between [segments] longer than [longerThan], each trimmed by
/// [cushion] at both ends so a jump never clips the first or last word.
List<({Duration from, Duration to})> pausesIn(
  List<TranscriptSegment> segments, {
  Duration longerThan = const Duration(milliseconds: 1500),
  Duration cushion = const Duration(milliseconds: 300),
}) {
  final pauses = <({Duration from, Duration to})>[];
  for (var i = 1; i < segments.length; i++) {
    final end = segments[i - 1].e;
    final start = segments[i].s;
    if (start - end <= longerThan.inMilliseconds) continue;
    pauses.add((
      from: Duration(milliseconds: end) + cushion,
      to: Duration(milliseconds: start) - cushion,
    ));
  }
  return pauses;
}
