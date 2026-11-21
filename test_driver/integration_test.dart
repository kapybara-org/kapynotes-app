// Runs one integration test under flutter drive and saves its screenshots:
//
//   flutter drive --driver test_driver/integration_test.dart \
//     --target integration_test/phone_v2_test.dart -d <device> \
//     --dart-define=KAPYNOTES_SYNC=false
//
// Each screenshot the test takes (integration_test/screenshot.dart) lands in
// build/screenshots/<name>.png.
import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() => integrationDriver(
  responseDataCallback: null,
  onScreenshot: (name, bytes, [args]) async {
    if (!RegExp(r'^[a-z0-9-]+$').hasMatch(name)) return false;
    final file = File('build/screenshots/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    return true;
  },
);
