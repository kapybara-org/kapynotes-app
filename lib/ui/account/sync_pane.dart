import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../billing/billing.dart';
import '../../core/file_export.dart';
import '../../core/platform.dart';
import '../../core/text_file_export.dart';
import '../../core/theme.dart';
import '../../core/toast.dart';
import '../../images/image_ingest.dart';
import '../../images/image_picker.dart';
import '../../sync/account.dart';
import '../../sync/recovery_key.dart';
import '../../sync/sync_service.dart';
import 'recovery_key_dialog.dart';
import '../control_surface.dart';
import '../profile_avatar.dart';
import '../billing/pro_sheet.dart';
import '../settings_rows.dart';

/// Everything about the account, in one settings pane.
///
/// It is a small state machine rather than a form, because "signed in" is not
/// one condition: an account can be signed in and unreadable, or readable and
/// offline, and each of those needs a different sentence and a different next
/// step. Showing one form with disabled bits would hide which.
class SyncPane extends StatelessWidget {
  const SyncPane({
    super.key,
    required this.account,
    this.includeDeleteAccount = true,
    this.saveTextFile,
    this.passphraseGenerator,
  });

  final Account account;
  final bool includeDeleteAccount;
  final TextFileSaver? saveTextFile;
  final String Function()? passphraseGenerator;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: account,
      builder: (context, _) => switch (account.state) {
        AccountState.restoring => const _Busy(),
        AccountState.signedOut => _SignInForm(account: account),
        AccountState.needsProfile => _ProfileSetup(account: account),
        AccountState.needsPassphrase => _PassphraseForm(
          account: account,
          saveTextFile: saveTextFile ?? TextFileExport.save,
          passphraseGenerator: passphraseGenerator ?? generatePassphrase,
        ),
        AccountState.locked => _UnlockForm(
          account: account,
          includeDeleteAccount: includeDeleteAccount,
        ),
        AccountState.needsAccountDecision => _AccountSwitch(account: account),
        AccountState.ready => _Ready(
          account: account,
          includeDeleteAccount: includeDeleteAccount,
        ),
      },
    );
  }
}

class _Busy extends StatelessWidget {
  const _Busy();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 40),
    child: Center(
      child: SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    ),
  );
}

/// The shared frame: a sentence saying where things stand, then the controls.
class _Panel extends StatelessWidget {
  const _Panel({
    super.key,
    required this.title,
    required this.blurb,
    required this.children,
  });

  final String title;
  final String blurb;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: AppTypeScale.title,
            fontWeight: FontWeight.w400,
            color: palette.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          blurb,
          style: TextStyle(
            fontSize: AppTypeScale.body,
            color: palette.textSecondary,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 14),
        ...children,
      ],
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    super.key,
    required this.controller,
    required this.hint,
    this.obscure = false,
    this.autofocus = false,
    this.keyboardType,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String hint;
  final bool obscure;

  final bool autofocus;
  final TextInputType? keyboardType;
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        autofocus: autofocus,
        keyboardType: keyboardType,
        autocorrect: false,
        enableSuggestions: false,
        style: TextStyle(
          fontSize: AppTypeScale.control,
          color: palette.textPrimary,
        ),
        onSubmitted: (_) => onSubmitted?.call(),
        decoration: InputDecoration(
          hintText: hint,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 11,
          ),
          filled: true,
          fillColor: palette.controlBackground,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: palette.controlBorder, width: 0.5),
          ),
        ),
      ),
    );
  }
}

/// The one thing on this pane worth stopping to read.
///
/// Set apart from [_Panel]'s blurb rather than folded into it: the blurb says
/// what the field is, and this says what the whole arrangement costs — no
/// reset, no support request, no way back without the recovery key. Somebody
/// who skims past that discovers it at the worst possible moment.
class _InfoNote extends StatelessWidget {
  const _InfoNote(this.text, {super.key, this.icon = KapyIcons.lockRounded});

