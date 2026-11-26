import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/appearance.dart';
import 'package:kapy_notes/core/system_contrast.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/tag_colours.dart';
import 'package:material_ui/material_ui.dart';

/// The design system (KAP-415; the Captain's
/// handoffs/design-system/tokens.md). Riverbank is the references' neutral
/// ladder with the brand orange as its accent, and the other five themes are
/// that ladder moved a little, each keeping its own tag colours.
void main() {
  final sides = [
    for (final theme in AppTheme.values)
      for (final side in Brightness.values)
        if (theme != AppTheme.midnight || side == Brightness.dark)
          (theme, side),
  ];

  group('the ladder', () {
    test("Riverbank dark takes the references' tokens", () {
      final p = KapyTheme.palette(AppTheme.riverbank, Brightness.dark);
      for (final (colour, want, role) in [
        (p.sidebarBackground, 0xFF0D0D0D, 'window'),
        (p.editorBackground, 0xFF0F0E0E, 'note pane'),
        (p.cardBackground, 0xFF131313, 'card'),
        (p.controlBackground, 0xFF20201F, 'button fill'),
        (p.selectedBackground, 0xFF191918, 'selected row'),
        (p.hover, 0xFF191918, 'hover'),
        (p.pageBorder, 0xFF202020, 'hairline'),
        (p.paneEdge, 0xFF252524, 'pane divider'),
        (p.switchTrackOff, 0xFF2A2A28, 'switch off'),
        (p.checkboxBorder, 0xFF4D4D4D, 'checkbox ring'),
        (p.resultPillBackground, 0xFF1E1E1E, 'grey chip'),
        (p.textPrimary, 0xFFDBDBDB, 'text'),
        (p.textHeading, 0xFFDADADA, 'title'),
        (p.textSecondary, 0xFF969696, 'secondary'),
        (p.textDescription, 0xFF969696, 'description'),
        (p.textTertiary, 0xFF878787, 'tertiary'),
        (p.textDivider, 0xFF494948, 'dots and chevrons'),
        (p.accent, 0xFFE8772E, 'accent'),
        (p.onAccent, 0xFF1A0E06, 'ink on the accent'),
        (p.accentText, 0xFFE8772E, 'orange words'),
        (p.switchThumb, 0xFFFFFFFF, 'the knob stays white'),
      ]) {
        expect(colour, Color(want), reason: role);
      }
      // #7C7C7B reads at 4.45:1 on a card, so it is lifted just past 4.5.
      expect(
        _contrast(p.textQuiet, p.cardBackground),
        greaterThanOrEqualTo(4.5),
      );
      expect(_contrast(p.textQuiet, p.cardBackground), lessThan(5.0));
      expect(
        p.selection,
        const Color(0xFFE8772E).withAlpha(0x4D),
        reason: 'the selection is the accent at 30%',
      );
    });

    test('Riverbank light is the brand orange on neutral greys', () {
      final p = KapyTheme.palette(AppTheme.riverbank, Brightness.light);
      expect(p.editorBackground, const Color(0xFFFFFFFF));
      expect(p.accent, const Color(0xFFD9692A));
      expect(p.onAccent, const Color(0xFF1A0E06));
      expect(p.selection, const Color(0xFFD9692A).withAlpha(0x40));
      for (final (ink, low, high, what) in [
        (p.textPrimary, 12.5, 15.0, 'text'),
        (p.textSecondary, 5.8, 6.8, 'secondary'),
        (p.textTertiary, 5.0, 6.0, 'tertiary'),
      ]) {
        final ratio = _contrast(ink, p.editorBackground);
        expect(ratio, inInclusiveRange(low, high), reason: what);
      }
    });

    for (final (theme, side) in sides) {
      test('${theme.label} ${side.name} is the ladder, with neutral '
          'text and an orange accent', () {
        final p = KapyTheme.palette(theme, side);
        final base = KapyTheme.palette(AppTheme.riverbank, side);
        expect(p.brightness, side);
        expect(p.textPrimary, base.textPrimary);
        expect(p.textHeading, base.textHeading);
        expect(p.onAccent, base.onAccent);
        final hue = HSLColor.fromColor(p.accent).hue;
        expect(hue, inInclusiveRange(15, 30), reason: 'orange, never blue');
        expect(p.totalPillBackground, p.accent);
        expect(p.selectedBorder, p.accent);
        expect(
          _contrast(p.cardBackground, p.sidebarBackground),
          lessThan(1.25),
          reason: 'surfaces sit a step or two apart',
        );
        expect(p.tagDots, hasLength(TagColour.values.length));
      });
    }

    test('the five other themes differ from Riverbank in their surfaces', () {
      for (final theme in AppTheme.values.where(
        (t) => t != AppTheme.riverbank,
      )) {
        final p = KapyTheme.palette(theme, Brightness.dark);
        expect(
          p.editorBackground,
          isNot(KapyTheme.darkPalette.editorBackground),
          reason: theme.label,
        );
      }
      expect(
        KapyTheme.palette(AppTheme.midnight, Brightness.dark).sidebarBackground,
        const Color(0xFF000000),
      );
    });

    test('Midnight by day is Riverbank light', () {
      expect(
        KapyTheme.palette(AppTheme.midnight, Brightness.light),
        same(KapyTheme.lightPalette),
      );
    });

    test('Increase contrast strengthens the words and keeps the grounds', () {
      for (final (theme, side) in sides) {
        final plain = KapyTheme.palette(theme, side);
        final p = plain.withIncreasedContrast();
        expect(p.increasedContrast, isTrue);
        expect(p.tagDots, plain.tagDots);
        expect(p.editorBackground, plain.editorBackground);
        expect(p.cardBackground, plain.cardBackground);
        expect(
          _contrast(p.textQuiet, p.cardBackground),
          greaterThan(_contrast(plain.textQuiet, plain.cardBackground)),
        );
      }
    });
  });

  group('contrast', () {
    for (final (theme, side) in sides) {
      test('${theme.label} ${side.name} reads at AA, and well past it with '
          'Increase contrast on', () {
        final p = KapyTheme.palette(theme, side);
        for (final (ink, ground, what) in [
          (p.textPrimary, p.editorBackground, 'text on the page'),
          (p.textSecondary, p.editorBackground, 'secondary on the page'),
          (p.textSecondary, p.cardBackground, 'secondary on a card'),
          (p.textMuted, p.cardBackground, 'muted on a card'),
          (p.textTertiary, p.editorBackground, 'faint on the page'),
          (p.textTertiary, p.cardBackground, 'faint on a card'),
          (p.accentText, p.editorBackground, 'a link'),
          (p.accentText, p.sidebarBackground, 'a link in the sidebar'),
          (p.textQuiet, p.sidebarBackground, 'quiet words in the sidebar'),
          (p.textQuiet, p.cardBackground, 'quiet words on a card'),
          (p.textSecondary, p.selectedBackground, 'secondary on a row'),
        ]) {
          expect(
            _contrast(ink, ground),
            greaterThanOrEqualTo(4.5),
            reason: what,
          );
        }
        for (final ground in [
          p.sidebarBackground,
          p.editorBackground,
          p.cardBackground,
        ]) {
          expect(_contrast(p.accent, ground), greaterThanOrEqualTo(3));
        }
        expect(_contrast(p.onAccent, p.accent), greaterThanOrEqualTo(4.5));

        final ic = p.withIncreasedContrast();
        // 14:1 as the spec rounds it: Dusk dark is 13.98.
        expect(
          _contrast(ic.textPrimary, ic.editorBackground),
          greaterThanOrEqualTo(13.95),
        );
        for (final (ink, what) in [
          (ic.textSecondary, 'secondary'),
          (ic.textTertiary, 'faint'),
        ]) {
          expect(
            _contrast(ink, ic.cardBackground),
            greaterThanOrEqualTo(7),
            reason: '$what on a card, AAA',
          );
        }
        expect(
          _contrast(ic.controlBorder, ic.editorBackground),
          greaterThan(3.4),
          reason: 'borders the switch raises',
        );
      });

      for (final increase in [false, true]) {
        for (final transparency in [false, true]) {
          test('${theme.label} ${side.name}'
              '${increase ? ' with Increase contrast on' : ''}'
              '${transparency ? ' with transparency on' : ''}: faint text on '
              'a selected row and both keycaps read at AA', () {
            final build = side == Brightness.dark
                ? KapyTheme.dark
                : KapyTheme.light;
            final p = build(
              theme: theme,
              increaseContrast: increase,
              transparency: transparency,
            ).extension<CalcPalette>()!;
            Color over(Color top, Color under) => Color.alphaBlend(top, under);
            final menu = over(p.surfaceBackground, p.editorBackground);
            final row = over(p.selectedBackground, menu);
            final key = over(p.keycapBackground, row);
            final accentKey = over(
              p.tonalKeyBackground,
              over(p.tonalBackground, p.editorBackground),
            );
            for (final (ink, ground, what) in [
              (p.textTertiary, row, 'faint text on a selected row'),
              (p.keycapText, key, 'keycap text on its key'),
              (
                p.tonalKeyText,
                accentKey,
                "the accent keycap's text on its key",
              ),
            ]) {
              expect(
                _contrast(over(ink, ground), ground),
                greaterThanOrEqualTo(4.5),
                reason: what,
              );
            }
          });
        }
      }
    }
  });

  test('rose, the tag the spec leaves out, stands apart from every other tag '
      'in every theme', () {
    for (final (theme, side) in sides) {
      final p = KapyTheme.palette(theme, side);
      expect(p.tagDots, hasLength(TagColour.values.length));
      final rose = TagColour.rose.dot(p);
      for (final other in TagColour.values.where((t) => t != TagColour.rose)) {
        expect(
          _deltaE(rose, other.dot(p)),
          greaterThanOrEqualTo(15),
          reason: '${theme.label} ${side.name}: rose and ${other.name}',
        );
      }
    }
  });

  group('At night', () {
    const night = NightTheme(enabled: true);
    DateTime at(int hour, int minute, {int day = 19}) =>
        DateTime(2026, 11, day, hour, minute);

    test('wears the night theme from 22:00 up to 06:00, whatever the mode', () {
      for (final (time, dark) in [
        (at(21, 59), false),
        (at(22, 0), true),
        (at(5, 59, day: 20), true),
        (at(6, 0, day: 20), false),
      ]) {
        final look = KapyTheme.window(
          mode: AppearanceMode.light,
          theme: AppTheme.graphite,
          night: night,
          wallClock: time,
        );
        expect(
          look.mode,
          dark ? ThemeMode.dark : ThemeMode.light,
          reason: '$time',
        );
        expect(
          look.dark.extension<CalcPalette>()!.editorBackground,
          KapyTheme.palette(
            dark ? AppTheme.lamplight : AppTheme.graphite,
            Brightness.dark,
          ).editorBackground,
          reason: '$time',
        );
        expect(
          look.light.extension<CalcPalette>()!.editorBackground,
          KapyTheme.palette(
            AppTheme.graphite,
            Brightness.light,
          ).editorBackground,
        );
      }
    });

    test('switched off, the mode decides at any hour', () {
      final look = KapyTheme.window(
        mode: AppearanceMode.system,
        theme: AppTheme.riverbank,
        night: const NightTheme(),
        wallClock: at(23, 30),
      );
      expect(look.mode, ThemeMode.system);
    });

    test('Increase contrast sits on top of it', () {
      final look = KapyTheme.window(
        mode: AppearanceMode.dark,
        theme: AppTheme.riverbank,
        night: night,
        wallClock: at(23, 0),
        increaseContrast: true,
      );
      final palette = look.dark.extension<CalcPalette>()!;
      expect(palette.increasedContrast, isTrue);
      expect(
        palette.textPrimary,
        KapyTheme.palette(
          AppTheme.lamplight,
          Brightness.dark,
        ).withIncreasedContrast().textPrimary,
      );
    });

    test('covers hours within a day as well as across midnight', () {
      const daytime = NightTheme(enabled: true, from: 6 * 60, to: 22 * 60);
      expect(daytime.covers(at(12, 0)), isTrue);
      expect(daytime.covers(at(23, 0)), isFalse);
      const never = NightTheme(enabled: true, from: 22 * 60, to: 22 * 60);
      expect(never.covers(at(22, 0)), isFalse);
      expect(never.covers(at(3, 0)), isFalse);
    });

    test('reads back what it saved, and the default for what it cannot', () {
      const chosen = NightTheme(
        enabled: true,
        theme: AppTheme.dusk,
        from: 21 * 60 + 30,
        to: 7 * 60,
      );
      expect(NightTheme.fromJson(chosen.toJson()), chosen);
      expect(
        NightTheme.fromJson({
          'enabled': 'yes',
          'theme': 'contrast',
          'from': 24 * 60,
          'to': -1,
        }),
        const NightTheme(),
      );
      expect(NightTheme.fromJson('nonsense'), const NightTheme());
      expect(NightTheme.clock(22 * 60), '22:00');
      expect(NightTheme.clock(6 * 60 + 5), '06:05');
    });
  });

  group('the system asking for contrast', () {
    testWidgets('is read once and followed as it changes', (tester) async {
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        SystemContrast.channel,
        (call) async => call.method == 'increaseContrast' ? true : null,
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemContrast.channel, null),
      );
      final contrast = SystemContrast();
      addTearDown(contrast.dispose);
      await contrast.start();
      expect(contrast.value, isTrue);

      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        SystemContrast.channel.name,
        SystemContrast.channel.codec.encodeMethodCall(
          const MethodCall('changed', false),
        ),
        (_) {},
      );
      expect(contrast.value, isFalse);
    });

    testWidgets('is nobody asking where no platform answers', (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemContrast.channel,
        (call) async => throw MissingPluginException(),
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemContrast.channel,
          null,
        ),
      );
      final contrast = SystemContrast();
      addTearDown(contrast.dispose);
      await contrast.start();
      expect(contrast.value, isFalse);
    });
  });
}

double _contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

/// CIE76 in L*a*b*, the measure the spec spreads the tags by.
double _deltaE(Color a, Color b) {
  List<double> lab(Color c) {
    double linear(double v) => v <= 0.04045
        ? v / 12.92
        : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    final r = linear(c.r), g = linear(c.g), bl = linear(c.b);
    double f(double t) =>
        t > 0.008856 ? math.pow(t, 1 / 3).toDouble() : 7.787 * t + 16 / 116;
    final x = f((0.4124 * r + 0.3576 * g + 0.1805 * bl) / 0.95047);
    final y = f(0.2126 * r + 0.7152 * g + 0.0722 * bl);
    final z = f((0.0193 * r + 0.1192 * g + 0.9505 * bl) / 1.08883);
    return [116 * y - 16, 500 * (x - y), 200 * (y - z)];
  }

  final p = lab(a), q = lab(b);
  return math.sqrt(
    math.pow(p[0] - q[0], 2) +
        math.pow(p[1] - q[1], 2) +
        math.pow(p[2] - q[2], 2),
  );
}
