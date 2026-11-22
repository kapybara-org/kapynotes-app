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
//
// So a reviewer can see the keyboard, a shot taken with `device: true` is
// also read off the simulator's or emulator's own screen by the run's host,
// as build/screenshots/<name>-device.png, when tool/ci/phone_screenshots.sh
// names the device. The test waits until the host has it, so the screen
// holds still meanwhile.
import 'dart:async';
import 'dart:developer' as developer;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:integration_test/integration_test.dart';

/// Takes a screenshot of the app as it is now. [name] is lower-case letters,
/// digits and dashes. With [device], the run's host also saves the device's
/// own screen, keyboard and status bar included, when it reads one.
///
/// Throws in a profile or release build, which keeps no layer tree to draw.
Future<void> screenshot(String name, {bool device = false}) async {
  final binding = IntegrationTestWidgetsFlutterBinding.instance;
  final view = binding.renderViews.first;
  final layer = view.debugLayer;
  if (layer is! OffsetLayer) {
    throw StateError('No layer tree to draw $name from: run a debug build.');
  }
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
  if (!device || !_hostReadsScreens) return;
  final shot = _hostShots[name] = Completer<void>();
  developer.postEvent('kapynotes.deviceShot', {'name': name});
  await shot.future.timeout(
    const Duration(minutes: 1),
    onTimeout: () => throw StateError('The host read no screen for $name.'),
  );
}

const _hostReadsScreens =
    String.fromEnvironment('KAPYNOTES_DEVICE_SHOTS') != '';

/// The device shots the test is waiting on, which the host answers when it
/// has saved one or could not.
final Map<String, Completer<void>> _hostShots = _hearHost();

Map<String, Completer<void>> _hearHost() {
  final waiting = <String, Completer<void>>{};
  developer.registerExtension('ext.kapynotes.deviceShot', (_, params) async {
    final shot = waiting.remove(params['name']);
    final error = params['error'];
    if (error == null) {
      shot?.complete();
    } else {
      shot?.completeError(StateError(error));
    }
    return developer.ServiceExtensionResponse.result('{}');
  });
  return waiting;
}