  final String text;
  final KapyIconData icon;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      padding: const EdgeInsets.fromLTRB(11, 10, 12, 11),
      decoration: BoxDecoration(
        color: palette.controlBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.controlBorder, width: 0.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: KapyIcon(
              icon,
              size: AppControlMetrics.iconAdornment,
              color: palette.textSecondary,
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: AppTypeScale.small,
                color: palette.textSecondary,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Text(
      text,
      style: TextStyle(
        fontSize: AppTypeScale.small,
        color: context.palette.textSecondary,
        height: 1.4,
      ),
    ),
  );
}

// ---------------------------------------------------------------------------

/// What the sign-in form is currently asking for.
///
/// An enum rather than a handful of booleans because the states are exclusive
/// and two of them look almost identical — a six-digit field either signs you
/// in or precedes a new password, and only this says which.
enum _SignInStep { email, code, password, resetRequest, resetCode }

class _SignInForm extends StatefulWidget {
  const _SignInForm({required this.account});
  final Account account;

  @override
  State<_SignInForm> createState() => _SignInFormState();
}

class _SignInFormState extends State<_SignInForm> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();

  _SignInStep _step = _SignInStep.email;
  bool _busy = false;
  String? _note;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  String get _address => _email.text.trim();

  Future<void> _run(
    Future<void> Function() action, {
    required String waiting,
    required String done,
    required String failed,
  }) async {
    setState(() => _busy = true);
    final progress = Toast.showProgress(context, waiting);
    try {
      await action();
      final error = widget.account.lastError;
      if (error == null) {
        progress.success(done);
      } else {
        progress.error(failed);
      }
    } catch (_) {
      progress.error(failed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _goTo(_SignInStep step, {String? note}) => setState(() {
    _step = step;
    _note = note;
    _code.clear();
  });

  Future<void> _sendSignInCode() => _run(
    () async {
      if (await widget.account.sendCode(_address) && mounted) {
        _goTo(_SignInStep.code);
      }
    },
    waiting: 'Sending sign-in code…',
    done: 'Sign-in code sent',
    failed: 'Could not send sign-in code',
  );

  Future<void> _sendResetCode() => _run(
    () async {
      if (await widget.account.requestPasswordReset(_address) && mounted) {
        _goTo(_SignInStep.resetCode);
      }
    },
    waiting: 'Sending reset code…',
    done: 'Reset code sent',
    failed: 'Could not send reset code',
  );

  Future<void> _resetPassword() => _run(
    () async {
      final done = await widget.account.resetPassword(
        email: _address,
        code: _code.text.trim(),
        password: _password.text,
      );
      if (done && mounted) {
        _password.clear();
        _goTo(_SignInStep.password, note: 'Password changed. Sign in with it.');
      }
    },
    waiting: 'Changing password…',
    done: 'Password updated',
    failed: 'Could not change password',
  );

  @override
  Widget build(BuildContext context) {
    return _Panel(
      title: _step == _SignInStep.resetRequest || _step == _SignInStep.resetCode
          ? 'Reset your password'
          : 'Sign in',
      blurb: switch (_step) {
        _SignInStep.code =>
          'Enter the 6-digit code sent to $_address. It expires in 10 minutes.',
        _SignInStep.resetCode =>
          'Enter the code sent to $_address and choose a new password.',
        _SignInStep.resetRequest =>
          'We will email a reset code. Your passphrase and notes will not change.',
        _ => 'Sync encrypted notes across your devices.',
      },
      children: [
        ..._fields(),
        ..._actions(),
        if (_note != null) _Message(_note!),
        if (widget.account.lastError != null)
          _Message(widget.account.lastError!),
      ],
    );
  }

  List<Widget> _fields() => switch (_step) {
    _SignInStep.email || _SignInStep.resetRequest => [
      _Field(
        controller: _email,
        hint: 'Email',
        autofocus: true,
        keyboardType: TextInputType.emailAddress,
        onSubmitted: _busy ? null : _primaryAction,
      ),
    ],
    _SignInStep.password => [
      _Field(
        controller: _email,
        hint: 'Email',
        keyboardType: TextInputType.emailAddress,
      ),
      _Field(
        controller: _password,
        hint: 'Password',
        obscure: true,
        onSubmitted: _busy ? null : _primaryAction,
      ),
    ],
    _SignInStep.code => [
      _Field(
        key: const ValueKey('sign-in-code'),
        controller: _code,
        hint: '6-digit code',
        autofocus: true,
        keyboardType: TextInputType.number,
        onSubmitted: _busy ? null : _primaryAction,
      ),
    ],
    _SignInStep.resetCode => [
      _Field(
        key: const ValueKey('reset-code'),
        controller: _code,
        hint: '6-digit code',
        autofocus: true,
        keyboardType: TextInputType.number,
      ),
      _Field(
        controller: _password,
        hint: 'New password',
        obscure: true,
        onSubmitted: _busy ? null : _primaryAction,
      ),
    ],
  };

  String get _primaryLabel => switch (_step) {
    _SignInStep.email => 'Email me a code',
    _SignInStep.code => 'Sign in',
    _SignInStep.password => 'Sign in',
    _SignInStep.resetRequest => 'Email me a code',
    _SignInStep.resetCode => 'Set new password',
  };

  void _primaryAction() => switch (_step) {
    _SignInStep.email => _sendSignInCode(),
    _SignInStep.resetRequest => _sendResetCode(),
    _SignInStep.resetCode => _resetPassword(),
    _SignInStep.code => _run(
      () => widget.account.signInWithCode(
        email: _address,
        code: _code.text.trim(),
      ),
      waiting: 'Signing in…',
      done: 'Signed in',
      failed: 'Could not sign in',
    ),
    _SignInStep.password => _run(
      () => widget.account.signIn(email: _address, password: _password.text),
      waiting: 'Signing in…',
      done: 'Signed in',
      failed: 'Could not sign in',
    ),
  };

  List<Widget> _actions() => [
    FilledButton(
      onPressed: _busy ? null : _primaryAction,
      child: Text(_primaryLabel),
    ),
    const SizedBox(height: 6),
    Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: switch (_step) {
        _SignInStep.email => [
          TextButton(
            onPressed: _busy ? null : () => _goTo(_SignInStep.password),
            child: const Text('Use a password'),
          ),
        ],
        _SignInStep.password => [
          TextButton(
            onPressed: _busy ? null : () => _goTo(_SignInStep.email),
            child: const Text('Email me a code instead'),
          ),
          TextButton(
            onPressed: _busy ? null : () => _goTo(_SignInStep.resetRequest),
            child: const Text('Forgot password?'),
          ),
        ],
        _SignInStep.code || _SignInStep.resetCode => [
          TextButton(
            onPressed: _busy ? null : () => _goTo(_SignInStep.email),
            child: const Text('Start over'),
          ),
          TextButton(
            onPressed: _busy
                ? null
                : _step == _SignInStep.code
                ? _sendSignInCode
                : _sendResetCode,
            child: const Text('Send another'),
          ),
        ],
        _SignInStep.resetRequest => [
          TextButton(
            onPressed: _busy ? null : () => _goTo(_SignInStep.password),
            child: const Text('Back'),
          ),
        ],
      },
    ),
  ];
}

// ---------------------------------------------------------------------------

class _ProfileSetup extends StatelessWidget {
  const _ProfileSetup({required this.account});

  final Account account;

  @override
  Widget build(BuildContext context) => _Panel(
    title: 'What should people call you?',
    blurb: 'This name appears when you share notes.',
    children: [_ProfileEditor(account: account, firstRun: true)],
  );
}

class _ProfileEditor extends StatefulWidget {
  const _ProfileEditor({
    required this.account,
    this.firstRun = false,
    this.onClose,
  });

  final Account account;
  final bool firstRun;

  /// Set when the editor was opened from the profile card: it then offers a
  /// way back without saving, and closes itself once a save succeeds.
  final VoidCallback? onClose;

  @override
  State<_ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<_ProfileEditor> {
  late final TextEditingController _name;
  bool _busy = false;
  bool _imageChanged = false;
  String? _image;

  @override
  void initState() {
    super.initState();
    final user = widget.account.user;
    _name = TextEditingController(
      text: user?.needsName == true ? '' : (user?.name ?? ''),
    );
    _name.addListener(_changed);
    _image = user?.image;
  }

  @override
  void dispose() {
    _name.removeListener(_changed);
    _name.dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  bool get _valid {
    final clean = _name.text.trim();
    return clean.isNotEmpty && clean.runes.length <= 50;
  }

  Future<void> _pickImage() async {
    final files = AppPlatform.isMobile
        ? await pickExistingImageFiles()
        : await pickImageFiles();
    if (!mounted || files.isEmpty) return;
    final progress = Toast.showProgress(context, 'Preparing profile photo…');
    final prepared = await prepareProfileImageDataUrl(
      await files.first.readAsBytes(),
    );
    if (!mounted) {
      progress.dismiss();
      return;
    }
    if (prepared == null || prepared.length > 140000) {
      progress.error('Could not use that photo');
      return;
    }
    setState(() {
      _image = prepared;
      _imageChanged = true;
    });
    progress.success('Profile photo ready');
  }

  Future<void> _save() async {
    if (_busy || !_valid) return;
    setState(() => _busy = true);
    final progress = Toast.showProgress(context, 'Saving profile…');
    final ok = await widget.account.updateProfile(
      name: _name.text,
      image: _image,
      replaceImage: _imageChanged,
    );
    if (!mounted) {
      progress.dismiss();
      return;
    }
    setState(() {
      _busy = false;
      if (ok) _imageChanged = false;
    });
    if (ok) {
      progress.success(widget.firstRun ? 'Profile created' : 'Profile saved');
      widget.onClose?.call();
    } else {
      progress.error(widget.account.lastError ?? 'Could not save profile');
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.account.user;
    if (user == null) return const SizedBox.shrink();
    final palette = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            ProfileAvatar(
              key: const ValueKey('profile-avatar'),
              seed: user.id,
              name: _name.text.trim().isEmpty ? user.displayName : _name.text,
              image: _image,
              extent: 64,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('choose-profile-photo'),
                    onPressed: _busy ? null : _pickImage,
                    icon: const KapyIcon(KapyIcons.addAPhotoOutlined, size: 17),
                    label: Text(_image == null ? 'Add photo' : 'Change photo'),
                  ),
                  if (_image != null)
                    TextButton(
                      key: const ValueKey('remove-profile-photo'),
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                              _image = null;
                              _imageChanged = true;
                            }),
                      child: const Text('Use default avatar'),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('profile-name'),
          controller: _name,
          autofocus: widget.firstRun,
          maxLength: 50,
          textCapitalization: TextCapitalization.words,
          inputFormatters: [
            LengthLimitingTextInputFormatter(50),
            FilteringTextInputFormatter.deny(RegExp(r'[\u0000-\u001f\u007f]')),
          ],
          decoration: InputDecoration(
            labelText: 'Name',
            helperText: 'Shown to people you share notes with',
            filled: true,
            fillColor: palette.controlBackground,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onSubmitted: (_) => _save(),
        ),
        const SizedBox(height: 4),
        if (widget.onClose case final close?)
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                key: const ValueKey('cancel-profile'),
                onPressed: _busy ? null : close,
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const ValueKey('save-profile'),
                onPressed: _busy || !_valid ? null : _save,
                child: const Text('Save'),
              ),
            ],
          )
        else
          FilledButton(
            key: const ValueKey('save-profile'),
            onPressed: _busy || !_valid ? null : _save,
            child: Text(widget.firstRun ? 'Continue' : 'Save profile'),
          ),
        if (widget.account.lastError case final error?) _Message(error),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

class _PassphraseForm extends StatefulWidget {
  const _PassphraseForm({
    required this.account,
    required this.saveTextFile,
    required this.passphraseGenerator,
  });

  final Account account;
  final TextFileSaver saveTextFile;
  final String Function() passphraseGenerator;

  @override
  State<_PassphraseForm> createState() => _PassphraseFormState();
}

class _PassphraseFormState extends State<_PassphraseForm> {
  late final String _passphrase = widget.passphraseGenerator();
  String? _problem;
  bool _busy = false;
  bool _copied = false;
  bool _savingFile = false;
  bool _savedFile = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _passphrase));
    if (mounted) setState(() => _copied = true);
  }

