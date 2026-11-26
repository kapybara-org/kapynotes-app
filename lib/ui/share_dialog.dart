import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../billing/billing.dart';
import '../core/platform.dart';
import '../core/popup_keyboard.dart';
import '../core/theme.dart';
import '../core/toast.dart';
import '../data/note.dart';
import '../sync/joining.dart';
import '../sync/presence.dart';
import '../sync/safety.dart';
import '../sync/sharing.dart';
import '../sync/spaces.dart';
import '../sync/sync_api.dart' show SyncRefusedException;
import 'account/encryption_pane.dart' show changeDate;
import 'billing/pro_sheet.dart';
import 'control_surface.dart';
import 'join/join_requests_panel.dart';
import 'join/joining_ui.dart';
import 'join/space_link_panel.dart';
import 'profile_avatar.dart';
import 'safety_dialogs.dart';
import 'settings_rows.dart' show SettingsSwitch;
import 'sharing_sheet.dart';

/// The share sheet for one note: who can see it, and what each of them may do.
///
/// Person first: a person is added by address, with the access they get, and
/// then they appear in the list with the same access, changeable one tap away.
/// Nothing here names a space, and nothing here can take the note away from
/// its owner.
///
/// When the note is already shared together with other notes, adding somebody
/// asks whether they get only this note or every note they would otherwise
/// join, so an invitation sent from one note never quietly opens the rest.
Future<void> showShareDialog(
  BuildContext context, {
  required Note note,
  required Sharing sharing,
  Billing? billing,
}) {
  keepMobilePopupKeyboardClosed();
  return showSharingSheet(
    context,
    (asSheet) => _NoteShareSheet(
      note: note,
      sharing: sharing,
      billing: billing,
      asSheet: asSheet,
    ),
  );
}

/// A whole shared space's people, opened from the list or from Settings,
/// without a note in hand. Its notes are managed from the notes themselves.
Future<void> showSpaceDialog(
  BuildContext context, {
  required String spaceId,
  required Sharing sharing,
}) {
  keepMobilePopupKeyboardClosed();
  return showSharingSheet(
    context,
    (asSheet) =>
        _SpaceShareSheet(spaceId: spaceId, sharing: sharing, asSheet: asSheet),
  );
}

/// Who a new person's invitation is for: this note on its own, or every note
/// in the space it is already shared in.
enum _Audience { thisNote, allNotes }

// ---------------------------------------------------------------------------
// The note's sheet
// ---------------------------------------------------------------------------

class _NoteShareSheet extends StatefulWidget {
  const _NoteShareSheet({
    required this.note,
    required this.sharing,
    required this.billing,
    required this.asSheet,
  });

  final Note note;
  final Sharing sharing;
  final Billing? billing;
  final bool asSheet;

  @override
  State<_NoteShareSheet> createState() => _NoteShareSheetState();
}

class _NoteShareSheetState extends State<_NoteShareSheet> {
  final _email = TextEditingController();
  final _focus = FocusNode();
  final _rows = FocusNode(canRequestFocus: false, skipTraversal: true);
  final _chips = <String>[];
  SpaceRole _role = SpaceRole.member;
  _Audience _audience = _Audience.thisNote;
  bool _busy = false;
  String? _error;
  String? _notice;
  String? _loadedLinkOf;

  Sharing get _sharing => widget.sharing;

  /// The note as it stands, so a move made while the sheet is open shows at
  /// once.
  Note get _note => _sharing.noteById(widget.note.id) ?? widget.note;

  Space? get _space {
    final note = _note;
    return note.spaceId == null ? null : _sharing.spaceById(note.spaceId);
  }

  bool get _isOwner => _space?.isOwner ?? true;

  @override
  void initState() {
    super.initState();
    _sharing.addListener(_changed);
    _sharing.presenceChanges.addListener(_changed);
    _focus.addListener(_changed);
    _rows.addListener(_changed);
    unawaited(_refreshQuietly());
  }

