import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/appearance.dart';
import 'package:kapy_notes/core/system_contrast.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/tag_colours.dart';
import 'package:material_ui/material_ui.dart';

/// Themes r2 (KAP-144; the Captain's handoffs/KAPY-14/themes-r2.md and Paper
/// p-N-0). The five themes it adds take its tables as they are. Riverbank
/// keeps the values it shipped with, which riverbank_fidelity_test.dart holds
/// it to, so here it only has to read as well as the others.
void main() {
  final roles = <String, Color Function(CalcPalette)>{
    'canvas': (p) => p.sidebarBackground,
    'rail': (p) => p.railBackground,
    'page': (p) => p.editorBackground,
    'raised': (p) => p.controlBackground,
    'card': (p) => p.cardBackground,
    'key': (p) => p.keycapBackground,
    'keyEdge': (p) => p.keycapBorder,
    'border': (p) => p.controlBorder,
    'hair': (p) => p.pageBorder,
    'menuEdge': (p) => p.separator,
    'divider': (p) => p.textDivider,
    'switchOff': (p) => p.switchTrackOff,
    'text': (p) => p.textPrimary,
    'head': (p) => p.textHeading,
    'subhead': (p) => p.textSubheading,
    'cardTitle': (p) => p.cardTitle,
    'muted': (p) => p.textMuted,
    'sec': (p) => p.textSecondary,
    'icon': (p) => p.railInk,
    'faint': (p) => p.textTertiary,
    'dim': (p) => p.lineCommand,
    'dim2': (p) => p.checkboxBorder,
    'dim3': (p) => p.writingHint,
    'box': (p) => p.quoteBar,
    'accent': (p) => p.accent,
    'link': (p) => p.accentText,
    'chipText': (p) => p.chipNumber,
    'tb': (p) => p.tonalBackground,
    'tf': (p) => p.tonalForeground,
    'tkBg': (p) => p.tonalKeyBackground,
    'tkText': (p) => p.tonalKeyText,
    'onAccent': (p) => p.onAccent,
    'clay': (p) => p.clay,
    'codeBg': (p) => p.codeChip,
  };

  final sides = [
    for (final theme in AppTheme.values)
      for (final side in Brightness.values)
        if (theme != AppTheme.midnight || side == Brightness.dark)
          (theme, side),
  ];

  group('the spec tables', () {
    for (final MapEntry(key: (theme, side), value: want) in _spec.entries) {
      test('${theme.label} ${side.name} takes every role', () {
        final palette = KapyTheme.palette(theme, side);
        expect(palette.brightness, side);
        for (final MapEntry(key: role, value: colour) in want.roles.entries) {
          expect(roles[role]!(palette), Color(colour), reason: role);
        }
        expect(palette.tagCards.take(7), [for (final c in want.tags) Color(c)]);
        expect(palette.tagDots.take(7), [for (final c in want.dots) Color(c)]);
      });

      test('${theme.label} ${side.name} with Increase contrast on', () {
        final plain = KapyTheme.palette(theme, side);
        final palette = plain.withIncreasedContrast();
        expect(palette.increasedContrast, isTrue);
        for (final MapEntry(key: role, value: colour)
            in _increased[(theme, side)]!.entries) {
          expect(roles[role]!(palette), Color(colour), reason: role);
        }
        // A tag looks the same, just easier to read; the grounds stay put.
        expect(palette.tagCards, plain.tagCards);
        expect(palette.tagDots, plain.tagDots);
        expect(palette.editorBackground, plain.editorBackground);
        expect(palette.cardBackground, plain.cardBackground);
      });
    }

    test('Midnight by day is Riverbank light', () {
      expect(
        KapyTheme.palette(AppTheme.midnight, Brightness.light),
        same(KapyTheme.lightPalette),
      );
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
        ]) {
          expect(
            _contrast(ink, ground),
            greaterThanOrEqualTo(4.5),
            reason: what,
          );
        }
        expect(
          _contrast(p.accent, p.editorBackground),
          greaterThanOrEqualTo(3),
        );

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
              'a selected row and a keycap read at AA', () {
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
            for (final (ink, ground, what) in [
              (p.textTertiary, row, 'faint text on a selected row'),
              (p.keycapText, key, 'keycap text on its key'),
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
      expect(p.tagCards, hasLength(TagColour.values.length));
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

const _spec =
    <
      (AppTheme, Brightness),
      ({Map<String, int> roles, List<int> tags, List<int> dots})
    >{
      (AppTheme.graphite, Brightness.dark): (
        roles: {
          'canvas': 0xFF151515,
          'rail': 0xFF111111,
          'page': 0xFF1B1B1B,
          'raised': 0xFF252525,
          'card': 0xFF212121,
          'key': 0xFF242424,
          'keyEdge': 0xFF2F2F2F,
          'border': 0xFF2A2A2A,
          'hair': 0xFF272727,
          'menuEdge': 0xFF2E2E2E,
          'divider': 0xFF505050,
          'switchOff': 0xFF333333,
          'text': 0xFFE6E6E6,
          'head': 0xFFDEDEDE,
          'subhead': 0xFFD7D7D7,
          'cardTitle': 0xFFDDDDDD,
          'muted': 0xFFBEBEBE,
          'sec': 0xFFA3A3A3,
          'icon': 0xFF929292,
          'faint': 0xFF979797,
          'dim': 0xFF5A5A5A,
          'dim2': 0xFF555555,
          'dim3': 0xFF434343,
          'box': 0xFF4B4B4B,
          'accent': 0xFFC2C2C2,
          'link': 0xFFB3C2D6,
          'chipText': 0xFFCBD2DC,
          'tb': 0xFF2D2D2D,
          'tf': 0xFFE2E2E2,
          'tkBg': 0xFF4B4B4B,
          'tkText': 0xFFD0D0D0,
          'onAccent': 0xFF151515,
          'clay': 0xFFD58B63,
          'codeBg': 0xFF292929,
        },
        tags: [
          0xFF342F23,
          0xFF352924,
          0xFF2C2E24,
          0xFF232E2E,
          0xFF252F28,
          0xFF282C36,
          0xFF2E2A33,
        ],
        dots: [
          0xFFC2A04E,
          0xFFC77B55,
          0xFF8F9B55,
          0xFF4F9A9B,
          0xFF5FA071,
          0xFF6F8FD0,
          0xFF9C7FB8,
        ],
      ),
      (AppTheme.graphite, Brightness.light): (
        roles: {
          'canvas': 0xFFF2F2F2,
          'rail': 0xFFEBEBEB,
          'page': 0xFFFFFFFF,
          'raised': 0xFFF0F0F0,
          'card': 0xFFF7F7F7,
          'key': 0xFFF6F6F6,
          'keyEdge': 0xFFE9E9E9,
          'border': 0xFFEFEFEF,
          'hair': 0xFFF2F2F2,
          'menuEdge': 0xFFEAEAEA,
          'divider': 0xFFC5C5C5,
          'switchOff': 0xFFE4E4E4,
          'text': 0xFF1E1E1E,
          'head': 0xFF262626,
          'subhead': 0xFF2C2C2C,
          'cardTitle': 0xFF272727,
          'muted': 0xFF434343,
          'sec': 0xFF5C5C5C,
          'icon': 0xFF676767,
          'faint': 0xFF686868,
          'dim': 0xFFADADAD,
          'dim2': 0xFFB5B5B5,
          'dim3': 0xFFCBCBCB,
          'box': 0xFFC0C0C0,
          'accent': 0xFF3A3A3A,
          'link': 0xFF2F5D99,
          'chipText': 0xFF2B4260,
          'tb': 0xFFE8E8E8,
          'tf': 0xFF262626,
          'tkBg': 0xFFC5C5C5,
          'tkText': 0xFF313131,
          'onAccent': 0xFFFFFFFF,
          'clay': 0xFFB5552E,
          'codeBg': 0xFFEFEFEF,
        },
        tags: [
          0xFFEEEADE,
          0xFFF3E6E0,
          0xFFE9EAE0,
          0xFFDFEBEB,
          0xFFE2ECE5,
          0xFFE4E8F2,
          0xFFEBE6F0,
        ],
        dots: [
          0xFF8F7420,
          0xFFB0582F,
          0xFF6A7530,
          0xFF2C7778,
          0xFF3E7F50,
          0xFF4A68A6,
          0xFF7A579B,
        ],
      ),
      (AppTheme.midnight, Brightness.dark): (
        roles: {
          'canvas': 0xFF000000,
          'rail': 0xFF000000,
          'page': 0xFF000000,
          'raised': 0xFF151515,
          'card': 0xFF0F0F0F,
          'key': 0xFF151515,
          'keyEdge': 0xFF2E2E2E,
          'border': 0xFF2A2A2A,
          'hair': 0xFF1F1F1F,
          'menuEdge': 0xFF2E2E2E,
          'divider': 0xFF3C3B39,
          'switchOff': 0xFF1C1B1A,
          'text': 0xFFE6E2DA,
          'head': 0xFFDEDAD2,
          'subhead': 0xFFD8D4CB,
          'cardTitle': 0xFFDDD9D1,
          'muted': 0xFFC1BCB4,
          'sec': 0xFFA8A39A,
          'icon': 0xFF959087,
          'faint': 0xFF9A958C,
          'dim': 0xFF4F4C48,
          'dim2': 0xFF484641,
          'dim3': 0xFF32312E,
          'box': 0xFF3C3A37,
          'accent': 0xFF8BA374,
          'link': 0xFFA6BC8E,
          'chipText': 0xFFB4C99D,
          'tb': 0xFF1B2416,
          'tf': 0xFFC2D6AC,
          'tkBg': 0xFF313D29,
          'tkText': 0xFFA4BA8D,
          'onAccent': 0xFF000000,
          'clay': 0xFFCF7A57,
          'codeBg': 0xFF10100F,
        },
        tags: [
          0xFF28210E,
          0xFF271710,
          0xFF1D1F11,
          0xFF101F1F,
          0xFF132017,
          0xFF161B26,
          0xFF1F1824,
        ],
        dots: [
          0xFFC9A447,
          0xFFC4734F,
          0xFF8F9B55,
          0xFF4F9A9B,
          0xFF5FA071,
          0xFF6D88BE,
          0xFF9C77B4,
        ],
      ),
      (AppTheme.dusk, Brightness.dark): (
        roles: {
          'canvas': 0xFF15151F,
          'rail': 0xFF111119,
          'page': 0xFF1A1A26,
          'raised': 0xFF232330,
          'card': 0xFF20202C,
          'key': 0xFF21212D,
          'keyEdge': 0xFF2B2B37,
          'border': 0xFF262633,
          'hair': 0xFF242430,
          'menuEdge': 0xFF2A2A36,
          'divider': 0xFF464653,
          'switchOff': 0xFF2E2E3B,
          'text': 0xFFC4C2D2,
          'head': 0xFFBFBDCE,
          'subhead': 0xFFBBB9CA,
          'cardTitle': 0xFFBEBCCD,
          'muted': 0xFFACAABC,
          'sec': 0xFF9C9AAE,
          'icon': 0xFF8F8DA2,
          'faint': 0xFF9391A6,
          'dim': 0xFF595869,
          'dim2': 0xFF535263,
          'dim3': 0xFF424150,
          'box': 0xFF4A4959,
          'accent': 0xFF9B92C9,
          'link': 0xFFB2AADA,
          'chipText': 0xFFBEB7E2,
          'tb': 0xFF2A2840,
          'tf': 0xFFC9C3EA,
          'tkBg': 0xFF413D5B,
          'tkText': 0xFFB0A8D8,
          'onAccent': 0xFF15151F,
          'clay': 0xFFC08A78,
          'codeBg': 0xFF262632,
        },
        tags: [
          0xFF322F30,
          0xFF332A31,
          0xFF2C2D31,
          0xFF262E39,
          0xFF292F35,
          0xFF2A2C3D,
          0xFF2F2B3D,
        ],
        dots: [
          0xFFBBA468,
          0xFFBE8670,
          0xFF949A6E,
          0xFF6D9FA3,
          0xFF7FA488,
          0xFF8494C2,
          0xFFA88BBE,
        ],
      ),
      (AppTheme.dusk, Brightness.light): (
        roles: {
          'canvas': 0xFFECEBF2,
          'rail': 0xFFE5E4EC,
          'page': 0xFFF4F3F8,
          'raised': 0xFFE8E7EF,
          'card': 0xFFEFEEF4,
          'key': 0xFFECEBF1,
          'keyEdge': 0xFFE2E1E7,
          'border': 0xFFE6E5EB,
          'hair': 0xFFE9E8EE,
          'menuEdge': 0xFFE3E2E8,
          'divider': 0xFFC4C3CB,
          'switchOff': 0xFFDEDDE3,
          'text': 0xFF3B3A4A,
          'head': 0xFF3F3E4E,
          'subhead': 0xFF424051,
          'cardTitle': 0xFF3F3E4E,
          'muted': 0xFF4C4B5B,
          'sec': 0xFF585667,
          'icon': 0xFF605E70,
          'faint': 0xFF626072,
          'dim': 0xFFA4A2AE,
          'dim2': 0xFFABAAB5,
          'dim3': 0xFFC1C0C9,
          'box': 0xFFB7B5C0,
          'accent': 0xFF5E569A,
          'link': 0xFF5E569A,
          'chipText': 0xFF4F4789,
          'tb': 0xFFE2DFF0,
          'tf': 0xFF3F3878,
          'tkBg': 0xFFC8C4DF,
          'tkText': 0xFF50498B,
          'onAccent': 0xFFF4F3F8,
          'clay': 0xFFA65A3A,
          'codeBg': 0xFFE7E6EC,
        },
        tags: [
          0xFFE4DFD8,
          0xFFE8DCDC,
          0xFFDFDFDB,
          0xFFD6DFE4,
          0xFFD9E1DF,
          0xFFD9DDEC,
          0xFFE1DCE9,
        ],
        dots: [
          0xFF866F25,
          0xFFA55A3A,
          0xFF666F35,
          0xFF2E6F70,
          0xFF3F7A50,
          0xFF3F5FA7,
          0xFF755C93,
        ],
      ),
      (AppTheme.lamplight, Brightness.dark): (
        roles: {
          'canvas': 0xFF1A130C,
          'rail': 0xFF150F09,
          'page': 0xFF20180F,
          'raised': 0xFF2A2016,
          'card': 0xFF261D13,
          'key': 0xFF292015,
          'keyEdge': 0xFF342A1D,
          'border': 0xFF2F2519,
          'hair': 0xFF2C2217,
          'menuEdge': 0xFF33291C,
          'divider': 0xFF554734,
          'switchOff': 0xFF382D20,
          'text': 0xFFEBCB9E,
          'head': 0xFFE6C69A,
          'subhead': 0xFFE2C296,
          'cardTitle': 0xFFE6C699,
          'muted': 0xFFD4B488,
          'sec': 0xFFC4A47A,
          'icon': 0xFFAF916A,
          'faint': 0xFFAC8E68,
          'dim': 0xFF6C583F,
          'dim2': 0xFF65523B,
          'dim3': 0xFF50412D,
          'box': 0xFF5A4934,
          'accent': 0xFFC89550,
          'link': 0xFFDDB173,
          'chipText': 0xFFE4BD82,
          'tb': 0xFF3A2A16,
          'tf': 0xFFEBC891,
          'tkBg': 0xFF563F22,
          'tkText': 0xFFD8AC6D,
          'onAccent': 0xFF1A130C,
          'clay': 0xFFD9804F,
          'codeBg': 0xFF2E2519,
        },
        tags: [
          0xFF3D3018,
          0xFF3C2618,
          0xFF292717,
          0xFF3A3024,
          0xFF312F1B,
          0xFF32261A,
          0xFF3B2821,
        ],
        dots: [
          0xFFE2B94E,
          0xFFD9784A,
          0xFF5F7A45,
          0xFFCDB89A,
          0xFF93AE5C,
          0xFF9A7458,
          0xFFD2808A,
        ],
      ),
      (AppTheme.lamplight, Brightness.light): (
        roles: {
          'canvas': 0xFFEFE4CF,
          'rail': 0xFFE8DCC4,
          'page': 0xFFF7EEDC,
          'raised': 0xFFECE0C8,
          'card': 0xFFF2E7D2,
          'key': 0xFFEFE6D4,
          'keyEdge': 0xFFE4DAC9,
          'border': 0xFFE9E0CE,
          'hair': 0xFFECE3D1,
          'menuEdge': 0xFFE5DCCA,
          'divider': 0xFFC6BBAA,
          'switchOff': 0xFFE0D6C5,
          'text': 0xFF3A2A1A,
          'head': 0xFF3F2E1D,
          'subhead': 0xFF433220,
          'cardTitle': 0xFF402F1D,
          'muted': 0xFF533E28,
          'sec': 0xFF634B32,
          'icon': 0xFF6C543D,
          'faint': 0xFF6E5640,
          'dim': 0xFFAC9A86,
          'dim2': 0xFFB3A28E,
          'dim3': 0xFFC7B9A5,
          'box': 0xFFBDAE9A,
          'accent': 0xFF8A5A1E,
          'link': 0xFF8A5A1E,
          'chipText': 0xFF744B18,
          'tb': 0xFFEBD9B6,
          'tf': 0xFF5E3C12,
          'tkBg': 0xFFD8C098,
          'tkText': 0xFF764D19,
          'onAccent': 0xFFF7EEDC,
          'clay': 0xFFA84A22,
          'codeBg': 0xFFEAE0CE,
        },
        tags: [
          0xFFE7DABE,
          0xFFEBD5C0,
          0xFFDDD9C2,
          0xFFEBDAC5,
          0xFFE0DDC0,
          0xFFE2D5C2,
          0xFFE9D5C9,
        ],
        dots: [
          0xFF8A6A12,
          0xFFA84A22,
          0xFF4C6230,
          0xFFA86A40,
          0xFF5C7A24,
          0xFF6B4A30,
          0xFF9A4A5A,
        ],
      ),
      (AppTheme.fjord, Brightness.dark): (
        roles: {
          'canvas': 0xFF0F1A1C,
          'rail': 0xFF0C1517,
          'page': 0xFF132124,
          'raised': 0xFF1B2B2E,
          'card': 0xFF182729,
          'key': 0xFF1B292C,
          'keyEdge': 0xFF273537,
          'border': 0xFF223032,
          'hair': 0xFF1F2D2F,
          'menuEdge': 0xFF263436,
          'divider': 0xFF475556,
          'switchOff': 0xFF2B393B,
          'text': 0xFFDCE8E6,
          'head': 0xFFD4E1DF,
          'subhead': 0xFFCEDCDA,
          'cardTitle': 0xFFD3E1DE,
          'muted': 0xFFB6C8C6,
          'sec': 0xFF9DB3B0,
          'icon': 0xFF8BA4A0,
          'faint': 0xFF86A09C,
          'dim': 0xFF526766,
          'dim2': 0xFF4D6160,
          'dim3': 0xFF3B4D4E,
          'box': 0xFF435656,
          'accent': 0xFF5FB3A6,
          'link': 0xFF7FC9BD,
          'chipText': 0xFF9BD6CC,
          'tb': 0xFF1D3A38,
          'tf': 0xFFB6E3DB,
          'tkBg': 0xFF2A524E,
          'tkText': 0xFF86C9BE,
          'onAccent': 0xFF0F1A1C,
          'clay': 0xFFE08E6D,
          'codeBg': 0xFF212F32,
        },
        tags: [
          0xFF30362C,
          0xFF30302D,
          0xFF27352E,
          0xFF1C363A,
          0xFF213632,
          0xFF23333E,
          0xFF2B313D,
        ],
        dots: [
          0xFFD3B05A,
          0xFFD7865F,
          0xFF9AA765,
          0xFF4FB0B8,
          0xFF6FB07E,
          0xFF7E9BD3,
          0xFFB08CC9,
        ],
      ),
      (AppTheme.fjord, Brightness.light): (
        roles: {
          'canvas': 0xFFEDF4F3,
          'rail': 0xFFE5EFEE,
          'page': 0xFFFAFDFC,
          'raised': 0xFFE8F1F0,
          'card': 0xFFF2F8F7,
          'key': 0xFFF1F4F3,
          'keyEdge': 0xFFE3E9E7,
          'border': 0xFFEAEEED,
          'hair': 0xFFEDF1F0,
          'menuEdge': 0xFFE5EAE9,
          'divider': 0xFFBFC8C6,
          'switchOff': 0xFFDFE4E3,
          'text': 0xFF18302E,
          'head': 0xFF1D3634,
          'subhead': 0xFF223B39,
          'cardTitle': 0xFF1E3734,
          'muted': 0xFF314D4A,
          'sec': 0xFF42605C,
          'icon': 0xFF4D6A66,
          'faint': 0xFF506C68,
          'dim': 0xFF9DADAB,
          'dim2': 0xFFA5B5B2,
          'dim3': 0xFFBFCAC8,
          'box': 0xFFB3C0BE,
          'accent': 0xFF1F7A70,
          'link': 0xFF1D6C64,
          'chipText': 0xFF195E57,
          'tb': 0xFFD7EDE9,
          'tf': 0xFF145049,
          'tkBg': 0xFFB2D6D1,
          'tkText': 0xFF1A675E,
          'onAccent': 0xFFFFFFFF,
          'clay': 0xFFB5552E,
          'codeBg': 0xFFEAEFEE,
        },
        tags: [
          0xFFE9E8DA,
          0xFFEFE4DD,
          0xFFE3E8DC,
          0xFFD8E8E9,
          0xFFDCEAE1,
          0xFFDEE6EF,
          0xFFE6E3ED,
        ],
        dots: [
          0xFF87701C,
          0xFFAF5530,
          0xFF5E6E28,
          0xFF14737A,
          0xFF2F7D45,
          0xFF3F62A6,
          0xFF76509A,
        ],
      ),
    };

const _increased = <(AppTheme, Brightness), Map<String, int>>{
  (AppTheme.graphite, Brightness.dark): {
    'text': 0xFFF5F5F5,
    'head': 0xFFF5F5F5,
    'subhead': 0xFFEFEFEF,
    'sec': 0xFFCCCCCC,
    'muted': 0xFFD7D7D7,
    'faint': 0xFFC1C1C1,
    'border': 0xFF777777,
    'hair': 0xFF4B4B4B,
    'divider': 0xFF7D7D7D,
    'box': 0xFF888888,
    'link': 0xFFCAD4E2,
    'accent': 0xFFCDCDCD,
    'tf': 0xFFEFEFEF,
  },
  (AppTheme.graphite, Brightness.light): {
    'text': 0xFF0C0C0C,
    'head': 0xFF0C0C0C,
    'subhead': 0xFF121212,
    'sec': 0xFF343434,
    'muted': 0xFF2A2A2A,
    'faint': 0xFF3F3F3F,
    'border': 0xFF818181,
    'hair': 0xFFCACACA,
    'divider': 0xFF929292,
    'box': 0xFF868686,
    'link': 0xFF21416B,
    'accent': 0xFF303030,
    'tf': 0xFF151515,
  },
  (AppTheme.midnight, Brightness.dark): {
    'text': 0xFFF5F3F0,
    'head': 0xFFF5F3F0,
    'subhead': 0xFFEFEEEA,
    'sec': 0xFFCFCBC5,
    'muted': 0xFFD8D5CF,
    'faint': 0xFFC3BFB9,
    'border': 0xFF676665,
    'hair': 0xFF363535,
    'divider': 0xFF6E6D6C,
    'box': 0xFF7B7A78,
    'link': 0xFFC1D0B0,
    'accent': 0xFFA0B48D,
    'tf': 0xFFDDE8D1,
  },
  (AppTheme.dusk, Brightness.dark): {
    'text': 0xFFE7E7ED,
    'head': 0xFFE7E7ED,
    'subhead': 0xFFE4E3EA,
    'sec': 0xFFC2C1CE,
    'muted': 0xFFC7C5D2,
    'faint': 0xFFB9B8C6,
    'border': 0xFF70707A,
    'hair': 0xFF474752,
    'divider': 0xFF767680,
    'box': 0xFF81818A,
    'link': 0xFFC9C4E5,
    'accent': 0xFFADA6D3,
    'tf': 0xFFE1DEF3,
  },
  (AppTheme.dusk, Brightness.light): {
    'text': 0xFF18171E,
    'head': 0xFF18171E,
    'subhead': 0xFF1A1A20,
    'sec': 0xFF383743,
    'muted': 0xFF353440,
    'faint': 0xFF413F4C,
    'border': 0xFF828187,
    'hair': 0xFFC4C3C8,
    'divider': 0xFF919096,
    'box': 0xFF86858B,
    'link': 0xFF423C6C,
    'accent': 0xFF4D477E,
    'tf': 0xFF231F42,
  },
  (AppTheme.lamplight, Brightness.dark): {
    'text': 0xFFF7EAD8,
    'head': 0xFFF7EAD8,
    'subhead': 0xFFF3E7D5,
    'sec': 0xFFDEC7A9,
    'muted': 0xFFE4CCAC,
    'faint': 0xFFCEB79A,
    'border': 0xFF7A7063,
    'hair': 0xFF4F463B,
    'divider': 0xFF817769,
    'box': 0xFF8C8174,
    'link': 0xFFE7C89D,
    'accent': 0xFFD2A870,
    'tf': 0xFFF4E1C3,
  },
  (AppTheme.lamplight, Brightness.light): {
    'text': 0xFF17110A,
    'head': 0xFF17110A,
    'subhead': 0xFF1B140D,
    'sec': 0xFF3D2E1E,
    'muted': 0xFF382A1B,
    'faint': 0xFF473728,
    'border': 0xFF837B6F,
    'hair': 0xFFC6BDAE,
    'divider': 0xFF928B7E,
    'box': 0xFF878073,
    'link': 0xFF613F15,
    'accent': 0xFF714A19,
    'tf': 0xFF34210A,
  },
  (AppTheme.fjord, Brightness.dark): {
    'text': 0xFFF1F6F5,
    'head': 0xFFF1F6F5,
    'subhead': 0xFFEBF1F0,
    'sec': 0xFFC7D5D3,
    'muted': 0xFFD1DDDB,
    'faint': 0xFFB6C7C4,
    'border': 0xFF707A7C,
    'hair': 0xFF445052,
    'divider': 0xFF778182,
    'box': 0xFF828C8D,
    'link': 0xFFA5D9D1,
    'accent': 0xFF7CC1B6,
    'tf': 0xFFD7F0EB,
  },
  (AppTheme.fjord, Brightness.light): {
    'text': 0xFF0A1312,
    'head': 0xFF0A1312,
    'subhead': 0xFF0E1817,
    'sec': 0xFF263A37,
    'muted': 0xFF1F3331,
    'faint': 0xFF314441,
    'border': 0xFF7D8382,
    'hair': 0xFFC5CAC9,
    'divider': 0xFF8E9493,
    'box': 0xFF828887,
    'link': 0xFF144C46,
    'accent': 0xFF19645C,
    'tf': 0xFF0B2C28,
  },
};
