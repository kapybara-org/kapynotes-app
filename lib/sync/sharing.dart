import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/note.dart';
import '../data/note_attachment.dart';
import '../data/notes_store.dart';
import 'aead.dart';
import 'config.dart';
import 'image_sync.dart';
import 'key_wrap.dart';
import 'presence.dart';
import 'safety.dart';
import 'space_keyring.dart';
import 'spaces.dart';
import 'sync_api.dart';
import 'sync_service.dart';
import 'trust.dart';
import 'vault.dart';

/// Whether an invitation from someone whose shared notes this account is
/// already in is accepted without asking (D2). Off until Sanjay decides:
/// accepting on its own shows this account's name and email to the other
/// members of a space the person never chose to join.
const acceptInvitesOnTheirOwn = false;

/// Everything the UI does with shared spaces, in one place.
///
/// Sharing a note with a person means: find or create a space that contains
/// you both, invite them if the space is new, and move the note into it. The
/// server never sees a key; every one of them is minted here, wrapped here,
/// and handed over sealed to somebody's public key.
///
/// Every action goes through the server first and the local store second, so
/// a refused action changes nothing on this device, and then asks for a sync
/// so the other members hear about it.
class Sharing extends ChangeNotifier {
  Sharing({
    required SyncApi api,
    required Vault vault,
    required SpaceKeyring keyring,
    required NotesStore notes,
    required SyncService sync,
    ImageSync? images,
    DateTime Function() now = DateTime.now,
    bool acceptOnTheirOwn = acceptInvitesOnTheirOwn,
  }) : _api = api,
       _acceptOnTheirOwn = acceptOnTheirOwn,
       _vault = vault,
       _keyring = keyring,
       _notes = notes,
       _sync = sync,
       _images = images,
       _since = now() {
    _guests = _guestSpaces();
    _keyring.addListener(_onKeyring);
    _keyring.trust.addListener(notifyListeners);
    _changes = _sync.sharedChanges.listen(_onSharedChange);
  }

  final SyncApi _api;
  final Vault _vault;
  final SpaceKeyring _keyring;
  final NotesStore _notes;
  final SyncService _sync;
  final ImageSync? _images;

  /// When this device started watching. A space's whole history arriving
  /// is news only for a space joined after it; before, it is a device
  /// catching up on what was already shared.
  final DateTime _since;
  late final StreamSubscription<SharedChange> _changes;
  final StreamController<SharingNotice> _notices = StreamController.broadcast();

  /// The shared spaces somebody else owns, as last seen.
  late Map<String, ({SpaceRole role, String owner, List<Note> notes})> _guests;

  /// Spaces this device is leaving, whose going is no news.
  final Set<String> _leaving = {};

  final bool _acceptOnTheirOwn;

  /// Invitations this device has tried to accept by itself, once each.
  final Set<String> _autoAccepting = {};

  /// Spaces joined that way, whose notice offers to leave again.
  final Set<String> _autoAccepted = {};

  /// What happened to the notes shared with this account, once each: a
  /// note shared, access changed, access ended.
  Stream<SharingNotice> get notices => _notices.stream;

  /// Whether the server cannot be reached right now. Every action here asks
  /// it first, so they wait until it can.
  bool get isOffline => _sync.status == SyncStatus.offline;

  /// Whether sync is holding [spaceId] back until somebody in it has Pro.
  bool needsPro(String spaceId) => _sync.spacesNeedingPro.contains(spaceId);

  String get userId => _keyring.userId;
  List<Space> get spaces => _keyring.spaces;

  List<Block> _blocks = const [];
  TermsStatus _terms = TermsStatus.unknown;

  /// Everyone this account has blocked, newest first.
  List<Block> get blocks => _blocks;

  /// Whether this account has agreed to the rules of a shared space. Assumed
  /// not until the server has said otherwise, so the sheet is shown once too
  /// often rather than skipped.
  TermsStatus get terms => _terms;
  bool get hasAcceptedTerms => _terms.isAccepted;

  bool hasBlocked(String email) {
    final wanted = email.trim().toLowerCase();
    for (final block in _blocks) {
      if (block.email.toLowerCase() == wanted) return true;
    }
    return false;
  }

  /// Shared spaces, in the order they were created.
  List<Space> get teams => _keyring.teams;
  List<PendingInvite> get invites => _keyring.invites;
  TrustStore get trust => _keyring.trust;
  bool get isFresh => _keyring.isFresh;

