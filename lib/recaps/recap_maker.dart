import 'package:flutter/foundation.dart';

import '../ai/answer_engine.dart';
import '../ai/kapy_ai.dart';
import '../ai/kapy_chat_book.dart';
import '../ai/retrieval.dart';
import '../data/folders.dart';
import '../data/local_store.dart';
import '../data/note.dart';
import '../data/notes_store.dart';
import '../data/tags.dart';
import '../data/task_board.dart';
import 'recap_digest.dart';
import 'recap_engine.dart';
import 'recap_material.dart';
import 'recap_period.dart';
import 'recap_plan.dart';
import 'recap_record.dart';
import 'recap_story.dart';

/// What making [period]'s recap takes now, as the drawer shows it before
/// anything is spent: the counts, the plan and what it costs with [model].
class RecapPrice {
  const RecapPrice({
    required this.period,
    required this.digest,
    required this.plan,
    required this.model,
  });

  final RecapPeriod period;

  /// The period's numbers, counted on the device: what goes in.
  final RecapDigest digest;
  final RecapPlan plan;
  final KapyModel model;

  /// Kapy AI credits it uses: none through the person's own account.
  int get credits => plan.credits(model);

  bool get tooLittle => digest.counts.tooLittleFor(period.kind);
}

/// How a try that didn't make its recap ended.
enum RecapEnd {
  /// Nothing was reached and nothing was used.
  offline,

  /// A part failed; the parts made are kept.
  failed,

  /// Kapy AI Cloud's credits ran out.
  noCredits,

  /// Kapy AI Cloud wants someone signed in.
  signIn,

  /// Kapy AI Cloud is part of Pro, and this account has none.
  upgrade,
}

/// A recap being made, or the last try that didn't make it.
class RecapRun {
  RecapRun._(this.period, this.parts, this.started);

  final RecapPeriod period;
  final DateTime started;
  int parts;

  /// Parts back so far, made now or kept from before.
  int made = 0;
  bool stopping = false;

  /// Set once it ended without a recap.
  RecapEnd? end;

  /// The part that failed, from 1, when [end] is [RecapEnd.failed].
  int failedPart = 0;

  /// What Kapy AI Cloud said was left, when [end] is [RecapEnd.noCredits].
  CloudUsage? usage;

  bool get making => end == null;
}

/// Makes recaps with Kapy AI, one at a time, and keeps going when the
/// drawer closes. It never spends more than the drawer quoted.
///
/// It also takes words out of recaps when a note they may have read is
/// hidden or deleted for good, here or through sync. [handled] remembers on
/// this device which ones were dealt with, so reopening a recap looks only
/// at the ones no path saw.
class RecapMaker extends ChangeNotifier {
  RecapMaker({
    required NotesStore notes,
    required KapyChatBook chats,
    required KapyAi ai,
    required TagStore tags,
    required LocalStore local,
    required TaskBoard Function() tasks,
    required FolderTree Function() folders,
    required DateTime Function(DateTime) displayTime,
    required String Function() timeZone,
    required int Function() firstWeekday,
    DateTime? Function(Note note)? ownDay,
    DateTime Function()? now,
    Future<void> Function(Duration wait)? pause,
  }) : _notes = notes,
       _chats = chats,
       _ai = ai,
       _tags = tags,
       _local = local,
       _tasks = tasks,
       _folders = folders,
       _displayTime = displayTime,
       _timeZone = timeZone,
       _firstWeekday = firstWeekday,
       _ownDay = ownDay,
       _now = now ?? DateTime.now,
       _engine = RecapEngine(
         notes: notes,
         chats: chats,
         now: now,
         pause: pause,
       ),
       _handled = {
         for (final id in local.read<List<Object?>>(handledKey) ?? const [])
           if (id is String) id,
       } {
    _notes.addListener(_onNotes);
    _chats.addListener(notifyListeners);
    _ai.addListener(notifyListeners);
    _onNotes();
  }

