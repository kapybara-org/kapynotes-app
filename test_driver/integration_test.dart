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
  Future<String?> simulatorKeys(String keys) async {
    // Simulator's window with this device in it, or from Xcode 27, where
    // Device Hub took Simulator's place, Device Hub's. Each is found by its
    // path in the Xcode in use: Launch Services may know neither by name, as
    // on CI, where DEVELOPER_DIR picks the Xcode.
    final xcode =
        Platform.environment['DEVELOPER_DIR'] ??
        '${(await Process.run('xcode-select', ['-p'])).stdout}'.trim();
    final simulator = '$xcode/Applications/Simulator.app';
    final opened = Directory(simulator).existsSync()
        ? await run('open', [
            '-a',
            simulator,
            '--args',
            '-CurrentDeviceUDID',
            device,
          ])
        : await run('open', ['$xcode/../Applications/DeviceHub.app']) ??
              await run('open', ['devices://device/open?id=$device']);
    return opened ??
        await run('osascript', [
          '-e',
          'delay 3',
          '-e',
          'tell application "System Events" to $keys',
        ]);
  }

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
      'system-log' => _systemLog(device),
      _ => Future.value('a simulator cannot $action'),
    };
  }
  if (action.startsWith('tap:')) return _tapLabel(device, action.substring(4));
  if (action == 'tap-again') return _tapAgain(device);
  return switch (action) {
    'grant' => adbBoth(
      ['pm', 'grant', _app, 'android.permission.RECORD_AUDIO'],
      ['pm', 'grant', _app, 'android.permission.POST_NOTIFICATIONS'],
    ),
    'lock' => _lock(device),
    'wake' => adb(['input', 'keyevent', 'KEYCODE_WAKEUP']),
    'shade' => adb(['cmd', 'statusbar', 'expand-notifications']),
    'collapse' => adb(['cmd', 'statusbar', 'collapse']),
    'unlock' => _unlock(device),
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

/// Runs `adb shell` on [device], and returns its output and how it ended.
Future<ProcessResult> _adbShell(String device, List<String> arguments) =>
    Process.run('adb', ['-s', device, 'shell', ...arguments]);

/// Whether the emulator's lock screen was switched off before a test's
/// `lock` switched it on, as `locksettings get-disabled` said, for `unlock`
/// to put back.
String? _lockScreenWasDisabled;

/// Locks [device]. An emulator starts with its lock screen switched off, so
/// waking it would show the app again and nothing of what a locked phone
/// shows. Its swipe lock screen goes on first.
Future<String?> _lock(String device) async {
  final was = await _adbShell(device, ['locksettings', 'get-disabled']);
  _lockScreenWasDisabled ??= '${was.stdout}'.trim();
  for (final step in [
    ['locksettings', 'set-disabled', 'false'],
    ['input', 'keyevent', 'KEYCODE_SLEEP'],
  ]) {
    final result = await _adbShell(device, step);
    if (result.exitCode != 0) return '${step.join(' ')}: ${result.stderr}';
  }
  return null;
}

/// Wakes [device], swipes its lock screen away, and switches the lock screen
/// back off if `lock` found it off, for the tests that run after.
Future<String?> _unlock(String device) async {
  for (final step in [
    ['input', 'keyevent', 'KEYCODE_WAKEUP'],
    ['wm', 'dismiss-keyguard'],
    if (_lockScreenWasDisabled case 'true' || 'false')
      ['locksettings', 'set-disabled', _lockScreenWasDisabled!],
  ]) {
    final result = await _adbShell(device, step);
    if (result.exitCode != 0) return '${step.join(' ')}: ${result.stderr}';
  }
  _lockScreenWasDisabled = null;
  return null;
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
///
/// The tree goes to a file on the device and is read back from there: with
/// no terminal behind `adb exec-out`, a dump to /dev/tty comes back empty.
/// A screen that is still moving cannot be dumped, so it is tried again.
Future<String?> _tapLabel(String device, String label) async {
  const window = '/sdcard/kapynotes-window.xml';
  final labelled = RegExp(
    'text="${RegExp.escape(label)}"[^>]*bounds="\\[(\\d+),(\\d+)\\]\\[(\\d+),(\\d+)\\]"',
    caseSensitive: false,
  );
  var why = '';
  for (var attempt = 0; attempt < 3; attempt++) {
    if (attempt > 0) await Future<void>.delayed(const Duration(seconds: 1));
    await _adbShell(device, ['rm', '-f', window]);
    final dump = await _adbShell(device, ['uiautomator', 'dump', window]);
    final tree = await _adbShell(device, ['cat', window]);
    final node = labelled.firstMatch('${tree.stdout}');
    if (node == null) {
      why = '${dump.stdout}${dump.stderr}'.trim();
      continue;
    }
    int at(int group) => int.parse(node.group(group)!);
    _lastTap = ['${(at(1) + at(3)) ~/ 2}', '${(at(2) + at(4)) ~/ 2}'];
    return _tapAgain(device);
  }
  return 'nothing on screen says $label: $why';
}

/// Prints the last of what [device], a simulator, logged in the past few
/// minutes about the recording's Live Activity, to read in a run's log:
/// whether ActivityKit started it, and whether the widget extension drew it.
Future<String?> _systemLog(String device) async {
  final log = await Process.run('xcrun', [
    'simctl',
    'spawn',
    device,
    'log',
    'show',
    '--last',
    '4m',
    '--style',
    'compact',
    '--predicate',
    'eventMessage CONTAINS[c] "RecordingAttributes" OR '
        'process == "WriteNoteWidgetExtension"',
  ]);
  final lines = '${log.stdout}'.trim().split('\n');
  stderr.writeln(
    lines.sublist(lines.length > 80 ? lines.length - 80 : 0).join('\n'),
  );
  return log.exitCode == 0 ? null : '${log.stderr}'.trim();
}

/// Where `_tapLabel` last pressed, as `input tap` takes it.
List<String>? _lastTap;

/// Presses where [device] was last pressed: the same button, or whatever
/// has taken its place since.
Future<String?> _tapAgain(String device) async {
  final at = _lastTap;
  if (at == null) return 'nothing has been pressed yet';
  final tap = await _adbShell(device, ['input', 'tap', ...at]);
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
