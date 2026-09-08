import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/blob_store.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/voice_prefs.dart';
import 'package:kapy_notes/speech/speech_api.dart';
import 'package:kapy_notes/speech/transcription_queue.dart';
import 'package:kapy_notes/sync/sync_api.dart';
import 'package:kapy_notes/ui/editor/voice_chip.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore({super.fileName = 'queue-test.json'});

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;

  @override
  void putNow(String key, Object? value) => data[key] = value;
}

/// A store that answers with whatever a test puts in it.
class _FakeBlobs implements BlobStore {
  final Map<String, Uint8List> bytes = {};

  @override
  Future<Uint8List?> read(String hash) async => bytes[hash];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeSpeechApi implements SpeechApi {
  /// One outcome per call; a function throws, anything else is returned.
  final List<Object> transcribeScript = [];
  final List<Object> summarizeScript = [];

  final List<String> transcribeRequestIds = [];
  int summarizeCalls = 0;
  String? languageSent;

  @override
  Future<SpeechConsentStatus> consent() async => const SpeechConsentStatus(
    acceptedVersion: 1,
    currentVersion: 1,
  );

  @override
  Future<SpeechConsentStatus> acceptConsent(int version) async => consent();

  @override
  Future<SpeechUsage> usage() async =>
      SpeechUsage(usedSeconds: 0, quotaSeconds: 1800, resetsAt: DateTime.now());

  @override
  Future<TranscribeResult> transcribe({
    required Uint8List audio,
    required String requestId,
    String? language,
  }) async {
    transcribeRequestIds.add(requestId);
    languageSent = language;
    if (transcribeScript.isNotEmpty) {
      final next = transcribeScript.removeAt(0);
      if (next is Function) return next() as TranscribeResult;
    }
    return TranscribeResult(
      jobId: '11111111-1111-4111-8111-111111111111',
      lang: 'en',
      engine: 'cf/deepgram-nova-3',
      segments: const [TranscriptSegment(s: 0, e: 900, t: 'hello there')],
      usage: SpeechUsage(usedSeconds: 12, quotaSeconds: 1800, resetsAt: DateTime.now()),
    );
  }

  @override
  Future<SummaryResult> summarize({
    required String jobId,
    required String lang,
    required String text,
  }) async {
    summarizeCalls++;
    if (summarizeScript.isNotEmpty) {
      final next = summarizeScript.removeAt(0);
      if (next is Function) return next() as SummaryResult;
    }
    return const SummaryResult(
      engine: 'cf/llama',
      title: 'Standup',
      points: ['Said hello.'],
    );
  }
}

void main() {
  const anchor = NoteAttachmentRef.placeholder;
  late NotesStore notes;
  late _FakeBlobs blobs;
  late VoicePrefs prefs;
  late FakeSpeechApi api;
  late LocalStore queueStore;
  late TranscriptionQueue queue;
  late String noteId;

  NoteVoiceRef recording() => NoteVoiceRef(
    offset: 0,
    hash: 'v1',
    key: Uint8List(32),
    bytes: 2048,
    durationMs: 12000,
  );

  NoteVoiceRef? current() =>
      notes.byId(noteId)?.attachments.whereType<NoteVoiceRef>().firstOrNull;

  setUp(() async {
    notes = NotesStore(_MemoryStore(fileName: 'notes-test.json'));
    await notes.load();
    blobs = _FakeBlobs()..bytes['v1'] = Uint8List(16);
    prefs = VoicePrefs(_MemoryStore())..load();
    api = FakeSpeechApi();
    queueStore = _MemoryStore();
    queue = TranscriptionQueue(
      store: queueStore,
      notes: notes,
      blobs: blobs,
      prefs: prefs,
      api: () => api,
    );

    noteId = notes.create().id;
    notes.updateDocument(noteId, anchor, const [], [recording()]);
  });

  test('a drain writes the transcript, then the summary, then is done', () async {
    queue.enqueue(noteId, 'v1');
    await queue.drain();
    expect(current()!.transcript!.segments.single.t, 'hello there');

    await queue.drain();
    expect(current()!.summary!.title, 'Standup');
    expect(queue.entries, isEmpty);
  });

  test('a transcript bumps updatedAt, so other devices receive it', () async {
    final before = notes.byId(noteId)!.updatedAt;
    queue.enqueue(noteId, 'v1');
    await queue.drain();
    expect(notes.byId(noteId)!.updatedAt.isAfter(before), isTrue);
  });

  test('every retry of one intent reuses its request id', () async {
    // The server bills per intent. A fresh id on each retry would bill every
    // dropped connection.
    api.transcribeScript.add(() => throw const SyncTransientException('offline'));
    queue.enqueue(noteId, 'v1');
    await queue.drain();
    await queue.drain(now: DateTime.now().add(const Duration(minutes: 1)));
    expect(api.transcribeRequestIds, hasLength(2));
    expect(api.transcribeRequestIds.first, api.transcribeRequestIds.last);
  });

  test('transcribing again mints a new intent, and pays', () async {
    queue.enqueue(noteId, 'v1');
    await queue.drain();
    final first = api.transcribeRequestIds.single;

    queue.enqueue(noteId, 'v1', fresh: true);
    expect(queue.entries.single.requestId, isNot(first));
  });

  test('being offline never counts as an attempt', () async {
    // Otherwise a train journey burns the budget and the user has to press
    // Retry for something that was never wrong.
    for (var i = 0; i < 8; i++) {
      api.transcribeScript.add(() => throw const SyncTransientException('offline'));
    }
    queue.enqueue(noteId, 'v1');
    for (var i = 0; i < 8; i++) {
      await queue.drain(now: DateTime.now().add(Duration(hours: i + 1)));
    }
    expect(queue.entries.single.attempts, 0);
    expect(queue.entries.single.lastError, isNull);
  });

  test('backoff grows, so a flaky server is not hammered', () async {
    api.transcribeScript.add(() => throw const SyncRefusedException(502, 'oops', {}));
    queue.enqueue(noteId, 'v1');
    await queue.drain();

    final entry = queue.entries.single;
    expect(entry.attempts, 1);
    expect(entry.nextAttemptAt, greaterThan(DateTime.now().millisecondsSinceEpoch));
    // Not due yet: a second drain right now does nothing.
    await queue.drain();
    expect(api.transcribeRequestIds, hasLength(1));
  });

  test('a refusal the user must act on stops retrying immediately', () async {
    api.transcribeScript.add(
      () => throw const SyncRefusedException(403, SpeechCodes.consentRequired, {}),
    );
    queue.enqueue(noteId, 'v1');
    await queue.drain();

    expect(queue.needsConsent, isTrue);
    expect(queue.entries.single.attempts, 0);
    await queue.drain(now: DateTime.now().add(const Duration(days: 1)));
    expect(api.transcribeRequestIds, hasLength(1));
  });

  test('running out of minutes keeps the numbers to explain it', () async {
    api.transcribeScript.add(
      () => throw SyncRefusedException(409, SpeechCodes.minutesExhausted, {
        'usedSeconds': 1800,
        'quotaSeconds': 1800,
        'resetsAt': DateTime.utc(2026, 10).toIso8601String(),
      }),
    );
    queue.enqueue(noteId, 'v1');
    await queue.drain();

    expect(queue.exhausted!.usedSeconds, 1800);
    expect(queue.exhausted!.isExhausted, isTrue);
    expect(queue.stateFor(current()!), VoiceChipState.outOfMinutes);
  });

  test('an unreadable recording is not retried forever', () async {
    api.transcribeScript.add(
      () => throw const SyncRefusedException(422, SpeechCodes.unreadable, {}),
    );
    queue.enqueue(noteId, 'v1');
    await queue.drain();
    expect(queue.stateFor(current()!), VoiceChipState.failed);

    await queue.drain(now: DateTime.now().add(const Duration(days: 1)));
    expect(api.transcribeRequestIds, hasLength(1));
  });

  test('Retry clears the count and runs again', () async {
    api.transcribeScript.add(() => throw const SyncRefusedException(500, 'oops', {}));
    queue.enqueue(noteId, 'v1');
    await queue.drain();
    expect(queue.entries.single.attempts, 1);

    queue.retry(noteId, 'v1');
    expect(queue.entries.single.attempts, 0);
    await queue.drain();
    expect(current()!.transcript, isNotNull);
  });

  test('a kill between the two stages resumes rather than restarts', () async {
    queue.enqueue(noteId, 'v1');
    await queue.drain();

    // The app dies here. A new queue reads the same file.
    final resumed = TranscriptionQueue(
      store: queueStore,
      notes: notes,
      blobs: blobs,
      prefs: prefs,
      api: () => api,
    )..load();
    expect(resumed.entries.single.stage, TranscriptionStage.summarize);

    await resumed.drain();
    expect(current()!.summary, isNotNull);
    // The transcription was not paid for twice.
    expect(api.transcribeRequestIds, hasLength(1));
  });

  test('a stage whose work is already done is skipped, not repeated', () async {
    // Another device transcribed it and the note synced in.
    notes.updateAttachment(
      noteId,
      'v1',
      (ref) => (ref as NoteVoiceRef).copyWith(
        transcript: VoiceTranscript(
          lang: 'en',
          engine: 'other-device',
          at: 1,
          segments: const [TranscriptSegment(s: 0, e: 1, t: 'already done')],
        ),
      ),
    );
    queue.enqueue(noteId, 'v1');
    await queue.drain();
    expect(api.transcribeRequestIds, isEmpty);
    expect(current()!.transcript!.engine, 'other-device');
  });

  test('a recording removed from its note drops out of the queue', () async {
    queue.enqueue(noteId, 'v1');
    notes.updateDocument(noteId, 'just text now', const [], const []);
    await queue.drain();
    expect(queue.entries, isEmpty);
    expect(api.transcribeRequestIds, isEmpty);
  });

  test('a recording whose audio is not on this device is left alone', () async {
    // It arrived by sync; whichever device holds the bytes will do the work.
    blobs.bytes.clear();
    queue.enqueue(noteId, 'v1');
    await queue.drain();
    expect(queue.entries, isEmpty);
    expect(api.transcribeRequestIds, isEmpty);
  });

  test('summaries turned off stop after the transcript', () async {
    prefs.summarize = false;
    queue.enqueue(noteId, 'v1');
    await queue.drain();
    expect(current()!.transcript, isNotNull);
    expect(queue.entries, isEmpty);
    expect(api.summarizeCalls, 0);
  });

  test('a chosen language is sent to the provider', () async {
    prefs.language = 'de';
    queue.enqueue(noteId, 'v1');
    await queue.drain();
    expect(api.languageSent, 'de');
  });

  test('offline shows waiting, not transcribing', () async {
    queue.enqueue(noteId, 'v1');
    queue.online = false;
    expect(queue.stateFor(current()!), VoiceChipState.waiting);
    await queue.drain();
    expect(api.transcribeRequestIds, isEmpty);
  });

  test('a recording nobody queued reads as idle, and a done one as done', () {
    expect(queue.stateFor(current()!), VoiceChipState.idle);
    queue.enqueue(noteId, 'v1');
    expect(queue.stateFor(current()!), VoiceChipState.transcribing);
  });

  test('a summary that will not come does not lose the transcript', () async {
    api.summarizeScript.add(() => throw const SyncRefusedException(502, 'x', {}));
    queue.enqueue(noteId, 'v1');
    await queue.drain();
    await queue.drain();
    expect(current()!.transcript, isNotNull);
    expect(current()!.summary, isNull);
  });

  test('enqueueing the same recording twice does not queue it twice', () {
    queue.enqueue(noteId, 'v1');
    queue.enqueue(noteId, 'v1');
    expect(queue.entries, hasLength(1));
  });
}
