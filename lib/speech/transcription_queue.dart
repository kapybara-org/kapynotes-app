import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/blob_store.dart';
import '../data/local_store.dart';
import '../data/note_attachment.dart';
import '../data/notes_store.dart';
import '../data/voice_prefs.dart';
import 'cloud_transcriber.dart';
import 'summarizer.dart';
import 'transcriber.dart';
import '../sync/sync_api.dart';
import '../ui/editor/voice_chip.dart';
import 'speech_api.dart';

/// Which half of the work an entry is up to.
enum TranscriptionStage { transcribe, summarize }

/// One recording waiting to become words.
class TranscriptionEntry {
  final String noteId;
  final String hash;

  /// Names one *intent*: reused by every retry, so the server bills once.
  final String requestId;

  /// Filled by the transcribe response; the summarise stage needs it.
  final String? jobId;
  final String? lang;
  final TranscriptionStage stage;
  final int attempts;
  final int nextAttemptAt;
  final String? lastError;

  const TranscriptionEntry({
    required this.noteId,
    required this.hash,
    required this.requestId,
    this.jobId,
    this.lang,
    this.stage = TranscriptionStage.transcribe,
    this.attempts = 0,
    this.nextAttemptAt = 0,
    this.lastError,
  });

  TranscriptionEntry copyWith({
    String? jobId,
    String? lang,
    TranscriptionStage? stage,
    int? attempts,
    int? nextAttemptAt,
    Object? lastError = _keep,
  }) => TranscriptionEntry(
    noteId: noteId,
    hash: hash,
    requestId: requestId,
    jobId: jobId ?? this.jobId,
    lang: lang ?? this.lang,
    stage: stage ?? this.stage,
    attempts: attempts ?? this.attempts,
    nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
    lastError: identical(lastError, _keep)
        ? this.lastError
        : lastError as String?,
  );

  static const Object _keep = Object();

  Map<String, Object?> toJson() => {
    'noteId': noteId,
    'hash': hash,
    'requestId': requestId,
    if (jobId != null) 'jobId': jobId,
    if (lang != null) 'lang': lang,
    'stage': stage.name,
    'attempts': attempts,
    'nextAttemptAt': nextAttemptAt,
    if (lastError != null) 'lastError': lastError,
  };

  static TranscriptionEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final noteId = raw['noteId'];
    final hash = raw['hash'];
    final requestId = raw['requestId'];
    if (noteId is! String || hash is! String || requestId is! String) {
      return null;
    }
    return TranscriptionEntry(
      noteId: noteId,
      hash: hash,
      requestId: requestId,
      jobId: raw['jobId'] is String ? raw['jobId']! as String : null,
      lang: raw['lang'] is String ? raw['lang']! as String : null,
      stage: raw['stage'] == 'summarize'
          ? TranscriptionStage.summarize
          : TranscriptionStage.transcribe,
      attempts: raw['attempts'] is int ? raw['attempts']! as int : 0,
      nextAttemptAt: raw['nextAttemptAt'] is int
          ? raw['nextAttemptAt']! as int
          : 0,
      lastError: raw['lastError'] is String
          ? raw['lastError']! as String
          : null,
    );
  }
}

/// Turns recordings into transcripts and summaries, surviving everything.
///
/// A queue rather than a call at the end of recording, because none of the
/// things that make it fail are unusual: the device is offline, the user has
/// not agreed yet, the month's minutes are gone, the app was quit halfway. All
/// of those have to be recoverable without the user doing anything, and none
/// of them may lose the recording — which is already safe on disk before this
/// is ever asked to do anything.
///
/// Entries live in their own [LocalStore] file, flushed on every state change,
/// so a kill between two stages resumes rather than restarts.
class TranscriptionQueue extends ChangeNotifier {
  TranscriptionQueue({
    required LocalStore store,
    required NotesStore notes,
    required BlobStore blobs,
    required VoicePrefs prefs,
    SpeechApi? Function()? api,
    Summarizer? Function()? summarizer,
    Transcriber? Function()? transcriber,
  }) : _store = store,
       _notes = notes,
       _blobs = blobs,
       _prefs = prefs,
       _api = api ?? (() => null),
       _summarizer = summarizer ?? (() => null),
       _transcriber = transcriber ?? _cloudOnly(api ?? (() => null));

