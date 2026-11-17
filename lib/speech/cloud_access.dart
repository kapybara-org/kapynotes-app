import 'dart:async';

import 'package:flutter/foundation.dart';

import '../billing/billing.dart';
import '../data/voice_prefs.dart';
import 'summarizer.dart';
import 'transcriber.dart';

/// What Settings shows for one engine choice: the engine that will actually
/// run, whether Cloud can be picked, and the one line that explains either.
typedef EngineAccess<E extends Enum> = ({
  E engine,
  bool cloudSelectable,
  String? note,
});

/// Which engines the plan lets this device use.
///
/// The free plan transcribes and summarises on the device; Pro and its trial
/// may use the cloud. Bought minutes keep cloud transcription, and so does a
/// chosen language this device cannot transcribe. Summaries have no such
/// exceptions.
///
/// Never writes [VoicePrefs]: a saved Cloud the plan does not allow runs on
/// the device, and comes back by itself when the plan does.
///
/// Unknown is not free. Signed out, or signed in before the server's first
/// answer, the saved choice stands, so a slow network never moves a Pro
/// user's recordings to the device. Signed out, the cloud cannot run anyway
/// and says so through its own readiness.
class CloudAccess extends ChangeNotifier {
  CloudAccess({
    required VoicePrefs prefs,
    required Transcriber device,
    Billing? billing,
  }) : _prefs = prefs,
       _device = device,
       _billing = billing {
    _prefs.addListener(_update);
    _billing?.addListener(_update);
    _seen = _snapshot;
  }

  final VoicePrefs _prefs;

  /// Answers for the chosen language: each device engine reads the setting
  /// itself.
  final Transcriber _device;
  final Billing? _billing;

  String? _checkedLanguage;

  /// Whether the device said it cannot transcribe [_checkedLanguage]. Null
  /// until it has answered, which keeps the saved choice like any unknown.
  bool? _unsupported;
  Object? _seen;
  bool _disposed = false;

  bool get cloudTranscriptionAllowed =>
      cloudSummariesAllowed || _credits > 0 || _languageUnsupported != false;

  bool get cloudSummariesAllowed => _paysForCloud ?? true;

  /// Whether the chosen language is one this device cannot transcribe. Never
  /// with "Detect automatically": there is no language to ask about.
  bool get languageNeedsCloud => _languageUnsupported ?? false;

  EngineAccess<TranscriptEngine> get transcription {
    if (!cloudTranscriptionAllowed) {
      return (
        engine: TranscriptEngine.device,
        cloudSelectable: false,
        note: 'Cloud transcription is on Pro',
      );
    }
    final engine = _prefs.transcriptEngine;
    final language = _prefs.language;
    final onlyForLanguage =
        engine == TranscriptEngine.cloud &&
        _paysForCloud == false &&
        _credits == 0 &&
        languageNeedsCloud;
    return (
      engine: engine,
      cloudSelectable: true,
      note: onlyForLanguage
          ? 'Cloud is used for ${speechLanguages[language] ?? language}, '
                "which this device can't transcribe"
          : null,
    );
  }

  EngineAccess<SummaryEngine> get summaries => cloudSummariesAllowed
      ? (engine: _prefs.summaryEngine, cloudSelectable: true, note: null)
      : (
          engine: SummaryEngine.device,
          cloudSelectable: false,
          note: 'Cloud summaries are on Pro',
        );

  /// Pro or its trial, or null while the plan is unknown.
  bool? get _paysForCloud {
    final billing = _billing;
    final plan = billing?.entitlements;
    if (billing == null || plan == null) return null;
    return plan.isPro || billing.trialRunning;
  }

  int get _credits => _billing?.entitlements?.speechCreditSeconds ?? 0;

  /// Asks the device the first time a language is read rather than when it
  /// is set: [VoicePrefs.load] announces nothing.
  bool? get _languageUnsupported {
    final language = _prefs.language;
    if (language == null) return false;
    if (language != _checkedLanguage) {
      _checkedLanguage = language;
      _unsupported = null;
      unawaited(_check(language));
    }
    return _unsupported;
  }

  Future<void> _check(String language) async {
    final state = await _device.readiness();
    if (_disposed || language != _checkedLanguage) return;
    _unsupported = state == TranscriberReadiness.unsupported;
    _update();
  }

  /// Everything Settings can read. Reading [languageNeedsCloud] here also
  /// starts the device's answer for a new language, whatever the plan.
  Object get _snapshot => (transcription, summaries, languageNeedsCloud);

  /// Billing notifies for much besides the plan, so only a change in what
  /// Settings would show is passed on.
  void _update() {
    final next = _snapshot;
    if (next == _seen) return;
    _seen = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _prefs.removeListener(_update);
    _billing?.removeListener(_update);
    super.dispose();
  }
}
