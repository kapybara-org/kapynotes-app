import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/appearance.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/tasks/task_choice_cards.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  Future<TaskInk> inkUnder(WidgetTester tester, ThemeData theme) async {
    late TaskInk ink;
    await tester.pumpWidget(
      Theme(
        data: theme,
        child: Builder(
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

  double lift(Color line, Color ground) =>
      (Color.alphaBlend(line, ground).computeLuminance() -
              ground.computeLuminance())
          .abs();

  testWidgets('in dark, every theme\'s cards take that theme\'s colours, '
      'with and without Increase contrast', (tester) async {
    for (final theme in AppTheme.values) {
      for (final increaseContrast in [false, true]) {
        final themed = KapyTheme.dark(
          theme: theme,
          increaseContrast: increaseContrast,
        );
        final palette = themed.extension<CalcPalette>()!;
        final ink = await inkUnder(tester, themed);
        final reason = '${theme.name}, increaseContrast: $increaseContrast';
        expect(ink.card, palette.cardBackground, reason: reason);
        expect(ink.raised, palette.selectedBackground, reason: reason);
        expect(ink.rowHover, palette.hover, reason: reason);
        expect(ink.text, palette.textPrimary, reason: reason);
        expect(ink.secondary, palette.textSecondary, reason: reason);
        expect(ink.quiet, palette.textTertiary, reason: reason);
        expect(ink.sage, palette.accentText, reason: reason);
        expect(ink.hairline, palette.separator, reason: reason);
        if (increaseContrast) {
          expect(ink.edge, palette.controlBorder, reason: reason);
          expect(ink.keyEdge, palette.checkboxBorder, reason: reason);
        }
        for (final derived in [
          ink.lifted,
          ink.button,
          ink.chip,
          ink.doneFill,
          ink.edge,
          ink.keyEdge,
        ]) {
          expect(derived, isNot(ink.card), reason: reason);
        }
      }
    }
  });

  testWidgets('in dark, Increase contrast strengthens the cards\' edges', (
    tester,
  ) async {
    for (final theme in AppTheme.values) {
      final plain = await inkUnder(tester, KapyTheme.dark(theme: theme));
      final strong = await inkUnder(
        tester,
        KapyTheme.dark(theme: theme, increaseContrast: true),
      );
      expect(
        lift(strong.edge, strong.card),
        greaterThan(lift(plain.edge, plain.card)),
        reason: theme.name,
      );
      expect(
        lift(strong.keyEdge, strong.card),
        greaterThan(lift(plain.keyEdge, plain.card)),
        reason: theme.name,
      );
    }
  });

  testWidgets('Riverbank dark keeps the colours it was drawn in', (
    tester,
  ) async {
    final palette = KapyTheme.darkPalette;
    final ink = await inkUnder(tester, KapyTheme.dark());
    expect(ink.card, palette.cardBackground);
    expect(ink.raised, palette.selectedBackground);
    expect(ink.lifted, const Color(0xFF1F1F1F));
    expect(ink.rowHover, palette.hover);
    expect(ink.button, const Color(0xFF212121));
    expect(ink.chip, const Color(0xFF232323));
    expect(ink.text, palette.textPrimary);
    expect(ink.secondary, palette.textSecondary);
    expect(ink.quiet, palette.textTertiary);
    expect(ink.sage, palette.accentText);
    expect(ink.doneFill, const Color(0xFF352317));
    expect(ink.edge, const Color(0x14DBDBDB));
    expect(ink.keyEdge, const Color(0x24DBDBDB));
    expect(ink.hairline, palette.separator);
  });

  testWidgets('Midnight dark keeps the colours it was drawn in', (
    tester,
  ) async {
    final ink = await inkUnder(
      tester,
      KapyTheme.dark(theme: AppTheme.midnight),
    );
    expect(ink.card, const Color(0xFF060606));
    expect(ink.raised, const Color(0xFF0C0C0B));
    expect(ink.lifted, const Color(0xFF131313));
    expect(ink.rowHover, const Color(0xFF0C0C0B));
    expect(ink.button, const Color(0xFF151515));
    expect(ink.chip, const Color(0xFF171717));
    expect(ink.text, const Color(0xFFDBDBDB));
    expect(ink.secondary, const Color(0xFF969696));
    expect(ink.quiet, const Color(0xFF878787));
    expect(ink.sage, const Color(0xFFE8772E));
    expect(ink.doneFill, const Color(0xFF2A180C));
    expect(ink.edge, const Color(0x14DBDBDB));
    expect(ink.keyEdge, const Color(0x24DBDBDB));
    expect(ink.hairline, const Color(0xFF181817));
  });
}
