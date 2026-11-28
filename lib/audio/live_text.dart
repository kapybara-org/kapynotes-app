import 'dart:async';
import 'package:flutter/foundation.dart';

import '../data/voice_prefs.dart';
import '../speech/live_translation.dart';

/// Decides, as a recording starts, whether it is heard and translated live.
///
/// With live translation off this reads one preference and nothing else: no
/// channel is called, nothing is created, and the recording runs exactly as
/// it always has.
class LiveTranslationLauncher {
  LiveTranslationLauncher({
    required this.engine,
    required this.prefs,
    String Function()? deviceLanguage,
  }) : _deviceLanguage =
           deviceLanguage ??
           (() => PlatformDispatcher.instance.locale.languageCode);

  final LiveTranslationEngine engine;
  final VoicePrefs prefs;
  final String Function() _deviceLanguage;

  /// The language heard: the voice-notes language, else the device's own.
  String get from => prefs.language ?? _deviceLanguage().toLowerCase();

  LiveLanguages? _languages;

  /// What the device hears and translates into, asked once.
  Future<LiveLanguages> languages() async =>
      _languages ??= await engine.languages();

  /// The pair for a recording starting now, with each language's name, or
  /// null when it isn't heard live: the setting is off, no language is
  /// picked, or the pair's languages are no longer on the device.
  Future<LivePair?> pair() async {
    if (!prefs.liveTranslation) return null;
    final to = prefs.liveTranslateTo;
    final from = this.from;
    if (to == null || to == from) return null;
    try {
      final status = await engine.pairStatus(from, to);
      if (status.status != LivePairStatus.installed) return null;
      final names = await languages();
      return (
        from: from,
        to: to,
        fromName: names.nameOf(from),
        toName: names.nameOf(to),
      );
    } catch (error) {
      debugPrint('KapyNotes: live translation unavailable: $error');
      return null;
    }
  }
}

typedef LivePair = ({String from, String to, String fromName, String toName});

/// What a recording with live translation on has heard so far, for the card
/// above the recording bar and for the Lock Screen.
class LivePhrases extends ChangeNotifier {
  LivePhrases({
    required this.from,
    required this.to,
    required this.fromName,
    required this.toName,
    required LiveTranslationEngine engine,
    void Function()? onTranslated,
  }) : _onTranslated = onTranslated {
    _subscriptions = [
      engine.phrases.listen(_onPhrase),
      engine.stops.listen(_onStop),
    ];
  }

  /// How many phrases the card keeps: the one being heard and two before it.
  static const int shown = 3;

  final String from;
  final String to;
  final String fromName;
  final String toName;
  final void Function()? _onTranslated;
  late final List<StreamSubscription<Object?>> _subscriptions;
  final List<LivePhrase> _phrases = [];
  LiveTranslationStop? _stopped;
  bool _disposed = false;

  /// Oldest first, at most [shown].
  List<LivePhrase> get phrases => List.unmodifiable(_phrases);

  /// Why live text ended before the recording did, or null.
  LiveTranslationStop? get stopped => _stopped;

  /// The newest phrase that has its translation: what a locked phone shows,
  /// which is why it trails the card by the phrase still being heard.
  LivePhrase? get latestTranslated {
    for (final phrase in _phrases.reversed) {
      if (phrase.translation != null) return phrase;
    }
    return null;
  }

  void _onPhrase(LivePhrase phrase) {
    if (_disposed) return;
    final index = _phrases.indexWhere((p) => p.id == phrase.id);
    if (index >= 0) {
      _phrases[index] = phrase;
    } else {
      if (phrase.heard.trim().isEmpty && phrase.translation == null) return;
      _phrases.add(phrase);
      if (_phrases.length > shown) _phrases.removeAt(0);
    }
    notifyListeners();
    if (phrase.translation != null) _onTranslated?.call();
  }

  void _onStop(LiveTranslationStop reason) {
    if (_disposed) return;
    _stopped = reason;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }
}

/// [text] cut to at most [limit] characters at a word boundary, so a phrase
/// fits the Live Activity's 4 KB and never ends mid-word.
String clipPhrase(String text, int limit) {
  final trimmed = text.trim();
  if (trimmed.length <= limit) return trimmed;
  final cut = trimmed.substring(0, limit);
  final space = cut.lastIndexOf(' ');
  return '${(space > limit ~/ 2 ? cut.substring(0, space) : cut).trimRight()}…';
}