  final LocalStore _store;
  final NotesStore _notes;
  final BlobStore _blobs;
  final VoicePrefs _prefs;
  final SpeechApi? Function() _api;

  /// Where summaries get written. Null in a build with no summariser wired
  /// up at all, which is every test that only cares about transcripts.
  final Summarizer? Function() _summarizer;

  /// Where recordings get turned into words. In the app it is a
  /// [RoutingTranscriber] holding both the server and this device, so it is
  /// never null and the *preference* decides which one runs.
  final Transcriber? Function() _transcriber;

  /// What a queue given only a [SpeechApi] transcribes with.
  ///
  /// The seam arrived long after the queue did, and "an api and nothing else"
  /// has always meant "transcribe in the cloud". Keeping that true here rather
  /// than at each call site means no caller — and no test — has to know the
  /// seam exists to get the behaviour it always had.
  static Transcriber? Function() _cloudOnly(SpeechApi? Function() api) {
    final cloud = CloudTranscriber(api);
    // Still null when signed out, because that is what the drain gate reads
    // to decide there is nothing it can do for this entry.
    return () => api() == null ? null : cloud;
  }

  static const String _key = 'transcriptions.v1';

  /// Five attempts, then it waits for the user. Past that the failure is not
  /// transient and retrying is just noise on someone's battery.
  static const int maxAttempts = 5;

  static const Duration baseBackoff = Duration(seconds: 5);
  static const Duration maxBackoff = Duration(minutes: 10);

  /// The first wait after a failure; each one after it is double. Settable
  /// so a test can watch a retry happen without waiting five real seconds.
  Duration backoff = baseBackoff;

  /// Wakes the queue for the next attempt it has scheduled.
  ///
  /// Without this, a backed-off entry only ran again at the next launch, the
  /// next recording, or a press of Retry. Three attempts in a minute and then
  /// nothing — which the chip reported as "Transcribing…" — was the whole of
  /// "it takes forever".
  Timer? _wakeup;

  /// The session the queue last ran against; see [_forgiveRejectedSession].
  SpeechApi? _sessionSeen;
  final List<TranscriptionEntry> _entries = [];
  final Set<String> _running = {};
  bool _loaded = false;
  bool _online = true;
  bool _draining = false;

  /// Set when the server says consent is needed, so the app can offer the
  /// sheet exactly once rather than on every drain.
  bool needsConsent = false;

  /// Set when the month's minutes are gone, with the numbers to explain it.
  SpeechUsage? exhausted;

  List<TranscriptionEntry> get entries => List.unmodifiable(_entries);

  /// Whether the device believes it can reach the server. An offline attempt
  /// is not a failure and must never count against [maxAttempts].
  set online(bool value) => _online = value;

  /// Reads the queue file, then the entries in it.
  ///
  /// [load] alone only looks at what the store already holds, and a store that
  /// was never opened holds nothing and has nowhere to write: every entry was
  /// dropped on the floor at the first restart, and the chip forgot what it
  /// had been waiting on.
  Future<void> open() async {
    await _store.load();
    load();
  }

  void load() {
    if (_loaded) return;
    _loaded = true;
    final raw = _store.data[_key];
    if (raw is List) {
      for (final item in raw) {
        final entry = TranscriptionEntry.fromJson(item);
        if (entry != null) _entries.add(entry);
      }
    }
  }

  /// Adds a recording, or replaces an existing entry for it.
  ///
  /// [fresh] mints a new request id, which is what **Transcribe again** means:
  /// a deliberate second transcription, which the server bills for. An
  /// ordinary enqueue of something already queued leaves it alone.
  void enqueue(String noteId, String hash, {bool fresh = false}) {
    load();
    final index = _entries.indexWhere(
      (e) => e.noteId == noteId && e.hash == hash,
    );
    if (index >= 0 && !fresh) return;

    final entry = TranscriptionEntry(
      noteId: noteId,
      hash: hash,
      requestId: _uuid(),
    );
    if (index >= 0) {
      _entries[index] = entry;
    } else {
      _entries.add(entry);
    }
    _persist();
  }

  void remove(String noteId, String hash) {
    load();
    final before = _entries.length;
    _entries.removeWhere((e) => e.noteId == noteId && e.hash == hash);
    if (_entries.length != before) _persist();
  }

