import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../glass_surface.dart';

/// Persistent note status bar inspired by the compact footer in Numi.
class NoteFooter extends StatelessWidget {
  const NoteFooter({
    super.key,
    required this.total,
    required this.onSettingsPressed,
    this.showSettingsButton = true,
  });

  final String total;
  final VoidCallback onSettingsPressed;
  final bool showSettingsButton;

  static const double height = 40;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return GlassSurface(
      color: palette.surfaceBackground.withValues(alpha: 0.72),
      blur: 24,
      border: Border(top: BorderSide(color: palette.separator, width: 0.5)),
      child: SizedBox(
        height: height,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 52),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: palette.selectedBackground,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text.rich(
                      key: const ValueKey('note-total'),
                      TextSpan(
                        text: 'Total: ',
                        style: TextStyle(
                          fontSize: 11.25,
                          fontWeight: FontWeight.w500,
                          color: palette.textTertiary,
                        ),
                        children: [
                          TextSpan(
                            text: total,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: palette.textPrimary,
                            ),
                          ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
            ),
            if (showSettingsButton)
              Positioned(
                left: 8,
                child: FooterSettingsButton(onPressed: onSettingsPressed),
              ),
          ],
        ),
      ),
    );
  }
}

/// The shared settings affordance used by the note and sidebar footers.
class FooterSettingsButton extends StatelessWidget {
  const FooterSettingsButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    key: const ValueKey('note-settings'),
    onPressed: onPressed,
    icon: const Icon(Icons.settings_outlined, size: 17),
    tooltip: 'Settings',
    color: context.palette.textTertiary,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
    visualDensity: VisualDensity.compact,
  );
}
