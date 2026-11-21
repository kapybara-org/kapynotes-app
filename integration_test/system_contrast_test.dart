import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/core/system_contrast.dart';

/// The `kapynotes/contrast` channel on a real device. macOS and Android
/// answer it, because Flutter cannot read their switches; everywhere else
/// Flutter's own accessibility features carry the request, and nothing does.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the platform answers where Flutter cannot read the switch', (
    tester,
  ) async {
    final asked = SystemContrast.channel.invokeMethod<bool>('increaseContrast');
    if (Platform.isMacOS || Platform.isAndroid) {
      expect(await asked, isA<bool>());
    } else {
      await expectLater(asked, throwsA(isA<MissingPluginException>()));
    }
  });
}
