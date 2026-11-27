import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/audio/adts.dart';
import 'package:kapy_notes/audio/mp4_duration.dart';
import 'package:kapy_notes/audio/voice_recorder.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:record/record.dart';

/// The `record` plugin's native side, as far as a recording reaches it.
class _FakeRecordPlatform extends RecordPlatform {
  /// What a file recording was asked to write to.
  String? path;

  /// The ADTS frames of a stream recording, for the test to send.
  StreamController<Uint8List>? frames;

  bool stopped = false;

  @override
  Future<void> create(String recorderId) async {}

  @override
  Future<void> start(
    String recorderId,
    RecordConfig config, {
    required String path,
  }) async => this.path = path;

  /// What starting a stream recording throws, if anything.
  Object? streamFailure;

  @override
  Future<Stream<Uint8List>> startStream(
    String recorderId,
    RecordConfig config,
  ) async {
    if (streamFailure case final failure?) throw failure;
    return (frames = StreamController<Uint8List>()).stream;
  }

  @override
  Future<String?> stop(String recorderId) async {
    stopped = true;
    await frames?.close();
    return path;
  }

  @override
  Future<bool> isRecording(String recorderId) async => !stopped;

  @override
  Future<Amplitude> getAmplitude(String recorderId) async =>
      Amplitude(current: -40, max: -40);

  @override
  Stream<RecordState> onStateChanged(String recorderId) => const Stream.empty();

  @override
  Future<void> dispose(String recorderId) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The ADTS frames of the five-second fixture, one at a time, as Android's
/// encoder hands them over.
List<Uint8List> _frames() {
  final adts = File('test/fixtures/tone_5s.aac').readAsBytesSync();
  final frames = <Uint8List>[];
  var at = 0;
  while (at < adts.length) {
    final length =
        ((adts[at + 3] & 3) << 11) | (adts[at + 4] << 3) | (adts[at + 5] >> 5);
    frames.add(adts.sublist(at, at + length));
    at += length;
  }
  return frames;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late _FakeRecordPlatform platform;
  late RecordPlatform original;
  late VoiceRecorder recorder;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('kapy-recorder');
    original = RecordPlatform.instance;
    platform = _FakeRecordPlatform();
    RecordPlatform.instance = platform;
    recorder = VoiceRecorder();
  });

  tearDown(() async {
    await recorder.dispose();
    RecordPlatform.instance = original;
    AppPlatform.debugTargetPlatformOverride = null;
    temp.deleteSync(recursive: true);
  });

  group('on Android', () {
    setUp(
      () => AppPlatform.debugTargetPlatformOverride = TargetPlatform.android,
    );

    test('every frame is on disk as soon as it arrives', () async {
      final path = '${temp.path}/voice-1.m4a';
      await recorder.start(path);
      final frames = _frames();
      for (final frame in frames.take(30)) {
        platform.frames!.add(frame);
      }
      await pumpEventQueue();

      // What a kill now would leave: the 30 frames, and no `.m4a`.
      final adts = File(adtsBeside(path));
      expect(
        adts.lengthSync(),
        frames.take(30).fold(0, (n, f) => n + f.length),
      );
      expect(File(path).existsSync(), isFalse);
      expect(
        mp4DurationMs(mp4FromAdts(adts.readAsBytesSync())!),
        30 * 1024 * 1000 ~/ 16000,
      );
    });

    test('stop leaves the whole recording as an .m4a, and no ADTS', () async {
      final path = '${temp.path}/voice-2.m4a';
      await recorder.start(path);
      _frames().forEach(platform.frames!.add);

      expect(await recorder.stop(), path);

      expect(mp4DurationMs(File(path).readAsBytesSync()), 5120);
      expect(File(adtsBeside(path)).existsSync(), isFalse);
    });

    test('a recording that never got a frame leaves nothing', () async {
      final path = '${temp.path}/voice-3.m4a';
      await recorder.start(path);

      expect(await recorder.stop(), isNull);

      expect(temp.listSync(), isEmpty);
    });

    test('a recording that fails to start leaves nothing', () async {
      platform.streamFailure = Exception('the microphone is busy');

      await expectLater(
        recorder.start('${temp.path}/voice-7.m4a'),
        throwsException,
      );

      expect(temp.listSync(), isEmpty);
    });

    test('cancel leaves nothing', () async {
      final path = '${temp.path}/voice-4.m4a';
      await recorder.start(path);
      _frames().take(10).forEach(platform.frames!.add);
      await pumpEventQueue();

      await recorder.cancel();

      expect(temp.listSync(), isEmpty);
    });
  });

  test('an iPhone records ADTS into a file, and stop rewraps it', () async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    final path = '${temp.path}/voice-5.m4a';

    await recorder.start(path);
    expect(platform.path, adtsBeside(path));
    File(platform.path!).writeAsBytesSync(_frames().expand((f) => f).toList());

    expect(await recorder.stop(), path);

    expect(mp4DurationMs(File(path).readAsBytesSync()), 5120);
    expect(File(adtsBeside(path)).existsSync(), isFalse);
  });

  test('a computer still records straight to the .m4a', () async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.windows;
    final path = '${temp.path}/voice-6.m4a';

    await recorder.start(path);
    expect(platform.path, path);

    expect(await recorder.stop(), path);
  });
}
