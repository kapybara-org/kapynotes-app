import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/linux_wheel.dart';
import 'package:kapy_notes/ui/back_forward.dart';

import 'support/back_forward.dart';

/// The test binding with the wheel the app's Linux binding has.
class _GtkWheelBinding extends AutomatedTestWidgetsFlutterBinding
    with GtkWheelSteps {}

void main() {
  _GtkWheelBinding();

  /// How far one notch of [kind] moves a list as tall as a window [height]
  /// logical pixels tall, at twice the pixels, sent as the Linux engine
  /// sends a notch.
  Future<double> notch(
    WidgetTester tester, {
    required double height,
    PointerDeviceKind kind = PointerDeviceKind.mouse,
    Axis axis = Axis.vertical,
  }) async {
    tester.view.physicalSize = Size(800 * 2, height * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ListView(
          controller: controller,
          scrollDirection: axis,
          children: [
            for (var i = 0; i < 200; i++)
              SizedBox(width: 40, height: 40, child: Text('$i')),
          ],
        ),
      ),
    );
    await tester.sendEventToBinding(
      PointerScrollEvent(
        kind: kind,
        position: const Offset(400, 200),
        scrollDelta: axis == Axis.vertical
            ? const Offset(0, GtkWheelSteps.engineNotch)
            : const Offset(GtkWheelSteps.engineNotch, 0),
      ),
    );
    await tester.pumpAndSettle();
    return controller.offset;
  }

  // Measured in GTK 3 and GTK 4 on Xvfb: one notch over a text view as tall
  // as the window.
  for (final (height, gtk) in [
    (400.0, 54.29),
    (600.0, 71.14),
    (848.0, 89.59),
  ]) {
    testWidgets('a notch moves a ${height.round()} px window as far as GTK '
        'does', (tester) async {
      expect(await notch(tester, height: height), closeTo(gtk, 0.01));
    });
  }

  testWidgets('a sideways notch keeps its step, short of a Back or Forward '
      'step', (tester) async {
    final moved = await notch(tester, height: 848, axis: Axis.horizontal);
    expect(moved, GtkWheelSteps.engineNotch);
    expect(moved, lessThan(BackForwardArea.threshold));

    asDesktop();
    final steps = <BackForwardStep>[];
    await tester.pumpWidget(
      MaterialApp(
        home: BackForwardArea(
          onStep: (step) {
            steps.add(step);
            return true;
          },
          child: const SizedBox.expand(),
        ),
      ),
    );
    for (final dx in [GtkWheelSteps.engineNotch, -GtkWheelSteps.engineNotch]) {
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: const Offset(400, 200),
          scrollDelta: Offset(dx, 0),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(steps, isEmpty);
  });

  testWidgets('a touchpad is left alone', (tester) async {
    expect(
      await notch(tester, height: 848, kind: PointerDeviceKind.trackpad),
      GtkWheelSteps.engineNotch,
    );
  });

  for (final key in [
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.metaLeft,
  ]) {
    testWidgets('the wheel with ${key.keyLabel} held keeps its own steps', (
      tester,
    ) async {
      await tester.sendKeyDownEvent(key);
      addTearDown(() => tester.sendKeyUpEvent(key));
      expect(await notch(tester, height: 848), GtkWheelSteps.engineNotch);
    });
  }
}