  Space? spaceById(String? id) => _keyring.byId(id);

  /// The note as the store holds it now, so a dialog left open sees a move
  /// the moment it happens.
  Note? noteById(String id) => _notes.byId(id);

  /// The space a note lives in. Null for the personal one, or for a shared
  /// space this device has not heard about yet.
  Space? spaceOf(Note note) =>
      note.spaceId == null ? null : _keyring.byId(note.spaceId);

  /// Whether this device has the key needed to read a space right now.
  bool holdsKey(String spaceId) => _keyring.holdsKey(spaceId);

  /// Whoever else is in one of a space's notes right now.
  List<Collaborator> presentIn(String spaceId) =>
      _sync.collaboratorsInSpace(spaceId);

  /// Fires as people arrive in and leave shared notes, which this object's
  /// own notifications do not cover.
  Listenable get presenceChanges => _sync;

  /// Personal notes and notes in spaces where this account may make changes.
  bool canEdit(Note note) {
    if (!note.isShared) return true;
    return spaceOf(note)?.canEdit ?? false;
  }

  /// Where an invitation link lands. The token is useless to anyone who
  /// cannot sign in as the invited address.
  Uri inviteLink(String token) =>
      Uri.parse(kSiteBaseUrl).resolve('join/$token');

  /// Fetches the latest list of spaces and invitations, and the two
  /// account-level facts the sharing UI needs beside them.
  Future<void> refresh() async {
    await _keyring.refresh(_api, _vault);
    await refreshSafety();
  }

  /// Blocks and terms. Split out because the share sheet wants them without
  /// necessarily wanting a full space refresh.
  Future<void> refreshSafety() async {
    _blocks = await _api.fetchBlocks();
    _terms = await _api.fetchTerms();
    _autoAccept();
    notifyListeners();
  }

  Map<String, ({SpaceRole role, String owner, List<Note> notes})>
  _guestSpaces() => {
    for (final space in teams)
      if (!space.isOwner)
        space.id: (
          role: space.role,
          owner: space.shortNameOf(space.ownerId),
          notes: notesIn(space.id),
        ),
  };

  void _onKeyring() {
    final before = _guests;
    _guests = _guestSpaces();
    if (_keyring.isFresh) {
      for (final MapEntry(key: id, value: was) in before.entries) {
        final now = _guests[id];
        if (now != null) {
          if (now.role != was.role) {
            _notices.add(SharingNotice.access(from: now.owner, role: now.role));
          }
          continue;
        }
        if (_leaving.remove(id) || (spaceById(id)?.isOwner ?? false)) continue;
        final held = [
          for (final note in was.notes)
            if (_notes.byId(note.id)?.spaceId == id && !note.isHidden) note,
        ];
        if (held.isNotEmpty) {
          _notices.add(SharingNotice.ended(from: was.owner, notes: held));
        }
      }
      _autoAccept();
    }
    notifyListeners();
  }

  void _onSharedChange(SharedChange change) {
    final space = spaceById(change.spaceId);
    if (space == null || space.isOwner) return;
    final owner = space.shortNameOf(space.ownerId);
    final joined = space.member(userId)?.joinedAt;
    final catchingUp =
        change.wholeHistory && (joined == null || joined.isBefore(_since));
    final arrived = [
      for (final note in change.arrived)
        if (!note.isHidden) note,
    ];
    final removed = [
      for (final note in change.removed)
        if (!note.isHidden) note,
    ];
    if (arrived.isNotEmpty && !catchingUp) {
      _notices.add(
        SharingNotice.shared(
          from: owner,
          notes: arrived,
          leaveSpaceId: _autoAccepted.contains(space.id) ? space.id : null,
        ),
      );
    }
    if (removed.isNotEmpty) {
      _notices.add(SharingNotice.ended(from: owner, notes: removed));
    }
  }

  /// Accepts, without asking, an invitation from somebody whose shared notes
  /// this account is already in, and has not blocked (D2). Once per
  /// invitation: one that fails stays an ordinary invitation.
  void _autoAccept() {
    if (!_acceptOnTheirOwn || !hasAcceptedTerms) return;
    for (final invite in invites) {
      final from = invite.invitedBy.toLowerCase();
      final known = teams.any(
        (space) =>
            !space.isOwner &&
            space.member(space.ownerId)?.email.toLowerCase() == from,
      );
      if (!known || hasBlocked(from) || !_autoAccepting.add(invite.token)) {
        continue;
      }
      unawaited(_acceptOnItsOwn(invite));
    }
  }

