import '../ai/kapy_ai.dart';
import '../data/note_attachment.dart';
import '../speech/moments.dart';
import '../ui/sidebar_timestamp.dart';
import 'recap_lines.dart';
import 'recap_material.dart';
import 'recap_period.dart';
import 'recap_record.dart';

/// The cards a recap can show, each carrying one idea.
enum RecapCard {
  cover,
  numbers,
  week,
  calendar,
  highlights,
  topics,
  tasks,
  voice,
  months,
  moments,
  line,
  closing,
}

/// A topic a recap names: a tag or folder the period's notes carry, with how
/// many do, and the line Kapy AI wrote about it when it named it too. A topic
/// only Kapy AI named has no count.
typedef RecapTopicRow = ({String name, int? notes, String? line});

/// What a recap shows when it opens: the numbers worked out on the device
/// when it was made, and the words Kapy AI wrote, checked again against what
/// the period holds now.
class RecapStory {
  const RecapStory({
    required this.record,
    required this.lines,
    this.done = const [],
    this.open = const [],
    this.voice,
  });

  /// The recap [chat] holds, its newest answer read again against [now], the
  /// period's material as it is today: a highlight or a quote of a note that
  /// has been hidden, archived or deleted since is dropped, and so is a task
  /// in one. Null when [chat] is not a recap of [now]'s period.
  static RecapStory? read(KapyChat chat, RecapMaterial now) {
    final record = recapOf(chat);
    if (record == null || record.period != now.period) return null;
    final lines = readRecapLines(
      recapAnswer(chat) ?? '',
      period: record.period,
      sent: now.readable,
    );
    List<String> words(RecapSource source, List<String> ids) {
      final held = {
        for (final item in now.items)
          if (item.source == source) item.taskId: item.note.text,
      };
      return [for (final id in ids) ?held[id]];
    }

    final quote = lines.quote;
    return RecapStory(
      record: record,
      lines: lines,
      done: words(RecapSource.taskDone, record.numbers.done),
      open: words(RecapSource.taskOpen, record.numbers.open),
      voice: quote == null
          ? null
          : [
              for (final item in now.items)
                if (item.note.id == quote.noteId &&
                    item.voice?.hash == quote.hash)
                  item.voice!,
            ].firstOrNull,
    );
  }

  final RecapRecord record;
  final RecapLines lines;

  /// The words of the tasks done and still open that the recap lists.
  final List<String> done;
  final List<String> open;

  /// The recording [RecapLines.quote] is from.
  final NoteVoiceRef? voice;

  RecapPeriod get period => record.period;
  RecapNumbers get numbers => record.numbers;
  RecapKind get kind => period.kind;

  /// "Wed 19 recap", "17–23 Nov recap", "November recap", "2026 recap".
  String get name => '${period.label} recap';

  /// The cover's title: Kapy AI's, or a plain one where it gave none.
  String get title =>
      lines.title ??
      switch (kind) {
        RecapKind.day => 'Your day',
        RecapKind.week => 'Your week',
        RecapKind.month => 'Your month',
        RecapKind.year => 'Your year',
      };

  /// The cards, in order, leaving out any with nothing to show.
  List<RecapCard> get cards => [
    RecapCard.cover,
    ...switch (kind) {
      RecapKind.day => [
        RecapCard.numbers,
        if (lines.highlights.isNotEmpty) RecapCard.highlights,
        if (done.isNotEmpty || open.isNotEmpty) RecapCard.tasks,
        if (lines.quote != null) RecapCard.voice,
      ],
      RecapKind.week => [
        RecapCard.week,
        if (topics.isNotEmpty || lines.highlights.isNotEmpty)
          RecapCard.highlights,
      ],
      RecapKind.month => [RecapCard.calendar, RecapCard.topics],
      RecapKind.year => [
        RecapCard.numbers,
        RecapCard.months,
        if (topics.isNotEmpty) RecapCard.topics,
        if (lines.moments.isNotEmpty) RecapCard.moments,
        if (lines.line != null) RecapCard.line,
      ],
    },
    RecapCard.closing,
  ];

  /// The topics the period's notes carry, most first, each with Kapy AI's
  /// line when it named the same one, then the ones only Kapy AI named.
  List<RecapTopicRow> get topics {
    final written = {
      for (final topic in lines.topics.reversed)
        topic.name.toLowerCase(): topic.line,
    };
    final counted = {
      for (final topic in numbers.topics) topic.name.toLowerCase(),
    };
    return [
      for (final topic in numbers.topics)
        (
          name: topic.name,
          notes: topic.notes,
          line: written[topic.name.toLowerCase()],
        ),
      for (final topic in lines.topics)
        if (!counted.contains(topic.name.toLowerCase()))
          (name: topic.name, notes: null, line: topic.line),
    ];
  }

  /// The day of the period with the most notes, the earliest of a tie.
  int? get busiest => _most(numbers.chart);

  /// The period's first day plus [index] days.
  DateTime day(int index) =>
      DateTime(period.first.year, period.first.month, period.first.day + index);

