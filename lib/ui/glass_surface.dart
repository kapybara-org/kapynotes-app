import 'dart:ui' show ImageFilter;

import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
import '../core/theme.dart';

/// A restrained translucent surface for app chrome.
///
/// Text-heavy content stays on opaque backgrounds. This material is reserved
/// for navigation and transient controls where layering improves hierarchy.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.color,
    this.border,
    this.borderRadius = BorderRadius.zero,
    this.blur = 18,
  });

  final Widget child;
  final Color? color;
  final Border? border;
  final BorderRadius borderRadius;
  final double blur;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final materialColor = color ?? palette.surfaceBackground;
    final effectiveColor = AppPlatform.isMobile
        ? Color.alphaBlend(materialColor, palette.editorBackground)
        : materialColor;
    final surface = DecoratedBox(
      decoration: BoxDecoration(
        color: effectiveColor,
        border: border,
        borderRadius: borderRadius,
      ),
      child: child,
    );

    // Mobile GPUs pay this blur cost during the handoff to the full editor,
    // and Android's Impeller OpenGL path can drop the filtered surface on some
    // devices. Alpha compositing keeps the hierarchy without blocking input.
    final filtered = AppPlatform.isMobile
        ? surface
        : BackdropFilter(
            filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
            child: surface,
          );

    return ClipRRect(borderRadius: borderRadius, child: filtered);
  }
}
