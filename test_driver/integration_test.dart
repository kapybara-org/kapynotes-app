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
      if (event.extensionKind != 'kapynotes.deviceShot') return;
      final name = '${event.extensionData?.data['name']}';
      final error = _name.hasMatch(name)
          ? await _readScreen(device, name)
          : 'not a screenshot name: $name';
      await service.callServiceExtension(
        'ext.kapynotes.deviceShot',
        isolateId: event.isolate!.id,
        args: {'name': name, 'error': ?error},
      );
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

/// Saves what [device]'s screen shows as
/// `build/screenshots/<name>-device.png`, or says why it could not.
Future<String?> _readScreen(String device, String name) async {
  final file = File('build/screenshots/$name-device.png');
  await file.parent.create(recursive: true);
  // A simulator goes by its UDID, an emulator by its adb serial.
  final simulator = RegExp(
    r'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$',
    caseSensitive: false,
  ).hasMatch(device);
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