  Future<void> _acceptOnItsOwn(PendingInvite invite) async {
    try {
      await acceptInvite(invite.token);
      _autoAccepted.add(invite.spaceId);
    } on SyncException catch (error) {
      debugPrint('KapyNotes: invitation not accepted on its own: $error');
    }
  }

  // -------------------------------------------------------------------------
  // Sharing a note
  // -------------------------------------------------------------------------

  /// Creates a new shared space owned by this account, with the space key
  /// wrapped to its own identity key.
  Future<Space> createSpace(String name) async {
    final identity = await _keyring.ensureIdentity(_api, _vault);
    final key = randomKey();
    final space = await _api.createSpace(
      name: name.trim(),
      spaceKey: await sealToPublicKey(key, identity.x25519Public),
    );
    _keyring.remember(space.id, key);
    await refresh();
    return space;
  }

  /// Moves a note into a shared space under a freshly minted content key,
  /// and pushes it so the other members receive it.
  Future<void> shareNote(String noteId, {required String spaceId}) async {
    _checkMovable(noteId);
    final space = _keyring.byId(spaceId);
    if (space == null || !space.isTeam) {
      throw const SyncProtocolException('no such shared space');
    }
    if (!space.canEdit) {
      throw const SyncRefusedException(403, 'view-only', {});
    }
    if (!_keyring.holdsKey(spaceId)) {
      throw const SyncProtocolException('waiting for the key to this space');
    }
    _notes.moveToSpace(
      noteId,
      spaceId: spaceId,
      contentKey: randomKey(),
      keyGeneration: space.keyGeneration,
    );
    await _sync.syncNow();
  }

  /// Refuses a move of [noteId] into a shared space before anything is
  /// created or sent: Hidden notes are never shared, and only the owner of a
  /// shared space may take a note out of it.
  void _checkMovable(String noteId) {
    final note = _notes.byId(noteId);
    if (note?.isHidden ?? false) {
      throw const SyncRefusedException(409, 'hidden-note', {});
    }
    final from = note == null ? null : spaceOf(note);
    if (from != null && from.isTeam && !from.isOwner) {
      throw const SyncRefusedException(403, 'owner-only', {});
    }
  }

  /// Shares a private note with one person: the space that is exactly the two
  /// of you at that access, or a new one they are invited to.
  Future<Space> shareNoteWith(
    String noteId, {
    required String email,
    SpaceRole role = SpaceRole.member,
  }) => _moveTo(noteId, {_address(email): _access(role)});

  /// Moves a note to the space whose people other than this account are
  /// exactly [audience], at those accesses. One this account owns is reused;
  /// otherwise a new one is made and everyone in [audience] invited to it.
  ///
  /// Everything that can be refused is asked before the note moves. A new
  /// space whose invitations fail is deleted again, so a failure leaves no
  /// space and no invitation behind. Invitations go out in [audience]'s
  /// order, so a caller puts the address most likely to be refused first.
  Future<Space> _moveTo(String noteId, Map<String, SpaceRole> audience) async {
    _checkMovable(noteId);
    final existing = _spaceFor(audience);
    if (existing != null) {
      await shareNote(noteId, spaceId: existing.id);
      return _keyring.byId(existing.id) ?? existing;
    }
    final space = await createSpace(_pairName(audience.keys.first));
    try {
      for (final MapEntry(key: email, value: role) in audience.entries) {
        await _api.invite(space.id, email, role: role);
      }
    } on SyncException {
      try {
        await _api.stopSharing(space.id, const []);
        await refresh();
      } on SyncException {
        // The failure worth reporting is the first one.
      }
      rethrow;
    }
    await shareNote(noteId, spaceId: space.id);
    await refresh();
    return _keyring.byId(space.id) ?? space;
  }

  /// A team space this account owns, without a link, whose other members and
  /// invitations are exactly [audience].
  Space? _spaceFor(Map<String, SpaceRole> audience) {
    for (final space in teams) {
      if (!space.isOwner || space.hasLink) continue;
      if (mapEquals(_audienceOf(space), audience)) return space;
    }
    return null;
  }

