import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../billing/billing.dart';
import '../../core/theme.dart';
import '../../core/toast.dart';
import '../../data/note.dart';
import '../../data/notes_store.dart';
import '../../sync/account.dart';
import '../../sync/joining.dart';
import '../../sync/safety.dart';
import '../../sync/sharing.dart';
import '../../sync/spaces.dart';
import '../../sync/sync_api.dart' show SyncRefusedException;
import '../context_menu.dart';
import '../join/join_link_sheet.dart';
import '../join/joining_ui.dart';
import '../profile_avatar.dart';
import '../safety_dialogs.dart';
import '../settings_rows.dart';
import '../sharing_sheet.dart';
import '../sidebar_timestamp.dart';

/// Settings → Sharing: the people this account shares notes with, and what
/// each of them can see.
///
/// Before the account can share, it says what stands in the way, as the
/// account's own pane does.
class SharingSection extends StatelessWidget {
  const SharingSection({
    super.key,
    required this.account,
    required this.notes,
    this.displayTime = _asIs,
    this.start,
    this.onOpenNote,
    this.onShowPlan,
  });

  final Account account;
  final NotesStore notes;
  final DateTime Function(DateTime) displayTime;
  final SharingStart? start;
  final ValueChanged<String>? onOpenNote;
  final VoidCallback? onShowPlan;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: account,
    builder: (context, _) {
      final sharing = account.sharing;
      if (sharing == null) {
        return SettingsGroup(
          children: [
            _Row(
              titleLines: 2,
              title: switch (account.state) {
                AccountState.signedOut =>
                  'Sign in, and unlock your notes, to share them with people.',
                AccountState.needsProfile =>
                  'Finish your profile before sharing notes.',
                AccountState.needsPassphrase =>
                  'Save your passphrase to start sharing notes.',
                AccountState.locked ||
                AccountState.keysChanged => 'Unlock your notes to share them.',
                _ => 'Sharing becomes available once your notes are unlocked.',
              },
            ),
          ],
        );
      }
      return SharingSectionBody(
        sharing: sharing,
        notes: notes,
        billing: account.billing,
        displayTime: displayTime,
        start: start,
        onOpenNote: onOpenNote,
        onShowPlan: onShowPlan,
      );
    },
  );
}

DateTime _asIs(DateTime time) => time.toLocal();

/// Where Settings → Sharing opens, when whatever opened it chose.
class SharingStart {
  /// The page of the person with this address.
  const SharingStart.person(String this.person) : picking = false;

  /// Share with someone, unless the plan does not include starting to share.
  const SharingStart.picking() : person = null, picking = true;

  final String? person;
  final bool picking;
}

/// The section's contents, given a [Sharing] directly, so a test can mount it
/// without a whole signed-in [Account].
class SharingSectionBody extends StatefulWidget {
  const SharingSectionBody({
    super.key,
    required this.sharing,
    required this.notes,
    this.billing,
    this.displayTime = _asIs,
    this.start,
    this.onOpenNote,
    this.onShowPlan,
  });

  final Sharing sharing;
  final NotesStore notes;

  /// Says whether the plan includes starting to share. Null, or no answer
  /// yet, leaves the server to say so if it does not.
  final Billing? billing;
  final DateTime Function(DateTime) displayTime;

  /// Where it opens. Null opens on everyone.
  final SharingStart? start;

  /// Leaves settings for a note. Null leaves Open out.
  final ValueChanged<String>? onOpenNote;

  /// Goes to the plan, from the Pro line.
  final VoidCallback? onShowPlan;

  @override
  State<SharingSectionBody> createState() => _SharingSectionBodyState();
}

class _SharingSectionBodyState extends State<SharingSectionBody> {
  final _code = TextEditingController();

  /// The person whose page is showing, by address. Null shows everyone.
  String? _person;
  bool _busy = false;
  bool _joinOpen = false;
  bool _blockedOpen = false;

  /// The one thing that went wrong, said under the group it happened in.
  ({String at, String text})? _error;

  Sharing get _sharing => widget.sharing;

