// Remove noise on a phone, from a recording the phone made to a clean copy it
// plays. Run by tool/ci/phone_screenshots.sh; the same steps run on the Mac
// and on Windows in voice_recording_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/audio/voice_recording_controller.dart';

import 'noise_removal_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('noise comes off a real recording, and the clean copy plays', (
    tester,
  ) async {
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
