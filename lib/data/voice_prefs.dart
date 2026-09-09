import 'package:flutter/foundation.dart';

import '../speech/summarizer.dart';
import '../speech/transcriber.dart';
import '../speech/summary_instructions.dart';
import 'local_store.dart';

/// Everything the user has decided about voice notes.
///
/// Lives in the main [LocalStore], which is already read at launch, so a user
/// who never records pays nothing at startup for these existing.
class VoicePrefs extends ChangeNotifier {
  VoicePrefs(this._store);

  final LocalStore _store;

  static const String _languageKey = 'voice.language.v1';
  static const String _summarizeKey = 'voice.summarize.v1';
  static const String _playbackSpeedKey = 'voice.playbackSpeed.v1';
  static const String _declinedVersionKey =
      'voice.transcriptionDeclinedVersion.v1';
  static const String _summaryEngineKey = 'voice.summaryEngine.v1';
  static const String _transcriptEngineKey = 'voice.transcriptEngine.v1';
  static const String _summaryInstructionKey = 'voice.summaryInstruction.v1';
  static const String _modelTermsKey = 'voice.modelTerms.v1';

  String? _language;
  bool _summarize = true;
  double _playbackSpeed = 1;
  int? _declinedVersion;
  SummaryEngine _summaryEngine = SummaryEngine.cloud;
  TranscriptEngine _transcriptEngine = TranscriptEngine.cloud;
  String? _summaryInstruction;
  Map<String, int> _modelTerms = const {};

  /// ISO-639-1, or null for "let the provider work it out".
  ///
  /// Worth having as a setting because detection is the part that goes wrong:
  /// someone whose notes are always in one language, especially one that is
  /// often misdetected, should be able to say so once.
  String? get language => _language;

  bool get summarize => _summarize;
  double get playbackSpeed => _playbackSpeed;

  /// Where the summary is written.
  ///
  /// Cloud by default, and deliberately: it is the only one that is there for
  /// everybody, and the device options are each conditional on something —
  /// an eligible Mac, or 584 MB somebody chose to download.
  SummaryEngine get summaryEngine => _summaryEngine;

  /// Where a recording is turned into words.
  ///
  /// Cloud by default for the same reason [summaryEngine] is: it is the one
  /// that is there for everybody, knows the most languages, and is the same on
  /// a five-year-old phone as on a new laptop. The device option is
  /// conditional on something — a recent Apple OS, or 670 MB somebody chose to
  /// download — and defaulting to it would mean a fresh install quietly not
  /// transcribing on hardware that cannot.
  TranscriptEngine get transcriptEngine => _transcriptEngine;

  /// How this user wants their summaries written, in their own words.
  ///
  /// Null means "however the app writes them", which is
  /// [defaultSummaryInstruction] — and that text is what the editor is
  /// pre-filled with, so somebody who opens it and changes one line gets
  /// exactly the summary they now see described. Stored rather than sent
  /// every time so the choice outlives the recording it was made on.
  String? get summaryInstruction => _summaryInstruction;

  /// What the editor should show: their words if they have written any,
  /// otherwise the wording that is actually in use.
  String get effectiveSummaryInstruction =>
      _summaryInstruction ?? defaultSummaryInstruction;

  /// The consent version the user last said no to.
  ///
  /// Kept so the sheet is not put in front of them again on every recording.
  /// A *raised* version asks once more, which is the point of versioning it:
  /// the wording changed, so the old refusal was to a different question.
  int? get transcriptionDeclinedVersion => _declinedVersion;