  @override
  void initState() {
    super.initState();
    _sharing.addListener(_changed);
    _sharing.presenceChanges.addListener(_changed);
    widget.billing?.addListener(_changed);
    unawaited(_refreshQuietly());
    _person = widget.start?.person;
    if (widget.start?.picking ?? false) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _idle && _mayStart) unawaited(_pick(null));
      });
    }
  }

  @override
  void dispose() {
    _sharing.removeListener(_changed);
    _sharing.presenceChanges.removeListener(_changed);
    widget.billing?.removeListener(_changed);
    _code.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshQuietly() async {
    try {
      await _sharing.refresh();
    } on Object {
      // Offline: what was last seen still shows.
    }
  }

  bool get _mayStart => widget.billing?.entitlements?.sharing ?? true;
  bool get _idle => !_busy && !_sharing.isOffline;

  /// Runs one action. A failure is said once, under [at], and nowhere else;
  /// [done] is said as a toast, with Undo when [undo] can take it back.
  Future<bool> _run(
    String at,
    Future<void> Function() action, {
    String? done,
    Future<void> Function()? undo,
  }) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      try {
        await action();
      } on SyncRefusedException catch (error) {
        if (error.code != termsRequiredCode || !mounted) rethrow;
        final accepted = await showSharingTermsSheet(
          context,
          sharing: _sharing,
        );
        if (!accepted || !mounted) return false;
        await action();
      }
      if (mounted && done != null) {
        Toast.show(
          context,
          done,
          action: undo == null ? null : 'Undo',
          onAction: undo == null ? null : () => unawaited(_run(at, undo)),
        );
      }
      return true;
    } catch (error) {
      if (mounted) {
        setState(() => _error = (at: at, text: describeSharingError(error)));
      }
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Who is who

  static String _first(String name) => name.trim().split(' ').first;

  static String _count(int count) => count == 1 ? '1 note' : '$count notes';

  static String _access(SpaceRole role) =>
      role.canEdit ? 'Can edit' : 'Can view';

  List<Note> _visible(List<Note> notes) => [
    for (final note in notes)
      if (!note.isHidden) note,
  ];

  /// Every shared space between this account and [email]: the ones it owns
  /// with them in, invited or joined, and the ones they own.
  List<Space> _spacesWith(String email) => [
    for (final space in _sharing.teams)
      if (space.isOwner
          ? space
                    .othersThan(_sharing.userId)
                    .any((member) => member.email.toLowerCase() == email) ||
                space.invites.any(
                  (invite) => invite.email.toLowerCase() == email,
                )
          : space.member(space.ownerId)?.email.toLowerCase() == email)
        space,
  ];

  bool _here(SharePerson person) =>
      person.userId != null &&
      _spacesWith(person.email).any(
        (space) => _sharing
            .presentIn(space.id)
            .any((other) => other.userId == person.userId),
      );

  /// What [email] may do with a note this account owns, or null when they
  /// are not on it.
  ({SpaceRole role, bool invited})? _accessOf(Note note, String email) {
    final space = _sharing.spaceOf(note);
    if (space == null) return null;
    for (final member in space.othersThan(_sharing.userId)) {
      if (member.email.toLowerCase() == email) {
        return (role: member.role, invited: false);
      }
    }
    for (final invite in space.invites) {
      if (invite.email.toLowerCase() == email) {
        return (role: invite.role, invited: true);
      }
    }
    return null;
  }

  /// A state worth more than the counts, when there is one.
  String? _trouble(SharePerson person) {
    final first = _first(person.name);
    final spaces = _spacesWith(person.email);
    if (spaces.any(
      (space) => _sharing.trust
          .warningsFor(space.id)
          .any((warning) => warning.userId == person.userId),
    )) {
      return "$first's safety code changed. Check it's really them before "
          'you share more';
    }
    for (final space in spaces) {
      if (_sharing.needsPro(space.id)) {
        return space.isOwner
            ? 'Paused until you have Pro'
            : 'Paused until you or $first has Pro';
      }
    }
    if (spaces.any((space) => !space.isOwner && !_sharing.holdsKey(space.id))) {
      return 'Waiting for $first to let you in';
    }
    return null;
  }

  String _summary(SharePerson person) {
    final trouble = _trouble(person);
    if (trouble != null) return trouble;
    final mine = _visible(_sharing.notesSharedWith(person.email)).length;
    final theirs = _visible(_sharing.notesSharedFrom(person.email)).length;
    return [
      if (person.isInvited) 'Invited',
      if (mine > 0) 'You share ${_count(mine)}',
      if (theirs > 0)
        mine > 0 ? 'they share $theirs with you' : 'Shares $theirs with you',
      if (mine == 0 && theirs == 0) 'Nothing shared right now',
    ].join(' · ');
  }

  // ---------------------------------------------------------------------------
  // Asking first

  Future<T?> _menu<T>(
    BuildContext button,
    List<({T value, String label, bool danger})> items,
  ) {
    final box = button.findRenderObject() as RenderBox?;
    if (box == null) return Future<T?>.value();
    final danger = Theme.of(context).colorScheme.error;
    return showKapyContextMenu<T>(
      context: button,
      globalPosition: box.localToGlobal(
        Offset(box.size.width, box.size.height + 4),
      ),
      items: [
        for (final item in items)
          PopupMenuItem<T>(
            value: item.value,
            height: 36,
            child: Text(
              item.label,
              style: TextStyle(color: item.danger ? danger : null),
            ),
          ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Invitations to this account

  Future<void> _inviteMenu(BuildContext button, PendingInvite invite) async {
    final name = invite.inviterDisplayName;
    final choice = await _menu<String>(button, [
      (value: 'report', label: 'Report…', danger: false),
      (value: 'block', label: 'Block $name…', danger: true),
    ]);
    if (!mounted) return;
    if (choice == 'report') {
      await showReportDialog(
        context,
        sharing: _sharing,
        target: ReportTarget.invitation(
          token: invite.token,
          email: invite.invitedBy,
        ),
      );
    } else if (choice == 'block') {
      final ok = await askFirst(
        context,
        title: 'Block $name?',
        body:
            "They can't invite you again, and this invitation goes away. "
            'You can unblock them here, under Blocked people.',
        action: 'Block',
      );
      if (ok == null || !mounted) return;
      await _run(
        'invites',
        () => _sharing.blockPerson(invite.invitedBy),
        done: 'Blocked $name',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // A person

  Future<void> _pick(SharePerson? person) async {
    final shared = await showDialog<String>(
      context: context,
      builder: (context) => SharePicker(
        sharing: _sharing,
        notes: widget.notes,
        person: person,
        displayTime: widget.displayTime,
      ),
    );
    if (shared != null && mounted) Toast.show(context, shared);
  }

  Future<void> _personMenu(BuildContext button, SharePerson person) async {
    final first = _first(person.name);
    final choice = await _menu<String>(button, [
      (value: 'report', label: 'Report…', danger: false),
      (value: 'block', label: 'Block $first…', danger: true),
    ]);
    if (!mounted) return;
    final spaces = _spacesWith(person.email);
    if (choice == 'report' && spaces.isNotEmpty) {
      await showReportDialog(
        context,
        sharing: _sharing,
        target: ReportTarget.member(
          spaceId: spaces.first.id,
          email: person.email,
          name: person.name,
        ),
      );
    } else if (choice == 'block') {
      final ok = await askFirst(
        context,
        title: 'Block ${person.name}?',
        body:
            '$first loses access to everything you share, you leave what '
            "$first shares with you (keeping copies), and $first can't "
            'invite you again.',
        action: 'Block',
      );
      if (ok == null || !mounted) return;
      final blocked = await _run(
        'person',
        () => _sharing.blockEverywhere(person.email),
        done: 'Blocked ${person.name}',
      );
      if (blocked && mounted) setState(() => _person = null);
    }
  }

  Future<void> _accessMenu(
    BuildContext button,
    Note note,
    SharePerson person,
    ({SpaceRole role, bool invited}) access,
  ) async {
    final choice = await _menu<SpaceRole?>(button, [
      if (!access.invited) ...[
        (value: SpaceRole.member, label: 'Can edit', danger: false),
        (value: SpaceRole.viewer, label: 'Can view', danger: false),
      ],
      (value: SpaceRole.owner, label: 'Stop sharing this note', danger: true),
    ]);
    if (choice == null || !mounted) return;
    final first = _first(person.name);
    final title = _titleOf(note);
    if (choice == SpaceRole.owner) {
      final ok = await askFirst(
        context,
        title: 'Stop sharing “$title” with $first?',
        body:
            '$first stops seeing this note. It stays in your notes, with '
            'everything $first wrote.',
        action: 'Stop sharing',
      );
      if (ok == null || !mounted) return;
      await _run(
        'mine',
        () => _sharing.removeFromNote(note.id, person.email),
        done: 'Stopped sharing “$title” with $first',
        undo: () =>
            _sharing.addPerson(note.id, person.email, role: access.role),
      );
      return;
    }
    if (choice.canEdit == access.role.canEdit) return;
    final together = _visible(_sharing.notesIn(note.spaceId!)).length;
    if (together > 1) {
      final ok = await askFirst(
        context,
        title: choice.canEdit ? 'Let $first edit?' : 'Let $first only view?',
        body:
            '$first sees $together notes you share together, and the change '
            'is for all of them.',
        action: 'Change access',
      );
      if (ok == null || !mounted) return;
    }
    await _run(
      'mine',
      () => _sharing.changeAccessTo(note.id, person.email, choice),
      done: '$first ${choice.canEdit ? 'can edit' : 'can view'} now',
    );
  }

  Future<void> _receivedMenu(
    BuildContext button,
    Note note,
    SharePerson person,
  ) async {
    final open = widget.onOpenNote;
    final choice = await _menu<String>(button, [
      if (open != null) (value: 'open', label: 'Open', danger: false),
      (value: 'copy', label: 'Make a private copy', danger: false),
      (value: 'leave', label: 'Leave this note', danger: true),
    ]);
    if (!mounted) return;
    final first = _first(person.name);
    final title = _titleOf(note);
    switch (choice) {
      case 'open':
        open?.call(note.id);
      case 'copy':
        await _run(
          'theirs',
          () => _sharing.makePrivateCopy(note.id),
          done: 'Copied to your notes',
        );
      case 'leave':
        final spaceId = note.spaceId!;
        final together = _visible(_sharing.notesIn(spaceId)).length;
        final keep = await askFirst(
          context,
          title: together > 1
              ? 'Leave $together notes from $first?'
              : 'Leave “$title”?',
          body: together > 1
              ? '$first shares “$title” together with ${together - 1} more, '
                    "so you leave all of them. You stop seeing $first's "
                    'changes, and $first keeps the notes.'
              : "You stop seeing $first's changes. $first keeps the note.",
          action: 'Leave',
          option: together > 1 ? 'Keep private copies' : 'Keep a private copy',
        );
        if (keep == null || !mounted) return;
        await _run(
          'theirs',
          () => _sharing.leave(spaceId, keepCopies: keep),
          done: keep ? 'Left. Your copy is in your notes' : 'Left',
        );
    }
  }

  Future<void> _stopSharingWith(SharePerson person) async {
    final first = _first(person.name);
    final mine = _visible(_sharing.notesSharedWith(person.email));
    final ok = await askFirst(
      context,
      title: 'Stop sharing with $first?',
      body:
          '$first loses access to the ${_count(mine.length)} you share. They '
          'stay in your notes, with every change. Notes $first shares with '
          "you aren't affected.",
      action: 'Stop sharing',
    );
    if (ok == null || !mounted) return;
    final before = {
      for (final note in mine)
        if (_accessOf(note, person.email) case final access?)
          note.id: access.role,
    };
    await _run(
      'stop',
      () => _sharing.stopSharingWith(person.email),
      done: 'Stopped sharing with $first',
      undo: () async {
        for (final MapEntry(key: id, value: role) in before.entries) {
          await _sharing.addPerson(id, person.email, role: role);
        }
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Invitations this account sent

  Future<void> _copyLink(String token) async {
    await Clipboard.setData(
      ClipboardData(text: _sharing.inviteLink(token).toString()),
    );
    if (mounted) Toast.show(context, 'Invitation link copied');
  }

  Future<void> _cancel(Space space, SpaceInvite invite) async {
    final ok = await askFirst(
      context,
      title: 'Cancel the invitation to ${invite.email}?',
      body:
          'The invitation and its link stop working. The notes stay as '
          'they are.',
      action: 'Cancel invitation',
    );
    if (ok == null || !mounted) return;
    await _run(
      'sent',
      () => _sharing.revokeInvite(space.id, invite.token),
      done: 'Invitation to ${invite.email} cancelled',
    );
  }

  static String _expiry(DateTime expiresAt) {
    final days = (expiresAt.difference(DateTime.now()).inMinutes / 1440).ceil();
    return switch (days) {
      <= 1 => 'expires today',
      2 => 'expires tomorrow',
      _ => 'expires in $days days',
    };
  }

  // ---------------------------------------------------------------------------
  // Joining

  /// A pasted invitation: the code on its own, or the whole link.
  static String _tokenFrom(String typed) {
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
        sharing: _sharing,
      );
      return;
    }
    final token = target?.token ?? _tokenFrom(_code.text);
    if (token.isEmpty) return;
    String? joined;
    await _run('join', () async {
      final space = await _sharing.acceptInvite(token);
      _code.clear();
      joined = space.titleFor(_sharing.userId);
    });
    if (joined != null && mounted) {
      setState(() => _joinOpen = false);
      Toast.show(context, joinedLine);
    }
  }

  // ---------------------------------------------------------------------------
  // Drawing

  String _day(DateTime time) => SidebarTimestamp.glance(
    time,
    now: DateTime.now(),
    displayTime: widget.displayTime,
    today: true,
    clock: false,
  );

  Widget _errorAt(String at) {
    final error = _error;
    if (error == null || error.at != at) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(3, 8, 3, 0),
      child: Text(
        error.text,
        key: const ValueKey('sharing-error'),
        style: TextStyle(
          fontSize: AppTypeScale.small,
          height: 1.4,
          color: Theme.of(context).colorScheme.error,
        ),
      ),
    );
  }

  Widget _gap() => SizedBox(height: SettingsMetrics.groupGap);

  @override
  Widget build(BuildContext context) {
    final people = _sharing.people;
    final person = people.where((p) => p.email == _person).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_sharing.isOffline) ...[
          const _Quiet(
            "You're offline. What's here stays as it is, and changes wait "
            "until you're back.",
            key: ValueKey('sharing-offline'),
          ),
          const SizedBox(height: 12),
        ],
        if (person == null) ..._list(people) else ..._page(person),
      ],
    );
  }

  List<Widget> _list(List<SharePerson> people) {
    final invites = _sharing.invites;
    final sent = [
      for (final space in _sharing.teams)
        if (space.isOwner)
          for (final invite in space.invites) (space: space, invite: invite),
    ];
    final blocks = _sharing.blocks;
    final onShowPlan = widget.onShowPlan;
    return [
      if (!_mayStart) ...[
        SettingsGroup(
          key: const ValueKey('sharing-pro'),
          children: [
            _Row(
              title: 'Sharing is part of Pro',
              subtitle:
                  "People you invite don't need Pro. Notes shared with you "
                  'keep working.',
              trailing: onShowPlan == null
                  ? null
                  : SettingsRowButton(
                      label: 'See plans',
                      prominent: true,
                      onPressed: onShowPlan,
                    ),
            ),
          ],
        ),
        _gap(),
      ],
      if (invites.isNotEmpty) ...[
        _Heading(
          'Waiting for you',
          count: invites.length,
          key: const ValueKey('sharing-invites'),
        ),
        SettingsGroup(
          children: [
            for (final invite in invites)
              _InviteRow(
                key: ValueKey('invite-${invite.token}'),
                invite: invite,
                enabled: _idle,
                onMenu: (button) => _inviteMenu(button, invite),
                onDecline: () =>
                    _run('invites', () => _sharing.declineInvite(invite.token)),
                onAccept: () => _run(
                  'invites',
                  () => _sharing.acceptInvite(invite.token),
                  done: joinedLine,
                ),
              ),
          ],
        ),
        _errorAt('invites'),
        _gap(),
      ],
      _Heading(
        'People',
        count: people.length,
        key: const ValueKey('sharing-people'),
        action: SettingsRowButton(
          key: const ValueKey('share-with-someone'),
          label: 'Share with someone',
          prominent: true,
          onPressed: _idle && _mayStart ? () => _pick(null) : null,
        ),
      ),
      SettingsGroup(
        children: [
          if (people.isEmpty)
            const _Row(
              title: 'No one yet',
              subtitle:
                  'When you share a note, the person shows up here with every '
                  'note they can see. You can change or stop it from one '
                  'place.',
            ),
          for (final person in people)
            _Row(
              key: ValueKey('person-${person.email}'),
              leading: _Face(person: person, here: _here(person), extent: 28),
              title: person.name,
              subtitle: _summary(person),
              trailing: const _Chevron(),
              onTap: () => setState(() {
                _person = person.email;
                _error = null;
              }),
            ),
        ],
      ),
      _errorAt('person'),
      if (sent.isNotEmpty) ...[
        _gap(),
        _Heading(
          'Invitations you sent',
          count: sent.length,
          key: const ValueKey('sharing-sent'),
        ),
        SettingsGroup(
          children: [
            for (final (:space, :invite) in sent)
              _Row(
                key: ValueKey('sent-${space.id}-${invite.token}'),
                leading: _Face.forEmail(invite.email, extent: 28),
                title: invite.email,
                subtitle: [
                  for (final note in _visible(_sharing.notesIn(space.id)))
                    _titleOf(note),
                  _expiry(invite.expiresAt),
                ].join(' · '),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _IconAction(
                      key: ValueKey('copy-${invite.token}'),
                      icon: KapyIcons.copyRounded,
                      tooltip: 'Copy invitation link',
                      onPressed: () => _copyLink(invite.token),
                    ),
                    const SizedBox(width: 4),
                    SettingsRowButton(
                      key: ValueKey('cancel-${invite.token}'),
                      label: 'Cancel',
                      onPressed: _idle ? () => _cancel(space, invite) : null,
                    ),
                  ],
                ),
              ),
          ],
        ),
        _errorAt('sent'),
      ],
      _gap(),
      const SettingsLabel('More'),
      SettingsGroup(
        children: [
          _Row(
            key: const ValueKey('join-row'),
            title: 'Join with a link or code',
            subtitle: 'For an invitation someone sent you outside the app',
            trailing: _Chevron(open: _joinOpen),
            onTap: () => setState(() => _joinOpen = !_joinOpen),
          ),
          if (_joinOpen)
            _JoinField(controller: _code, enabled: _idle, onJoin: _join),
          _Row(
            key: const ValueKey('blocked-people'),
            title: 'Blocked people',
            subtitle: switch (blocks.length) {
              0 => 'Nobody',
              1 => "1 person can't invite you",
              final count => "$count people can't invite you",
            },
            trailing: _Chevron(open: _blockedOpen),
            onTap: () => setState(() => _blockedOpen = !_blockedOpen),
          ),
          if (_blockedOpen)
            for (final block in blocks)
              _Row(
                key: ValueKey('block-${block.email}'),
                title: block.email,
                subtitle: 'Blocked ${_day(block.createdAt)}',
                trailing: SettingsRowButton(
                  key: ValueKey('unblock-${block.email}'),
                  label: 'Unblock',
                  onPressed: _idle
                      ? () => _run(
                          'more',
                          () => _sharing.unblockPerson(block.email),
                          done: 'Unblocked ${block.email}',
                        )
                      : null,
                ),
              ),
        ],
      ),
      _errorAt('join'),
      _errorAt('more'),
      const SizedBox(height: 14),
      const SettingsNote(
        'Only the people you share a note with can read it. Not even Kapy '
        'can. Hidden notes are never shared.',
        icon: KapyIcons.lockRounded,
      ),
      const SettingsNote(
        'To be sure a note reaches the right person, compare safety codes '
        "with them in person once. You'll be told if their code ever "
        'changes.',
      ),
      const SettingsNote(
        "Something wrong? Block and report from the person's menu. One person "
        'reads every report, usually within $reportResponseDays working days, '
        'or write to $safetyContact.',
        icon: KapyIcons.flagOutlined,
      ),
    ];
  }

  List<Widget> _page(SharePerson person) {
    final first = _first(person.name);
    final mine = _visible(_sharing.notesSharedWith(person.email));
    final theirs = _visible(_sharing.notesSharedFrom(person.email));
    final open = widget.onOpenNote;
    final here = _here(person);
    DateTime? since;
    for (final space in _spacesWith(person.email)) {
      for (final member in space.members) {
        if (member.email.toLowerCase() != person.email) continue;
        if (since == null || member.joinedAt.isBefore(since)) {
          since = member.joinedAt;
        }
      }
    }
    String edited(Note note) => SidebarTimestamp.edited(
      note.updatedAt,
      now: DateTime.now(),
      displayTime: widget.displayTime,
    );
    return [
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const ValueKey('sharing-back'),
          onPressed: () => setState(() {
            _person = null;
            _error = null;
          }),
          icon: const KapyIcon(KapyIcons.chevronLeftRounded, size: 14),
          label: const Text('All people'),
        ),
      ),
      const SizedBox(height: 6),
      _Row(
        key: const ValueKey('person-header'),
        leading: _Face(person: person, here: here, extent: 40),
        title: person.name,
        subtitle: [
          person.email,
          if (person.isInvited)
            'invited, not joined yet'
          else if (since != null)
            'sharing since ${_day(since)}',
          if (here) 'here now',
        ].join(' · '),
        trailing: Builder(
          builder: (button) => _IconAction(
            key: const ValueKey('person-menu'),
            icon: KapyIcons.moreRounded,
            tooltip: 'More for ${person.name}',
            onPressed: _idle ? () => _personMenu(button, person) : null,
          ),
        ),
      ),
      _errorAt('person'),
      _gap(),
      _Heading(
        'Notes you share with $first',
        count: mine.length,
        action: SettingsRowButton(
          key: const ValueKey('add-notes'),
          label: 'Add notes',
          prominent: true,
          onPressed: _idle && _mayStart ? () => _pick(person) : null,
        ),
      ),
      SettingsGroup(
        children: [
          if (mine.isEmpty)
            _Row(
              title: 'Nothing yet',
              subtitle:
                  'Add notes and $first sees them in Shared, with the access '
                  'you choose.',
            ),
          for (final note in mine)
            if (_accessOf(note, person.email) case final access?)
              _Row(
                key: ValueKey('mine-${note.id}'),
                title: _titleOf(note),
                subtitle: [
                  if (_alsoWith(note, person.email) case final also?)
                    'Also with $also',
                  edited(note),
                ].join(' · '),
                onTap: open == null ? null : () => open(note.id),
                trailing: Builder(
                  builder: (button) => SettingsMenuButton(
                    key: ValueKey('access-${note.id}'),
                    label: access.invited
                        ? 'Invited · ${_access(access.role)}'
                        : _access(access.role),
                    onPressed: () {
                      if (_idle) {
                        unawaited(_accessMenu(button, note, person, access));
                      }
                    },
                  ),
                ),
              ),
        ],
      ),
      _errorAt('mine'),
      if (theirs.isNotEmpty) ...[
        _gap(),
        _Heading('Notes $first shares with you', count: theirs.length),
        SettingsGroup(
          children: [
            for (final note in theirs)
              _Row(
                key: ValueKey('theirs-${note.id}'),
                title: _titleOf(note),
                subtitle: [
                  (_sharing.spaceOf(note)?.canEdit ?? false)
                      ? 'You can edit'
                      : 'You can view',
                  edited(note),
                ].join(' · '),
                onTap: open == null ? null : () => open(note.id),
                trailing: Builder(
                  builder: (button) => _IconAction(
                    key: ValueKey('received-${note.id}'),
                    icon: KapyIcons.moreRounded,
                    tooltip: 'More for ${_titleOf(note)}',
                    onPressed: _idle
                        ? () => _receivedMenu(button, note, person)
                        : null,
                  ),
                ),
              ),
          ],
        ),
        _errorAt('theirs'),
      ],
      if (mine.isNotEmpty) ...[
        _gap(),
        const SettingsLabel('Stop sharing'),
        SettingsGroup(
          children: [
            _Row(
              title: 'Stop sharing with $first',
              subtitle:
                  '$first loses access to the ${_count(mine.length)} you '
                  'share. They stay in your notes, with every change.',
              trailing: SettingsRowButton(
                key: const ValueKey('stop-sharing-with'),
                label: 'Stop sharing',
                destructive: true,
                onPressed: _idle ? () => _stopSharingWith(person) : null,
              ),
            ),
          ],
        ),
        _errorAt('stop'),
      ],
    ];
  }

  /// The others besides [email] who are on [note], by first name.
  String? _alsoWith(Note note, String email) {
    final space = _sharing.spaceOf(note);
    if (space == null) return null;
    final names = [
      for (final other in space.peopleExcept(_sharing.userId))
        if ((other.member?.email ?? other.invite?.email)?.toLowerCase() !=
            email)
          _first(other.name),
    ];
    return names.isEmpty ? null : _listed(names);
  }
}