  /// The longest run of days with a note, first to last, the earliest of a
  /// tie, or null when it is shorter than two days.
  (DateTime, DateTime)? get run {
    final longest = numbers.longestRun;
    if (longest < 2 || kind == RecapKind.year) return null;
    var length = 0;
    for (var i = 0; i < numbers.chart.length; i++) {
      length = numbers.chart[i] > 0 ? length + 1 : 0;
      if (length == longest) return (day(i - longest + 1), day(i));
    }
    return null;
  }

  /// The day's numbers set beside the day before's: "2 more notes than Tue
  /// 18".
  String get comparison {
    final notes = numbers.counts.notes;
    final before = numbers.previous.notes;
    final label = SidebarTimestamp.weekdayAndDay(period.previous.first);
    final diff = notes - before;
    if (diff == 0) return 'As many notes as $label.';
    final count = diff.abs();
    return '$count ${diff > 0 ? 'more' : 'fewer'} '
        '${count == 1 ? 'note' : 'notes'} than $label.';
  }

  /// One normal note holding the recap's words, and the notes it names. It
  /// is read from this story, so a note hidden since it was made is never in
  /// it.
  RecapNote get note {
    final counts = numbers.counts;
    final topics = this.topics;
    final quote = lines.quote;
    String topic(RecapTopicRow row) => [
      '- ${_plainLine(row.name)}',
      if (row.notes case final notes?) ' (${_count(notes, 'note', 'notes')})',
      if (row.line case final line?) ': ${_plainLine(line)}',
    ].join();
    List<String> part(String heading, Iterable<String> rows) =>
        rows.isEmpty ? const [] : ['', heading, ...rows];
    return RecapNote(
      body: [
        name,
        _plainLine(title),
        [
          _count(counts.notes, 'note', 'notes'),
          if (counts.tasksDone > 0)
            _count(counts.tasksDone, 'task done', 'tasks done'),
          if (counts.voiceMinutes > 0)
            '${recapDuration(counts.voiceMinutes)} recorded',
        ].join(' · '),
        ...part('Highlights', [
          for (final it in lines.highlights)
            '- ${_plainLine(it.title)}: ${_plainLine(it.line)}',
        ]),
        ...part('Topics', topics.map(topic)),
        ...part('Moments', [
          for (final moment in lines.moments)
            '- ${SidebarTimestamp.monthName(DateTime(2000, moment.month))}: '
                '${_plainLine(moment.line)}',
        ]),
        ...part('From a voice note', [
          if (quote != null)
            '- ${_plainLine(quote.title)}, at '
                '${formatVoiceDuration(quote.at)}: “${_plainLine(quote.line)}”',
        ]),
        ...part('Line of the year', [
          if (lines.line case final line?) '- ${_plainLine(line)}',
        ]),
        ...part('Done', [for (final task in done) '- ${_plainLine(task)}']),
        ...part('Still open', [
          for (final task in open) '- ${_plainLine(task)}',
        ]),
        ...part(closingLabel, [
          if (lines.next case final next?) '- ${_plainLine(next)}',
        ]),
      ].join('\n'),
      names: {
        for (final it in lines.highlights) it.noteId,
        ?quote?.noteId,
      }.toList(),
    );
  }

  /// What the closing card's line is about.
  String get closingLabel => switch (kind) {
    RecapKind.day => 'What’s next',
    RecapKind.week => 'Next week',
    RecapKind.month => SidebarTimestamp.monthName(period.next.first),
    RecapKind.year => 'Into ${period.first.year + 1}',
  };
}

/// A recap as a note: its text, and the ids of the notes it names.
class RecapNote {
  const RecapNote({required this.body, required this.names});

  final String body;
  final List<String> names;
}

/// [minutes] as a recap says it: "12 minutes", "3 h 20", "31 hours".
String recapDuration(int minutes) {
  if (minutes < 60) return _count(minutes, 'minute', 'minutes');
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  if (rest == 0) return _count(hours, 'hour', 'hours');
  return '$hours h $rest';
}

String _count(int n, String one, String many) =>
    '${_figures(n)} ${n == 1 ? one : many}';

/// [n] with its thousands marked: "1,086".
String recapFigures(int n) => _figures(n);

String _figures(int n) {
  final digits = '$n';
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}

int? _most(List<int> values) {
  int? best;
  for (var i = 0; i < values.length; i++) {
    if (values[i] > 0 && (best == null || values[i] > values[best])) best = i;
  }
  return best;
}

/// [text] as one line of plain words to show: no control or direction
/// characters, and its spaces single. Kapy AI's words and a note's are shown
/// only this way, never as markdown or links.
String recapShown(String text) =>
    text.replaceAll(_control, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

final RegExp _control = RegExp(
  r'[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u202a-\u202e\u2066-\u2069]',
);

/// [text] as one line of plain words for a note: [recapShown], with nothing
/// at its start that a note would read as a heading, a list, a quote, a task
/// or a table.
String _plainLine(String text) => recapShown(text).replaceFirst(
  RegExp(
    r'^(?:(?:#{1,6}|>|\||[-*+](?=\s)|\d+[.)](?=\s)|\[[ xX]?\]|[`~]{3,}|[-=_*]{3,})\s*)+',
  ),
  '',
);
