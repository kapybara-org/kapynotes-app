import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../images/image_codec.dart';

/// Lets images be dropped straight onto the page.
///
/// Only built where there is a pointer to drop with. On a phone this is the
/// identity widget, which keeps the plugin's channel out of the mobile app
/// entirely rather than registering a listener that can never fire.
///
/// The overlay it shows while a drag is over the page is deliberately not a
/// full-bleed curtain: the writing stays legible underneath, so you can see
/// where the picture is about to land.
class ImageDropTarget extends StatefulWidget {
  const ImageDropTarget({
    super.key,
    required this.child,
    required this.onFiles,
    this.enabled = true,
  });

  final Widget child;
  final ValueChanged<List<XFile>> onFiles;
  final bool enabled;

  @override
  State<ImageDropTarget> createState() => _ImageDropTargetState();
}

class _ImageDropTargetState extends State<ImageDropTarget> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || !AppPlatform.isDesktop) return widget.child;

    return DropTarget(
      onDragEntered: (_) => setState(() => _hovering = true),
      onDragExited: (_) => setState(() => _hovering = false),
      onDragDone: (details) {
        setState(() => _hovering = false);
        final files = <XFile>[
          for (final item in details.files)
            // A dropped folder is not a mistake worth an error message; it is
            // simply not an image, so it is passed over in silence.
            if (item is! DropItemDirectory && _looksLikeImage(item.name)) item,
        ];
        if (files.isNotEmpty) widget.onFiles(files);
      },
      child: Stack(
        children: [
          widget.child,
          if (_hovering)
            Positioned.fill(
              child: IgnorePointer(child: _DropHint(palette: context.palette)),
            ),
        ],
      ),
    );
  }

  static bool _looksLikeImage(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return false;
    return supportedImageExtensions.contains(
      name.substring(dot + 1).toLowerCase(),
    );
  }
}

class _DropHint extends StatelessWidget {
  const _DropHint({required this.palette});

  final CalcPalette palette;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Container(
      margin: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.55), width: 1.5),
      ),
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: palette.surfaceBackground,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: palette.separator),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.image_outlined, size: 18, color: accent),
                const SizedBox(width: 8),
                Text(
                  'Drop to add to this note',
                  style: TextStyle(
                    fontSize: AppTypeScale.control,
                    fontWeight: FontWeight.w600,
                    color: palette.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