  void load() {
    final language = _store.data[_languageKey];
    _language = language is String && language.isNotEmpty ? language : null;

    final summarize = _store.data[_summarizeKey];
    _summarize = summarize is bool ? summarize : true;

    final speed = _store.data[_playbackSpeedKey];
    _playbackSpeed = speed is num ? _clampSpeed(speed.toDouble()) : 1;

    final declined = _store.data[_declinedVersionKey];
    _declinedVersion = declined is int ? declined : null;

    final engine = _store.data[_summaryEngineKey];
    _summaryEngine = engine == 'device'
        ? SummaryEngine.device
        : SummaryEngine.cloud;

    final transcriptEngine = _store.data[_transcriptEngineKey];
    _transcriptEngine = transcriptEngine == 'device'
        ? TranscriptEngine.device
        : TranscriptEngine.cloud;

    final instruction = _store.data[_summaryInstructionKey];
    _summaryInstruction = instruction is String && instruction.trim().isNotEmpty
        ? instruction
        : null;

    final terms = _store.data[_modelTermsKey];
    _modelTerms = terms is Map
        ? {
            for (final entry in terms.entries)
              if (entry.value is int) '${entry.key}': entry.value as int,
          }
        : const {};
  }

  /// Whether this model's terms have been agreed to at [version].
  ///
  /// False again when the version is raised, because a new version is a
  /// different set of words and the old agreement was not to them.
  bool hasAcceptedTerms(String modelId, int version) =>
      (_modelTerms[modelId] ?? -1) >= version;

  void acceptTerms(String modelId, int version) {
    if (hasAcceptedTerms(modelId, version)) return;
    _modelTerms = {..._modelTerms, modelId: version};
    _store.putNow(_modelTermsKey, _modelTerms);
    notifyListeners();
  }

  set language(String? value) {
    final next = (value != null && value.isNotEmpty) ? value : null;
    if (next == _language) return;
    _language = next;
    _store.putNow(_languageKey, next);
    notifyListeners();
  }

  set summarize(bool value) {
    if (value == _summarize) return;
    _summarize = value;
    _store.putNow(_summarizeKey, value);
    notifyListeners();
  }

  set playbackSpeed(double value) {
    final next = _clampSpeed(value);
    if (next == _playbackSpeed) return;
    _playbackSpeed = next;
    _store.putNow(_playbackSpeedKey, next);
    notifyListeners();
  }

  set summaryEngine(SummaryEngine value) {
    if (value == _summaryEngine) return;
    _summaryEngine = value;
    _store.putNow(_summaryEngineKey, value.name);
    notifyListeners();
  }

  set transcriptEngine(TranscriptEngine value) {
    if (value == _transcriptEngine) return;
    _transcriptEngine = value;
    _store.putNow(_transcriptEngineKey, value.name);
    notifyListeners();
  }

  /// Setting this to the default wording, or to nothing, clears it: there is
  /// no difference between "I want the standard summary" and "I have not
  /// chosen", and storing one would mean a later improvement to the default
  /// never reached somebody who had once opened the editor and changed
  /// nothing.
  set summaryInstruction(String? value) {
    final trimmed = value?.trim() ?? '';
    final next = (trimmed.isEmpty || trimmed == defaultSummaryInstruction)
        ? null
        : (trimmed.length > instructionMaxChars
              ? trimmed.substring(0, instructionMaxChars)
              : trimmed);
    if (next == _summaryInstruction) return;
    _summaryInstruction = next;
    _store.putNow(_summaryInstructionKey, next);
    notifyListeners();
  }

  set transcriptionDeclinedVersion(int? value) {
    if (value == _declinedVersion) return;
    _declinedVersion = value;
    _store.putNow(_declinedVersionKey, value);
    notifyListeners();
  }

  /// Whether the consent sheet should be offered for [version].
  ///
  /// False once they have said no to this exact version, and true again when
  /// it is raised — a new version is a different question.
  bool shouldOfferConsent(int version) =>
      _declinedVersion == null || _declinedVersion! < version;

  /// A speed outside this range is a corrupt record, not a preference.
  static double _clampSpeed(double value) {
    if (value.isNaN || value <= 0) return 1;
    return value.clamp(0.5, 3.0);
  }
}