  final NotesStore _notes;
  final KapyChatBook _chats;
  final KapyAi _ai;
  final TagStore _tags;
  final LocalStore _local;
  final TaskBoard Function() _tasks;
  final FolderTree Function() _folders;
  final DateTime Function(DateTime) _displayTime;
  final String Function() _timeZone;
  final int Function() _firstWeekday;
  final DateTime? Function(Note note)? _ownDay;
  final DateTime Function() _now;
  final RecapEngine _engine;
  final Set<String> _handled;

  /// Where [handled] is kept, on this device only and never synced.
  static const String handledKey = 'recaps.handledGone.v1';

  /// The most ids [handled] keeps, the oldest let go first. One let go only
  /// means a reopen checks that note again, which takes out nothing new.
  static const int handledMax = 2000;

  final Map<RecapPeriod, RecapRun> _runs = {};
  RecapRun? _making;
  Map<String, DateTime> _hidden = const {};
  Set<String> _stones = const {};

  /// The notes hidden or deleted whose words were already taken out of the
  /// recaps here.
  Set<String> get handled => Set.unmodifiable(_handled);

  /// The run going now, if any: one recap is made at a time.
  RecapRun? get making => _making;

  /// [period]'s run: being made, or the last try that ended without a recap.
  RecapRun? runOf(RecapPeriod period) => _runs[period];

  /// How far [period]'s recap has got while it is being made, for the
  /// timeline's pie: parts back, and parts in all.
  ({int made, int parts})? progressOf(RecapPeriod period) {
    final run = _runs[period];
    return run != null && run.making
        ? (made: run.made, parts: run.parts)
        : null;
  }

  /// [period]'s newest recap chat.
  KapyChat? chatOf(RecapPeriod period) => recapChatOf(_engine.recaps, period);

  /// Whether [period] has a recap to watch.
  bool hasRecap(RecapPeriod period) => chatOf(period) != null;

  /// What a recap is made with: the person's default, or Kapy AI Cloud
  /// where that is the device's model, which can't hold a recap. Off Pro, an
  /// account of their own that answers goes before a locked Kapy AI Cloud.
  KapyModel get model {
    final chosen = _ai.defaultModel;
    if (chosen.kind != KapyModelKind.device) return chosen;
    if (_ai.isPro) return KapyModel.cloud;
    for (final account in _ai.accounts) {
      if (account.enabled &&
          account.status == KapyAccountStatus.connected &&
          account.models.isNotEmpty) {
        return account.models.first;
      }
    }
    return KapyModel.cloud;
  }

  /// What stops [model] now, if anything.
  KapyPending? get hold => _ai.recapHold(model);

  CloudUsage? get usage => _ai.cloudUsage;
  bool get onTrial => _ai.onTrial;

  /// Whether each Kapy AI answer, as in a chat about a period, uses a
  /// credit: it does on Kapy AI Cloud.
  bool get askCosts => _ai.model.kind == KapyModelKind.cloud;

  /// Today, as the notes list shows days.
  DateTime get today {
    final shown = _displayTime(_now());
    return DateTime(shown.year, shown.month, shown.day);
  }

  /// The [DateTime.weekday] weeks start on.
  int get firstWeekday => _firstWeekday();

  /// [instant] as the notes list shows times.
  DateTime shown(DateTime instant) => _displayTime(instant);

  /// What making [period]'s recap takes now.
  RecapPrice quote(RecapPeriod period) => RecapPrice(
    period: period,
    digest: _digest(period),
    plan: _engine.plan(_material(period)),
    model: model,
  );

  /// [period]'s newest recap as a story, read against its notes as they are
  /// now, leaving alone the notes [handled] says were dealt with.
  RecapStory? story(RecapPeriod period) {
    final chat = chatOf(period);
    return chat == null
        ? null
        : RecapStory.read(chat, _material(period), handled: _handled);
  }

