import 'dart:io';

import '../data/note_attachment.dart';
import 'speech_api.dart';

/// Where a recording gets turned into words.
///
/// Not a capability list — a preference. What is actually *possible* is
/// [Transcriber.readiness], which the device options answer differently on
/// every machine. Deliberately the same shape as [SummaryEngine]: a user who
/// has understood one of these settings has understood both.
enum TranscriptEngine {
  /// Our server, which is there for everybody, knows the most languages, and
  /// is metered.
  cloud,

  /// This device: the platform's own recogniser where there is one, otherwise
  /// a downloaded model. No account, no minutes, and the recording never
  /// leaves the machine.
  device,
}

/// Whether a transcriber can run right now, and if not, what would fix it.
///
/// Every value is something the settings row can say in one short sentence,
/// because that is the only place a user meets it.
enum TranscriberReadiness {
  ready,

  /// Cloud only: no account, or transcription not turned on.
  needsAccount,

  /// A downloaded model that has not been downloaded.
  needsDownload,

  /// The machine can do this and has not been asked to fetch its own model
  /// yet — Apple downloads a locale on request, on its own schedule.
  needsSystemFeature,

  /// The platform has a recogniser and is still fetching the language. Not a
  /// failure, and not our download.
  preparing,

  /// This OS, this hardware, or this build has no such thing.
  unsupported,
}

/// A transcript before it is attached to a recording.
///
/// Deliberately not [VoiceTranscript]: that carries a timestamp and belongs
/// to the note. A transcriber's job ends at the words.
class TranscriptDraft {
  const TranscriptDraft({
    required this.engine,
    required this.lang,
    required this.segments,
    this.jobId,
    this.usage,
  });

  /// Goes into the ref, so a note can say what wrote it long after the
  /// setting changed. `cf/deepgram-nova-3` for the server,
  /// `apple/speech-analyzer`, `sherpa/parakeet-tdt-0.6b-v3-int8`.
  final String engine;

  /// ISO-639-1 where the engine knows it, else the engine's own word.
  final String lang;

  final List<TranscriptSegment> segments;

  /// The server's handle on this transcription, and null for every local one:
  /// there is nothing to bill and nothing to ask again about.
  final String? jobId;

  /// What the month looks like after this. Null locally, where there is no
  /// month and no allowance — which is the entire point of running here.
  final SpeechUsage? usage;
}

/// Something that can turn a recording into words.
///
/// The three implementations behind this — our server, Apple's own
/// recogniser, and a downloaded Parakeet — differ in every way that does not
/// matter here: one is metered, one appears and disappears with a system
/// asset download, one is 670 MB of file. What they share is this call.
abstract class Transcriber {
  /// What this would do if asked right now. Cheap enough for a settings pane
  /// to call on every open; never downloads anything to find out.
  Future<TranscriberReadiness> readiness();

  /// The words, or a throw.
  ///
  /// Takes the blob's [File] rather than its bytes because the local engines
  /// stream it from disk: a thirty-minute recording is tens of megabytes of
  /// AAC and several hundred of decoded PCM, and there is no reason for the
  /// whole of either to sit in the heap. The cloud one reads it, because an
  /// upload has to.
  ///
  /// [requestId] names one *intent* to transcribe: every retry of it is free
  /// on the server, and asking again deliberately means minting a new one. It
  /// means nothing locally, where nothing is billed.
  Future<TranscriptDraft> transcribe({
    required File audio,
    required String requestId,
    String? language,
  });
}

/// Raised when a transcriber was asked to work and cannot.
///
/// Carries the readiness that explains it, so the queue can tell "come back
/// when the model is downloaded" apart from "this will never work here" and
/// stop retrying the second one.
class TranscriberUnavailable implements Exception {
  const TranscriberUnavailable(this.readiness, this.message);

  final TranscriberReadiness readiness;
  final String message;

  /// Whether waiting could help. A missing download might arrive, a system
  /// asset might finish; an ineligible device will not become eligible.
  bool get isTemporary =>
      readiness == TranscriberReadiness.preparing ||
      readiness == TranscriberReadiness.needsDownload ||
      readiness == TranscriberReadiness.needsSystemFeature;

  @override
  String toString() => message;
}

/// Picks the device transcriber that this machine actually has.
///
/// Ordered, best-for-the-user first: the platform's own recogniser where
/// there is one, because it is free, already downloaded and costs no disk,
/// and a model we ship a download for after that — which is the answer for
/// every Windows and Android machine.
///
/// The order is not a quality judgement. Parakeet beats Apple's recogniser on
/// several of these languages. It is that one of them is already there and
/// the other is 670 MB.
class DeviceTranscriber implements Transcriber {
  DeviceTranscriber(this.candidates);

