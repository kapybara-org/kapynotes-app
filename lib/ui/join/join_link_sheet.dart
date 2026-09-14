import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../sync/joining.dart';
import '../../sync/safety.dart';
import '../../sync/sharing.dart';
import '../../sync/spaces.dart';
import '../../sync/sync_api.dart' show SyncRefusedException;
import '../safety_dialogs.dart';
import 'joining_ui.dart';

/// What opening a space's link shows: what the space is, who owns it, what
/// joining would let you do — and then the one thing there is to do about it.
///
/// Nothing is asked until the person chooses to. A preview is a read, and the
/// link might be one they were sent by mistake.
Future<void> showJoinLinkSheet(
  BuildContext context, {
  required String token,
  required Joining joining,
  required Sharing sharing,
}) => showDialog<void>(
  context: context,
  builder: (_) =>
      _JoinLinkSheet(token: token, joining: joining, sharing: sharing),
);

/// Opening an email invitation from its link. The invitation is already in
/// the account's list when it is addressed to this account; when it is not,
/// that is said plainly rather than failing on Accept.
Future<void> showInvitationSheet(
  BuildContext context, {
  required String token,
  required Sharing sharing,
}) => showDialog<void>(
  context: context,
  builder: (_) => _InvitationSheet(token: token, sharing: sharing),
);

/// Runs a sharing action, showing the sharing rules first if the server says
/// they have not been agreed to, and trying once more if they then are.
Future<T?> _withTerms<T>(
  BuildContext context,
  Sharing sharing,
  Future<T> Function() action,
) async {
  try {
    return await action();
  } on SyncRefusedException catch (error) {
    if (error.code != termsRequiredCode || !context.mounted) rethrow;
    final accepted = await showSharingTermsSheet(context, sharing: sharing);
    if (!accepted) return null;
    return action();
  }
}

String _describe(Object error) => switch (error) {
  // Refused on the joiner's side only when the owner's plan no longer covers
  // new people; "this needs Pro" would send the wrong person to pay.
  SyncRefusedException(code: 'pro-required') =>
    "The owner's plan does not cover new people right now.",
  _ => describeSharingError(error),
};

class _JoinLinkSheet extends StatefulWidget {
  const _JoinLinkSheet({
    required this.token,
    required this.joining,
    required this.sharing,
  });

  final String token;
  final Joining joining;
  final Sharing sharing;

  @override
  State<_JoinLinkSheet> createState() => _JoinLinkSheetState();
}

