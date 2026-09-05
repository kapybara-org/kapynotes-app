import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:kapy_notes/ui/sidebar_swipe.dart';

Widget harness({
  required bool visible,
  required VoidCallback onToggle,
}) => MaterialApp(
  home: SidebarSwipe(
    sidebarVisible: visible,
    onToggle: onToggle,
    child: const SizedBox.expand(child: ColoredBox(color: Color(0xFF000000))),
  ),
);

/// One trackpad swipe, delivered as the pan events a trackpad sends.
Future<void> swipe(WidgetTester tester, Offset total, {int steps = 6}) async {
  final center = tester.getCenter(find.byType(SidebarSwipe));
  final pointer = TestPointer(1, PointerDeviceKind.trackpad);
  await tester.sendEventToBinding(pointer.panZoomStart(center));
  var moved = Offset.zero;
  for (var i = 0; i < steps; i++) {
    moved += total / steps.toDouble();
    await tester.sendEventToBinding(pointer.panZoomUpdate(center, pan: moved));
  }
  await tester.sendEventToBinding(pointer.panZoomEnd());
  await tester.pump();
}

void main() {
  testWidgets('a swipe right opens the notes list', (tester) async {
    var toggles = 0;
    await tester.pumpWidget(harness(visible: false, onToggle: () => toggles++));
    // Natural scrolling reports rightward as negative.
    await swipe(tester, const Offset(-SidebarSwipe.threshold - 20, 0));
    expect(toggles, 1);
  });

  testWidgets('a swipe left closes it again', (tester) async {
    var toggles = 0;
    await tester.pumpWidget(harness(visible: true, onToggle: () => toggles++));
    await swipe(tester, const Offset(SidebarSwipe.threshold + 20, 0));
    expect(toggles, 1);
  });

  testWidgets('swiping the way it already is does nothing', (tester) async {
    var toggles = 0;
    await tester.pumpWidget(harness(visible: true, onToggle: () => toggles++));
    await swipe(tester, const Offset(-SidebarSwipe.threshold - 20, 0));
    expect(toggles, 0, reason: 'already open');
  });

  testWidgets('one long swipe toggles once, not repeatedly', (tester) async {
    var toggles = 0;
    await tester.pumpWidget(harness(visible: false, onToggle: () => toggles++));
    await swipe(tester, const Offset(-SidebarSwipe.threshold * 6, 0), steps: 40);
    expect(toggles, 1);
  });

  testWidgets('scrolling a note up and down leaves it alone', (tester) async {
    var toggles = 0;
    await tester.pumpWidget(harness(visible: false, onToggle: () => toggles++));
    // A vertical scroll with the sideways drift a real thumb produces.
    await swipe(tester, const Offset(-40, -600), steps: 20);
    expect(toggles, 0);
  });
}
