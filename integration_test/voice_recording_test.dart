// Does the microphone actually work on this platform?
//
// `flutter test` answers everything about voice notes except that, because it
// runs against a fake recorder by design — there is no microphone, no audio
// session, and no platform channel behind it. This runs the real
// `VoiceRecordingController` with the real `record` plugin on a real device or
// simulator, and is the only thing that can catch a missing permission string,
// an entitlement that was never granted, or a platform whose encoder writes a
// container we cannot read back.
//
//   flutter test integration_test/voice_recording_test.dart -d macos
//   flutter test integration_test/voice_recording_test.dart -d <android id>
//   flutter test integration_test/voice_recording_test.dart -d <ios sim id>
//
// Grant the microphone first, or the first case fails and says so:
//   adb shell pm grant com.kapybara.kapynotes android.permission.RECORD_AUDIO
//   xcrun simctl privacy booted grant microphone com.kapybara.kapynotes
//
// Silence is a perfectly good test subject. What is under test is whether a
// recording starts, stops, and comes back as a file whose header we can read —
// not what is on it.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/audio/mp4_duration.dart';
import 'package:kapy_notes/audio/voice_player.dart';
import 'package:kapy_notes/audio/voice_recording_controller.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late VoiceRecordingController controller;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('kapy-voice-integration');
    controller = VoiceRecordingController(tempDirectory: temp);
  });

  tearDown(() async {
    controller.dispose();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  testWidgets('the microphone is available and permitted', (tester) async {
    // The first thing to break on a new platform: a missing usage string on
    // Apple platforms, a missing entitlement on macOS, an ungranted runtime
    // permission on Android. All three surface here as a refusal to start.
    final started = await controller.start(noteId: 'n1');
    expect(
      started,
      isTrue,
      reason: 'the microphone was refused — check the purpose string, the '
          'macOS audio-input entitlement, and that RECORD_AUDIO is granted',
    );
    expect(controller.isRecording, isTrue);
    await controller.cancel();
  });

  testWidgets('a real recording produces a file we can read the length of', (
    tester,
  ) async {
    expect(await controller.start(noteId: 'n1'), isTrue);
    // Long enough to be worth keeping, short enough not to bore anyone.
    await Future<void>.delayed(const Duration(seconds: 3));

    final result = await controller.stop();
    expect(result, isNotNull, reason: 'nothing came back from the recorder');

    final file = result!.file;
    expect(await file.exists(), isTrue);
    final bytes = await file.readAsBytes();
    expect(bytes.length, greaterThan(1024), reason: 'the file is suspiciously empty');

    // The whole reason mp4_duration.dart exists: every platform writes its own
    // container, and this build has to read all of them. A null here means the
    // duration falls back to the elapsed timer on this platform, silently.
    final headerMs = mp4DurationMs(bytes);
    expect(
      headerMs,
      isNotNull,
      reason: 'could not find moov/mvhd in what ${Platform.operatingSystem} '
          'recorded — the chip would fall back to the elapsed timer',
    );
    expect(headerMs, greaterThan(1500));
    expect(headerMs, lessThan(10000));

    expect(result.duration.inMilliseconds, greaterThan(1500));
    expect(result.peaks, hasLength(100));
  });

  testWidgets('the recording plays back', (tester) async {
    expect(await controller.start(noteId: 'n1'), isTrue);
    await Future<void>.delayed(const Duration(seconds: 2));
    final result = await controller.stop();
    expect(result, isNotNull);

    final player = VoicePlayer();
    addTearDown(player.dispose);

    // iOS picks its decoder from the file extension, so a recording stored
    // without one is silent there and nowhere else. The temp file already ends
    // in .m4a; this proves the decoder accepts what the encoder wrote.
    await player.play('hash', result!.file);
    expect(player.activeHash, 'hash');
    expect(
      player.duration,
      isNotNull,
      reason: 'the player could not read a duration from its own recording',
    );
    expect(player.duration!.inMilliseconds, greaterThan(1000));

    await player.pause();
    await player.stop();
  });

  testWidgets('a recording under a second is thrown away, not kept', (
    tester,
  ) async {
    expect(await controller.start(noteId: 'n1'), isTrue);
    final result = await controller.stop();
    expect(result, isNull, reason: 'a mis-tap should leave nothing behind');
  });

  testWidgets('pause and resume work on the real recorder', (tester) async {
    expect(await controller.start(noteId: 'n1'), isTrue);
    await Future<void>.delayed(const Duration(seconds: 1));

    await controller.pause();
    expect(controller.session!.paused, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 500));

    await controller.resume();
    expect(controller.session!.paused, isFalse);
    await Future<void>.delayed(const Duration(seconds: 2));

    final result = await controller.stop();
    expect(result, isNotNull, reason: 'a paused-and-resumed recording was lost');
    expect(mp4DurationMs(await result!.file.readAsBytes()), isNotNull);
  });

  testWidgets('cancelling leaves nothing on disk', (tester) async {
    expect(await controller.start(noteId: 'n1'), isTrue);
    await Future<void>.delayed(const Duration(seconds: 1));
    await controller.cancel();

    final leftovers = await temp
        .list()
        .where((e) => e.path.endsWith('.m4a'))
        .toList();
    expect(leftovers, isEmpty);
  });
}