  /// Everyone but this account in [space], by address, at their access.
  Map<String, SpaceRole> _audienceOf(Space space) => {
    for (final member in space.othersThan(userId))
      member.email.toLowerCase(): member.role,
    for (final invite in space.invites) invite.email.toLowerCase(): invite.role,
  };

  static String _address(String email) => email.trim().toLowerCase();

  static SpaceRole _access(SpaceRole role) =>
      role == SpaceRole.viewer ? SpaceRole.viewer : SpaceRole.member;

  static String _pairName(String email) {
    final local = email.split('@').first;
    final name = local.isEmpty ? email : local;
    return 'With $name';
  }

  /// Takes a note out of a shared space and back into the personal one, under
  /// a new key. Only the space's owner may: it takes the note away from
  /// everyone else in it, and the server refuses anyone else.
  Future<void> unshareNote(String noteId) async {
    final note = _notes.byId(noteId);
    if (note == null || !(spaceOf(note)?.isOwner ?? false)) {
      throw const SyncRefusedException(403, 'owner-only', {});
    }
    _notes.moveToSpace(noteId, spaceId: null, contentKey: null);
    await _sync.syncNow();
  }

  /// Every note in a shared space as this device holds it, archived and
  /// hidden ones included: an invitation opens all of them.
  List<Note> notesIn(String spaceId) => _notes.notesIn(spaceId);

  /// A copy of a shared note in this account's own notes. The shared note is
  /// untouched, for everyone in the space.
  ///
  /// The server hands out the space's attachments only to its members, so the
  /// copy's go up again under the copy. Their bytes are fetched first; without
  /// them nothing is copied.
  Future<void> makePrivateCopy(String noteId) async {
    final note = _notes.byId(noteId);
    if (note == null || !note.isShared) {
      throw const SyncProtocolException('no such shared note');
    }
    _notes.keepCopy(await _detached(note));
  }

  /// [note] with its attachments' bytes on this device and their server ids
  /// dropped, so a copy uploads them again under itself. Throws when a
  /// download fails.
  Future<Note> _detached(Note note) async {
    final attachments = <NoteAttachmentRef>[];
    for (final ref in note.attachments) {
      final hashes = [
        ref.hash,
        if (ref case NoteImageRef(:final thumbHash?)) thumbHash,
      ];
      for (final hash in hashes) {
        if (await _notes.blobs.has(hash)) continue;
        if (await _images?.fetch(hash) == null) {
          throw SyncTransientException('could not fetch attachment $hash');
        }
      }
      attachments.add(
        NoteAttachmentRef.fromJson(
          {...ref.toJson()}
            ..remove('attachmentId')
            ..remove('thumbId'),
        )!,
      );
    }
    return note.copyWith(attachments: attachments);
  }

  /// A new note straight into a shared space.
  Note createNoteIn(String spaceId) {
    final space = _keyring.byId(spaceId);
    if (space == null ||
        !space.isTeam ||
        !space.canEdit ||
        !_keyring.holdsKey(spaceId)) {
      throw const SyncProtocolException('no such shared space');
    }
    return _notes.create(
      body: Note.blankBody,
      authored: false,
      spaceId: spaceId,
      contentKey: randomKey(),
      keyGeneration: space.keyGeneration,
    );
  }

  // -------------------------------------------------------------------------
  // People
  // -------------------------------------------------------------------------

  /// Everyone this account shares notes with or receives notes from: the
  /// others in the shared spaces it owns, invited or joined, and the owners
  /// of the ones it belongs to. Somebody who is only another guest in a space
  /// owned by a third person is neither, and is not listed.
  List<SharePerson> get people {
    final found = <String, SharePerson>{};
    for (final space in teams) {
      if (!space.isOwner) {
        if (space.member(space.ownerId) case final owner?) {
          found[owner.email.toLowerCase()] = _personOf(owner);
        }
        continue;
      }
      for (final member in space.othersThan(userId)) {
        found[member.email.toLowerCase()] = _personOf(member);
      }
      for (final invite in space.invites) {
        found.putIfAbsent(invite.email.toLowerCase(), () => _invited(invite));
      }
    }
    return _byName(found.values);
  }

