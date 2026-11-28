import 'dart:async';

import 'package:flutter/services.dart';

import '../core/platform.dart';

/// One phrase of a recording with live translation on: what was heard, and
/// its translation once there is one.
class LivePhrase {
  const LivePhrase({
    required this.id,
    required this.heard,
    this.finished = false,
    this.translation,
  });

  final int id;
  final String heard;

  /// The recogniser has stopped revising [heard].
  final bool finished;
  final String? translation;

  LivePhrase copyWith({String? heard, bool? finished, String? translation}) =>
      LivePhrase(
        id: id,
        heard: heard ?? this.heard,
        finished: finished ?? this.finished,
        translation: translation ?? this.translation,
      );
}

/// What the device can hear and translate into, with each language's name
/// in English and in its own words, as the OS gives them.
class LiveLanguages {
  const LiveLanguages({
    this.spoken = const {},
    this.targets = const {},
    this.names = const {},
  });

  final Set<String> spoken;
  final Set<String> targets;
  final Map<String, ({String english, String own})> names;

  /// The English name, else the code itself.
  String nameOf(String code) => names[code]?.english ?? code;
}

/// Whether a language pair can be translated live on this device now.
enum LivePairStatus { installed, downloadable, unsupported }

/// What turning live translation on came to.
enum LivePrepareResult { ready, denied, declined, unsupported }

/// Why a live session ended early. The recording itself carries on.
enum LiveTranslationStop { denied, interrupted, failed }

/// The device's own speech recogniser and translator, heard while a recording
/// runs. Nothing behind it is created until [start] or [prepare] is called,
/// so a person who never turns live translation on pays nothing for it.
abstract class LiveTranslationEngine {
  /// Whether this OS can do it at all. The Settings row is hidden otherwise.
  Future<bool> isAvailable();

  /// Languages the recogniser can hear, and languages the translator can
  /// translate into, as ISO-639-1 codes.
  Future<LiveLanguages> languages();

  Future<({LivePairStatus status, int? bytes})> pairStatus(
    String from,
    String to,
  );

  /// Asks for permission, then downloads what the pair needs; on Android,
  /// over Wi-Fi only when [wifiOnly].
  Future<LivePrepareResult> prepare(
    String from,
    String to, {
    bool wifiOnly = true,
  });

  /// Opens this app's page in the system's Settings, for a person who said
  /// no to Speech Recognition (iPhone and Mac).
  Future<void> openSettings();

  /// Deletes a language this app downloaded itself (Android only).
  Future<void> remove(String language);

  /// Begins hearing. On Android [path] is where the recording goes, because
  /// there the live session records the file too.
  Future<void> start({required String from, required String to, String? path});

  Future<void> pause();
  Future<void> resume();

  /// Ends hearing; on Android answers the file it wrote.
  Future<String?> stop();

  /// Phrases as they are heard, finished and translated.
  Stream<LivePhrase> get phrases;

  /// Microphone level in dBFS, from the Android live recorder only.
  Stream<double> get levels;

  /// Fires once if the session ends on its own.
  Stream<LiveTranslationStop> get stops;

  /// Each of [texts] translated on the device from [from] into [to], with
  /// no session and no microphone, in order. Null when the device can't:
  /// the pair isn't on it, or there's no translator here at all.
  Future<List<String>?> translate(String from, String to, List<String> texts);

  /// Android only, where the live session records the file: true when the
  /// system took the microphone, false once capture runs again.
  Stream<bool> get interruptions;
}

/// The "kapynotes/live_translation" channels: LiveTranslation.swift on iOS
/// and macOS, LiveTranslation.kt on Android. Every other platform answers
/// unavailable without asking.
class PlatformLiveTranslation implements LiveTranslationEngine {
  PlatformLiveTranslation({
    MethodChannel channel = const MethodChannel(channelName),
    EventChannel events = const EventChannel(eventsName),
  }) : _channel = channel,
       _events = events;

  static const String channelName = 'kapynotes/live_translation';
  static const String eventsName = 'kapynotes/live_translation/phrases';

  static bool get isPossibleHere =>
      AppPlatform.isIOS || AppPlatform.isMacOS || AppPlatform.isAndroid;

  final MethodChannel _channel;
  final EventChannel _events;

  final _phrases = StreamController<LivePhrase>.broadcast();
  final _levels = StreamController<double>.broadcast();
  final _stops = StreamController<LiveTranslationStop>.broadcast();
  final _interruptions = StreamController<bool>.broadcast();
  StreamSubscription<Object?>? _subscription;
  final Map<int, LivePhrase> _open = {};

