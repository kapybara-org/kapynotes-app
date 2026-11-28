import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/audio/adts.dart';
import 'package:kapy_notes/audio/audio_decode.dart';
import 'package:kapy_notes/audio/mp4_duration.dart';
import 'package:kapy_notes/audio/recording_controls.dart';
import 'package:kapy_notes/audio/voice_recorder.dart';
import 'package:kapy_notes/audio/voice_recording_controller.dart';
import 'package:kapy_notes/core/platform.dart';

/// A backend with no microphone in it.
///
/// Writes real bytes to the real path it is given, because the controller
/// reads the file back to find the duration — a fake that wrote nothing would
/// silently exercise only the fallback path.
class FakeVoiceRecorder implements VoiceRecorderBackend {
  FakeVoiceRecorder({
    this.permitted = true,
    this.microphone = true,
    this.bytes,
    this.writesFile = true,
  });

  bool permitted;

  /// Whether the computer has a microphone at all.
  bool microphone;

  /// Whether `start` puts real bytes on disk. Off for the clock tests, which
  /// run inside `fakeAsync` where real file I/O would never complete.
  bool writesFile;

  /// What `start` leaves on disk. Null means "a real 5-second recording".
  List<int>? bytes;

  /// Holds `start` until completed: a microphone slow to deliver its first
  /// samples, as Linux waits for.
  Completer<void>? startGate;

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
  Future<bool> hasMicrophone() async => microphone;

