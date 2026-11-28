import '../data/note_attachment.dart';
import '../speech/moments.dart';
import '../ui/sidebar_timestamp.dart';
import 'recap_period.dart';

/// The labels a recap's answer is written in, one line each, and the ones
/// each kind asks for: the words on its cards, and nothing else.
const Map<RecapKind, Set<String>> recapLabels = {
  RecapKind.day: {'TITLE', 'HIGHLIGHT', 'QUOTE', 'NEXT'},
  RecapKind.week: {'TITLE', 'TOPIC', 'HIGHLIGHT', 'NEXT'},
  RecapKind.month: {'TITLE', 'TOPIC', 'HIGHLIGHT', 'NEXT'},
  RecapKind.year: {'TITLE', 'TOPIC', 'MOMENT', 'LINE', 'NEXT'},
};

const Set<String> _allLabels = {
  'TITLE',
  'HIGHLIGHT',
  'QUOTE',
  'TOPIC',
  'MOMENT',
  'LINE',
  'NEXT',
};

/// The most of each a recap keeps.
const int recapHighlightsMax = 3;
const int recapTopicsMax = 3;

/// The longest digest a digest call is asked for.
const int recapDigestChars = 1500;

/// The days [period] covers, spelt out for a model that has no clock:
/// "Thursday, 19 November 2026", "17–23 Nov 2026", "November 2026", "2026".
String recapDates(RecapPeriod period) => switch (period.kind) {
  RecapKind.day =>
    '${SidebarTimestamp.fullDay(period.first)} ${period.first.year}',
  RecapKind.week =>
    '${SidebarTimestamp.dayRange(period.first, period.last)} ${period.last.year}',
  RecapKind.month =>
    '${SidebarTimestamp.monthName(period.first)} ${period.first.year}',
  RecapKind.year => '${period.first.year}',
};

/// The question for one part of a longer recap: a digest of [label]'s
/// notes that the recap itself reads later.
String recapDigestQuestion(RecapPeriod period, String label) =>
    'These are my notes, tasks and voice notes from $label, part of '
    '${recapDates(period)}. Write a digest of them for a recap written '
    'later: what happened, what was decided and what is still open, in at '
    'most $recapDigestChars characters of plain text. Name each note you '
    'mention by its exact title. Add nothing the notes do not say.';

/// The question for the recap itself, asking for labelled lines rather than
/// prose so each card gets its own words.
String recapQuestion(RecapPeriod period) {
  final dates = recapDates(period);
  final reads = switch (period.kind) {
    RecapKind.day => 'These are my notes, tasks and voice notes from $dates.',
    RecapKind.week =>
      'These are my notes, tasks and voice notes from $dates, with a digest '
          'of its first days.',
    RecapKind.month => 'These are digests of my notes from $dates.',
    RecapKind.year =>
      'These are digests of my notes from $dates, one for each month.',
  };
  final lines = [
    'TITLE: a cover title of at most 6 words',
    if (period.kind != RecapKind.year)
      'HIGHLIGHT: <exact note title> | <one line about it>, up to '
          '$recapHighlightsMax lines, each naming a different note',
    if (period.kind == RecapKind.day)
      'QUOTE: <exact voice note title> | <m:ss> | <one line copied word for '
          'word from its transcript>, at most one, only if there is a voice '
          'note',
    if (period.kind != RecapKind.day)
      'TOPIC: <a topic in 1 to 3 words> | <one line about it>, up to '
          '$recapTopicsMax lines',
    if (period.kind == RecapKind.year) ...[
      'MOMENT: <month name> | <one line about that month>, one for each month '
          'there is a digest for',
      'LINE: the one line that sums up the year',
    ],
    'NEXT: one line on what comes next',
  ];
  return '$reads Write a recap of them. Reply with only these lines, each on '
      'a line of its own, in plain text, starting with its label:\n'
      '${lines.join('\n')}\n'
      'Write nothing else. Keep each line under 20 words.';
}

/// [text] with every line that [readRecapLines] would take for a labelled
/// line written so it no longer is one, so a note, a transcript or an earlier
/// digest cannot hand the model a line to repeat as if the recap wrote it.
/// Each line is judged as the reader sees it: without list marks, bold or
/// invisible characters.
String recapDefanged(String text) => [
  for (final line in text.split('\n'))
    switch (_labelled.firstMatch(_plain(line))) {
      final match? when _allLabels.contains(match[1]!.toUpperCase()) =>
        '${match[1]} - ${match[2]}',
      _ => line,
    },
].join('\n');

