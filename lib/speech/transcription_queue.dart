import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/blob_store.dart';
import '../data/local_store.dart';
import '../data/note_attachment.dart';
import '../data/notes_store.dart';
import '../data/voice_prefs.dart';
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
    lastError: identical(lastError, _keep) ? this.lastError : lastError as String?,
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
    if (noteId is! String || hash is! String || requestId is! String) return null;
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
      nextAttemptAt: raw['nextAttemptAt'] is int ? raw['nextAttemptAt']! as int : 0,
      lastError: raw['lastError'] is String ? raw['lastError']! as String : null,
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
  }) : _store = store,
       _notes = notes,
       _blobs = blobs,
       _prefs = prefs,
       _api = api ?? (() => null);

  final LocalStore _store;
  final NotesStore _notes;
  final BlobStore _blobs;
  final VoicePrefs _prefs;
  final SpeechApi? Function() _api;

  static const String _key = 'transcriptions.v1';

  /// Five attempts, then it waits for the user. Past that the failure is not
  /// transient and retrying is just noise on someone's battery.
  static const int maxAttempts = 5;

  static const Duration baseBackoff = Duration(seconds: 5);
  static const Duration maxBackoff = Duration(minutes: 10);

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
    final index = _entries.indexWhere((e) => e.noteId == noteId && e.hash == hash);
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

  /// Clears the attempt count so a failed entry runs again. What **Retry**
  /// does, and the only way out of the "waiting for the user" state.
  void retry(String noteId, String hash) {
    load();
    final index = _entries.indexWhere((e) => e.noteId == noteId && e.hash == hash);
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
    if (entry.attempts >= maxAttempts || _isTerminal(entry.lastError)) {
      return VoiceChipState.failed;
    }
    if (!_online) return VoiceChipState.waiting;
    return entry.stage == TranscriptionStage.summarize
        ? VoiceChipState.summarising
        : VoiceChipState.transcribing;
  }

  /// Works through everything due. Safe to call from several places at once.
  Future<void> drain({DateTime? now}) async {
    load();
    if (_draining || _entries.isEmpty) return;
    final api = _api();
    if (api == null || !_online) return;

    _draining = true;
    try {
      final at = (now ?? DateTime.now()).millisecondsSinceEpoch;
      // A copy, because running an entry mutates the list.
      for (final entry in [..._entries]) {
        if (entry.nextAttemptAt > at) continue;
        if (entry.attempts >= maxAttempts) continue;
        if (_isTerminal(entry.lastError)) continue;
        if (_running.contains(entry.hash)) continue;
        await _run(api, entry);
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _run(SpeechApi api, TranscriptionEntry entry) async {
    // The note may have been edited, or the chip removed, since this was
    // queued. Either way there is nothing to write a transcript into.
    final ref = _refFor(entry);
    if (ref == null) {
      remove(entry.noteId, entry.hash);
      return;
    }
    // Already has what this stage would produce: a second device did it, or a
    // previous run's write landed and its response did not.
    if (entry.stage == TranscriptionStage.transcribe && ref.transcript != null) {
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
        await _transcribe(api, entry, ref);
      } else {
        await _summarize(api, entry, ref);
      }
    } finally {
      _running.remove(entry.hash);
    }
  }

  Future<void> _transcribe(
    SpeechApi api,
    TranscriptionEntry entry,
    NoteVoiceRef ref,
  ) async {
    final bytes = await _blobs.read(entry.hash);
    if (bytes == null) {
      // The recording is not on this device — it arrived by sync and the audio
      // has not come down yet. Whichever device holds it will transcribe it.
      remove(entry.noteId, entry.hash);
      return;
    }

    try {
      final result = await api.transcribe(
        audio: bytes,
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
    } catch (error) {
      _recordFailure(entry, error);
    }
  }

  Future<void> _summarize(
    SpeechApi api,
    TranscriptionEntry entry,
    NoteVoiceRef ref,
  ) async {
    final transcript = ref.transcript;
    final jobId = entry.jobId;
    if (transcript == null || jobId == null) {
      remove(entry.noteId, entry.hash);
      return;
    }
    final text = transcript.text.trim();
    if (text.isEmpty) {
      remove(entry.noteId, entry.hash);
      return;
    }

    try {
      final result = await api.summarize(
        jobId: jobId,
        lang: transcript.lang,
        text: text,
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
        (current) =>
            current is NoteVoiceRef ? current.copyWith(summary: summary) : current,
        touch: true,
      );
      remove(entry.noteId, entry.hash);
    } catch (error) {
      _recordFailure(entry, error);
    }
  }

  /// Moves an entry on when the stage it was about is already done.
  void _advance(TranscriptionEntry entry, NoteVoiceRef ref) {
    if (ref.summary != null || !_prefs.summarize || entry.jobId == null) {
      remove(entry.noteId, entry.hash);
      return;
    }
    _replace(entry.copyWith(stage: TranscriptionStage.summarize));
  }

  void _recordFailure(TranscriptionEntry entry, Object error) {
    // Being offline is not a failure. Counting it would mean a train journey
    // burns through the attempt budget and the user has to press Retry for
    // something that was never wrong.
    if (error is SyncTransientException || error is SyncAuthException) {
      _replace(
        entry.copyWith(
          nextAttemptAt: _nextAttemptAt(entry.attempts),
          lastError: null,
        ),
      );
      return;
    }

    final code = error is SyncRefusedException ? error.code : 'error';
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
      code == SpeechCodes.consentRequired ||
      code == SpeechCodes.minutesExhausted ||
      code == SpeechCodes.retryLimit ||
      code == SpeechCodes.unreadable ||
      code == SpeechCodes.tooLong ||
      code == SpeechCodes.tooLarge;

  int _nextAttemptAt(int attempts) {
    final millis = min(
      baseBackoff.inMilliseconds * pow(2, attempts).toInt(),
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