String _titleOf(Note note) {
  final title = note.title.trim();
  return title.isEmpty ? 'Untitled' : title;
}

String _listed(List<String> names) => switch (names.length) {
  1 => names.single,
  2 => '${names.first} and ${names.last}',
  _ => '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}',
};

/// Picks notes to share with one person, or with an address typed here.
///
/// Hidden notes are never listed, and it says so. Each note goes to the
/// person on its own, so the people already on it keep their access and get
/// nothing more. Closes with what to say about it.
class SharePicker extends StatefulWidget {
  const SharePicker({
    super.key,
    required this.sharing,
    required this.notes,
    this.person,
    this.displayTime = _asIs,
  });

  final Sharing sharing;
  final NotesStore notes;

  /// Null asks for their address.
  final SharePerson? person;
  final DateTime Function(DateTime) displayTime;

  @override
  State<SharePicker> createState() => _SharePickerState();
}

class _SharePickerState extends State<SharePicker> {
  final _email = TextEditingController();
  final _find = TextEditingController();
  final Set<String> _picked = {};
  SpaceRole _role = SpaceRole.member;
  bool _busy = false;
  String? _error;

  Sharing get _sharing => widget.sharing;

  @override
  void initState() {
    super.initState();
    _find.addListener(() => setState(() {}));
    _email.addListener(() {
      if (_error != null) setState(() => _error = null);
    });
  }

