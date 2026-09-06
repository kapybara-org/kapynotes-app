import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../sync/account.dart';
import '../../sync/recovery_key.dart';
import '../../sync/sync_service.dart';
import 'recovery_key_dialog.dart';

/// Everything about the account, in one settings pane.
///
/// It is a small state machine rather than a form, because "signed in" is not
/// one condition: an account can be signed in and unreadable, or readable and
/// offline, and each of those needs a different sentence and a different next
/// step. Showing one form with disabled bits would hide which.
class SyncPane extends StatelessWidget {
  const SyncPane({super.key, required this.account});

  final Account account;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: account,
      builder: (context, _) => switch (account.state) {
        AccountState.restoring => const _Busy(),
        AccountState.signedOut => _SignInForm(account: account),
        AccountState.needsPassphrase => _PassphraseForm(account: account),
        AccountState.locked => _UnlockForm(account: account),
        AccountState.needsAccountDecision => _AccountSwitch(account: account),
        AccountState.ready => _Ready(account: account),
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
            fontWeight: FontWeight.w600,
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
    this.monospace = false,
    this.keyboardType,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String hint;
  final bool obscure;

  /// For a value that has to be read off the screen and typed somewhere else,
  /// the way the recovery key dialog sets one.
  final bool monospace;
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
          fontFamily: monospace ? AppPlatform.monoFontFallback.first : null,
          fontFamilyFallback: monospace ? AppPlatform.monoFontFallback : null,
          letterSpacing: monospace ? 0.3 : null,
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
  const _InfoNote(this.text);

  final String text;

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
            child: Icon(
              Icons.lock_outline_rounded,
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

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    await action();
    if (mounted) setState(() => _busy = false);
  }

  void _goTo(_SignInStep step, {String? note}) => setState(() {
    _step = step;
    _note = note;
    _code.clear();
  });

  Future<void> _sendSignInCode() => _run(() async {
    if (await widget.account.sendCode(_address) && mounted) {
      _goTo(_SignInStep.code);
    }
  });

  Future<void> _sendResetCode() => _run(() async {
    if (await widget.account.requestPasswordReset(_address) && mounted) {
      _goTo(_SignInStep.resetCode);
    }
  });

  Future<void> _resetPassword() => _run(() async {
    final done = await widget.account.resetPassword(
      email: _address,
      code: _code.text.trim(),
      password: _password.text,
    );
    if (done && mounted) {
      _password.clear();
      _goTo(_SignInStep.password, note: 'Password changed. Sign in with it.');
    }
  });

  @override
  Widget build(BuildContext context) {
    final account = widget.account;
    return _Panel(
      title: _step == _SignInStep.resetRequest || _step == _SignInStep.resetCode
          ? 'Reset your password'
          : 'Sign in',
      blurb: switch (_step) {
        _SignInStep.code =>
          'We sent a six-digit code to $_address. It works once and expires '
              'in ten minutes.',
        _SignInStep.resetCode =>
          'We sent a code to $_address. Enter it with the password you want '
              'from now on.',
        _SignInStep.resetRequest =>
          'We will email you a code. This changes how you sign in — it does '
              'not touch your encryption passphrase, and your notes stay '
              'locked with that.',
        _ =>
          'Sync your notes across your devices. Your notes are encrypted on '
              'this device before they are sent — the server stores them '
              'sealed and cannot read them.',
      },
      children: [
        ..._fields(),
        ..._actions(),
        if (_note != null) _Message(_note!),
        if (account.lastError != null) _Message(account.lastError!),
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
    ),
    _SignInStep.password => _run(
      () => widget.account.signIn(email: _address, password: _password.text),
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

class _PassphraseForm extends StatefulWidget {
  const _PassphraseForm({required this.account});
  final Account account;

  @override
  State<_PassphraseForm> createState() => _PassphraseFormState();
}

class _PassphraseFormState extends State<_PassphraseForm> {
  final _passphrase = TextEditingController();
  final _confirm = TextEditingController();
  String? _problem;
  bool _busy = false;

  /// The generated value, while it is still the thing in the field. Typing
  /// over it clears this, because everything below keys off it — the copy
  /// button, the saved-it gate, and whether the confirm field is worth
  /// showing at all.
  String? _generated;
  bool _copied = false;
  bool _savedIt = false;

  /// Not a password policy, a floor. This key is the only thing between the
  /// notes and anyone holding the ciphertext, and unlike a password nobody
  /// can reset it for you.
  static const int _minimumLength = 10;

  @override
  void initState() {
    super.initState();
    _passphrase.addListener(_onPassphraseChanged);
  }

  @override
  void dispose() {
    _passphrase.removeListener(_onPassphraseChanged);
    _passphrase.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _onPassphraseChanged() {
    if (_generated == null || _passphrase.text == _generated) return;
    // They have taken it over. It is theirs to confirm and remember now.
    setState(() {
      _generated = null;
      _copied = false;
      _savedIt = false;
      _confirm.clear();
    });
  }

  void _generate() {
    final value = generatePassphrase();
    setState(() {
      _generated = value;
      _copied = false;
      _savedIt = false;
      _problem = null;
      _passphrase.text = value;
      // Confirming means retyping thirty-two characters nobody chose, to
      // catch a typo that cannot happen. The field goes away instead.
      _confirm.text = value;
    });
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _passphrase.text));
    if (mounted) setState(() => _copied = true);
  }

  Future<void> _create() async {
    final passphrase = _passphrase.text;
    if (passphrase.length < _minimumLength) {
      setState(() => _problem = 'Use at least $_minimumLength characters.');
      return;
    }
    if (_generated == null && passphrase != _confirm.text) {
      setState(() => _problem = 'Those do not match.');
      return;
    }

    setState(() {
      _problem = null;
      _busy = true;
    });
    final recovery = await widget.account.createPassphrase(passphrase);
    if (!mounted) return;
    setState(() => _busy = false);
    if (recovery == null) {
      setState(
        () => _problem = widget.account.lastError ?? 'That did not work.',
      );
      return;
    }
    await showRecoveryKeyDialog(context, recovery);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final generated = _generated != null;

    return _Panel(
      title: 'Choose an encryption passphrase',
      blurb:
          'This is what your notes are locked with. It never leaves this '
          'device, so nobody — including us — can reset it or read your notes '
          'without it.',
      children: [
        const _InfoNote(
          'Your notes are sealed on this device before any of them are sent, '
          'and this passphrase is the key. We never receive it — which is '
          'what makes "we cannot read your notes" a fact about how sync works '
          'rather than a promise about how we behave.\n\n'
          'The same choice is why there is no reset link. Forget this and '
          'your recovery key, and the notes cannot be opened by anyone.',
        ),
        const SizedBox(height: 12),
        _Field(
          controller: _passphrase,
          hint: 'Passphrase',
          // A generated one has to be readable to be written down.
          obscure: !generated,
          monospace: generated,
          autofocus: true,
        ),
        if (!generated)
          _Field(
            controller: _confirm,
            hint: 'Type it again',
            obscure: true,
            onSubmitted: _busy ? null : _create,
          ),
        if (generated) ...[
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _copy,
                icon: Icon(
                  _copied ? Icons.check_rounded : Icons.copy_rounded,
                  size: AppControlMetrics.iconControl,
                ),
                label: Text(_copied ? 'Copied' : 'Copy'),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: _generate,
                child: const Text('Generate another'),
              ),
            ],
          ),
          CheckboxListTile(
            key: const ValueKey('generated-passphrase-saved'),
            value: _savedIt,
            onChanged: (value) => setState(() => _savedIt = value ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(
              'I have saved this somewhere safe',
              style: TextStyle(
                fontSize: AppTypeScale.body,
                color: palette.textPrimary,
              ),
            ),
          ),
        ] else
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('generate-passphrase'),
              onPressed: _generate,
              child: const Text('Generate a strong one for me'),
            ),
          ),
        const SizedBox(height: 4),
        FilledButton(
          // Generated and unsaved is the one combination that ends with notes
          // nobody can open, so it is the one the button waits on.
          onPressed: _busy || (generated && !_savedIt) ? null : _create,
          child: const Text('Set passphrase'),
        ),
        if (_problem != null) _Message(_problem!),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

class _UnlockForm extends StatefulWidget {
  const _UnlockForm({required this.account});
  final Account account;

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
    final opened = _usingRecoveryKey
        ? await widget.account.unlockWithRecoveryKey(_input.text)
        : await widget.account.unlock(_input.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _problem = opened
          ? null
          : _usingRecoveryKey
          ? 'That recovery key does not open this account.'
          : 'That passphrase does not open this account.';
    });
  }

  @override
  Widget build(BuildContext context) => _Panel(
    title: 'Unlock your notes',
    blurb: _usingRecoveryKey
        ? 'Paste the recovery key you saved when you set up this account.'
        : 'Your notes are on this device but sealed. Enter your passphrase to '
              'open them.',
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
            onPressed: _busy ? null : widget.account.signOut,
            child: const Text('Sign out'),
          ),
        ],
      ),
      // Reachable from here on purpose. Someone who has lost the passphrase
      // and the recovery key can do nothing else with this account, and a
      // delete that first demanded the key would be withheld from precisely
      // the person with no other way out.
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
      title: 'These notes were written before you signed in',
      blurb:
          'They belong to this device, not to $email. Adding them uploads '
          'them to that account. Discarding them removes them from here, and '
          'they are not on any server to get back.',
      children: [
        FilledButton(
          onPressed: () => account.resolveAccountSwitch(keepLocalNotes: true),
          child: Text('Add them to $email'),
        ),
        const SizedBox(height: 6),
        TextButton(
          onPressed: () => account.resolveAccountSwitch(keepLocalNotes: false),
          child: const Text('Discard them'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

class _Ready extends StatelessWidget {
  const _Ready({required this.account});
  final Account account;

  String get _status => switch (account.sync?.status) {
    SyncStatus.syncing => 'Syncing…',
    SyncStatus.offline => 'Offline — will retry',
    SyncStatus.signedOut => 'Session expired — sign in again',
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

  @override
  Widget build(BuildContext context) => _Panel(
    title: account.user?.email ?? 'Signed in',
    blurb: _status,
    children: [
      Row(
        children: [
          FilledButton(
            onPressed: account.isSyncing ? null : () => account.sync?.syncNow(),
            child: const Text('Sync now'),
          ),
          const SizedBox(width: 8),
          TextButton(onPressed: account.signOut, child: const Text('Sign out')),
        ],
      ),
      _Message(
        'Signing out leaves your notes on this device. It only forgets the '
        'key and the session.',
      ),
      _DeleteAccount(account: account),
    ],
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

    final ok = await widget.account.deleteAccount(_typed.text.trim());
    if (!mounted) return;

    if (ok) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _busy = false;
      _problem = widget.account.lastError ?? 'That did not work.';
    });
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
              'This removes the account and everything stored for it: the '
              'synced copy of your notes, their attachments, and the key your '
              'passphrase unlocks.',
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
              'Nobody can undo it, us included — without that key what is on '
              'our servers is unreadable to anyone. The notes on this device '
              'stay where they are.',
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