  /// Who the Shared list files [note] under: the owner of a note somebody
  /// shares with this account, or everyone this account shares its own note
  /// with. Access is set aside, so one person's notes stay together whatever
  /// each of them lets that person do. Null for a note in no shared space
  /// this device knows, or in one of its own that nobody else is in.
  ShareGroup? groupOf(Note note) {
    final space = spaceOf(note);
    if (space == null || !space.isTeam) return null;
    if (!space.isOwner) {
      final owner = space.member(space.ownerId);
      return owner == null
          ? null
          : ShareGroup(ShareGroupKind.from, [_personOf(owner)]);
    }
    final joined = space.othersThan(userId);
    final people = [
      ..._byName(joined.map(_personOf)),
      ..._byName(space.invites.map(_invited)),
    ];
    if (people.isEmpty) return null;
    return ShareGroup(
      joined.isEmpty ? ShareGroupKind.waiting : ShareGroupKind.sharedWith,
      people,
    );
  }

  static SharePerson _personOf(SpaceMember member) => SharePerson(
    email: member.email.toLowerCase(),
    name: member.displayName,
    userId: member.userId,
    image: member.image,
  );

  static SharePerson _invited(SpaceInvite invite) =>
      SharePerson(email: invite.email.toLowerCase(), name: invite.displayName);

  static List<SharePerson> _byName(Iterable<SharePerson> people) =>
      people.toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  /// The notes this account shares with [email], in the spaces it owns,
  /// whether or not they have accepted yet.
  List<Note> notesSharedWith(String email) {
    final address = _address(email);
    return [
      for (final space in teams)
        if (space.isOwner && _audienceOf(space).containsKey(address))
          ...notesIn(space.id),
    ];
  }

  /// The notes [email] shares with this account, in the spaces they own.
  List<Note> notesSharedFrom(String email) {
    final address = _address(email);
    return [
      for (final space in teams)
        if (!space.isOwner &&
            space.member(space.ownerId)?.email.toLowerCase() == address)
          ...notesIn(space.id),
    ];
  }

  /// Gives [email] access to a note. Owner only for a note that is shared
  /// already.
  ///
  /// A private note goes to the space for exactly this person. A shared note
  /// that has its space to itself, or with [allNotes], takes them into its
  /// space, so they get every note in it. Otherwise only this note moves, to
  /// the space for its current people plus them, and the people already on
  /// it get an invitation to that space.
  Future<void> addPerson(
    String noteId,
    String email, {
    SpaceRole role = SpaceRole.member,
    bool allNotes = false,
  }) async {
    final note = _notes.byId(noteId);
    if (note == null) throw const SyncProtocolException('no such note');
    final address = _address(email);
    final access = _access(role);
    final space = spaceOf(note);
    if (space == null || !space.isTeam) {
      await shareNoteWith(noteId, email: address, role: access);
      return;
    }
    _checkMovable(noteId);
    if (!space.isOwner) {
      throw const SyncRefusedException(403, 'owner-only', {});
    }
    final audience = _audienceOf(space);
    if (audience.containsKey(address)) {
      throw const SyncRefusedException(409, 'already a member', {});
    }
    if (allNotes || notesIn(space.id).length == 1) {
      await _api.invite(space.id, address, role: access);
      await refresh();
      return;
    }
    await _moveTo(noteId, {address: access, ...audience});
  }

  /// Changes what [email] may do with a note, Editor or View only. Access
  /// belongs to the note's space, so it changes for every note in it.
  Future<void> changeAccessTo(String noteId, String email, SpaceRole role) {
    final member = _memberOn(noteId, email);
    if (member == null) {
      throw const SyncProtocolException('not a member of this note');
    }
    return changeAccess(_notes.byId(noteId)!.spaceId!, member.userId, role);
  }

  /// Takes [email] off one note. Owner only.
  ///
  /// When the note has its space to itself, they leave the space, or the
  /// space ends when they were the last one in it. Otherwise the note moves
  /// to the space for the people who stay, or home when nobody does.
  Future<void> removeFromNote(String noteId, String email) async {
    final note = _notes.byId(noteId);
    final space = note == null ? null : spaceOf(note);
    if (space == null || !space.isOwner) {
      throw const SyncRefusedException(403, 'owner-only', {});
    }
    final address = _address(email);
    final audience = _audienceOf(space);
    if (!audience.containsKey(address)) {
      throw const SyncProtocolException('not on this note');
    }
    final remaining = {...audience}..remove(address);
    if (notesIn(space.id).length > 1) {
      if (remaining.isEmpty) return unshareNote(noteId);
      await _moveTo(noteId, remaining);
      return;
    }
    if (remaining.isEmpty) return stopSharing(space.id);
    await _removeFrom(space, address);
    await refresh();
    _sync.requestSync();
  }

