import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../sync/account.dart';
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
  const _Panel({required this.title, required this.blurb, required this.children});

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
            fontSize: 14.5,
            fontWeight: FontWeight.w600,
            color: palette.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          blurb,
          style: TextStyle(fontSize: 12.5, color: palette.textSecondary, height: 1.4),
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
        style: TextStyle(fontSize: 13, color: palette.textPrimary),
        onSubmitted: (_) => onSubmitted?.call(),
        decoration: InputDecoration(
          hintText: hint,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
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

class _Message extends StatelessWidget {
  const _Message(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Text(
      text,
      style: TextStyle(fontSize: 12, color: context.palette.textSecondary, height: 1.4),
    ),
  );
}

// ---------------------------------------------------------------------------

class _SignInForm extends StatefulWidget {
  const _SignInForm({required this.account});
  final Account account;

  @override
  State<_SignInForm> createState() => _SignInFormState();
}

class _SignInFormState extends State<_SignInForm> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _name = TextEditingController();
  bool _creating = false;
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    await action();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final account = widget.account;
    return _Panel(
      title: _creating ? 'Create an account' : 'Sign in',
      blurb: _creating
          ? 'Your notes are encrypted on this device before they are sent. '
                'The server stores them sealed and cannot read them.'
          : 'Sync your notes across your devices.',
      children: [
        if (_creating)
          _Field(controller: _name, hint: 'Your name', autofocus: true),
        _Field(
          controller: _email,
          hint: 'Email',
          autofocus: !_creating,
          keyboardType: TextInputType.emailAddress,
        ),
        _Field(
          controller: _password,
          hint: 'Password',
          obscure: true,
          onSubmitted: _busy ? null : _submit,
        ),
        const SizedBox(height: 4),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(_creating ? 'Create account' : 'Sign in'),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() => _creating = !_creating),
              child: Text(_creating ? 'I have an account' : 'Create an account'),
            ),
            if (!_creating)
              TextButton(
                onPressed: _busy || _email.text.trim().isEmpty
                    ? null
                    : () => _run(
                        () => account.sendMagicLink(_email.text.trim()),
                      ),
                child: const Text('Email me a link'),
              ),
          ],
        ),
        if (account.lastError != null) _Message(account.lastError!),
      ],
    );
  }

  void _submit() => _run(() {
    final email = _email.text.trim();
    final password = _password.text;
    return _creating
        ? widget.account.signUp(
            email: email,
            password: password,
            name: _name.text.trim().isEmpty ? email : _name.text.trim(),
          )
        : widget.account.signIn(email: email, password: password);
  });
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

  /// Not a password policy, a floor. This key is the only thing between the
  /// notes and anyone holding the ciphertext, and unlike a password nobody
  /// can reset it for you.
  static const int _minimumLength = 10;

  @override
  void dispose() {
    _passphrase.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final passphrase = _passphrase.text;
    if (passphrase.length < _minimumLength) {
      setState(() => _problem = 'Use at least $_minimumLength characters.');
      return;
    }
    if (passphrase != _confirm.text) {
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
      setState(() => _problem = widget.account.lastError ?? 'That did not work.');
      return;
    }
    await showRecoveryKeyDialog(context, recovery);
  }

  @override
  Widget build(BuildContext context) => _Panel(
    title: 'Choose an encryption passphrase',
    blurb: 'This is what your notes are locked with. It never leaves this '
        'device, so nobody — including us — can reset it or read your notes '
        'without it.',
    children: [
      _Field(
        controller: _passphrase,
        hint: 'Passphrase',
        obscure: true,
        autofocus: true,
      ),
      _Field(
        controller: _confirm,
        hint: 'Type it again',
        obscure: true,
        onSubmitted: _busy ? null : _create,
      ),
      const SizedBox(height: 4),
      FilledButton(
        onPressed: _busy ? null : _create,
        child: const Text('Set passphrase'),
      ),
      if (_problem != null) _Message(_problem!),
    ],
  );
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
      blurb: 'They belong to this device, not to $email. Adding them uploads '
          'them to that account. Discarding them removes them from here, and '
          'they are not on any server to get back.',
      children: [
        FilledButton(
          onPressed: () =>
              account.resolveAccountSwitch(keepLocalNotes: true),
          child: Text('Add them to $email'),
        ),
        const SizedBox(height: 6),
        TextButton(
          onPressed: () =>
              account.resolveAccountSwitch(keepLocalNotes: false),
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
          TextButton(
            onPressed: account.signOut,
            child: const Text('Sign out'),
          ),
        ],
      ),
      _Message(
        'Signing out leaves your notes on this device. It only forgets the '
        'key and the session.',
      ),
    ],
  );
}