  @override
  void dispose() {
    _sharing.removeListener(_changed);
    _sharing.presenceChanges.removeListener(_changed);
    _focus.removeListener(_changed);
    _rows.removeListener(_changed);
    _focus.dispose();
    _rows.dispose();
    _email.dispose();
    // A removal held for Undo goes out once the sheet closes: after this
    // frame, since sending tells listeners at once and the tree is locked.
    final sharing = _sharing;
    final noteId = widget.note.id;
    scheduleMicrotask(() => sharing.sendHeldRemovalsQuietly(noteId));
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshQuietly() async {
    try {
      await _sharing.refresh();
    } on Object {
      // Offline: the sheet says so and the cached list is still worth showing.
    }
  }

  /// One action, with the sharing rules offered if the server asks for them
  /// first. A failure is said in the sheet and nowhere else.
  Future<void> _run(Future<void> Function() action, {String? notice}) async {
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      try {
        // A removal still held goes first, so nothing else is worked out
        // from people the sheet already shows gone.
        await _sharing.sendHeldRemovals(_note.id);
        await action();
      } on SyncRefusedException catch (error) {
        if (error.code != termsRequiredCode || !mounted) rethrow;
        setState(() => _busy = false);
        final accepted = await showSharingTermsSheet(
          context,
          sharing: _sharing,
        );
        if (!accepted || !mounted) return;
        setState(() => _busy = true);
        await action();
      }
      if (mounted && notice != null) setState(() => _notice = notice);
    } catch (error) {
      if (mounted) setState(() => _error = describeSharingError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _typed(String _) {
    if (_error == null && _notice == null) {
      setState(() {});
      return;
    }
    setState(() {
      _error = null;
      _notice = null;
    });
  }

  void _addChip(String email) {
    final address = email.trim().toLowerCase();
    if (address.isEmpty) return;
    setState(() {
      if (!_chips.contains(address)) _chips.add(address);
      _email.clear();
      _error = null;
      _notice = null;
    });
    _focus.requestFocus();
  }

  void _removeChip(String email) {
    setState(() => _chips.remove(email));
  }

  static bool _looksLikeEmail(String address) =>
      RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(address);

  static List<String> _split(String raw) => [
    for (final part in raw.split(RegExp(r'[,\s;]+')))
      if (part.trim().isNotEmpty) part.trim(),
  ];

  List<String> get _addresses => [
    ..._chips,
    for (final typed in _split(_email.text)) typed.toLowerCase(),
  ];

  /// Everybody who could be added from here: the people already shared with,
  /// minus those who can already see this note.
  List<SharePerson> get _suggestions {
    final space = _space;
    final taken = {
      for (final member in space?.othersThan(_sharing.userId) ?? const [])
        member.email.toLowerCase(),
      for (final invite in space?.invites ?? const [])
        invite.email.toLowerCase(),
    };
    final query = _email.text.trim().toLowerCase();
    return [
      for (final person in _sharing.people)
        if (!taken.contains(person.email) &&
            !_chips.contains(person.email) &&
            (query.isEmpty ||
                person.name.toLowerCase().contains(query) ||
                person.email.contains(query)))
          person,
    ].take(4).toList();
  }

  /// The notes this person would join when the note is shared with others.
  List<Note> get _otherNotes {
    final space = _space;
    if (space == null) return const [];
    return _sharing.notesIn(space.id);
  }

  Future<void> _share() async {
    final addresses = _addresses;
    if (addresses.isEmpty) {
      setState(() => _error = "Add someone's email first.");
      return;
    }
    for (final address in addresses) {
      if (!_looksLikeEmail(address)) {
        setState(() => _error = '“$address” isn’t an email address.');
        return;
      }
    }
    final allNotes = _audience == _Audience.allNotes;
    // Several people on a note nobody else is on go into one space made for
    // them, rather than one person's space with everybody else invited after.
    final group = _space == null && addresses.length > 1;
    await _run(() async {
      if (_note.isHidden) {
        throw const SyncRefusedException(409, 'hidden-note', {});
      }
      if (group) {
        final made = await _sharing.createSpace(groupSpaceName(addresses));
        try {
          for (final address in addresses) {
            await _sharing.invite(made.id, address, role: _role);
          }
        } catch (_) {
          await _endQuietly(made.id);
          rethrow;
        }
        await _sharing.shareNote(_note.id, spaceId: made.id);
      } else {
        for (final address in addresses) {
          await _sharing.addPerson(
            _note.id,
            address,
            role: _role,
            allNotes: allNotes,
          );
        }
      }
      setState(() {
        _chips.clear();
        _email.clear();
        _audience = _Audience.thisNote;
        _notice = addresses.length == 1
            ? 'Shared with ${_nameOf(addresses.single)}'
            : 'Shared with ${addresses.length} people';
      });
    });
  }

  /// What to call an address: the person's name when this account knows one.
  String _nameOf(String email) {
    for (final person in _sharing.people) {
      if (person.email == email.toLowerCase()) {
        return _firstName(person.name, email);
      }
    }
    return email;
  }

  String get _addingPhrase => _listedNames(_addresses.map(_nameOf).toList());

  static String _listedNames(List<String> names) => switch (names.length) {
    0 => '',
    1 => names.single,
    2 => '${names.first} and ${names.last}',
    _ => '${names.first} and ${names.length - 1} others',
  };

  String _peoplePhrase(Space space) =>
      space.peoplePhrase(_sharing.userId) ?? 'The people here';

  /// Access is for everything shared with that person together, so a change
  /// that reaches further than this note asks first, naming what else.
  Future<void> _changeAccess(String email, SpaceRole role) async {
    final name = _nameOf(email);
    final others = [
      for (final note in _sharing.notesIn(_note.spaceId!))
        if (!note.isHidden && note.id != _note.id) note,
    ];
    if (others.isNotEmpty) {
      final ok = await askFirst(
        context,
        title: role.canEdit ? 'Let $name edit?' : 'Let $name only view?',
        body: others.length == 1
            ? '$name sees this note together with “${others.single.title}”, '
                  'so the change is for both.'
            : '$name sees ${others.length + 1} notes you share together, '
                  'and the change is for all of them.',
        action: 'Change access',
      );
      if (ok == null || !mounted) return;
    }
    await _run(() async {
      await _sharing.changeAccessTo(_note.id, email, role);
      if (!mounted) return;
      Toast.show(
        context,
        '$name ${role.canEdit ? 'can edit' : 'can view'} now',
      );
    });
  }

  /// A person taken off one note. The removal is held on this device while
  /// the toast offers Undo, so Undo puts them back with nothing sent; it goes
  /// out when the toast does, or when the sheet closes first.
  Future<void> _removePerson(SpaceMember member) async {
    final name = member.firstName;
    final role = member.role;
    final ok = await askFirst(
      context,
      title: 'Remove $name from this note?',
      body:
          '$name stops seeing this note, and it leaves their devices. It '
          'stays in your notes, with everything $name wrote.',
      action: 'Remove',
    );
    if (ok != true || !mounted) return;
    await _run(() async {
      if (!mounted) return;
      final sharing = _sharing;
      final noteId = _note.id;
      sharing.holdRemoval(
        noteId,
        member.email,
        Toast.actionLifetime,
        onRefused: (error) {
          if (!mounted) return false;
          setState(() => _error = describeSharingError(error));
          return true;
        },
      );
      final overlay = Overlay.of(context, rootOverlay: true);
      Toast.show(
        context,
        'Removed $name from this note',
        icon: AppPlatform.hasPointer ? null : KapyIcons.checkCircleRounded,
        action: 'Undo',
        onAction: () => unawaited(
          undoSharing(overlay, () async {
            if (sharing.cancelRemoval(noteId, member.email)) {
              return '$name can see this note again';
            }
            await sharing.sendHeldRemovals(noteId);
            await sharing.addPerson(noteId, member.email, role: role);
            return sharing.memberOn(noteId, member.email) == null
                ? 'Invited $name again. They can see the note once they '
                      'accept.'
                : '$name can see this note again';
          }),
        ),
      );
    });
  }

  Future<void> _stopSharing() async {
    // Sends a removal still held first, so the ask names who is really on it.
    await _run(() async {});
    final space = _space;
    if (space == null || _error != null || !mounted) return;
    final audience = _sharing.audienceOf(space);
    final names = {for (final email in audience.keys) email: _nameOf(email)};
    final people = space.othersThan(_sharing.userId).length;
    final who = _peoplePhrase(space);
    final ok = await askFirst(
      context,
      title: 'Stop sharing “${_note.title}”?',
      body:
          '$who ${people > 1 ? 'lose' : 'loses'} access. The note '
          'stays in your notes, with every change.',
      action: 'Stop sharing',
    );
    if (ok != true || !mounted) return;
    await _run(() async {
      await _sharing.unshareNote(_note.id);
      if (!mounted) return;
      final sharing = _sharing;
      final noteId = _note.id;
      final overlay = Overlay.of(context, rootOverlay: true);
      Toast.show(
        context,
        'Stopped sharing “${_note.title}”',
        action: 'Undo',
        onAction: () => unawaited(
          undoSharing(overlay, () async {
            await sharing.shareNoteWithPeople(noteId, audience);
            final invited = [
              for (final email in audience.keys)
                if (sharing.memberOn(noteId, email) == null) names[email]!,
            ];
            if (invited.isEmpty) return '$who can see this note again';
            return 'Invited ${_listedNames(invited)} again. They can see the '
                'note once they accept.';
          }),
        ),
      );
    });
  }

  Future<void> _leave() async {
    final space = _space;
    if (space == null) return;
    final keep = await _askToLeave(
      context,
      sharing: _sharing,
      space: space,
      title: _note.title,
    );
    if (keep == null || !mounted) return;
    final leave = Navigator.of(context);
    await _run(() async {
      await _sharing.leave(space.id, keepCopies: keep);
      leave.pop();
    });
  }

  Future<void> _copyPrivate(Note note) async {
    await _run(() async {
      await _sharing.makePrivateCopy(note.id);
      if (!mounted) return;
      Toast.show(context, 'Copied to my notes');
    });
  }

  Future<void> _reportNote(Space space) => showReportDialog(
    context,
    sharing: _sharing,
    target: ReportTarget.note(
      spaceId: space.id,
      noteId: _note.id,
      noteBody: _note.body,
    ),
  );

  Future<void> _block(SpaceMember member) async {
    if (!await _askToBlock(context, member) || !mounted) return;
    final done = Navigator.of(context);
    final overlay = Overlay.of(context, rootOverlay: true);
    await _run(() async {
      await _sharing.blockEverywhere(member.email);
      Toast.showOn(overlay, 'Blocked ${member.displayName}');
      done.pop();
    }, notice: null);
  }

  Future<void> _copyLink(String token) async {
    final host = context;
    await Clipboard.setData(
      ClipboardData(text: _sharing.inviteLink(token).toString()),
    );
    if (host.mounted) Toast.show(host, 'Invitation link copied');
  }

  Future<void> _sendAgain(Space space, SpaceInvite invite) async {
    await _run(() async {
      await _sharing.invite(space.id, invite.email, role: invite.role);
      if (!mounted) return;
      setState(() => _notice = 'Sent again to ${invite.email}');
    });
  }

  Future<void> _cancelInvite(Space space, SpaceInvite invite) async {
    final ok = await askFirst(
      context,
      title: 'Cancel the invitation to ${invite.email}?',
      body:
          'The invitation and its link stop working. The note stays as it is.',
      action: 'Cancel invitation',
    );
    if (ok != true || !mounted) return;
    await _run(() async {
      await _sharing.revokeInvite(space.id, invite.token);
      if (!mounted) return;
      setState(() => _notice = 'Invitation to ${invite.email} cancelled');
    });
  }

  // -------------------------------------------------------------------------
  // The link
  // -------------------------------------------------------------------------

  void _loadLinkIfNeeded(Joining? joining) {
    final space = _space;
    if (joining == null || space == null) return;
    if (joining.knowsLinkOf(space.id) || _loadedLinkOf == space.id) return;
    _loadedLinkOf = space.id;
    unawaited(_loadLinkQuietly(joining, space.id));
  }

  Future<void> _loadLinkQuietly(Joining joining, String spaceId) async {
    try {
      await joining.loadLink(spaceId);
    } on Object {
      // Offline, or not the owner after all: the switch stays off.
    }
  }

  /// Turning the link on shows it to hand out at once; turning it off says it
  /// lets nobody else in.
  Future<void> _toggleLink(Joining joining, bool on) async {
    final space = _space;
    if (!on) {
      if (space == null) return;
      await _run(() async {
        await joining.turnOffLink(space.id);
        if (!mounted) return;
        setState(
          () => _notice =
              'The link is off, so it lets nobody else in. Everyone already '
              'in stays.',
        );
      });
      return;
    }
    await _run(() async {
      final link = space == null
          ? await _makeLinkFor(joining)
          : await joining.makeLink(
              space.id,
              role: SpaceRole.viewer,
              approval: false,
            );
      await Clipboard.setData(ClipboardData(text: link.url.toString()));
      if (!mounted) return;
      setState(
        () => _notice =
            'Link copied. Anyone who opens it can view, in Kapy Notes.',
      );
    });
  }

  /// A note shared by link: a space of its own, its link, then the note, so
  /// the link opens this note and nothing shared before it.
  Future<JoinLink> _makeLinkFor(Joining joining) async {
    if (_note.isHidden) {
      throw const SyncRefusedException(409, 'hidden-note', {});
    }
    final space = await _sharing.createSpace(kLinkSpaceName);
    try {
      final link = await joining.makeLink(
        space.id,
        role: SpaceRole.viewer,
        approval: false,
      );
      await _sharing.shareNote(_note.id, spaceId: space.id);
      return link;
    } catch (_) {
      await _endQuietly(space.id);
      rethrow;
    }
  }

  /// Ends a space this sheet just made for nobody. Best effort: if it cannot
  /// be ended now, it holds no notes, so it is harmless where it is.
  Future<void> _endQuietly(String spaceId) async {
    try {
      await _sharing.stopSharing(spaceId);
    } on Object {
      // Left for the owner to stop from the list; it shares nothing.
    }
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final space = _space;
    final owner = _isOwner;
    final joining = JoiningScope.of(context);
    _loadLinkIfNeeded(joining);
    final enabled = !_busy && !_sharing.isOffline;

    return _SheetScaffold(
      asSheet: widget.asSheet,
      title: _note.isHidden
          ? 'Private'
          : owner
          ? 'Share'
          : 'Shared with you',
      subtitle: _note.title,
      onClose: () => Navigator.of(context).pop(),
      more: space == null || owner
          ? null
          : _OverflowMenu(onReportNote: () => _reportNote(space)),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_note.isHidden)
            const _StatePanel(
              key: ValueKey('share-hidden'),
              icon: KapyIcons.lockRounded,
              title: 'Hidden notes stay private',
              body:
                  'Hidden notes are never shared. To share this one, take it '
                  'out of Hidden first.',
            )
          else if (_outOfPro)
            _StatePanel(
              key: const ValueKey('share-free'),
              icon: KapyIcons.groupOutlined,
              title: 'Sharing is part of Pro',
              body:
                  'Share notes with the people you choose and edit together. '
                  'The people you invite don’t need Pro.',
              action: FilledButton(
                onPressed: () =>
                    showProSheet(context, billing: widget.billing!),
                child: const Text('See Pro'),
              ),
            )
          else if (!owner)
            ..._memberBody(context, space!)
          else
            ..._ownerBody(context, space, joining, enabled),
        ],
      ),
      actions: _actions(space: space, owner: owner, enabled: enabled),
    );
  }