  @override
  Stream<LivePhrase> get phrases => _phrases.stream;
  @override
  Stream<double> get levels => _levels.stream;
  @override
  Stream<LiveTranslationStop> get stops => _stops.stream;
  @override
  Stream<bool> get interruptions => _interruptions.stream;

  @override
  Future<bool> isAvailable() async {
    if (!isPossibleHere) return false;
    return await _ask<String>('availability') == 'ready';
  }

  @override
  Future<LiveLanguages> languages() async {
    final answer = await _ask<Map<Object?, Object?>>('languages');
    Set<String> codes(Object? raw) => {
      if (raw is List)
        for (final code in raw)
          if (code is String) code.toLowerCase(),
    };
    final names = answer?['names'];
    return LiveLanguages(
      spoken: codes(answer?['spoken']),
      targets: codes(answer?['targets']),
      names: {
        if (names is Map)
          for (final MapEntry(:key, :value) in names.entries)
            if (key is String &&
                value is Map &&
                value['english'] is String &&
                value['own'] is String)
              key.toLowerCase(): (
                english: value['english'] as String,
                own: value['own'] as String,
              ),
      },
    );
  }

  @override
  Future<({LivePairStatus status, int? bytes})> pairStatus(
    String from,
    String to,
  ) async {
    final answer = await _ask<Map<Object?, Object?>>('pairStatus', {
      'from': from,
      'to': to,
    });
    final status = switch (answer?['status']) {
      'installed' => LivePairStatus.installed,
      'downloadable' => LivePairStatus.downloadable,
      _ => LivePairStatus.unsupported,
    };
    final bytes = answer?['bytes'];
    return (status: status, bytes: bytes is int ? bytes : null);
  }

  @override
  Future<LivePrepareResult> prepare(
    String from,
    String to, {
    bool wifiOnly = true,
  }) async => switch (await _ask<String>('prepare', {
    'from': from,
    'to': to,
    'wifiOnly': wifiOnly,
  })) {
    'ready' => LivePrepareResult.ready,
    'denied' => LivePrepareResult.denied,
    'declined' => LivePrepareResult.declined,
    _ => LivePrepareResult.unsupported,
  };

  @override
  Future<void> openSettings() => _ask<void>('openSettings');

  @override
  Future<void> remove(String language) =>
      _ask<void>('remove', {'language': language});

  @override
  Future<void> start({
    required String from,
    required String to,
    String? path,
  }) async {
    _open.clear();
    _subscription ??= _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: (_) => _stops.add(LiveTranslationStop.failed),
    );
    await _channel.invokeMethod<void>('start', {
      'from': from,
      'to': to,
      'path': ?path,
    });
  }

  @override
  Future<List<String>?> translate(
    String from,
    String to,
    List<String> texts,
  ) async {
    final answer = await _ask<List<Object?>>('translate', {
      'from': from,
      'to': to,
      'texts': texts,
    });
    if (answer == null ||
        answer.length != texts.length ||
        answer.any((text) => text is! String)) {
      return null;
    }
    return List<String>.from(answer);
  }

  @override
  Future<void> pause() => _ask<void>('pause');
  @override
  Future<void> resume() => _ask<void>('resume');

  @override
  Future<String?> stop() async {
    final answer = await _ask<Object?>('stop');
    await _subscription?.cancel();
    _subscription = null;
    _open.clear();
    return answer is Map ? answer['path'] as String? : null;
  }

  void _onEvent(Object? event) {
    if (event is! Map) return;
    final level = event['level'];
    if (level is num) return _levels.add(level.toDouble());
    final interrupted = event['interrupted'];
    if (interrupted is bool) return _interruptions.add(interrupted);
    final error = event['error'];
    if (error is String) {
      return _stops.add(switch (error) {
        'denied' => LiveTranslationStop.denied,
        'interrupted' => LiveTranslationStop.interrupted,
        _ => LiveTranslationStop.failed,
      });
    }
    final id = event['id'];
    if (id is! int) return;
    final heard = event['heard'];
    final translation = event['translation'];
    final known = _open[id] ?? LivePhrase(id: id, heard: '');
    final phrase = known.copyWith(
      heard: heard is String ? heard : null,
      finished: event['final'] == true ? true : null,
      translation: translation is String ? translation : null,
    );
    if (phrase.translation != null) {
      _open.remove(id);
    } else {
      _open[id] = phrase;
    }
    _phrases.add(phrase);
  }

  /// A platform without the channel, or one that failed, answers null: every
  /// caller reads null as "not here".
  Future<T?> _ask<T>(String method, [Map<String, Object?>? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
