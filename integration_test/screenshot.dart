// Screenshots for a reviewer to look at. Under flutter drive with
// test_driver/integration_test.dart each one is saved as
// build/screenshots/<name>.png; under flutter test it is taken and dropped.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

var _surfaceIsImage = false;

/// Takes a screenshot of the app as it is now. [name] is lower-case letters,
/// digits and dashes.
Future<void> screenshot(String name) async {
  final binding = IntegrationTestWidgetsFlutterBinding.instance;
  if (!_surfaceIsImage) {
    // Android reads a screenshot from an image of the Flutter surface, so the
    // surface stays one until the test ends. Elsewhere this does nothing.
    await binding.convertFlutterSurfaceToImage();
    _surfaceIsImage = true;
    addTearDown(() => _surfaceIsImage = false);
  }
  await binding.takeScreenshot(name);
}