  /// Only when the server says this account can't share: an account whose
  /// plan has not been answered yet, or that the server lets share without
  /// Pro, is not told sharing is closed to it.
  bool get _outOfPro =>
      _space == null && widget.billing?.entitlements?.sharing == false;

  List<Widget> _ownerBody(
    BuildContext context,
    Space? space,
    Joining? joining,
    bool enabled,
  ) {
    final firstUse = _sharing.teams.isEmpty && space == null;
    final others = _otherNotes;
    final questionsScope = space != null && others.length > 1;
    return [
      if (firstUse) ...[
        const _Intro(key: ValueKey('share-first-use')),
        const SizedBox(height: 16),
      ],
      if (_sharing.isOffline) ...[
        const _Banner(
          key: ValueKey('share-offline'),
          icon: KapyIcons.wifiOffRounded,
          text:
              'You’re offline. Sharing changes need a connection. Your note '
              'is safe.',
        ),
        const SizedBox(height: 12),
      ],
      if (_chips.isNotEmpty) ...[
        _Chips(emails: _chips, onRemove: enabled ? _removeChip : null),
        const SizedBox(height: 8),
      ],
      _EmailField(
        controller: _email,
        focus: _focus,
        enabled: enabled,
        onChanged: _typed,
        onSubmit: enabled ? () => unawaited(_share()) : null,
      ),
      if (_focus.hasFocus || _rows.hasFocus || _email.text.isNotEmpty)
        // The field's own: they show only while it has focus, so a press on
        // one must not take that focus away before it lifts.
        TextFieldTapRegion(
          child: Focus(
            focusNode: _rows,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final person in _suggestions)
                  _SuggestionRow(
                    key: ValueKey('share-suggest-${person.email}'),
                    person: person,
                    onTap: enabled ? () => _addChip(person.email) : null,
                  ),
              ],
            ),
          ),
        ),
      if (questionsScope && (_chips.isNotEmpty || _email.text.isNotEmpty)) ...[
        const SizedBox(height: 14),
        _ScopeChoice(
          noteId: _note.id,
          noteTitle: _note.title.trim().isEmpty ? 'This note' : _note.title,
          who: _addingPhrase,
          shared: _peoplePhrase(space),
          notes: others,
          selected: _audience,
          enabled: enabled,
          onChanged: (value) => setState(() => _audience = value),
        ),
      ],
      if (_chips.isNotEmpty || _email.text.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text(
          'They’ll get an email and see it in Shared',
          style: TextStyle(
            fontSize: AppTypeScale.caption,
            color: context.palette.textTertiary,
          ),
        ),
      ],
      SizedBox(height: widget.asSheet ? 6 : 10),
      _AccessAndShare(
        role: _role,
        enabled: enabled,
        busy: _busy,
        onRole: (role) => setState(() => _role = role),
        onShare: _share,
      ),
      if (_notice case final notice?) ...[
        const SizedBox(height: 12),
        _Message(notice),
      ],
      if (_error case final error?) ...[
        const SizedBox(height: 12),
        _Message(error, key: const ValueKey('share-error'), isError: true),
      ],
      if (space != null) ...[
        const SizedBox(height: 4),
        _PeopleWithAccess(
          sharing: _sharing,
          space: space,
          noteId: _note.id,
          busy: !enabled,
          onAccess: _changeAccess,
          removeLabel: 'Remove from this note',
          onRemove: _removePerson,
          onBlock: _block,
          onReport: (member) => showReportDialog(
            context,
            sharing: _sharing,
            target: ReportTarget.member(
              spaceId: space.id,
              email: member.email,
              name: member.displayName,
            ),
          ),
          onCopyLink: _copyLink,
          onSendAgain: (invite) => _sendAgain(space, invite),
          onCancelInvite: (invite) => _cancelInvite(space, invite),
        ),
      ],
      if (joining != null) ...[
        _LinkRow(
          joining: joining,
          spaceId: space?.id,
          enabled: enabled,
          opensMore: (space?.liveNotes ?? 0) > 1
              ? 'The link opens ${_notesPhrase(space!.liveNotes)} here, not '
                    'only this one.'
              : null,
          onToggle: (on) => _toggleLink(joining, on),
          onCopy: _copyLinkOf,
        ),
      ],
    ];
  }

  Future<void> _copyLinkOf(JoinLink link) async {
    final host = context;
    await Clipboard.setData(ClipboardData(text: link.url.toString()));
    if (host.mounted) Toast.show(host, 'Link copied');
  }

  List<Widget> _memberBody(BuildContext context, Space space) {
    final owner = space.member(space.ownerId);
    final me = space.member(_sharing.userId);
    final others = [
      for (final member in space.othersThan(_sharing.userId))
        if (!member.isOwner) member,
    ];
    final waiting = !_sharing.holdsKey(space.id);
    return [
      if (waiting) ...[
        _Banner(icon: KapyIcons.hourglassRounded, text: waitingForAccessText),
      ],
      const _Label('People with access'),
      Column(
        children: [
          if (owner != null)
            _PersonRow(
              key: ValueKey('member-row-${owner.userId}'),
              name: owner.displayName,
              detail: owner.email,
              trailing: const _RoleText('Owner'),
            ),
          if (me != null)
            _PersonRow(
              key: ValueKey('member-row-${me.userId}'),
              name: me.displayName,
              label: 'You',
              detail: me.role.canEdit
                  ? 'You can edit this note'
                  : 'You can only view this note',
              trailing: _RoleText(me.role.canEdit ? 'Can edit' : 'Can view'),
            ),
          for (final member in others)
            _PersonRow(
              key: ValueKey('member-row-${member.userId}'),
              name: member.displayName,
              detail: member.email,
              trailing: _RoleText(
                member.role.canEdit ? 'Can edit' : 'Can view',
              ),
            ),
        ],
      ),
      const SizedBox(height: 10),
      Text(
        'Only ${space.shortNameOf(space.ownerId)} can add people or change '
        'access.',
        style: TextStyle(
          fontSize: AppTypeScale.caption,
          color: context.palette.textTertiary,
          height: 1.4,
        ),
      ),
      if (_error case final error?) ...[
        const SizedBox(height: 12),
        _Message(error, key: const ValueKey('share-error'), isError: true),
      ],
    ];
  }

  List<_FooterAction> _actions({
    required Space? space,
    required bool owner,
    required bool enabled,
  }) {
    if (space == null || _note.isHidden || _outOfPro) return const [];
    if (!owner) {
      return [
        (
          key: const ValueKey('copy-note'),
          label: 'Make a private copy',
          onPressed: enabled ? () => _copyPrivate(_note) : null,
        ),
        (
          key: const ValueKey('leave-space'),
          label: 'Leave',
          onPressed: enabled ? _leave : null,
        ),
      ];
    }
    return [
      (
        key: const ValueKey('stop-sharing'),
        label: 'Stop sharing',
        onPressed: enabled ? _stopSharing : null,
      ),
    ];
  }
}