  @override
  void dispose() {
    _email.dispose();
    _find.dispose();
    super.dispose();
  }

  /// This account's own notes that can go to the person: private ones, and
  /// ones it shares from spaces it owns, but never a Hidden one.
  List<Note> get _candidates {
    final person = widget.person;
    final already = {
      if (person != null)
        for (final note in _sharing.notesSharedWith(person.email)) note.id,
    };
    final query = _find.text.trim().toLowerCase();
    return [
      for (final note in widget.notes.notes)
        if (!note.isHidden &&
            !already.contains(note.id) &&
            (note.spaceId == null ||
                (_sharing.spaceOf(note)?.isOwner ?? false)) &&
            (query.isEmpty || note.title.toLowerCase().contains(query)))
          note,
    ];
  }

  String _about(Note note) {
    final names = [
      for (final person
          in _sharing.spaceOf(note)?.peopleExcept(_sharing.userId) ??
              const <SpacePerson>[])
        person.name.trim().split(' ').first,
    ];
    if (names.isNotEmpty) {
      final who = names.length == 1 ? 'who keeps' : 'who keep';
      return 'Shared with ${_listed(names)}, $who access';
    }
    final edited = SidebarTimestamp.glance(
      note.updatedAt,
      now: DateTime.now(),
      displayTime: widget.displayTime,
      today: true,
    );
    return 'Private · edited $edited';
  }

