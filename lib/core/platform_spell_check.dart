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
  Timer? _quietTimer;
  Completer<List<SuggestionSpan>?>? _pendingRequest;
  int _requestGeneration = 0;
  bool _disposed = false;

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
  }

  static List<SuggestionSpan> _decode(List<Object?>? raw, int textLength) {
    if (raw == null) return const [];
    final spans = <SuggestionSpan>[];
    for (final item in raw) {
      if (item is! Map<Object?, Object?>) continue;
      final start = item['startIndex'];
      final end = item['endIndex'];
      final suggestions = item['suggestions'];
      if (start is! int ||
          end is! int ||
          start < 0 ||
          end <= start ||
          end > textLength ||
          suggestions is! List<Object?>) {
        continue;
      }
      spans.add(
        SuggestionSpan(
          TextRange(start: start, end: end),
          suggestions.whereType<String>().toList(growable: false),
        ),
      );
    }
    spans.sort((left, right) => left.range.start.compareTo(right.range.start));
    return spans;
  }
}
