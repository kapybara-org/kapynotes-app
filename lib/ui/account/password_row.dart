import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../core/toast.dart';
import '../../sync/account.dart';
import '../settings_rows.dart';
import 'encryption_pane.dart' show keyCodeProblemText, maskedEmail;

/// Creates a password, or changes it, without signing this device out.
///
/// Accounts start with emailed codes only. A password is set the way a
/// forgotten one is reset, with a code sent to the address, but from here the
/// reset carries this device's session, so the server ends every session but
/// this one.
class PasswordRow extends StatefulWidget {
  const PasswordRow({super.key, required this.account});

  final Account account;

  @override
  State<PasswordRow> createState() => _PasswordRowState();
}

class _PasswordRowState extends State<PasswordRow> {
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  Future<void> _check() async {
    await widget.account.checkPassword();
    if (mounted) setState(() => _checking = false);
  }

  @override
  Widget build(BuildContext context) {
    final has = widget.account.hasPassword;
    return SettingsRow(
      key: const ValueKey('password-row'),
      title: 'Password',
      subtitle: switch (has) {
        true => 'Signs you in without an emailed code',
        false => 'Not set. You sign in with an emailed code',
        null => _checking ? 'Checking…' : "Couldn't check right now",
      },
      trailing: switch (has) {
        null when _checking => null,
        null => SettingsRowButton(
          key: const ValueKey('password-retry'),
          label: 'Try again',
          onPressed: () {
            setState(() => _checking = true);
            unawaited(_check());
          },
        ),
        final has => SettingsRowButton(
          key: const ValueKey('password'),
          label: has ? 'Change…' : 'Create…',
          onPressed: () => unawaited(
            showDialog<void>(
              context: context,
              builder: (context) =>
                  _PasswordDialog(account: widget.account, creating: !has),
            ),
          ),
        ),
      },
    );
  }
}

String passwordProblemText(PasswordProblem problem) => switch (problem) {
  PasswordProblem.offline => keyCodeProblemText(KeyCodeProblem.offline),
  PasswordProblem.tooSoon => keyCodeProblemText(KeyCodeProblem.tooSoon),
  PasswordProblem.wrongCode => keyCodeProblemText(KeyCodeProblem.wrong),
  PasswordProblem.codeExpired => keyCodeProblemText(KeyCodeProblem.expired),
  PasswordProblem.tooManyTries => keyCodeProblemText(
    KeyCodeProblem.tooManyTries,
  ),
  PasswordProblem.tooShort => 'Use at least 8 characters.',
  PasswordProblem.tooLong => 'Use 128 characters or fewer.',
  PasswordProblem.refused => "Kapy Notes couldn't make that change. Try again.",
};

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({required this.account, required this.creating});

  final Account account;
  final bool creating;

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _code = TextEditingController();
  final _password = TextEditingController();
  bool _codeSent = false;
  bool _busy = false;
  String? _problem;

  String get _email => maskedEmail(widget.account.user?.email ?? '');

  @override
  void dispose() {
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _run(Future<PasswordProblem?> Function() attempt) async {
    setState(() {
      _busy = true;
      _problem = null;
    });
    final problem = await attempt();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _problem = problem == null ? null : passwordProblemText(problem);
    });
  }

  Future<void> _sendCode() => _run(() async {
    final problem = await widget.account.sendPasswordCode();
    if (problem == null) {
      _code.clear();
      _codeSent = true;
    }
    return problem;
  });

  Future<void> _save() => _run(() async {
    final problem = await widget.account.setPassword(
      code: _code.text,
      password: _password.text,
    );
    if (problem == null && mounted) {
      Toast.show(
        context,
        widget.creating ? 'Password created' : 'Password changed',
      );
      Navigator.of(context).pop();
    }
    return problem;
  });

  @override
  Widget build(BuildContext context) {
    final problem = _problem;
    final problemLine = problem == null
        ? null
        : Padding(
            padding: EdgeInsets.only(
              top: _codeSent ? 0 : 10,
              bottom: _codeSent ? 10 : 0,
            ),
            child: Text(
              problem,
              key: const ValueKey('password-problem'),
              style: TextStyle(
                fontSize: AppTypeScale.small,
                color: context.palette.textSecondary,
                height: 1.4,
              ),
            ),
          );
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        scrollable: true,
        title: Text(
          _codeSent
              ? 'Enter the code'
              : widget.creating
              ? 'Create a password'
              : 'Change your password',
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: _codeSent
                ? [
                    _Line(
                      'We sent a 6-digit code to $_email. It works for 10 minutes.',
                    ),
                    ?problemLine,
                    ..._fields(),
                  ]
                : [..._intro(), ?problemLine],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('password-continue'),
            onPressed: _busy ? null : (_codeSent ? _save : _sendCode),
            child: Text(
              !_codeSent
                  ? 'Send code'
                  : widget.creating
                  ? 'Create password'
                  : 'Change password',
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _intro() => [
    _Line(
      widget.creating
          ? "You'll be able to sign in with your email and a password. "
                'Emailed codes keep working too.'
          : 'Your old password stops working.',
    ),
    const _Line(
      'Your other devices will be signed out and will need your passphrase '
      "again. This device stays signed in, and your notes don't change.",
    ),
    _Line("To check it's you, we'll email a code to $_email.", last: true),
  ];

  List<Widget> _fields() => [
    TextField(
      key: const ValueKey('password-code'),
      controller: _code,
      autofocus: true,
      keyboardType: TextInputType.number,
      textInputAction: TextInputAction.next,
      autofillHints: const [AutofillHints.oneTimeCode],
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      maxLength: 6,
      decoration: const InputDecoration(hintText: 'Code', counterText: ''),
    ),
    const SizedBox(height: 8),
    TextField(
      key: const ValueKey('new-password'),
      controller: _password,
      obscureText: true,
      autocorrect: false,
      enableSuggestions: false,
      autofillHints: const [AutofillHints.newPassword],
      decoration: const InputDecoration(hintText: 'New password'),
      onSubmitted: (_) => _busy ? null : _save(),
    ),
    Align(
      alignment: Alignment.centerLeft,
      child: TextButton(
        key: const ValueKey('password-resend'),
        onPressed: _busy ? null : _sendCode,
        child: const Text('Send another code'),
      ),
    ),
  ];
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
