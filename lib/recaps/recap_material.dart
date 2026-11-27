import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as hashes;

import '../ai/recording_context.dart';
import '../ai/retrieval.dart';
import '../data/note.dart';
import '../data/note_attachment.dart';
import '../data/notes_store.dart';
import '../data/task_board.dart';
import '../ui/notes_grouping.dart';
import '../ui/sidebar_timestamp.dart';
import 'recap_digest.dart';
import 'recap_lines.dart';
import 'recap_period.dart';

enum RecapSource { note, voice, taskDone, taskOpen }

/// One thing a recap reads, on the day it belongs to. [note]'s id is the
/// note it comes from, so [readableNotes] looks at it again on its way out.
/// A task is one line of the tasks note each call is sent.
class RecapItem {
  const RecapItem(
    this.source,
    this.note,
    this.day,
    this.key, {
    this.voice,
    this.taskId,
  });

  final RecapSource source;
  final ReadNote note;
  final DateTime day;

  /// What it is and which version: a fingerprint is made of these.
  final String key;
  final NoteVoiceRef? voice;
  final String? taskId;
}

/// What a period gives a recap made with Kapy AI, chosen on the device: its
/// visible notes, each recording in them as its summary and transcript, and
/// its tasks done and still open. Never a hidden or archived note, nor
/// anything in one.
class RecapMaterial {
  RecapMaterial._(this.period, this.items, this.edited);

  factory RecapMaterial.gather(
    RecapPeriod period, {
    required NotesStore store,
    required TaskBoard tasks,
    required DateTime Function(DateTime) displayTime,
    DateTime? Function(Note note)? ownDay,
  }) {
    final held = recapNotes(
      period,
      notes: store.allNotes,
      displayTime: displayTime,
      ownDay: ownDay,
    );
    final days = {for (final entry in held.entries) entry.key.id: entry.value};
    final visible = {
      for (final note in store.allNotes)
        if (!note.isHidden && !note.isArchived) note.id,
    };
    final items = <RecapItem>[];
    for (final MapEntry(key: note, value: day) in held.entries) {
      final at = note.updatedAt.millisecondsSinceEpoch;
      final text = [
        for (final line in note.body.split('\n'))
          if (line.replaceAll(NoteAttachmentRef.placeholder, '').trim()
              case final kept when kept.isNotEmpty)
            kept,
      ].join('\n');
      if (text.isNotEmpty) {
        items.add(
          RecapItem(
            RecapSource.note,
            ReadNote(
              id: note.id,
              title: note.title,
              text: text,
              edited: note.updatedAt,
            ),
            day,
            'n:${note.id}:$at',
          ),
        );
      }
      for (final ref in note.attachments.whereType<NoteVoiceRef>()) {
        if (ref.summary == null && ref.transcript == null) continue;
        final read = readRecording(note, ref, _oneNote).parts;
        if (read.isEmpty) continue;
        items.add(
          RecapItem(
            RecapSource.voice,
            read.first,
            day,
            'v:${note.id}:${ref.hash}:$at',
            voice: ref,
          ),
        );
      }
    }
    for (final task in tasks.done) {
      final day = dayShown(task.doneAt!, displayTime);
      if (!visible.contains(task.note.id) || !period.contains(day)) continue;
      items.add(_task(RecapSource.taskDone, task, day));
    }
    for (final task in tasks.open) {
      final day = days[task.note.id];
      if (day != null) items.add(_task(RecapSource.taskOpen, task, day));
    }
    items.sort((a, b) {
      final byDay = a.day.compareTo(b.day);
      if (byDay != 0) return byDay;
      final bySource = a.source.index.compareTo(b.source.index);
      return bySource != 0 ? bySource : a.note.edited.compareTo(b.note.edited);
    });
    return RecapMaterial._(period, List.unmodifiable(items), {
      for (final note in held.keys) note.id: note.updatedAt,
    });
  }

  final RecapPeriod period;
  final List<RecapItem> items;

  /// The period's notes, and when each was last edited.
  final Map<String, DateTime> edited;