  /// Ends [email]'s access to everything this account shares with them. The
  /// notes stay with this account: a space that was only for them ends and
  /// its notes come home, and they leave every other.
  ///
  /// Each space is one step, so a failure part of the way leaves the spaces
  /// before it done and the rest untouched, and a retry finishes the job.
  Future<void> stopSharingWith(String email) async {
    final address = _address(email);
    final spaces = [
      for (final space in teams)
        if (space.isOwner && _audienceOf(space).containsKey(address)) space,
    ];
    for (final space in spaces) {
      if (_audienceOf(space).length == 1) {
        await stopSharing(space.id);
      } else {
        await _removeFrom(space, address);
      }
    }
    await refresh();
    _sync.requestSync();
  }

  /// Takes [address] out of [space], as a member or an invitation. A member
  /// the server no longer has, as after a lost answer, is out already.
  Future<void> _removeFrom(Space space, String address) async {
    for (final member in space.othersThan(userId)) {
      if (member.email.toLowerCase() != address) continue;
      try {
        await _api.removeMember(space.id, member.userId);
      } on SyncRefusedException catch (error) {
        if (error.status != 404 || error.code != 'not a member') rethrow;
      }
    }
    for (final invite in space.invites) {
      if (invite.email.toLowerCase() == address) {
        await _api.revokeInvite(space.id, invite.token);
      }
    }
  }

