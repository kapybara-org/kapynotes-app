// Runs one integration test under flutter drive and saves its screenshots:
//
//   flutter drive --driver test_driver/integration_test.dart \
//     --target integration_test/phone_v2_test.dart -d <device> \
//     --dart-define=KAPYNOTES_SYNC=false
//
// Each screenshot the test takes (integration_test/screenshot.dart) lands in
// build/screenshots/<name>.png. With KAPYNOTES_DEVICE_SHOTS naming the iOS
// simulator or Android emulator in the environment, as
// tool/ci/phone_screenshots.sh does, each one taken with `device: true` is
// also read off that device's own screen into
// build/screenshots/<name>-device.png.
import 'dart:async';
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';
import 'package:integration_test/integration_test_driver_extended.dart';

final _name = RegExp(r'^[a-z0-9-]+$');

Future<void> main() async {
  final driver = await FlutterDriver.connect();
  final device = Platform.environment['KAPYNOTES_DEVICE_SHOTS'] ?? '';
  if (device.isNotEmpty) {
    final service = driver.serviceClient;
    service.onExtensionEvent.listen((event) async {
      switch (event.extensionKind) {
        case 'kapynotes.deviceShot':
          final name = '${event.extensionData?.data['name']}';
          final error = _name.hasMatch(name)
              ? await _readScreen(device, name)
              : 'not a screenshot name: $name';
          await service.callServiceExtension(
            'ext.kapynotes.deviceShot',
            isolateId: event.isolate!.id,
            args: {'name': name, 'error': ?error},
          );
        case 'kapynotes.deviceAction':
          final action = '${event.extensionData?.data['action']}';
          final error = await _act(device, action);
          if (error != null) stderr.writeln('Could not $action: $error');
          await service.callServiceExtension(
            'ext.kapynotes.deviceAction',
            isolateId: event.isolate!.id,
            args: {'action': action, 'error': ?error},
          );
      }
    });
    await service.streamListen('Extension');
  }
  await integrationDriver(
    driver: driver,
    responseDataCallback: null,
    onScreenshot: (name, bytes, [args]) async {
      if (!_name.hasMatch(name)) return false;
      final file = File('build/screenshots/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
      return true;
    },
  );
}

/// The app, by its Android package and its iOS bundle identifier alike.
const _app = 'com.kapybara.kapynotes';

/// A simulator goes by its UDID, an emulator by its adb serial.
bool _isSimulator(String device) => RegExp(
  r'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$',
  caseSensitive: false,
).hasMatch(device);

/// Does what [action] names to [device], for a test that needs the phone
/// itself handled (integration_test/screenshot.dart's `deviceAction`), and
/// returns why it could not, or null.
///
/// A simulator has no lock button, so Simulator's own Lock and Home
/// shortcuts are pressed for it, which needs the host's permission to send
/// keystrokes. Nor is its microphone granted here: an iPhone ends an app
/// whose permissions change while it runs, so tool/ci/phone_screenshots.sh
/// grants it before the app starts. Pressing a notification's button reads
/// the emulator's screen for the button's label: `tap:Pause`.
Future<String?> _act(String device, String action) async {
  Future<String?> run(String executable, List<String> arguments) async {
    final result = await Process.run(executable, arguments);
    if (result.exitCode == 0) return null;
    return '$executable ${arguments.join(' ')}: ${result.stderr}'.trim();
  }

  Future<String?> adb(List<String> arguments) =>
      run('adb', ['-s', device, 'shell', ...arguments]);
  Future<String?> adbBoth(List<String> first, List<String> second) async =>
      await adb(first) ?? await adb(second);
  Future<String?> simctl(List<String> arguments) =>
      run('xcrun', ['simctl', ...arguments]);
  Future<String?> simulatorKeys(String keys) async =>
      await run('open', [
        '-a',
        'Simulator',
        '--args',
        '-CurrentDeviceUDID',
        device,
      ]) ??
      await run('osascript', [
        '-e',
        'tell application "Simulator" to activate',
        '-e',
        'delay 1',
        '-e',
        'tell application "System Events" to $keys',
      ]);

  if (_isSimulator(device)) {
    return switch (action) {
      'lock' => simulatorKeys('keystroke "l" using command down'),
      'unlock' => simulatorKeys(
        'keystroke "h" using {command down, shift down}',
      ),
      'other-app' => simctl(['launch', device, 'com.apple.Preferences']),
      'back' => simctl(['launch', device, _app]),
      'light' || 'dark' => simctl(['ui', device, 'appearance', action]),
      'wake' => Future.value(null),
      _ => Future.value('a simulator cannot $action'),
    };
  }
  if (action.startsWith('tap:')) return _tapLabel(device, action.substring(4));
  return switch (action) {
    'grant' => adbBoth(
      ['pm', 'grant', _app, 'android.permission.RECORD_AUDIO'],
      ['pm', 'grant', _app, 'android.permission.POST_NOTIFICATIONS'],
    ),
    'lock' => adb(['input', 'keyevent', 'KEYCODE_SLEEP']),
    'wake' => adb(['input', 'keyevent', 'KEYCODE_WAKEUP']),
    'shade' => adb(['cmd', 'statusbar', 'expand-notifications']),
    'collapse' => adb(['cmd', 'statusbar', 'collapse']),
    'unlock' => adbBoth(
      ['input', 'keyevent', 'KEYCODE_WAKEUP'],
      ['wm', 'dismiss-keyguard'],
    ),
    'other-app' => adb(['am', 'start', '-a', 'android.settings.SETTINGS']),
    'film' => _film(device),
    'cut' => _cut(device),
    'back' => adb(['am', 'start', '-n', '$_app/.MainActivity']),
    'light' || 'dark' => adb([
      'cmd',
      'uimode',
      'night',
      if (action == 'dark') 'yes' else 'no',
    ]),
    _ => Future.value('no such action: $action'),
  };
}

/// The emulator filming its own screen, from a test's `film` to its `cut`.
Future<int>? _filming;

/// Films the next 90 seconds of [device]'s screen, for the Play Console's
/// foreground-service declaration, which asks for a video of what the
/// service is for.
Future<String?> _film(String device) async {
  final film = await Process.start('adb', [
    '-s',
    device,
    'shell',
    'screenrecord',
    '--time-limit',
    '90',
    '/sdcard/recording-away.mp4',
  ]);
  unawaited(film.stdout.drain<void>());
  unawaited(film.stderr.drain<void>());
  _filming = film.exitCode;
  return null;
}

/// Saves the film as `build/screenshots/recording-away.mp4` once it ends.
Future<String?> _cut(String device) async {
  final filming = _filming;
  if (filming == null) return 'nothing was filmed';
  _filming = null;
  await filming;
  final pull = await Process.run('adb', [
    '-s',
    device,
    'pull',
    '/sdcard/recording-away.mp4',
    'build/screenshots/recording-away.mp4',
  ]);
  return pull.exitCode == 0 ? null : '${pull.stderr}'.trim();
}

/// Presses whatever on [device]'s screen is labelled [label], as found in
/// the screen's accessibility tree.
Future<String?> _tapLabel(String device, String label) async {
  final dump = await Process.run('adb', [
    '-s',
    device,
    'exec-out',
    'uiautomator',
    'dump',
    '/dev/tty',
  ]);
  final node = RegExp(
    'text="${RegExp.escape(label)}"[^>]*bounds="\\[(\\d+),(\\d+)\\]\\[(\\d+),(\\d+)\\]"',
    caseSensitive: false,
  ).firstMatch('${dump.stdout}');
  if (node == null) return 'nothing on screen says $label';
  int at(int group) => int.parse(node.group(group)!);
  final tap = await Process.run('adb', [
    '-s',
    device,
    'shell',
    'input',
    'tap',
    '${(at(1) + at(3)) ~/ 2}',
    '${(at(2) + at(4)) ~/ 2}',
  ]);
  return tap.exitCode == 0 ? null : '${tap.stderr}'.trim();
}

/// Saves what [device]'s screen shows as
/// `build/screenshots/<name>-device.png`, or says why it could not.
Future<String?> _readScreen(String device, String name) async {
  final file = File('build/screenshots/$name-device.png');
  await file.parent.create(recursive: true);
  final simulator = _isSimulator(device);
  final read = simulator
      ? await Process.run('xcrun', [
          'simctl',
          'io',
          device,
          'screenshot',
          file.path,
        ])
      : await Process.run('adb', [
          '-s',
          device,
          'exec-out',
          'screencap',
          '-p',
        ], stdoutEncoding: null);
  if (read.exitCode != 0) return '${read.stderr}'.trim();
  if (!simulator) await file.writeAsBytes(read.stdout as List<int>);
  return null;
}
