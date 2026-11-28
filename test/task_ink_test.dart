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
        expect(ink.card, palette.wellBackground, reason: reason);
        expect(ink.card, isNot(palette.cardBackground), reason: reason);
        expect(ink.rowHover, palette.hover, reason: reason);
        expect(ink.text, palette.textPrimary, reason: reason);
        expect(ink.quiet, palette.textTertiary, reason: reason);
        expect(ink.hairline, palette.separator, reason: reason);
        if (increaseContrast) {
          expect(ink.edge, palette.controlBorder, reason: reason);
          expect(ink.keyEdge, palette.checkboxBorder, reason: reason);
        }
        for (final derived in [
          ink.raised,
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

  testWidgets('in light, the phone\'s Done is white on the filled orange, '
      'at 4.5 : 1 or better in every theme', (tester) async {
    double contrast(Color a, Color b) {
      final (hi, lo) = a.computeLuminance() > b.computeLuminance()
          ? (a, b)
          : (b, a);
      return (hi.computeLuminance() + 0.05) / (lo.computeLuminance() + 0.05);
    }

    for (final theme in AppTheme.values) {
      for (final increaseContrast in [false, true]) {
        final themed = KapyTheme.light(
          theme: theme,
          increaseContrast: increaseContrast,
        );
        final palette = themed.extension<CalcPalette>()!;
        final ink = await inkUnder(tester, themed);
        final reason = '${theme.name}, increaseContrast: $increaseContrast';
        expect(ink.doneFill, palette.accentFill, reason: reason);
        expect(ink.doneInk, palette.onAccent, reason: reason);
        expect(
          contrast(ink.doneInk, ink.doneFill),
          greaterThanOrEqualTo(4.5),
          reason: reason,
        );
      }
    }
  });

  testWidgets('every word on a Tasks card or on a lift over it reads at '
      '4.5 : 1 or better, in every theme, light and dark', (tester) async {
    double contrast(Color a, Color b) {
      final (hi, lo) = a.computeLuminance() > b.computeLuminance()
          ? (a, b)
          : (b, a);
      return (hi.computeLuminance() + 0.05) / (lo.computeLuminance() + 0.05);
    }

    for (final dark in [false, true]) {
      for (final theme in AppTheme.values) {
        for (final increaseContrast in [false, true]) {
          final ink = await inkUnder(
            tester,
            dark
                ? KapyTheme.dark(
                    theme: theme,
                    increaseContrast: increaseContrast,
                  )
                : KapyTheme.light(
                    theme: theme,
                    increaseContrast: increaseContrast,
                  ),
          );
          final reason =
              '${theme.name}, dark: $dark, increaseContrast: $increaseContrast';
          for (final words in [ink.text, ink.secondary, ink.quiet, ink.sage]) {
            expect(
              contrast(words, ink.card),
              greaterThanOrEqualTo(4.5),
              reason: reason,
            );
          }
          for (final lift in [ink.raised, ink.lifted, ink.button, ink.chip]) {
            for (final words in [ink.text, ink.secondary, ink.quietOnLift]) {
              expect(
                contrast(words, lift),
                greaterThanOrEqualTo(4.5),
                reason: reason,
              );
            }
          }
          expect(
            contrast(ink.doneInk, ink.doneFill),
            greaterThanOrEqualTo(4.5),
            reason: reason,
          );
        }
      }
    }
  });

  testWidgets('mid-way through a switch between light and dark, the inks '
      'still resolve', (tester) async {
    for (final t in [0.25, 0.5, 0.75]) {
      final ink = await inkUnder(
        tester,
        ThemeData.lerp(KapyTheme.light(), KapyTheme.dark(), t),
      );
      expect(ink.secondary, isNotNull, reason: '$t');
    }
  }, timeout: const Timeout(Duration(seconds: 20)));

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
    expect(ink.card, palette.wellBackground);
    expect(ink.raised, const Color(0xFF303030));
    expect(ink.lifted, const Color(0xFF323232));
    expect(ink.rowHover, palette.hover);
    expect(ink.button, const Color(0xFF343434));
    expect(ink.chip, const Color(0xFF363636));
    expect(ink.text, palette.textPrimary);
    expect(ink.secondary, palette.textSecondary);
    expect(ink.quiet, palette.textTertiary);
    expect(ink.sage, palette.accentText);
    expect(ink.doneFill, const Color(0xFF372D27));
    expect(ink.doneInk, palette.accentText);
    expect(ink.edge, const Color(0x14EDEDED));
    expect(ink.keyEdge, const Color(0x24EDEDED));
    expect(ink.hairline, palette.separator);
  });

  testWidgets('Midnight dark keeps the colours it was drawn in', (
    tester,
  ) async {
    final ink = await inkUnder(
      tester,
      KapyTheme.dark(theme: AppTheme.midnight),
    );
    expect(ink.card, const Color(0xFF191919));
    expect(ink.raised, const Color(0xFF242424));
    expect(ink.lifted, const Color(0xFF262626));
    expect(ink.rowHover, const Color(0xFF191919));
    expect(ink.button, const Color(0xFF282828));
    expect(ink.chip, const Color(0xFF2A2A2A));
    expect(ink.text, const Color(0xFFEDEDED));
    expect(ink.secondary, const Color(0xFFA3A3A3));
    expect(ink.quiet, const Color(0xFF8F8F8F));
    expect(ink.sage, const Color(0xFFE8772E));
    expect(ink.doneFill, const Color(0xFF2C211B));
    expect(ink.edge, const Color(0x14EDEDED));
    expect(ink.keyEdge, const Color(0x24EDEDED));
    expect(ink.hairline, const Color(0xFF212121));
  });
}
