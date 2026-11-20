import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/toast.dart';
import '../../sync/account.dart';
import '../../sync/auth_api.dart';
import '../settings_rows.dart';

/// Ends the session of every other device on the account, after asking.
///
/// The counterweight to sessions that last a year: a lost phone stays signed
/// in until somebody signs it out, and this is how to do that from here.
class SignOutOthersRow extends StatelessWidget {
  const SignOutOthersRow({super.key, required this.account});

  final Account account;

  @override
  Widget build(BuildContext context) => SettingsRow(
    title: 'Sign out other devices',
    subtitle: 'This device stays signed in',
    trailing: SettingsRowButton(
      key: const ValueKey('sign-out-others'),
      label: 'Sign out others…',
      onPressed: () => unawaited(_confirm(context)),
    ),
  );

  Future<void> _confirm(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out other devices?'),
        content: const Text(
          'Every other device signed in to this account stops syncing until '
          'it signs in again. Notes on those devices stay there.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('sign-out-others-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sign out others'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final progress = Toast.showProgress(context, 'Signing out other devices…');
    switch (await account.signOutOtherDevices()) {
      case RevokeOthers.done:
        progress.success('Other devices signed out');
      case RevokeOthers.sessionEnded:
        progress.error("This device's session has ended. Sign in again.");
      case RevokeOthers.failed:
        progress.error('Couldn’t reach Kapy cloud. Try again.');
    }
  }
}
