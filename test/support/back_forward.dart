import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/ui/back_forward.dart';

/// The three ways to take a step: two fingers on a trackpad (a pan), a
/// sideways scroll signal (a tilting wheel, or a trackpad on some systems),
/// and the mouse's Back and Forward buttons.
enum StepBy { pan, wheel, button }

int _pointer = 9000;

/// Runs a desktop test as the app runs there: Flutter's platform is the
/// variant's desktop, and so is the app's own.
void asDesktop() {
  AppPlatform.debugTargetPlatformOverride = defaultTargetPlatform;
  addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
}

/// One step at [at], [by] one input: fingers moving right, a scroll whose
/// fingers move right, or Back, to go back, and the other way forward. A
/// swipe goes [reach] times as far as a step needs.
Future<void> stepAt(
  WidgetTester tester,
  Offset at,
  BackForwardStep step,
  StepBy by, {
  double reach = 1.4,
}) async {
  final sign = step == BackForwardStep.back ? 1.0 : -1.0;
  final fingers = BackForwardArea.threshold * reach * sign;
  switch (by) {
    case StepBy.pan:
      final pointer = TestPointer(++_pointer, PointerDeviceKind.trackpad);
      await tester.sendEventToBinding(pointer.panZoomStart(at));
      for (var part = 1; part <= 4; part++) {
        await tester.sendEventToBinding(
          pointer.panZoomUpdate(at, pan: Offset(fingers * part / 4, 0)),
        );
      }
      await tester.sendEventToBinding(pointer.panZoomEnd());
    case StepBy.wheel:
      for (var part = 0; part < 4; part++) {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: at,
            kind: PointerDeviceKind.mouse,
            scrollDelta: Offset(-fingers / 4, 0),
          ),
        );
      }
      // The pause that ends a run of scroll signals.
      await tester.pump(const Duration(milliseconds: 200));
    case StepBy.button:
      await tester.tapAt(
        at,
        buttons: step == BackForwardStep.back
            ? kBackMouseButton
            : kForwardMouseButton,
        kind: PointerDeviceKind.mouse,
      );
  }
  await tester.pumpAndSettle();
}

/// [stepAt] over the middle of [finder].
Future<void> stepOver(
  WidgetTester tester,
  Finder finder,
  BackForwardStep step,
  StepBy by,
) => stepAt(tester, tester.getCenter(finder), step, by);
