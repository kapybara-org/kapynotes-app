import '../ai/answer_engine.dart';
import '../ai/kapy_ai.dart';
import '../ai/kapy_chat_book.dart';
import '../ai/retrieval.dart';
import '../data/notes_store.dart';
import 'recap_digest.dart';
import 'recap_filter.dart';
import 'recap_lines.dart';
import 'recap_material.dart';
import 'recap_period.dart';
import 'recap_plan.dart';
import 'recap_record.dart';

/// How making a recap ended.
sealed class RecapOutcome {
  const RecapOutcome();
}

/// It was made, and [chat] holds it.
class RecapMade extends RecapOutcome {
  const RecapMade(this.chat, this.lines);

  final KapyChat chat;
  final RecapLines lines;
}

/// Part [part] of [parts] was not made: [failure] says why, or it is null
/// when the person stopped. The parts before it are kept, so making it
/// again starts there and costs only what is left.
class RecapStopped extends RecapOutcome {
  const RecapStopped(this.failure, this.part, this.parts);

  final AnswerFailure? failure;
  final int part;
  final int parts;
}

/// Makes recaps with Kapy AI, a call at a time as [RecapPlan] lays out, and
/// keeps each in the chat book as a recap chat.
///
/// A digest that came back is kept for as long as the app runs, the way a
/// translation's parts are, under what its days held: asking again for the
/// same days asks only for what is left, so no part is paid for twice.
class RecapEngine {
  RecapEngine({
    required NotesStore notes,
    required KapyChatBook chats,
    DateTime Function()? now,
    Future<void> Function(Duration wait)? pause,
  }) : _notes = notes,
       _chats = chats,
       _now = now ?? DateTime.now,
       _pause = pause ?? Future<void>.delayed;

  final NotesStore _notes;
  final KapyChatBook _chats;
  final DateTime Function() _now;
  final Future<void> Function(Duration wait) _pause;
  final Map<String, RecapPiece> _kept = {};

  /// The most digests kept at once, the oldest let go first.
  static const int keptMax = 64;

  /// How often a call asked too fast is asked again, and the longest wait
  /// before each.
  static const int tooFastTries = 3;
  static const Duration longestWait = Duration(minutes: 1);

  /// The recap chats, newest first.
  List<KapyChat> get recaps => [
    for (final chat in _chats.chats)
      if (chat.recap != null) chat,
  ];

  /// What making a recap of [material] takes now: the digests kept, and
  /// for a year the months whose own recaps were made once they were over,
  /// cost nothing.
  RecapPlan plan(RecapMaterial material) {
    final months = <int, RecapRecord>{};
    if (material.period.kind == RecapKind.year) {
      for (final chat in recaps) {
        final record = recapOf(chat);
        if (record == null ||
            record.digest == null ||
            record.period.kind != RecapKind.month ||
            record.period.first.year != material.period.first.year ||
            record.fingerprint !=
                recapFingerprint(
                  material.within(record.period.first, record.period.last),
                )) {
          continue;
        }
        final month = record.period.first.month;
        if (months[month]?.madeAt.isAfter(record.madeAt) ?? false) continue;
        months[month] = record;
      }
    }
    return RecapPlan.of(
      material,
      ready: (slice) => switch (months[slice.first.month]?.digest) {
        final digest? when slice.kind == RecapKind.year => RecapPiece(digest),
        _ => _kept[slice.key],
      },
    );
  }