  @override
  Future<void> start(String path) async {
    startedAt = path;
    if (writesFile) await File(path).writeAsBytes(bytes ?? _fixture());
    await startGate?.future;
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

/// The notification or Live Activity, as a list of what it was asked to show.
class FakeRecordingControls implements RecordingControls {
  final calls = <String>[];
  Duration? elapsed;
  bool live = false;
  String? phrase;
  String? heard;
  Future<bool> Function(RecordingCommand command)? _onCommand;

  @override
  set onCommand(Future<bool> Function(RecordingCommand command)? handler) =>
      _onCommand = handler;

  /// A press on one of its buttons.
  Future<bool> press(RecordingCommand command) async =>
      await _onCommand?.call(command) ?? false;

  @override
  Future<void> prepare() async => calls.add('prepare');

  @override
  Future<void> show({
    required Duration elapsed,
    required bool paused,
    required bool interrupted,
    bool live = false,
    String? phrase,
    String? heard,
  }) async {
    this.elapsed = elapsed;
    this.live = live;
    this.phrase = phrase;
    this.heard = heard;
    calls.add(
      paused
          ? 'show paused'
          : interrupted
          ? 'show interrupted'
          : 'show',
    );
  }

  @override
  Future<void> hide() async => calls.add('hide');
}

/// Controls whose question is answered only when [_answer] completes: a
/// dialog left up, or a platform that never replies.
/// A backend whose look for a microphone fails rather than answering.
class _MicrophoneUnknown extends FakeVoiceRecorder {
  @override
  Future<bool> hasMicrophone() async => throw StateError('no answer');
}

class _UnansweredControls extends FakeRecordingControls {
  _UnansweredControls(this._answer);

  final Future<void> _answer;

  @override
  Future<void> prepare() => _answer;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  group('a silent microphone (KAP-424)', () {
    const silence = -160.0;

    /// One level a tenth of a second, as every backend reports them.
    Future<void> hear(Iterable<double> levels) async {
      for (final level in levels) {
        recorder.amplitudes.add(level);
      }
      await pumpEventQueue();
    }

    test('a recording that never had a sound is not kept', () async {
      var delivered = 0;
      controller.onFinished = (result, noteId) async => delivered++;
      await controller.start(noteId: 'n1');
      final path = recorder.startedAt!;
      await hear(List.filled(50, silence));

      expect(
        await controller.finishRecordingAndFlush(discardSilent: true),
        isTrue,
      );
      expect(delivered, 0);
      expect(await File(path).exists(), isFalse);
      expect(controller.session, isNull);
    });

    test('nor is one whose only noise is a step or two of dither', () async {
      await controller.start(noteId: 'n1');
      final path = recorder.startedAt!;
      // One and two steps of a 16-bit sample.
      await hear([for (var i = 0; i < 50; i++) i.isEven ? -90.3 : -84.3]);

      expect(await controller.stop(discardSilent: true), isNull);
      expect(await File(path).exists(), isFalse);
    });

    test('a quiet room is sound, and is kept', () async {
      var delivered = 0;
      controller.onFinished = (result, noteId) async => delivered++;
      await controller.start(noteId: 'n1');
      // A laptop's microphone in a quiet room, at its quietest.
      await hear([for (var i = 0; i < 50; i++) -74.0 + (i % 5)]);

      expect(
        await controller.finishRecordingAndFlush(discardSilent: true),
        isFalse,
      );
      expect(delivered, 1);
    });

    test('one sound anywhere in it keeps the recording', () async {
      await controller.start(noteId: 'n1');
      await hear([
        ...List.filled(40, silence),
        -30,
        ...List.filled(40, silence),
      ]);

      expect(await controller.stop(discardSilent: true), isNotNull);
    });

    test('levels that never arrive keep the recording', () async {
      // A backend whose levels do not reach us says nothing about the sound,
      // and a real recording is not thrown away on a guess.
      var delivered = 0;
      controller.onFinished = (result, noteId) async => delivered++;
      await controller.start(noteId: 'n1');

      expect(
        await controller.finishRecordingAndFlush(discardSilent: true),
        isFalse,
      );
      expect(delivered, 1);
    });

    test('an ending nobody pressed Stop for keeps even silence', () async {
      // Quitting, the thirty-minute cap, Stop on a phone's notification: no
      // one is there to be told why a recording went missing, so it stays.
      var delivered = 0;
      controller.onFinished = (result, noteId) async => delivered++;
      await controller.start(noteId: 'n1');
      await hear(List.filled(50, silence));

      expect(await controller.finishRecordingAndFlush(), isFalse);
      expect(delivered, 1);
    });

    test('levels heard while paused do not count', () async {
      await controller.start(noteId: 'n1');
      await hear(List.filled(20, silence));
      await controller.pause();
      await hear([-20]);
      await controller.resume();

      expect(await controller.stop(discardSilent: true), isNull);
    });
  });

  test('the bar does not say it is recording until the microphone has '
      'started', () async {
    final gate = recorder.startGate = Completer<void>();
    final started = controller.start(noteId: 'n1');
    await pumpEventQueue();
    expect(controller.session!.starting, isTrue);

    gate.complete();
    expect(await started, isTrue);
    expect(controller.session!.starting, isFalse);
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

  test('a backend that cannot tell whether there is a microphone lets the '
      'recording try', () async {
    final controller = VoiceRecordingController(
      recorder: _MicrophoneUnknown(),
      tempDirectory: temp,
    );
    addTearDown(controller.dispose);
    expect(await controller.hasMicrophone(), isTrue);
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

  test('the sweep removes a stray phone recording no note claims', () async {
    final stray = File('${temp.path}/voice-old.aac')..writeAsBytesSync([1]);
    final claimed = File('${temp.path}/voice-kept.aac')..writeAsBytesSync([1]);
    File('${temp.path}/voice-kept.json').writeAsStringSync('{"noteId":"n1"}');
    for (final file in [stray, claimed]) {
      file.setLastModifiedSync(
        DateTime.now().subtract(const Duration(hours: 2)),
      );
    }

    await VoiceRecordingController.sweepTempFiles(directory: temp);

    expect(await stray.exists(), isFalse);
    expect(await claimed.exists(), isTrue);
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

    test('a tick that comes late loses no time', () {
      // A locked phone can hold timers back. The length is read off the
      // clock, so the second the tick was late for is still counted.
      withClock((async, controller) {
        async.elapse(const Duration(seconds: 2));
        async.elapseBlocking(const Duration(seconds: 5));
        async.elapse(const Duration(seconds: 1));
        expect(controller.session!.elapsed, const Duration(seconds: 8));
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

    test('silence is told once it has lasted silentAfter, and no sooner', () {
      FakeAsync().run((async) {
        final recorder = FakeVoiceRecorder(writesFile: false);
        final controller = VoiceRecordingController(
          recorder: recorder,
          tempDirectory: temp,
        );
        controller.start(noteId: 'n1');
        async.flushMicrotasks();
        void hearSilence(Duration span) {
          for (var i = 0; i < span.inMilliseconds ~/ 100; i++) {
            recorder.amplitudes.add(-160);
            async.elapse(const Duration(milliseconds: 100));
          }
        }

        hearSilence(
          VoiceRecordingController.silentAfter - const Duration(seconds: 1),
        );
        expect(controller.session!.silent, isFalse);
        hearSilence(const Duration(seconds: 1));
        expect(controller.session!.silent, isTrue);

        // Unmuted: the warning goes with the first sound.
        recorder.amplitudes.add(-40);
        async.flushMicrotasks();
        expect(controller.session!.silent, isFalse);
        hearSilence(const Duration(seconds: 5));
        expect(controller.session!.silent, isFalse);
        controller.dispose();
      });
    });

    test('a quiet room is never told it is silent', () {
      FakeAsync().run((async) {
        final recorder = FakeVoiceRecorder(writesFile: false);
        final controller = VoiceRecordingController(
          recorder: recorder,
          tempDirectory: temp,
        );
        controller.start(noteId: 'n1');
        async.flushMicrotasks();
        for (var i = 0; i < 100; i++) {
          recorder.amplitudes.add(-74.0 + (i % 5));
          async.elapse(const Duration(milliseconds: 100));
        }
        expect(controller.session!.silent, isFalse);
        controller.dispose();
      });
    });

    test('no levels at all is not called silence', () {
      withClock((async, controller) {
        async.elapse(const Duration(seconds: 10));
        expect(controller.session!.silent, isFalse);
      });
    });

    test('cancel asks first only once there is something to lose', () {
      withClock((async, controller) {
        expect(controller.shouldConfirmCancel, isFalse);
        async.elapse(VoiceRecordingController.confirmCancelAfter);
        expect(controller.shouldConfirmCancel, isTrue);
      });
    });

    test(
      'the thirty-minute cap stops the recording rather than truncating it',
      () {
        withClock((async, controller) {
          async.elapse(
            VoiceRecordingController.maxDuration - const Duration(seconds: 1),
          );
          expect(controller.session, isNotNull);
          expect(controller.session!.finishing, isFalse);

          async.elapse(const Duration(seconds: 1));
          async.flushMicrotasks();
          // It has begun delivering itself; the file work finishes off-clock.
          expect(controller.session?.finishing ?? true, isTrue);
        }, dispose: false);
      },
    );
  });

  group('away from the app', () {
    late FakeRecordingControls controls;

    setUp(() {
      controller.dispose();
      recorder = FakeVoiceRecorder();
      controls = FakeRecordingControls();
      controller = VoiceRecordingController(
        recorder: recorder,
        tempDirectory: temp,
        controls: controls,
      );
    });

    File markerOf(String audioPath) =>
        File(audioPath.replaceFirst(RegExp(r'\.m4a$'), '.json'));

    test(
      'the phone shows the recording while it runs, and not after',
      () async {
        await controller.start(noteId: 'n1');
        await pumpEventQueue();
        // Shown again once the first recording's question is answered.
        expect(controls.calls, ['show', 'prepare', 'show']);

        await controller.finishRecordingAndFlush();
        expect(controls.calls, ['show', 'prepare', 'show', 'hide']);
      },
    );

    test('a question nobody answers holds nothing up', () async {
      final unanswered = Completer<void>();
      controller.dispose();
      recorder = FakeVoiceRecorder();
      controller = VoiceRecordingController(
        recorder: recorder,
        tempDirectory: temp,
        controls: _UnansweredControls(unanswered.future),
      );

      expect(await controller.start(noteId: 'n1'), isTrue);
      expect(controller.isRecording, isTrue);
      unanswered.complete();
    });

    test('an answer after the recording ended shows nothing', () async {
      final answer = Completer<void>();
      final slow = _UnansweredControls(answer.future);
      controller.dispose();
      recorder = FakeVoiceRecorder();
      controller = VoiceRecordingController(
        recorder: recorder,
        tempDirectory: temp,
        controls: slow,
      );

      await controller.start(noteId: 'n1');
      await controller.finishRecordingAndFlush();
      answer.complete();
      await pumpEventQueue();
      expect(slow.calls, ['show', 'hide']);
    });

    test('it follows a pause, a resume and an interruption', () async {
      await controller.start(noteId: 'n1');
      await pumpEventQueue();
      controls.calls.clear();
      await controller.pause();
      await controller.resume();
      controller.debugInterrupt();
      expect(controls.calls, ['show paused', 'show', 'show interrupted']);
    });

    test('its buttons reach the recording', () async {
      String? deliveredTo;
      controller.onFinished = (result, noteId) async => deliveredTo = noteId;
      await controller.start(noteId: 'n1');

      expect(await controls.press(RecordingCommand.pause), isTrue);
      expect(recorder.pauses, 1);
      expect(controller.session!.paused, isTrue);

      expect(await controls.press(RecordingCommand.resume), isTrue);
      expect(recorder.resumes, 1);
      expect(controller.session!.paused, isFalse);

      expect(await controls.press(RecordingCommand.stop), isTrue);
      expect(controller.session, isNull);
      expect(deliveredTo, 'n1');
    });

    test('a press with nothing recording says so', () async {
      // The iPhone ends a Live Activity that nothing is behind.
      expect(await controls.press(RecordingCommand.stop), isFalse);
      expect(recorder.stopped, isFalse);
    });

    test('a phone that cannot show any of it still records', () async {
      // Notifications refused, or no Live Activities below iOS 16.1.
      const channel = MethodChannel(PlatformRecordingControls.channelName);
      final asked = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        asked.add(call.method);
        throw PlatformException(code: 'denied');
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      controller.dispose();
      recorder = FakeVoiceRecorder();
      controller = VoiceRecordingController(
        recorder: recorder,
        tempDirectory: temp,
        controls: PlatformRecordingControls(),
      );

      expect(await controller.start(noteId: 'n1'), isTrue);
      await pumpEventQueue();
      expect(controller.isRecording, isTrue);
      expect(asked, ['show', 'prepare', 'show']);
    });

    test('a press arrives over the platform channel', () async {
      final controls = PlatformRecordingControls();
      final pressed = <RecordingCommand>[];
      controls.onCommand = (command) async {
        pressed.add(command);
        return true;
      };
      const codec = StandardMethodCodec();
      Future<Object?> send(String method) async {
        final reply = Completer<Object?>();
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              PlatformRecordingControls.channelName,
              codec.encodeMethodCall(MethodCall(method)),
              (data) => reply.complete(codec.decodeEnvelope(data!)),
            );
        return reply.future;
      }

      expect(await send('pause'), isTrue);
      expect(await send('resume'), isTrue);
      expect(await send('stop'), isTrue);
      expect(await send('rewind'), isFalse);
      expect(pressed, [
        RecordingCommand.pause,
        RecordingCommand.resume,
        RecordingCommand.stop,
      ]);
    });

    test('a recording in progress notes its note beside it', () async {
      await controller.start(noteId: 'n1');
      final marker = markerOf(recorder.startedAt!);
      expect(jsonDecode(marker.readAsStringSync()), {'noteId': 'n1'});

      await controller.stop();
      expect(marker.existsSync(), isFalse);
    });

    test('a cancelled recording leaves no note of itself', () async {
      await controller.start(noteId: 'n1');
      final marker = markerOf(recorder.startedAt!);
      await controller.cancel();
      expect(marker.existsSync(), isFalse);
    });

    group('the next launch', () {
      late Map<String, VoiceRecordingResult> delivered;
      late int flushes;

      setUp(() {
        delivered = {};
        flushes = 0;
        controller.onFinished = (result, noteId) async =>
            delivered[noteId] = result;
        controller.onFlush = () async => flushes++;
      });

      File leftBehind(String name, String noteId, List<int> bytes) {
        File(
          '${temp.path}/$name.json',
        ).writeAsStringSync(jsonEncode({'noteId': noteId}));
        return File('${temp.path}/$name.m4a')..writeAsBytesSync(bytes);
      }

      final tone = File('test/fixtures/tone_5s.m4a').readAsBytesSync();

      test('delivers what the last run never finished', () async {
        final audio = leftBehind('voice-1-2', 'n7', tone);

        await controller.recoverInterrupted();

        expect(delivered.keys, ['n7']);
        expect(delivered['n7']!.file.path, audio.path);
        expect(delivered['n7']!.duration.inMilliseconds, closeTo(5000, 200));
        expect(markerOf(audio.path).existsSync(), isFalse);
        expect(flushes, 1);
      });

      test('draws its waveform from the audio', () async {
        // One second of silence, then one at half of full scale.
        final pcm = File('${temp.path}/decoded.pcm');
        final samples = ByteData(32000 * 2);
        for (var i = 16000; i < 32000; i++) {
          samples.setInt16(i * 2, i.isEven ? 16384 : -16384, Endian.little);
        }
        pcm.writeAsBytesSync(samples.buffer.asUint8List());
        const channel = MethodChannel('test/audio_decode');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          channel,
          (call) async => {
            'path': pcm.path,
            'frames': 32000,
            'sampleRate': 16000,
          },
        );
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
        leftBehind('voice-3-4', 'n7', tone);

        await controller.recoverInterrupted(
          decoder: const AudioDecoder(channel: channel),
        );

        final peaks = delivered['n7']!.peaks;
        expect(peaks.first, 0);
        expect(peaks.last, greaterThan(200));
        // The decoded copy is the caller's to throw away.
        expect(pcm.existsSync(), isFalse);
      });

      /// What a phone leaves when the app is killed outright mid-recording:
      /// its marker, and the ADTS written so far, with no `.m4a` yet.
      File killedDuring(String name, String noteId, List<int> adts) {
        File(
          '${temp.path}/$name.json',
        ).writeAsStringSync(jsonEncode({'noteId': noteId}));
        File('${temp.path}/$name.aac').writeAsBytesSync(adts);
        return File('${temp.path}/$name.m4a');
      }

      final toneAdts = File('test/fixtures/tone_5s.aac').readAsBytesSync();

      test('delivers a phone recording the app was killed during', () async {
        // 42 whole frames, and the start of a 43rd the kill cut short.
        final audio = killedDuring(
          'voice-11-12',
          'n7',
          toneAdts.sublist(0, 15000),
        );

        await controller.recoverInterrupted();

        expect(delivered.keys, ['n7']);
        expect(delivered['n7']!.file.path, audio.path);
        expect(delivered['n7']!.duration, const Duration(milliseconds: 2688));
        expect(mp4DurationMs(audio.readAsBytesSync()), 2688);
        expect(File(adtsBeside(audio.path)).existsSync(), isFalse);
        expect(markerOf(audio.path).existsSync(), isFalse);
        expect(flushes, 1);
      });

      test(
        'rewraps it again when the last launch was cut off doing so',
        () async {
          final audio = killedDuring('voice-13-14', 'n7', toneAdts)
            ..writeAsBytesSync(tone.sublist(0, 4096));

          await controller.recoverInterrupted();

          expect(delivered['n7']!.duration, const Duration(milliseconds: 5120));
          expect(File(adtsBeside(audio.path)).existsSync(), isFalse);
        },
      );

      test('lets go of one killed before its first frame', () async {
        final audio = killedDuring('voice-15-16', 'n7', [0xFF, 0xF1, 0x60]);

        await controller.recoverInterrupted();

        expect(delivered, isEmpty);
        expect(flushes, 0);
        expect(File(adtsBeside(audio.path)).existsSync(), isFalse);
        expect(markerOf(audio.path).existsSync(), isFalse);
      });

      test('leaves a file killed before it was closed to the sweep', () async {
        final audio = leftBehind('voice-5-6', 'n7', [1, 2, 3, 4]);

        await controller.recoverInterrupted();

        expect(delivered, isEmpty);
        expect(flushes, 0);
        expect(markerOf(audio.path).existsSync(), isFalse);
        expect(audio.existsSync(), isTrue);
      });

      test('leaves the recording in progress alone', () async {
        await controller.start(noteId: 'n1');

        await controller.recoverInterrupted();

        expect(delivered, isEmpty);
        expect(markerOf(recorder.startedAt!).existsSync(), isTrue);
      });

      test('waits for somewhere to put it', () async {
        controller.onFinished = null;
        final audio = leftBehind('voice-7-8', 'n7', tone);

        await controller.recoverInterrupted();

        expect(markerOf(audio.path).existsSync(), isTrue);
      });

      test('is not swept away first, however old', () async {
        final audio = leftBehind('voice-9-10', 'n7', tone);
        audio.setLastModifiedSync(
          DateTime.now().subtract(const Duration(hours: 3)),
        );

        await VoiceRecordingController.sweepTempFiles(directory: temp);

        expect(audio.existsSync(), isTrue);
      });
    });
  });
}