class _JoinLinkSheetState extends State<_JoinLinkSheet> {
  JoinLinkPreview? _preview;
  String? _error;
  String? _notice;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final preview = await widget.joining.preview(widget.token);
      if (mounted) setState(() => _preview = preview);
    } catch (error) {
      if (mounted) setState(() => _error = _describe(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _act(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = _describe(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _ask() => _act(() async {
    final next = await _withTerms(
      context,
      widget.sharing,
      () => widget.joining.ask(widget.token),
    );
    if (next == null || !mounted) return;
    setState(() {
      // A link that needs no asking lets them in at once, but the notes
      // follow only when a device holding the key hands it over.
      if (_preview?.status != JoinStatus.member &&
          next.status == JoinStatus.member) {
        _notice =
            'The notes arrive the next time ${next.ownerShort} or another '
            'member is online.';
      }
      _preview = next;
    });
  });

  Future<void> _acceptInvite(JoinLinkPreview preview) => _act(() async {
    final token = preview.inviteToken;
    if (token == null) return;
    final space = await _withTerms(
      context,
      widget.sharing,
      () => widget.sharing.acceptInvite(token),
    );
    if (space == null || !mounted) return;
    setState(() {
      _preview = preview.withStatus(JoinStatus.member);
      _notice =
          'Joined. Notes appear after ${preview.ownerShort} or another member '
          'syncs.';
    });
  });

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return AlertDialog(
      key: const ValueKey('join-link-sheet'),
      title: const Text('Join a shared space'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (preview == null && _busy)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(child: CircularProgressIndicator.adaptive()),
              )
            else if (preview != null)
              ..._describePreview(preview),
            if (_notice case final notice?) ...[
              const SizedBox(height: 10),
              JoinMessage(notice),
            ],
            if (_error case final error?) ...[
              const SizedBox(height: 10),
              JoinMessage(error, isError: true),
            ],
          ],
        ),
      ),
      actions: _actions(preview),
    );
  }

  List<Widget> _describePreview(JoinLinkPreview p) {
    // The placeholder a note shared by link is given names nothing worth
    // quoting back.
    final named = p.spaceName.trim() != kLinkSpaceName;
    final name = named ? '“${p.spaceName}”' : 'these notes';
    final them = named ? 'notes' : 'them';
    final access = p.role == SpaceRole.viewer
        ? 'You can view $them but cannot edit them.'
        : 'You can view and edit $them.';
    final lines = switch (p.status) {
      JoinStatus.none when !p.approval => [
        '${p.ownerLabel} shares $name with anyone who has this link.',
        access,
      ],
      JoinStatus.none => [
        '${p.ownerLabel} shared $name with this link.',
        access,
        'Request access and wait for approval.',
      ],
      JoinStatus.pending => [
        'Your request to join $name is pending.',
        'Notes appear after ${p.ownerShort} approves it.',
      ],
      JoinStatus.declined => [
        // Also what someone the owner removed sees, who may never have asked,
        // so this cannot say that a request was declined.
        'This link does not let you into $name.',
        'Ask ${p.ownerShort} for an email invitation if needed.',
      ],
      JoinStatus.member => [named ? 'You are in $name.' : 'You are in.'],
      JoinStatus.invited => [
        '${p.ownerShort} already invited you to $name by email.',
        access,
      ],
    };
    return [
      for (final (i, line) in lines.indexed) ...[
        if (i > 0) const SizedBox(height: 8),
        JoinMessage(line),
      ],
    ];
  }

  List<Widget> _actions(JoinLinkPreview? p) {
    final close = TextButton(
      onPressed: () => Navigator.of(context).pop(),
      child: Text(switch (p?.status) {
        JoinStatus.none || JoinStatus.invited => 'Not now',
        _ => 'Done',
      }),
    );
    return [
      close,
      if (p != null && p.status == JoinStatus.none)
        FilledButton(
          key: ValueKey(p.approval ? 'join-link-ask' : 'join-link-join'),
          onPressed: _busy ? null : _ask,
          child: Text(p.approval ? 'Ask to join' : 'Join'),
        ),
      if (p?.status == JoinStatus.invited)
        FilledButton(
          key: const ValueKey('join-link-accept'),
          onPressed: _busy ? null : () => _acceptInvite(p!),
          child: const Text('Accept invitation'),
        ),
    ];
  }
}

class _InvitationSheet extends StatefulWidget {
  const _InvitationSheet({required this.token, required this.sharing});

  final String token;
  final Sharing sharing;

  @override
  State<_InvitationSheet> createState() => _InvitationSheetState();
}

class _InvitationSheetState extends State<_InvitationSheet> {
  bool _busy = true;
  bool _joined = false;
  String? _error;

  PendingInvite? get _invite {
    for (final invite in widget.sharing.invites) {
      if (invite.token == widget.token) return invite;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// Whatever the server knows now: the link may have been opened moments
  /// after the invitation was sent, before this device heard of it.
  Future<void> _load() async {
    try {
      await widget.sharing.refresh();
    } on Object {
      // Offline: the list already here is still worth reading.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _accept() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final space = await _withTerms(
        context,
        widget.sharing,
        () => widget.sharing.acceptInvite(widget.token),
      );
      if (space != null && mounted) setState(() => _joined = true);
    } catch (error) {
      if (mounted) setState(() => _error = _describe(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final invite = _invite;
    final String line;
    if (_joined && invite != null) {
      line =
          'You are in “${invite.spaceName}”. The notes arrive the next time '
          'somebody who is already in it syncs.';
    } else if (_joined) {
      line = 'You are in.';
    } else if (invite != null) {
      line = '${invite.invitedBy} invited you to “${invite.spaceName}”.';
    } else if (_busy) {
      line = '';
    } else {
      line =
          'That invitation is not for the account you are signed in with, '
          'or it has expired. Sign in with the address it was sent to, or ask '
          'for a new one.';
    }
    return AlertDialog(
      key: const ValueKey('invitation-sheet'),
      title: const Text('An invitation'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_busy && invite == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(child: CircularProgressIndicator.adaptive()),
              )
            else
              JoinMessage(line),
            if (_error case final error?) ...[
              const SizedBox(height: 10),
              JoinMessage(error, isError: true),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(invite != null && !_joined ? 'Not now' : 'Done'),
        ),
        if (invite != null && !_joined)
          FilledButton(
            key: const ValueKey('invitation-accept'),
            onPressed: _busy ? null : _accept,
            child: const Text('Accept'),
          ),
      ],
    );
  }
}
