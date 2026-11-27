// Remove noise on a phone, from a recording the phone made to a clean copy it
// plays. The same steps run on the Mac and on Windows in
// voice_recording_test.dart.
//
// Run by tool/ci/phone_screenshots.sh, after it grants a simulator's
// microphone; an emulator's is granted here, by the host. Under plain
// `flutter test`, with no host, it skips.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/audio/voice_recording_controller.dart';
import 'package:record/record.dart';

import 'noise_removal_support.dart';
import 'screenshot.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('noise comes off a real recording, and the clean copy plays', (
    tester,
  ) async {
    if (!hostReadsScreens) {
      markTestSkipped('Needs the host in tool/ci/phone_screenshots.sh.');
      return;
    }
    if (Platform.isAndroid) {
      expect(await deviceAction('grant'), isNull, reason: 'the microphone');
    }
    // Checked without asking, so that a phone never granted the microphone
    // fails here rather than waiting on a dialog nobody answers.
    final probe = AudioRecorder();
    final granted = await probe.hasPermission(request: false);
    await probe.dispose();
    expect(granted, isTrue, reason: 'the microphone was never granted');

    final temp = await Directory.systemTemp.createTemp('kapy-remove-noise');
    addTearDown(() => temp.delete(recursive: true));
    final controller = VoiceRecordingController(tempDirectory: temp);
    addTearDown(controller.dispose);

    expect(await controller.start(noteId: 'n1'), isTrue);
    await Future<void>.delayed(const Duration(seconds: 3));
    final result = await controller.stop();
    expect(result, isNotNull, reason: 'nothing came back from the recorder');

    await removeNoiseAndPlay(result!.file, temp);
  });
}
