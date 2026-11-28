import '../data/folders.dart';
import '../data/note.dart';
import '../data/notes_store.dart';
import '../data/tags.dart';
import '../data/task_board.dart';
import '../recaps/recap_digest.dart';
import '../recaps/recap_material.dart';
import '../recaps/recap_period.dart';
import '../recaps/recap_record.dart' show recapTopicName;
import '../ui/sidebar_timestamp.dart';
import 'answer_engine.dart';
import 'retrieval.dart';

/// A chat about a period: what it may read, and what it says about that.

/// Gathers what [period] holds now, or null where nothing can be read.
typedef KapyPeriodReader = KapyPeriodRead? Function(RecapPeriod period);

/// A period as a chat about it reads it, gathered on the device the way a
/// recap of it is ([RecapMaterial], [RecapDigest]), so the two agree on what
/// the period holds: its visible notes by the day the notes list shows them
/// on, their voice notes, and its tasks done and still open. Never a hidden
/// or archived note, nor anything in one.
class KapyPeriodRead {
  KapyPeriodRead(this.material, this.digest);

  factory KapyPeriodRead.gather(
    RecapPeriod period, {
    required NotesStore store,
    required TaskBoard tasks,
    required TagStore tags,
    required FolderTree folders,
    required DateTime Function(DateTime) displayTime,
    DateTime? Function(Note note)? ownDay,
  }) => KapyPeriodRead(
    RecapMaterial.gather(
      period,
      store: store,
      tasks: tasks,
      tags: tags,
      displayTime: displayTime,
      ownDay: ownDay,
    ),
    // The live notes only, so a note still being deleted never counts.
    RecapDigest.compute(
      period,
      notes: store.notes,
      tasks: tasks,
      tags: tags,
      folders: folders,
      displayTime: displayTime,
      ownDay: ownDay,
    ),
  );

  final RecapMaterial material;
  final RecapDigest digest;

  RecapPeriod get period => material.period;
  int get notes => digest.counts.notes;
  int get tasks => digest.counts.tasksDone + digest.tasksOpen;
  int get voiceNotes => digest.counts.voiceNotes;

  /// The tag or folder most of its notes carry, as one short plain line, or
  /// null when they carry none. A name is the person's own text, or a shared
  /// note's, so nothing in it reaches the screen or a question but words.
  String? get topic {
    for (final topic in digest.topics) {
      final name = recapTopicName(
        topic.name,
      ).replaceAll(_unseen, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
      if (name.isNotEmpty) return name;
    }
    return null;
  }

  /// What an answer may read: each note and voice note as it is, and the
  /// tasks as one note, each looked at once more on the way ([recapNotesFor]).
  List<ReadNote> sent(NotesStore store, {required DateTime today}) =>
      recapNotesFor(material.items, store, today: today);

  /// The empty chat's promise: "Answers come only from 17–23 Nov: 14 notes,
  /// 12 tasks and 2 voice notes. Hidden notes are never used."
  String get reads {
    String count(int n, String one) => '$n ${n == 1 ? one : '${one}s'}';
    final held = [
      if (notes > 0) count(notes, 'note'),
      if (tasks > 0) count(tasks, 'task'),
      if (voiceNotes > 0) count(voiceNotes, 'voice note'),
    ];
    final list = held.length < 2
        ? held.join()
        : '${held.sublist(0, held.length - 1).join(', ')} and ${held.last}';
    return 'Answers come only from ${period.label}'
        '${list.isEmpty ? '' : ': $list'}. Hidden notes are never used.';
  }

  /// For a period with more notes than an answer reads, why a narrower
  /// question does better; null when every note fits.
  String? get narrower => notes <= RetrievalBudget.cloud.notes
      ? null
      : '${period.label} has $notes notes. Each answer reads the '
            '${RetrievalBudget.cloud.notes} that fit the question best, so a '
            'narrower question gets a fuller answer.';
}

/// Characters that draw nothing or turn text around.
final RegExp _unseen = RegExp(
  r'[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u202a-\u202e\u2066-\u2069]',
);

/// The line a question about [period] starts with, since the model has no
/// clock: "About 17–23 Nov 2026:".
String kapyPeriodLine(RecapPeriod period) {
  final first = period.first;
  final last = period.last;
  final named = switch (period.kind) {
    RecapKind.day =>
      '${SidebarTimestamp.shortWeekday(first)} '
          '${SidebarTimestamp.formatDay(first)}',
    RecapKind.week =>
      first.year == last.year
          ? '${SidebarTimestamp.dayRange(first, last)} ${last.year}'
          : '${SidebarTimestamp.formatDay(first)} – '
                '${SidebarTimestamp.formatDay(last)}',
    RecapKind.month => '${SidebarTimestamp.monthName(first)} ${first.year}',
    RecapKind.year => '${first.year}',
  };
  return 'About $named:';
}

/// [question] as it is sent in a chat about [period]: after [kapyPeriodLine],
/// and the two together within the contract's question length. The chat
/// keeps and shows the question alone.
String kapyPeriodQuestion(RecapPeriod period, String question) {
  final line = kapyPeriodLine(period);
  final room = AnswerRequest.maxQuestionChars - line.length - 1;
  var text = question.length <= room ? question : question.substring(0, room);
  if (text.isNotEmpty) {
    final end = text.codeUnitAt(text.length - 1);
    if (end >= 0xd800 && end < 0xdc00) {
      text = text.substring(0, text.length - 1);
    }
  }
  return '$line\n$text';
}

/// What a person calls [period] on [today]: "this week", "yesterday",
/// "last month", or its label ("10–16 Nov") when it is further away.
String kapyPeriodName(RecapPeriod period, DateTime today) {
  final now = RecapPeriod.containing(
    today,
    period.kind,
    firstWeekday: period.first.weekday,
  );
  final (current, previous) = switch (period.kind) {
    RecapKind.day => ('today', 'yesterday'),
    RecapKind.week => ('this week', 'last week'),
    RecapKind.month => ('this month', 'last month'),
    RecapKind.year => ('this year', 'last year'),
  };
  if (period == now) return current;
  if (period == now.previous) return previous;
  return period.label;
}

/// The empty chat's questions: two that fit any period, and one about the
/// main topic of [read] when it has one.
List<String> kapyPeriodSuggestions(
  RecapPeriod period, {
  required DateTime today,
  KapyPeriodRead? read,
}) {
  final name = kapyPeriodName(period, today);
  final during = name != period.label
      ? name
      : switch (period.kind) {
          RecapKind.day => 'on $name',
          RecapKind.week => 'during $name',
          RecapKind.month || RecapKind.year => 'in $name',
        };
  return [
    'What did I get done $during?',
    'What’s still open from $name?',
    if (read?.topic case final topic?) 'What did I decide about $topic?',
  ];
}
