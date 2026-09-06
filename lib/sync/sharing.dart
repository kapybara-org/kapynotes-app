import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/note.dart';
import '../data/notes_store.dart';
import 'aead.dart';
import 'config.dart';
import 'key_wrap.dart';
import 'note_payload.dart';
import 'safety.dart';
import 'space_keyring.dart';
import 'spaces.dart';
import 'sync_api.dart';
import 'sync_service.dart';
import 'trust.dart';
import 'vault.dart';

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
  }) : _api = api,
       _vault = vault,
       _keyring = keyring,
       _notes = notes,
       _sync = sync {
    _keyring.addListener(notifyListeners);
    _keyring.trust.addListener(notifyListeners);
  }

  final SyncApi _api;
  final Vault _vault;
  final SpaceKeyring _keyring;
  final NotesStore _notes;
  final SyncService _sync;

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

  /// Whether this device can read and write in a space right now.
  bool holdsKey(String spaceId) => _keyring.holdsKey(spaceId);

  /// Where an invitation link lands. The token is useless to anyone who
  /// cannot sign in as the invited address.
  Uri inviteLink(String token) => Uri.parse(kSiteBaseUrl).resolve('join/$token');

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
    notifyListeners();
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
    final space = _keyring.byId(spaceId);
    if (space == null || !space.isTeam) {
      throw const SyncProtocolException('no such shared space');
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

  /// Shares a note with one person: finds a space that is exactly the two of
  /// you, or makes one and invites them, then moves the note into it.
  Future<Space> shareNoteWith(String noteId, {required String email}) async {
    final address = email.trim().toLowerCase();
    final existing = _pairSpace(address);
    final space = existing ?? await createSpace(_pairName(address));
    if (existing == null) await _api.invite(space.id, address);
    await shareNote(noteId, spaceId: space.id);
    return _keyring.byId(space.id) ?? space;
  }

  /// A team space whose members and invitations are exactly this account and
  /// [email], if one exists.
  Space? _pairSpace(String email) {
    for (final space in teams) {
      final others = space.othersThan(userId).map((m) => m.email.toLowerCase());
      final invited = space.invites.map((i) => i.email.toLowerCase());
      final people = {...others, ...invited};
      if (people.length == 1 && people.contains(email)) return space;
    }
    return null;
  }

  static String _pairName(String email) {
    final local = email.split('@').first;
    final name = local.isEmpty ? email : local;
    return 'With $name';
  }

  /// Takes a note out of a shared space and back into the personal one, under
  /// a new key. Any member may do this: they could copy the text and delete
  /// the original anyway, so it is not a privilege.
  Future<void> unshareNote(String noteId) async {
    _notes.moveToSpace(noteId, spaceId: null, contentKey: null);
    await _sync.syncNow();
  }

  /// A new note straight into a shared space.
  Note createNoteIn(String spaceId) {
    final space = _keyring.byId(spaceId);
    if (space == null || !space.isTeam || !_keyring.holdsKey(spaceId)) {
      throw const SyncProtocolException('no such shared space');
    }
    return _notes.create(
      spaceId: spaceId,
      contentKey: randomKey(),
      keyGeneration: space.keyGeneration,
    );
  }

  // -------------------------------------------------------------------------
  // Membership
  // -------------------------------------------------------------------------

  Future<InviteResult> invite(String spaceId, String email) async {
    final result = await _api.invite(spaceId, email.trim().toLowerCase());
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

  /// Leaving a space. The notes already on this device are the user's to
  /// keep; nothing here pretends otherwise.
  Future<void> leave(String spaceId) async {
    await _api.removeMember(spaceId, userId);
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
    final mine = _notes.notesIn(spaceId);
    final at = DateTime.now();
    final sealed = await _vault.sealAll([
      for (final note in mine) NotePayload.fromNote(note),
    ]);
    final personal = _keyring.personal;
    if (personal == null) throw const SyncProtocolException('no personal space');
    await _api.stopSharing(spaceId, [
      for (var i = 0; i < mine.length; i++)
        WireNote(
          id: mine[i].id,
          spaceId: personal.id,
          updatedAt: at,
          payload: sealed[i],
        ),
    ]);
    _notes.bringHome(mine.map((note) => note.id), at: at);
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
    _keyring.removeListener(notifyListeners);
    _keyring.trust.removeListener(notifyListeners);
    super.dispose();
  }
}
