import 'dart:async';
import 'dart:io';

import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/audio/voice_recorder.dart';
import 'package:kapy_notes/audio/voice_recording_controller.dart';

/// A backend with no microphone in it.
///
/// Writes real bytes to the real path it is given, because the controller
/// reads the file back to find the duration — a fake that wrote nothing would
/// silently exercise only the fallback path.
class FakeVoiceRecorder implements VoiceRecorderBackend {
  FakeVoiceRecorder({this.permitted = true, this.bytes, this.writesFile = true});

  bool permitted;

  /// Whether `start` puts real bytes on disk. Off for the clock tests, which
  /// run inside `fakeAsync` where real file I/O would never complete.
  bool writesFile;

  /// What `start` leaves on disk. Null means "a real 5-second recording".
  List<int>? bytes;

  String? startedAt;
  bool cancelled = false;
  bool stopped = false;
  bool disposed = false;
  int pauses = 0;
  int resumes = 0;

  final amplitudes = StreamController<double>.broadcast();
  final pausedStates = StreamController<bool>.broadcast();

  @override
  Future<bool> hasPermission() async => permitted;

  @override
  Future<void> start(String path) async {
    startedAt = path;
    if (writesFile) await File(path).writeAsBytes(bytes ?? _fixture());
  }

  static List<int> _fixture() =>
      File('test/fixtures/tone_5s.m4a').readAsBytesSync();

  @override
  Future<void> pause() async => pauses++;

  @override
  Future<void> resume() async => resumes++;

  @override
  Future<String?> stop() async {
    stopped = true;
    return startedAt;
  }

  @override
  Future<void> cancel() async => cancelled = true;

  @override
  Stream<double> get amplitude => amplitudes.stream;

  @override
  Stream<bool> get paused => pausedStates.stream;

  @override
  Future<void> dispose() async {
    disposed = true;
    await amplitudes.close();
    await pausedStates.close();
  }
}

