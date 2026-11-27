import 'dart:math';

import '../data/note.dart';
import '../data/note_attachment.dart';
import '../speech/moments.dart';
import 'retrieval.dart';

/// What a question about one recording reads, and how far into it.
class RecordingRead {
  const RecordingRead({required this.parts, this.readTo});

  /// The recording as the notes a question sends: one, or a long one in
  /// parts, each within the budget's room for a note.
  final List<ReadNote> parts;

  /// Where reading stopped, when the transcript did not fit; null when it
  /// was read to the end.
  final Duration? readTo;
}

/// [ref], in [note], as Kapy AI reads it: the summary's title and points,
/// then the transcript a paragraph a line, each with its time and, when more
/// than one person speaks, its speaker. No other note goes with it.
///
/// Kapy AI Cloud takes 12,000 characters a note and 48,000 in all, so a long
/// transcript goes as up to four parts of one note, about fifty minutes of
/// speech. The device's model reads one part, as much as fits it. Whatever
/// is past the budget is left out from the start of a paragraph, and
/// [RecordingRead.readTo] says where, so the answer can say how much it
/// read.
RecordingRead readRecording(
  Note note,
  NoteVoiceRef ref,
  RetrievalBudget budget,
) {
  final summary = ref.summary;
  final transcript = ref.transcript;
  final lines = <({String text, Duration at})>[
    if (summary != null) ...[
      (text: 'Summary: ${summary.title}', at: Duration.zero),
      for (final point in summary.points) (text: '- $point', at: Duration.zero),
      (text: 'Transcript:', at: Duration.zero),
    ],
  ];
  if (transcript != null) {
    final named = transcript.speakerIds.length > 1;
    for (final paragraph in groupTranscriptParagraphs(transcript.segments)) {
      final at = Duration(milliseconds: paragraph.first.s);
      final speaker = named ? paragraph.first.speaker : null;
      final said = paragraph.map((segment) => segment.t.trim()).join(' ');
      final who = speaker == null ? '' : '${transcript.nameFor(speaker)}: ';
      lines.add((text: '${timeMark(at)} $who$said', at: at));
    }
  }

  final most = min(budget.notes, (budget.chars / budget.charsPerNote).ceil());
  final texts = <String>[];
  var part = StringBuffer();
  var spent = 0;
  Duration? readTo;
  for (final line in lines) {
    final text = line.text.length > budget.charsPerNote
        ? line.text.substring(0, budget.charsPerNote)
        : line.text;
    if (part.isNotEmpty &&
        part.length + 1 + text.length > budget.charsPerNote) {
      texts.add(part.toString());
      part = StringBuffer();
    }
    final cost = text.length + (part.isEmpty ? 0 : 1);
    if (texts.length == most || spent + cost > budget.chars) {
      readTo = line.at;
      break;
    }
    if (part.isNotEmpty) part.write('\n');
    part.write(text);
    spent += cost;
  }
  if (part.isNotEmpty) texts.add(part.toString());

  final named = summary?.title.trim() ?? '';
  final title = named.isEmpty ? note.title : named;
  final short = title.length > _titleChars
      ? title.substring(0, _titleChars)
      : title;
  return RecordingRead(
    parts: [
      for (var i = 0; i < texts.length; i++)
        ReadNote(
          id: note.id,
          title: texts.length == 1
              ? short
              : '$short (part ${i + 1} of ${texts.length})',
          text: texts[i],
          edited: note.updatedAt,
        ),
    ],
    readTo: readTo,
  );
}

/// Within the 200 characters the cloud contract takes for a title, with
/// room left for "(part 2 of 4)".
const int _titleChars = 180;

/// The questions a recording suggests before anything is asked: two that
/// fit any recording, and one about a speaker somebody has named, when more
/// than one person speaks. The person who opens a recording is usually the
/// one who made it, so the named speaker picked is the first who did not
/// speak first, and the one who did only when nobody else is named.
List<String> recordingQuestions(VoiceTranscript? transcript) {
  final speakers = transcript?.speakerIds ?? const <int>[];
  final named = [
    if (speakers.length > 1)
      for (final speaker in speakers)
        if (transcript!.speakers[speaker]?.trim().isNotEmpty ?? false) speaker,
  ];
  final asked =
      named.where((speaker) => speaker != speakers.first).firstOrNull ??
      named.firstOrNull;
  return [
    'What did we decide?',
    'What are the next steps?',
    if (asked != null) 'What did ${transcript!.nameFor(asked)} ask for?',
  ];
}
