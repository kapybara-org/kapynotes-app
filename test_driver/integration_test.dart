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
          final island = event.extensionData?.data['island'] == true;
          final error = _name.hasMatch(name)
              ? await _readScreen(device, name, island: island)
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

/// For osascript: chooses the menu item named by its first argument in the
/// menus of the app whose bundle identifier is its second, or says which
/// items there are when none is called that.
const _chooseMenuItem = '''
on run {wanted, hubId}
  delay 3
  set AppleScript's text item delimiters to ", "
  tell application "System Events"
    set hub to first application process whose bundle identifier is hubId
    set frontmost of hub to true
    set seen to {}
    repeat with candidate in (entire contents of menu bar 1 of hub)
      if class of candidate is menu item then
        set itemName to name of candidate
        if itemName is wanted then
          if not (enabled of candidate) then error wanted & " is greyed out"
          click candidate
          return
        end if
        if itemName is not missing value then set end of seen to itemName
      end if
    end repeat
    error "no " & wanted & " among " & (seen as text)
  end tell
end run
''';

/// Does what [action] names to [device], for a test that needs the phone
/// itself handled (integration_test/screenshot.dart's `deviceAction`), and
/// returns why it could not, or null.
///
/// A simulator's Lock and Home buttons are pressed with AXe
/// (https://github.com/cameroncooke/AXe) when it is on the PATH, as on CI:
/// from Xcode 27 a simulator takes button presses only through its own HID
/// service, which simctl has no command for, and Device Hub shows a script on
/// CI no menus. Without AXe they are chosen from the menus of Simulator, or of
/// Device Hub, which needs the host's permission to control the computer.
///
/// Nor is a simulator's microphone granted here: an iPhone ends an app whose
/// permissions change while it runs, so tool/ci/phone_screenshots.sh grants
/// it before the app starts. Pressing a notification's button reads the
/// emulator's screen for the button's label, `tap:Pause`, and unfolding a
/// folded notification reads it for the notification's title,
/// `expand:Recording paused`.
Future<String?> _act(String device, String action) async {
  if (action.startsWith('record:')) {
    return _record(device, action.substring(7));
  }
  if (action == 'record-stop') return _stopRecording(device);
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
  Future<String?> simulatorMenu(String item) async {
    // Simulator, with this device in its window, or from Xcode 27, where
    // Device Hub took Simulator's place, Device Hub. Each is found by its
    // path in the Xcode in use: Launch Services may know neither by name, as
    // on CI, where DEVELOPER_DIR picks the Xcode.
    final xcode =
        Platform.environment['DEVELOPER_DIR'] ??
        '${(await Process.run('xcode-select', ['-p'])).stdout}'.trim();
    var host = '$xcode/Applications/Simulator.app';
    final String? opened;
    if (Directory(host).existsSync()) {
      opened = await run('open', [
        '-a',
        host,
        '--args',
        '-CurrentDeviceUDID',
        device,
      ]);
    } else {
      host = '$xcode/../Applications/DeviceHub.app';
      opened =
          await run('open', [host]) ??
          await run('open', ['devices://device/open?id=$device']);
    }
    if (opened != null) return opened;
    final id = await Process.run('defaults', [
      'read',
      '$host/Contents/Info',
      'CFBundleIdentifier',
    ]);
    final chosen = await Process.run('osascript', [
      '-e',
      _chooseMenuItem,
      item,
      '${id.stdout}'.trim(),
    ]);
    return chosen.exitCode == 0 ? null : '$item: ${chosen.stderr}'.trim();
  }

  Future<String?> press(String button) async {
    try {
      return await run('axe', ['button', button, '--udid', device]);
    } on ProcessException {
      return simulatorMenu(button == 'lock' ? 'Lock' : 'Home');
    }
  }

  // A touch at [x], [y] on the simulator's screen, in points, lifted after
  // [hold] seconds. AXe readies the simulator's accessibility for each
  // touch, which ran out of time on the Lock Screen, so a touch gets three
  // tries.
  Future<String?> touch(int x, int y, {double hold = 0.1}) async {
    String? error;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) await Future<void>.delayed(const Duration(seconds: 2));
      try {
        error = await run('axe', [
          'touch',
          '-x',
          '$x',
          '-y',
          '$y',
          '--down',
          '--up',
          '--delay',
          '$hold',
          '--udid',
          device,
        ]);
      } on ProcessException catch (missing) {
        return 'a touch needs AXe: ${missing.message}';
      }
      if (error == null) return null;
    }
    return error;
  }

  // What SpringBoard tells whoever asks about the simulator's screen:
  // `hasBlankedScreen` once it has gone dark, `lockstate` while it is locked.
  Future<bool> springBoard(String state) async {
    final result = await Process.run('xcrun', [
      'simctl',
      'spawn',
      device,
      'notifyutil',
      '-g',
      'com.apple.springboard.$state',
    ]);
    return '${result.stdout}'.trim().endsWith(' 1');
  }

  // Sets the simulator's appearance, and reads it back for the run's log.
  Future<String?> appearance(String wanted) async {
    final error = await simctl(['ui', device, 'appearance', wanted]);
    if (error != null) return error;
    final read = await Process.run('xcrun', [
      'simctl',
      'ui',
      device,
      'appearance',
    ]);
    final now = '${read.stdout}'.trim();
    stderr.writeln('Appearance: $now');
    return now == wanted ? null : 'the appearance is $now, not $wanted';
  }

  // A test's warning for the run's log. On Android a test's own words reach
  // the log behind logcat's prefix, where GitHub doesn't see a warning.
  if (action.startsWith('warn:')) {
    stdout.writeln('::warning::${action.substring(5)}');
    return null;
  }
  if (_isSimulator(device)) {
    return switch (action) {
      'lock' => press('lock'),
      // Lock again lights a screen that locking turned off, as the side
      // button does.
      'wake' => springBoard(
        'hasBlankedScreen',
      ).then((off) => off ? press('lock') : null),
      // An app's first Live Activity asks under its card on the Lock Screen
      // whether to allow the app's Live Activities. Its Allow sits at 290, 710
      // on CI's iPhone 17; should the press open the phone, it is locked and
      // lit again.
      'allow' => touch(290, 710).then(
        (error) async =>
            error ??
            (await springBoard('lockstate')
                ? null
                : await press('lock') ?? await press('lock')),
      ),
      // Held, the Dynamic Island opens to all it shows.
      'hold-island' => touch(201, 32, hold: 1),
      // A first Home lights a dark Lock Screen, and with no passcode either
      // press opens the phone; one more on the Home Screen does nothing.
      'unlock' => press(
        'home',
      ).then((error) async => error ?? await press('home')),
      'other-app' => simctl(['launch', device, 'com.apple.Preferences']),
      'back' => simctl(['launch', device, _app]),
      'light' || 'dark' => appearance(action),
      'system-log' => _systemLog(device),
      _ => Future.value('a simulator cannot $action'),
    };
  }
  if (action.startsWith('tap:')) return _tapLabel(device, action.substring(4));
  if (action.startsWith('expand:')) {
    return _tapLabel(device, action.substring(7), expand: true);
  }
  if (action == 'tap-again') return _tapAgain(device);
  return switch (action) {
    'keyboard-shown' => _keyboardShown(device),
    'grant' => adbBoth(
      ['pm', 'grant', _app, 'android.permission.RECORD_AUDIO'],
      ['pm', 'grant', _app, 'android.permission.POST_NOTIFICATIONS'],
    ),
    'lock' => _lock(device),
    'wake' => adb(['input', 'keyevent', 'KEYCODE_WAKEUP']),
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

/// Null when Android's input method says its keyboard is on [device]'s
/// screen, else what it says instead.
Future<String?> _keyboardShown(String device) async {
  final state = await _adbShell(device, ['dumpsys', 'input_method']);
  final shown = RegExp(
    r'mInputShown=(true|false)',
  ).firstMatch('${state.stdout}')?.group(1);
  return shown == 'true' ? null : 'the input method says mInputShown=$shown';
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
/// the screen's accessibility tree, or with [expand], the arrow on the same
/// line as it, which unfolds a folded notification as a person does.
///
/// The tree goes to a file on the device and is read back from there: with
/// no terminal behind `adb exec-out`, a dump to /dev/tty comes back empty.
/// A screen that is still moving cannot be dumped, so it is tried again, and
/// one that has gone dark is lit first, as a lock screen does after seconds.
Future<String?> _tapLabel(
  String device,
  String label, {
  bool expand = false,
}) async {
  const window = '/sdcard/kapynotes-window.xml';
  final bounds = RegExp(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"');
  List<List<int>> boxes(String tree, String attribute) => [
    for (final node in RegExp('<node [^>]*>').allMatches(tree))
      if (node[0]!.toLowerCase().contains(attribute.toLowerCase()))
        if (bounds.firstMatch(node[0]!) case final box?)
          [for (var i = 1; i <= 4; i++) int.parse(box[i]!)],
  ];
  int middle(List<int> box) => (box[1] + box[3]) ~/ 2;
  String seen(String tree, String attribute) => {
    for (final value in RegExp(' $attribute="([^"]+)"').allMatches(tree))
      value[1],
  }.join(', ');
  var why = '';
  for (var attempt = 0; attempt < 3; attempt++) {
    if (attempt > 0) await Future<void>.delayed(const Duration(seconds: 1));
    await _adbShell(device, ['input', 'keyevent', 'KEYCODE_WAKEUP']);
    await _adbShell(device, ['rm', '-f', window]);
    final dump = await _adbShell(device, ['uiautomator', 'dump', window]);
    final tree = '${(await _adbShell(device, ['cat', window])).stdout}';
    final labelled = boxes(tree, 'text="$label"');
    if (labelled.isEmpty) {
      why =
          'nothing on screen says $label, only ${seen(tree, 'text')}: '
          '${dump.stdout}${dump.stderr}';
      continue;
    }
    final title = labelled.first;
    final arrows = boxes(tree, 'resource-id="android:id/expand_button"');
    if (expand && arrows.isEmpty) {
      why = 'no arrow beside $label, among ${seen(tree, 'resource-id')}';
      continue;
    }
    int away(List<int> box) => (middle(box) - middle(title)).abs();
    final target = expand
        ? arrows.reduce((a, b) => away(a) <= away(b) ? a : b)
        : title;
    _lastTap = ['${(target[0] + target[2]) ~/ 2}', '${middle(target)}'];
    return _tapAgain(device);
  }
  return why.trim();
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
/// has taken its place since, with the screen lit first.
Future<String?> _tapAgain(String device) async {
  final at = _lastTap;
  if (at == null) return 'nothing has been pressed yet';
  await _adbShell(device, ['input', 'keyevent', 'KEYCODE_WAKEUP']);
  final tap = await _adbShell(device, ['input', 'tap', ...at]);
  return tap.exitCode == 0 ? null : '${tap.stderr}'.trim();
}

/// The recording of the device's screen under way, from `record:<name>`
/// until `record-stop`, and the name it is saved under, as
/// `build/screenshots/<name>.mp4`.
({Process process, String name})? _recording;

Future<String?> _record(String device, String name) async {
  if (!_name.hasMatch(name)) return 'not a recording name: $name';
  if (_recording case final going?) return 'already recording ${going.name}';
  await Directory('build/screenshots').create(recursive: true);
  final process = _isSimulator(device)
      ? await Process.start('xcrun', [
          'simctl',
          'io',
          device,
          'recordVideo',
          '--codec=h264',
          '--force',
          'build/screenshots/$name.mp4',
        ])
      : await Process.start('adb', [
          '-s',
          device,
          'shell',
          'screenrecord',
          '--bit-rate',
          '8000000',
          '/sdcard/kapynotes-$name.mp4',
        ]);
  _recording = (process: process, name: name);
  // Both recorders take a moment to begin.
  await Future<void>.delayed(const Duration(seconds: 2));
  return null;
}

Future<String?> _stopRecording(String device) async {
  final recording = _recording;
  if (recording == null) return 'nothing is recording';
  _recording = null;
  final (:process, :name) = recording;
  if (_isSimulator(device)) {
    process.kill(ProcessSignal.sigint);
    final code = await process.exitCode.timeout(const Duration(seconds: 30));
    return code == 0 ? null : 'recordVideo ended with $code';
  }
  final stop = await Process.run('adb', [
    '-s',
    device,
    'shell',
    'pkill',
    '-INT',
    'screenrecord',
  ]);
  if (stop.exitCode != 0) return 'screenrecord: ${stop.stderr}'.trim();
  await process.exitCode.timeout(const Duration(seconds: 30));
  // The file is whole only once screenrecord has written its index.
  await Future<void>.delayed(const Duration(seconds: 1));
  final file = '/sdcard/kapynotes-$name.mp4';
  final pull = await Process.run('adb', [
    '-s',
    device,
    'pull',
    file,
    'build/screenshots/$name.mp4',
  ]);
  await Process.run('adb', ['-s', device, 'shell', 'rm', file]);
  return pull.exitCode == 0 ? null : '${pull.stderr}'.trim();
}

/// Saves what [device]'s screen shows as
/// `build/screenshots/<name>-device.png`, or says why it could not.
///
/// simctl's screenshot of a simulator leaves out the Dynamic Island, so an
/// [island] shot is read with AXe when it is on the PATH, as on CI. AXe takes
/// the screen's sRGB for Display P3, which oversaturates it (#CF7A57 comes
/// out #DD754E), so it reads no other shot.
Future<String?> _readScreen(
  String device,
  String name, {
  bool island = false,
}) async {
  final file = File('build/screenshots/$name-device.png');
  await file.parent.create(recursive: true);
  if (_isSimulator(device)) {
    final simctl = ['simctl', 'io', device, 'screenshot', file.path];
    ProcessResult read;
    try {
      read = island
          ? await Process.run('axe', [
              'screenshot',
              '--udid',
              device,
              '--output',
              file.path,
            ])
          : await Process.run('xcrun', simctl);
    } on ProcessException {
      read = await Process.run('xcrun', simctl);
    }
    return read.exitCode == 0 ? null : '${read.stderr}'.trim();
  }
  final read = await Process.run('adb', [
    '-s',
    device,
    'exec-out',
    'screencap',
    '-p',
  ], stdoutEncoding: null);
  if (read.exitCode != 0) return '${read.stderr}'.trim();
  await file.writeAsBytes(read.stdout as List<int>);
  return null;
}