  Future<void> _share() async {
    final person = widget.person;
    final email = (person?.email ?? _email.text).trim().toLowerCase();
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      setState(
        () => _error = email.isEmpty
            ? 'Add their email first'
            : '“$email” isn’t an email address',
      );
      return;
    }
    final ids = [
      for (final note in widget.notes.notes)
        if (_picked.contains(note.id)) note.id,
    ];
    setState(() {
      _busy = true;
      _error = null;
    });
    var done = 0;
    try {
      for (final id in ids) {
        try {
          await _sharing.addPerson(id, email, role: _role);
        } on SyncRefusedException catch (error) {
          if (error.code != termsRequiredCode || !mounted) rethrow;
          if (!await showSharingTermsSheet(context, sharing: _sharing)) return;
          await _sharing.addPerson(id, email, role: _role);
        }
        done++;
      }
      if (!mounted) return;
      final who = person == null ? email : person.name.trim().split(' ').first;
      Navigator.of(
        context,
      ).pop('Shared ${done == 1 ? '1 note' : '$done notes'} with $who');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _picked.removeAll(ids.take(done));
        _error = [
          if (done > 0) 'Shared $done of ${ids.length}.',
          describeSharingError(error),
        ].join(' ');
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chooseRole(BuildContext button) async {
    final box = button.findRenderObject() as RenderBox?;
    if (box == null) return;
    final chosen = await showKapyContextMenu<SpaceRole>(
      context: button,
      globalPosition: box.localToGlobal(Offset(0, box.size.height + 4)),
      items: const [
        PopupMenuItem(
          value: SpaceRole.member,
          height: 36,
          child: Text('Can edit'),
        ),
        PopupMenuItem(
          value: SpaceRole.viewer,
          height: 36,
          child: Text('Can view'),
        ),
      ],
    );
    if (chosen != null && mounted) setState(() => _role = chosen);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final person = widget.person;
    final who = person?.name.trim().split(' ').first;
    final candidates = _candidates;
    final count = _picked.length;
    final small = TextStyle(
      fontSize: AppTypeScale.small,
      height: 1.4,
      color: palette.textTertiary,
    );
    return Dialog(
      key: const ValueKey('share-picker'),
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500, maxHeight: 620),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Share with ${who ?? 'someone'}',
                style: TextStyle(
                  fontSize: AppTypeScale.title,
                  color: palette.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Choose the notes and what ${who ?? 'they'} can do',
                style: small,
              ),
              const SizedBox(height: 14),
              if (person == null) ...[
                _Field(
                  key: const ValueKey('picker-email'),
                  controller: _email,
                  hint: 'name@example.com',
                  label: 'Email',
                  autofocus: true,
                  keyboardType: TextInputType.emailAddress,
                ),
                const SizedBox(height: 12),
              ],
              _Field(
                key: const ValueKey('picker-find'),
                controller: _find,
                hint: 'Find a note…',
                label: 'Notes',
                autofocus: person != null,
              ),
              const SizedBox(height: 6),
              Flexible(
                child: candidates.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        child: Text(
                          _find.text.trim().isEmpty
                              ? 'No notes to share yet'
                              : 'No notes match “${_find.text.trim()}”',
                          textAlign: TextAlign.center,
                          style: small,
                        ),
                      )
                    : ListView(
                        shrinkWrap: true,
                        children: [
                          for (final note in candidates)
                            _PickRow(
                              key: ValueKey('pick-${note.id}'),
                              title: _titleOf(note),
                              subtitle: _about(note),
                              picked: _picked.contains(note.id),
                              onTap: _busy
                                  ? null
                                  : () => setState(() {
                                      if (!_picked.remove(note.id)) {
                                        _picked.add(note.id);
                                      }
                                    }),
                            ),
                        ],
                      ),
              ),
              const SizedBox(height: 8),
              Row(
                key: const ValueKey('picker-hidden-note'),
                children: [
                  KapyIcon(
                    KapyIcons.lockRounded,
                    size: 12,
                    color: palette.textTertiary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      "Hidden notes can't be shared, so they aren't listed.",
                      style: small,
                    ),
                  ),
                ],
              ),
              if (_error case final error?)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    error,
                    key: const ValueKey('picker-error'),
                    style: small.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Builder(
                    builder: (button) => SettingsMenuButton(
                      key: const ValueKey('picker-access'),
                      label: _role.canEdit ? 'Can edit' : 'Can view',
                      onPressed: () => unawaited(_chooseRole(button)),
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 6),
                  FilledButton(
                    key: const ValueKey('picker-share'),
                    onPressed: count == 0 || _busy ? null : _share,
                    child: Text(
                      _busy
                          ? 'Sharing…'
                          : count == 0
                          ? 'Share'
                          : 'Share ${count == 1 ? '1 note' : '$count notes'}',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Parts

/// A group's heading, with how many are in it and, at its end, the one thing
/// to do about them.
class _Heading extends StatelessWidget {
  const _Heading(this.text, {super.key, this.count = 0, this.action});

  final String text;
  final int count;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final label = SettingsLabel(text, detail: count > 0 ? '$count' : null);
    final action = this.action;
    if (action == null) return label;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(child: label),
        Padding(padding: const EdgeInsets.only(bottom: 6), child: action),
      ],
    );
  }
}

/// A row of a group: an optional face, words that may wrap, and whatever
/// sits at the end.
class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.titleLines = 1,
  });

  final String title;
  final int titleLines;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final subtitle = this.subtitle;
    final leading = this.leading;
    final trailing = this.trailing;
    final row = Container(
      constraints: BoxConstraints(minHeight: SettingsMetrics.minRowHeight),
      padding: SettingsMetrics.padding,
      child: Row(
        children: [
          if (leading != null) ...[
            leading,
            SizedBox(width: SettingsMetrics.gap),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: titleLines,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: SettingsMetrics.titleSize,
                    color: palette.textPrimary,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: SettingsMetrics.subtitleSize,
                      height: 1.35,
                      color: palette.textDescription,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            SizedBox(width: SettingsMetrics.gap),
            trailing,
          ],
        ],
      ),
    );
    final onTap = this.onTap;
    if (onTap == null) return row;
    return Semantics(
      button: true,
      child: InkWell(onTap: onTap, child: row),
    );
  }
}

