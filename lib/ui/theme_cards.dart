import 'package:material_ui/material_ui.dart';

import '../core/appearance.dart';
import '../core/platform.dart';
import '../core/theme.dart';
import 'tag_colours.dart';

/// Appearance's mode as three small windows: System, half light and half
/// dark, then Light and Dark, each in the chosen theme's own colours. A
/// pointer names each in its tooltip; a phone, which has none, writes the
/// name under it.
class AppearanceModes extends StatelessWidget {
  const AppearanceModes({
    super.key,
    required this.theme,
    required this.selected,
    required this.onSelected,
  });

  final AppTheme theme;
  final AppearanceMode selected;
  final ValueChanged<AppearanceMode> onSelected;

  @override
  Widget build(BuildContext context) {
    final ground = context.palette;
    final pointer = AppPlatform.hasPointer;
    final light = KapyTheme.palette(theme, Brightness.light);
    final dark = KapyTheme.palette(theme, Brightness.dark);
    final lights = [
      Theme.of(context).colorScheme.error,
      TagColour.mustard.dot(ground),
      TagColour.sage.dot(ground),
    ];
    final (width, height) = pointer ? (36.0, 24.0) : (48.0, 32.0);

    Widget window(AppearanceMode mode) {
      final chosen = mode == selected;
      BoxDecoration fill(Color Function(CalcPalette p) tone) => BoxDecoration(
        gradient: LinearGradient(
          colors: switch (mode) {
            AppearanceMode.system => [tone(light), tone(light), tone(dark), tone(dark)],
            AppearanceMode.light => [tone(light), tone(light)],
            AppearanceMode.dark => [tone(dark), tone(dark)],
          },
          stops: mode == AppearanceMode.system ? const [0, 0.5, 0.5, 1] : null,
        ),
      );

      final preview = Container(
        width: width,
        height: height,
        clipBehavior: Clip.antiAlias,
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
            color: chosen ? ground.accent : ground.switchTrackOff,
            width: chosen ? 2 : 1,
            strokeAlign: BorderSide.strokeAlignOutside,
          ),
        ),
        decoration: fill(
          (p) => p.controlBackground,
        ).copyWith(borderRadius: BorderRadius.circular(5)),
        child: Align(
          alignment: Alignment.topCenter,
          child: Container(
            height: height / 4,
            decoration: fill((p) => p.switchTrackOff),
            padding: const EdgeInsets.only(left: 3),
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                for (final colour in lights) ...[
                  if (colour != lights.first) const SizedBox(width: 1.5),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: colour,
                      shape: BoxShape.circle,
                    ),
                    child: const SizedBox.square(dimension: 2),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
      final button = Semantics(
        button: true,
        selected: chosen,
        inMutuallyExclusiveGroup: true,
        label: mode.label,
        child: InkWell(
          key: ValueKey('appearance-${mode.name}'),
          onTap: chosen ? null : () => onSelected(mode),
          borderRadius: BorderRadius.circular(5),
          child: pointer
              ? preview
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    preview,
                    const SizedBox(height: 6),
                    ExcludeSemantics(
                      child: Text(
                        mode.label,
                        style: TextStyle(
                          fontSize: 12,
                          height: 16 / 12,
                          color: chosen
                              ? ground.textPrimary
                              : ground.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      );
      return pointer ? Tooltip(message: mode.label, child: button) : button;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final mode in AppearanceMode.values) ...[
          if (mode != AppearanceMode.values.first)
            SizedBox(width: pointer ? 8 : 14),
          window(mode),
        ],
      ],
    );
  }
}

/// A theme as a coin: its dark page on the left, its light page on the right.
class ThemeSwatch extends StatelessWidget {
  const ThemeSwatch(this.theme, {super.key, this.size = 16});

  final AppTheme theme;
  final double size;

  @override
  Widget build(BuildContext context) {
    final dark = KapyTheme.palette(theme, Brightness.dark).sidebarBackground;
    final light = KapyTheme.palette(theme, Brightness.light).sidebarBackground;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [dark, dark, light, light],
          stops: const [0, 0.5, 0.5, 1],
        ),
        border: Border.all(
          color: context.palette.switchTrackOff,
          strokeAlign: BorderSide.strokeAlignOutside,
        ),
      ),
    );
  }
}

/// The six themes as swatches, the chosen one named beside them and ringed
/// in the accent. Each theme's line about itself, and its Default, Dark only
/// or New, is in its tooltip.
class ThemeSwatches extends StatelessWidget {
  const ThemeSwatches({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final AppTheme selected;
  final ValueChanged<AppTheme> onSelected;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final pointer = AppPlatform.hasPointer;
    final size = pointer ? 16.0 : 24.0;

    Widget swatch(AppTheme theme) {
      final chosen = theme == selected;
      final badge = theme.badge;
      return Tooltip(
        message: badge == null
            ? '${theme.label}\n${theme.description}'
            : '${theme.label} · $badge\n${theme.description}',
        child: Semantics(
          button: true,
          selected: chosen,
          inMutuallyExclusiveGroup: true,
          label: theme.label,
          child: InkWell(
            key: ValueKey('theme-${theme.name}'),
            onTap: () => onSelected(theme),
            customBorder: const CircleBorder(),
            child: Container(
              width: size + 8,
              height: size + 8,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: chosen ? palette.accent : Colors.transparent,
                  width: 1.5,
                ),
              ),
              child: ThemeSwatch(theme, size: size),
            ),
          ),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: Text(
              selected.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: pointer ? 13 : 15,
                height: 18 / (pointer ? 13 : 15),
                color: palette.textSecondary,
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        for (final theme in AppTheme.values) swatch(theme),
      ],
    );
  }
}
