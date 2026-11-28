import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/file_export.dart';
import '../../core/platform.dart';
import '../../core/text_file_export.dart';
import '../../core/theme.dart';
import '../../core/toast.dart';
import '../../sync/account.dart';
import '../../sync/device_name.dart';
import '../../sync/key_bundle.dart';
import '../../sync/recovery_key.dart';
import '../../sync/sync_api.dart' show protocolVersion;
import '../control_surface.dart';
import '../editor/editor_context_menu.dart';
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
            if (account.canRestore)
              SettingsRow(
                key: const ValueKey('restore-row'),
                title: 'Notes from before the reset',
                subtitle: switch (account.restorableUntil) {
                  final until? =>
                    'Kept until ${changeDate(until)}. Your old passphrase or '
                        'recovery key brings them back.',
                  null =>
                    'Your old passphrase or recovery key brings them back.',
                },
                trailing: SettingsRowButton(
                  key: const ValueKey('restore'),
                  label: 'Bring back…',
                  onPressed: () => showRestoreDialog(context, account),
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
/// device. Each needs an emailed code, the first recovery key included: a
/// stolen session alone must not be able to put a key in place that its
/// owner never saw.
Future<void> showKeyChangeDialog(
  BuildContext context,
  Account account,
  KeyProofAction action, {
  TextFileSaver? saveTextFile,
  String Function()? passphraseGenerator,
}) async {
  final save = saveTextFile ?? TextFileExport.save;
  final replacesOld = account.hasRecoveryKey || account.recoveryKeyUnsaved;
  // The pane can be rebuilt away while the dialog is open, by the account
  // changing state under it; the new key is still shown, from the root.
  final host = Navigator.of(context, rootNavigator: true).context;
  final made = await showDialog<Object>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _KeyChangeDialog(
      account: account,
      action: action,
      saveTextFile: save,
      passphraseGenerator: passphraseGenerator ?? generatePassphrase,
    ),
  );
  if (made == null || !host.mounted) return;
  final reset = made is PreparedReset ? made : null;
  await showRecoveryKeyDialog(
    host,
    reset?.recoveryKey ?? (made as PreparedRecoveryKey).key,
    saveTextFile: save,
    title: 'Save your new recovery key',
    replacesOld: reset != null || replacesOld,
  );
  if (reset != null) {
    account.resetRecoveryKeySaved(reset);
    if (context.mounted) {
      Toast.show(context, 'Encryption reset. Uploading your notes…');
    }
    return;
  }
  account.recoveryKeySaved(made as PreparedRecoveryKey);
  if (context.mounted) Toast.show(context, 'New recovery key saved');
}

/// Where a device stands after a reset: a build older than [protocolVersion]
/// keeps its notes but cannot sync until it is updated to [release].
String resetDeviceLine(ResetDevice device, String? release, {DateTime? now}) {
  final ago = (now ?? DateTime.now()).difference(device.lastSeenAt);
  final synced = ago.inMinutes < 1
      ? 'synced just now'
      : ago.inHours < 1
      ? 'synced ${ago.inMinutes} min ago'
      : ago.inDays < 1
      ? 'synced ${ago.inHours} ${ago.inHours == 1 ? 'hour' : 'hours'} ago'
      : 'synced ${ago.inDays} ${ago.inDays == 1 ? 'day' : 'days'} ago';
  final protocol = device.protocol;
  if (release == null || protocol == null || protocol >= protocolVersion) {
    return synced;
  }
  return '$synced · needs Kapy Notes $release to sync after a reset';
}

String resetDeviceName(ResetDevice device) =>
    device.name ??
    switch (device.platform) {
      'macos' => 'A Mac',
      'windows' => 'A Windows PC',
      'ios' => 'An iPhone or iPad',
      'android' => 'An Android device',
      _ => 'Another device',
    };

enum _Step { first, explain, intro, code, passphrase }

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

  late _Step _step = _resets ? _Step.first : _Step.intro;
  String? _proof;
  Object? _prepared;
  ResetPreview? _preview;

  bool get _resets => widget.action == KeyProofAction.reset;

  @override
  void initState() {
    super.initState();
    if (_resets) unawaited(_loadPreview());
  }

  Future<void> _loadPreview() async {
    final preview = await widget.account.resetPreview();
    if (!mounted) return;
    setState(() {
      _preview = preview;
      _problem = preview == null ? _offline : null;
    });
  }

  String? _problem;
  bool _busy = false;
  bool _savingFile = false;

  bool get _changesPassphrase =>
      widget.action == KeyProofAction.passphrase || _resets;

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
    final prepared = _prepared ??= _resets
        ? await account.prepareReset(_passphrase)
        : _changesPassphrase
        ? await account.preparePassphrase(_passphrase)
        : await account.prepareRecoveryKey();
    final result = switch (prepared) {
      PreparedReset() => await account.commitReset(prepared, proof: _proof!),
      PreparedKeyChange() => await account.commitKeyChange(
        prepared,
        proof: _proof,
      ),
      _ => const KeyChangeRefused(),
    };
    if (!mounted) return;
    switch (result) {
      case KeyChangeDone():
        if (prepared is PreparedPassphrase) {
          Toast.show(context, 'Passphrase changed');
        }
        Navigator.of(
          context,
        ).pop(prepared is PreparedPassphrase ? null : prepared);
      case KeyChangeNeedsCode():
        setState(() {
          _proof = null;
          _code.clear();
          _step = _Step.code;
          _problem = keyCodeProblemText(KeyCodeProblem.expired);
        });
      case KeyChangeLostRace(:final change, :final byReset) when _resets:
        setState(
          () => _problem = byReset
              ? 'Encryption was just reset on ${changeDevice(change)}, so '
                    'nothing was reset here. Enter the new passphrase.'
              : 'Your passphrase was just changed on ${changeDevice(change)}, '
                    'so nothing was reset. Try the new passphrase.',
        );
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
      _Step.first => _first(),
      _Step.explain => _explain(),
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

  Widget _next(VoidCallback? onPressed, String label) => FilledButton(
    key: const ValueKey('key-change-continue'),
    onPressed: _busy ? null : onPressed,
    child: Text(label),
  );

  (String, List<Widget>, List<Widget>) _first() {
    final preview = _preview;
    final devices = preview?.devices ?? const <ResetDevice>[];
    return (
      'Try these first',
      [
        const _Line(
          'Resetting is the last resort. Your notes are safe either way.',
        ),
        if (devices.isNotEmpty) ...[
          const _Line(
            'If Kapy Notes is still open on one of these, change your '
            'passphrase there instead. No reset needed:',
          ),
          SettingsGroup(
            children: [
              for (final device in devices)
                SettingsRow(
                  title: resetDeviceName(device),
                  subtitle: resetDeviceLine(device, preview?.release),
                ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        const _Line(
          'Look for your recovery key: a file named '
          'kapy-notes-recovery-key.txt, or wherever you wrote it down.',
          last: true,
        ),
      ],
      [
        _cancel(),
        _next(
          preview == null
              ? () => _run(_loadPreview)
              : () => setState(() => _step = _Step.explain),
          'Continue',
        ),
      ],
    );
  }

  (String, List<Widget>, List<Widget>) _explain() {
    final preview = _preview!;
    final missing = widget.account.notesOnlyOnServer(preview);
    final kind = thisDeviceKind;
    return (
      'What a reset does',
      [
        _Line(
          "On this $kind: every note stays. They're uploaded again under "
          'your new passphrase.',
        ),
        const _Line(
          'On your other devices: their notes stay too. Each asks once for '
          'the new passphrase or recovery key, then adds its notes back.',
        ),
        if (preview.release != null &&
            preview.devices.any(
              (d) => d.protocol != null && d.protocol! < protocolVersion,
            ))
          _Line(
            'A device on an older version keeps its notes, and syncs again '
            'once it has Kapy Notes ${preview.release} or later.',
          ),
        const _Line(
          'Shared notes: you stay in every shared space. The people you '
          'share with see that you reset, and their app gives you access '
          'again the next time it syncs.',
        ),
        if (preview.orphanedSpaces.isNotEmpty)
          _Line(
            "In a space where nobody else can give you access, this $kind "
            'gives it a new key. Notes there that aren\'t on this $kind '
            "can't be read after a reset.",
          ),
        if (missing > 0)
          _Line(
            '${missing == 1 ? '1 note is' : '$missing notes are'} on the '
            'Kapy cloud but not on this $kind. If another device has them, they '
            'come back when you unlock it. If none does, they can\'t be read '
            "after a reset. You'll have 30 days to bring them back if you "
            'find your old passphrase or recovery key.',
          ),
        const _Line("Your account, plan and purchases don't change."),
        _Line("To check it's you, we'll email a code to $_email.", last: true),
      ],
      [
        TextButton(
          onPressed: _busy ? null : () => setState(() => _step = _Step.first),
          child: const Text('Back'),
        ),
        _next(_sendCode, 'Send code'),
      ],
    );
  }

  (String, List<Widget>, List<Widget>) _intro() {
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
          )
        else
          const _Line(
            'Your current recovery key will stop working. Your passphrase, '
            "your notes and your other devices aren't affected.",
          ),
        _Line("To check it's you, we'll email a code to $_email.", last: true),
      ],
      [
        _cancel(),
        FilledButton(
          key: const ValueKey('key-change-continue'),
          onPressed: _busy ? null : _sendCode,
          child: const Text('Send code'),
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
        contextMenuBuilder: kapyTextFieldMenu,
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
        child: Text(_resets ? 'Reset encryption' : 'Change passphrase'),
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
            contextMenuBuilder: kapyTextFieldMenu,
            widget.passphrase,
            key: const ValueKey('generated-passphrase'),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: AppPlatform.monoFontFallback.first,
              fontFamilyFallback: AppPlatform.monoFontFallback,
              fontSize: AppTypeScale.control,
              fontWeight: AppWeight.font(AppWeight.rowTitle),
              fontVariations: AppWeight.wght(AppWeight.rowTitle),
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

/// Brings back the notes from before a reset, with the passphrase or
/// recovery key that opened them then.
Future<void> showRestoreDialog(BuildContext context, Account account) async {
  final host = Navigator.of(context, rootNavigator: true).context;
  final done = await showDialog<RestoreDone>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _RestoreDialog(account: account),
  );
  if (done == null) return;
  final target = context.mounted ? context : host;
  if (!target.mounted) return;
  final count = done.added + done.changed;
  Toast.show(target, switch (count) {
    0 => 'Every note from before the reset is already here',
    1 => 'Brought back 1 note',
    _ => 'Brought back $count notes',
  });
}

class _RestoreDialog extends StatefulWidget {
  const _RestoreDialog({required this.account});
  final Account account;

  @override
  State<_RestoreDialog> createState() => _RestoreDialogState();
}

class _RestoreDialogState extends State<_RestoreDialog> {
  final _secret = TextEditingController();
  bool _busy = false;
  String? _problem;

  @override
  void dispose() {
    _secret.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    final typed = _secret.text.trim();
    if (typed.isEmpty) return;
    setState(() {
      _busy = true;
      _problem = null;
    });
    final result = await widget.account.restoreFromArchive(typed);
    if (!mounted) return;
    if (result is RestoreDone) {
      Navigator.of(context).pop(result);
      return;
    }
    setState(() {
      _busy = false;
      _problem = switch (result) {
        RestoreWrongKey() =>
          "That doesn't open the notes from before the reset. Check it and "
              'try again.',
        RestoreGone() => 'The notes from before the reset are no longer kept.',
        RestoreLocked() =>
          "The notes from before the reset can't be read until sync is "
              'unlocked on this device.',
        RestoreOffline() => _offline,
        RestoreRefused() || RestoreDone() => _refused,
      };
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: const Text('Bring back notes from before the reset'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Line(
              'Enter the passphrase or recovery key you used before the '
              "reset. Notes you've deleted since stay deleted.",
            ),
            TextField(
              key: const ValueKey('restore-secret'),
              contextMenuBuilder: kapyTextFieldMenu,
              controller: _secret,
              autofocus: true,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              enabled: !_busy,
              decoration: const InputDecoration(
                hintText: 'Old passphrase or recovery key',
              ),
              onSubmitted: (_) => _busy ? null : _restore(),
            ),
            if (_problem != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  _problem!,
                  key: const ValueKey('restore-problem'),
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
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('restore-confirm'),
          onPressed: _busy ? null : _restore,
          child: const Text('Bring back'),
        ),
      ],
    ),
  );
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