  /// Writes the summary again, under whatever instruction is set now.
  ///
  /// Clears the existing one first, because a stage whose result is already
  /// on the note is skipped — and because the honest thing for the chip to
  /// say while this runs is "Summarising…" rather than the old title.
  ///
  /// Costs a summary from the recording's budget, like the first one did.
  void summarizeAgain(String noteId, String hash) {
    load();
    _notes.updateAttachment(
      noteId,
      hash,
      (current) =>
          current is NoteVoiceRef ? current.copyWith(summary: null) : current,
      touch: true,
    );
    final entry = TranscriptionEntry(
      noteId: noteId,
      hash: hash,
      requestId: _uuid(),
      stage: TranscriptionStage.summarize,
    );
    final index = _entries.indexWhere(
      (e) => e.noteId == noteId && e.hash == hash,
    );
    if (index >= 0) {
      _entries[index] = entry;
    } else {
      _entries.add(entry);
    }
    _persist();
  }

  /// Clears the attempt count so a failed entry runs again. What **Retry**
  /// does, and the only way out of the "waiting for the user" state.
  void retry(String noteId, String hash) {
    load();
    final index = _entries.indexWhere(
      (e) => e.noteId == noteId && e.hash == hash,
    );
    if (index < 0) return;
    _entries[index] = _entries[index].copyWith(
      attempts: 0,
      nextAttemptAt: 0,
      lastError: null,
    );
    _persist();
  }

  /// What the chip should say about [hash].
  VoiceChipState stateFor(NoteVoiceRef ref) {
    if (ref.summary != null) return VoiceChipState.done;
    final entry = _entries.where((e) => e.hash == ref.hash).firstOrNull;
    if (entry == null) {
      return ref.transcript != null ? VoiceChipState.done : VoiceChipState.idle;
    }
    if (entry.lastError == SpeechCodes.consentRequired) {
      return VoiceChipState.needsConsent;
    }
    if (entry.lastError == SpeechCodes.minutesExhausted) {
      return VoiceChipState.outOfMinutes;
    }
    // Before the attempt budget: "Couldn't transcribe" is true but useless
    // when the fix is to sign in again, and the chip that says so is already
    // one tap from the pane that does it.
    if (entry.lastError == SpeechCodes.sessionRejected) {
      return VoiceChipState.needsAccount;
    }
    // Reached nobody last time. Says what is true and recovers by itself,
    // where "Transcribing…" would have described work that is not happening.
    if (entry.lastError == SpeechCodes.offline) return VoiceChipState.waiting;
    if (entry.attempts >= maxAttempts || _isTerminal(entry.lastError)) {
      return VoiceChipState.failed;
    }
    // The server answered and said no, in a way worth retrying. Between one
    // attempt and the next nothing is being transcribed, and the chip saying
    // so was the whole difference between "slow" and "broken".
    if (entry.lastError == SpeechCodes.unavailable) {
      return VoiceChipState.retrying;
    }
    // Nothing is going to happen to this entry, and saying "Transcribing…"
    // over a queue that cannot drain is the app telling the user to wait for
    // something that was never started. `drain` returns early without an API,
    // so no error would ever arrive to correct it.
    if (_api() == null && !_runsHere(entry)) {
      return VoiceChipState.needsAccount;
    }
    // Consent is about a recording leaving the device. Work that happens
    // here has never needed it, and asking would be asking permission to do
    // nothing.
    if (_prefs.transcriptionDeclinedVersion == speechConsentVersion &&
        !_runsHere(entry)) {
      return VoiceChipState.needsConsent;
    }
    if (!_online && !_runsHere(entry)) return VoiceChipState.waiting;
    return entry.stage == TranscriptionStage.summarize
        ? VoiceChipState.summarising
        : VoiceChipState.transcribing;
  }

  /// Gives anything the last session could not do a fresh budget.
  ///
  /// [Account] builds a new [SpeechApi] each time a session starts, so a
  /// different instance is the one honest signal that signing in again has
  /// happened. Without this, five refusals under a dead session would leave a
  /// recording stuck behind "Sign in to transcribe" after the signing in.
  void _forgiveRejectedSession(SpeechApi api) {
    if (identical(api, _sessionSeen)) return;
    _sessionSeen = api;
    for (final entry in [..._entries]) {
      if (entry.lastError != SpeechCodes.sessionRejected) continue;
      _replace(entry.copyWith(attempts: 0, nextAttemptAt: 0, lastError: null));
    }
  }

