import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/appearance.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/tasks/task_choice_cards.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  Future<TaskInk> inkUnder(WidgetTester tester, ThemeData theme) async {
    late TaskInk ink;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Builder(
          builder: (context) {
            ink = TaskInk.of(context);
            return const SizedBox();
          },
        ),
      ),
    );
    return ink;
  }

  testWidgets('in light, the pair cards and Start stand off the pair panel, '
      'and a hovered card off a resting one', (tester) async {
    for (final theme in AppTheme.values) {
      for (final increaseContrast in [false, true]) {
        final ink = await inkUnder(
          tester,
          KapyTheme.light(theme: theme, increaseContrast: increaseContrast),
        );
        final reason = '${theme.name}, increaseContrast: $increaseContrast';
        expect(ink.lifted, isNot(ink.card), reason: reason);
        expect(ink.lifted, isNot(ink.raised), reason: reason);
      }
    }
  });

  testWidgets('dark keeps the boards\' own colours', (tester) async {
    for (final theme in AppTheme.values) {
      final ink = await inkUnder(tester, KapyTheme.dark(theme: theme));
      expect(ink.lifted, const Color(0xFF2F2D29), reason: theme.name);
      expect(ink.card, const Color(0xFF24221E), reason: theme.name);
    }
  });
}