void main() {
  late Directory temp;
  late FakeVoiceRecorder recorder;
  late VoiceRecordingController controller;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('kapy-voice-test');
    recorder = FakeVoiceRecorder();
    controller = VoiceRecordingController(
      recorder: recorder,
      tempDirectory: temp,
    );
  });

  tearDown(() async {
    controller.dispose();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('a refused microphone starts nothing', () async {
    recorder.permitted = false;
    expect(await controller.start(noteId: 'n1'), isFalse);
    expect(controller.session, isNull);
    expect(recorder.startedAt, isNull);
  });

  test('the path ends in .m4a, which is what Windows muxes from', () async {
    await controller.start(noteId: 'n1');
    expect(recorder.startedAt, endsWith('.m4a'));
  });

  test('stop reports the duration from the file, not the timer', () async {
    await controller.start(noteId: 'n1');
    final result = await controller.stop();
    expect(result, isNotNull);
    // The timer never ticked; the header says five seconds.
    expect(result!.duration.inMilliseconds, closeTo(5000, 200));
    expect(result.peaks, hasLength(100));
    expect(controller.session, isNull);
  });

  test('a mis-tap shorter than a second is thrown away', () async {
    recorder.bytes = List.filled(64, 9);
    await controller.start(noteId: 'n1');
    final result = await controller.stop();
    expect(result, isNull);
    expect(await File(recorder.startedAt!).exists(), isFalse);
  });

  test('cancel deletes the file and keeps nothing', () async {
    await controller.start(noteId: 'n1');
    final path = recorder.startedAt!;
    await controller.cancel();
    expect(recorder.cancelled, isTrue);
    expect(controller.session, isNull);
    expect(await File(path).exists(), isFalse);
  });

  test('a pause the user asked for reads as paused', () async {
    await controller.start(noteId: 'n1');
    await controller.pause();
    expect(controller.session!.paused, isTrue);
    expect(controller.session!.interrupted, isFalse);
    expect(recorder.pauses, 1);

    await controller.resume();
    expect(controller.session!.paused, isFalse);
    expect(recorder.resumes, 1);
  });

  test('a pause nobody asked for reads as interrupted', () async {
    // A phone call. The user has to press resume, so it cannot look the same
    // as a pause they chose.
    await controller.start(noteId: 'n1');
    recorder.pausedStates.add(true);
    await pumpEventQueue();
    expect(controller.session!.interrupted, isTrue);
    expect(controller.session!.paused, isFalse);
  });

  test('a backend pause during a user pause is not an interruption', () async {
    await controller.start(noteId: 'n1');
    await controller.pause();
    recorder.pausedStates.add(true);
    await pumpEventQueue();
    expect(controller.session!.interrupted, isFalse);
  });

  test('amplitudes become peaks, and are ignored while paused', () async {
    await controller.start(noteId: 'n1');
    recorder.amplitudes.add(0);
    await pumpEventQueue();
    expect(controller.session!.level, 1);
    expect(controller.session!.sampleSequence, 1);

    await controller.pause();
    recorder.amplitudes.add(0);
    await pumpEventQueue();
    expect(controller.session!.level, 0);
    expect(controller.session!.sampleSequence, 1);
  });

  test('two callers of the finish path share one future', () async {
    // A window close and an app exit can both fire. Running the delivery twice
    // would insert the recording into the note twice.
    var delivered = 0;
    controller.onFinished = (result, noteId) async {
      delivered++;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    };
    await controller.start(noteId: 'n1');
    await Future.wait([
      controller.finishRecordingAndFlush(),
      controller.finishRecordingAndFlush(),
    ]);
    expect(delivered, 1);
  });

  test('finishing with nothing recording resolves at once', () async {
    var delivered = 0;
    controller.onFinished = (result, noteId) async => delivered++;
    await controller.finishRecordingAndFlush();
    expect(delivered, 0);
  });

  test('the recording is delivered to the note it started in', () async {
    String? landedIn;
    controller.onFinished = (result, noteId) async => landedIn = noteId;
    await controller.start(noteId: 'first');
    await controller.finishRecordingAndFlush();
    expect(landedIn, 'first');
  });

  test('the stores are flushed after delivery, not before', () async {
    final order = <String>[];
    controller.onFinished = (result, noteId) async => order.add('deliver');
    controller.onFlush = () async => order.add('flush');
    await controller.start(noteId: 'n1');
    await controller.finishRecordingAndFlush();
    expect(order, ['deliver', 'flush']);
  });

  test('a failing delivery still flushes', () async {
    final order = <String>[];
    controller.onFinished = (result, noteId) async => throw StateError('nope');
    controller.onFlush = () async => order.add('flush');
    await controller.start(noteId: 'n1');
    await controller.finishRecordingAndFlush();
    expect(order, ['flush']);
  });

  test('the sweep removes stray recordings, and only old ones', () async {
    final old = File('${temp.path}/voice-old.m4a')..writeAsBytesSync([1]);
    final fresh = File('${temp.path}/voice-fresh.m4a')..writeAsBytesSync([1]);
    final other = File('${temp.path}/notes-export.zip')..writeAsBytesSync([1]);
    old.setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 2)));

    await VoiceRecordingController.sweepTempFiles(directory: temp);

    expect(await old.exists(), isFalse);
    expect(await fresh.exists(), isTrue);
    expect(await other.exists(), isTrue);
  });

  group('durationFor', () {
    test('the header wins over the timer, even when they disagree', () {
      final bytes = File('test/fixtures/tone_5s.m4a').readAsBytesSync();
      final duration = VoiceRecordingController.durationFor(
        bytes,
        const Duration(minutes: 9),
      );
      expect(duration.inMilliseconds, closeTo(5000, 200));
    });

    test('an unreadable header falls back to the timer', () {
      // A recording with a header we cannot parse is still a recording.
      final duration = VoiceRecordingController.durationFor(
        Uint8List.fromList(List.filled(64, 9)),
        const Duration(seconds: 12),
      );
      expect(duration, const Duration(seconds: 12));
    });
  });

  group('the clock', () {
    /// Runs [body] against a controller whose timers are under our control,
    /// so the thirty-minute cap costs a microsecond instead of half an hour.
    void withClock(
      void Function(FakeAsync async, VoiceRecordingController c) body, {
      bool dispose = true,
    }) {
      FakeAsync().run((async) {
        final recorder = FakeVoiceRecorder(writesFile: false);
        final controller = VoiceRecordingController(
          recorder: recorder,
          tempDirectory: temp,
        );
        controller.start(noteId: 'n1');
        async.flushMicrotasks();
        body(async, controller);
        // A test that left a finish in flight keeps the controller: disposing
        // it here would tear it down inside its own await.
        if (dispose) controller.dispose();
      });
    }

    test('elapsed follows the wall clock', () {
      withClock((async, controller) {
        async.elapse(const Duration(seconds: 3));
        expect(controller.session!.elapsed, const Duration(seconds: 3));
      });
    });

    test('the clock stops while paused and restarts on resume', () {
      withClock((async, controller) {
        async.elapse(const Duration(seconds: 2));
        controller.pause();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 5));
        expect(controller.session!.elapsed, const Duration(seconds: 2));

        controller.resume();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 4));
        expect(controller.session!.elapsed, const Duration(seconds: 6));
      });
    });

    test('the clock stops while interrupted too', () {
      // A phone call must not be counted as recorded time; the file will not
      // contain it either.
      withClock((async, controller) {
        async.elapse(const Duration(seconds: 2));
        controller.debugInterrupt();
        async.elapse(const Duration(seconds: 5));
        expect(controller.session!.elapsed, const Duration(seconds: 2));
      });
    });

    test('cancel asks first only once there is something to lose', () {
      withClock((async, controller) {
        expect(controller.shouldConfirmCancel, isFalse);
        async.elapse(VoiceRecordingController.confirmCancelAfter);
        expect(controller.shouldConfirmCancel, isTrue);
      });
    });

    test('the thirty-minute cap stops the recording rather than truncating it', () {
      withClock((async, controller) {
        async.elapse(VoiceRecordingController.maxDuration - const Duration(seconds: 1));
        expect(controller.session, isNotNull);
        expect(controller.session!.finishing, isFalse);

        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        // It has begun delivering itself; the file work finishes off-clock.
        expect(controller.session?.finishing ?? true, isTrue);
      }, dispose: false);
    });
  });
}