  /// Whether [entry]'s remaining work happens on this device.
  ///
  /// Read off the preference rather than by asking the summariser, because a
  /// chip asks this on every rebuild and readiness is an await. Being wrong
  /// optimistically costs one attempt that fails with a reason; being wrong
  /// the other way would tell somebody to sign in for work needing no account.
  bool _summarizesHere(TranscriptionEntry entry) =>
      entry.stage == TranscriptionStage.summarize &&
      _prefs.summaryEngine == SummaryEngine.device &&
      _summarizer() != null;

  /// The same question about the other stage.
  ///
  /// Worth its own method rather than a flag, because the two stages can
  /// disagree: transcribing here and summarising in the cloud is a perfectly
  /// ordinary setting, and so is the reverse.
  bool _transcribesHere(TranscriptionEntry entry) =>
      entry.stage == TranscriptionStage.transcribe &&
      _prefs.transcriptEngine == TranscriptEngine.device &&
      _transcriber() != null;

  /// Whether [entry]'s next step needs nothing but this machine.
  ///
  /// The one question every "can this proceed?" test below actually wants.
  /// Each half checks its own stage, so exactly one of them can be true.
  bool _runsHere(TranscriptionEntry entry) =>
      _summarizesHere(entry) || _transcribesHere(entry);

  /// Works through everything due. Safe to call from several places at once.
  Future<void> drain({DateTime? now}) async {
    load();
    if (_draining || _entries.isEmpty) return;
    final api = _api();
    final offline = api == null || !_online;
    // Signed out or offline still leaves something to do when the work
    // happens here — either stage can. Anything that does need the server is
    // skipped entry by entry below.
    if (offline && !_entries.any(_runsHere)) return;
    if (api != null) _forgiveRejectedSession(api);

    _draining = true;
    try {
      final at = (now ?? DateTime.now()).millisecondsSinceEpoch;
      // Passes until one advances nothing. A transcript that just landed
      // leaves its entry due for the summary, and one pass used to stop
      // there — the summary waited for whatever next happened to call drain.
      // A failure is not an advance: it has a wait of its own, and the
      // caller's idea of `now` must not turn that wait into a tight loop.
      var advanced = true;
      while (advanced) {
        advanced = false;
        // A copy, because running an entry mutates the list.
        for (final entry in [..._entries]) {
          if (entry.nextAttemptAt > at) continue;
          if (entry.attempts >= maxAttempts) continue;
          if (_isTerminal(entry.lastError)) continue;
          if (_running.contains(entry.hash)) continue;
          if (offline && !_runsHere(entry)) continue;
          await _run(entry);
          final after = _entries
              .where((e) => e.noteId == entry.noteId && e.hash == entry.hash)
              .firstOrNull;
          if (after == null || after.stage != entry.stage) advanced = true;
        }
      }
    } finally {
      _draining = false;
      _armWakeup(now: now);
    }
  }

  void _armWakeup({DateTime? now}) {
    _wakeup?.cancel();
    _wakeup = null;
    final at = (now ?? DateTime.now()).millisecondsSinceEpoch;
    int? soonest;
    for (final entry in _entries) {
      if (entry.attempts >= maxAttempts) continue;
      if (_isTerminal(entry.lastError)) continue;
      if (entry.nextAttemptAt <= at) continue;
      if (soonest == null || entry.nextAttemptAt < soonest) {
        soonest = entry.nextAttemptAt;
      }
    }
    if (soonest == null) return;
    _wakeup = Timer(
      Duration(milliseconds: soonest - at),
      () => unawaited(drain()),
    );
  }

  @override
  void dispose() {
    _wakeup?.cancel();
    super.dispose();
  }

