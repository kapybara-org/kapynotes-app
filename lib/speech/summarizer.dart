import 'note_summary_text.dart';

/// Where a summary gets written.
///
/// Not a capability list — a preference. What is actually *possible* is
/// [Summarizer.readiness], which the device options answer differently on
/// every machine.
enum SummaryEngine {
  /// Our server, which is the only one that can write a good summary of a
  /// long transcript today.
  cloud,

  /// This device: the platform's own model where there is one, otherwise a
  /// downloaded one. Nothing leaves the machine.
  device,
}

/// Whether a summariser can run right now, and if not, what would fix it.
///
/// Every value is something the settings row can say in one short sentence,
/// because that is the only place a user meets it.
enum SummarizerReadiness {
  ready,

  /// Cloud only: no account, or transcription not turned on.
  needsAccount,

  /// A downloaded model that has not been downloaded.
  needsDownload,

  /// The machine can do this and the user has not switched it on — Apple
  /// Intelligence off in System Settings, in practice. Its own answer
  /// because it is the most actionable one and the most common.
  needsSystemFeature,

  /// The platform has a model and is still fetching it. Apple Intelligence
  /// does this on its own schedule; it is not a failure and not our download.
  preparing,

  /// This OS, this hardware, or this build has no such thing.
  unsupported,
}

/// A summary before it is attached to a recording.
///
/// Deliberately not `VoiceSummary`: that carries a timestamp and belongs to
/// the note. A summariser's job ends at the words.
class SummaryDraft {
  const SummaryDraft({
    required this.engine,
    required this.title,
    required this.points,
  });

  /// Goes into the ref, so a note can say what wrote it long after the
  /// setting changed. `cf/...` for the server, `apple/foundation-models`,
  /// `gemma-3-1b`.
  final String engine;
  final String title;
  final List<String> points;
}

/// Something that can turn a transcript into a title and a few points.
///
/// The three implementations behind this — our server, Apple's on-device
/// model, and a downloaded Gemma — differ in every way that does not matter
/// here: one is metered, one appears and disappears with a system setting,
/// one is 584 MB of file. What they share is this call.
abstract class Summarizer {
  /// What this would do if asked right now. Cheap enough for a settings pane
  /// to call on every open; never downloads anything to find out.
  Future<SummarizerReadiness> readiness();

  /// The summary, or a throw. [jobId] is the server's handle on the
  /// transcription this came from, and is meaningless to the local ones.
  ///
  /// [instruction] replaces the default description of what a summary is —
  /// never the rules around it. A user choosing bullet points over prose is
  /// choosing a kind of summary; they are not choosing whether the model may
  /// invent things, and no implementation here lets them.
  Future<SummaryDraft> summarize({
    required String text,
    required String lang,
    String? jobId,
    String? instruction,
  });

  /// Writes something else from the transcript — a post, a shorter version,
  /// whatever [instruction] asks for — and answers with the text itself.
  ///
  /// Free text rather than a title and points because the answer is meant to
  /// be copied out whole.
  Future<String> rewrite({
    required String text,
    required String lang,
    required String instruction,
    String? jobId,
  });
}

/// Raised when a summariser was asked to work and cannot.
///
/// Carries the readiness that explains it, so the queue can tell "come back
/// when the model is downloaded" apart from "this will never work here" and
/// stop retrying the second one.
class SummarizerUnavailable implements Exception {
  const SummarizerUnavailable(this.readiness, this.message);

  final SummarizerReadiness readiness;
  final String message;

  /// Whether waiting could help. A missing download might arrive, a system
  /// feature might be switched on; an ineligible device will not become
  /// eligible.
  bool get isTemporary =>
      readiness == SummarizerReadiness.preparing ||
      readiness == SummarizerReadiness.needsDownload ||
      readiness == SummarizerReadiness.needsSystemFeature;

  @override
  String toString() => message;
}