/// What a member is told while the key to the space has not reached them.
const String waitingForAccessText =
    'Waiting for someone to let you in. The note opens in a moment.';

// ---------------------------------------------------------------------------
// The space's sheet
// ---------------------------------------------------------------------------

class _SpaceShareSheet extends StatefulWidget {
  const _SpaceShareSheet({
    required this.spaceId,
    required this.sharing,
    required this.asSheet,
  });

  final String spaceId;
  final Sharing sharing;
  final bool asSheet;

  @override
  State<_SpaceShareSheet> createState() => _SpaceShareSheetState();
}

class _SpaceShareSheetState extends State<_SpaceShareSheet> {
  final _email = TextEditingController();
  SpaceRole _role = SpaceRole.member;
  bool _busy = false;
  String? _error;
  String? _notice;

  Sharing get _sharing => widget.sharing;
  Space? get _space => _sharing.spaceById(widget.spaceId);

  @override
  void initState() {
    super.initState();
    _sharing.addListener(_changed);
    unawaited(_refreshQuietly());
  }

  @override
  void dispose() {
    _sharing.removeListener(_changed);
    _email.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshQuietly() async {
    try {
      await _sharing.refresh();
    } on Object {
      // Offline: the cached list is still worth showing.
    }
  }

  Future<void> _run(Future<void> Function() action, {String? notice}) async {
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      try {
        await action();
      } on SyncRefusedException catch (error) {
        if (error.code != termsRequiredCode || !mounted) rethrow;
        setState(() => _busy = false);
        final accepted = await showSharingTermsSheet(
          context,
          sharing: _sharing,
        );
        if (!accepted || !mounted) return;
        setState(() => _busy = true);
        await action();
      }
      if (mounted && notice != null) setState(() => _notice = notice);
    } catch (error) {
      if (mounted) setState(() => _error = describeSharingError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _block(SpaceMember member) async {
    if (!await _askToBlock(context, member) || !mounted) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    await _run(() async {
      await _sharing.blockEverywhere(member.email);
      Toast.showOn(overlay, 'Blocked ${member.displayName}');
    });
  }

  Future<void> _leave(Space space) async {
    final keep = await _askToLeave(
      context,
      sharing: _sharing,
      space: space,
      title:
          [
            for (final note in _sharing.notesIn(space.id))
              if (!note.isHidden) note.title,
          ].firstOrNull ??
          space.titleFor(_sharing.userId),
    );
    if (keep == null || !mounted) return;
    final leave = Navigator.of(context);
    await _run(() async {
      await _sharing.leave(space.id, keepCopies: keep);
      leave.pop();
    });
  }

  /// The notes here that the people in it see, Hidden ones left out.
  List<Note> _notesOf(Space space) => [
    for (final note in _sharing.notesIn(space.id))
      if (!note.isHidden) note,
  ];

  /// Someone taken off every note here, asked first as the note's sheet asks,
  /// with one tap to invite them back.
  Future<void> _removePerson(Space space, SpaceMember member) async {
    final name = member.firstName;
    final many = _notesOf(space).length > 1;
    final where = many ? 'these notes' : 'this note';
    final ok = await askFirst(
      context,
      title: 'Remove $name from $where?',
      body: many
          ? '$name stops seeing these notes, and they leave $name’s devices. '
                'They stay in your notes, with everything $name wrote.'
          : '$name stops seeing this note, and it leaves their devices. It '
                'stays in your notes, with everything $name wrote.',
      action: 'Remove',
    );
    if (ok != true || !mounted) return;
    await _run(() async {
      await _sharing.removeMember(space.id, member.userId);
      if (!mounted) return;
      final sharing = _sharing;
      final overlay = Overlay.of(context, rootOverlay: true);
      Toast.show(
        context,
        'Removed $name from $where',
        action: 'Undo',
        onAction: () => unawaited(
          undoSharing(overlay, () async {
            await sharing.invite(space.id, member.email, role: member.role);
            return 'Invitation sent to ${member.email}';
          }),
        ),
      );
    });
  }

  /// Ends the share, asked first as the note's sheet asks, with one tap to
  /// share the same notes with the same people again.
  Future<void> _stopSharing(Space space) async {
    final notes = _notesOf(space);
    final audience = _sharing.audienceOf(space);
    final people = space.othersThan(_sharing.userId).length;
    final who = space.peoplePhrase(_sharing.userId) ?? 'The people here';
    final what = switch (notes.length) {
      0 => '',
      1 => ' “${notes.single.title}”',
      final count => ' $count notes',
    };
    final ok = await askFirst(
      context,
      title: 'Stop sharing$what?',
      body:
          '$who ${people > 1 ? 'lose' : 'loses'} access. '
          '${switch (notes.length) {
            0 => 'Everything here stays',
            1 => 'The note stays',
            _ => 'The notes stay',
          }} in your notes, with every change.',
      action: 'Stop sharing',
    );
    if (ok != true || !mounted) return;
    final close = Navigator.of(context);
    await _run(() async {
      await _sharing.stopSharing(space.id);
      if (!mounted) return;
      final sharing = _sharing;
      final overlay = Overlay.of(context, rootOverlay: true);
      Toast.show(
        context,
        'Stopped sharing$what',
        action: notes.isEmpty ? null : 'Undo',
        onAction: () => unawaited(
          undoSharing(overlay, () async {
            final again = await sharing.shareNoteWithPeople(
              notes.first.id,
              audience,
            );
            for (final note in notes.skip(1)) {
              await sharing.shareNote(note.id, spaceId: again.id);
            }
            if (notes.any(
              (note) => audience.keys.any(
                (email) => sharing.memberOn(note.id, email) != null,
              ),
            )) {
              return 'Shared again with $who';
            }
            return audience.length == 1
                ? 'Invitation sent to $who'
                : 'Invitations sent to $who';
          }),
        ),
      );
      close.pop();
    });
  }

  /// Access is for every note here, so a change that covers more than one
  /// asks first, as the note's sheet and Settings do.
  Future<void> _changeAccess(Space space, String email, SpaceRole role) async {
    final member = space
        .othersThan(_sharing.userId)
        .where((member) => member.email.toLowerCase() == email.toLowerCase())
        .firstOrNull;
    if (member == null) return;
    final name = member.firstName;
    final together = _notesOf(space).length;
    if (together > 1) {
      final ok = await askFirst(
        context,
        title: role.canEdit ? 'Let $name edit?' : 'Let $name only view?',
        body:
            '$name sees $together notes you share together, and the change '
            'is for all of them.',
        action: 'Change access',
      );
      if (ok == null || !mounted) return;
    }
    await _run(
      () => _sharing.changeAccess(space.id, member.userId, role),
      notice: 'Access changed',
    );
  }

  /// The join panels share this sheet's one way of running an action.
  Future<void> _panelRun(
    Future<void> Function() action, {
    String waiting = 'Updating sharing…',
    String? done,
    String? success,
  }) => _run(action, notice: done ?? success);

  Future<void> _invite() async {
    final space = _space;
    final email = _email.text.trim();
    if (space == null) return;
    if (!_NoteShareSheetState._looksLikeEmail(email)) {
      setState(() => _error = 'Enter an email address.');
      return;
    }
    await _run(() async {
      await _sharing.invite(space.id, email, role: _role);
      _email.clear();
      if (mounted) setState(() => _notice = 'Invitation sent to $email');
    });
  }

  @override
  Widget build(BuildContext context) {
    final space = _space;
    final enabled = !_busy && !_sharing.isOffline;
    final joining = JoiningScope.of(context);
    return _SheetScaffold(
      asSheet: widget.asSheet,
      title: space?.titleFor(_sharing.userId) ?? 'Shared notes',
      subtitle: 'Who can see these notes',
      onClose: () => Navigator.of(context).pop(),
      body: space == null
          ? const _StatePanel(
              key: ValueKey('space-missing'),
              icon: KapyIcons.groupOutlined,
              title: 'This share has ended',
              body: 'Nobody else can see its notes now.',
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _PeopleWithAccess(
                  sharing: _sharing,
                  space: space,
                  busy: !enabled,
                  onAccess: (email, role) => _changeAccess(space, email, role),
                  removeLabel: _notesOf(space).length > 1
                      ? 'Remove from these notes'
                      : 'Remove from this note',
                  onRemove: (member) => _removePerson(space, member),
                  onBlock: _block,
                  onReport: (member) => showReportDialog(
                    context,
                    sharing: _sharing,
                    target: ReportTarget.member(
                      spaceId: space.id,
                      email: member.email,
                      name: member.displayName,
                    ),
                  ),
                  onCopyLink: (token) async {
                    await Clipboard.setData(
                      ClipboardData(
                        text: _sharing.inviteLink(token).toString(),
                      ),
                    );
                    if (context.mounted) {
                      Toast.show(context, 'Invitation link copied');
                    }
                  },
                  onSendAgain: (invite) => _run(
                    () => _sharing.invite(
                      space.id,
                      invite.email,
                      role: invite.role,
                    ),
                    notice: 'Sent again to ${invite.email}',
                  ),
                  onCancelInvite: (invite) => _run(
                    () => _sharing.revokeInvite(space.id, invite.token),
                    notice: 'Invitation to ${invite.email} cancelled',
                  ),
                ),
                if (space.isOwner) ...[
                  const _Label('Add someone by email'),
                  _AccessAndShare(
                    role: _role,
                    enabled: enabled && _sharing.holdsKey(space.id),
                    busy: _busy,
                    field: _EmailField(
                      controller: _email,
                      enabled: enabled,
                      onChanged: (_) => setState(() {
                        _error = null;
                        _notice = null;
                      }),
                      onSubmit: _invite,
                      hint: 'Email address',
                    ),
                    action: 'Invite',
                    onRole: (role) => setState(() => _role = role),
                    onShare: _invite,
                  ),
                  if (joining != null) ...[
                    const SizedBox(height: 18),
                    SpaceLinkPanel(
                      spaceId: space.id,
                      joining: joining,
                      run: _panelRun,
                      scope: space.liveNotes > 1
                          ? 'It opens ${_notesPhrase(space.liveNotes)} shared '
                                'here, not only the one you are in.'
                          : null,
                      enabled: enabled,
                    ),
                    JoinRequestsPanel(
                      spaceId: space.id,
                      joining: joining,
                      run: _panelRun,
                      enabled: enabled,
                    ),
                  ],
                ],
                if (_notice case final notice?) ...[
                  const SizedBox(height: 12),
                  _Message(notice),
                ],
                if (_error case final error?) ...[
                  const SizedBox(height: 12),
                  _Message(
                    error,
                    key: const ValueKey('share-error'),
                    isError: true,
                  ),
                ],
              ],
            ),
      actions: _actions(space, enabled),
    );
  }

