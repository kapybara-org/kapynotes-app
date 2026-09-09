import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';

/// A translucent surface for app chrome.
///
/// The desktop shows through this because the window blurs it natively —
/// macOS' visual effect material, Windows' acrylic — and this paints a thin
/// tint over that blur. It never filters anything itself. A Flutter
/// `BackdropFilter` can only blur what Flutter drew beneath it, which for the
/// toolbar, the sidebar and the footer is nothing, and it is not free even
/// then: the engine keeps a window-sized copy of the backdrop for every one
/// on screen, and the three here once held over a hundred megabytes of GPU
/// memory for the life of the window.
///
/// With transparency off, or on a platform with nothing behind the window,
/// the palette carries no translucency and the surface paints solid.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.color,
    this.border,
    this.borderRadius = BorderRadius.zero,
  });

  final Widget child;
  final Color? color;
  final Border? border;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final materialColor = (color ?? palette.surfaceBackground)
        .withMultipliedAlpha(palette.translucency);
    // Opaque mode blends onto the editor's flat background so a surface asked
    // for at 94% paints the same pixels it would have painted at 100%.
    final effectiveColor = palette.isGlass
        ? materialColor
        : Color.alphaBlend(materialColor, palette.editorBackground);

    // The glass rim: a hairline of light along the top edge, fading out over
    // the first few points. It is what tells a pane of glass from a pane of
    // fog, and it costs one gradient.
    final highlight = palette.glassHighlight;
    final sheen = highlight.a == 0
        ? null
        : BoxDecoration(
            borderRadius: borderRadius,
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: const [0, 0.04, 0.5],
              colors: [
                highlight,
                highlight.withMultipliedAlpha(0.2),
                highlight.withMultipliedAlpha(0),
              ],
            ),
          );

    return ClipRRect(
      borderRadius: borderRadius,
      child: Container(
        decoration: BoxDecoration(
          color: effectiveColor,
          border: border,
          borderRadius: borderRadius,
        ),
        foregroundDecoration: sheen,
        child: child,
      ),
    );
  }
}