  Future<void> _run(TranscriptionEntry entry) async {
    // The note may have been edited, or the chip removed, since this was
    // queued. Either way there is nothing to write a transcript into.
    final ref = _refFor(entry);
    if (ref == null) {
      remove(entry.noteId, entry.hash);
      return;
    }
    // Already has what this stage would produce: a second device did it, or a
    // previous run's write landed and its response did not.
    if (entry.stage == TranscriptionStage.transcribe &&
        ref.transcript != null) {
      _advance(entry, ref);
      return;
    }
    if (entry.stage == TranscriptionStage.summarize && ref.summary != null) {
      remove(entry.noteId, entry.hash);
      return;
    }

    _running.add(entry.hash);
    try {
      if (entry.stage == TranscriptionStage.transcribe) {
        await _transcribe(entry, ref);
      } else {
        await _summarize(entry, ref);
      }
    } finally {
      _running.remove(entry.hash);
    }
  }

  Future<void> _transcribe(TranscriptionEntry entry, NoteVoiceRef ref) async {
    final transcriber = _transcriber();
    if (transcriber == null) {
      remove(entry.noteId, entry.hash);
      return;
    }
    // The file rather than its bytes: the local engines stream it from disk,
    // and a thirty-minute recording has no business being in the heap twice.
    final file = await _blobs.fileFor(entry.hash);
    if (file == null) {
      // The recording is not on this device — it arrived by sync and the audio
      // has not come down yet. Whichever device holds it will transcribe it.
      remove(entry.noteId, entry.hash);
      return;
    }

    try {
      final result = await transcriber.transcribe(
        audio: file,
        requestId: entry.requestId,
        language: _prefs.language,
      );
      needsConsent = false;
      exhausted = null;

      final transcript = VoiceTranscript(
        lang: result.lang,
        engine: result.engine,
        at: DateTime.now().millisecondsSinceEpoch,
        segments: result.segments,
        // Kept on the note, not just in this entry: the entry is removed the
        // moment both stages finish, and asking for another summary — or a
        // post — a week later needs the same handle the server bills against.
        jobId: result.jobId,
      );
      _notes.updateAttachment(
        entry.noteId,
        entry.hash,
        (current) => current is NoteVoiceRef
            ? current.copyWith(transcript: transcript)
            : current,
        // Other devices need the words, and sync only pushes dirty notes.
        touch: true,
      );
      _replace(
        entry.copyWith(
          jobId: result.jobId,
          lang: result.lang,
          stage: TranscriptionStage.summarize,
          attempts: 0,
          nextAttemptAt: 0,
          lastError: null,
        ),
      );
      if (!_prefs.summarize) remove(entry.noteId, entry.hash);
    } on TranscriberUnavailable catch (error) {
      // "Still fetching its language" is a real wait and worth retrying.
      // Everything else — no model downloaded, an OS without a recogniser, a
      // file that will not decode — is the same answer however long we wait,
      // so it is recorded terminally rather than burning four more attempts
      // to reach it. Retry clears it, which is what somebody who has just
      // downloaded the model will press.
      if (error.readiness == TranscriberReadiness.preparing) {
        _recordFailure(entry, error);
      } else {
        _replace(
          entry.copyWith(
            nextAttemptAt: _nextAttemptAt(entry.attempts),
            lastError: SpeechCodes.engineUnavailable,
          ),
        );
      }
    } catch (error) {
      _recordFailure(entry, error);
    }
  }

  Future<void> _summarize(TranscriptionEntry entry, NoteVoiceRef ref) async {
    final transcript = ref.transcript;
    final summarizer = _summarizer();
    if (transcript == null || summarizer == null) {
      remove(entry.noteId, entry.hash);
      return;
    }
    final text = transcript.text.trim();
    if (text.isEmpty) {
      remove(entry.noteId, entry.hash);
      return;
    }

    try {
      final result = await summarizer.summarize(
        text: text,
        lang: transcript.lang,
        jobId: entry.jobId ?? transcript.jobId,
        instruction: _prefs.summaryInstruction,
      );
      final summary = VoiceSummary(
        engine: result.engine,
        at: DateTime.now().millisecondsSinceEpoch,
        title: result.title,
        points: result.points,
      );
      _notes.updateAttachment(
        entry.noteId,
        entry.hash,
        (current) => current is NoteVoiceRef
            ? current.copyWith(summary: summary)
            : current,
        touch: true,
      );
      remove(entry.noteId, entry.hash);
    } on SummarizerUnavailable catch (error) {
      // A summariser that cannot work here will not start working. Keeping
      // the entry would leave the chip saying "Summarising…" forever over a
      // transcript that is already finished and readable.
      if (error.isTemporary) {
        _recordFailure(entry, error);
      } else {
        remove(entry.noteId, entry.hash);
      }
    } catch (error) {
      _recordFailure(entry, error);
    }
  }

