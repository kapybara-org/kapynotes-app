import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../core/toast.dart';
import '../data/note.dart';
import '../sync/safety.dart';
import '../sync/presence.dart';
import '../sync/sharing.dart';
import '../sync/sync_api.dart' show SyncRefusedException;
import '../sync/spaces.dart';
import '../sync/trust.dart';
import 'collaborator_colors.dart';
import 'control_surface.dart';
import 'member_avatars.dart';
import 'profile_avatar.dart';
import '../sync/joining.dart';
import 'join/join_requests_panel.dart';
import 'join/joining_ui.dart';
import 'join/space_link_panel.dart';
import 'safety_dialogs.dart';

/// The share sheet for one note.
///
/// A private note is offered two ways in: a person, by email, or a space the
/// account is already in. A shared note shows who else has access, who is
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
  SpaceRole _inviteRole = SpaceRole.member;
  String? _error;
  String? _notice;

  /// The last invitation this dialog sent, so its link can be copied.
  String? _lastInviteToken;

  @override
  void initState() {
    super.initState();
    widget.sharing.addListener(_changed);
    widget.sharing.presenceChanges.addListener(_changed);
    // Whatever another device did since the list was last fetched.
    unawaited(_refreshQuietly());
  }

  @override
  void dispose() {
    widget.sharing.removeListener(_changed);
    widget.sharing.presenceChanges.removeListener(_changed);
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

  Future<void> _run(
    Future<void> Function() action, {
    String waiting = 'Updating sharing…',
    String? done,
  }) async {
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    var progress = Toast.showProgress(context, waiting);
    var progressActive = true;
    try {
      try {
        await action();
      } on SyncRefusedException catch (error) {
        if (error.code != termsRequiredCode || !mounted) rethrow;

        // A confirmation is waiting on the person, not on the app. Remove the
        // indefinite spinner while the rules are being read, then resume it
        // only after they explicitly accept.
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
        if (done != null) setState(() => _notice = done);
        progress.success('Sharing updated');
      } else {
        progress.dismiss();
      }
    } catch (error) {
      final message = describeSharingError(error);
      if (mounted) {
        setState(() => _error = message);
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

  Future<void> _reportNote() async {
    final note = _note;
    final space = _space;
    if (note == null || space == null) return;
    await showReportDialog(
      context,
      sharing: widget.sharing,
      target: ReportTarget.note(
        spaceId: space.id,
        noteId: note.id,
        noteBody: note.body,
      ),
    );
  }

  Future<void> _shareWithEmail() async {
    final addresses = splitAddresses(_email.text);
    if (addresses.length > 1) return _shareWithMany(addresses);
    final email = _email.text.trim();
    if (!email.contains('@')) {
      setState(() => _error = 'Enter an email address.');
      return;
    }
    final noteId = widget.noteId;
    await _run(() async {
      if (noteId != null && _space == null) {
        final space = await widget.sharing.shareNoteWith(
          noteId,
          email: email,
          role: _inviteRole,
        );
        final invite = space.invites.where(
          (i) => i.email == email.toLowerCase(),
        );
        _lastInviteToken = invite.isEmpty ? null : invite.first.token;
      } else {
        final space = _space!;
        final result = await widget.sharing.invite(
          space.id,
          email,
          role: _inviteRole,
        );
        _lastInviteToken = result.token;
      }
      _email.clear();
    }, done: 'Invitation sent to $email as ${_inviteRole.accessLabel}.');
  }

  /// Several addresses at once: into this space when there is one, and
  /// otherwise into a new space made for exactly these people.
  ///
  /// Never into a two-person space that happens to exist already, as sharing
  /// with one person does. Adding several people to "With priya" would show
  /// every one of them the notes shared with Priya before.
  ///
  /// And never a new space with nobody in it. The owner's device ends any
  /// space that holds notes and no one else — it brings them home — so a note
  /// moved into a space the server then turned every address away from would
  /// be moved straight back out, racing the cleanup of spaces left behind.
  /// Nothing is made until an address could be somebody, and the note moves
  /// only once an invitation has actually been written.
  Future<void> _shareWithMany(List<String> addresses) async {
    final joining = JoiningScope.of(context);
    if (joining == null) {
      setState(
        () => _error = 'Sign in again to invite several people at once.',
      );
      return;
    }
    if (addresses.length > kBatchInviteMax) {
      setState(
        () => _error = 'Invite up to $kBatchInviteMax people at a time.',
      );
      return;
    }
    final noteId = widget.noteId;
    if (_space == null && !addresses.any(_looksLikeEmail)) {
      setState(() => _error = 'None of those look like email addresses.');
      return;
    }
    var results = const <BatchInviteResult>[];
    await _run(() async {
      final existing = _space;
      if (existing != null) {
        results = await joining.inviteMany(
          existing.id,
          addresses,
          role: _inviteRole,
        );
      } else if (noteId != null) {
        // The order sharing with one person uses: make the space, invite,
        // then move the note in. Making it is what asks for the sharing
        // rules, so a retry after agreeing starts from nothing made.
        final space = await widget.sharing.createSpace(
          groupSpaceName(addresses),
        );
        try {
          results = await joining.inviteMany(
            space.id,
            addresses,
            role: _inviteRole,
          );
        } catch (_) {
          await _endQuietly(space.id);
          rethrow;
        }
        if (!results.any((r) => r.sent)) {
          await _endQuietly(space.id);
          return;
        }
        await widget.sharing.shareNote(noteId, spaceId: space.id);
      }
      _lastInviteToken = null;
      _email.clear();
    }, waiting: 'Sending invitations…');
    if (mounted && _error == null && results.isNotEmpty) {
      setState(() => _notice = describeBatch(results));
    }
  }

  static bool _looksLikeEmail(String address) =>
      RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(address);

  /// Ends a space this dialog just made for nobody. Best effort: if it cannot
  /// be ended now, it holds no notes, so it is harmless where it is.
  Future<void> _endQuietly(String spaceId) async {
    try {
      await widget.sharing.stopSharing(spaceId);
    } on Object {
      // Left for the owner to stop from the list; it shares nothing.
    }
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
    final title = space == null
        ? 'Share note'
        : widget.noteId == null
        ? space.titleFor(sharing.userId)
        : 'Shared ${sharedPhrase(space, sharing.userId)}';
    final subtitle = space == null
        ? 'Invite people to collaborate securely'
        : widget.noteId == null
        ? 'Manage access to this space'
        : 'Manage access to this note';

    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      titlePadding: const EdgeInsets.fromLTRB(22, 20, 14, 0),
      contentPadding: const EdgeInsets.fromLTRB(22, 18, 22, 22),
      title: _ShareHeader(
        title: title,
        subtitle: subtitle,
        onClose: () => Navigator.of(context).pop(),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 448),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (space == null) ...[
                _Blurb(
                  'Choose access, then add one or more email addresses. Only '
                  'invited people can read the note.',
                ),
                const SizedBox(height: 18),
                _Label('Invite someone'),
                _InviteControls(
                  key: const ValueKey('share-invite-card'),
                  role: _inviteRole,
                  enabled: !_busy,
                  controller: _email,
                  action: 'Share',
                  autofocus: true,
                  onRoleChanged: (role) => setState(() => _inviteRole = role),
                  onEmailChanged: _clearMessage,
                  onSubmit: _shareWithEmail,
                ),
                if (sharing.teams.where(sharing.canAddNotesTo_).isNotEmpty) ...[
                  const SizedBox(height: 18),
                  _Label('Or add to an existing space'),
                  KapyControlSurface(
                    child: Column(
                      children: [
                        for (final team in sharing.teams)
                          if (sharing.canAddNotesTo_(team))
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
                                      done:
                                          'Shared ${sharedPhrase(team, sharing.userId)}.',
                                    ),
                            ),
                      ],
                    ),
                  ),
                ],
              ] else ...[
                _Members(
                  space: space,
                  sharing: sharing,
                  present: sharing.presentIn(space.id),
                  busy: _busy,
                  onCopyLink: _copyLink,
                  onRemove: (member) => _confirm(
                    title: 'Remove ${member.displayName}?',
                    body:
                        'They stop receiving updates immediately. Downloaded '
                        'copies stay on their devices.',
                    action: 'Remove',
                    destructive: true,
                    run: () => sharing.removeMember(space.id, member.userId),
                  ),
                  onBlock: (member) => _confirm(
                    title: 'Block ${member.displayName}?',
                    body:
                        'They can no longer invite you, and you leave this '
                        'space. Downloaded copies stay on their devices.',
                    action: 'Block',
                    destructive: true,
                    run: () async {
                      await sharing.blockPerson(
                        member.email,
                        inSpaceId: space.id,
                      );
                      if (context.mounted) Navigator.of(context).pop();
                    },
                  ),
                  onReport: (member) => showReportDialog(
                    context,
                    sharing: sharing,
                    target: ReportTarget.member(
                      spaceId: space.id,
                      email: member.email,
                      name: member.displayName,
                    ),
                  ),
                  onReportNote: note == null ? null : _reportNote,
                  onRevoke: (invite) =>
                      _run(() => sharing.revokeInvite(space.id, invite.token)),
                  onTrust: sharing.trustNewKey,
                ),
                if (space.isOwner) ...[
                  const SizedBox(height: 16),
                  _Label('Invite someone'),
                  _InviteControls(
                    key: const ValueKey('share-invite-card'),
                    role: _inviteRole,
                    enabled: !_busy && sharing.holdsKey(space.id),
                    controller: _email,
                    action: 'Invite',
                    onRoleChanged: (role) => setState(() => _inviteRole = role),
                    onEmailChanged: _clearMessage,
                    onSubmit: _shareWithEmail,
                  ),
                  if (JoiningScope.of(context) case final joining?) ...[
                    const SizedBox(height: 18),
                    SpaceLinkPanel(
                      spaceId: space.id,
                      joining: joining,
                      run: _run,
                      role: _inviteRole,
                      enabled: !_busy && sharing.holdsKey(space.id),
                    ),
                    JoinRequestsPanel(
                      spaceId: space.id,
                      joining: joining,
                      run: _run,
                      enabled: !_busy,
                    ),
                  ],
                ],
                if (_lastInviteToken case final token?) ...[
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => _copyLink(token),
                      icon: KapyIcon(
                        KapyIcons.linkRounded,
                        size: AppControlMetrics.iconControl,
                      ),
                      label: const Text('Copy invitation link'),
                    ),
                  ),
                ],
              ],
              if (_notice case final notice?) ...[
                const SizedBox(height: 12),
                _Message(notice),
              ],
              if (_error case final error?) ...[
                const SizedBox(height: 12),
                _Message(error, isError: true),
              ],
              if (space != null) ...[
                const SizedBox(height: 18),
                Divider(height: 1, color: palette.separator),
                const SizedBox(height: 10),
                _ManagementActions(
                  enabled: !_busy,
                  onMoveToMine: note != null && space.canEdit
                      ? () => _confirm(
                          title: 'Move to my notes?',
                          body:
                              'This note leaves the shared space and becomes '
                              'private. Others keep downloaded copies.',
                          action: 'Move note',
                          run: () async {
                            await sharing.unshareNote(note.id);
                            if (context.mounted) Navigator.of(context).pop();
                          },
                        )
                      : null,
                  onStopSharing: space.isOwner
                      ? () => _confirm(
                          title: switch (space.chosenName) {
                            final name? => 'Stop sharing $name?',
                            null => switch (space.peoplePhrase(
                              sharing.userId,
                            )) {
                              final people? => 'Stop sharing with $people?',
                              null => 'Stop sharing?',
                            },
                          },
                          body:
                              'All notes return to my notes and sharing ends. '
                              'Nothing is deleted.',
                          action: 'Stop sharing',
                          destructive: true,
                          run: () async {
                            await sharing.stopSharing(space.id);
                            if (context.mounted) Navigator.of(context).pop();
                          },
                        )
                      : null,
                  onLeave: !space.isOwner
                      ? () => _confirm(
                          title: switch (space.chosenName) {
                            final name? => 'Leave $name?',
                            null => 'Leave these shared notes?',
                          },
                          body:
                              'You stop receiving updates. Unsynced notes '
                              'remain in my notes.',
                          action: 'Leave',
                          destructive: true,
                          run: () async {
                            await sharing.leave(space.id);
                            if (context.mounted) Navigator.of(context).pop();
                          },
                        )
                      : null,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _clearMessage(String _) {
    if (_error == null && _notice == null) return;
    setState(() {
      _error = null;
      _notice = null;
    });
  }
}

class _ShareHeader extends StatelessWidget {
  const _ShareHeader({
    required this.title,
    required this.subtitle,
    required this.onClose,
  });

  final String title;
  final String subtitle;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(AppRadii.button),
            border: Border.all(color: accent.withValues(alpha: 0.28)),
          ),
          alignment: Alignment.center,
          child: KapyIcon(
            KapyIcons.shareRounded,
            size: AppControlMetrics.iconFeature,
            color: accent,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTypeScale.heading,
                      fontWeight: FontWeight.w600,
                      color: palette.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppTypeScale.small,
                    fontWeight: FontWeight.w400,
                    color: palette.textSecondary,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          key: const ValueKey('share-dialog-close'),
          tooltip: 'Close',
          onPressed: onClose,
          icon: KapyIcon(
            KapyIcons.closeRounded,
            size: AppControlMetrics.iconControl,
          ),
        ),
      ],
    );
  }
}

