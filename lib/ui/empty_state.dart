import 'package:material_ui/material_ui.dart';

import '../core/editor_font.dart';
import '../core/theme.dart';
import 'app_logo.dart';

/// Shown in the main pane when there is no note to edit.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required VoidCallback this.onCreate})
    : drawings = false,
      shortcut = null;

  /// The page in Drawings with nothing open: a quiet hint at New drawing,
  /// which is already in the window bar over the list.
  const EmptyState.drawings({super.key, this.shortcut})
    : drawings = true,
      onCreate = null;

  final VoidCallback? onCreate;
  final bool drawings;

  /// The keys for New drawing, named in the hint.
  final String? shortcut;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    if (drawings) {
      const handwritten = WritingFont.handwritten;
      return Container(
        color: palette.paperColor,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            KapyIcon(
              KapyIcons.penRounded,
              size: 30,
              strokeWidth: 1.4,
              color: palette.textTertiary,
            ),
            const SizedBox(height: 10),
            Text(
              'No drawing open',
              style: TextStyle(
                fontFamily: handwritten.fontFamily,
                fontFamilyFallback: handwritten.fontFamilyFallback,
                fontVariations: handwritten.fontVariations,
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: palette.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              ['Start one with New drawing', ?shortcut].join(' or '),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppTypeScale.small,
                fontWeight: FontWeight.w500,
                color: palette.textTertiary,
              ),
            ),
          ],
        ),
      );
    }

    // The paper runs to the window's edges; the words in it stay clear of the
    // home indicator, the same bargain the notes list makes.
    return Container(
      color: palette.paperColor,
      alignment: Alignment.center,
      padding: EdgeInsets.fromLTRB(
        32,
        32,
        32,
        32 + MediaQuery.paddingOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppWordmark(
            markSize: AppControlMetrics.wordmarkMarkLarge,
            fontSize: AppTypeScale.display,
            spacing: 12,
          ),
          const SizedBox(height: 18),
          Text(
            'No note selected',
            style: TextStyle(
              fontSize: AppTypeScale.title,
              fontWeight: FontWeight.w400,
              color: palette.textPrimary,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            'Start writing. Calculations resolve as you type.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: AppTypeScale.body,
              height: 1.45,
              color: palette.textSecondary,
            ),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: onCreate,
            icon: KapyIcon(
              KapyIcons.addRounded,
              size: AppControlMetrics.iconAction,
            ),
            label: const Text('New note'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
                fontSize: AppTypeScale.control,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