  /// Moves an entry on when the stage it was about is already done.
  void _advance(TranscriptionEntry entry, NoteVoiceRef ref) {
    final needsJobId = _prefs.summaryEngine != SummaryEngine.device;
    if (ref.summary != null ||
        !_prefs.summarize ||
        (needsJobId && entry.jobId == null)) {
      remove(entry.noteId, entry.hash);
      return;
    }
    _replace(entry.copyWith(stage: TranscriptionStage.summarize));
  }

  void _recordFailure(TranscriptionEntry entry, Object error) {
    // Being offline is not a failure. Counting it would mean a train journey
    // burns through the attempt budget and the user has to press Retry for
    // something that was never wrong.
    // A failure with no answer in it is a network, not a refusal: nobody was
    // reached, and the next tunnel fixes it. The device's own online flag is
    // not the test — nothing in the app sets it — but whether the server got
    // as far as replying is knowable from the exception itself.
    if (error is SyncTransientException && !error.answered) {
      _replace(
        entry.copyWith(
          nextAttemptAt: _nextAttemptAt(entry.attempts),
          lastError: SpeechCodes.offline,
        ),
      );
      return;
    }

    // Everything else counts. A server that cannot be reached while the device
    // believes it is online, and a session the server rejected, both used to
    // return above without counting and without leaving a code — so the chip
    // went on saying "Transcribing…" over a request that had already failed,
    // retrying every few seconds for as long as the app stayed open, and the
    // one place the reason would have been shown had nothing to show.
    final code = switch (error) {
      SyncAuthException() => SpeechCodes.sessionRejected,
      SyncTransientException() => SpeechCodes.unavailable,
      SyncRefusedException(:final code) => code,
      _ => 'error',
    };
    if (code == SpeechCodes.consentRequired) needsConsent = true;
    if (code == SpeechCodes.minutesExhausted && error is SyncRefusedException) {
      exhausted = SpeechUsage.fromJson(error.body);
    }

    _replace(
      entry.copyWith(
        // A refusal the user has to act on does not get retried at all: the
        // attempt budget is for things that might work next time.
        attempts: _isTerminal(code) ? entry.attempts : entry.attempts + 1,
        nextAttemptAt: _nextAttemptAt(entry.attempts),
        lastError: code,
      ),
    );
  }

  /// Refusals no retry can fix — the user has to agree, wait for the month to
  /// roll over, or accept that this recording cannot be read.
  static bool _isTerminal(String? code) =>
      code == SpeechCodes.engineUnavailable ||
      code == SpeechCodes.consentRequired ||
      code == SpeechCodes.minutesExhausted ||
      code == SpeechCodes.retryLimit ||
      code == SpeechCodes.unreadable ||
      code == SpeechCodes.tooLong ||
      code == SpeechCodes.tooLarge;

  int _nextAttemptAt(int attempts) {
    final millis = min(
      backoff.inMilliseconds * pow(2, attempts).toInt(),
      maxBackoff.inMilliseconds,
    );
    return DateTime.now().millisecondsSinceEpoch + millis;
  }

  NoteVoiceRef? _refFor(TranscriptionEntry entry) {
    final note = _notes.byId(entry.noteId);
    if (note == null) return null;
    for (final ref in note.attachments) {
      if (ref is NoteVoiceRef && ref.hash == entry.hash) return ref;
    }
    return null;
  }

  void _replace(TranscriptionEntry entry) {
    final index = _entries.indexWhere(
      (e) => e.noteId == entry.noteId && e.hash == entry.hash,
    );
    if (index < 0) return;
    _entries[index] = entry;
    _persist();
  }

  /// Written on every state change, not on a timer: the whole point is that a
  /// kill between two stages resumes rather than starts again.
  void _persist() {
    _store.putNow(_key, _entries.map((e) => e.toJson()).toList());
    notifyListeners();
  }

  static String _uuid() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String hex(int start, int end) => bytes
        .sublist(start, end)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
  }
}