  List<_FooterAction> _actions(Space? space, bool enabled) {
    if (space == null) return const [];
    return [
      if (space.isOwner)
        (
          key: const ValueKey('stop-sharing'),
          label: 'Stop sharing',
          onPressed: enabled ? () => _stopSharing(space) : null,
        )
      else
        (
          key: const ValueKey('leave-space'),
          label: 'Leave',
          onPressed: enabled ? () => _leave(space) : null,
        ),
    ];
  }
}

// ---------------------------------------------------------------------------
// Pieces both sheets use
// ---------------------------------------------------------------------------

/// Asks before blocking [member]. Blocking ends everything shared between
/// this account and them, so the question says so.
Future<bool> _askToBlock(BuildContext context, SpaceMember member) async {
  final name = member.firstName;
  return await askFirst(
        context,
        title: 'Block ${member.displayName}?',
        body:
            '$name loses access to everything you share, you leave what $name '
            'shares with you (keeping copies), and $name can’t invite you '
            'again.',
        action: 'Block',
      ) ==
      true;
}

/// Asks before leaving [space], named by the note [title], and whether to
/// keep copies; null means no. Leaving takes every note in the space, so
/// with more than one the question counts them.
Future<bool?> _askToLeave(
  BuildContext context, {
  required Sharing sharing,
  required Space space,
  required String title,
}) {
  final owner = space.shortNameOf(space.ownerId);
  final together = [
    for (final note in sharing.notesIn(space.id))
      if (!note.isHidden) note,
  ].length;
  return askFirst(
    context,
    title: together > 1
        ? 'Leave $together notes from $owner?'
        : 'Leave “$title”?',
    body: together > 1
        ? '$owner shares “$title” together with ${together - 1} more, so '
              'you leave all of them. You stop seeing $owner’s changes, and '
              '$owner keeps the notes.'
        : 'You stop seeing $owner’s changes. $owner keeps the note.',
    action: 'Leave',
    option: together > 1
        ? 'Keep private copies'
        : 'Keep a private copy in my notes',
  );
}

/// Marks what sits on a phone sheet, so the pieces both sheets use take the
/// phone's measurements there and the Mac dialog's everywhere else.
class _OnPhone extends InheritedWidget {
  const _OnPhone({required super.child});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_OnPhone>() != null;

  @override
  bool updateShouldNotify(_OnPhone oldWidget) => false;
}

/// A footer action beside Done, in words only.
typedef _FooterAction = ({Key key, String label, VoidCallback? onPressed});

/// A dialog on a desktop, a sheet with a grab handle on a phone: the same
/// header, body and footer either way, at each one's measurements.
class _SheetScaffold extends StatelessWidget {
  const _SheetScaffold({
    required this.asSheet,
    required this.title,
    required this.subtitle,
    required this.onClose,
    required this.body,
    this.actions = const [],
    this.more,
  });

  final bool asSheet;
  final String title;
  final String subtitle;
  final VoidCallback onClose;
  final Widget body;
  final List<_FooterAction> actions;

  /// The quiet menu beside close, for what is rare enough not to earn a row.
  final Widget? more;

