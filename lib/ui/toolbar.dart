import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../core/toast.dart';
import '../data/update_checker.dart';

/// "Update and restart", the whole of an update once a release has downloaded
/// and passed its checks.
///
/// In the title bar because the title bar is always there: the notes list
/// starts every launch closed, so a button inside it would first need the
/// list opened. Draws nothing at all until there is something to install,
/// and listens to the checker itself, so a download counting up its percent
/// rebuilds this and not the page under it.
class UpdateRestartButton extends StatelessWidget {
  const UpdateRestartButton({
    super.key,
    required this.updates,
    required this.wide,
    this.gap = 6,
  });

  final UpdateChecker updates;
  final bool wide;

  /// The space before the next button, kept inside so it goes with this.
  final double gap;

  Future<void> _install(BuildContext context) async {
    if (await updates.installAndRestart() || !context.mounted) return;
    Toast.show(
      context,
      updates.downloadError ?? 'Could not install the update',
      icon: KapyIcons.errorOutlined,
      isError: true,
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: updates,
    builder: (context, _) {
      final staged = updates.staged;
      if (staged == null) return const SizedBox.shrink();
      final palette = context.palette;
      final installing = updates.isInstalling;
      final label = installing
          ? 'Restarting…'
          : wide
          ? 'Update and restart'
          : 'Update';
      return Padding(
        padding: EdgeInsets.only(right: gap),
        child: Tooltip(
          message: 'Install Kapy Notes ${staged.version} and restart',
          child: TextButton.icon(
            key: const ValueKey('toolbar-update-restart'),
            onPressed: installing ? null : () => unawaited(_install(context)),
            icon: KapyIcon(
              KapyIcons.systemUpdateRounded,
              size: 14,
              color: installing ? palette.textTertiary : palette.chipCurrency,
            ),
            label: Text(
              label,
              maxLines: 1,
              style: TextStyle(
                fontSize: AppTypeScale.small,
                fontWeight: FontWeight.w500,
                fontVariations: AppWeight.variations(AppWeight.bold(AppWeight.rowTitle)),
              ),
            ),
            style: TextButton.styleFrom(
              foregroundColor: palette.chipCurrency,
              disabledForegroundColor: palette.textTertiary,
              backgroundColor: palette.selectedBackground,
              minimumSize: Size(0, AppControlMetrics.iconButtonExtent),
              padding: const EdgeInsets.symmetric(horizontal: 9),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              shape: StadiumBorder(
                side: BorderSide(
                  color: palette.chipCurrency.withValues(alpha: 0.35),
                  width: AppHairline.of(context),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