  List<RecapItem> within(DateTime first, DateTime last) => [
    for (final item in items)
      if (!item.day.isBefore(first) && !item.day.isAfter(last)) item,
  ];

  /// A short fingerprint of everything in the period.
  String get fingerprint => recapFingerprint(items);

  /// What a made recap's lines are checked against when it opens again:
  /// everything the period holds now, so a highlight of a note hidden since
  /// is dropped.
  RecapSent get readable {
    final sent = RecapSent(
      months: {
        if (period.kind == RecapKind.year)
          for (final item in items) item.day.month,
      },
    );
    for (final item in items) {
      _hear(sent, item);
    }
    return sent;
  }
}

/// A recording as one note, as long as a note may be.
const RetrievalBudget _oneNote = RetrievalBudget(
  notes: 1,
  chars: 12000,
  charsPerNote: 12000,
);

RecapItem _task(RecapSource source, TaskItem task, DateTime day) => RecapItem(
  source,
  ReadNote(
    id: task.note.id,
    title: '',
    text: task.words,
    edited: task.note.updatedAt,
  ),
  day,
  '${source == RecapSource.taskDone ? 'd' : 'o'}:${task.id}:'
  '${task.doneAt?.millisecondsSinceEpoch ?? ''}',
  taskId: task.id,
);

/// A short fingerprint of [items], the same for the same versions of the
/// same things.
String recapFingerprint(Iterable<RecapItem> items) => hashes.sha256
    .convert(
      utf8.encode(([for (final item in items) item.key]..sort()).join(',')),
    )
    .toString()
    .substring(0, 16);

/// [items] as the notes a call sends, after [readableNotes] has looked at
/// each one last time: each note and voice note as it is, and the tasks as
/// one note. Every line that starts like a recap's label is defanged.
List<ReadNote> recapNotesFor(
  List<RecapItem> items,
  NotesStore store, {
  required DateTime today,
}) {
  final archived = {
    for (final note in store.allNotes)
      if (note.isArchived) note.id,
  };
  final readable = readableNotes(store, [
    for (final item in items)
      if (!archived.contains(item.note.id)) item.note,
  ]).toSet();
  final kept = [
    for (final item in items)
      if (readable.contains(item.note)) item,
  ];
  List<String> tasks(RecapSource source) => [
    for (final item in kept)
      if (item.source == source)
        '- ${item.note.text.replaceAll('\n', ' ')} '
            '(${SidebarTimestamp.weekdayAndDay(item.day)})',
  ];
  final done = tasks(RecapSource.taskDone);
  final open = tasks(RecapSource.taskOpen);
  return [
    for (final item in kept)
      if (item.source == RecapSource.note || item.source == RecapSource.voice)
        recapNote(
          item.note.id,
          item.note.title,
          item.note.text,
          item.note.edited,
        ),
    if (done.isNotEmpty || open.isNotEmpty)
      recapNote(
        '',
        'Tasks',
        [
          if (done.isNotEmpty) ...['Done:', ...done],
          if (open.isNotEmpty) ...['Still open:', ...open],
        ].join('\n'),
        today,
      ),
  ];
}

/// A note as a recap sends it, its title within the contract's 200
/// characters and nothing in it that reads like a label.
ReadNote recapNote(String id, String title, String text, DateTime edited) =>
    ReadNote(
      id: id,
      title: _cutTitle(recapDefanged(title).replaceAll('\n', ' ')),
      text: recapDefanged(text),
      edited: edited,
    );

String _cutTitle(String title) =>
    title.length <= _titleMax ? title : _within(title, _titleMax);

const int _titleMax = 200;

/// The least of a note worth sending: its title and an opening line or two.
const int _floor = 300;

