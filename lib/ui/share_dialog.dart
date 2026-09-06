import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../core/toast.dart';
import '../data/note.dart';
import '../sync/sharing.dart';
import '../sync/spaces.dart';
import '../sync/sync_api.dart';
import '../sync/trust.dart';

/// The share sheet for one note.
///
/// A private note is offered two ways in: a person, by email, or a space the
/// account is already in. A shared note shows who else can read it, who is
/// still waiting for the key, and the ways out — back to your own notes, or
/// for the owner, ending the space for everyone.
Future<void> showShareDialog(
  BuildContext context, {
  required Note note,
  required Sharing sharing,
}) => showDialog<void>(
  context: context,
  builder: (context) => _ShareDialog(noteId: note.id, sharing: sharing),
);

/// Managing one shared space from settings, without a note in hand.
Future<void> showSpaceDialog(
  BuildContext context, {
  required String spaceId,
  required Sharing sharing,
}) => showDialog<void>(
  context: context,
  builder: (context) => _ShareDialog(spaceId: spaceId, sharing: sharing),
);

/// One sentence for whatever went wrong, in place of an exception nobody
/// sees.
String describeSharingError(Object error) => switch (error) {
  SyncAuthException() => 'Sign in again to share notes.',
  SyncOutdatedException() => 'Update Kapy Notes to keep sharing.',
  SyncRefusedException(:final code) => switch (code) {
    'already a member' => 'They are already in this space.',
    'too many pending invitations' => 'Too many people are still to accept.',
    'too many invitations today' => 'That is enough invitations for today.',
    'the space is full' => 'This space is full.',
    'quota exceeded' => 'Not enough storage for this.',
    'the new owner does not hold the key yet' =>
      'They have to be let in before they can take over.',
    'no such invitation' => 'That invitation is not for this account, or has expired.',
    'owned-spaces' => 'Hand over or stop sharing your spaces first.',
    _ => 'The server did not allow that.',
  },
  SyncTransientException() =>
    'Could not reach the server. Try again in a moment.',
  SyncProtocolException(:final message) => message,
  _ => 'That did not work.',
};

class _ShareDialog extends StatefulWidget {
  const _ShareDialog({this.noteId, this.spaceId, required this.sharing});

  final String? noteId;
  final String? spaceId;
  final Sharing sharing;

  @override
  State<_ShareDialog> createState() => _ShareDialogState();
}

class _ShareDialogState extends State<_ShareDialog> {
  final _email = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _notice;

  /// The last invitation this dialog sent, so its link can be copied.
  String? _lastInviteToken;

  @override
  void initState() {
    super.initState();
    widget.sharing.addListener(_changed);
    // Whatever another device did since the list was last fetched.
    unawaited(_refreshQuietly());
  }

  @override
  void dispose() {
    widget.sharing.removeListener(_changed);
    _email.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshQuietly() async {
    try {
      await widget.sharing.refresh();
    } on Object {
      // Offline: the cached list is still worth showing.
    }
  }

  /// Read through the store on every build, so a move made while the dialog
  /// is open shows at once.
  Note? get _note =>
      widget.noteId == null ? null : widget.sharing.noteById(widget.noteId!);

  Space? get _space {
    final explicit = widget.spaceId;
    if (explicit != null) return widget.sharing.spaceById(explicit);
    final note = _note;
    return note == null ? null : widget.sharing.spaceOf(note);
  }

  Future<void> _run(Future<void> Function() action, {String? done}) async {
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await action();
      if (mounted && done != null) setState(() => _notice = done);
    } catch (error) {
      if (mounted) setState(() => _error = describeSharingError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _shareWithEmail() async {
    final email = _email.text.trim();
    if (!email.contains('@')) {
      setState(() => _error = 'Enter an email address.');
      return;
    }
    final noteId = widget.noteId;
    await _run(() async {
      if (noteId != null && _space == null) {
        final space = await widget.sharing.shareNoteWith(noteId, email: email);
        final invite = space.invites.where((i) => i.email == email.toLowerCase());
        _lastInviteToken = invite.isEmpty ? null : invite.first.token;
      } else {
        final space = _space!;
        final result = await widget.sharing.invite(space.id, email);
        _lastInviteToken = result.token;
      }
      _email.clear();
    }, done: 'Invitation sent to $email.');
  }

  Future<void> _copyLink(String token) async {
    await Clipboard.setData(
      ClipboardData(text: widget.sharing.inviteLink(token).toString()),
    );
    if (mounted) Toast.show(context, 'Invitation link copied');
  }

  Future<void> _confirm({
    required String title,
    required String body,
    required String action,
    required Future<void> Function() run,
    bool destructive = false,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
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
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                  )
                : null,
            child: Text(action),
          ),
        ],
      ),
    );
    if (ok == true) await _run(run);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final space = _space;
    final sharing = widget.sharing;
    final note = _note;

