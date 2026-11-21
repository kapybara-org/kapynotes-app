// Screenshots for a reviewer to look at. Under flutter drive with
// test_driver/integration_test.dart each one is saved as
// build/screenshots/<name>.png; under flutter test it is taken and dropped.
//
// This draws the app's own layer tree to a PNG instead of reading the screen
// through the platform with binding.takeScreenshot. On Android that needs the
// Flutter surface turned into an image view, which Impeller never draws into,
// so the capture waits forever. Drawing the layer tree works the same on
// every platform and uses the app's own renderer. The status bar and the
// keyboard are not Flutter's, so they are not in it.
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:integration_test/integration_test.dart';

/// Takes a screenshot of the app as it is now. [name] is lower-case letters,
/// digits and dashes.
Future<void> screenshot(String name) async {
  final binding = IntegrationTestWidgetsFlutterBinding.instance;
  final view = binding.renderViews.first;
  final layer = view.debugLayer;
  if (layer is! OffsetLayer) return;
  final image = await layer.toImage(view.paintBounds);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  final reportData = binding.reportData ??= <String, dynamic>{};
  ((reportData['screenshots'] ??= <dynamic>[]) as List<dynamic>).add(
    <String, dynamic>{
      'screenshotName': name,
      'bytes': png!.buffer.asUint8List(),
    },
  );
}
