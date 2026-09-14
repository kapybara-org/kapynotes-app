import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/file_export.dart';
import '../../core/platform.dart';
import '../../core/text_file_export.dart';
import '../../core/theme.dart';
import '../../core/toast.dart';
import '../../sync/account.dart';
import '../control_surface.dart';

/// Shows the recovery key once, and does not let it be dismissed casually.
///
/// This is the only moment the key exists outside a sealed box. Everything
/// about the dialog is built to make skipping past it harder than reading it:
/// there is no barrier tap or close button, and leaving requires the explicit
/// saved-it action. A forgotten passphrase with no recovery key means the notes
/// are gone, and there is no support request that can undo it.
Future<void> showRecoveryKeyDialog(
  BuildContext context,
  RecoveryKey key, {
  TextFileSaver? saveTextFile,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _RecoveryKeyDialog(
      recoveryKey: key,
      saveTextFile: saveTextFile ?? TextFileExport.save,
    ),
  );
}

class _RecoveryKeyDialog extends StatefulWidget {
  const _RecoveryKeyDialog({
    required this.recoveryKey,
    required this.saveTextFile,
  });

  final RecoveryKey recoveryKey;
  final TextFileSaver saveTextFile;

  @override
  State<_RecoveryKeyDialog> createState() => _RecoveryKeyDialogState();
}

class _RecoveryKeyDialogState extends State<_RecoveryKeyDialog> {
  bool _copied = false;
  bool _savingFile = false;
  bool _savedFile = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.recoveryKey.formatted));
    if (mounted) setState(() => _copied = true);
  }

  Future<void> _download() async {
    if (_savingFile) return;
    setState(() => _savingFile = true);
    final result = await widget.saveTextFile(
      contents: '${widget.recoveryKey.formatted}\n',
      suggestedName: 'kapy-notes-recovery-key.txt',
    );
    if (!mounted) return;
    setState(() {
      _savingFile = false;
      if (result == FileExportOutcome.saved) _savedFile = true;
    });
    if (result == FileExportOutcome.failed ||
        result == FileExportOutcome.unsupported) {
      Toast.show(
        context,
        'Could not save the file. Copy it instead.',
        isError: true,
      );
    }
  }

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
                'Keep this with your passphrase. It unlocks your notes if '
                'you forget the passphrase.',
                style: TextStyle(
                  fontSize: AppTypeScale.body,
                  color: palette.textSecondary,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 12),
              KapyControlSurface(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                child: SelectableText(
                  widget.recoveryKey.formatted,
                  key: const ValueKey('recovery-key-value'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: AppPlatform.monoFontFallback.first,
                    fontFamilyFallback: AppPlatform.monoFontFallback,
                    fontSize: AppTypeScale.control,
                    height: 1.7,
                    letterSpacing: 0.4,
                    color: palette.textPrimary,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('copy-recovery-key'),
                    onPressed: _copy,
                    icon: KapyIcon(
                      _copied ? KapyIcons.checkRounded : KapyIcons.copyRounded,
                      size: AppControlMetrics.iconControl,
                    ),
                    label: Text(_copied ? 'Copied' : 'Copy'),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('download-recovery-key'),
                    onPressed: _savingFile ? null : _download,
                    icon: _savingFile
                        ? SizedBox.square(
                            dimension: AppControlMetrics.iconControl,
                            child: const CircularProgressIndicator(
                              strokeWidth: 1.5,
                            ),
                          )
                        : KapyIcon(
                            _savedFile
                                ? KapyIcons.checkRounded
                                : KapyIcons.downloadRounded,
                            size: AppControlMetrics.iconControl,
                          ),
                    label: Text(_savedFile ? 'Saved' : 'Download'),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          FilledButton.icon(
            key: const ValueKey('confirm-recovery-key-saved'),
            onPressed: _savingFile ? null : () => Navigator.of(context).pop(),
            icon: const KapyIcon(KapyIcons.checkRounded),
            label: const Text("I've saved my recovery key"),
          ),
        ],
      ),
    );
  }
}