    return AlertDialog(
      title: Text(
        space == null
            ? 'Share note'
            : widget.noteId == null
            ? space.displayName
            : 'Shared in ${space.displayName}',
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (space == null) ...[
                _Blurb(
                  'Share this note with someone and you both edit the same '
                  'note. It stays encrypted on the way, so only the people '
                  'you share it with can read it.',
                ),
                const SizedBox(height: 14),
                _Label('Share with a person'),
                _EmailRow(
                  controller: _email,
                  busy: _busy,
                  action: 'Share',
                  onSubmit: _shareWithEmail,
                ),
                if (sharing.teams.where(sharing.holdsKey_).isNotEmpty) ...[
                  const SizedBox(height: 14),
                  _Label('Or add it to a space you are already in'),
                  for (final team in sharing.teams)
                    if (sharing.holdsKey(team.id))
                      _SpaceRow(
                        key: ValueKey('share-into-${team.id}'),
                        space: team,
                        userId: sharing.userId,
                        onTap: _busy || note == null
                            ? null
                            : () => _run(
                                () => sharing.shareNote(
                                  note.id,
                                  spaceId: team.id,
                                ),
                                done: 'Shared in ${team.displayName}.',
                              ),
                      ),
                ],
              ] else ...[
                _Members(
                  space: space,
                  sharing: sharing,
                  busy: _busy,
                  onCopyLink: _copyLink,
                  onRemove: (member) => _confirm(
                    title: 'Remove ${member.email}?',
                    body:
                        'They stop receiving changes right away. What they '
                        'already downloaded stays on their devices.',
                    action: 'Remove',
                    destructive: true,
                    run: () => sharing.removeMember(space.id, member.userId),
                  ),
                  onRevoke: (invite) =>
                      _run(() => sharing.revokeInvite(space.id, invite.token)),
                  onTrust: sharing.trustNewKey,
                ),
                if (space.isOwner) ...[
                  const SizedBox(height: 14),
                  _Label('Add someone'),
                  _EmailRow(
                    controller: _email,
                    busy: _busy || !sharing.holdsKey(space.id),
                    action: 'Invite',
                    onSubmit: _shareWithEmail,
                  ),
                ],
                if (_lastInviteToken case final token?) ...[
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => _copyLink(token),
                      icon: Icon(
                        Icons.link_rounded,
                        size: AppControlMetrics.iconControl,
                      ),
                      label: const Text('Copy invitation link'),
                    ),
                  ),
                ],
              ],
              if (_notice case final notice?) ...[
                const SizedBox(height: 10),
                _Message(notice),
              ],
              if (_error case final error?) ...[
                const SizedBox(height: 10),
                _Message(error, isError: true),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (space != null && note != null)
          TextButton(
            key: const ValueKey('unshare-note'),
            onPressed: _busy
                ? null
                : () => _confirm(
                    title: 'Move back to My notes?',
                    body:
                        'The note leaves ${space.displayName} and becomes '
                        'yours alone, under a new key. Others keep what they '
                        'already downloaded.',
                    action: 'Move it',
                    run: () async {
                      await sharing.unshareNote(note.id);
                      if (context.mounted) Navigator.of(context).pop();
                    },
                  ),
            child: const Text('Move to My notes'),
          ),
        if (space != null && space.isOwner)
          TextButton(
            key: const ValueKey('stop-sharing'),
            onPressed: _busy
                ? null
                : () => _confirm(
                    title: 'Stop sharing ${space.displayName}?',
                    body:
                        'Every note in it comes back to your own notes and '
                        'the space ends for everyone. Nothing is deleted.',
                    action: 'Stop sharing',
                    destructive: true,
                    run: () async {
                      await sharing.stopSharing(space.id);
                      if (context.mounted) Navigator.of(context).pop();
                    },
                  ),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Stop sharing'),
          ),
        if (space != null && !space.isOwner)
          TextButton(
            key: const ValueKey('leave-space'),
            onPressed: _busy
                ? null
                : () => _confirm(
                    title: 'Leave ${space.displayName}?',
                    body:
                        'You stop receiving changes. Notes you have not '
                        'synced yet stay with you as your own.',
                    action: 'Leave',
                    destructive: true,
                    run: () async {
                      await sharing.leave(space.id);
                      if (context.mounted) Navigator.of(context).pop();
                    },
                  ),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Leave'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            'Done',
            style: TextStyle(color: palette.textPrimary),
          ),
        ),
      ],
    );
  }
}

extension on Sharing {
  bool holdsKey_(Space space) => holdsKey(space.id);
}

/// Who can read the notes in a space, and where each of them stands.
class _Members extends StatelessWidget {
  const _Members({
    required this.space,
    required this.sharing,
    required this.busy,
    required this.onCopyLink,
    required this.onRemove,
    required this.onRevoke,
    required this.onTrust,
  });

