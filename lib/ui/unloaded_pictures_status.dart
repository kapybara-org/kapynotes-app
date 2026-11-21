import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';

/// What the page toolbar says in place of Saved while the open note has
/// pictures that didn't load: the note is saved and syncs, but those pictures
/// are still only the addresses they were pasted from. Pressing it shows the
/// first of them.
class UnloadedPicturesStatus extends StatelessWidget {
  const UnloadedPicturesStatus({
    super.key,
    required this.count,
    required this.onPressed,
  });

  final int count;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final tint = palette.clay.withValues(
      alpha: palette.brightness == Brightness.dark ? 0.1 : 0.12,
    );
    return FilledButton(
      onPressed: onPressed,
      style: ButtonStyle(
        minimumSize: WidgetStatePropertyAll(
          Size(0, AppControlMetrics.tonalButtonHeight),
        ),
        shape: const WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(AppRadii.control)),
          ),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 10),
        ),
        backgroundColor: KapyTheme.fillStates(
          tint,
          ink: palette.clay,
          disabled: tint,
        ),
        foregroundColor: WidgetStatePropertyAll(palette.clayText),
        textStyle: WidgetStatePropertyAll(
          Theme.of(context).textTheme.labelLarge?.copyWith(
            fontSize: AppTypeScale.body,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          KapyIcon(KapyIcons.errorOutlined, size: 15, color: palette.clay),
          const SizedBox(width: 6),
          Text(
            count == 1
                ? "1 picture didn't load"
                : "$count pictures didn't load",
            maxLines: 1,
          ),
        ],
      ),
    );
  }
}