class _ManagementActions extends StatelessWidget {
  const _ManagementActions({
    required this.enabled,
    this.onMoveToMine,
    this.onStopSharing,
    this.onLeave,
  });

  final bool enabled;
  final VoidCallback? onMoveToMine;
  final VoidCallback? onStopSharing;
  final VoidCallback? onLeave;

  @override
  Widget build(BuildContext context) {
    final danger = Theme.of(context).colorScheme.error;
    final move = onMoveToMine;
    final stop = onStopSharing;
    final leave = onLeave;
    return Align(
      alignment: Alignment.centerRight,
      child: Wrap(
        alignment: WrapAlignment.end,
        spacing: 8,
        runSpacing: 8,
        children: [
          if (move != null)
            OutlinedButton.icon(
              key: const ValueKey('unshare-note'),
              onPressed: enabled ? move : null,
              icon: KapyIcon(
                KapyIcons.restoreRounded,
                size: AppControlMetrics.iconControl,
              ),
              label: const Text('Move to my notes'),
            ),
          if (stop != null)
            TextButton.icon(
              key: const ValueKey('stop-sharing'),
              onPressed: enabled ? stop : null,
              style: TextButton.styleFrom(foregroundColor: danger),
              icon: KapyIcon(
                KapyIcons.stopRounded,
                size: AppControlMetrics.iconControl,
              ),
              label: const Text('Stop sharing'),
            ),
          if (leave != null)
            TextButton.icon(
              key: const ValueKey('leave-space'),
              onPressed: enabled ? leave : null,
              style: TextButton.styleFrom(foregroundColor: danger),
              icon: KapyIcon(
                KapyIcons.logoutRounded,
                size: AppControlMetrics.iconControl,
              ),
              label: const Text('Leave'),
            ),
        ],
      ),
    );
  }
}