/// A voice note a recap was sent: the note it is in, and the recording.
typedef RecapVoice = ({String noteId, NoteVoiceRef ref});

/// What a recap's calls were sent, by which an answer's lines are checked:
/// note titles, voice note titles and, for a year, months, each in lower
/// case.
class RecapSent {
  RecapSent({
    Map<String, String>? notes,
    Map<String, RecapVoice>? voices,
    Set<int>? months,
  }) : notes = notes ?? {},
       voices = voices ?? {},
       months = months ?? {};

  /// Each title, to the note it names.
  final Map<String, String> notes;
  final Map<String, RecapVoice> voices;
  final Set<int> months;
}

class RecapHighlight {
  const RecapHighlight({
    required this.noteId,
    required this.title,
    required this.line,
  });

  final String noteId;
  final String title;
  final String line;
}

/// A line from a voice note, at the moment it is said: "Play this part".
class RecapQuote {
  const RecapQuote({
    required this.noteId,
    required this.hash,
    required this.title,
    required this.at,
    required this.line,
  });

  final String noteId;

  /// The recording's.
  final String hash;
  final String title;
  final Duration at;
  final String line;
}

typedef RecapTopicLine = ({String name, String line});

/// A year's line for one month, January being 1.
typedef RecapMoment = ({int month, String line});

/// The words of a recap's cards, as far as they survived [readRecapLines].
/// What is missing leaves its card to the numbers, and a missing title to
/// [recapTitle].
class RecapLines {
  const RecapLines({
    this.title,
    this.highlights = const [],
    this.quote,
    this.topics = const [],
    this.moments = const [],
    this.line,
    this.next,
  });

  final String? title;
  final List<RecapHighlight> highlights;
  final RecapQuote? quote;
  final List<RecapTopicLine> topics;
  final List<RecapMoment> moments;
  final String? line;
  final String? next;

  /// The lines as the answer message keeps them, in the order of the cards.
  String get text => [
    if (title case final title?) 'TITLE: $title',
    for (final it in highlights) 'HIGHLIGHT: ${it.title} | ${it.line}',
    if (quote case final quote?)
      'QUOTE: ${quote.title} | ${formatVoiceDuration(quote.at)} | '
          '${quote.line}',
    for (final topic in topics) 'TOPIC: ${topic.name} | ${topic.line}',
    for (final moment in moments)
      'MOMENT: ${_monthNames[moment.month - 1]} | ${moment.line}',
    if (line case final line?) 'LINE: $line',
    if (next case final next?) 'NEXT: $next',
  ].join('\n');

  /// A month's lines as the digest a year recap reads instead of asking
  /// again.
  String get digest => [
    ?title,
    for (final topic in topics) '${topic.name}: ${topic.line}',
    for (final it in highlights) '${it.title}: ${it.line}',
    if (next case final next?) 'Next: $next',
  ].join('\n');
}

/// A recap's own name, where its answer gave it none: "Recap · Wed 19". An
/// older build lists a recap as a chat under this name.
String recapTitle(RecapPeriod period) => 'Recap · ${period.label}';

