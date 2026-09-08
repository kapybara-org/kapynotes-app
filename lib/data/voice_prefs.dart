import 'package:flutter/foundation.dart';

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
  static const String _declinedVersionKey = 'voice.transcriptionDeclinedVersion.v1';

  String? _language;
  bool _summarize = true;
  double _playbackSpeed = 1;
  int? _declinedVersion;

  /// ISO-639-1, or null for "let the provider work it out".
  ///
  /// Worth having as a setting because detection is the part that goes wrong:
  /// someone whose notes are always in one language, especially one that is
  /// often misdetected, should be able to say so once.
  String? get language => _language;

  bool get summarize => _summarize;
  double get playbackSpeed => _playbackSpeed;

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
