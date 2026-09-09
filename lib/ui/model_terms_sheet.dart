import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/theme.dart';
import '../core/toast.dart';
import '../speech/local_models.dart';

/// Asks somebody to agree to a model's licence before it is downloaded.
///
/// Only one model needs this, and it needs it for a specific reason: Gemma's
/// terms allow us to redistribute the weights on the condition that the terms
/// travel with them. Mirroring the file makes us the distributor, so this
/// sheet is the obligation being met, not a formality — which is why it says
/// what agreeing means in our own words and links the documents rather than
/// burying them.
///
/// Returns true only if the button was pressed. Dismissing is a no.
Future<bool?> showModelTermsSheet(
  BuildContext context, {
  required DownloadableModel model,
}) {
  final terms = model.terms;
  if (terms == null) return Future.value(true);
  return showDialog<bool>(
    context: context,
    builder: (context) => _ModelTermsDialog(model: model, terms: terms),
  );
}

class _ModelTermsDialog extends StatelessWidget {
  const _ModelTermsDialog({required this.model, required this.terms});

  final DownloadableModel model;
  final ModelTerms terms;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return AlertDialog(
      key: const ValueKey('model-terms-dialog'),
      title: Text('Download ${model.name}?'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              terms.summary,
              style: TextStyle(fontSize: 13, color: palette.textSecondary),
            ),
            const SizedBox(height: 14),
            for (final link in terms.links)
              _TermsLink(label: link.label, url: link.url),
            const SizedBox(height: 10),
            Text(
              '${fileSize(model.bytes)} to download.',
              style: TextStyle(fontSize: 12, color: palette.textTertiary),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('model-terms-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey('model-terms-accept'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Agree and download'),
        ),
      ],
    );
  }
}

class _TermsLink extends StatelessWidget {
  const _TermsLink({required this.label, required this.url});

  final String label;
  final String url;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        onTap: () => _open(context),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.open_in_new_rounded,
              size: 13,
              color: palette.textTertiary,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    final target = Uri.tryParse(url);
    if (target == null) return;
    var opened = false;
    try {
      opened = await launchUrl(target, mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }
    if (opened || !context.mounted) return;
    Toast.show(
      context,
      'Could not open ${target.host}',
      icon: Icons.error_outline_rounded,
      isError: true,
    );
  }
}
