import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ui/tasks/task_choice_cards.dart';

/// The `wght` axis [style] draws at.
double _wght(TextStyle style) =>
    style.fontVariations!.firstWhere((v) => v.axis == 'wght').value;

void main() {
  for (final boldText in [true, false]) {
    testWidgets(
      'with Bold Text ${boldText ? 'on, Tasks text is 200 heavier' : 'off, Tasks text keeps its weight'}',
      (tester) async {
        final dispatcher = tester.binding.platformDispatcher;
        dispatcher.accessibilityFeaturesTestValue = FakeAccessibilityFeatures(
          boldText: boldText,
        );
        addTearDown(dispatcher.clearAccessibilityFeaturesTestValue);
        const ink = Color(0xFF000000);
        expect(
          {
            for (final weight in [400.0, 500.0, 520.0])
              weight: _wght(taskText(13, 18, ink, weight)),
          },
          boldText
              ? {400.0: 600.0, 500.0: 700.0, 520.0: 700.0}
              : {400.0: 400.0, 500.0: 500.0, 520.0: 520.0},
        );
      },
    );
  }
}
