// A scratch check of mac.yml, never merged: one screenshot, then a failure.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'screenshot.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a screenshot, then a failure', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: Text('mac.yml probe')),
      ),
    );
    await screenshot('mac-probe');
    expect('screenshot taken', 'a failure');
  });
}