  Future<void> _download() async {
    if (_savingFile) return;
    setState(() {
      _savingFile = true;
      _problem = null;
    });
    final result = await widget.saveTextFile(
      contents: '$_passphrase\n',
      suggestedName: 'kapy-notes-passphrase.txt',
    );
    if (!mounted) return;
    setState(() {
      _savingFile = false;
      if (result == FileExportOutcome.saved) _savedFile = true;
      if (result == FileExportOutcome.failed ||
          result == FileExportOutcome.unsupported) {
        _problem = 'Could not save the file. Copy it instead.';
      }
    });
  }

  Future<void> _create() async {
    setState(() {
      _problem = null;
      _busy = true;
    });
    final progress = Toast.showProgress(context, 'Finishing setup…');
    final recovery = await widget.account.createPassphrase(_passphrase);
    if (!mounted) {
      progress.dismiss();
      return;
    }
    setState(() => _busy = false);
    if (recovery == null) {
      final message = widget.account.lastError ?? 'That did not work.';
      setState(() => _problem = message);
      progress.error('Could not secure sync');
      return;
    }
    progress.dismiss();
    await showRecoveryKeyDialog(
      context,
      recovery,
      saveTextFile: widget.saveTextFile,
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return _Panel(
      key: const ValueKey('passphrase-setup'),
      title: 'Save your passphrase',
      blurb: 'Use it to unlock your notes on other devices.',
      children: [
        KapyControlSurface(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: SelectableText(
            _passphrase,
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
              onPressed: _busy ? null : _copy,
              icon: KapyIcon(
                _copied ? KapyIcons.checkRounded : KapyIcons.copyRounded,
                size: AppControlMetrics.iconControl,
              ),
              label: Text(_copied ? 'Copied' : 'Copy'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('download-passphrase'),
              onPressed: _busy || _savingFile ? null : _download,
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
        const SizedBox(height: 12),
        FilledButton.icon(
          key: const ValueKey('confirm-passphrase-saved'),
          onPressed: _busy || _savingFile ? null : _create,
          icon: const KapyIcon(KapyIcons.checkRounded),
          label: const Text("I've saved my passphrase"),
        ),
        if (_problem != null) _Message(_problem!),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

class _UnlockForm extends StatefulWidget {
  const _UnlockForm({
    required this.account,
    required this.includeDeleteAccount,
  });
  final Account account;
  final bool includeDeleteAccount;

  @override
  State<_UnlockForm> createState() => _UnlockFormState();
}

class _UnlockFormState extends State<_UnlockForm> {
  final _input = TextEditingController();
  bool _usingRecoveryKey = false;
  bool _busy = false;
  String? _problem;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    setState(() {
      _busy = true;
      _problem = null;
    });
    final progress = Toast.showProgress(context, 'Unlocking notes…');
    final opened = _usingRecoveryKey
        ? await widget.account.unlockWithRecoveryKey(_input.text)
        : await widget.account.unlock(_input.text);
    if (!mounted) {
      if (opened) {
        progress.success('Notes unlocked');
      } else {
        progress.dismiss();
      }
      return;
    }
    final problem = opened
        ? null
        : _usingRecoveryKey
        ? 'That recovery key does not open this account.'
        : 'That passphrase does not open this account.';
    setState(() {
      _busy = false;
      _problem = problem;
    });
    if (opened) {
      progress.success('Notes unlocked');
    } else {
      progress.error('Could not unlock notes');
    }
  }

  @override
  Widget build(BuildContext context) => _Panel(
    title: 'Unlock your notes',
    blurb: _usingRecoveryKey
        ? 'Paste the recovery key saved for this account.'
        : 'Enter your passphrase to unlock notes on this device.',
    children: [
      _Field(
        key: ValueKey(_usingRecoveryKey),
        controller: _input,
        hint: _usingRecoveryKey ? 'Recovery key' : 'Passphrase',
        obscure: !_usingRecoveryKey,
        autofocus: true,
        onSubmitted: _busy ? null : _unlock,
      ),
      const SizedBox(height: 4),
      FilledButton(
        onPressed: _busy ? null : _unlock,
        child: const Text('Unlock'),
      ),
      const SizedBox(height: 6),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                    _usingRecoveryKey = !_usingRecoveryKey;
                    _input.clear();
                    _problem = null;
                  }),
            child: Text(
              _usingRecoveryKey ? 'Use my passphrase' : 'Use my recovery key',
            ),
          ),
          TextButton(
            onPressed: _busy
                ? null
                : () => unawaited(
                    _runAccountAction(
                      context,
                      waiting: 'Signing out…',
                      done: 'Signed out',
                      action: widget.account.signOut,
                    ),
                  ),
            child: const Text('Sign out'),
          ),
        ],
      ),
      // Reachable from here on purpose. Someone who has lost the passphrase
      // and the recovery key can do nothing else with this account, and a
      // delete that first demanded the key would be withheld from precisely
      // the person with no other way out.
      if (widget.includeDeleteAccount)
        _DeleteAccount(account: widget.account, enabled: !_busy),
      if (_problem != null) _Message(_problem!),
    ],
  );
}

// ---------------------------------------------------------------------------

class _AccountSwitch extends StatelessWidget {
  const _AccountSwitch({required this.account});
  final Account account;

  @override
  Widget build(BuildContext context) {
    final email = account.user?.email ?? 'this account';
    return _Panel(
      title: 'Keep the notes already on this device?',
      blurb:
          'Add them to $email to sync them, or discard them from this device. '
          'Discarded notes cannot be recovered.',
      children: [
        FilledButton(
          onPressed: () => unawaited(
            _runAccountAction(
              context,
              waiting: 'Adding notes to this account…',
              done: 'Notes added to this account',
              action: () => account.resolveAccountSwitch(keepLocalNotes: true),
            ),
          ),
          child: const Text('Add and sync'),
        ),
        const SizedBox(height: 6),
        TextButton(
          onPressed: () => unawaited(
            _runAccountAction(
              context,
              waiting: 'Removing local notes…',
              done: 'Local notes removed',
              action: () => account.resolveAccountSwitch(keepLocalNotes: false),
            ),
          ),
          child: const Text('Discard local notes'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

/// Signed in and unlocked: who you are, and the account's few controls.
///
/// The profile is a card with an Edit button rather than a form left open.
/// A name field waiting to be typed into, over a full-width Save, made the
/// pane read as a page to fill in every time it was visited — when a name is
/// set once and the pane is mostly opened to sync, share or sign out.
class _Ready extends StatefulWidget {
  const _Ready({required this.account, required this.includeDeleteAccount});
  final Account account;
  final bool includeDeleteAccount;

  @override
  State<_Ready> createState() => _ReadyState();
}

class _ReadyState extends State<_Ready> {
  bool _editing = false;

  Account get account => widget.account;

  String get _status => account.sync?.personalNeedsPro ?? false
      ? 'Sync paused · Upgrade to Pro to resume'
      : _syncStatus;

  String get _syncStatus => switch (account.sync?.status) {
    SyncStatus.syncing => 'Syncing…',
    SyncStatus.offline => 'Offline. Will retry',
    SyncStatus.signedOut => 'Session expired. Sign in again',
    SyncStatus.failed => account.sync?.lastError ?? 'Sync failed',
    SyncStatus.locked => 'Locked',
    _ => _lastSynced,
  };

  String get _lastSynced {
    final at = account.sync?.lastSyncedAt;
    if (at == null) return 'Not synced yet';
    final ago = DateTime.now().difference(at);
    if (ago.inSeconds < 60) return 'Synced just now';
    if (ago.inMinutes < 60) return 'Synced ${ago.inMinutes}m ago';
    if (ago.inHours < 24) return 'Synced ${ago.inHours}h ago';
    return 'Synced ${ago.inDays}d ago';
  }

  Future<void> _syncNow() async {
    final sync = account.sync;
    if (sync == null) return;
    final progress = Toast.showProgress(context, 'Syncing notes…');
    try {
      // Pressed by a person, so it is worth asking about what is held back
      // once more: Pro may have been bought somewhere this device never heard.
      sync.recheckCoverage();
      await sync.syncNow();
      if (sync.status == SyncStatus.failed ||
          sync.status == SyncStatus.offline) {
        progress.error(sync.lastError ?? 'Could not sync notes');
      } else if (sync.personalNeedsPro) {
        progress.error('Sync is part of Pro');
      } else {
        progress.success('Notes synced');
      }
    } catch (_) {
      progress.error(sync.lastError ?? 'Could not sync notes');
    }
  }

  @override
  Widget build(BuildContext context) {
    final billing = account.billing;
    if (billing == null) return _contents(context, null);
    return ListenableBuilder(
      listenable: billing,
      builder: (context, _) => _contents(context, billing),
    );
  }

  static String _trialLine(int daysLeft) {
    final when = daysLeft == 1 ? 'today' : 'in $daysLeft days';
    return 'Your Pro trial ends $when. Then your account switches to Free. '
        'Sync and sharing stop, and notes after the first five become '
        'read-only. Nothing is deleted.';
  }

  Widget _contents(BuildContext context, Billing? billing) {
    final email = account.user?.email ?? '';
    final trialDays = billing?.trialDaysLeft;
    final needsPro = account.sync?.personalNeedsPro ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_editing)
          SettingsGroup(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: _ProfileEditor(
                  account: account,
                  onClose: () => setState(() => _editing = false),
                ),
              ),
            ],
          )
        else
          _ProfileCard(
            account: account,
            onEdit: () => setState(() => _editing = true),
          ),
        if (trialDays != null) ...[
          const SizedBox(height: 12),
          _InfoNote(
            _trialLine(trialDays),
            key: const ValueKey('sync-trial'),
            icon: KapyIcons.scheduleRounded,
          ),
        ],
        if (billing != null &&
            billing.canPurchase &&
            (needsPro || trialDays != null)) ...[
          const SizedBox(height: 12),
          SettingsNavigationRow(
            key: const ValueKey('sync-get-pro'),
            icon: KapyIcons.verifiedOutlined,
            title: 'Get Pro',
            subtitle: needsPro
                ? 'Restore sync and sharing'
                : 'Keep Pro after your trial',
            onTap: () => unawaited(showProSheet(context, billing: billing)),
          ),
        ],
        const SizedBox(height: 18),
        const SettingsLabel('ACCOUNT'),
        SettingsGroup(
          children: [
            SettingsRow(
              key: const ValueKey('sync-status'),
              icon: KapyIcons.syncRounded,
              title: 'Sync',
              subtitle: _status,
              trailing: SettingsRowButton(
                key: const ValueKey('sync-now'),
                label: 'Sync now',
                onPressed: account.isSyncing
                    ? null
                    : () => unawaited(_syncNow()),
              ),
            ),
            // Who is signed in, beside the way out: the address is the thing
            // somebody checks before they press it. The whole row is not the
            // button, because signing out forgets the key, and a stray click
            // should not cost a passphrase.
            SettingsRow(
              key: const ValueKey('sign-out-row'),
              icon: KapyIcons.logoutRounded,
              title: email.isEmpty ? 'Signed in' : email,
              subtitle: 'Your notes stay on this device',
              trailing: SettingsRowButton(
                key: const ValueKey('sign-out'),
                label: 'Sign out',
                onPressed: () => unawaited(
                  _runAccountAction(
                    context,
                    waiting: 'Signing out…',
                    done: 'Signed out',
                    action: account.signOut,
                  ),
                ),
              ),
            ),
            if (widget.includeDeleteAccount)
              SettingsRow(
                key: const ValueKey('delete-account'),
                icon: KapyIcons.deleteForeverOutlined,
                title: 'Delete account',
                subtitle: 'Permanently delete synced notes',
                destructive: true,
                onTap: () => _confirm(context, account),
              ),
          ],
        ),
      ],
    );
  }
}

/// The name people see, the picture beside it, and the way to change both.
class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.account, required this.onEdit});

