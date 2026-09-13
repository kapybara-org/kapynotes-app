import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';

/// Says why a note will not change, or why a new one will not start, and
/// what can be done about it. True if the answer was to go and get Pro.
///
/// The limit is never a dead end, and the words say so first: nothing is
/// deleted, pinning chooses which notes stay editable, and deleting one makes
/// room. Buying is offered wherever this build can sell something, signed in
/// or not — lifting this limit is the one thing Pro does that needs no
/// account.
Future<bool> showNoteLimitDialog(
  BuildContext context, {
  required int limit,
  required bool creating,
  required bool canBuy,
}) async {
  final number = _spelled(limit);
  final title = creating
      ? 'Free keeps up to $number notes'
      : 'This note is read-only on Free';
  final body = creating
      ? 'A new note can be started once you have fewer than $number. Nothing '
            'you have is deleted: delete a note you no longer need to make '
            'room, or get Pro Lifetime for as many as you like.'
      : 'Free keeps $number notes editable: the $number at the top of your '
            'list, pinned ones first. The rest stay here to read, copy, '
            'export or delete, and nothing is deleted.\n\nPin this note to '
            'keep it editable instead of another, or get Pro Lifetime to edit '
            'every note.';

  final answer = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const ValueKey('note-limit-dialog'),
      title: Text(title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Text(
          body,
          style: TextStyle(
            fontSize: AppTypeScale.control,
            color: context.palette.textPrimary,
            height: 1.4,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
        if (canBuy)
          FilledButton(
            key: const ValueKey('note-limit-get-pro'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Get Pro'),
          ),
      ],
    ),
  );
  return answer ?? false;
}

String _spelled(int n) => switch (n) {
  1 => 'one',
  2 => 'two',
  3 => 'three',
  4 => 'four',
  5 => 'five',
  6 => 'six',
  7 => 'seven',
  8 => 'eight',
  9 => 'nine',
  10 => 'ten',
  _ => '$n',
};
