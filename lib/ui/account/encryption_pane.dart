import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/file_export.dart';
import '../../core/platform.dart';
import '../../core/text_file_export.dart';
import '../../core/theme.dart';
import '../../core/toast.dart';
import '../../sync/account.dart';
import '../../sync/key_bundle.dart';
import '../../sync/recovery_key.dart';
import '../control_surface.dart';
import '../settings_rows.dart';
import 'recovery_key_dialog.dart';

/// Settings → Sync's Encryption group: the passphrase and the recovery key,
/// each changeable from any unlocked device without the old passphrase.
class EncryptionGroup extends StatelessWidget {
  const EncryptionGroup({
    super.key,
    required this.account,
    this.saveTextFile,
    this.passphraseGenerator,
  });

  final Account account;
  final TextFileSaver? saveTextFile;
  final String Function()? passphraseGenerator;

  @override
  Widget build(BuildContext context) {
    final changes = account.keyBundle?.changes ?? const KeyChanges();
    final unsaved = account.recoveryKeyUnsaved;
    final missing = account.keyBundle != null && !account.hasRecoveryKey;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsLabel('Encryption'),
        SettingsGroup(
          children: [
            SettingsRow(
              key: const ValueKey('passphrase-row'),
              title: 'Passphrase',
              subtitle: switch (changes.passphrase) {
                final change? =>
                  'Changed ${changeDate(change.at)} on ${changeDevice(change)}',
                null => 'Unlocks your notes on a new device',
              },
              trailing: SettingsRowButton(
                key: const ValueKey('change-passphrase'),
                label: 'Change…',
                onPressed: () => showKeyChangeDialog(
                  context,
                  account,
                  KeyProofAction.passphrase,
                  saveTextFile: saveTextFile,
                  passphraseGenerator: passphraseGenerator,
                ),
              ),
            ),
            SettingsRow(
              key: const ValueKey('recovery-key-row'),
              title: 'Recovery key',
              subtitle: unsaved
                  ? "Your new recovery key wasn't saved. Make another."
                  : missing
                  ? 'Not set up yet'
                  : switch (changes.recoveryKey) {
                      final change? =>
                        'Made ${changeDate(change.at)} on ${changeDevice(change)}',
                      null => 'Your way back in if you forget the passphrase',
                    },
              trailing: SettingsRowButton(
                key: const ValueKey('recovery-key'),
                label: missing ? 'Set up…' : 'Make new…',
                prominent: missing || unsaved,
                onPressed: () => showKeyChangeDialog(
                  context,
                  account,
                  KeyProofAction.recoveryKey,
                  saveTextFile: saveTextFile,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// "18 Nov", or "18 Nov 2025" outside this year, in local time.
String changeDate(DateTime at, {DateTime? now}) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final local = at.toLocal();
  final day = '${local.day} ${months[local.month - 1]}';
  return local.year == (now ?? DateTime.now()).year
      ? day
      : '$day ${local.year}';
}

String changeDevice(KeyChange change) => change.device ?? 'another device';

/// s•••@gmail.com: enough to recognise, not enough to read over a shoulder.
String maskedEmail(String email) {
  final at = email.indexOf('@');
  if (at < 1) return email;
  return '${email[0]}•••${email.substring(at)}';
}

String keyCodeProblemText(KeyCodeProblem problem) => switch (problem) {
  KeyCodeProblem.offline => _offline,
  KeyCodeProblem.tooSoon => 'Wait a moment before asking for another code.',
  KeyCodeProblem.wrong =>
    "That code doesn't match. Check the latest email from Kapy Notes.",
  KeyCodeProblem.expired => 'That code has expired. Send another to try again.',
  KeyCodeProblem.tooManyTries => 'Too many tries. Send another code.',
};

const String _offline =
    "Couldn't reach Kapy Notes. Nothing has changed yet. Try again when "
    "you're online.";

const String _refused = "Kapy Notes couldn't make that change. Try again.";

/// Changes the passphrase, or makes a recovery key, from this unlocked
/// device. A first recovery key on an older account needs no code: whoever
/// holds this device already holds the key it seals.
Future<void> showKeyChangeDialog(
  BuildContext context,
  Account account,
  KeyProofAction action, {
  TextFileSaver? saveTextFile,
  String Function()? passphraseGenerator,
}) async {
  final save = saveTextFile ?? TextFileExport.save;
  final replacesOld = account.hasRecoveryKey || account.recoveryKeyUnsaved;
  final made = await showDialog<PreparedRecoveryKey>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _KeyChangeDialog(
      account: account,
      action: action,
      saveTextFile: save,
      passphraseGenerator: passphraseGenerator ?? generatePassphrase,
    ),
  );
  if (made == null || !context.mounted) return;
  await showRecoveryKeyDialog(
    context,
    made.key,
    saveTextFile: save,
    title: 'Save your new recovery key',
    replacesOld: replacesOld,
  );
  account.recoveryKeySaved(made);
  if (context.mounted) Toast.show(context, 'New recovery key saved');
}

enum _Step { intro, code, passphrase }

class _KeyChangeDialog extends StatefulWidget {
  const _KeyChangeDialog({
    required this.account,
    required this.action,
    required this.saveTextFile,
    required this.passphraseGenerator,
  });

  final Account account;
  final KeyProofAction action;
  final TextFileSaver saveTextFile;
  final String Function() passphraseGenerator;

  @override
  State<_KeyChangeDialog> createState() => _KeyChangeDialogState();
}

class _KeyChangeDialogState extends State<_KeyChangeDialog> {
  final _code = TextEditingController();
  late final String _passphrase = widget.passphraseGenerator();
  late final bool _firstKey =
      widget.action == KeyProofAction.recoveryKey &&
      widget.account.keyBundle != null &&
      !widget.account.hasRecoveryKey;

  _Step _step = _Step.intro;
  String? _proof;
  PreparedKeyChange? _prepared;
  String? _problem;
  bool _busy = false;
  bool _savingFile = false;

  bool get _changesPassphrase => widget.action == KeyProofAction.passphrase;

  String get _email => maskedEmail(widget.account.user?.email ?? '');

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() body) async {
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      await body();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendCode() => _run(() async {
    final problem = await widget.account.sendKeyCode(widget.action);
    if (!mounted) return;
    setState(() {
      if (problem != null) {
        _problem = keyCodeProblemText(problem);
      } else {
        _code.clear();
        _step = _Step.code;
      }
    });
  });

  Future<void> _confirmCode() => _run(() async {
    final result = await widget.account.verifyKeyCode(
      widget.action,
      _code.text,
    );
    if (!mounted) return;
    final problem = result.problem;
    if (problem != null) {
      setState(() => _problem = keyCodeProblemText(problem));
      return;
    }
    _proof = result.proof;
    if (_changesPassphrase) {
      setState(() => _step = _Step.passphrase);
    } else {
      await _commit();
    }
  });

  Future<void> _commit() async {
    final account = widget.account;
    final prepared = _prepared ??= _changesPassphrase
        ? await account.preparePassphrase(_passphrase)
        : await account.prepareRecoveryKey();
    if (prepared == null) {
      if (mounted) setState(() => _problem = _refused);
      return;
    }
    final result = await account.commitKeyChange(prepared, proof: _proof);
    if (!mounted) return;
    switch (result) {
      case KeyChangeDone():
        if (_changesPassphrase) Toast.show(context, 'Passphrase changed');
        Navigator.of(
          context,
        ).pop(prepared is PreparedRecoveryKey ? prepared : null);
      case KeyChangeNeedsCode():
        setState(() {
          _proof = null;
          _code.clear();
          _step = _Step.code;
          _problem = keyCodeProblemText(KeyCodeProblem.expired);
        });
      case KeyChangeLostRace(:final change):
        setState(
          () => _problem = _changesPassphrase
              ? 'Your passphrase was just changed on ${changeDevice(change)}. '
                    'Nothing changed here.'
              : 'A new recovery key was made on ${changeDevice(change)} a '
                    'moment ago. Keep that one. Make another here only if '
                    "you've lost it.",
        );
      case KeyChangeOffline():
        setState(() => _problem = _offline);
      case KeyChangeRefused():
        setState(() => _problem = _refused);
    }
  }

  @override
  Widget build(BuildContext context) {
    final (title, lines, actions) = switch (_step) {
      _Step.intro => _intro(),
      _Step.code => _codeStep(),
      _Step.passphrase => _newPassphrase(),
    };
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ...lines,
              if (_problem != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    _problem!,
                    key: const ValueKey('key-change-problem'),
                    style: TextStyle(
                      fontSize: AppTypeScale.small,
                      color: context.palette.textSecondary,
                      height: 1.4,
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: actions,
      ),
    );
  }

  Widget _cancel() => TextButton(
    key: const ValueKey('key-change-cancel'),
    onPressed: _busy ? null : () => Navigator.of(context).pop(),
    child: const Text('Cancel'),
  );

  (String, List<Widget>, List<Widget>) _intro() {
    final sendsCode = !_firstKey;
    return (
      _changesPassphrase
          ? 'Change your passphrase'
          : _firstKey
          ? 'Set up a recovery key'
          : 'Make a new recovery key?',
      [
        if (_changesPassphrase) ...[
          const _Line(
            'Your notes stay as they are. Your other devices keep syncing '
            "and won't ask for anything.",
          ),
          const _Line(
            "A device that's signed out, or a new one, will need the new "
            "passphrase. Shared notes aren't affected.",
          ),
        ] else if (_firstKey)
          const _Line(
            'If you forget your passphrase, this key gets you back in. '
            'Nothing else changes.',
            last: true,
          )
        else
          const _Line(
            'Your current recovery key will stop working. Your passphrase, '
            "your notes and your other devices aren't affected.",
          ),
        if (sendsCode)
          _Line(
            "To check it's you, we'll email a code to $_email.",
            last: true,
          ),
      ],
      [
        _cancel(),
        FilledButton(
          key: const ValueKey('key-change-continue'),
          onPressed: _busy
              ? null
              : sendsCode
              ? _sendCode
              : () => _run(_commit),
          child: Text(sendsCode ? 'Send code' : 'Continue'),
        ),
      ],
    );
  }

  (String, List<Widget>, List<Widget>) _codeStep() => (
    'Enter the code',
    [
      _Line('We sent a 6-digit code to $_email. It works for 10 minutes.'),
      TextField(
        key: const ValueKey('key-change-code'),
        controller: _code,
        autofocus: true,
        keyboardType: TextInputType.number,
        autofillHints: const [AutofillHints.oneTimeCode],
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        maxLength: 6,
        decoration: const InputDecoration(hintText: 'Code', counterText: ''),
        onSubmitted: (_) => _busy ? null : _confirmCode(),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          key: const ValueKey('key-change-resend'),
          onPressed: _busy ? null : _sendCode,
          child: const Text('Send another code'),
        ),
      ),
    ],
    [
      _cancel(),
      FilledButton(
        key: const ValueKey('key-change-confirm-code'),
        onPressed: _busy ? null : _confirmCode,
        child: const Text('Confirm'),
      ),
    ],
  );

  (String, List<Widget>, List<Widget>) _newPassphrase() => (
    'Save your new passphrase',
    [
      const _Line('Use it to unlock your notes on a new device.'),
      GeneratedPassphrase(
        passphrase: _passphrase,
        saveTextFile: widget.saveTextFile,
        enabled: !_busy,
        onSaving: (saving) => setState(() => _savingFile = saving),
        onProblem: (problem) => setState(() => _problem = problem),
      ),
    ],
    [
      _cancel(),
      FilledButton(
        key: const ValueKey('confirm-new-passphrase'),
        onPressed: _busy || _savingFile ? null : () => _run(_commit),
        child: const Text('Change passphrase'),
      ),
    ],
  );
}

/// A generated passphrase, with ways to keep it: the one shape both setting
/// up sync and changing the passphrase show it in.
class GeneratedPassphrase extends StatefulWidget {
  const GeneratedPassphrase({
    super.key,
    required this.passphrase,
    required this.saveTextFile,
    required this.enabled,
    required this.onSaving,
    required this.onProblem,
  });

  final String passphrase;
  final TextFileSaver saveTextFile;
  final bool enabled;
  final ValueChanged<bool> onSaving;
  final ValueChanged<String?> onProblem;

  @override
  State<GeneratedPassphrase> createState() => _GeneratedPassphraseState();
}

class _GeneratedPassphraseState extends State<GeneratedPassphrase> {
  bool _copied = false;
  bool _savingFile = false;
  bool _savedFile = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.passphrase));
    if (mounted) setState(() => _copied = true);
  }

  Future<void> _download() async {
    if (_savingFile) return;
    setState(() => _savingFile = true);
    widget.onSaving(true);
    widget.onProblem(null);
    final result = await widget.saveTextFile(
      contents: '${widget.passphrase}\n',
      suggestedName: 'kapy-notes-passphrase.txt',
    );
    if (!mounted) return;
    setState(() {
      _savingFile = false;
      if (result == FileExportOutcome.saved) _savedFile = true;
    });
    widget.onSaving(false);
    if (result == FileExportOutcome.failed ||
        result == FileExportOutcome.unsupported) {
      widget.onProblem('Could not save the file. Copy it instead.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KapyControlSurface(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: SelectableText(
            widget.passphrase,
            key: const ValueKey('generated-passphrase'),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: AppPlatform.monoFontFallback.first,
              fontFamilyFallback: AppPlatform.monoFontFallback,
              fontSize: AppTypeScale.control,
              fontWeight: FontWeight.w500,
              height: 1.6,
              letterSpacing: 0.45,
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
              key: const ValueKey('copy-passphrase'),
              onPressed: widget.enabled ? _copy : null,
              icon: KapyIcon(
                _copied ? KapyIcons.checkRounded : KapyIcons.copyRounded,
                size: AppControlMetrics.iconControl,
              ),
              label: Text(_copied ? 'Copied' : 'Copy'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('download-passphrase'),
              onPressed: widget.enabled && !_savingFile ? _download : null,
              icon: _savingFile
                  ? SizedBox.square(
                      dimension: AppControlMetrics.iconControl,
                      child: const CircularProgressIndicator(strokeWidth: 1.5),
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
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.text, {this.last = false});
  final String text;
  final bool last;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: last ? 0 : 10),
    child: Text(
      text,
      style: TextStyle(
        fontSize: AppTypeScale.body,
        color: context.palette.textSecondary,
        height: 1.45,
      ),
    ),
  );
}