  /// [period]'s newest recap's record.
  RecapRecord? recordOf(RecapPeriod period) => switch (chatOf(period)) {
    final chat? => recapOf(chat),
    null => null,
  };

  /// How many of [period]'s notes changed since its recap was made.
  int changesSince(RecapPeriod period) =>
      recordOf(period)?.changesSince(_material(period)) ?? 0;

  /// Keeps a recap chat the viewer pruned as it opened.
  void keep(KapyChat chat) => _chats.put(chat);

  /// Makes [quoted]'s recap. When it would now cost more than [quoted]
  /// said, or its model changed, nothing is spent and listeners hear, so the
  /// drawer quotes again. Returns whether the recap was asked for.
  Future<bool> make(RecapPrice quoted) async {
    if (_making != null) return false;
    final period = quoted.period;
    final fresh = quote(period);
    if (fresh.model != quoted.model ||
        fresh.credits > quoted.credits ||
        fresh.tooLittle) {
      notifyListeners();
      return false;
    }
    final model = fresh.model;
    final run = RecapRun._(period, fresh.plan.parts, _now());
    _runs[period] = run;
    final engine = _ai.recapEngine(model);
    final held = hold;
    if (engine == null || held != null) {
      run
        ..failedPart = 1
        ..end = switch (held) {
          KapyCloudLocked(signIn: true) => RecapEnd.signIn,
          KapyCloudLocked() => RecapEnd.upgrade,
          _ => RecapEnd.failed,
        };
      notifyListeners();
      return false;
    }
    final usage = this.usage;
    if (model.kind == KapyModelKind.cloud &&
        usage != null &&
        usage.remaining < fresh.credits) {
      run
        ..usage = usage
        ..end = RecapEnd.noCredits;
      notifyListeners();
      return false;
    }

    _making = run;
    notifyListeners();
    final paid = _Paid(engine);
    RecapOutcome outcome;
    try {
      outcome = await _engine.make(
        fresh.plan,
        digest: () => _digest(period),
        model: model,
        engine: paid,
        budget: RetrievalBudget.cloud,
        timeZone: _timeZone(),
        firstWeekday: period.kind == RecapKind.week
            ? period.first.weekday
            : _firstWeekday(),
        onPart: (made, parts) {
          run
            ..made = made
            ..parts = parts;
          notifyListeners();
        },
        stopped: () => run.stopping,
      );
    } catch (error) {
      debugPrint('KapyNotes: a recap could not be made: ${error.runtimeType}');
      outcome = RecapStopped(
        const AnswerFailed('Something went wrong.'),
        run.made + 1,
        run.parts,
      );
    }
    _making = null;
    switch (outcome) {
      case RecapMade() || RecapStopped(failure: null):
        _runs.remove(period);
      case RecapStopped(:final failure?, :final part, :final parts):
        if (failure case AnswerLimitReached(:final usage)) run.usage = usage;
        run
          ..failedPart = part
          ..parts = parts
          ..end = switch (failure) {
            AnswerOffline() when paid.answers == 0 => RecapEnd.offline,
            AnswerLimitReached() => RecapEnd.noCredits,
            AnswerSignInNeeded() => RecapEnd.signIn,
            AnswerProNeeded() => RecapEnd.upgrade,
            _ => RecapEnd.failed,
          };
    }
    notifyListeners();
    return true;
  }

  /// Stops [period]'s recap before its next part. The parts back are kept,
  /// so making it again costs only what is left.
  void stop(RecapPeriod period) {
    final run = _runs[period];
    if (run == null || !run.making) return;
    run.stopping = true;
    notifyListeners();
  }

  /// About how long [run] has left, from how long its parts took so far.
  Duration timeLeft(RecapRun run) {
    final each = run.made == 0
        ? const Duration(seconds: 15)
        : _now().difference(run.started) ~/ run.made;
    return each * (run.parts - run.made);
  }