  SpaceMember? _memberOn(String noteId, String email) {
    final note = _notes.byId(noteId);
    final space = note == null ? null : spaceOf(note);
    final address = _address(email);
    for (final member in space?.othersThan(userId) ?? const <SpaceMember>[]) {
      if (member.email.toLowerCase() == address) return member;
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // Membership
  // -------------------------------------------------------------------------

  Future<InviteResult> invite(
    String spaceId,
    String email, {
    SpaceRole role = SpaceRole.member,
  }) async {
    final result = await _api.invite(
      spaceId,
      _address(email),
      role: _access(role),
    );
    await refresh();
    return result;
  }

  Future<void> revokeInvite(String spaceId, String token) async {
    await _api.revokeInvite(spaceId, token);
    await refresh();
  }

  Future<Space> rename(String spaceId, String name) async {
    final space = await _api.renameSpace(spaceId, name.trim());
    await refresh();
    return space;
  }

  /// Accepts an invitation. The account becomes a member with no key; the
  /// next time somebody who holds it syncs, they grant it, and the notes
  /// arrive on the sync after that.
  Future<Space> acceptInvite(String token) async {
    final space = await _api.acceptInvite(token.trim());
    await refresh();
    _sync.requestSync();
    return space;
  }

  Future<void> declineInvite(String token) async {
    await _api.declineInvite(token);
    await refresh();
  }

  /// Owner removing someone. They are cut off server-side at once; the key
  /// rotation that follows happens on the next sync of any member holding it.
  Future<void> removeMember(String spaceId, String userId) async {
    await _api.removeMember(spaceId, userId);
    await refresh();
    _sync.requestSync();
  }

  /// Changes what a member may do, Editor or View only. Owner only.
  ///
  /// A server from before this has no such route, which answers a plain 404.
  /// With one other person in the space, the notes then move to the pair
  /// space for them at the new access, which they join from a fresh
  /// invitation, and they leave this one.
  Future<void> changeAccess(
    String spaceId,
    String userId,
    SpaceRole role,
  ) async {
    final space = _keyring.byId(spaceId);
    if (space == null || !space.isOwner) {
      throw const SyncRefusedException(403, 'owner-only', {});
    }
    if (role == SpaceRole.owner) {
      throw const SyncProtocolException('ownership moves by transfer');
    }
    try {
      await _api.changeRole(spaceId, userId, role);
    } on SyncRefusedException catch (error) {
      final others = space.othersThan(this.userId);
      final notes = notesIn(spaceId);
      if (error.status != 404 ||
          error.code != 'server returned 404' ||
          others.length != 1 ||
          space.invites.isNotEmpty ||
          notes.any((note) => note.isHidden)) {
        rethrow;
      }
      for (final note in notes) {
        await _moveTo(note.id, {others.single.email.toLowerCase(): role});
      }
      await _api.removeMember(spaceId, userId);
    }
    await refresh();
  }

  /// Leaving a space. By default each of its notes stays as a private copy,
  /// attachments included, hidden ones still hidden. The copies are written
  /// to disk before the server is asked, so nothing is ever lost. A retry
  /// reuses the copies an earlier attempt made, until one succeeds. Only a
  /// refusal, which means nothing changed, takes back the copies this attempt
  /// made; a timeout may have left the space all the same, so they stay.
  Future<void> leave(String spaceId, {bool keepCopies = true}) async {
    _leaving.add(spaceId);
    final sources = keepCopies ? notesIn(spaceId) : const <Note>[];
    final detached = [for (final note in sources) await _detached(note)];
    final made = [
      for (final note in detached)
        if (_notes.privateCopyOf(note) case (:final note, made: true)) note,
    ];
    await _notes.flush();
    try {
      await _api.removeMember(spaceId, userId);
    } on SyncRefusedException catch (error) {
      final alreadyGone =
          error.status == 404 &&
          (error.code == 'not a member' || error.code == 'no such space');
      if (!alreadyGone) {
        _leaving.remove(spaceId);
        for (final copy in made) {
          _notes.delete(copy.id);
        }
        rethrow;
      }
    }
    _sync.left(spaceId);
    _notes.forgetPrivateCopies(sources.map((note) => note.id));
    await refresh();
    _sync.requestSync();
  }

  Future<Space> transfer(String spaceId, String userId) async {
    final space = await _api.transfer(spaceId, userId);
    await refresh();
    return space;
  }

  /// Owner ending a space: every note comes home to the personal space and
  /// the space is gone. Nothing is deleted.
  Future<void> stopSharing(String spaceId) async {
    final space = _keyring.byId(spaceId);
    if (space == null || !space.isOwner) {
      throw const SyncProtocolException('only the owner can stop sharing');
    }
    // Whatever this device has not sent yet goes first, so the server's set
    // of live notes and the set brought home are the same set.
    await _sync.syncNow();
    if (_sync.status != SyncStatus.idle) {
      throw const SyncTransientException('could not sync before stopping');
    }
    if (!await _sync.bringHome(spaceId)) {
      throw const SyncTransientException('could not sync before stopping');
    }
    await refresh();
    _sync.requestSync();
  }

  // -------------------------------------------------------------------------
  // Blocking, reporting and the terms
  // -------------------------------------------------------------------------

  /// Agrees to the rules of a shared space. Every door into sharing is closed
  /// until this has happened, so it is the first thing the UI does.
  Future<void> acceptTerms() async {
    _terms = await _api.acceptTerms();
    notifyListeners();
  }

  /// Blocks a person, and ends whatever relationship gave them a way in.
  ///
  /// Blocking on its own only stops future invitations, which is no use at
  /// all if the problem is somebody already in a space with you. So when
  /// [inSpaceId] is given, this also does the thing that actually removes
  /// them: the owner removes them, and a member leaves.
  Future<void> blockPerson(String email, {String? inSpaceId}) async {
    final address = email.trim().toLowerCase();
    await _api.block(address);

    final space = inSpaceId == null ? null : _keyring.byId(inSpaceId);
    if (space != null && space.isTeam) {
      String? theirId;
      for (final member in space.members) {
        if (member.email.toLowerCase() == address) theirId = member.userId;
      }
      if (space.isOwner && theirId != null && theirId != userId) {
        await _api.removeMember(space.id, theirId);
      } else if (!space.isOwner && theirId != null) {
        // Not ours to remove them from, so we go instead.
        _leaving.add(space.id);
        await _api.removeMember(space.id, userId);
      }
    }

    await refresh();
    _sync.requestSync();
  }

  Future<void> unblockPerson(String email) async {
    await _api.unblock(email);
    await refreshSafety();
  }

  /// Files a report. Nothing encrypted travels unless [includeContent] is
  /// true, which the UI only passes when the person has been shown what it
  /// means and has said yes.
  Future<void> report({
    required ReportTarget target,
    required ReportReason reason,
    String? details,
    bool includeContent = false,
  }) async {
    await _api.report(
      target: target,
      reason: reason,
      details: details,
      includeContent: includeContent,
    );
    // An invitation reported is usually one the person also wants gone.
    if (target.kind == ReportKind.invitation) await refresh();
  }

  /// The person has looked at a changed fingerprint and chosen to trust it.
  void trustNewKey(TrustWarning warning) => trust.acknowledge(warning);

  @override
  void dispose() {
    _keyring.removeListener(_onKeyring);
    _keyring.trust.removeListener(notifyListeners);
    unawaited(_changes.cancel());
    unawaited(_notices.close());
    super.dispose();
  }
}

/// Something that happened to the notes shared with this account, said in
/// one line.
class SharingNotice {
  const SharingNotice._(this.message, {this.leaveSpaceId});

  factory SharingNotice.shared({
    required String from,
    required List<Note> notes,
    String? leaveSpaceId,
  }) => SharingNotice._(
    notes.length == 1
        ? '$from shared ${_named(notes.single)} with you'
        : '$from shared ${notes.length} notes with you',
    leaveSpaceId: leaveSpaceId,
  );

  factory SharingNotice.access({
    required String from,
    required SpaceRole role,
  }) => SharingNotice._(
    role.canEdit
        ? 'You can now edit notes from $from'
        : 'You can now only view notes from $from',
  );

  factory SharingNotice.ended({
    required String from,
    required List<Note> notes,
  }) => SharingNotice._(
    notes.length == 1 && notes.single.title.trim().isEmpty
        ? 'A note from $from is no longer shared with you'
        : notes.length == 1
        ? '${_named(notes.single)} is no longer shared with you'
        : '${notes.length} notes from $from are no longer shared with you',
  );

  final String message;

  /// The space a share accepted on its own joined, which the notice offers
  /// to leave again.
  final String? leaveSpaceId;

  static String _named(Note note) {
    final title = note.title.trim();
    return title.isEmpty ? 'a note' : '"$title"';
  }
}

/// Somebody this account shares notes with or receives them from, across
/// every space: a member of one, or an address with an invitation waiting.
class SharePerson {
  const SharePerson({
    required this.email,
    required this.name,
    this.userId,
    this.image,
  });

  /// Lower-cased. What identifies them from one space to the next.
  final String email;
  final String name;

  /// Null while they have only been invited.
  final String? userId;
  final String? image;

  bool get isInvited => userId == null;

  /// What to call them in a heading, where a full name would crowd it: the
  /// first word, unless that is only an initial and says nothing alone.
  String get firstName {
    final whole = name.trim();
    final first = whole.split(RegExp(r'\s+')).first;
    return first.replaceAll('.', '').length > 1 ? first : whole;
  }
}

/// How a group in the Shared list stands to this account.
enum ShareGroupKind {
  /// Its own notes, open to people of whom at least one has joined.
  sharedWith,

  /// Its own notes, open only to people who have not joined yet.
  waiting,

  /// Notes somebody else owns and shares with this account.
  from,
}

/// A heading in the Shared list: whose notes are under it. Two notes are in
/// the same group exactly when their groups have the same [key].
class ShareGroup {
  const ShareGroup(this.kind, this.people);

  final ShareGroupKind kind;

  /// The owner alone for [ShareGroupKind.from]; otherwise everyone the notes
  /// are open to, by name.
  final List<SharePerson> people;

  String get key =>
      '${kind.name}:${[for (final person in people) person.email].join('+')}';

  /// "With Priya", "With Aoife and Kwame", "From Wen", "Waiting for tomas",
  /// and "With Aoife, waiting for kwame" while only some have joined.
  String get title {
    final firsts = [for (final person in people) person.firstName];
    String nameOf(int index) =>
        firsts.where((first) => first == firsts[index]).length > 1
        ? people[index].name
        : firsts[index];
    String list(Iterable<String> names) => switch (names.toList()) {
      [final one] => one,
      [final one, final two] => '$one and $two',
      [final one, final two, final three] => '$one, $two and $three',
      final many => '${many[0]}, ${many[1]} and ${many.length - 2} others',
    };
    final all = [for (var i = 0; i < people.length; i++) nameOf(i)];
    if (kind == ShareGroupKind.from) return 'From ${list(all)}';
    if (kind == ShareGroupKind.waiting) return 'Waiting for ${list(all)}';
    final invited = [
      for (var i = 0; i < people.length; i++)
        if (people[i].isInvited) nameOf(i),
    ];
    final joined = [
      for (var i = 0; i < people.length; i++)
        if (!people[i].isInvited) nameOf(i),
    ];
    if (invited.isEmpty || joined.isEmpty) return 'With ${list(all)}';
    return 'With ${list(joined)}, waiting for ${list(invited)}';
  }
}
