import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../sync/account.dart';
import '../../sync/sharing.dart';
import '../../sync/sync_api.dart' show SyncRefusedException;
import '../../sync/safety.dart';
import '../../sync/spaces.dart';
import '../safety_dialogs.dart';
import '../share_dialog.dart';

/// Shared spaces, in settings: invitations waiting for an answer, a place to
/// paste an invitation code, and every space this account is in.
///
/// A note is shared from the note itself; this pane is where the account's
/// side of it lives — who invited you, what you are in, and the one honest
/// caveat about what "encrypted" means when more than one person holds a key.
class SharingPane extends StatelessWidget {
  const SharingPane({super.key, required this.account});

  final Account account;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: account,
    builder: (context, _) {
      final sharing = account.sharing;
      if (sharing == null) {
        return _Panel(
          title: 'Sharing',
          blurb: switch (account.state) {
            AccountState.signedOut =>
              'Sign in, and unlock your notes, to share them with people.',
            AccountState.needsPassphrase =>
              'Choose an encryption passphrase to start sharing notes.',
            AccountState.locked => 'Unlock your notes to share them.',
            _ => 'Sharing becomes available once your notes are unlocked.',
          },
          children: const [],
        );
      }
      return SharingPaneBody(sharing: sharing);
    },
  );
}

/// The pane's contents, given a [Sharing] directly.
///
/// Public so a test can mount it without standing up a whole signed-in
/// [Account] — the thing worth testing here is what the pane does with
/// invitations and blocks, not the session behind it.
class SharingPaneBody extends StatefulWidget {
  const SharingPaneBody({super.key, required this.sharing});
  final Sharing sharing;

  @override
  State<SharingPaneBody> createState() => _SharingPaneBodyState();
}

class _SharingPaneBodyState extends State<SharingPaneBody> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _message;
  bool _messageIsError = false;

  @override
  void initState() {
    super.initState();
    widget.sharing.addListener(_changed);
    unawaited(_refreshQuietly());
  }

  @override
  void dispose() {
    widget.sharing.removeListener(_changed);
    _code.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshQuietly() async {
    try {
      await widget.sharing.refresh();
    } on Object {
      // Offline: the cached list still shows.
    }
  }

  Future<void> _run(Future<void> Function() action, {String? done}) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await _withTerms(action);
      if (mounted) {
        setState(() {
          _message = done;
          _messageIsError = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _message = describeSharingError(error);
          _messageIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Runs an action, showing the sharing rules first if the server says this
  /// account has not agreed to them. Accepting an invitation is a door into
  /// sharing exactly as sending one is, so it is gated the same way.
  Future<void> _withTerms(Future<void> Function() action) async {
    try {
      await action();
    } on SyncRefusedException catch (error) {
      if (error.code != termsRequiredCode || !mounted) rethrow;
      final accepted = await showSharingTermsSheet(
        context,
        sharing: widget.sharing,
      );
      if (!accepted) return;
      await action();
    }
  }

  /// A pasted invitation: the code on its own, or the whole link.
  static String tokenFrom(String typed) {
    final trimmed = typed.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri != null && uri.pathSegments.length >= 2 && uri.pathSegments.first == 'join') {
      return uri.pathSegments[1];
    }
    return trimmed.split('/').last;
  }

  Future<void> _join() async {
    final token = tokenFrom(_code.text);
    if (token.isEmpty) return;
    await _run(() async {
      final space = await widget.sharing.acceptInvite(token);
      _code.clear();
      _message = 'You are in ${space.displayName}.';
    }, done: 'Joined.');
  }

  @override
  Widget build(BuildContext context) {
    final sharing = widget.sharing;
    final palette = context.palette;
    final invites = sharing.invites;
    final teams = sharing.teams;

    return _Panel(
      title: 'Sharing',
      blurb:
          'Share a note from the note itself — right-click it in the list, '
          'or hover it and choose Share. Spaces you have been invited to, '
          'and the ones you are in, are here.',
      children: [
        const _InfoNote(
          'Shared notes are encrypted on your devices with keys only the '
          'members hold. Our servers store and relay sealed bytes and cannot '
          'read them. Until you have compared a member\'s key fingerprint '
          'with them in person, this protects against a server that only '
          'looks, not one that lies about whose key is whose — the app pins '
          'every member\'s key the first time it sees it and warns if it '
          'changes.',
        ),
        if (invites.isNotEmpty) ...[
          const SizedBox(height: 14),
          _Label('Invitations'),
          for (final invite in invites)
            _InviteRow(
              key: ValueKey('invite-${invite.token}'),
              invite: invite,
              busy: _busy,
              onAccept: () => _run(
                () => sharing.acceptInvite(invite.token),
                done: 'You are in ${invite.spaceName}. The notes arrive once '
                    'a member lets you in.',
              ),
              onDecline: () => _run(() => sharing.declineInvite(invite.token)),
              onBlock: () => _run(
                () => sharing.blockPerson(invite.invitedBy),
                done: 'Blocked ${invite.invitedBy}. They cannot invite you '
                    'again.',
              ),
              onReport: () => showReportDialog(
                context,
                sharing: sharing,
                target: ReportTarget.invitation(
                  token: invite.token,
                  email: invite.invitedBy,
                ),
              ),
            ),
        ],
        const SizedBox(height: 14),
        _Label('Have an invitation link?'),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('join-code'),
                controller: _code,
                enabled: !_busy,
                autocorrect: false,
                enableSuggestions: false,
                onSubmitted: (_) => _busy ? null : _join(),
                style: TextStyle(
                  fontSize: AppTypeScale.control,
                  color: palette.textPrimary,
                ),
                decoration: InputDecoration(
                  hintText: 'Paste the link or its code',
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 11,
                  ),
                  filled: true,
                  fillColor: palette.controlBackground,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(
                      color: palette.controlBorder,
                      width: 0.5,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              key: const ValueKey('join-submit'),
              onPressed: _busy ? null : _join,
              child: const Text('Join'),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _Label('Shared spaces'),
        if (teams.isEmpty)
          Text(
            'None yet. Share a note with someone to start one.',
            style: TextStyle(
              fontSize: AppTypeScale.body,
              color: palette.textTertiary,
            ),
          ),
        for (final team in teams)
          _TeamRow(
            key: ValueKey('space-${team.id}'),
            space: team,
            sharing: sharing,
            onTap: () => showSpaceDialog(
              context,
              spaceId: team.id,
              sharing: sharing,
            ),
          ),
        if (sharing.blocks.isNotEmpty) ...[
          const SizedBox(height: 14),
          _Label('Blocked'),
          for (final block in sharing.blocks)
            Padding(
              key: ValueKey('block-${block.email}'),
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(
                    Icons.block_rounded,
                    size: AppControlMetrics.iconControl,
                    color: palette.textTertiary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      block.email,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppTypeScale.control,
                        color: palette.textSecondary,
                      ),
                    ),
                  ),
                  TextButton(
                    key: ValueKey('unblock-${block.email}'),
                    onPressed: _busy
                        ? null
                        : () => _run(
                            () => sharing.unblockPerson(block.email),
                            done: 'Unblocked ${block.email}.',
                          ),
                    child: const Text('Unblock'),
                  ),
                ],
              ),
            ),
        ],
        const SizedBox(height: 14),
        Text(
          'Something wrong in a shared space? Block the person from their '
          'invitation or from the space, and report it — one person reads '
          'every report, usually within $reportResponseDays working days. You '
          'can also write to $safetyContact.',
          style: TextStyle(
            fontSize: AppTypeScale.small,
            color: palette.textTertiary,
            height: 1.45,
          ),
        ),
        if (_message case final message?) ...[
          const SizedBox(height: 10),
          Text(
            message,
            style: TextStyle(
              fontSize: AppTypeScale.small,
              color: _messageIsError
                  ? Theme.of(context).colorScheme.error
                  : palette.textSecondary,
              height: 1.4,
            ),
          ),
        ],
      ],
    );
  }
}