/// An invitation to this account. The buttons go under the words where the
/// row is too narrow for both.
class _InviteRow extends StatelessWidget {
  const _InviteRow({
    super.key,
    required this.invite,
    required this.enabled,
    required this.onMenu,
    required this.onDecline,
    required this.onAccept,
  });

  final PendingInvite invite;
  final bool enabled;
  final ValueChanged<BuildContext> onMenu;
  final VoidCallback onDecline;
  final VoidCallback onAccept;

  @override
  Widget build(BuildContext context) {
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Builder(
          builder: (button) => _IconAction(
            key: ValueKey('invite-menu-${invite.token}'),
            icon: KapyIcons.moreRounded,
            tooltip: 'More',
            onPressed: enabled ? () => onMenu(button) : null,
          ),
        ),
        const SizedBox(width: 4),
        SettingsRowButton(
          key: ValueKey('decline-${invite.token}'),
          label: 'Decline',
          onPressed: enabled ? onDecline : null,
        ),
        const SizedBox(width: 6),
        SettingsRowButton(
          key: ValueKey('accept-${invite.token}'),
          label: 'Accept',
          prominent: true,
          onPressed: enabled ? onAccept : null,
        ),
      ],
    );
    // The address stays on an invitation: it comes from somebody you may not
    // know yet, and a name is only what they call themselves.
    final row = _Row(
      titleLines: 2,
      leading: _Face.forEmail(
        invite.invitedBy,
        name: invite.inviterDisplayName,
        extent: 28,
      ),
      title: invite.hasGeneratedSpaceName
          ? '${invite.inviterDisplayName} invited you to share notes'
          : '${invite.inviterDisplayName} invited you to ${invite.spaceName}',
      subtitle: [
        if (invite.invitedByName != null) invite.invitedBy,
        invite.role.canEdit ? 'Can edit' : 'Can view',
      ].join(' · '),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 560) {
          return Row(
            children: [
              Expanded(child: row),
              actions,
              SizedBox(width: SettingsMetrics.padding.right),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            row,
            Padding(
              padding: EdgeInsets.fromLTRB(
                0,
                0,
                SettingsMetrics.padding.right,
                SettingsMetrics.padding.bottom,
              ),
              child: Align(alignment: Alignment.centerRight, child: actions),
            ),
          ],
        );
      },
    );
  }
}

