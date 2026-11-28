// Every phone integration test in one app, so Phones' iOS job builds it once
// and tool/ci/phone_screenshots.sh drives each file against that build:
//
//   flutter build ios --simulator --debug --target integration_test/phones.dart \
//     --dart-define=KAPYNOTES_PHONE_TEST_FILE=/tmp/phone-test
//   echo phone_about > /tmp/phone-test
//   flutter drive --driver test_driver/integration_test.dart \
//     --target integration_test/phones.dart -d <simulator> \
//     --use-application-binary build/ios/iphonesimulator/Runner.app
//
// A simulator's app reads the Mac's own files, so the file named at build time
// says which test to run, and the script rewrites it before each drive. The
// simulator doesn't pass SIMCTL_CHILD_ variables through flutter drive to the
// app. Each file still runs in a fresh install of the app, as it does under
// its own build.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'kapy_ai_notice_test.dart' as kapy_ai_notice;
import 'kapy_ai_page_test.dart' as kapy_ai_page;
import 'kapy_ai_sheet_test.dart' as kapy_ai_sheet;
import 'phone_about_test.dart' as phone_about;
import 'phone_bar_android_test.dart' as phone_bar_android;
import 'phone_camera_test.dart' as phone_camera;
import 'phone_format_bar_test.dart' as phone_format_bar;
import 'phone_home_test.dart' as phone_home;
import 'phone_keyboard_test.dart' as phone_keyboard;
import 'phone_note_open_test.dart' as phone_note_open;
import 'phone_note_page_test.dart' as phone_note_page;
import 'phone_note_swipe_test.dart' as phone_note_swipe;
import 'phone_page_turn_test.dart' as phone_page_turn;
import 'phone_recording_away_test.dart' as phone_recording_away;
import 'phone_remove_noise_test.dart' as phone_remove_noise;
import 'phone_sharing_test.dart' as phone_sharing;
import 'phone_tasks_test.dart' as phone_tasks;
import 'phone_time_line_test.dart' as phone_time_line;
import 'phone_v2_test.dart' as phone_v2;
import 'phone_video_test.dart' as phone_video;
import 'phone_voice_chip_test.dart' as phone_voice_chip;
import 'phone_voice_window_test.dart' as phone_voice_window;

const _tests = <String, void Function()>{
  'kapy_ai_notice': kapy_ai_notice.main,
  'kapy_ai_page': kapy_ai_page.main,
  'kapy_ai_sheet': kapy_ai_sheet.main,
  'phone_about': phone_about.main,
  'phone_bar_android': phone_bar_android.main,
  'phone_camera': phone_camera.main,
  'phone_format_bar': phone_format_bar.main,
  'phone_home': phone_home.main,
  'phone_keyboard': phone_keyboard.main,
  'phone_note_open': phone_note_open.main,
  'phone_note_page': phone_note_page.main,
  'phone_note_swipe': phone_note_swipe.main,
  'phone_page_turn': phone_page_turn.main,
  'phone_recording_away': phone_recording_away.main,
  'phone_remove_noise': phone_remove_noise.main,
  'phone_sharing': phone_sharing.main,
  'phone_tasks': phone_tasks.main,
  'phone_time_line': phone_time_line.main,
  'phone_v2': phone_v2.main,
  'phone_video': phone_video.main,
  'phone_voice_chip': phone_voice_chip.main,
  'phone_voice_window': phone_voice_window.main,
};

const _pick = String.fromEnvironment('KAPYNOTES_PHONE_TEST_FILE');

void main() {
  final file = File(_pick);
  final name = _pick.isNotEmpty && file.existsSync()
      ? file.readAsStringSync().trim()
      : null;
  final test = _tests[name];
  if (test != null) return test();
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('integration_test/phones.dart', (_) async {
    fail(
      '${_pick.isEmpty ? 'No KAPYNOTES_PHONE_TEST_FILE' : _pick} names '
      '${name ?? 'no test'}, which is not one of '
      '${_tests.keys.join(', ')}.',
    );
  });
}