  /// Makes [plan]'s recap with [model] through [engine], sending what
  /// [budget] allows a call. [digest] gives its numbers, and [timeZone] and
  /// [firstWeekday] say how its days were worked out. [onPart] hears each
  /// part come back; [stopped] is asked before each call.
  Future<RecapOutcome> make(
    RecapPlan plan, {
    required RecapDigest digest,
    required KapyModel model,
    required AnswerEngine engine,
    required RetrievalBudget budget,
    required String timeZone,
    required int firstWeekday,
    void Function(int made, int parts)? onPart,
    bool Function()? stopped,
  }) async {
    final period = plan.period;
    final material = plan.material;
    final started = _now();
    Future<RecapPiece> ask(RecapSlice slice) async {
      final items = material.within(slice.first, slice.last);
      final notes = packRecap(
        recapNotesFor(items, _notes, today: _now()),
        budget,
      );
      final piece = RecapPiece(
        _cut(
          await _ask(
            engine,
            model,
            recapDigestQuestion(period, slice.label),
            notes,
          ),
          recapDigestChars * 4 ~/ 3,
        ),
        (RecapSent()..heard(notes, items)).notes,
      );
      _keep(slice.key, piece);
      return piece;
    }

    final sent = RecapSent();
    final pieces = <RecapPiece>[];
    for (final slice in plan.slices) {
      if (stopped?.call() ?? false) {
        return RecapStopped(null, pieces.length + 1, plan.parts);
      }
      try {
        pieces.add(slice.ready ?? await ask(slice));
      } on AnswerFailure catch (failure) {
        return RecapStopped(failure, pieces.length + 1, plan.parts);
      }
      onPart?.call(pieces.length, plan.parts);
    }
    if (stopped?.call() ?? false) {
      return RecapStopped(null, pieces.length + 1, plan.parts);
    }

    // A part that read a note gone since (hidden, archived or deleted) is
    // left out rather than asked again, so nothing taken from that note goes
    // out and the recap never costs more than its plan said.
    final readable = _readable();
    final gone = <String>{};
    final digests = <ReadNote>[];
    final read = <RecapRead>[];
    RecapRead part(DateTime first, DateTime last, List<RecapItem> items) => (
      first: period.indexOf(first)!,
      last: period.indexOf(last)!,
      notes: RecapFilter.of([for (final item in items) item.note.id]),
    );

    for (final (index, slice) in plan.slices.indexed) {
      final piece = pieces[index];
      final within = material.within(slice.first, slice.last);
      final hidden = {
        for (final item in within)
          if (!readable.contains(item.note.id)) item.note.id,
      };
      if (hidden.isNotEmpty) {
        for (final MapEntry(key: title, value: id) in piece.sent.entries) {
          if (hidden.contains(id)) gone.add(title);
        }
        continue;
      }
      sent.notes.addAll(piece.sent);
      read.add(part(slice.first, slice.last, within));
      if (period.kind == RecapKind.year) sent.months.add(slice.first.month);
      digests.add(recapNote('', slice.label, piece.text, slice.last));
    }

    final rest = plan.rest;
    final items = rest == null
        ? const <RecapItem>[]
        : material.within(rest.$1, rest.$2);
    if (rest != null && items.isNotEmpty) {
      read.add(part(rest.$1, rest.$2, items));
    }
    final notes = packRecap([
      ...digests,
      ...recapNotesFor(items, _notes, today: _now()),
    ], budget);
    sent.heard(notes, items);
    var answer = '';
    if (notes.isNotEmpty) {
      try {
        answer = await _ask(engine, model, recapQuestion(period), notes);
      } on AnswerFailure catch (failure) {
        return RecapStopped(failure, plan.parts, plan.parts);
      }
    }
    final stillReadable = _readable();
    for (final MapEntry(key: title, value: id) in sent.notes.entries) {
      if (!stillReadable.contains(id)) gone.add(title);
    }
    sent.notes.removeWhere((_, id) => !stillReadable.contains(id));
    sent.voices.removeWhere(
      (_, voice) => !stillReadable.contains(voice.noteId),
    );
    final lines = readRecapLines(
      [
        for (final line in answer.split('\n'))
          if (!_names(line, gone)) line,
      ].join('\n'),
      period: period,
      sent: sent,
    );
    final now = _now();
    final over = DateTime(now.year, now.month, now.day).isAfter(period.last);
    final record = RecapRecord(
      period: period,
      timeZone: timeZone,
      firstWeekday: firstWeekday,
      madeAt: started,
      numbers: RecapNumbers.of(digest, material),
      fingerprint: material.fingerprint,
      digest: period.kind == RecapKind.month && over && lines.digest.isNotEmpty
          ? lines.digest
          : null,
      read: read,
    );
    final chat = recapChat(
      recapChatOf(recaps, period),
      record: record,
      answer: lines.text.isEmpty ? recapTitle(period) : lines.text,
      model: model,
      now: now,
    );
    _chats.put(chat);
    onPart?.call(plan.parts, plan.parts);
    return RecapMade(chat, lines);
  }

  /// One call, asked again after the wait a too-fast answer names.
  Future<String> _ask(
    AnswerEngine engine,
    KapyModel model,
    String question,
    List<ReadNote> notes,
  ) async {
    for (var tries = 1; ; tries++) {
      try {
        return await engine.answer(
          model,
          AnswerRequest(question: question, notes: notes, today: _now()),
        );
      } on AnswerTooFast catch (fast) {
        if (tries == tooFastTries) rethrow;
        await _pause(fast.wait > longestWait ? longestWait : fast.wait);
      }
    }
  }

  /// The ids of the notes a recap may still read: not hidden, archived or
  /// deleted, now.
  Set<String> _readable() => {for (final note in _notes.notes) note.id};

  void _keep(String key, RecapPiece piece) {
    _kept.remove(key);
    _kept[key] = piece;
    while (_kept.length > keptMax) {
      _kept.remove(_kept.keys.first);
    }
  }
}

/// Whether [text] names any of [titles], which are in lower case.
bool _names(String text, Set<String> titles) {
  final lower = text.toLowerCase();
  return titles.any((title) => title.isNotEmpty && lower.contains(title));
}

/// What came back, within [max] characters: a model asked for a digest of
/// some length can still write more.
String _cut(String text, int max) =>
    text.length <= max ? text : text.substring(0, max);