/// Someone's face, with a dot while they are in a shared note right now.
class _Face extends StatelessWidget {
  const _Face({required this.person, required this.here, required this.extent})
    : email = null,
      name = null;

  const _Face.forEmail(String this.email, {this.name, required this.extent})
    : person = null,
      here = false;

  final SharePerson? person;
  final String? email;
  final String? name;
  final bool here;
  final double extent;

  @override
  Widget build(BuildContext context) {
    final person = this.person;
    final face = ProfileAvatar(
      seed: person?.userId ?? person?.email ?? email!,
      name: person?.name ?? name ?? email!,
      image: person?.image,
      extent: extent,
    );
    if (!here) return face;
    final dot = extent / 4 + 3;
    return SizedBox.square(
      dimension: extent,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          face,
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              key: const ValueKey('here-now'),
              width: dot,
              height: dot,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Theme.of(context).colorScheme.primary,
                border: Border.all(
                  color: context.palette.cardBackground,
                  width: 1.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Chevron extends StatelessWidget {
  const _Chevron({this.open = false});

  final bool open;

  @override
  Widget build(BuildContext context) => KapyIcon(
    open ? KapyIcons.chevronDownRounded : KapyIcons.chevronRightRounded,
    size: SettingsMetrics.chevronSize,
    color: context.palette.textTertiary,
  );
}

class _IconAction extends StatelessWidget {
  const _IconAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final KapyIconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    onPressed: onPressed,
    tooltip: tooltip,
    constraints: BoxConstraints.tightFor(
      width: SettingsMetrics.controlHeight,
      height: SettingsMetrics.controlHeight,
    ),
    padding: EdgeInsets.zero,
    icon: KapyIcon(
      icon,
      size: AppControlMetrics.iconControl,
      color: onPressed == null
          ? context.palette.textTertiary
          : context.palette.textSecondary,
    ),
  );
}

/// The quiet line at the top while offline.
class _Quiet extends StatelessWidget {
  const _Quiet(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      fontSize: AppTypeScale.small,
      height: 1.4,
      color: context.palette.textSecondary,
    ),
  );
}

/// Where a pasted invitation goes in, opened from its row.
class _JoinField extends StatelessWidget {
  const _JoinField({
    required this.controller,
    required this.enabled,
    required this.onJoin,
  });

  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) => Padding(
    padding: SettingsMetrics.padding,
    child: Row(
      children: [
        Expanded(
          child: _Field(
            key: const ValueKey('join-code'),
            controller: controller,
            hint: 'kapynotes.com/join/… or code',
            enabled: enabled,
            autofocus: true,
            onSubmitted: enabled ? onJoin : null,
          ),
        ),
        const SizedBox(width: 8),
        SettingsRowButton(
          key: const ValueKey('join-submit'),
          label: 'Join',
          prominent: true,
          onPressed: enabled ? onJoin : null,
        ),
      ],
    ),
  );
}

/// A text field drawn as settings draws its wells.
class _Field extends StatelessWidget {
  const _Field({
    super.key,
    required this.controller,
    required this.hint,
    this.label,
    this.enabled = true,
    this.autofocus = false,
    this.keyboardType,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String hint;
  final String? label;
  final bool enabled;
  final bool autofocus;
  final TextInputType? keyboardType;
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadii.control),
      borderSide: BorderSide(
        color: palette.controlBorder,
        width: AppHairline.of(context),
      ),
    );
    final onSubmitted = this.onSubmitted;
    final field = TextField(
      controller: controller,
      enabled: enabled,
      autofocus: autofocus,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: keyboardType,
      onSubmitted: onSubmitted == null ? null : (_) => onSubmitted(),
      style: TextStyle(
        fontSize: AppTypeScale.control,
        color: palette.textPrimary,
      ),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(
          fontSize: AppTypeScale.control,
          color: palette.textTertiary,
        ),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        filled: true,
        fillColor: palette.surfaceBackground,
        enabledBorder: border,
        disabledBorder: border,
        focusedBorder: border.copyWith(
          borderSide: BorderSide(color: palette.selectedBorder, width: 0.75),
        ),
      ),
    );
    final label = this.label;
    if (label == null) return field;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: AppTypeScale.small,
            color: palette.textSecondary,
          ),
        ),
        const SizedBox(height: 4),
        field,
      ],
    );
  }
}

/// One note in the picker, ticked or not.
class _PickRow extends StatelessWidget {
  const _PickRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.picked,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final bool picked;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final onTap = this.onTap;
    return Semantics(
      checked: picked,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.control),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
          child: Row(
            children: [
              Checkbox(
                value: picked,
                onChanged: onTap == null ? null : (_) => onTap(),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppTypeScale.control,
                        color: palette.textPrimary,
                      ),
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppTypeScale.small,
                        color: palette.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A question before something that changes who sees what. With [option],
/// a box, ticked to begin with, whose answer comes back; null is no.