extension on Sharing {
  bool canAddNotesTo_(Space space) => space.canEdit && holdsKey(space.id);
}

/// How a sentence refers to a space: "with Priya and 2 others", or "in
/// Family" for one somebody named — never by the address it began with.
String sharedPhrase(Space space, String userId) {
  final chosen = space.chosenName;
  if (chosen != null) return 'in $chosen';
  final people = space.peoplePhrase(userId);
  return people == null ? 'in a shared space' : 'with $people';
}

/// Who can read the notes in a space, and where each of them stands.
class _Members extends StatelessWidget {
  const _Members({
    required this.space,
    required this.sharing,
    required this.present,
    required this.busy,
    required this.onCopyLink,
    required this.onRemove,
    required this.onBlock,
    required this.onReport,
    required this.onReportNote,
    required this.onRevoke,
    required this.onTrust,
  });

  final Space space;
  final Sharing sharing;

  /// Whoever else is in one of the space's notes right now.
  final List<Collaborator> present;
  final bool busy;
  final ValueChanged<String> onCopyLink;
  final ValueChanged<SpaceMember> onRemove;
  final ValueChanged<SpaceMember> onBlock;
  final ValueChanged<SpaceMember> onReport;
  final VoidCallback? onReportNote;
  final ValueChanged<SpaceInvite> onRevoke;
  final ValueChanged<TrustWarning> onTrust;