  final Account account;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final user = account.user;
    if (user == null) return const SizedBox.shrink();
    final palette = context.palette;
    return SettingsGroup(
      key: const ValueKey('profile-card'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
          child: Row(
            children: [
              ProfileAvatar(
                key: const ValueKey('profile-avatar'),
                seed: user.id,
                name: user.displayName,
                image: user.image,
                extent: 44,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppTypeScale.title,
                        fontWeight: FontWeight.w400,
                        color: palette.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Visible to people you share with',
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: SettingsMetrics.subtitleSize,
                        color: palette.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              SettingsRowButton(
                key: const ValueKey('edit-profile'),
                label: 'Edit',
                onPressed: onEdit,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

/// Account deletion is deliberately the final group in Profile & sync.
///
/// [SyncPane] can still carry the action when it is mounted on its own. The
/// combined settings category turns that copy off and places this after the
/// sharing controls, where a destructive account-wide action belongs.
class DeleteAccountSettings extends StatelessWidget {
  const DeleteAccountSettings({super.key, required this.account});

  final Account account;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: account,
    builder: (context, _) {
      if (account.state != AccountState.ready &&
          account.state != AccountState.locked) {
        return const SizedBox.shrink();
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SettingsLabel('ACCOUNT DELETION'),
          SettingsGroup(
            children: [
              SettingsRow(
                key: const ValueKey('delete-account'),
                icon: KapyIcons.deleteForeverOutlined,
                title: 'Delete account',
                subtitle: 'Permanently delete synced notes',
                destructive: true,
                onTap: () => _confirm(context, account),
              ),
            ],
          ),
        ],
      );
    },
  );
}

// ---------------------------------------------------------------------------

/// The way out of the account entirely, and the last thing in the pane.
///
/// Deliberately quiet — a text button, not a filled one — and deliberately
/// present in every signed-in state. Both stores require it of an app that can
/// create an account, and someone locked out of their own notes has no other
/// move to make.
class _DeleteAccount extends StatelessWidget {
  const _DeleteAccount({required this.account, this.enabled = true});

  final Account account;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton(
      onPressed: enabled ? () => _confirm(context, account) : null,
      style: TextButton.styleFrom(
        foregroundColor: Theme.of(context).colorScheme.error,
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      child: const Text('Delete account'),
    ),
  );
}

Future<void> _confirm(BuildContext context, Account account) =>
    showDialog<void>(
      context: context,
      builder: (context) => _DeleteAccountDialog(account: account),
    );

Future<void> _runAccountAction(
  BuildContext context, {
  required String waiting,
  required String done,
  required Future<void> Function() action,
}) async {
  final progress = Toast.showProgress(context, waiting);
  try {
    await action();
    progress.success(done);
  } catch (_) {
    progress.error('Could not reach the server. Try again.');
  }
}

class _DeleteAccountDialog extends StatefulWidget {
  const _DeleteAccountDialog({required this.account});
  final Account account;

  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  final _typed = TextEditingController();
  bool _busy = false;
  String? _problem;

  @override
  void initState() {
    super.initState();
    // The button enables itself the moment the address matches, so the field
    // has to be listened to rather than read on submit.
    _typed.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  String get _email => widget.account.user?.email ?? '';

  bool get _matches =>
      _typed.text.trim().toLowerCase() == _email.trim().toLowerCase() &&
      _email.isNotEmpty;

  Future<void> _delete() async {
    setState(() {
      _busy = true;
      _problem = null;
    });
    final progress = Toast.showProgress(context, 'Deleting account…');

    final ok = await widget.account.deleteAccount(_typed.text.trim());
    if (!mounted) {
      if (ok) {
        progress.success('Account deleted');
      } else {
        progress.dismiss();
      }
      return;
    }

    if (ok) {
      Navigator.of(context).pop();
      progress.success('Account deleted');
      return;
    }
    final message = widget.account.lastError ?? 'That did not work.';
    setState(() {
      _busy = false;
      _problem = message;
    });
    progress.error('Could not delete account');
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return AlertDialog(
      title: const Text('Delete this account'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'This permanently deletes your account, synced notes, '
              'attachments, and encryption key.',
              style: TextStyle(
                fontSize: AppTypeScale.control,
                color: palette.textPrimary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              // The honest version. Nobody can undo this, and saying so is
              // the same fact the passphrase design has been saying all along.
              'Notes stored on this device stay here. Everything deleted '
              'from the server cannot be recovered.',
              style: TextStyle(
                fontSize: AppTypeScale.control,
                color: palette.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Type $_email to confirm.',
              style: TextStyle(
                fontSize: AppTypeScale.body,
                color: palette.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 8),
            _Field(
              controller: _typed,
              hint: 'Your email address',
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              onSubmitted: _busy || !_matches ? null : _delete,
            ),
            if (_problem != null) _Message(_problem!),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Keep my account'),
        ),
        FilledButton(
          onPressed: _busy || !_matches ? null : _delete,
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          child: Text(_busy ? 'Deleting…' : 'Delete account'),
        ),
      ],
    );
  }
}