  RecapMaterial _material(RecapPeriod period) => RecapMaterial.gather(
    period,
    store: _notes,
    tasks: _tasks(),
    tags: _tags,
    displayTime: _displayTime,
    ownDay: _ownDay,
  );

  /// The numbers, from the notes the list shows, so a note pending delete
  /// never counts.
  RecapDigest _digest(RecapPeriod period) => RecapDigest.compute(
    period,
    notes: _notes.notes,
    tasks: _tasks(),
    tags: _tags,
    folders: _folders(),
    displayTime: _displayTime,
    ownDay: _ownDay,
  );

  /// Finds the notes hidden, or deleted for good, since the last look, here
  /// or through sync, and prunes the recaps that may have read them. A note
  /// moved to a space leaves a tombstone too but is still here, so it is no
  /// delete, and a delete held for Undo has no tombstone until it's final.
  /// The first look, at launch, sees every one as new: those made before a
  /// recap, or that it never read, are passed over at once.
  void _onNotes() {
    final live = {for (final note in _notes.allNotes) note.id};
    final hidden = {
      for (final note in _notes.allNotes) note.id: ?note.hiddenAt,
    };
    final stones = <String>{};
    final gone = <String, DateTime>{};
    for (final stone in _notes.tombstones) {
      final key =
          '${stone.spaceId}/${stone.id}/${stone.deletedAt.millisecondsSinceEpoch}';
      stones.add(key);
      if (!_stones.contains(key) && !live.contains(stone.id)) {
        gone[stone.id] = stone.deletedAt;
      }
    }
    for (final MapEntry(key: id, value: at) in hidden.entries) {
      if (_hidden[id] != at) gone[id] = at;
    }
    final shown = {
      for (final id in _hidden.keys)
        if (!hidden.containsKey(id) && live.contains(id)) id,
    };
    _hidden = hidden;
    _stones = stones;
    if (_handled.any(shown.contains)) {
      _handled.removeAll(shown);
      _save();
    }
    if (gone.isNotEmpty) _prune(gone);
  }

  /// Takes [gone]'s words out of each recap made before they went whose
  /// filters may hold them, and keeps them as handled.
  void _prune(Map<String, DateTime> gone) {
    final pruned = <String>{};
    for (final chat in _engine.recaps) {
      final record = recapOf(chat);
      if (record == null) continue;
      final ids = {
        for (final MapEntry(key: id, value: at) in gone.entries)
          if (at.isAfter(record.madeAt) &&
              (record.allRead?.mayHold(id) ?? true))
            id,
      };
      if (ids.isEmpty) continue;
      final story = RecapStory.read(
        chat,
        _material(record.period),
        handled: _handled.difference(ids),
      );
      if (story != null) {
        if (recapPruned(story, now: _now()) case final kept?) _chats.put(kept);
      }
      pruned.addAll(ids);
    }
    if (pruned.isEmpty) return;
    _handled
      ..removeAll(pruned)
      ..addAll(pruned);
    _save();
  }

  void _save() {
    final ids = _handled.toList();
    if (ids.length > handledMax) {
      _handled
        ..clear()
        ..addAll(ids.sublist(ids.length - handledMax));
    }
    _local.put(handledKey, _handled.toList());
  }

  @override
  void dispose() {
    _notes.removeListener(_onNotes);
    _chats.removeListener(notifyListeners);
    _ai.removeListener(notifyListeners);
    super.dispose();
  }
}

/// [engine], counting the answers that came back: what Kapy AI Cloud
/// counts, since a call that fails is handed back.
class _Paid implements AnswerEngine {
  _Paid(this.engine);

  final AnswerEngine engine;
  int answers = 0;

  @override
  Future<String> answer(KapyModel model, AnswerRequest request) async {
    final text = await engine.answer(model, request);
    answers++;
    return text;
  }
}
