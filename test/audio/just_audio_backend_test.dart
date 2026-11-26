import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/audio/voice_player.dart';

/// [JustAudioBackend.load] against just_audio's own channels, answered the way
/// just_audio_windows 0.2.3 answers them (windows/player.hpp:259-278 and
/// 548-575): `load` replies with an empty map, and the length comes only in
/// the playback events, as 0 until the file has opened (KAP-398). The other
/// platforms reply to `load` with the length.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = MethodChannel('com.ryanheise.just_audio.methods');
  const session = MethodChannel('com.ryanheise.audio_session');

  late Directory temp;
  late File file;
  late JustAudioBackend backend;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('kapy-just-audio');
    file = File('${temp.path}/voice.m4a')..writeAsBytesSync([0]);
    messenger.setMockMethodCallHandler(session, (_) async => null);
    backend = JustAudioBackend();
  });

  tearDown(() async {
    await backend.dispose();
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(session, null);
    await temp.delete(recursive: true);
  });

  /// A player whose `load` replies with [answer], and which reports [length]
  /// [after] the file has opened, if it ever does.
  void player({
    Duration? answer,
    Duration? length,
    Duration after = Duration.zero,
  }) {
    messenger.setMockMethodCallHandler(methods, (call) async {
      if (call.method != 'init') return <String, Object?>{};
      final id = (call.arguments as Map)['id'] as String;
      MockStreamHandlerEventSink? events;
      messenger.setMockStreamHandler(
        EventChannel('com.ryanheise.just_audio.events.$id'),
        MockStreamHandler.inline(onListen: (arguments, sink) => events = sink),
      );
      messenger.setMockStreamHandler(
        EventChannel('com.ryanheise.just_audio.data.$id'),
        MockStreamHandler.inline(onListen: (arguments, sink) {}),
      );
      void report(int state, Duration duration) => events?.success({
        'processingState': state,
        'updatePosition': 0,
        'updateTime': DateTime.now().millisecondsSinceEpoch,
        'bufferedPosition': 0,
        'duration': duration.inMicroseconds,
        'currentIndex': 0,
      });
      messenger.setMockMethodCallHandler(
        MethodChannel('com.ryanheise.just_audio.methods.$id'),
        (call) async {
          if (call.method != 'load') return <String, Object?>{};
          // Opening, then open with no length yet: its position equals its
          // length of 0, which just_audio_windows reports as completed.
          report(1, Duration.zero);
          Timer(Duration.zero, () => report(4, Duration.zero));
          if (length != null) Timer(after, () => report(3, length));
          return {if (answer != null) 'duration': answer.inMicroseconds};
        },
      );
      return null;
    });
  }

  test('a load that answers with the length keeps it', () async {
    player(answer: const Duration(seconds: 3));
    expect(await backend.load(file), const Duration(seconds: 3));
  });

  test(
    'a load that answers with none takes the length the player reports',
    () async {
      player(length: const Duration(milliseconds: 2500));
      expect(await backend.load(file), const Duration(milliseconds: 2500));
    },
  );

  test(
    'the 0 the player reports while the file opens is not its length',
    () async {
      player(
        length: const Duration(milliseconds: 2500),
        after: const Duration(milliseconds: 300),
      );
      expect(await backend.load(file), const Duration(milliseconds: 2500));
    },
  );

  test(
    'a file whose length never comes opens without one, within 2 s',
    () async {
      player();
      final clock = Stopwatch()..start();
      expect(
        await backend.load(file).timeout(const Duration(seconds: 5)),
        isNull,
      );
      expect(clock.elapsed, lessThan(const Duration(milliseconds: 2500)));
    },
  );
}
