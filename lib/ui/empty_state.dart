import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import 'app_logo.dart';

/// Shown in the main pane when there is no note to edit.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Container(
      color: palette.editorBackground,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(32),
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
              fontWeight: FontWeight.w600,
              color: palette.textPrimary,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            'Write freely. Calculations resolve as you type.',
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
            icon: Icon(Icons.add_rounded, size: AppControlMetrics.iconAction),
            label: const Text('New Note'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
                fontSize: AppTypeScale.control,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
