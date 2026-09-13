import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../sync/account.dart';
import '../../sync/joining.dart';

/// Makes the account's [Joining] reachable from anywhere under the app,
/// dialogs included.
///
/// Sits in `MaterialApp.builder`, above the Navigator, because a dialog's
/// route is built in the Navigator's overlay and cannot see anything placed
/// inside the home screen. Rebuilds its readers when the account changes,
/// since signing in and out is what creates and drops [Joining].
class JoiningScope extends InheritedNotifier<Listenable> {
  /// The app's scope: follows the account, which signing in and out changes.
  JoiningScope({super.key, required Account? account, required super.child})
    : _read = (() => account?.joining),
      super(notifier: account);

  /// A fixed service, for a test or anything else that already holds one.
  JoiningScope.value({
    super.key,
    required Joining? joining,
    required super.child,
  }) : _read = (() => joining),
       super(notifier: null);

  final Joining? Function() _read;

  /// The joining service, or null while signed out or with no scope above.
  static Joining? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<JoiningScope>()?._read();

  @override
  bool updateShouldNotify(JoiningScope oldWidget) =>
      !identical(oldWidget._read(), _read()) ||
      super.updateShouldNotify(oldWidget);
}

/// A small heading in a sharing sheet, as the share dialog draws its own.
class JoinLabel extends StatelessWidget {
  const JoinLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: TextStyle(
        fontSize: AppTypeScale.caption,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.4,
        color: context.palette.textTertiary,
      ),
    ),
  );
}

/// A line of explanation, or of error, under a sharing control.
class JoinMessage extends StatelessWidget {
  const JoinMessage(this.text, {super.key, this.isError = false});
  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      fontSize: AppTypeScale.small,
      color: isError
          ? Theme.of(context).colorScheme.error
          : context.palette.textSecondary,
      height: 1.4,
    ),
  );
}

/// What a batch did, as one short paragraph: how many went, and then only
/// the exceptions, named, so a typo is findable and a success is not a list.
String describeBatch(List<BatchInviteResult> results) {
  final sent = results.where((r) => r.sent).toList();
  final already = [
    for (final r in results)
      if (r.outcome == BatchInviteOutcome.alreadyMember) r.email,
  ];
  final invalid = [
    for (final r in results)
      if (r.outcome == BatchInviteOutcome.invalid) r.email,
  ];
  final unsent = [
    for (final r in sent)
      if (!r.emailed) r.email,
  ];

  final parts = <String>[
    if (sent.length == 1)
      'Invited ${sent.single.email}.'
    else if (sent.isNotEmpty)
      'Invited ${sent.length} people.',
    if (already.length == 1)
      '${already.single} is already in this space.'
    else if (already.isNotEmpty)
      '${already.length} are already in this space.',
    if (invalid.isNotEmpty)
      '${_list(invalid)} ${invalid.length == 1 ? 'does' : 'do'} not look '
          'like ${invalid.length == 1 ? 'an email address' : 'email addresses'}.',
    if (unsent.isNotEmpty)
      'The email to ${_list(unsent)} did not go out; copy their link from the '
          'list and send it yourself.',
  ];
  return parts.isEmpty ? 'Nobody was invited.' : parts.join(' ');
}

String _list(List<String> items) {
  if (items.length == 1) return items.single;
  if (items.length == 2) return '${items.first} and ${items.last}';
  return '${items.take(items.length - 1).join(', ')} and ${items.last}';
}

/// The name a new space gets when a note is shared with several people at
/// once. Follows the "With priya" of a two-person space, and keeps going.
String groupSpaceName(List<String> emails) {
  final names = [
    for (final e in emails) e.split('@').first.isEmpty ? e : e.split('@').first,
  ];
  if (names.length <= 3) return 'With ${_list(names)}';
  return 'With ${names.take(2).join(', ')} and ${names.length - 2} others';
}
