import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../sync/account.dart';

/// Shows the recovery key once, and does not let it be dismissed casually.
///
/// This is the only moment the key exists outside a sealed box. Everything
/// about the dialog is built to make skipping past it harder than reading it:
/// there is no barrier tap, no close button, and the confirmation stays
/// disabled until the checkbox is ticked. That friction is the feature — a
/// forgotten passphrase with no recovery key means the notes are gone, and
/// there is no support request that can undo it.
Future<void> showRecoveryKeyDialog(BuildContext context, RecoveryKey key) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _RecoveryKeyDialog(recoveryKey: key),
  );
}

class _RecoveryKeyDialog extends StatefulWidget {
  const _RecoveryKeyDialog({required this.recoveryKey});
  final RecoveryKey recoveryKey;

  @override
  State<_RecoveryKeyDialog> createState() => _RecoveryKeyDialogState();
}

class _RecoveryKeyDialogState extends State<_RecoveryKeyDialog> {
  bool _saved = false;
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return PopScope(
      // Back and Escape are both a way past this, and there is nothing behind
      // it worth getting to yet.
      canPop: false,
      child: AlertDialog(
        title: const Text('Save your recovery key'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'If you forget your passphrase, this is the only way back to '
                'your notes. Nobody can reset it for you — not even us, '
                'because we never had it.',
                style: TextStyle(
                  fontSize: 12.5,
                  color: palette.textSecondary,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 14),
              SelectableText(
                widget.recoveryKey.formatted,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  height: 1.7,
                  letterSpacing: 0.4,
                  color: palette.textPrimary,
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: widget.recoveryKey.formatted),
                  );
                  if (context.mounted) setState(() => _copied = true);
                },
                icon: Icon(
                  _copied ? Icons.check_rounded : Icons.copy_rounded,
                  size: 16,
                ),
                label: Text(_copied ? 'Copied' : 'Copy'),
              ),
              const SizedBox(height: 6),
              CheckboxListTile(
                value: _saved,
                onChanged: (value) => setState(() => _saved = value ?? false),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(
                  'I have saved this somewhere safe',
                  style: TextStyle(fontSize: 12.5, color: palette.textPrimary),
                ),
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: _saved ? () => Navigator.of(context).pop() : null,
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }
}
