import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/billing/billing.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/data/blob_store.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/voice_prefs.dart';
import 'package:kapy_notes/speech/cloud_access.dart';
import 'package:kapy_notes/speech/cloud_summarizer.dart';
import 'package:kapy_notes/speech/cloud_transcriber.dart';
import 'package:kapy_notes/speech/speech_api.dart';
import 'package:kapy_notes/speech/speech_errors.dart';
import 'package:kapy_notes/speech/summarizer.dart';
import 'package:kapy_notes/speech/transcriber.dart';
import 'package:kapy_notes/speech/transcription_queue.dart';
import 'package:kapy_notes/sync/sync_api.dart';
import 'package:kapy_notes/ui/editor/voice_chip.dart';

import '../billing/billing_fakes.dart';

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
  final Directory _temp = Directory.systemTemp.createTempSync('kapy-blobs');

  @override
  Future<Uint8List?> read(String hash) async => bytes[hash];

  /// A real file on disk, because that is what the transcriber seam takes:
  /// the local engines stream a recording rather than holding all of it, and
  /// only the cloud one reads it into memory to upload.
  @override
  Future<File?> fileFor(String hash) async {
    final data = bytes[hash];
    if (data == null) return null;
    final file = File('${_temp.path}/$hash');
    await file.writeAsBytes(data);
    return file;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A transcriber that never touches a network, like the real local ones.
class _FakeLocalTranscriber implements Transcriber {
  TranscriberReadiness state = TranscriberReadiness.ready;
  int calls = 0;

  @override
  Future<TranscriberReadiness> readiness() async => state;

  @override
  Future<TranscriptDraft> transcribe({
    required File audio,
    required String requestId,
    String? language,
  }) async {
    if (state != TranscriberReadiness.ready) {
      throw TranscriberUnavailable(state, 'not here');
    }
    calls++;
    return const TranscriptDraft(
      engine: 'sherpa/parakeet',
      lang: 'en',
      segments: [TranscriptSegment(s: 0, e: 900, t: 'said here')],
    );
  }
}

/// A summariser that runs here, like Apple's model or Gemma.
class _FakeLocalSummarizer implements Summarizer {
  int calls = 0;

  /// Null writes everything. Otherwise any other language has no model here,
  /// as Hindi has none on an iPhone.
  Set<String>? languages;

  @override
  Future<SummarizerReadiness> readiness() async => SummarizerReadiness.ready;

  @override
  Future<bool> writes(String lang) async => true;

  @override
  Future<SummaryDraft> summarize({
    required String text,
    required String lang,
    String? jobId,
    String? instruction,
  }) async {
    calls++;
    if (languages case final known? when !known.contains(lang)) {
      throw SummaryLanguageUnavailable(lang);
    }
    return const SummaryDraft(
      engine: 'apple/foundation-models',
      title: 'Summarised here',
      points: ['Said here.'],
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeSpeechApi implements SpeechApi {
  /// One outcome per call; a function throws, anything else is returned.
  final List<Object> transcribeScript = [];
  final List<Object> summarizeScript = [];

  final List<String> transcribeRequestIds = [];
  int summarizeCalls = 0;
  String? lastInstruction;
  final List<String> rewriteInstructions = [];
  String? languageSent;
  String? modelSent;

  @override
  Future<SpeechConsentStatus> consent() async =>
      const SpeechConsentStatus(acceptedVersion: 2, currentVersion: 2);

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
    String? model,
  }) async {
    transcribeRequestIds.add(requestId);
    languageSent = language;
    modelSent = model;
    if (transcribeScript.isNotEmpty) {
      final next = transcribeScript.removeAt(0);
      if (next is Function) return next() as TranscribeResult;
    }
    return TranscribeResult(
      jobId: '11111111-1111-4111-8111-111111111111',
      lang: 'en',
      engine: 'openrouter/microsoft/mai-transcribe-2',
      segments: const [TranscriptSegment(s: 0, e: 900, t: 'hello there')],
      usage: SpeechUsage(
        usedSeconds: 12,
        quotaSeconds: 1800,
        resetsAt: DateTime.now(),
      ),
    );
  }

  @override
  Future<SummaryResult> summarize({
    required String jobId,
    required String lang,
    required String text,
    String? instruction,
  }) async {
    summarizeCalls++;
    lastInstruction = instruction;
    if (summarizeScript.isNotEmpty) {
      final next = summarizeScript.removeAt(0);
      if (next is Function) return next() as SummaryResult;
    }
    return const SummaryResult(
      engine: 'deepseek/deepseek-v4-flash-0731',
      title: 'Standup',
      points: ['Said hello.'],
    );
  }

  @override
  Future<RewriteResult> rewrite({
    required String jobId,
    required String lang,
    required String text,
    required String instruction,
  }) async {
    rewriteInstructions.add(instruction);
    return RewriteResult(
      engine: 'deepseek/deepseek-v4-flash-0731',
      text: 'a post about $instruction',
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
      summarizer: () => CloudSummarizer(() => api),
    );

    noteId = notes.create().id;
    notes.updateDocument(noteId, anchor, const [], [recording()]);
  });

  test(
    'a drain writes the transcript, then the summary, then is done',
    () async {
      queue.enqueue(noteId, 'v1');
      await queue.drain();
      expect(current()!.transcript!.segments.single.t, 'hello there');

      await queue.drain();
      expect(current()!.summary!.title, 'Standup');
      expect(queue.entries, isEmpty);
    },
  );

  test('a transcript bumps updatedAt, so other devices receive it', () async {
    final before = notes.byId(noteId)!.updatedAt;
    queue.enqueue(noteId, 'v1');
    await queue.drain();
    expect(notes.byId(noteId)!.updatedAt.isAfter(before), isTrue);
  });

  test('every retry of one intent reuses its request id', () async {
    // The server bills per intent. A fresh id on each retry would bill every
    // dropped connection.
    api.transcribeScript.add(
      () => throw const SyncTransientException('offline'),
    );
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
      api.transcribeScript.add(
        () => throw const SyncTransientException('offline'),
      );
    }
    queue.enqueue(noteId, 'v1');
    for (var i = 0; i < 8; i++) {
      await queue.drain(now: DateTime.now().add(Duration(hours: i + 1)));
    }
    expect(queue.entries.single.attempts, 0);
    // Not silence any more: the chip can say "Waiting for connection" instead
    // of describing work that is not happening.
    expect(queue.entries.single.lastError, SpeechCodes.offline);
    expect(queue.stateFor(current()!), VoiceChipState.waiting);
  });

  test('backoff grows, so a flaky server is not hammered', () async {
    api.transcribeScript.add(
      () => throw const SyncRefusedException(502, 'oops', {}),
    );
    queue.enqueue(noteId, 'v1');
    await queue.drain();

    final entry = queue.entries.single;
    expect(entry.attempts, 1);
    expect(
      entry.nextAttemptAt,
      greaterThan(DateTime.now().millisecondsSinceEpoch),
    );
    // Not due yet: a second drain right now does nothing.
    await queue.drain();
    expect(api.transcribeRequestIds, hasLength(1));
  });

  test('a refusal the user must act on stops retrying immediately', () async {
    api.transcribeScript.add(
      () => throw const SyncRefusedException(
        403,
        SpeechCodes.consentRequired,
        {},
      ),
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
    api.transcribeScript.add(
      () => throw const SyncRefusedException(500, 'oops', {}),
    );
    queue.enqueue(noteId, 'v1');
    await queue.drain();
    expect(queue.entries.single.attempts, 1);

    queue.retry(noteId, 'v1');
    expect(queue.entries.single.attempts, 0);
    await queue.drain();
    expect(current()!.transcript, isNotNull);
  });

  test('a kill between the two stages resumes rather than restarts', () async {
    // One drain now carries an entry through both stages, so the gap a kill
    // lands in is made by a summary that did not come back this time.
    api.summarizeScript.add(
      () => throw const SyncTransientException('killed', answered: true),
    );
    queue.enqueue(noteId, 'v1');
    await queue.drain();

    // The app dies here. A new queue reads the same file.
    final resumed = TranscriptionQueue(
      store: queueStore,
      notes: notes,
      blobs: blobs,
      prefs: prefs,
      api: () => api,
      summarizer: () => CloudSummarizer(() => api),
    )..load();
    expect(resumed.entries.single.stage, TranscriptionStage.summarize);

    await resumed.drain(now: DateTime.now().add(const Duration(minutes: 1)));
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

  group('live translation', () {
    late List<(String, String, String)> kept;
    late TranscriptionQueue translating;

    setUp(() {
      kept = [];
      translating = TranscriptionQueue(
        store: _MemoryStore(),
        notes: notes,
        blobs: blobs,
        prefs: prefs,
        api: () => api,
        keepTranslation: (noteId, hash, to) => kept.add((noteId, hash, to)),
      );
    });

    test('on, a finished transcript is kept in its language once', () async {
      prefs
        ..liveTranslation = true
        ..liveTranslateTo = 'es';
      translating.enqueue(noteId, 'v1');
      await translating.drain();
      expect(current()!.transcript, isNotNull);
      expect(kept, [(noteId, 'v1', 'es')]);
      await translating.drain();
      expect(kept, hasLength(1), reason: 'not again for the summary');
    });

    test('off, nothing is kept', () async {
      prefs.liveTranslateTo = 'es';
      translating.enqueue(noteId, 'v1');
      await translating.drain();
      expect(current()!.transcript, isNotNull);
      expect(kept, isEmpty);
    });

    test('on with no language picked, nothing is kept', () async {
      prefs.liveTranslation = true;
      translating.enqueue(noteId, 'v1');
      await translating.drain();
      expect(current()!.transcript, isNotNull);
      expect(kept, isEmpty);
    });
  });

  test('a chosen language is sent to the provider', () async {
    prefs.language = 'de';
    queue.enqueue(noteId, 'v1');
    await queue.drain();
    expect(api.languageSent, 'de');
  });

  test('cloud transcription asks for MAI-Transcribe 2', () async {
    queue.enqueue(noteId, 'v1');
    await queue.drain();
    expect(api.modelSent, 'microsoft/mai-transcribe-2');
  });

  test('offline shows waiting, not transcribing', () async {
    queue.enqueue(noteId, 'v1');
    queue.online = false;
    expect(queue.stateFor(current()!), VoiceChipState.waiting);
    await queue.drain();
    expect(api.transcribeRequestIds, isEmpty);
  });

  test(
    'a refused attempt is tried again by itself, when its time comes',
    () async {
      // Nothing used to wake the queue for the retry it had scheduled, so a
      // recording that failed three times in a minute then sat behind
      // "Transcribing…" until the next launch or the next recording.
      queue.backoff = const Duration(milliseconds: 40);
      api.transcribeScript.add(
        () => throw const SyncTransientException(
          'server returned 500',
          answered: true,
        ),
      );
      queue.enqueue(noteId, 'v1');
      await queue.drain();
      expect(queue.entries.single.attempts, 1);

      // No further drain from here: the queue has to come back on its own.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(current()!.transcript, isNotNull, reason: 'the retry never ran');
      expect(queue.entries, isEmpty);
    },
  );

  test(
    'the transcript keeps the job id, so it can be asked about later',
    () async {
      // The queue entry is thrown away the moment both stages finish. Without
      // this, asking for another summary — or a post — a week later has nothing
      // to bill against and the server rightly refuses.
      queue.enqueue(noteId, 'v1');
      await queue.drain();
      expect(current()!.transcript!.jobId, isNotNull);
      expect(queue.entries, isEmpty);
    },
  );

  test('the summary is written the way the user asked for', () async {
    prefs.summaryInstruction = 'Two bullet points only.';
    queue.enqueue(noteId, 'v1');
    await queue.drain();
    expect(api.lastInstruction, 'Two bullet points only.');
  });

  test('no preference leaves the server on its own wording', () async {
    queue.enqueue(noteId, 'v1');
    await queue.drain();
    expect(api.lastInstruction, isNull);
  });

  test('asking again clears the old summary and writes another', () async {
    queue.enqueue(noteId, 'v1');
    await queue.drain();
    expect(current()!.summary!.title, 'Standup');
    expect(api.summarizeCalls, 1);

    prefs.summaryInstruction = 'Two bullet points only.';
    queue.summarizeAgain(noteId, 'v1');
    // Cleared straight away: the chip must not go on showing the old title
    // while a new summary is being written.
    expect(current()!.summary, isNull);

    await queue.drain();
    expect(api.summarizeCalls, 2);
    expect(api.lastInstruction, 'Two bullet points only.');
    expect(current()!.summary!.title, 'Standup');
    // And it does not pay for the transcription twice.
    expect(api.transcribeRequestIds, hasLength(1));
  });

  test('a name the person gave survives the summary written again', () async {
    queue.enqueue(noteId, 'v1');
    await queue.drain();
    notes.updateAttachment(
      noteId,
      'v1',
      (ref) => (ref as NoteVoiceRef).copyWith(
        summary: ref.summary!.withTitle('Pricing plan'),
      ),
    );

    queue.summarizeAgain(noteId, 'v1');
    expect(current()!.summary, isNull);
    await queue.drain();

    expect(api.summarizeCalls, 2);
    expect(current()!.summary!.title, 'Pricing plan');
    expect(current()!.summary!.named, isTrue);
  });

  test('a name the person gave survives a summary written over it', () async {
    queue.enqueue(noteId, 'v1');
    await queue.drain();
    notes.updateAttachment(
      noteId,
      'v1',
      (ref) => (ref as NoteVoiceRef).copyWith(
        summary: ref.summary!.withTitle('Pricing plan'),
      ),
    );

    queue.enqueue(noteId, 'v1', fresh: true);
    await queue.drain();

    expect(current()!.summary!.title, 'Pricing plan');
  });

  test('a server that cannot be reached is a failure, not a silence', () async {
    // This is what an unreachable or refusing server looked like from the
    // chip: nothing. The attempt was not counted and no code was kept, so it
    // retried every few seconds and read as "Transcribing…" forever.
    api.transcribeScript.add(
      () => throw const SyncTransientException(
        'server returned 502',
        answered: true,
      ),
    );
    queue.enqueue(noteId, 'v1');
    await queue.drain();

    expect(queue.entries.single.attempts, 1);
    expect(queue.entries.single.lastError, SpeechCodes.unavailable);
    // Between attempts nothing is happening, and the chip must not say
    // "Transcribing…" over a wait: that read as slow when it was broken.
    expect(queue.stateFor(current()!), VoiceChipState.retrying);
    expect(
      describeSpeechError(
        SyncRefusedException(400, queue.entries.single.lastError!, const {}),
      ),
      'Transcription is temporarily unavailable. Retrying soon.',
    );
  });

  test(
    'a rejected session asks for a sign-in, and recovers after one',
    () async {
      api.transcribeScript.add(() => throw const SyncAuthException('rejected'));
      queue.enqueue(noteId, 'v1');
      await queue.drain();

      expect(queue.entries.single.lastError, SpeechCodes.sessionRejected);
      expect(queue.stateFor(current()!), VoiceChipState.needsAccount);

      // Signing in builds a new SpeechApi, which is the signal that the reason
      // for the refusal is gone.
      api = FakeSpeechApi();
      await queue.drain();

      expect(api.transcribeRequestIds, hasLength(1));
      expect(current()!.transcript, isNotNull);
      // And straight on to the summary, in the same drain: a transcript that
      // has landed does not wait for the next thing to call drain.
      expect(current()!.summary, isNotNull);
      expect(queue.stateFor(current()!), VoiceChipState.done);
    },
  );

  test('signed out says so instead of pretending to transcribe', () async {
    // `drain` returns without an API, so no error ever arrives to correct a
    // chip that says "Transcribing…". It has to be right the first time.
    final signedOut = TranscriptionQueue(
      store: queueStore,
      notes: notes,
      blobs: blobs,
      prefs: prefs,
      api: () => null,
    );
    signedOut.enqueue(noteId, 'v1');
    expect(signedOut.stateFor(current()!), VoiceChipState.needsAccount);

    await signedOut.drain();
    expect(
      signedOut.stateFor(current()!),
      VoiceChipState.needsAccount,
      reason: 'draining changes nothing without an account, and must not lie',
    );
  });

  group('transcribing on this device', () {
    late _FakeLocalTranscriber local;
    late TranscriptionQueue offline;

    /// A queue with no account and no network, which is exactly the situation
    /// the device engine exists for.
    TranscriptionQueue build({SpeechApi? Function()? api}) =>
        TranscriptionQueue(
          store: queueStore,
          notes: notes,
          blobs: blobs,
          prefs: prefs,
          api: api ?? (() => null),
          transcriber: () => local,
        );

    setUp(() {
      local = _FakeLocalTranscriber();
      prefs.transcriptEngine = TranscriptEngine.device;
      prefs.summarize = false;
      offline = build();
    });

    test('a recording becomes words with no account at all', () async {
      offline.enqueue(noteId, 'v1');
      expect(
        offline.stateFor(current()!),
        VoiceChipState.transcribing,
        reason: 'this machine can do it, so there is nothing to sign in for',
      );

      await offline.drain();

      expect(local.calls, 1);
      expect(current()!.transcript!.text, 'said here');
      expect(current()!.transcript!.engine, 'sherpa/parakeet');
      expect(
        current()!.transcript!.jobId,
        isNull,
        reason: 'nothing was billed, so there is nothing to ask about later',
      );
    });

    test('being offline is no obstacle to work that happens here', () async {
      offline.online = false;
      offline.enqueue(noteId, 'v1');

      expect(offline.stateFor(current()!), VoiceChipState.transcribing);
      await offline.drain();

      expect(current()!.transcript, isNotNull);
    });

    test('declining to send recordings does not block keeping them', () async {
      // Consent is about a recording leaving the device. It never does here,
      // so asking for it would be asking permission to do nothing.
      prefs.transcriptionDeclinedVersion = speechConsentVersion;
      offline.enqueue(noteId, 'v1');

      expect(offline.stateFor(current()!), VoiceChipState.transcribing);
      await offline.drain();

      expect(current()!.transcript, isNotNull);
    });

    test('a model nobody downloaded fails once, not five times', () async {
      // Five retries over two minutes spends a battery to reach the same
      // answer, with the chip claiming to work the whole way.
      local.state = TranscriberReadiness.needsDownload;
      offline.enqueue(noteId, 'v1');

      await offline.drain();
      await offline.drain();

      expect(local.calls, 0);
      expect(offline.stateFor(current()!), VoiceChipState.failed);
      expect(offline.entries.single.attempts, 0);
      expect(offline.entries.single.lastError, SpeechCodes.engineUnavailable);
    });

    test('Retry runs it again once the model has arrived', () async {
      local.state = TranscriberReadiness.needsDownload;
      offline.enqueue(noteId, 'v1');
      await offline.drain();
      expect(offline.stateFor(current()!), VoiceChipState.failed);

      local.state = TranscriberReadiness.ready;
      offline.retry(noteId, 'v1');
      await offline.drain();

      expect(current()!.transcript, isNotNull);
    });

    test('switching back to the cloud sends the next one there', () async {
      final cloudQueue = TranscriptionQueue(
        store: queueStore,
        notes: notes,
        blobs: blobs,
        prefs: prefs,
        api: () => api,
        transcriber: () => RoutingTranscriber(
          engineOf: () => prefs.transcriptEngine,
          cloud: CloudTranscriber(() => api),
          device: local,
        ),
      );
      cloudQueue.enqueue(noteId, 'v1');
      await cloudQueue.drain();
      expect(local.calls, 1, reason: 'the setting still says device');

      prefs.transcriptEngine = TranscriptEngine.cloud;
      notes.updateDocument(noteId, anchor, const [], [recording()]);
      cloudQueue.enqueue(noteId, 'v1', fresh: true);
      await cloudQueue.drain();

      expect(local.calls, 1, reason: 'the second one went to the server');
      expect(current()!.transcript!.jobId, isNotNull);
    });
  });

  test('someone who declined is asked, not left waiting', () {
    queue.enqueue(noteId, 'v1');
    expect(queue.stateFor(current()!), VoiceChipState.transcribing);

    prefs.transcriptionDeclinedVersion = speechConsentVersion;
    expect(queue.stateFor(current()!), VoiceChipState.needsConsent);

    // Saying yes later puts it back on the queue's own footing.
    prefs.transcriptionDeclinedVersion = null;
    expect(queue.stateFor(current()!), VoiceChipState.transcribing);
  });

  test('a recording nobody queued reads as idle, and a done one as done', () {
    expect(queue.stateFor(current()!), VoiceChipState.idle);
    queue.enqueue(noteId, 'v1');
    expect(queue.stateFor(current()!), VoiceChipState.transcribing);
  });

  test('a summary that will not come does not lose the transcript', () async {
    api.summarizeScript.add(
      () => throw const SyncRefusedException(502, 'x', {}),
    );
    queue.enqueue(noteId, 'v1');
    await queue.drain();
    await queue.drain();
    expect(current()!.transcript, isNotNull);
    expect(current()!.summary, isNull);
  });

  test(
    'an exhausted AI allowance keeps the transcript and does not retry',
    () async {
      api.summarizeScript.add(
        () => throw const SyncRefusedException(
          409,
          SpeechCodes.summariesExhausted,
          {
            'usedGenerations': 100,
            'quotaGenerations': 100,
            'resetsAt': '2026-10-01T00:00:00.000Z',
          },
        ),
      );
      queue.enqueue(noteId, 'v1');
      await queue.drain();

      expect(current()!.transcript, isNotNull);
      expect(current()!.summary, isNull);
      expect(queue.entries.single.attempts, 0);
      expect(queue.stateFor(current()!), VoiceChipState.failed);

      await queue.drain(now: DateTime.now().add(const Duration(days: 1)));
      expect(api.summarizeCalls, 1);
    },
  );

  group('on the free plan', () {
    late _FakeLocalTranscriber local;
    late _FakeLocalSummarizer here;
    late Billing billing;
    late CloudAccess access;
    late TranscriptionQueue free;

    setUp(() async {
      local = _FakeLocalTranscriber();
      here = _FakeLocalSummarizer();
      final session = FakeSession();
      billing = billingFor(session, FakeBillingApi());
      session.signIn('user-1');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      access = CloudAccess(prefs: prefs, device: local, billing: billing);
      free = TranscriptionQueue(
        store: queueStore,
        notes: notes,
        blobs: blobs,
        prefs: prefs,
        cloudAccess: access,
        api: () => api,
        summarizer: () => RoutingSummarizer(
          engineOf: () => access.summaries.engine,
          cloud: CloudSummarizer(() => api),
          device: here,
        ),
        transcriber: () => RoutingTranscriber(
          engineOf: () => access.transcription.engine,
          cloud: CloudTranscriber(() => api),
          device: local,
        ),
      );
    });

    tearDown(() {
      access.dispose();
      billing.dispose();
    });

    test(
      'a transcript made here is summarised here, whatever was saved',
      () async {
        notes.updateAttachment(
          noteId,
          'v1',
          (ref) => (ref as NoteVoiceRef).copyWith(
            transcript: VoiceTranscript(
              lang: 'en',
              engine: 'sherpa/parakeet',
              at: 1,
              segments: const [TranscriptSegment(s: 0, e: 1, t: 'said here')],
            ),
          ),
        );
        free.enqueue(noteId, 'v1');
        await free.drain();

        expect(current()!.summary!.title, 'Summarised here');
        expect(api.summarizeCalls, 0);
        expect(prefs.summaryEngine, SummaryEngine.cloud);
      },
    );

    test('a summary no model here can write says the cloud does, once, and '
        'keeps the transcript', () async {
      here.languages = {'en'};
      notes.updateAttachment(
        noteId,
        'v1',
        (ref) => (ref as NoteVoiceRef).copyWith(
          transcript: VoiceTranscript(
            lang: 'hi',
            engine: 'apple/speech',
            at: 1,
            segments: const [TranscriptSegment(s: 0, e: 1, t: 'नमस्ते')],
          ),
        ),
      );
      free.enqueue(noteId, 'v1');
      await free.drain();

      final entry = free.entries.single;
      expect(current()!.transcript, isNotNull);
      expect(current()!.summary, isNull);
      expect(entry.lastError, SpeechCodes.summaryNeedsCloudPlan);
      expect(free.stateFor(current()!), VoiceChipState.failed);
      expect(api.summarizeCalls, 0);

      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      expect(
        describeSpeechError(
          SyncRefusedException(400, entry.lastError!, {'lang': entry.lang}),
        ),
        "Hindi summaries on iPhone use the cloud, which isn't part of the "
        'Free plan. The transcript is here.',
      );

      await free.drain(now: DateTime.now().add(const Duration(days: 1)));
      expect(here.calls, 1, reason: 'a language no model has is not retried');
    });

    test('signed out, it says to sign in before choosing Cloud', () async {
      final signedOut = TranscriptionQueue(
        store: queueStore,
        notes: notes,
        blobs: blobs,
        prefs: prefs,
        cloudAccess: access,
        summarizer: () => here,
        transcriber: () => local,
      );
      addTearDown(signedOut.dispose);
      here.languages = {'en'};
      notes.updateAttachment(
        noteId,
        'v1',
        (ref) => (ref as NoteVoiceRef).copyWith(
          transcript: VoiceTranscript(
            lang: 'hi',
            engine: 'apple/speech',
            at: 1,
            segments: const [TranscriptSegment(s: 0, e: 1, t: 'नमस्ते')],
          ),
        ),
      );
      signedOut.enqueue(noteId, 'v1');
      await signedOut.drain();

      final entry = signedOut.entries.single;
      expect(entry.lastError, SpeechCodes.summaryNeedsCloudSignIn);
      expect(current()!.transcript, isNotNull);

      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      expect(
        describeSpeechError(
          SyncRefusedException(400, entry.lastError!, {'lang': entry.lang}),
        ),
        'Hindi summaries on iPhone use the cloud. Sign in, then choose Cloud '
        'for summaries in Settings › Voice & AI.',
      );
    });

    test('a language this device cannot do goes to the cloud, its summary '
        'stays here', () async {
      local.state = TranscriberReadiness.unsupported;
      prefs.language = 'hi';
      await Future<void>.delayed(const Duration(milliseconds: 5));

      free.enqueue(noteId, 'v1');
      await free.drain();

      expect(api.transcribeRequestIds, hasLength(1));
      expect(current()!.summary!.title, 'Summarised here');
      expect(api.summarizeCalls, 0);
    });
  });

  test('a plan with cloud summaries is pointed at them, by language', () {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);

    expect(
      describeSpeechError(
        const SyncRefusedException(400, SpeechCodes.summaryNeedsCloud, {
          'lang': 'hi',
        }),
      ),
      'Hindi summaries on iPhone use the cloud. Choose Cloud for summaries in '
      'Settings › Voice & AI.',
    );
    expect(
      describeSpeechError(
        const SyncRefusedException(400, SpeechCodes.summaryNeedsCloud, {
          'lang': 'xx',
        }),
      ),
      startsWith('Summaries in this language on iPhone'),
    );
  });

  test('enqueueing the same recording twice does not queue it twice', () {
    queue.enqueue(noteId, 'v1');
    queue.enqueue(noteId, 'v1');
    expect(queue.entries, hasLength(1));
  });
}
