import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// The video player, without a platform: every video is 1:05 of 1280 × 720,
/// and every call is written down so a test can ask what was asked of it.
class FakeVideoPlayer extends VideoPlayerPlatform {
  final List<String> calls = [];
  final Map<int, StreamController<VideoEvent>> _events = {};
  final Map<int, Duration> positions = {};
  int _next = 0;

  static const Duration length = Duration(minutes: 1, seconds: 5);

  int get made => _next;

  @override
  Future<void> init() async {}

  @override
  Future<int?> create(DataSource dataSource) async => _make();

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async => _make();

  int _make() {
    final id = _next++;
    _events[id] = StreamController<VideoEvent>()
      ..add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          duration: length,
          size: const Size(1280, 720),
        ),
      );
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;

  @override
  Future<void> dispose(int playerId) async {
    await _events.remove(playerId)?.close();
  }

  @override
  Future<void> play(int playerId) async => calls.add('play');

  @override
  Future<void> pause(int playerId) async => calls.add('pause');

  @override
  Future<void> setVolume(int playerId, double volume) async =>
      calls.add('volume $volume');

  @override
  Future<void> seekTo(int playerId, Duration position) async =>
      positions[playerId] = position;

  @override
  Future<Duration> getPosition(int playerId) async =>
      positions[playerId] ?? Duration.zero;

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Widget buildView(int playerId) => const ColoredBox(color: Color(0xFF263238));

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      buildView(options.playerId);
}
