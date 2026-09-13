import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../core/toast.dart';
import '../../sync/account.dart';
import '../../sync/sharing.dart';
import '../../sync/sync_api.dart' show SyncRefusedException;
import '../../sync/safety.dart';
import '../../sync/spaces.dart';
import '../member_avatars.dart';
import '../../sync/joining.dart';
import '../join/join_link_sheet.dart';
import '../join/joining_ui.dart';
import '../safety_dialogs.dart';
import '../settings_rows.dart';
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
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SettingsLabel('SHARING'),
            SettingsGroup(
              children: [
                SettingsRow(
                  icon: KapyIcons.peopleOutlined,
                  title: switch (account.state) {
                    AccountState.signedOut =>
                      'Sign in, and unlock your notes, to share them with '
                          'people.',
                    AccountState.needsProfile =>
                      'Finish your profile before sharing notes.',
                    AccountState.needsPassphrase =>
                      'Save your passphrase to start sharing notes.',
                    AccountState.locked => 'Unlock your notes to share them.',
                    _ =>
                      'Sharing becomes available once your notes are '
                          'unlocked.',
                  },
                ),
              ],
            ),
          ],
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
    widget.sharing.presenceChanges.addListener(_changed);
    unawaited(_refreshQuietly());
  }

  @override
  void dispose() {
    widget.sharing.removeListener(_changed);
    widget.sharing.presenceChanges.removeListener(_changed);
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

  Future<void> _run(
    Future<void> Function() action, {
    String waiting = 'Updating sharing…',
    String? done,
  }) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    var progress = Toast.showProgress(context, waiting);
    var progressActive = true;
    try {
      try {
        await action();
      } on SyncRefusedException catch (error) {
        if (error.code != termsRequiredCode || !mounted) rethrow;

        // Reading or declining the rules is not work in progress. Keep the
        // pane disabled, but stop the spinner until acceptance resumes the
        // server action.
        progress.dismiss();
        progressActive = false;
        final accepted = await showSharingTermsSheet(
          context,
          sharing: widget.sharing,
        );
        if (!accepted || !mounted) return;
        progress = Toast.showProgress(context, waiting);
        progressActive = true;
        await action();
      }
      if (mounted) {
        setState(() {
          _message = done;
          _messageIsError = false;
        });
        progress.success('Sharing updated');
      } else {
        progress.dismiss();
      }
    } catch (error) {
      final message = describeSharingError(error);
      if (mounted) {
        setState(() {
          _message = message;
          _messageIsError = true;
        });
        if (progressActive) {
          progress.error('Sharing failed');
        } else {
          Toast.show(context, 'Sharing failed', isError: true);
        }
      } else {
        progress.dismiss();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A pasted invitation: the code on its own, or the whole link.
  static String tokenFrom(String typed) {
    final trimmed = typed.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri != null &&
        uri.pathSegments.length >= 2 &&
        uri.pathSegments.first == 'join') {
      return uri.pathSegments[1];
    }
    return trimmed.split('/').last;
  }

  Future<void> _join() async {
    // A space's link asks the owner rather than joining outright, so it opens
    // the sheet that says what the space is before anything is asked.
    final target = parseJoinTarget(_code.text);
    if (target is SpaceLinkTarget) {
      final joining = JoiningScope.of(context);
      if (joining == null) return;
      _code.clear();
      await showJoinLinkSheet(
        context,
        token: target.token,
        joining: joining,
        sharing: widget.sharing,
      );
      return;
    }
    final token = target?.token ?? tokenFrom(_code.text);
    if (token.isEmpty) return;
    await _run(() async {
      final space = await widget.sharing.acceptInvite(token);
      _code.clear();
      final title = space.titleFor(widget.sharing.userId);
      _message = space.chosenName == null ? '$title.' : 'You are in $title.';
    }, done: 'Joined.');
  }

  @override
  Widget build(BuildContext context) {
    final sharing = widget.sharing;
    final palette = context.palette;
    final invites = sharing.invites;
    final teams = sharing.teams;

    // One card for everything you can act on — what is waiting for an
    // answer, what you are in, and the way into another — with the reading
    // underneath it. It used to open on two paragraphs and a boxed third
    // before the first thing that could be pressed.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsLabel('SHARING'),
        SettingsGroup(
          key: const ValueKey('sharing-group'),
          children: [
            for (final invite in invites)
              _InviteRow(
                key: ValueKey('invite-${invite.token}'),
                invite: invite,
                busy: _busy,
                onAccept: () => _run(
                  () => sharing.acceptInvite(invite.token),
                  done:
                      'You are in. The notes arrive once '
                      '${invite.inviterDisplayName} or another member lets '
                      'you in.',
                ),
                onDecline: () =>
                    _run(() => sharing.declineInvite(invite.token)),
                onBlock: () => _run(
                  () => sharing.blockPerson(invite.invitedBy),
                  done:
                      'Blocked ${invite.inviterDisplayName}. They cannot '
                      'invite you again.',
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
            if (teams.isEmpty)
              const SettingsRow(
                icon: KapyIcons.peopleOutlined,
                title: 'No shared spaces',
                subtitle: 'None yet. Share a note with someone to start one.',
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
            _JoinRow(controller: _code, busy: _busy, onJoin: _join),
          ],
        ),
        if (_message case final message?)
          Padding(
            padding: const EdgeInsets.fromLTRB(3, 8, 3, 0),
            child: Text(
              message,
              style: TextStyle(
                fontSize: AppTypeScale.small,
                color: _messageIsError
                    ? Theme.of(context).colorScheme.error
                    : palette.textSecondary,
                height: 1.4,
              ),
            ),
          ),
        SettingsNote(
          AppPlatform.hasPointer
              ? 'To share a note, open it and use the people button at the '
                    'top, or right-click it in the list.'
              : 'To share a note, open it and use the people button at the '
                    'top, or long-press it in the list.',
        ),
        if (sharing.blocks.isNotEmpty) ...[
          const SizedBox(height: 18),
          const SettingsLabel('BLOCKED'),
          SettingsGroup(
            children: [
              for (final block in sharing.blocks)
                SettingsRow(
                  key: ValueKey('block-${block.email}'),
                  icon: KapyIcons.blockedRounded,
                  title: block.email,
                  trailing: SettingsRowButton(
                    key: ValueKey('unblock-${block.email}'),
                    label: 'Unblock',
                    onPressed: _busy
                        ? null
                        : () => _run(
                            () => sharing.unblockPerson(block.email),
                            done: 'Unblocked ${block.email}.',
                          ),
                  ),
                ),
            ],
          ),
        ],
        const SizedBox(height: 14),
        // The one honest caveat about what "encrypted" means when more than
        // one person holds a key. Kept in full and on the pane, not behind a
        // tap — but under the controls, where it no longer stands between
        // somebody and the thing they came to do.
        const SettingsNote(
          'Shared notes are encrypted on your devices with keys only the '
          'members hold. Our servers store and relay sealed bytes and cannot '
          'read them. Until you have compared a member\'s key fingerprint '
          'with them in person, this protects against a server that only '
          'looks, not one that lies about whose key is whose. The app pins '
          'every member\'s key the first time it sees it and warns if it '
          'changes.',
          icon: KapyIcons.lockRounded,
        ),
        const SettingsNote(
          'Something wrong in a shared space? Block the person from their '
          'invitation or from the space, and report it. One person reads '
          'every report, usually within $reportResponseDays working days. You '
          'can also write to $safetyContact.',
          icon: KapyIcons.flagOutlined,
        ),
      ],
    );
  }
}

/// Where a pasted invitation goes in: a field and a button, as a row of the
/// card, since joining is one more way into a shared space.
class _JoinRow extends StatelessWidget {
  const _JoinRow({
    required this.controller,
    required this.busy,
    required this.onJoin,
  });

  final TextEditingController controller;
  final bool busy;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: SettingsMetrics.padding,
      child: Row(
        children: [
          SizedBox(
            width: SettingsMetrics.iconSlot,
            child: KapyIcon(
              KapyIcons.linkRounded,
              size: SettingsMetrics.iconSize,
              color: palette.textSecondary,
            ),
          ),
          SizedBox(width: SettingsMetrics.gap),
          Expanded(
            child: TextField(
              key: const ValueKey('join-code'),
              controller: controller,
              enabled: !busy,
              autocorrect: false,
              enableSuggestions: false,
              onSubmitted: (_) => busy ? null : onJoin(),
              style: TextStyle(
                fontSize: AppTypeScale.control,
                color: palette.textPrimary,
              ),
              decoration: InputDecoration(
                hintText: 'Invitation link or code',
                hintStyle: TextStyle(
                  fontSize: AppTypeScale.control,
                  color: palette.textTertiary,
                ),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                filled: true,
                fillColor: palette.surfaceBackground,
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                    color: palette.controlBorder,
                    width: 0.5,
                  ),
                ),
                disabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                    color: palette.controlBorder,
                    width: 0.5,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                    color: palette.selectedBorder,
                    width: 0.75,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SettingsRowButton(
            key: const ValueKey('join-submit'),
            label: 'Join',
            prominent: true,
            onPressed: busy ? null : onJoin,
          ),
        ],
      ),
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
    // The words line up with every other row in the card; the buttons take
    // the row's whole width, which four of them need on a phone.
    return Padding(
      padding: EdgeInsets.fromLTRB(SettingsMetrics.padding.left, 10, 8, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: SettingsMetrics.iconSlot,
                child: KapyIcon(
                  KapyIcons.mailOutlined,
                  size: SettingsMetrics.iconSize,
                  color: palette.textSecondary,
                ),
              ),
              SizedBox(width: SettingsMetrics.gap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      invite.hasGeneratedSpaceName
                          ? '${invite.inviterDisplayName} invited you to '
                                'share notes'
                          : '${invite.inviterDisplayName} invited you to '
                                '${invite.spaceName}',
                      style: TextStyle(
                        fontSize: AppTypeScale.control,
                        color: palette.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    // The address stays on an invitation, and only here: it
                    // comes from somebody you may not know yet, and a name is
                    // only what they call themselves. The address is the part
                    // that was verified.
                    Text(
                      [
                        if (invite.invitedByName != null) invite.invitedBy,
                        '${invite.role.accessLabel} access',
                      ].join(' · '),
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
            ],
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
    final people = space.peopleExcept(sharing.userId);
    final warnings = sharing.trust.warningsFor(space.id);
    final detail = sharing.needsPro(space.id)
        ? (space.isOwner
              ? 'Paused until you have Pro'
              : 'Paused until you or its owner has Pro')
        : !sharing.holdsKey(space.id)
        ? 'Waiting for someone to let you in'
        : warnings.isNotEmpty
        ? "A member's key changed"
        : people.isEmpty
        ? 'Only you'
        : [
            for (final person in people)
              person.isInvited ? '${person.name} (invited)' : person.fullName,
          ].join(', ');
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: SettingsMetrics.padding,
        child: Row(
          children: [
            SizedBox(
              width: SettingsMetrics.iconSlot,
              child: KapyIcon(
                warnings.isNotEmpty
                    ? KapyIcons.warningRounded
                    : KapyIcons.peopleOutlined,
                size: SettingsMetrics.iconSize,
                color: warnings.isNotEmpty
                    ? Theme.of(context).colorScheme.error
                    : palette.textSecondary,
              ),
            ),
            SizedBox(width: SettingsMetrics.gap),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          space.titleFor(sharing.userId),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppTypeScale.control,
                            color: palette.textPrimary,
                          ),
                        ),
                      ),
                      if (!space.isOwner) ...[
                        const SizedBox(width: 8),
                        Text(
                          space.role.accessLabel,
                          style: TextStyle(
                            fontSize: AppTypeScale.caption,
                            fontWeight: FontWeight.w400,
                            color: palette.textTertiary,
                          ),
                        ),
                      ],
                    ],
                  ),
                  Text(
                    detail,
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
            const SizedBox(width: 8),
            SpacePeopleAvatars(
              space: space,
              currentUserId: sharing.userId,
              present: {
                for (final person in sharing.presentIn(space.id)) person.userId,
              },
              extent: 22,
              maxAvatars: 4,
            ),
            KapyIcon(
              KapyIcons.chevronRightRounded,
              size: AppControlMetrics.iconControl,
              color: palette.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}