/// [notes] within [budget]: at most its count of notes, each within its
/// characters a note, and all of them within its characters in all.
///
/// Past the count, the shortest notes go together into one, each as its
/// first lines. Past the characters in all, the longest are cut to the
/// same length, at a line, so each keeps its title and opening lines;
/// a note is left out only when that would leave less than [_floor] each.
List<ReadNote> packRecap(List<ReadNote> notes, RetrievalBudget budget) {
  var sized = [for (final note in notes) _cutNote(note, budget.charsPerNote)];
  if (sized.length > budget.notes) {
    final byLength = [for (var i = 0; i < sized.length; i++) i]
      ..sort((a, b) => sized[b].text.length.compareTo(sized[a].text.length));
    final own = byLength.take(max(0, budget.notes - 1)).toSet();
    final folded = [
      for (var i = 0; i < sized.length; i++)
        if (!own.contains(i)) sized[i],
    ];
    sized = [
      for (var i = 0; i < sized.length; i++)
        if (own.contains(i)) sized[i],
      _cutNote(
        ReadNote(
          id: '',
          title: _bundle,
          text: [
            for (final note in folded)
              '- ${note.title}: '
                  '${note.text.split('\n').skip(1).take(2).join(' / ')}',
          ].join('\n'),
          edited: folded.map((note) => note.edited).reduce(_later),
        ),
        budget.charsPerNote,
      ),
    ];
  }
  int total(int cap) =>
      sized.fold(0, (sum, note) => sum + min(note.text.length, cap));
  if (total(budget.charsPerNote) > budget.chars) {
    var low = 0;
    var high = budget.charsPerNote;
    while (low < high) {
      final mid = (low + high + 1) ~/ 2;
      if (total(mid) <= budget.chars) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    final cap = max(low, _floor);
    sized = [for (final note in sized) _cutNote(note, cap)];
  }
  while (sized.isNotEmpty &&
      sized.fold(0, (sum, note) => sum + note.text.length) > budget.chars) {
    sized.removeLast();
  }
  return sized;
}

/// The note the notes past a call's count go into together.
const String _bundle = 'More notes';

extension RecapHeard on RecapSent {
  /// Adds the notes and voice notes of [items] that [packed] sent: each one
  /// with a note of its own, and each one whose line in [_bundle] survived.
  void heard(List<ReadNote> packed, List<RecapItem> items) {
    final own = {
      for (final note in packed)
        if (note.id.isNotEmpty) note.title.toLowerCase(),
    };
    final folded = [
      for (final note in packed)
        if (note.id.isEmpty && note.title == _bundle) note.text.toLowerCase(),
    ].join('\n');
    for (final item in items) {
      final title = _sentTitle(item);
      if (own.contains(title) || folded.contains('- $title:')) {
        _hear(this, item);
      }
    }
  }
}

/// [item]'s title as a call sends it, in lower case.
String _sentTitle(RecapItem item) => recapNote(
  item.note.id,
  item.note.title,
  '',
  item.note.edited,
).title.toLowerCase();

/// Adds [item] to [sent] when it is a note or a voice note.
void _hear(RecapSent sent, RecapItem item) {
  if (item.source != RecapSource.note && item.source != RecapSource.voice) {
    return;
  }
  final title = _sentTitle(item);
  sent.notes[title] = item.note.id;
  if (item.voice case final ref?) {
    sent.voices[title] = (noteId: item.note.id, ref: ref);
  }
}

DateTime _later(DateTime a, DateTime b) => a.isAfter(b) ? a : b;

ReadNote _cutNote(ReadNote note, int cap) => note.text.length <= cap
    ? note
    : ReadNote(
        id: note.id,
        title: note.title,
        text: _within(note.text, cap),
        edited: note.edited,
      );

/// [text] in at most [cap] characters, at the end of a line when one ends
/// in them, and never through a character that takes two.
String _within(String text, int cap) {
  var cut = text.substring(0, cap);
  final line = cut.lastIndexOf('\n');
  if (line > 0) {
    cut = cut.substring(0, line);
  } else if (cut.isNotEmpty &&
      cut.codeUnitAt(cut.length - 1) >= 0xd800 &&
      cut.codeUnitAt(cut.length - 1) < 0xdc00) {
    cut = cut.substring(0, cut.length - 1);
  }
  return cut;
}