  @override
  Widget build(BuildContext context) {
    final content = Builder(
      builder: (context) {
        final palette = context.palette;
        final phone = asSheet;
        ButtonStyle text(Color color) => TextButton.styleFrom(
          foregroundColor: color,
          minimumSize: Size(0, phone ? 44 : 28),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: chromeStyle(
            size: phone ? 15 : 13,
            line: phone ? 20 : 18,
            weight: AppWeight.button,
            color: color,
          ),
        );
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(
              title: title,
              subtitle: subtitle,
              onClose: onClose,
              more: more,
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: body,
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: palette.textPrimary.withValues(alpha: 0.06),
                    width: AppHairline.of(context),
                  ),
                ),
              ),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  12,
                  phone ? 4 : 8,
                  12,
                  phone ? 0 : 8,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          for (final action in actions)
                            TextButton(
                              key: action.key,
                              onPressed: action.onPressed,
                              style: text(palette.textSecondary),
                              child: Text(action.label),
                            ),
                        ],
                      ),
                    ),
                    TextButton(
                      key: const ValueKey('share-done'),
                      onPressed: onClose,
                      style: text(palette.textPrimary),
                      child: const Text('Done'),
                    ),
                  ],
                ),
              ),
            ),
            // A phone's sheet opens the same room in its frame.
            if (!phone) const ToastClearance.room(),
          ],
        );
      },
    );
    if (asSheet) return SharingSheetFrame(child: _OnPhone(child: content));
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: context.palette.textPrimary.withValues(alpha: 0.08),
          width: AppHairline.of(context),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Semantics(
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: title,
        child: SizedBox(
          key: const ValueKey('share-dialog'),
          width: 480,
          child: content,
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.subtitle,
    required this.onClose,
    this.more,
  });

  final String title;
  final String subtitle;
  final VoidCallback onClose;
  final Widget? more;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final phone = _OnPhone.of(context);
    final box = phone ? 44.0 : 28.0;
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: phone ? 52 : 0),
      child: Padding(
        padding: phone
            ? const EdgeInsets.fromLTRB(20, 0, 8, 4)
            : const EdgeInsets.fromLTRB(20, 16, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: chromeStyle(
                        size: phone ? 17 : 15,
                        line: phone ? 22 : 20,
                        weight: AppWeight.page,
                        color: palette.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    key: const ValueKey('share-subtitle'),
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: chromeStyle(
                      size: phone ? 13 : 12,
                      line: 16,
                      weight: AppWeight.body,
                      color: palette.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            if (more != null) SizedBox.square(dimension: box, child: more),
            SizedBox.square(
              dimension: box,
              child: IconButton(
                key: const ValueKey('share-dialog-close'),
                tooltip: 'Close',
                padding: EdgeInsets.zero,
                onPressed: onClose,
                icon: KapyIcon(
                  KapyIcons.closeRounded,
                  size: phone ? 20 : 16,
                  color: palette.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The three promises, until this account has shared once.
class _Intro extends StatelessWidget {
  const _Intro({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    const lines = [
      (
        KapyIcons.lockRounded,
        'Only the people you add can read it. Not even Kapy can.',
      ),
      (KapyIcons.editOutlined, 'Choose who can edit and who can only view.'),
      (
        KapyIcons.restoreRounded,
        'Stop sharing any time. The note stays with you.',
      ),
    ];
    return KapyControlSurface(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (icon, text) in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: KapyIcon(
                      icon,
                      size: AppControlMetrics.iconAdornment,
                      color: palette.textTertiary,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      text,
                      style: TextStyle(
                        fontSize: AppTypeScale.small,
                        color: palette.textSecondary,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Who is on the note, and what each of them may do.
class _PeopleWithAccess extends StatelessWidget {
  const _PeopleWithAccess({
    required this.sharing,
    required this.space,
    this.noteId,
    required this.busy,
    required this.onAccess,
    required this.removeLabel,
    required this.onRemove,
    required this.onBlock,
    required this.onReport,
    required this.onCopyLink,
    required this.onSendAgain,
    required this.onCancelInvite,
  });

  final Sharing sharing;
  final Space space;

  /// The note this list is for, whose removals held for Undo it leaves out
  /// until they miss the server and wait to go again.
  final String? noteId;
  final bool busy;
  final void Function(String email, SpaceRole role) onAccess;

  /// What taking someone off is called here: this note, or every note in
  /// the share.
  final String removeLabel;
  final ValueChanged<SpaceMember> onRemove;
  final ValueChanged<SpaceMember> onBlock;
  final ValueChanged<SpaceMember> onReport;
  final ValueChanged<String> onCopyLink;
  final ValueChanged<SpaceInvite> onSendAgain;
  final ValueChanged<SpaceInvite> onCancelInvite;

  @override
  Widget build(BuildContext context) {
    final me = sharing.userId;
    final noteId = this.noteId;
    final present = {
      for (final person in sharing.presentIn(space.id)) person.userId: person,
    };
    final warnings = sharing.trust.warningsFor(space.id);
    final members = [
      for (final member in space.members)
        if (noteId == null ||
            !sharing.isRemovalHeld(noteId, member.email) ||
            sharing.isRemovalWaiting(noteId, member.email))
          member,
    ];
    final here = [
      ...members.where((m) => m.userId == me),
      ...members.where((m) => m.userId != me && present.containsKey(m.userId)),
      ...members.where((m) => m.userId != me && !present.containsKey(m.userId)),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final warning in warnings)
          _Banner(
            icon: KapyIcons.warningRounded,
            isWarning: true,
            text: switch (space.member(warning.userId)) {
              SpaceMember(:final displayName, :final identityResetAt?) =>
                '$displayName reset encryption on '
                    '${changeDate(identityResetAt)}, so their safety code '
                    'changed. Shared notes aren’t affected. Compare safety '
                    'codes before trusting it: ${warning.current}',
              final member =>
                '${member?.displayName ?? warning.email}’s safety code '
                    'changed. If they set up a new account, compare this '
                    'safety code with them before trusting it: '
                    '${warning.current}',
            },
            action: TextButton(
              onPressed: () => sharing.trustNewKey(warning),
              child: const Text('Trust this safety code'),
            ),
          ),
        const _Label('People with access'),
        Column(
          key: const ValueKey('share-access-card'),
          children: [
            for (final member in here)
              _PersonRow(
                key: ValueKey('member-row-${member.userId}'),
                name: member.displayName,
                label: member.userId == me ? 'You' : null,
                detail: _detailFor(member, present[member.userId]),
                live: present.containsKey(member.userId),
                trailing: member.userId == me
                    ? _RoleText(member.isOwner ? 'Owner' : 'You')
                    : member.isOwner
                    ? const _RoleText('Owner')
                    : noteId != null &&
                          sharing.isRemovalWaiting(noteId, member.email)
                    ? const _RoleText('Removing…')
                    : _MemberMenu(
                        key: ValueKey('member-menu-${member.userId}'),
                        role: member.role,
                        enabled: !busy,
                        canManage: space.isOwner,
                        canRemove: space.isOwner,
                        removeLabel: removeLabel,
                        onAccess: (role) => onAccess(member.email, role),
                        onReport: () => onReport(member),
                        onBlock: () => onBlock(member),
                        onRemove: () => onRemove(member),
                      ),
              ),
            for (final invite in space.invites)
              _PersonRow(
                key: ValueKey('invite-row-${invite.token}'),
                invited: true,
                name: invite.email,
                detail: '${_accessLabel(invite.role)} · waiting to join',
                trailing: _InviteMenu(
                  key: ValueKey('invite-menu-${invite.token}'),
                  enabled: !busy && space.isOwner,
                  onCopyLink: () => onCopyLink(invite.token),
                  onSendAgain: () => onSendAgain(invite),
                  onCancel: () => onCancelInvite(invite),
                ),
              ),
          ],
        ),
      ],
    );
  }

  String _detailFor(SpaceMember member, Collaborator? present) {
    if (present != null) return present.typing ? 'Typing…' : 'Here now';
    if (!member.hasKey) {
      return member.x25519Public == null
          ? 'Hasn’t unlocked yet'
          : 'Waiting for access';
    }
    return member.email;
  }
}

String _accessLabel(SpaceRole role) => role.canEdit ? 'Can edit' : 'Can view';

/// Two notes are both notes; more are counted.
String _notesPhrase(int count) =>
    count == 2 ? 'both notes' : 'all $count notes';

/// One person: their face, their name, and what they may do.
class _PersonRow extends StatelessWidget {
  const _PersonRow({
    super.key,
    required this.name,
    this.label,
    required this.detail,
    this.trailing,
    this.invited = false,
    this.live = false,
  });

  /// Who they are: what their face is drawn from.
  final String name;

  /// What the row calls them when that isn't [name]: "You".
  final String? label;
  final String detail;
  final Widget? trailing;
  final bool invited;

  /// [detail] says what they are doing right now: typing, or here. Their face
  /// carries the sage dot while it does.
  final bool live;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final phone = _OnPhone.of(context);
    final avatar = phone ? 32.0 : 28.0;
    final dot = phone ? 12.0 : 10.0;
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: phone ? 56 : 44),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                if (invited)
                  Container(
                    key: const ValueKey('invite-face'),
                    width: avatar,
                    height: avatar,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: palette.textPrimary.withValues(alpha: 0.07),
                    ),
                    child: KapyIcon(
                      KapyIcons.mailOutlined,
                      size: phone ? 16 : 14,
                      color: palette.textTertiary,
                    ),
                  )
                else
                  ProfileAvatar(extent: avatar, name: name),
                if (live)
                  Positioned(
                    key: const ValueKey('presence-dot'),
                    right: -1,
                    bottom: -1,
                    child: Container(
                      width: dot,
                      height: dot,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: palette.accentText,
                        border: Border.all(
                          color: phone
                              ? palette.cardBackground
                              : palette.surfaceBackground,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label ?? name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: chromeStyle(
                      size: phone ? 15 : 13,
                      line: phone ? 20 : 18,
                      weight: AppWeight.button,
                      color: palette.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: chromeStyle(
                      size: phone ? 13 : 12,
                      line: 16,
                      weight: AppWeight.body,
                      color: live
                          ? palette.textSecondary
                          : palette.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            if (trailing case final trailing?) ...[
              const SizedBox(width: 12),
              trailing,
            ],
          ],
        ),
      ),
    );
  }
}

/// What a sheet rarely needs, behind one button in its header so no label
/// has to share a line with it.
class _OverflowMenu extends StatelessWidget {
  const _OverflowMenu({required this.onReportNote});

  final VoidCallback onReportNote;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    key: const ValueKey('share-more'),
    tooltip: 'More',
    padding: EdgeInsets.zero,
    icon: KapyIcon(
      KapyIcons.moreVerticalRounded,
      size: _OnPhone.of(context) ? 20 : 16,
      color: context.palette.textSecondary,
    ),
    onSelected: (_) => onReportNote(),
    itemBuilder: (context) => const [
      PopupMenuItem(
        key: ValueKey('report-note'),
        value: 'report',
        child: Text('Report this note'),
      ),
    ],
  );
}

class _RoleText extends StatelessWidget {
  const _RoleText(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final phone = _OnPhone.of(context);
    return Text(
      text,
      style: chromeStyle(
        size: phone ? 15 : 13,
        line: phone ? 20 : 18,
        weight: AppWeight.body,
        color: context.palette.textTertiary,
      ),
    );
  }
}

/// What a person on the note may do, and how to take them off it.
class _MemberMenu extends StatelessWidget {
  const _MemberMenu({
    super.key,
    required this.role,
    required this.enabled,
    required this.canManage,
    required this.canRemove,
    required this.removeLabel,
    required this.onAccess,
    required this.onReport,
    required this.onBlock,
    required this.onRemove,
  });

  final SpaceRole role;
  final bool enabled;
  final bool canManage;
  final bool canRemove;
  final String removeLabel;
  final ValueChanged<SpaceRole> onAccess;
  final VoidCallback onReport;
  final VoidCallback onBlock;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => _RowMenu(
    enabled: enabled,
    tooltip: _accessLabel(role),
    onSelected: (value) => switch (value) {
      'edit' => onAccess(SpaceRole.member),
      'view' => onAccess(SpaceRole.viewer),
      'report' => onReport(),
      'block' => onBlock(),
      _ => onRemove(),
    },
    items: [
      if (canManage) ...[
        PopupMenuItem(
          value: 'edit',
          enabled: !role.canEdit,
          child: const Text('Can edit'),
        ),
        PopupMenuItem(
          value: 'view',
          enabled: role.canEdit,
          child: const Text('Can view'),
        ),
        const PopupMenuDivider(),
      ],
      const PopupMenuItem(value: 'report', child: Text('Report…')),
      const PopupMenuItem(value: 'block', child: Text('Block…')),
      if (canRemove) ...[
        const PopupMenuDivider(),
        PopupMenuItem(value: 'remove', child: Text(removeLabel)),
      ],
    ],
    child: _AccessButton(_accessLabel(role), chevron: canManage),
  );
}

/// An invitation nobody has accepted yet.
class _InviteMenu extends StatelessWidget {
  const _InviteMenu({
    super.key,
    required this.enabled,
    required this.onCopyLink,
    required this.onSendAgain,
    required this.onCancel,
  });

  final bool enabled;
  final VoidCallback onCopyLink;
  final VoidCallback onSendAgain;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => _RowMenu(
    enabled: enabled,
    tooltip: 'Invitation',
    onSelected: (value) => switch (value) {
      'copy' => onCopyLink(),
      'resend' => onSendAgain(),
      _ => onCancel(),
    },
    items: const [
      PopupMenuItem(value: 'copy', child: Text('Copy link')),
      PopupMenuItem(value: 'resend', child: Text('Send again')),
      PopupMenuDivider(),
      PopupMenuItem(value: 'cancel', child: Text('Cancel invitation…')),
    ],
    child: _AccessButton('Invited', chevron: enabled),
  );
}

/// A row's menu, which hides a notice showing while it is open. The notice
/// comes back when the menu's route ends, however it ends, even when the
/// row has gone from under it.
class _RowMenu extends StatelessWidget {
  const _RowMenu({
    required this.enabled,
    required this.tooltip,
    required this.items,
    required this.onSelected,
    required this.child,
  });

  final bool enabled;
  final String tooltip;
  final List<PopupMenuEntry<String>> items;
  final ValueChanged<String> onSelected;
  final Widget child;

  void _open(BuildContext context) {
    final button = context.findRenderObject()! as RenderBox;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final under =
        PopupMenuTheme.of(context).position == PopupMenuPosition.under;
    final offset = Offset(0, under ? button.size.height : 0);
    Toast.hide(true);
    showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(
          button.localToGlobal(offset, ancestor: overlay),
          button.localToGlobal(
            button.size.bottomRight(Offset.zero) + offset,
            ancestor: overlay,
          ),
        ),
        Offset.zero & overlay.size,
      ),
      items: items,
    ).whenComplete(() => Toast.hide(false)).then((value) {
      if (value != null && context.mounted) onSelected(value);
    });
  }

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: InkWell(
      onTap: enabled ? () => _open(context) : null,
      canRequestFocus: enabled,
      child: child,
    ),
  );
}

/// What a person row's menu opens from: their access, or that they are
/// invited, with a chevron while it can be changed.
class _AccessButton extends StatelessWidget {
  const _AccessButton(this.label, {required this.chevron});

  final String label;
  final bool chevron;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final phone = _OnPhone.of(context);
    return SizedBox(
      height: phone ? 44 : 28,
      child: Padding(
        padding: EdgeInsets.only(left: 8, right: phone ? 0 : 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: chromeStyle(
                size: phone ? 15 : 13,
                line: phone ? 20 : 18,
                weight: AppWeight.button,
                color: palette.textSecondary,
              ),
            ),
            if (chevron) ...[
              const SizedBox(width: 4),
              KapyIcon(
                KapyIcons.chevronDownRounded,
                size: phone ? 14 : 12,
                color: palette.textSecondary,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The address field, with the people this account already shares with
/// offered underneath it.
class _EmailField extends StatelessWidget {
  const _EmailField({
    required this.controller,
    required this.enabled,
    required this.onChanged,
    required this.onSubmit,
    this.focus,
    this.hint = 'Add people by email',
  });

  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String> onChanged;
  final VoidCallback? onSubmit;
  final FocusNode? focus;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final phone = _OnPhone.of(context);
    final text = chromeStyle(
      size: phone ? 15 : 13,
      line: phone ? 20 : 18,
      weight: AppWeight.body,
      color: palette.textPrimary,
    );
    OutlineInputBorder border([BorderSide side = BorderSide.none]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(phone ? 9 : 6),
          borderSide: side,
        );
    return TextField(
      key: const ValueKey('share-email'),
      controller: controller,
      focusNode: focus,
      enabled: enabled,
      keyboardType: TextInputType.emailAddress,
      autocorrect: false,
      enableSuggestions: false,
      onChanged: onChanged,
      onSubmitted: (_) => onSubmit?.call(),
      style: text,
      cursorColor: palette.accentText,
      cursorWidth: 1.5,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: text.copyWith(color: palette.textTertiary),
        isDense: true,
        filled: true,
        fillColor: palette.textPrimary.withValues(alpha: 0.04),
        constraints: BoxConstraints.tightFor(height: phone ? 44 : 32),
        contentPadding: EdgeInsets.fromLTRB(
          0,
          phone ? 12 : 7,
          phone ? 12 : 10,
          phone ? 12 : 7,
        ),
        prefixIcon: Padding(
          padding: EdgeInsets.only(left: phone ? 12 : 10, right: 8),
          child: KapyIcon(
            KapyIcons.mailOutlined,
            size: phone ? 16 : AppControlMetrics.iconAdornment,
            color: palette.textTertiary,
          ),
        ),
        prefixIconConstraints: const BoxConstraints(),
        border: border(),
        enabledBorder: border(),
        disabledBorder: border(),
        focusedBorder: border(
          BorderSide(
            color: palette.selectedBorder,
            width: palette.increasedContrast ? 2 : 1.25,
          ),
        ),
      ),
    );
  }
}

/// Who someone new may be: Can edit or Can view, side by side on one quiet
/// track, the chosen side lifted a little.
class _AccessSegments extends StatelessWidget {
  const _AccessSegments({required this.role, required this.onRole});

  final SpaceRole role;
  final ValueChanged<SpaceRole>? onRole;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final phone = _OnPhone.of(context);
    return Container(
      key: const ValueKey('share-role'),
      height: phone ? 36 : 28,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: palette.textPrimary.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(phone ? 9 : 6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 2,
        children: [
          for (final (value, label) in const [
            (SpaceRole.member, 'Can edit'),
            (SpaceRole.viewer, 'Can view'),
          ])
            Semantics(
              selected: value == role,
              inMutuallyExclusiveGroup: true,
              child: TextButton(
                key: ValueKey('share-role-${value.name}'),
                onPressed: onRole == null ? null : () => onRole!(value),
                style: TextButton.styleFrom(
                  backgroundColor: value == role
                      ? palette.textPrimary.withValues(alpha: 0.07)
                      : null,
                  disabledBackgroundColor: value == role
                      ? palette.textPrimary.withValues(alpha: 0.07)
                      : null,
                  foregroundColor: value == role
                      ? palette.textPrimary
                      : palette.textSecondary,
                  minimumSize: Size(0, phone ? 32 : 24),
                  padding: EdgeInsets.symmetric(horizontal: phone ? 12 : 10),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(phone ? 7 : 5),
                  ),
                  textStyle: chromeStyle(
                    size: phone ? 14 : 13,
                    line: 18,
                    weight: AppWeight.button,
                    color: palette.textPrimary,
                  ),
                ),
                child: Text(label),
              ),
            ),
        ],
      ),
    );
  }
}

class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({super.key, required this.person, required this.onTap});

  final SharePerson person;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.control),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
        child: Row(
          children: [
            ProfileAvatar(extent: 24, name: person.name, image: person.image),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    person.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTypeScale.control,
                      color: palette.textPrimary,
                    ),
                  ),
                  Text(
                    person.email,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTypeScale.caption,
                      color: palette.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

class _Chips extends StatelessWidget {
  const _Chips({required this.emails, required this.onRemove});

  final List<String> emails;
  final ValueChanged<String>? onRemove;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Wrap(
      key: const ValueKey('share-chips'),
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final email in emails)
          Container(
            key: ValueKey('share-chip-$email'),
            padding: const EdgeInsets.fromLTRB(9, 4, 4, 4),
            decoration: BoxDecoration(
              color: palette.controlBackground,
              borderRadius: BorderRadius.circular(AppRadii.pill),
              border: Border.all(color: palette.controlBorder),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  email,
                  style: TextStyle(
                    fontSize: AppTypeScale.caption,
                    color: palette.textPrimary,
                  ),
                ),
                const SizedBox(width: 2),
                InkWell(
                  key: ValueKey('share-chip-remove-$email'),
                  onTap: onRemove == null ? null : () => onRemove!(email),
                  borderRadius: BorderRadius.circular(AppRadii.pill),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: KapyIcon(
                      KapyIcons.closeRounded,
                      size: AppControlMetrics.iconInline,
                      color: palette.textTertiary,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Only this note, or every note the new person would otherwise join.
class _ScopeChoice extends StatelessWidget {
  const _ScopeChoice({
    required this.noteId,
    required this.noteTitle,
    required this.who,
    required this.shared,
    required this.notes,
    required this.selected,
    required this.enabled,
    required this.onChanged,
  });

  /// The note being shared, named rather than called "this note" twice.
  final String noteId;
  final String noteTitle;

  /// Whoever is being added, by name where this account knows one.
  final String who;

  /// The people already on it, in one phrase.
  final String shared;

  /// Every note in the space, this one included.
  final List<Note> notes;
  final _Audience selected;
  final bool enabled;
  final ValueChanged<_Audience> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final others = [
      for (final note in notes)
        if (note.id != noteId) note.title,
    ];
    final count = notes.length;
    return KapyControlSurface(
      key: const ValueKey('share-scope'),
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '$noteTitle is shared with $shared together with '
            '${_othersPhrase(others)}. Give $who:',
            style: TextStyle(
              fontSize: AppTypeScale.small,
              color: palette.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 6),
          _ChoiceRow(
            key: const ValueKey('share-scope-one'),
            label: 'Only this note',
            selected: selected == _Audience.thisNote,
            enabled: enabled,
            onTap: () => onChanged(_Audience.thisNote),
          ),
          _ChoiceRow(
            key: const ValueKey('share-scope-all'),
            label: count == 2 ? 'Both notes' : 'All $count notes',
            selected: selected == _Audience.allNotes,
            enabled: enabled,
            onTap: () => onChanged(_Audience.allNotes),
          ),
        ],
      ),
    );
  }

  static String _othersPhrase(List<String> titles) => switch (titles.length) {
    0 => 'nothing else',
    1 => titles.single,
    2 => '${titles.first} and 1 other',
    _ => '${titles.first} and ${titles.length - 1} others',
  };
}

class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    super.key,
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(AppRadii.control),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: KapyIcon(
                selected
                    ? KapyIcons.radioCheckedRounded
                    : KapyIcons.radioUncheckedRounded,
                size: AppControlMetrics.iconControl,
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : palette.textTertiary,
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: AppTypeScale.control,
                  color: palette.textPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Can edit or can view, and the one button that sends it.
class _AccessAndShare extends StatelessWidget {
  const _AccessAndShare({
    required this.role,
    required this.enabled,
    required this.busy,
    required this.onRole,
    required this.onShare,
    this.field,
    this.action = 'Share',
  });

  final SpaceRole role;
  final bool enabled;
  final bool busy;
  final ValueChanged<SpaceRole> onRole;
  final VoidCallback onShare;
  final Widget? field;
  final String action;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final phone = _OnPhone.of(context);
    final buttons = Row(
      children: [
        _AccessSegments(role: role, onRole: enabled ? onRole : null),
        const Spacer(),
        FilledButton(
          key: ValueKey('share-submit-$action'),
          onPressed: enabled ? onShare : null,
          style: FilledButton.styleFrom(
            backgroundColor: palette.accentText.withValues(alpha: 0.16),
            foregroundColor: palette.accentText,
            disabledBackgroundColor: palette.textPrimary.withValues(
              alpha: 0.04,
            ),
            disabledForegroundColor: palette.textTertiary,
            minimumSize: Size(0, phone ? 36 : 28),
            padding: EdgeInsets.symmetric(horizontal: phone ? 16 : 12),
            tapTargetSize: phone
                ? MaterialTapTargetSize.padded
                : MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(phone ? 9 : 6),
            ),
            textStyle: chromeStyle(
              size: phone ? 15 : 13,
              line: phone ? 20 : 18,
              weight: AppWeight.page,
              color: palette.accentText,
            ),
          ),
          child: Text(busy ? 'Sharing…' : action),
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (field case final field?) ...[
          field,
          SizedBox(height: phone ? 6 : 10),
        ],
        buttons,
      ],
    );
  }
}

/// The note's invitation link, as one switch.
class _LinkRow extends StatelessWidget {
  const _LinkRow({
    required this.joining,
    required this.spaceId,
    required this.enabled,
    required this.onToggle,
    required this.onCopy,
    this.opensMore,
  });

  final Joining joining;
  final String? spaceId;
  final bool enabled;
  final ValueChanged<bool> onToggle;
  final ValueChanged<JoinLink> onCopy;
  final String? opensMore;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final spaceId = this.spaceId;
    final link = spaceId == null ? null : joining.linkOf(spaceId);
    final on = link != null;
    final detail = switch (link) {
      null => 'Off · Turn on to invite people without their email',
      final link => '${_linkRoleLabel(link)} · they still need to sign in',
    };
    final phone = _OnPhone.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Container(
            height: AppHairline.of(context),
            color: palette.textPrimary.withValues(alpha: 0.06),
          ),
        ),
        ConstrainedBox(
          key: const ValueKey('share-link'),
          constraints: BoxConstraints(minHeight: phone ? 52 : 0),
          child: Padding(
            padding: EdgeInsets.only(
              top: phone ? 4 : 10,
              bottom: phone ? 0 : 4,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Invite link',
                        style: chromeStyle(
                          size: phone ? 15 : 13,
                          line: phone ? 20 : 18,
                          weight: AppWeight.button,
                          color: palette.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        detail,
                        key: const ValueKey('share-link-detail'),
                        style: chromeStyle(
                          size: phone ? 13 : 12,
                          line: 16,
                          weight: AppWeight.body,
                          color: palette.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                if (on)
                  TextButton(
                    key: const ValueKey('share-link-copy'),
                    onPressed: enabled ? () => onCopy(link) : null,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 30),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    child: const Text('Copy link'),
                  ),
                Semantics(
                  label: 'Invite link',
                  child: GestureDetector(
                    key: const ValueKey('share-link-switch'),
                    onTap: enabled ? () => onToggle(!on) : null,
                    behavior: HitTestBehavior.opaque,
                    child: SettingsSwitch(value: on, enabled: enabled),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (opensMore != null)
          Padding(
            padding: EdgeInsets.only(top: phone ? 2 : 4),
            child: Row(
              children: [
                KapyIcon(
                  KapyIcons.infoOutlined,
                  size: phone ? 16 : 14,
                  color: palette.textSecondary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    opensMore!,
                    key: const ValueKey('share-link-scope'),
                    style: chromeStyle(
                      size: phone ? 13 : 12,
                      line: phone ? 18 : 16,
                      weight: AppWeight.body,
                      color: palette.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  static String _linkRoleLabel(JoinLink link) => link.role == SpaceRole.viewer
      ? 'Anyone with the link can view'
      : 'Anyone with the link can edit';
}

class _Banner extends StatelessWidget {
  const _Banner({
    super.key,
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

/// A whole state instead of the sheet's controls: hidden, or without Pro.
class _StatePanel extends StatelessWidget {
  const _StatePanel({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  final KapyIconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: palette.controlBackground,
              borderRadius: BorderRadius.circular(AppRadii.control),
              border: Border.all(color: palette.controlBorder),
            ),
            child: KapyIcon(
              icon,
              size: AppControlMetrics.iconFeature,
              color: palette.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            title,
            style: TextStyle(
              fontSize: AppTypeScale.control,
              color: palette.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(body, style: _bodyStyle(context)),
          if (action case final action?) ...[
            const SizedBox(height: 12),
            Align(alignment: Alignment.centerLeft, child: action),
          ],
        ],
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final phone = _OnPhone.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: Text(
        text,
        style: chromeStyle(
          size: phone ? 13 : 12,
          line: phone ? 18 : 16,
          weight: AppWeight.section,
          color: context.palette.textTertiary,
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text, {super.key, this.isError = false});

  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final color = isError
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.primary;
    return Semantics(
      liveRegion: true,
      child: KapyControlSurface(
        color: color.withValues(alpha: 0.07),
        borderColor: color.withValues(alpha: 0.34),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: KapyIcon(
                isError
                    ? KapyIcons.errorOutlined
                    : KapyIcons.checkCircleRounded,
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
      ),
    );
  }
}

String _firstName(String name, String fallback) {
  final first = name.trim().split(RegExp(r'\s+')).first;
  return first.isEmpty ? fallback : first;
}

TextStyle _bodyStyle(BuildContext context) => TextStyle(
  fontSize: AppTypeScale.control,
  color: context.palette.textPrimary,
  height: 1.4,
);
