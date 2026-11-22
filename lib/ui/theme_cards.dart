import 'package:material_ui/material_ui.dart';

import '../core/appearance.dart';
import '../core/theme.dart';
import 'tag_colours.dart';

/// The six themes as cards in Settings › Appearance, each a small window in
/// its own colours (Themes r2, p-N-0: 20RJ-0 on a computer, 20YF-0 on a
/// phone). Three across with a line about each where there is room, two
/// across and names alone on a phone.
class ThemeCards extends StatelessWidget {
  const ThemeCards({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final AppTheme selected;
  final ValueChanged<AppTheme> onSelected;

  static const double _gap = 12;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return LayoutBuilder(
      builder: (context, constraints) {
        final roomy = constraints.maxWidth >= 480;
        final columns = roomy ? 3 : 2;
        const themes = AppTheme.values;
        return Column(
          children: [
            for (var start = 0; start < themes.length; start += columns) ...[
              if (start > 0) const SizedBox(height: _gap),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = start; i < start + columns; i++) ...[
                      if (i > start) const SizedBox(width: _gap),
                      Expanded(
                        child: i < themes.length
                            ? _ThemeCard(
                                theme: themes[i],
                                // Midnight's light side is Riverbank's, so it
                                // shows the side that is its own.
                                palette: KapyTheme.palette(
                                  themes[i],
                                  themes[i] == AppTheme.midnight
                                      ? Brightness.dark
                                      : brightness,
                                ),
                                selected: themes[i] == selected,
                                described: roomy,
                                onTap: () => onSelected(themes[i]),
                              )
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _ThemeCard extends StatelessWidget {
  const _ThemeCard({
    required this.theme,
    required this.palette,
    required this.selected,
    required this.described,
    required this.onTap,
  });

  final AppTheme theme;

  /// The theme's own colours, for the window it shows.
  final CalcPalette palette;
  final bool selected;
  final bool described;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ground = context.palette;
    final badge = theme.badge;
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      // The chosen card is a step lighter, with no outline or tick (D13).
      // Increase contrast outlines every card and rings the chosen one.
      child: Material(
        color: selected
            ? Color.alphaBlend(ground.fillControl, ground.cardBackground)
            : ground.cardBackground,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.surface),
          side: !ground.increasedContrast
              ? BorderSide.none
              : selected
              ? BorderSide(color: ground.accent, width: 2)
              : BorderSide(color: ground.controlBorder),
        ),
        child: InkWell(
          key: ValueKey('theme-${theme.name}'),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ThemePreview(theme, palette),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          theme.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: ground.textPrimary,
                            fontSize: 13.5,
                            height: 18 / 13.5,
                            fontWeight: AppWeight.font(AppWeight.section),
                            fontVariations: AppWeight.wght(AppWeight.section),
                          ),
                        ),
                      ),
                      if (badge != null) ...[
                        const SizedBox(width: 6),
                        Container(
                          height: 18,
                          constraints: const BoxConstraints(maxWidth: 80),
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: Color.alphaBlend(
                              ground.fillControl,
                              ground.cardBackground,
                            ),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            badge,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: ground.textSecondary,
                              fontSize: 11,
                              height: 15 / 11,
                              fontWeight: AppWeight.font(AppWeight.rowTitle),
                              fontVariations: AppWeight.wght(
                                AppWeight.rowTitle,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (described) ...[
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(2, 0, 2, 2),
                    child: Text(
                      theme.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: ground.textTertiary,
                        fontSize: 12,
                        height: 16 / 12,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A window in miniature: the spaces rail, the notes list with two tagged
/// notes, and a page with a heading, lines, a checked task and the totals.
class _ThemePreview extends StatelessWidget {
  const _ThemePreview(this.theme, this.p);

  final AppTheme theme;
  final CalcPalette p;

  /// The list's three notes, tagged mustard, plain and tagged sage, then the
  /// rust the second total takes beside the first's sage. D13 picks
  /// Riverbank's dark side by hand and mixes every other dark side's tag dots
  /// into its page, Midnight's at 20% and the rest at 15%. A light side,
  /// which D13 doesn't draw, is mixed the same way at 15%.
  List<Color> get _tints {
    if (theme == AppTheme.riverbank && p.brightness == Brightness.dark) {
      return const [
        Color(0xFF393425),
        Color(0xFF2F2D29),
        Color(0xFF25332A),
        Color(0xFF372B26),
      ];
    }
    final strength = theme == AppTheme.midnight ? 0.2 : 0.15;
    Color tint(TagColour tag) => Color.alphaBlend(
      tag.dot(p).withValues(alpha: strength),
      p.editorBackground,
    );
    return [
      tint(TagColour.mustard),
      p.cardBackground,
      tint(TagColour.sage),
      tint(TagColour.rust),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final [mustard, plain, sage, rust] = _tints;
    Widget block(Color color, double width, double height, double radius) =>
        Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(radius),
          ),
        );
    Widget line(Color color, double share, {double height = 4}) =>
        FractionallySizedBox(
          widthFactor: share,
          alignment: Alignment.centerLeft,
          child: block(color, double.infinity, height, height / 2),
        );
    Widget note(Color color) => Expanded(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    );
    return Container(
      height: 88,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: p.sidebarBackground,
        border: Border.all(color: p.controlBorder),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: 11,
            color: p.railBackground,
            padding: const EdgeInsets.only(top: 8),
            child: Column(
              children: [
                block(p.tonalBackground, 6, 6, 2),
                const SizedBox(height: 5),
                block(p.checkboxBorder, 5, 5, 2),
              ],
            ),
          ),
          Expanded(
            flex: 34,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  line(p.textHeading, 0.6),
                  const SizedBox(height: 4),
                  note(mustard),
                  const SizedBox(height: 4),
                  note(plain),
                  const SizedBox(height: 4),
                  note(sage),
                ],
              ),
            ),
          ),
          Expanded(
            flex: 61,
            child: Container(
              margin: const EdgeInsets.fromLTRB(0, 5, 5, 5),
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 9),
              decoration: BoxDecoration(
                color: p.editorBackground,
                border: Border.all(color: p.pageBorder),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  line(p.textHeading, 0.55, height: 6),
                  const SizedBox(height: 5),
                  line(p.textPrimary, 0.85),
                  const SizedBox(height: 5),
                  line(p.textSecondary, 0.7),
                  const SizedBox(height: 7),
                  Row(
                    children: [
                      block(p.accent, 7, 7, 2),
                      const SizedBox(width: 4),
                      Expanded(child: line(p.textMuted, 0.45)),
                    ],
                  ),
                  const Spacer(),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      // The chips stand for totals, not content, so they give
                      // way before the card overflows at a narrow window.
                      final room = constraints.maxWidth >= 62;
                      return Row(
                        children: [
                          block(sage, room ? 16 : 10, 6, 3),
                          const SizedBox(width: 4),
                          block(rust, room ? 16 : 10, 6, 3),
                          const Spacer(),
                          block(p.accent, room ? 18 : 12, 7, 3),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