  final Space space;
  final Sharing sharing;
  final bool busy;
  final ValueChanged<String> onCopyLink;
  final ValueChanged<SpaceMember> onRemove;
  final ValueChanged<SpaceInvite> onRevoke;
  final ValueChanged<TrustWarning> onTrust;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final warnings = {
      for (final w in sharing.trust.warningsFor(space.id)) w.userId: w,
    };
    final waiting = !sharing.holdsKey(space.id);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (waiting)
          _Banner(
            icon: Icons.hourglass_top_rounded,
            text:
                'Waiting for someone with access to let you in. The notes '
                'arrive once they have.',
          ),
        for (final warning in warnings.values)
          _Banner(
            icon: Icons.warning_amber_rounded,
            isWarning: true,
            text:
                "${warning.email}'s key changed. If they set up a new "
                'account, compare this fingerprint with them before '
                'trusting it: ${warning.current}',
            action: TextButton(
              onPressed: () => onTrust(warning),
              child: const Text('Trust the new key'),
            ),
          ),
        _Label('People'),
        for (final member in space.members)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(
                  member.isOwner
                      ? Icons.person_rounded
                      : Icons.person_outline_rounded,
                  size: AppControlMetrics.iconControl,
                  color: palette.textSecondary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        member.userId == sharing.userId
                            ? '${member.email} (you)'
                            : member.email,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppTypeScale.control,
                          color: palette.textPrimary,
                        ),
                      ),
                      Text(
                        [
                          if (member.isOwner) 'Owner',
                          if (!member.hasKey)
                            member.x25519Public == null
                                ? 'Has not unlocked yet'
                                : 'Waiting for access',
                        ].join(' · '),
                        style: TextStyle(
                          fontSize: AppTypeScale.caption,
                          color: palette.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (space.isOwner && !member.isOwner)
                  TextButton(
                    key: ValueKey('remove-${member.userId}'),
                    onPressed: busy ? null : () => onRemove(member),
                    child: const Text('Remove'),
                  ),
              ],
            ),
          ),
        for (final invite in space.invites)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(
                  Icons.mail_outline_rounded,
                  size: AppControlMetrics.iconControl,
                  color: palette.textTertiary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        invite.email,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppTypeScale.control,
                          color: palette.textSecondary,
                        ),
                      ),
                      Text(
                        'Invited · not yet accepted',
                        style: TextStyle(
                          fontSize: AppTypeScale.caption,
                          color: palette.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Copy invitation link',
                  onPressed: () => onCopyLink(invite.token),
                  icon: Icon(
                    Icons.link_rounded,
                    size: AppControlMetrics.iconControl,
                  ),
                ),
                if (space.isOwner)
                  TextButton(
                    onPressed: busy ? null : () => onRevoke(invite),
                    child: const Text('Cancel'),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SpaceRow extends StatelessWidget {
  const _SpaceRow({
    super.key,
    required this.space,
    required this.userId,
    required this.onTap,
  });

  final Space space;
  final String userId;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final others = space.othersThan(userId);
    final who = others.isEmpty
        ? (space.invites.isEmpty
              ? 'Nobody else yet'
              : 'Waiting on ${space.invites.map((i) => i.email).join(', ')}')
        : others.map((m) => m.email).join(', ');
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(
          children: [
            Icon(
              Icons.people_outline_rounded,
              size: AppControlMetrics.iconControl,
              color: palette.textSecondary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    space.displayName,
                    style: TextStyle(
                      fontSize: AppTypeScale.control,
                      color: palette.textPrimary,
                    ),
                  ),
                  Text(
                    who,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTypeScale.caption,
                      color: palette.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: AppControlMetrics.iconControl,
              color: palette.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}

class _EmailRow extends StatelessWidget {
  const _EmailRow({
    required this.controller,
    required this.busy,
    required this.action,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final bool busy;
  final String action;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Row(
      children: [
        Expanded(
          child: TextField(
            key: const ValueKey('share-email'),
            controller: controller,
            enabled: !busy,
            autofocus: true,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            enableSuggestions: false,
            onSubmitted: (_) => busy ? null : onSubmit(),
            style: TextStyle(
              fontSize: AppTypeScale.control,
              color: palette.textPrimary,
            ),
            decoration: InputDecoration(
              hintText: 'Their email address',
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
        ),
        const SizedBox(width: 8),
        FilledButton(
          key: ValueKey('share-submit-$action'),
          onPressed: busy ? null : onSubmit,
          child: Text(action),
        ),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.text,
    this.isWarning = false,
    this.action,
  });

  final IconData icon;
  final String text;
  final bool isWarning;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final color = isWarning
        ? Theme.of(context).colorScheme.error
        : palette.textSecondary;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(11, 10, 12, 10),
      decoration: BoxDecoration(
        color: palette.controlBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isWarning ? color.withValues(alpha: 0.5) : palette.controlBorder,
          width: 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(
                  icon,
                  size: AppControlMetrics.iconAdornment,
                  color: color,
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
          if (action case final action?)
            Align(alignment: Alignment.centerRight, child: action),
        ],
      ),
    );
  }
}

class _Blurb extends StatelessWidget {
  const _Blurb(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      fontSize: AppTypeScale.body,
      color: context.palette.textSecondary,
      height: 1.45,
    ),
  );
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: TextStyle(
        fontSize: AppTypeScale.caption,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.4,
        color: context.palette.textTertiary,
      ),
    ),
  );
}

class _Message extends StatelessWidget {
  const _Message(this.text, {this.isError = false});
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
