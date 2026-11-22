import 'package:material_ui/material_ui.dart';

import '../core/appearance.dart';
import '../core/theme.dart';

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
      child: Material(
        color: ground.cardBackground,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.surface),
          side: selected
              ? BorderSide(color: ground.accent, width: 2)
              : BorderSide(color: ground.controlBorder),
        ),
        child: InkWell(
          key: ValueKey('theme-${theme.name}'),
          onTap: onTap,
          child: Stack(
            children: [
              Padding(
                padding: EdgeInsets.all(selected ? 7 : 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _ThemePreview(palette),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              theme.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: ground.textPrimary,
                                fontSize: 13.5,
                                height: 18 / 13.5,
                                fontWeight: AppWeight.font(AppWeight.section),
                                fontVariations: AppWeight.wght(
                                  AppWeight.section,
                                ),
                              ),
                            ),
                          ),
                          if (badge != null)
                            Flexible(
                              child: Container(
                                height: 18,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                ),
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: ground.controlBackground,
                                  border: Border.all(
                                    color: ground.controlBorder,
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
                                    fontWeight: AppWeight.font(
                                      AppWeight.rowTitle,
                                    ),
                                    fontVariations: AppWeight.wght(
                                      AppWeight.rowTitle,
                                    ),
                                  ),
                                ),
                              ),
                            ),
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
                            color: ground.textDescription,
                            fontSize: 12,
                            height: 16 / 12,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (selected)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: ground.accent,
                      shape: BoxShape.circle,
                    ),
                    child: KapyIcon(
                      KapyIcons.checkRounded,
                      size: 13,
                      color: ground.onAccent,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A window in miniature: the spaces rail, the notes list with two tagged
/// notes, and a page with a heading, lines, a checked task and the totals.
class _ThemePreview extends StatelessWidget {
  const _ThemePreview(this.p);

  final CalcPalette p;

  @override
  Widget build(BuildContext context) {
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
    Widget note() => Expanded(
      child: Container(
        decoration: BoxDecoration(
          color: p.cardBackground,
          border: Border.all(color: p.controlBorder),
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
                  note(),
                  const SizedBox(height: 4),
                  note(),
                  const SizedBox(height: 4),
                  note(),
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
                          block(p.resultPillBackground, room ? 16 : 10, 6, 3),
                          const SizedBox(width: 4),
                          block(p.resultPillBackground, room ? 16 : 10, 6, 3),
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