class _InviteRow extends StatelessWidget {
  const _InviteRow({
    super.key,
    required this.invite,
    required this.busy,
    required this.onAccept,
    required this.onDecline,
    required this.onBlock,
    required this.onReport,
  });

  final PendingInvite invite;
  final bool busy;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final VoidCallback onBlock;
  final VoidCallback onReport;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
      decoration: BoxDecoration(
        color: palette.controlBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.controlBorder, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${invite.invitedBy} invited you to ${invite.spaceName}',
            style: TextStyle(
              fontSize: AppTypeScale.control,
              color: palette.textPrimary,
            ),
          ),
          Row(
            children: [
              // The two quiet ways out sit at the far end from Accept, so the
              // reflex tap is never the irreversible one.
              TextButton(
                key: ValueKey('report-${invite.token}'),
                onPressed: busy ? null : onReport,
                child: const Text('Report'),
              ),
              TextButton(
                key: ValueKey('block-${invite.token}'),
                onPressed: busy ? null : onBlock,
                child: const Text('Block'),
              ),
              const Spacer(),
              TextButton(
                onPressed: busy ? null : onDecline,
                child: const Text('Decline'),
              ),
              FilledButton(
                key: ValueKey('accept-${invite.token}'),
                onPressed: busy ? null : onAccept,
                child: const Text('Accept'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TeamRow extends StatelessWidget {
  const _TeamRow({
    super.key,
    required this.space,
    required this.sharing,
    required this.onTap,
  });

  final Space space;
  final Sharing sharing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final others = space.othersThan(sharing.userId);
    final warnings = sharing.trust.warningsFor(space.id);
    final status = !sharing.holdsKey(space.id)
        ? 'Waiting for someone to let you in'
        : warnings.isNotEmpty
        ? "A member's key changed"
        : others.isEmpty
        ? (space.invites.isEmpty
              ? 'Only you'
              : 'Invited: ${space.invites.map((i) => i.email).join(', ')}')
        : others.map((m) => m.email).join(', ');
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(
          children: [
            Icon(
              warnings.isNotEmpty
                  ? Icons.warning_amber_rounded
                  : Icons.people_outline_rounded,
              size: AppControlMetrics.iconControl,
              color: warnings.isNotEmpty
                  ? Theme.of(context).colorScheme.error
                  : palette.textSecondary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${space.displayName}${space.isOwner ? '' : ' · shared with you'}',
                    style: TextStyle(
                      fontSize: AppTypeScale.control,
                      color: palette.textPrimary,
                    ),
                  ),
                  Text(
                    status,
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
