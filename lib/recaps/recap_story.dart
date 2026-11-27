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
/// only Kapy AI named has no count. [colour] is the tag's colour, one of
/// [tagColours] or [noTagColour], as it is now; null for a folder and for a
/// topic only Kapy AI named.
typedef RecapTopicRow = ({
  String name,
  int? notes,
  String? line,
  String? colour,
});

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
    this.wordsGone = false,
    this.chat,
    this.dropped = false,
    this.colours = const {},
  });

  /// The recap [chat] holds, its newest answer read again against [now], the
  /// period's material as it is today: a highlight or a quote of a note that
  /// has been hidden, archived or deleted since is dropped, and so is a task
  /// in one, and so is every other line of Kapy AI's that names one: [gone] holds
  /// the titles of the period's notes hidden or archived since, and the
  /// titles its highlights and quote name that [now] no longer holds are
  /// added to it.
  ///
  /// A line can tell of a note without naming it, so where a note one of
  /// the recap's parts may have read was hidden after it was made, every
  /// line no part can be told from is dropped too: the title, the topics,
  /// the line of the year and what's next. So are a year's moments of that
  /// part's months, and the highlights and the quote of any note that part
  /// may have read. Deleting or archiving a note takes nothing out this way.
  ///
  /// Which parts may have read a hidden note, the record's filters alone
  /// say, whatever day the note shows on now: first the one of every note
  /// the recap read, then each part's own. [handled] holds the notes whose
  /// hide was dealt with already, and they are left alone. Null when [chat]
  /// is not a recap of [now]'s period.
  static RecapStory? read(
    KapyChat chat,
    RecapMaterial now, {
    Set<String> gone = const {},
    Set<String> handled = const {},
  }) {
    final record = recapOf(chat);
    if (record == null || record.period != now.period) return null;
    final readable = now.readable;
    final answer = (recapAnswer(chat) ?? '').split('\n');
    final titles = {
      for (final title in gone) title.trim().toLowerCase(),
      for (final line in answer)
        if (_named.firstMatch(recapShown(line).replaceAll('**', ''))
            case final match?)
          if (match[1]!.trim().replaceAll(_quotes, '').toLowerCase()
              case final title
              when !readable.notes.containsKey(title) &&
                  !readable.voices.containsKey(title))
            title,
    }..remove('');
    final lines = readRecapLines(
      [
        for (final line in answer)
          if (_named.hasMatch(recapShown(line).replaceAll('**', '')) ||
              !_mentions(line, titles))
            line,
      ].join('\n'),
      period: record.period,
      sent: readable,
    );
    List<String> words(RecapSource source, List<String> ids) {
      final held = {
        for (final item in now.items)
          if (item.source == source) item.taskId: item.note.text,
      };
      return [for (final id in ids) ?held[id]];
    }

    final period = record.period;
    DateTime dayAt(int index) => DateTime(
      period.first.year,
      period.first.month,
      period.first.day + index,
    );
    final changed = [
      for (final note in now.hidden)
        if (note.at.isAfter(record.madeAt) &&
            !handled.contains(note.id) &&
            (record.allRead?.mayHold(note.id) ?? true))
          note.id,
    ];
    final parts = record.read;
    final affected = parts == null
        ? (changed.isEmpty ? const <RecapRead>[] : null)
        : [
            for (final part in parts)
              if (changed.any(part.notes.mayHold)) part,
          ];
    bool drops(String noteId) =>
        affected == null || affected.any((part) => part.notes.mayHold(noteId));
    bool dropsMonth(int it) =>
        affected == null ||
        affected.any(
          (part) =>
              it >= dayAt(part.first).month && it <= dayAt(part.last).month,
        );
    final kept = affected != null && affected.isEmpty
        ? lines
        : RecapLines(
            highlights: [
              for (final it in lines.highlights)
                if (!drops(it.noteId)) it,
            ],
            quote: switch (lines.quote) {
              final quote? when !drops(quote.noteId) => quote,
              _ => null,
            },
            moments: [
              for (final moment in lines.moments)
                if (!dropsMonth(moment.month)) moment,
            ],
          );

    final quote = kept.quote;
    int worded(Iterable<String> lines) => lines
        .where(
          (line) => _worded.hasMatch(recapShown(line).replaceAll('**', '')),
        )
        .length;
    final said = worded(answer);
    final left = kept.text.isEmpty ? 0 : kept.text.split('\n').length;
    final answers = [
      for (final message in chat.messages)
        if (message.role == KapyRole.assistant) message.text,
    ];
    final before = answers.reversed.skip(1);
    return RecapStory(
      record: record,
      lines: kept,
      chat: chat,
      colours: now.tagColours,
      dropped: left < said,
      wordsGone:
          left == 0 &&
          (said > 0 || before.any((text) => worded(text.split('\n')) > 0)),
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

  /// Whether every word Kapy AI wrote was left out because notes it may
  /// have come from are hidden or gone now, here or when an earlier opening
  /// kept the chat without them ([recapPruned]): its newest answer has no
  /// words, but an older one did. The closing card says so and offers to
  /// make it again, and a remake with words ends it.
  final bool wordsGone;

  /// The chat it was read from.
  final KapyChat? chat;

  /// Whether any of the words in [chat]'s answer were left out.
  final bool dropped;

  /// Each tag's colour key by its name in lower case, as the tags are now:
  /// [RecapMaterial.tagColours].
  final Map<String, String> colours;

  RecapPeriod get period => record.period;
  RecapNumbers get numbers => record.numbers;
  RecapKind get kind => period.kind;

  /// "Recap · Wed 19", "Recap · 17–23 Nov", "Recap · November", "Recap ·
  /// 2026".
  String get name => recapTitle(period);

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
          colour: colours[topic.name.toLowerCase()],
        ),
      for (final topic in lines.topics)
        if (!counted.contains(topic.name.toLowerCase()))
          (name: topic.name, notes: null, line: topic.line, colour: null),
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

/// [story]'s chat with what it shows now as its newest answer, when it left
/// out any of its words, else null. What told it to leave them out may not
/// last (a hidden note deleted later is gone once its tombstone is), so
/// keeping what is left makes the words stay gone on every device. It costs
/// no call, and the record stays as it was. With no words left, the older
/// answers still show there were some, so the story still tells why and
/// offers Remake.
KapyChat? recapPruned(RecapStory story, {required DateTime now}) {
  final chat = story.chat;
  if (chat == null || !story.dropped) return null;
  final record = story.record;
  return recapChat(
    chat,
    record: record,
    answer: story.lines.text.isEmpty
        ? recapTitle(record.period)
        : story.lines.text,
    model: chat.model,
    now: now,
  );
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

final RegExp _named = RegExp(
  r'^(?:[-*•]|\d+[.)])?\s*(?:HIGHLIGHT|QUOTE)\s*:([^|]*)\|',
  caseSensitive: false,
);

final RegExp _worded = RegExp(
  r'^(?:[-*•]|\d+[.)])?\s*(?:TITLE|HIGHLIGHT|QUOTE|TOPIC|MOMENT|LINE|NEXT)\s*:',
  caseSensitive: false,
);

final RegExp _quotes = RegExp('^["“”\'‘’`_]+|["“”\'‘’`_]+\$');

/// Whether [line] names any of [titles], each in lower case, as words of
/// their own.
bool _mentions(String line, Set<String> titles) {
  final lower = line.toLowerCase();
  return titles.any(
    (title) => RegExp(
      '(?<![\\p{L}\\p{N}])${RegExp.escape(title)}(?![\\p{L}\\p{N}])',
      unicode: true,
    ).hasMatch(lower),
  );
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