  final List<Transcriber> candidates;

  @override
  Future<TranscriberReadiness> readiness() async {
    var best = TranscriberReadiness.unsupported;
    for (final candidate in candidates) {
      final state = await candidate.readiness();
      if (state == TranscriberReadiness.ready) return state;
      // Report whichever failure the user can act on. "Download a model" is
      // an action; "your device cannot do this" is not, and neither is a wait.
      if (_rank(state) > _rank(best)) best = state;
    }
    return best;
  }

  /// How worth reporting a failure is. Asking the system for a language it
  /// already knows how to fetch beats spending 670 MB, which beats waiting,
  /// which beats being told the machine cannot do it at all.
  static int _rank(TranscriberReadiness state) => switch (state) {
    TranscriberReadiness.ready => 4,
    TranscriberReadiness.needsSystemFeature => 3,
    TranscriberReadiness.needsDownload => 2,
    TranscriberReadiness.preparing => 1,
    _ => 0,
  };

  @override
  Future<TranscriptDraft> transcribe({
    required File audio,
    required String requestId,
    String? language,
  }) async {
    final chosen = await _ready();
    return chosen.transcribe(
      audio: audio,
      requestId: requestId,
      language: language,
    );
  }

  Future<Transcriber> _ready() async {
    for (final candidate in candidates) {
      if (await candidate.readiness() == TranscriberReadiness.ready) {
        return candidate;
      }
    }
    throw TranscriberUnavailable(
      await readiness(),
      'No transcriber is ready on this device.',
    );
  }
}

/// Sends the work wherever the preference says.
///
/// Holds both so that changing the setting takes effect on the next
/// recording without rebuilding anything, and so a queue entry that was
/// written under one setting is finished under the current one.
class RoutingTranscriber implements Transcriber {
  RoutingTranscriber({
    required this.engineOf,
    required this.cloud,
    required this.device,
  });

  final TranscriptEngine Function() engineOf;
  final Transcriber cloud;
  final Transcriber device;

  Transcriber get _chosen =>
      engineOf() == TranscriptEngine.device ? device : cloud;

  @override
  Future<TranscriberReadiness> readiness() => _chosen.readiness();

  @override
  Future<TranscriptDraft> transcribe({
    required File audio,
    required String requestId,
    String? language,
  }) => _chosen.transcribe(
    audio: audio,
    requestId: requestId,
    language: language,
  );
}

/// Turns one long block of recognised text into timed segments.
///
/// Shared by both local engines, because neither of them is asked for
/// sentences and both of them can say when each word was spoken. Splitting on
/// sentence punctuation gives the transcript view something to lay out and
/// playback something to follow; a single paragraph would give it neither.
///
/// [words] must be in order. A word with no time — which happens at the edges
/// of some models' output — inherits the run it lands in rather than starting
/// a new one, since a segment boundary is a worse guess than a slightly long
/// segment.
List<TranscriptSegment> segmentsFromWords(List<TimedWord> words) {
  if (words.isEmpty) return const [];
  final segments = <TranscriptSegment>[];
  var buffer = <TimedWord>[];

  void flush() {
    if (buffer.isEmpty) return;
    final text = buffer.map((w) => w.text).join(' ').trim();
    if (text.isNotEmpty) {
      segments.add(
        TranscriptSegment(s: buffer.first.startMs, e: buffer.last.endMs, t: text),
      );
    }
    buffer = <TimedWord>[];
  }

  for (final word in words) {
    buffer.add(word);
    // A sentence end, or a segment long enough that the view would rather
    // have a break than a wall. Twelve seconds is about two spoken sentences,
    // and is the point past which highlighting the current line stops meaning
    // anything.
    final ended = _endsSentence(word.text);
    final long = word.endMs - buffer.first.startMs >= 12000;
    if (ended || long) flush();
  }
  flush();
  return segments;
}

bool _endsSentence(String word) {
  final trimmed = word.trimRight();
  if (trimmed.isEmpty) return false;
  final last = trimmed[trimmed.length - 1];
  return last == '.' || last == '?' || last == '!' || last == '。' ||
      last == '？' || last == '！';
}

/// One recognised word and when it was said.
class TimedWord {
  const TimedWord({
    required this.text,
    required this.startMs,
    required this.endMs,
  });

  final String text;
  final int startMs;
  final int endMs;
}