/// The lines of [answer] that hold, for a recap of [period] that was sent
/// [sent]. Every line is untrusted: a line without one of the period's
/// labels, or with a second label inside it, is dropped; a highlight must
/// name a note that was sent, a quote must be word for word in that voice
/// note's transcript, and a moment must name a month that was sent; the
/// first of each counts, and every line is cut to fit its card.
RecapLines readRecapLines(
  String answer, {
  required RecapPeriod period,
  required RecapSent sent,
}) {
  final allowed = recapLabels[period.kind]!;
  String? title;
  String? line;
  String? next;
  RecapQuote? quote;
  final highlights = <RecapHighlight>[];
  final topics = <RecapTopicLine>[];
  final moments = <RecapMoment>[];
  for (final raw in answer.split('\n')) {
    final match = _labelled.firstMatch(_plain(raw));
    if (match == null) continue;
    final label = match[1]!.toUpperCase();
    final value = match[2]!.trim();
    if (!allowed.contains(label) ||
        value.isEmpty ||
        _innerLabel.hasMatch(value)) {
      continue;
    }
    final fields = _fields(value, label == 'QUOTE' ? 3 : 2);
    switch (label) {
      case 'TITLE':
        title ??= _cut(value, 60);
      case 'LINE':
        line ??= _cut(value, 160);
      case 'NEXT':
        next ??= _cut(value, 160);
      case 'HIGHLIGHT' when fields.length == 2:
        final noteId = sent.notes[fields[0].toLowerCase()];
        if (noteId == null ||
            highlights.length == recapHighlightsMax ||
            highlights.any((it) => it.noteId == noteId)) {
          continue;
        }
        highlights.add(
          RecapHighlight(
            noteId: noteId,
            title: _cut(fields[0], 80),
            line: _cut(fields[1], 140),
          ),
        );
      case 'QUOTE' when fields.length == 3 && quote == null:
        final voice = sent.voices[fields[0].toLowerCase()];
        final at = voice == null ? null : _heardAt(voice.ref, fields[2]);
        if (voice == null || at == null) continue;
        quote = RecapQuote(
          noteId: voice.noteId,
          hash: voice.ref.hash,
          title: _cut(fields[0], 80),
          at: at,
          line: _cut(fields[2], 200),
        );
      case 'TOPIC' when fields.length == 2 && fields[0].isNotEmpty:
        if (topics.length == recapTopicsMax) continue;
        topics.add((name: _cut(fields[0], 32), line: _cut(fields[1], 140)));
      case 'MOMENT' when fields.length == 2:
        final month = _month(fields[0]);
        if (month == null ||
            !sent.months.contains(month) ||
            moments.any((it) => it.month == month)) {
          continue;
        }
        moments.add((month: month, line: _cut(fields[1], 140)));
    }
  }
  moments.sort((a, b) => a.month.compareTo(b.month));
  return RecapLines(
    title: title,
    highlights: highlights,
    quote: quote,
    topics: [
      for (final topic in topics)
        if (topic.line.isNotEmpty) topic,
    ],
    moments: [
      for (final moment in moments)
        if (moment.line.isNotEmpty) moment,
    ],
    line: line,
    next: next,
  );
}

final RegExp _labelled = RegExp(r'^([A-Za-z]+)\s*:\s*(.*)$');

final RegExp _innerLabel = RegExp('\\b(${_allLabels.join('|')})\\s*:');

final RegExp _control = RegExp(
  r'[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u202a-\u202e\u2066-\u2069]',
);

/// A line with its control and direction characters gone, its spaces
/// single, and the list marks and emphasis a model adds taken off.
String _plain(String raw) => raw
    .replaceAll(_control, ' ')
    .replaceAll('**', '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim()
    .replaceFirst(RegExp(r'^(?:[-*•]|\d+[.)])\s*'), '');

/// [value] split at its first [count] - 1 bars, each part unquoted: the
/// last keeps any bars of its own.
List<String> _fields(String value, int count) {
  final fields = <String>[];
  var rest = value;
  while (fields.length < count - 1) {
    final bar = rest.indexOf('|');
    if (bar < 0) break;
    fields.add(_unquoted(rest.substring(0, bar)));
    rest = rest.substring(bar + 1);
  }
  return [...fields, _unquoted(rest)];
}

String _unquoted(String field) =>
    field.trim().replaceAll(RegExp('^["“”\'‘’`_]+|["“”\'‘’`_]+\$'), '').trim();

/// [text] in at most [max] characters, cut at a word with an ellipsis.
String _cut(String text, int max) {
  if (text.length <= max) return text;
  final head = text.substring(0, max - 1);
  final space = head.lastIndexOf(' ');
  return '${(space > max ~/ 2 ? head.substring(0, space) : head).trimRight()}…';
}

/// When [ref]'s transcript says [said], word for word: the start of the
/// segment its first word is in. Null when it never does, or [said] is too
/// short to be a line.
Duration? _heardAt(NoteVoiceRef ref, String said) {
  final words = _words(said);
  final segments = ref.transcript?.segments ?? const [];
  if (words.length < 3) return null;
  final heard = [
    for (final segment in segments)
      for (final word in _words(segment.t)) (word: word, at: segment.s),
  ];
  for (var i = 0; i + words.length <= heard.length; i++) {
    var j = 0;
    while (j < words.length && heard[i + j].word == words[j]) {
      j++;
    }
    if (j == words.length) return Duration(milliseconds: heard[i].at);
  }
  return null;
}

List<String> _words(String text) => [
  for (final word in text.toLowerCase().split(RegExp(r'\s+')))
    if (word.replaceAll(_notWord, '') case final bare when bare.isNotEmpty)
      bare,
];

final RegExp _notWord = RegExp(r'[^\p{L}\p{N}]', unicode: true);

int? _month(String name) {
  final lower = name.toLowerCase();
  for (var i = 0; i < 12; i++) {
    final full = _monthNames[i].toLowerCase();
    if (lower == full || lower == full.substring(0, 3)) return i + 1;
  }
  return null;
}

const List<String> _monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];
