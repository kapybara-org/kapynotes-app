import 'dart:async';
import 'dart:ui' show Locale, TextRange;

import 'package:flutter/services.dart';

import 'platform.dart';

/// The operating system's spelling service behind Flutter's editor contract.
///
/// Flutter already bridges this service on Android and iOS. Its desktop
/// engines do not, so the runners expose the same small result shape using
/// NSSpellChecker and Windows Spell Checking. Nothing here owns a dictionary,
/// uploads note text, or changes what the user typed.
///
/// Finding the misspellings and correcting one are separate calls on desktop.
/// Guessing what a word should have been costs two orders of magnitude more
/// than finding it — a long note pays that for every flagged word on every
/// pause in typing, while only the word somebody asks about is ever read out.
/// Android and iOS answer both questions in one call of their own, and those
/// corrections arrive with the spans.
class PlatformSpellCheckService implements SpellCheckService {
  PlatformSpellCheckService({
    MethodChannel channel = const MethodChannel(_channelName),
    Duration quietPeriod = const Duration(milliseconds: 180),
  }) : _channel = channel,
       _quietPeriod = quietPeriod;

  static const String _channelName = 'kapynotes/spell_check';

  final MethodChannel _channel;
  final Duration _quietPeriod;
  final DefaultSpellCheckService _mobile = DefaultSpellCheckService();
  final Map<String, List<String>> _suggestions = {};
  final Map<String, Future<List<String>>> _suggestionRequests = {};
  Timer? _quietTimer;
  Completer<List<SuggestionSpan>?>? _pendingRequest;
  int _requestGeneration = 0;
  bool _disposed = false;

  /// How many words' corrections are kept. Someone works through a note a
  /// word at a time; the whole note's worth was never going to be read.
  static const int _suggestionCacheLimit = 64;

  @override
  Future<List<SuggestionSpan>?> fetchSpellCheckSuggestions(
    Locale locale,
    String text,
  ) {
    // EditableText asks after every edit. Waiting for a brief pause means a
    // long note crosses the platform boundary once per word, not once per
    // keystroke. Superseded requests resolve as cancelled, just like Flutter's
    // own mobile service.
    if (_disposed) return Future.value(null);
    final generation = ++_requestGeneration;
    _quietTimer?.cancel();
    final previous = _pendingRequest;
    if (previous != null && !previous.isCompleted) previous.complete(null);

    final completer = Completer<List<SuggestionSpan>?>();
    _pendingRequest = completer;

    Future<void> check() async {
      _quietTimer = null;
      final spans = await _fetchNow(locale, text);
      if (!completer.isCompleted) {
        completer.complete(
          !_disposed && generation == _requestGeneration ? spans : null,
        );
      }
      if (identical(_pendingRequest, completer)) _pendingRequest = null;
    }

    if (_quietPeriod == Duration.zero) {
      unawaited(check());
    } else {
      _quietTimer = Timer(_quietPeriod, () => unawaited(check()));
    }
    return completer.future;
  }

  /// Corrections already in hand for [word], if it has been asked about.
  List<String>? cachedSuggestionsFor(Locale locale, String word) =>
      _suggestions['${locale.toLanguageTag()}\u0000$word'];

  /// What the platform would offer for one misspelled word.
  ///
  /// Called when a menu is about to show them, and remembered so that opening
  /// the same menu twice costs one lookup. Words repeat within a note, and the
  /// answer does not depend on where in the text the word sits.
  Future<List<String>> suggestionsFor(
    Locale locale,
    String text,
    TextRange range,
  ) {
    if (_disposed ||
        range.start < 0 ||
        range.end <= range.start ||
        range.end > text.length) {
      return Future.value(const []);
    }
    final word = text.substring(range.start, range.end);
    // Keyed by language too: the same letters are a different question of a
    // different dictionary.
    final key = '${locale.toLanguageTag()}\u0000$word';
    final known = _suggestions[key];
    if (known != null) return Future.value(known);
    final pending = _suggestionRequests[key];
    if (pending != null) return pending;

    final request = _suggestNow(locale, text, range).then((suggestions) {
      _suggestionRequests.remove(key);
      if (_disposed) return suggestions;
      if (_suggestions.length >= _suggestionCacheLimit) {
        _suggestions.remove(_suggestions.keys.first);
      }
      _suggestions[key] = suggestions;
      return suggestions;
    });
    _suggestionRequests[key] = request;
    return request;
  }

  Future<List<String>> _suggestNow(
    Locale locale,
    String text,
    TextRange range,
  ) async {
    if (!AppPlatform.isMacOS && !AppPlatform.isWindows) return const [];
    try {
      final raw = await _channel.invokeListMethod<Object?>('suggest', {
        'language': locale.toLanguageTag(),
        'text': text,
        'startIndex': range.start,
        'endIndex': range.end,
      });
      return raw?.whereType<String>().toList(growable: false) ?? const [];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  Future<List<SuggestionSpan>?> _fetchNow(Locale locale, String text) async {
    if (AppPlatform.isIOS || AppPlatform.isAndroid) {
      return _mobile.fetchSpellCheckSuggestions(locale, text);
    }
    if (!AppPlatform.isMacOS && !AppPlatform.isWindows) return const [];

    try {
      final raw = await _channel.invokeListMethod<Object?>('check', {
        'language': locale.toLanguageTag(),
        'text': text,
      });
      return _decode(raw, text.length);
    } on MissingPluginException {
      // A runner built before the bridge, or a widget test with no runner.
      return const [];
    } on PlatformException {
      // A missing dictionary must never interrupt typing.
      return const [];
    }
  }

  /// Stops the quiet-period work owned by an editor that is leaving.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _requestGeneration++;
    _quietTimer?.cancel();
    _quietTimer = null;
    final pending = _pendingRequest;
    if (pending != null && !pending.isCompleted) pending.complete(null);
    _pendingRequest = null;
    _suggestions.clear();
    _suggestionRequests.clear();
  }

  static List<SuggestionSpan> _decode(List<Object?>? raw, int textLength) {
    if (raw == null) return const [];
    final spans = <SuggestionSpan>[];
    for (final item in raw) {
      if (item is! Map<Object?, Object?>) continue;
      final start = item['startIndex'];
      final end = item['endIndex'];
      final suggestions = item['suggestions'];
      // Absent for a word whose corrections have not been asked for yet;
      // anything else in its place is a runner that cannot be believed.
      if (start is! int ||
          end is! int ||
          start < 0 ||
          end <= start ||
          end > textLength ||
          (suggestions != null && suggestions is! List<Object?>)) {
        continue;
      }
      spans.add(
        SuggestionSpan(
          TextRange(start: start, end: end),
          suggestions is List<Object?>
              ? suggestions.whereType<String>().toList(growable: false)
              : const [],
        ),
      );
    }
    spans.sort((left, right) => left.range.start.compareTo(right.range.start));
    return spans;
  }
}
