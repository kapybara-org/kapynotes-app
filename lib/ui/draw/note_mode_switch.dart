import 'package:material_ui/material_ui.dart';

import '../../core/platform.dart';
import '../../core/theme.dart';

/// "Write | Draw": what a new note is going to be.
///
/// Shown only while the note is blank. Once there are words or strokes in it
/// the choice has been made, and the switch goes away rather than offering to
/// throw them out.
class NoteModeSwitch extends StatelessWidget {
  const NoteModeSwitch({
    super.key,
    required this.drawing,
    required this.onChanged,
  });

  final bool drawing;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final touch = !AppPlatform.hasPointer;
    return Semantics(
      container: true,
      label: 'Note type',
      child: Container(
        key: const ValueKey('note-mode-switch'),
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: palette.controlBackground,
          borderRadius: BorderRadius.circular(AppRadii.control),
          border: Border.all(color: palette.controlBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Segment(
              key: const ValueKey('note-mode-write'),
              label: 'Write',
              icon: KapyIcons.editNoteRounded,
              selected: !drawing,
              touch: touch,
              onTap: () => onChanged(false),
            ),
            _Segment(
              key: const ValueKey('note-mode-draw'),
              label: 'Draw',
              icon: KapyIcons.drawModeRounded,
              selected: drawing,
              touch: touch,
              onTap: () => onChanged(true),
            ),
          ],
        ),
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.touch,
    required this.onTap,
  });

  final String label;
  final KapyIconData icon;
  final bool selected;
  final bool touch;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final color = selected ? palette.textPrimary : palette.textSecondary;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: selected ? null : onTap,
          borderRadius: BorderRadius.circular(AppRadii.control - 2),
          hoverColor: palette.hover,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: EdgeInsets.symmetric(
              horizontal: touch ? 12 : 9,
              vertical: touch ? 8 : 4,
            ),
            decoration: BoxDecoration(
              color: selected ? palette.surfaceBackground : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadii.control - 2),
              border: Border.all(
                color: selected ? palette.controlBorder : Colors.transparent,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                KapyIcon(icon, size: touch ? 16 : 14, color: color),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: touch ? 14 : 12.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: color,
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