  @override
  Widget build(BuildContext context) {
    final warnings = {
      for (final w in sharing.trust.warningsFor(space.id)) w.userId: w,
    };
    final waiting = !sharing.holdsKey(space.id);
    final here = {for (final person in present) person.userId: person};
    final me = sharing.userId;
    // This account first, then whoever is in the notes now, then everyone
    // else in the order the space lists them.
    final members = [
      ...space.members.where((m) => m.userId == me),
      ...space.members.where(
        (m) => m.userId != me && here.containsKey(m.userId),
      ),
      ...space.members.where(
        (m) => m.userId != me && !here.containsKey(m.userId),
      ),
    ];
    final rows = <Widget>[
      for (final member in members)
        _MemberRow(
          key: ValueKey('member-row-${member.userId}'),
          member: member,
          isSelf: member.userId == me,
          presence: here[member.userId],
          trailing: member.userId == me
              ? null
              : _MemberMenu(
                  key: ValueKey('member-menu-${member.userId}'),
                  canRemove: space.isOwner && !member.isOwner,
                  enabled: !busy,
                  onReport: () => onReport(member),
                  onBlock: () => onBlock(member),
                  onRemove: () => onRemove(member),
                ),
        ),
      for (final invite in space.invites)
        _InviteeRow(
          key: ValueKey('invite-row-${invite.token}'),
          invite: invite,
          canRevoke: space.isOwner,
          busy: busy,
          onCopyLink: () => onCopyLink(invite.token),
          onRevoke: () => onRevoke(invite),
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (waiting)
          _Banner(
            icon: KapyIcons.hourglassRounded,
            text: 'Waiting for a member to approve access.',
          ),
        for (final warning in warnings.values)
          _Banner(
            icon: KapyIcons.warningRounded,
            isWarning: true,
            text:
                "${space.member(warning.userId)?.displayName ?? warning.email}'s "
                'key changed. If they set up a new account, compare this '
                'fingerprint with them before trusting it: ${warning.current}',
            action: TextButton(
              onPressed: () => onTrust(warning),
              child: const Text('Trust the new key'),
            ),
          ),
        _Label(
          'People with access',
          trailing: onReportNote == null
              ? null
              : TextButton.icon(
                  key: const ValueKey('report-note'),
                  onPressed: busy ? null : onReportNote,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 24),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 4,
                    ),
                    visualDensity: VisualDensity.standard,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    foregroundColor: context.palette.textSecondary,
                    textStyle: Theme.of(context).textTheme.labelSmall?.copyWith(
                      fontSize: AppTypeScale.caption,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  icon: KapyIcon(
                    KapyIcons.flagOutlined,
                    size: AppControlMetrics.iconInline,
                  ),
                  label: const Text('Report this note'),
                ),
        ),
        KapyControlSurface(
          key: const ValueKey('share-access-card'),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Column(
            children: [
              for (var index = 0; index < rows.length; index++) ...[
                if (index > 0)
                  Divider(
                    height: 1,
                    indent: _MemberRow._avatar + 10,
                    color: context.palette.separator,
                  ),
                rows[index],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// One person with access: their face, their name, what they may do and
/// whether they are in the notes right now.
///
/// The address stays off the row. A name is what somebody chose to be called
/// and the address is who they provably are, so it is kept one hover (or one
/// long press) away, for the moment somebody needs to check.
class _MemberRow extends StatelessWidget {
  const _MemberRow({
    super.key,
    required this.member,
    required this.isSelf,
    this.presence,
    this.trailing,
  });

  final SpaceMember member;
  final bool isSelf;
  final Collaborator? presence;
  final Widget? trailing;

  static const double _avatar = 30;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final presence = this.presence;
    final status = [
      member.role.accessLabel,
      if (!member.hasKey)
        member.x25519Public == null
            ? 'Has not unlocked yet'
            : 'Waiting for access',
      if (presence != null) presence.typing ? 'Typing' : 'Here now',
    ].join(' · ');
    Widget name = Text(
      isSelf ? '${member.displayName} (you)' : member.displayName,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: AppTypeScale.control,
        fontWeight: FontWeight.w500,
        color: palette.textPrimary,
      ),
    );
    if (member.hasName) name = Tooltip(message: member.email, child: name);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          ProfileAvatar(
            extent: _avatar,
            seed: member.userId.isEmpty ? member.email : member.userId,
            name: member.displayName,
            image: member.image,
            ring: presence == null
                ? null
                : collaboratorColor(member.userId, on: palette.brightness),
            ringWidth: 2,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                name,
                Text(
                  status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppTypeScale.caption,
                    fontWeight: presence == null
                        ? FontWeight.w400
                        : FontWeight.w400,
                    color: presence == null
                        ? palette.textSecondary
                        : collaboratorColor(
                            member.userId,
                            on: palette.brightness,
                          ),
                  ),
                ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// An invitation nobody has accepted yet: the address is all there is to
/// show, since there is no profile behind it until they join.
class _InviteeRow extends StatelessWidget {
  const _InviteeRow({
    super.key,
    required this.invite,
    required this.canRevoke,
    required this.busy,
    required this.onCopyLink,
    required this.onRevoke,
  });

  final SpaceInvite invite;
  final bool canRevoke;
  final bool busy;
  final VoidCallback onCopyLink;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Container(
            width: _MemberRow._avatar,
            height: _MemberRow._avatar,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: palette.surfaceBackground,
              border: Border.all(color: palette.controlBorder),
            ),
            child: KapyIcon(
              KapyIcons.mailOutlined,
              size: AppControlMetrics.iconAdornment,
              color: palette.textTertiary,
            ),
          ),
          const SizedBox(width: 10),
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
                    fontWeight: FontWeight.w500,
                    color: palette.textPrimary,
                  ),
                ),
                Text(
                  '${invite.role.accessLabel} · Invite pending',
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
            onPressed: onCopyLink,
            icon: KapyIcon(
              KapyIcons.linkRounded,
              size: AppControlMetrics.iconControl,
            ),
          ),
          if (canRevoke)
            TextButton(
              onPressed: busy ? null : onRevoke,
              child: const Text('Revoke'),
            ),
        ],
      ),
    );
  }
}

/// The per-member actions, behind one button.
///
/// A row that grew three more text buttons would push the address it is about
/// off the edge on a phone, and two of the three are rare enough that they
/// should cost a tap rather than permanent width.
class _MemberMenu extends StatelessWidget {
  const _MemberMenu({
    super.key,
    required this.canRemove,
    required this.enabled,
    required this.onReport,
    required this.onBlock,
    required this.onRemove,
  });