/// Picks the device summariser that this machine actually has.
///
/// Ordered, best-for-the-user first: the platform's own model where there is
/// one, because it is free, already downloaded and costs no disk, and a model
/// we ship a download for after that — which is the answer for every Windows
/// and Linux machine and every Mac without Apple Intelligence.
///
/// The order is not a quality judgement. It is that one of them is already
/// there and the other is several hundred megabytes.
class DeviceSummarizer implements Summarizer {
  DeviceSummarizer(this.candidates);

  final List<Summarizer> candidates;

  @override
  Future<SummarizerReadiness> readiness() async {
    var best = SummarizerReadiness.unsupported;
    for (final candidate in candidates) {
      final state = await candidate.readiness();
      if (state == SummarizerReadiness.ready) return state;
      // Report whichever failure the user can act on. "Download a model" is
      // an action; "your Mac is not eligible" is not, and neither is a wait.
      if (_rank(state) > _rank(best)) best = state;
    }
    return best;
  }

  /// How worth reporting a failure is. Switching on a feature already on the
  /// machine beats spending several hundred megabytes, which beats waiting,
  /// which beats being told the machine cannot do it at all.
  static int _rank(SummarizerReadiness state) => switch (state) {
    SummarizerReadiness.ready => 4,
    SummarizerReadiness.needsSystemFeature => 3,
    SummarizerReadiness.needsDownload => 2,
    SummarizerReadiness.preparing => 1,
    _ => 0,
  };

  @override
  Future<SummaryDraft> summarize({
    required String text,
    required String lang,
    String? jobId,
    String? instruction,
  }) async {
    final chosen = await _ready();
    return chosen.summarize(
      text: text,
      lang: lang,
      jobId: jobId,
      instruction: instruction,
    );
  }

  @override
  Future<String> rewrite({
    required String text,
    required String lang,
    required String instruction,
    String? jobId,
  }) async {
    final chosen = await _ready();
    return chosen.rewrite(
      text: text,
      lang: lang,
      instruction: instruction,
      jobId: jobId,
    );
  }

  Future<Summarizer> _ready() async {
    for (final candidate in candidates) {
      if (await candidate.readiness() == SummarizerReadiness.ready) {
        return candidate;
      }
    }
    throw SummarizerUnavailable(
      await readiness(),
      'No summariser is ready on this device.',
    );
  }
}

/// Sends the work wherever the preference says.
///
/// Holds both so that changing the setting takes effect on the next
/// recording without rebuilding anything, and so a queue entry that was
/// written under one setting is finished under the current one.
class RoutingSummarizer implements Summarizer {
  RoutingSummarizer({
    required this.engineOf,
    required this.cloud,
    required this.device,
  });

  final SummaryEngine Function() engineOf;
  final Summarizer cloud;
  final Summarizer device;

  Summarizer get _chosen => engineOf() == SummaryEngine.device ? device : cloud;

  @override
  Future<SummarizerReadiness> readiness() => _chosen.readiness();

  @override
  Future<SummaryDraft> summarize({
    required String text,
    required String lang,
    String? jobId,
    String? instruction,
  }) => _chosen.summarize(
    text: text,
    lang: lang,
    jobId: jobId,
    instruction: instruction,
  );

  @override
  Future<String> rewrite({
    required String text,
    required String lang,
    required String instruction,
    String? jobId,
  }) => _chosen.rewrite(
    text: text,
    lang: lang,
    instruction: instruction,
    jobId: jobId,
  );
}

/// Turns a model's free text into a title and points.
///
/// Shared by every local summariser, because both of them are asked for the
/// same shape and both of them sometimes answer with a preamble, a heading,
/// or numbered lines instead. See [parseSummaryText].
SummaryDraft draftFromText(String raw, {required String engine}) {
  final parsed = parseSummaryText(raw);
  return SummaryDraft(
    engine: engine,
    title: parsed.title,
    points: parsed.points,
  );
}
