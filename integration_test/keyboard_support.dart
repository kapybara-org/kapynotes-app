// Waiting for a phone's keyboard to finish moving before a test measures the
// layout over it (KAP-359). The inset changes every frame while the keyboard
// slides, and Android can call off a keyboard halfway in, when the app hides
// it just after asking for it, so a check made as soon as the inset crosses
// zero can measure a page that is still moving.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screenshot.dart';

/// Pumps frames until the keyboard's inset has held still for half a second,
/// up when [up] is true and down when it is false, and fails after 10 s.
///
/// A keyboard asked for but still down after 4 s is asked for once more,
/// with a warning in the run's log, because the emulator can drop a show that
/// lands just after a hide.
Future<void> settleKeyboard(WidgetTester tester, {required bool up}) async {
  const frame = Duration(milliseconds: 50);
  const still = Duration(milliseconds: 500);
  double inset() => tester.view.viewInsets.bottom;
  final clock = Stopwatch()..start();
  var last = inset();
  var since = Duration.zero;
  var retried = false;
  while (clock.elapsed < const Duration(seconds: 10)) {
    await tester.pump(frame);
    if (inset() != last) {
      last = inset();
      since = clock.elapsed;
    } else if ((last > 0) == up && clock.elapsed - since >= still) {
      await tester.pumpAndSettle();
      return;
    }
    if (up &&
        !retried &&
        last == 0 &&
        clock.elapsed > const Duration(seconds: 4)) {
      retried = true;
      await deviceAction(
        'warn:${tester.testDescription}: the keyboard took a retry, '
        'still down 4 s after it was asked for',
      );
      await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    }
  }
  fail(
    'waited 10 s for the keyboard to settle ${up ? 'up' : 'down'}; '
    'its inset is $last',
  );
}