  final bool canRemove;
  final bool enabled;
  final VoidCallback onReport;
  final VoidCallback onBlock;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final error = Theme.of(context).colorScheme.error;
    return PopupMenuButton<String>(
      enabled: enabled,
      tooltip: 'More',
      icon: KapyIcon(
        KapyIcons.moreRounded,
        size: AppControlMetrics.iconControl,
        color: palette.textSecondary,
      ),
      onSelected: (value) => switch (value) {
        'report' => onReport(),
        'block' => onBlock(),
        _ => onRemove(),
      },
      itemBuilder: (context) => [
        const PopupMenuItem(value: 'report', child: Text('Report…')),
        const PopupMenuItem(value: 'block', child: Text('Block…')),
        if (canRemove)
          PopupMenuItem(
            value: 'remove',
            child: Text('Remove', style: TextStyle(color: error)),
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
    final people = space.peopleExcept(userId);
    final who = people.isEmpty
        ? 'Nobody else yet'
        : [
            for (final person in people)
              person.isInvited ? '${person.name} (invited)' : person.fullName,
          ].join(', ');
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.surface),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            KapyIcon(
              KapyIcons.peopleOutlined,
              size: AppControlMetrics.iconControl,
              color: palette.textSecondary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    space.titleFor(userId),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTypeScale.control,
                      fontWeight: FontWeight.w500,
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
            const SizedBox(width: 8),
            SpacePeopleAvatars(
              space: space,
              currentUserId: userId,
              extent: 22,
              maxAvatars: 3,
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

class _InviteControls extends StatelessWidget {
  const _InviteControls({
    super.key,
    required this.role,
    required this.enabled,
    required this.controller,
    required this.action,
    required this.onRoleChanged,
    required this.onEmailChanged,
    required this.onSubmit,
    this.autofocus = false,
  });

  final SpaceRole role;
  final bool enabled;
  final TextEditingController controller;
  final String action;
  final ValueChanged<SpaceRole> onRoleChanged;
  final ValueChanged<String> onEmailChanged;
  final VoidCallback onSubmit;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => KapyControlSurface(
    padding: const EdgeInsets.all(12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RolePicker(value: role, enabled: enabled, onChanged: onRoleChanged),
        const SizedBox(height: 10),
        _EmailRow(
          controller: controller,
          busy: !enabled,
          action: action,
          autofocus: autofocus,
          onChanged: onEmailChanged,
          onSubmit: onSubmit,
        ),
      ],
    ),
  );
}

class _RolePicker extends StatelessWidget {
  const _RolePicker({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final SpaceRole value;
  final bool enabled;
  final ValueChanged<SpaceRole> onChanged;

  @override
  Widget build(BuildContext context) => SegmentedButton<SpaceRole>(
    key: const ValueKey('share-role'),
    expandedInsets: EdgeInsets.zero,
    segments: [
      ButtonSegment(
        value: SpaceRole.member,
        icon: KapyIcon(
          KapyIcons.editOutlined,
          size: AppControlMetrics.iconControl,
        ),
        label: const Text('Editor'),
      ),
      ButtonSegment(
        value: SpaceRole.viewer,
        icon: KapyIcon(
          KapyIcons.visibilityOutlined,
          size: AppControlMetrics.iconControl,
        ),
        label: const Text('View only'),
      ),
    ],
    selected: {value},
    showSelectedIcon: false,
    onSelectionChanged: enabled
        ? (selection) {
            if (selection.isNotEmpty) onChanged(selection.first);
          }
        : null,
  );
}

class _EmailRow extends StatelessWidget {
  const _EmailRow({
    required this.controller,
    required this.busy,
    required this.action,
    required this.autofocus,
    required this.onChanged,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final bool busy;
  final String action;
  final bool autofocus;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final field = TextField(
      key: const ValueKey('share-email'),
      controller: controller,
      enabled: !busy,
      autofocus: autofocus,
      keyboardType: TextInputType.emailAddress,
      autocorrect: false,
      enableSuggestions: false,
      onChanged: onChanged,
      onSubmitted: (_) {
        if (!busy) onSubmit();
      },
      style: TextStyle(
        fontSize: AppTypeScale.control,
        color: palette.textPrimary,
      ),
      decoration: kapyFieldDecoration(
        context,
        hintText: 'Email addresses',
        fillColor: palette.surfaceBackground,
        prefixIcon: Center(
          widthFactor: 1,
          heightFactor: 1,
          child: KapyIcon(
            KapyIcons.mailOutlined,
            size: AppControlMetrics.iconAdornment,
            color: palette.textTertiary,
          ),
        ),
        prefixIconConstraints: BoxConstraints(
          minWidth: AppControlMetrics.fieldAdornmentSlot + 4,
          minHeight: AppControlMetrics.fieldAdornmentSlot,
        ),
      ),
    );
    final submit = FilledButton(
      key: ValueKey('share-submit-$action'),
      onPressed: busy ? null : onSubmit,
      child: Text(action),
    );

    if (MediaQuery.sizeOf(context).width < 520) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [field, const SizedBox(height: 8), submit],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: field),
        const SizedBox(width: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 76),
          child: submit,
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

  final KapyIconData icon;
  final String text;
  final bool isWarning;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final color = isWarning
        ? Theme.of(context).colorScheme.error
        : palette.textSecondary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: KapyControlSurface(
        color: isWarning
            ? color.withValues(alpha: 0.07)
            : palette.controlBackground,
        borderColor: isWarning
            ? color.withValues(alpha: 0.42)
            : palette.controlBorder,
        padding: const EdgeInsets.fromLTRB(11, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: KapyIcon(
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
  const _Label(this.text, {this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: AppTypeScale.caption,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
              color: context.palette.textSecondary,
            ),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

class _Message extends StatelessWidget {
  const _Message(this.text, {this.isError = false});
  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final color = isError
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.primary;
    return KapyControlSurface(
      color: color.withValues(alpha: 0.07),
      borderColor: color.withValues(alpha: 0.34),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: KapyIcon(
              isError ? KapyIcons.errorOutlined : KapyIcons.checkCircleRounded,
              size: AppControlMetrics.iconAdornment,
              color: color,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: AppTypeScale.small,
                color: isError ? color : palette.textSecondary,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
