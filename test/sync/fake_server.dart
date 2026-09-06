import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/sync/auth_api.dart';
import 'package:kapy_notes/sync/identity.dart';
import 'package:kapy_notes/sync/key_bundle.dart';
import 'package:kapy_notes/sync/key_wrap.dart';
import 'package:kapy_notes/sync/live_channel.dart';
import 'package:kapy_notes/sync/safety.dart';
import 'package:kapy_notes/sync/sealed_box.dart';
import 'package:kapy_notes/sync/spaces.dart';
import 'package:kapy_notes/sync/sync_api.dart';
import 'package:kapy_notes/sync/vault.dart';

/// An in-memory stand-in for the server, implementing the rules that matter:
/// last-writer-wins on `updatedAt` per (space, id), a keyset cursor over
/// `(updatedAt, id)` per space, membership on every read and write, a move as
/// a tombstone and a live note applied together or not at all, key
/// generations and content-key epochs compared as integers, and the grant,
/// removal, rotation, reap and stop-sharing rules of `server/src`.
///
/// Having one lets several devices of several accounts talk to the same store,
/// which is the only way to test the cases sharing actually gets wrong — a
/// member removed while another edits, a rotation racing a write, a space
/// that empties.
class FakeServer {
  final Map<String, FakeUser> users = {};
  final Map<String, FakeSpace> spaces = {};

  /// spaceId → note id → row.
  final Map<String, Map<String, WireNote>> _rows = {};

  /// Requests recorded in order, so a test can assert on what was sent.
  final List<String> calls = [];

  /// Set to fail the next call, to exercise the offline and signed-out paths.
  SyncException? failNext;

  /// Open wake-up channels, by device. The real server keeps the same map,
  /// and applies the same rule to it: everyone but the device that pushed.
  final Map<String, void Function(LiveSignal)> live = {};
  final Map<String, String> _deviceUser = {};

  /// True to drop wake-ups on the floor, standing in for a proxy that will
  /// not carry an event stream. The devices should still converge — slower,
  /// on the poll.
  bool deliverWakeups = true;

  /// Invitation emails "sent". A blocked sender's invitation never appears
  /// here, which is how a test sees the silence.
  final List<({String to, String token})> outbox = [];

  /// Reports filed, in order. `content` is null unless consent was given.
  final List<FakeReport> reports = [];

  /// The minimum protocol the server serves. Raise it to see a build refuse.
  int minProtocol = 1;

  /// Notes returned per page, mirroring the real limit being smaller than the
  /// corpus.
  int pageSize = 200;

  /// The address [deleteAccount] will accept for the default account,
  /// mirroring the real server's check that the caller named the account it
  /// meant.
  String get email => user('user-1').email;
  set email(String value) => user('user-1').email = value;

  /// True once the default account has been deleted, so a test can tell "the
  /// request was refused" apart from "the request never arrived".
  bool get deleted => users['user-1']?.deleted ?? false;

  /// The default account's key bundle.
  KeyBundle? get bundle => users['user-1']?.bundle;
  set bundle(KeyBundle? value) => user('user-1').bundle = value;

  /// Every row across every space, keyed by note id, with a live copy taking
  /// precedence over a tombstone left behind by a move. What a single-account
  /// test means by "what the server holds".
  Map<String, WireNote> get rows {
    final all = <String, WireNote>{};
    for (final space in _rows.values) {
      for (final row in space.values) {
        final existing = all[row.id];
        if (existing == null || (existing.isTombstone && !row.isTombstone)) {
          all[row.id] = row;
        }
      }
    }
    return all;
  }

  Map<String, WireNote> rowsIn(String spaceId) => _rows[spaceId] ?? const {};

  /// Gives an account a key bundle with no identity keys yet, the shape an
  /// account that unlocked before sharing existed has: the first sync then
  /// generates and publishes the identity keys, as it would in the app.
  KeyBundle seedBundle(String userId) {
    final account = user(userId);
    return account.bundle ??= KeyBundle(
      wrappedMasterKey: SealedBox(
        cipherText: Uint8List(48),
        nonce: Uint8List(24),
        version: 1,
      ),
      kdf: KdfParams(
        salt: Uint8List(16),
        memory: 8,
        iterations: 1,
        parallelism: 1,
      ),
    );
  }

  FakeUser user(String id) => users.putIfAbsent(
    id,
    () => FakeUser(
      id: id,
      email: id == 'user-1' ? 'someone@example.com' : '$id@example.com',
    ),
  );

  /// The personal space for [userId], created on first contact.
  FakeSpace personal(String userId) {
    for (final space in spaces.values) {
      if (space.kind == SpaceKind.personal && space.ownerId == userId) {
        return space;
      }
    }
    final space = FakeSpace(
      id: 'personal-$userId',
      kind: SpaceKind.personal,
      name: null,
      ownerId: userId,
    )..members[userId] = SpaceRole.owner;
    spaces[space.id] = space;
    return space;
  }

  void dropChannels() {
    for (final notify in live.values.toList()) {
      notify(LiveSignal.disconnected);
    }
  }

  void announceSpace(String spaceId, String? origin) {
    if (!deliverWakeups) return;
    final space = spaces[spaceId];
    if (space == null) return;
    for (final entry in live.entries.toList()) {
      if (entry.key == origin) continue;
      if (!space.members.containsKey(_deviceUser[entry.key])) continue;
      entry.value(LiveSignal.wakeFor(spaceId));
    }
  }

  void announceUsers(Iterable<String> userIds) {
    if (!deliverWakeups) return;
    final wanted = userIds.toSet();
    for (final entry in live.entries.toList()) {
      if (!wanted.contains(_deviceUser[entry.key])) continue;
      entry.value(LiveSignal.wake);
    }
  }

  // -------------------------------------------------------------------------
  // Sync
  // -------------------------------------------------------------------------

  Never _refuse(int status, String code, [Map<String, Object?> extra = const {}]) =>
      throw SyncRefusedException(status, code, {'error': code, ...extra});

  FakeSpace _member(String userId, String spaceId) {
    final space = spaces[spaceId];
    if (space == null || !space.members.containsKey(userId)) {
      _refuse(404, 'no such space');
    }
    return space;
  }

  PushResult push(String userId, List<WireNote> notes, {String? origin}) {
    calls.add('push:${notes.length}');
    final personalId = personal(userId).id;
    final items = [
      for (final note in notes)
        (note: note, spaceId: note.spaceId ?? personalId),
    ];

    final spaceIds = {for (final item in items) item.spaceId};
    for (final id in spaceIds) {
      final space = spaces[id];
      if (space == null || !space.members.containsKey(userId)) {
        _refuse(403, 'not a member of this space', {'spaceId': id});
      }
    }
    for (final item in items) {
      if (item.note.isTombstone) continue;
      final space = spaces[item.spaceId]!;
      if (space.kind == SpaceKind.personal) {
        if (item.note.key != null) _refuse(400, 'a personal note carries no key');
      } else if (item.note.key != null &&
          item.note.key!.keyGeneration != space.keyGeneration) {
        _refuse(409, 'stale-key-generation', {
          'spaceId': item.spaceId,
          'keyGeneration': space.keyGeneration,
        });
      }
    }

    // Moves: a note in two spaces, one dead, one live.
    final groups = <String, List<({WireNote note, String spaceId})>>{};
    for (final item in items) {
      groups.putIfAbsent(item.note.id, () => []).add(item);
    }
    final skipped = <String>{};
    final conflicts = <WireNote>[];
    final moves = <({String id, String from, String to})>[];
    for (final entry in groups.entries) {
      final group = entry.value;
      if (group.length == 1) continue;
      final live = group.where((g) => !g.note.isTombstone).toList();
      final dead = group.where((g) => g.note.isTombstone).toList();
      if (group.length > 2 || live.length != 1 || dead.length != 1) {
        _refuse(400, 'a note in two spaces must be a move');
      }
      final src = _rows[dead.single.spaceId]?[entry.key];
      final dst = _rows[live.single.spaceId]?[entry.key];
      final blocked =
          (src != null && !src.updatedAt.isBefore(dead.single.note.updatedAt)) ||
          (dst != null && !dst.updatedAt.isBefore(live.single.note.updatedAt));
      if (blocked) {
        skipped.add('${dead.single.spaceId}:${entry.key}');
        skipped.add('${live.single.spaceId}:${entry.key}');
        if (src != null) conflicts.add(src);
        if (dst != null) conflicts.add(dst);
      } else {
        moves.add((id: entry.key, from: dead.single.spaceId, to: live.single.spaceId));
      }
    }

    final applied = <String>{};
    final appliedKeys = <String>{};
    for (final item in items) {
      final key = '${item.spaceId}:${item.note.id}';
      if (skipped.contains(key)) continue;
      final rows = _rows.putIfAbsent(item.spaceId, () => {});
      final existing = rows[item.note.id];
      if (existing == null || existing.updatedAt.isBefore(item.note.updatedAt)) {
        rows[item.note.id] = WireNote(
          id: item.note.id,
          spaceId: item.spaceId,
          updatedAt: item.note.updatedAt,
          deletedAt: item.note.deletedAt,
          payload: item.note.payload,
        );
        applied.add(item.note.id);
        appliedKeys.add(key);
      } else {
        // Rejected, and the winning copy rides back with the rejection.
        conflicts.add(existing);
      }
    }

    // Keys ride beside their notes.
    for (final item in items) {
      final key = '${item.spaceId}:${item.note.id}';
      if (!appliedKeys.contains(key)) continue;
      final space = spaces[item.spaceId]!;
      if (space.kind != SpaceKind.team) continue;
      if (item.note.isTombstone) {
        space.noteKeys.remove(item.note.id);
        continue;
      }
      final wire = item.note.key;
      final stored = space.noteKeys[item.note.id];
      if (wire == null) {
        if (stored == null) _refuse(400, 'a team note needs a key');
        continue;
      }
      Never refuseEpoch() => _refuse(409, 'content-key-epoch', {
        'spaceId': item.spaceId,
        'noteId': item.note.id,
        'contentKeyEpoch': stored?.contentKeyEpoch ?? 0,
      });
      if (stored == null) {
        if (wire.contentKeyEpoch != 1) refuseEpoch();
        space.noteKeys[item.note.id] = FakeNoteKey(
          wrapped: wire.wrapped,
          keyGeneration: space.keyGeneration,
          contentKeyEpoch: 1,
          contentKeyGeneration: space.keyGeneration,
        );
      } else if (wire.contentKeyEpoch == stored.contentKeyEpoch) {
        // Same key; nothing to do.
      } else if (wire.contentKeyEpoch == stored.contentKeyEpoch + 1) {
        space.noteKeys[item.note.id] = FakeNoteKey(
          wrapped: wire.wrapped,
          keyGeneration: space.keyGeneration,
          contentKeyEpoch: wire.contentKeyEpoch,
          contentKeyGeneration: space.keyGeneration,
        );
      } else {
        refuseEpoch();
      }
    }

    // Anything the tombstones emptied.
    final reaped = <String>[];
    for (final item in items) {
      if (!item.note.isTombstone) continue;
      if (!appliedKeys.contains('${item.spaceId}:${item.note.id}')) continue;
      reaped.addAll(_reapIfEmpty(item.spaceId));
    }

    if (applied.isNotEmpty) {
      for (final id in spaceIds) {
        announceSpace(id, origin);
      }
    }
    if (reaped.isNotEmpty) announceUsers(reaped);

    return PushResult(
      applied: applied,
      conflicts: conflicts.map(_withKey).toList(),
      serverTime: DateTime.now(),
    );
  }

  WireNote _withKey(WireNote row) {
    final space = spaces[row.spaceId];
    final key = row.isTombstone ? null : space?.noteKeys[row.id];
    return WireNote(
      id: row.id,
      spaceId: row.spaceId,
      updatedAt: row.updatedAt,
      deletedAt: row.deletedAt,
      payload: row.payload,
      key: key == null
          ? null
          : WireNoteKey(
              wrapped: key.wrapped,
              keyGeneration: key.keyGeneration,
              contentKeyEpoch: key.contentKeyEpoch,
              contentKeyGeneration: key.contentKeyGeneration,
            ),
    );
  }

  PullPage pull(String userId, {String? space, String? cursor}) {
    calls.add('pull:${cursor ?? ''}');
    final spaceId = space ?? personal(userId).id;
    _member(userId, spaceId);
    final sorted = (_rows[spaceId] ?? const {}).values.toList()
      ..sort((a, b) {
        final byTime = a.updatedAt.compareTo(b.updatedAt);
        return byTime != 0 ? byTime : a.id.compareTo(b.id);
      });

    var start = 0;
    if (cursor != null && cursor.isNotEmpty) {
      final decoded = utf8.decode(base64Url.decode(cursor));
      final split = decoded.indexOf('.');
      final millis = int.parse(decoded.substring(0, split));
      final id = decoded.substring(split + 1);
      start = sorted.indexWhere(
        (n) =>
            n.updatedAt.millisecondsSinceEpoch > millis ||
            (n.updatedAt.millisecondsSinceEpoch == millis && n.id.compareTo(id) > 0),
      );
      if (start < 0) start = sorted.length;
    }

    final end = (start + pageSize).clamp(0, sorted.length);
    final page = sorted.sublist(start, end);
    final last = page.isEmpty ? null : page.last;

    return PullPage(
      notes: page.map(_withKey).toList(),
      // An empty page echoes the cursor back rather than rewinding.
      cursor: last == null
          ? (cursor ?? '')
          : base64Url.encode(
              utf8.encode('${last.updatedAt.millisecondsSinceEpoch}.${last.id}'),
            ),
      hasMore: end < sorted.length,
    );
  }

  // -------------------------------------------------------------------------
  // Spaces
  // -------------------------------------------------------------------------

  List<Space> spacesFor(String userId) {
    personal(userId);
    return [
      for (final space in spaces.values)
        if (space.members.containsKey(userId)) _wire(space, userId),
    ];
  }

  Space _wire(FakeSpace space, String userId) => Space(
    id: space.id,
    kind: space.kind,
    name: space.name,
    ownerId: space.ownerId,
    role: space.members[userId]!,
    keyGeneration: space.keyGeneration,
    rotationPending: space.rotationPending,
    spaceKey: space.keys[userId],
    members: [
      for (final entry in space.members.entries)
        SpaceMember(
          userId: entry.key,
          email: user(entry.key).email,
          role: entry.value,
          joinedAt: DateTime.utc(2026, 9, 1),
          hasKey: space.keys.containsKey(entry.key),
          x25519Public: user(entry.key).bundle?.identity?.x25519Public,
          ed25519Public: user(entry.key).bundle?.identity?.ed25519Public,
        ),
    ],
    invites: [
      for (final entry in space.invites.entries)
        SpaceInvite(
          token: entry.key,
          email: entry.value,
          expiresAt: DateTime.utc(2027),
          createdAt: DateTime.utc(2026, 9, 1),
        ),
    ],
    liveNotes: _liveNotes(space.id).length,
    createdAt: DateTime.utc(2026, 9, 1),
  );

  Iterable<WireNote> _liveNotes(String spaceId) =>
      (_rows[spaceId] ?? const {}).values.where((n) => !n.isTombstone);

  List<String> _reapIfEmpty(String spaceId) {
    final space = spaces[spaceId];
    if (space == null || space.kind != SpaceKind.team) return const [];
    if (space.members.length > 1) return const [];
    if (space.invites.isNotEmpty) return const [];
    if (_liveNotes(spaceId).isNotEmpty) return const [];
    final members = space.members.keys.toList();
    spaces.remove(spaceId);
    _rows.remove(spaceId);
    return members;
  }

  void _requireTerms(String userId) {
    if (user(userId).termsVersion < sharingTermsVersion) {
      _refuse(403, termsRequiredCode);
    }
  }

  Space createSpace(String userId, String name, SealedToPublicKey key) {
    calls.add('createSpace');
    _requireTerms(userId);
    final space = FakeSpace(
      id: 'space-${spaces.length + 1}-$name',
      kind: SpaceKind.team,
      name: name,
      ownerId: userId,
    )
      ..members[userId] = SpaceRole.owner
      ..keys[userId] = key;
    spaces[space.id] = space;
    return _wire(space, userId);
  }

  InviteResult invite(String userId, String spaceId, String email) {
    calls.add('invite:$email');
    _requireTerms(userId);
    final space = _member(userId, spaceId);
    if (space.members[userId] != SpaceRole.owner) {
      _refuse(403, 'only the owner can do this');
    }
    for (final member in space.members.keys) {
      if (user(member).email.toLowerCase() == email) _refuse(409, 'already a member');
    }
    space.invites.removeWhere((_, existing) => existing == email);
    final token = 'invite-${email.split('@').first}-${space.invites.length}';
    space.invites[token] = email;
    // Blocked: written, never delivered, and the sender is told nothing.
    final blockedBy = users.values.where(
      (u) => u.email.toLowerCase() == email && u.blocks.contains(user(userId).email.toLowerCase()),
    );
    if (blockedBy.isEmpty) outbox.add((to: email, token: token));
    announceSpace(spaceId, null);
    return InviteResult(
      token: token,
      email: email,
      expiresAt: DateTime.utc(2027),
      emailed: true,
    );
  }

  List<PendingInvite> invitesFor(String userId) {
    final email = user(userId).email.toLowerCase();
    final blocked = user(userId).blocks;
    return [
      for (final space in spaces.values)
        for (final entry in space.invites.entries)
          if (entry.value == email &&
              !blocked.contains(user(space.ownerId).email.toLowerCase()))
            PendingInvite(
              token: entry.key,
              spaceId: space.id,
              spaceName: space.name ?? 'Shared notes',
              invitedBy: user(space.ownerId).email,
              expiresAt: DateTime.utc(2027),
            ),
    ];
  }

  Space acceptInvite(String userId, String token) {
    calls.add('accept');
    final email = user(userId).email.toLowerCase();
    for (final space in spaces.values) {
      if (space.invites[token] != email) continue;
      // A blocked sender's invitation does not exist, however its link
      // travelled, and the rules are agreed to before joining.
      if (user(userId).blocks.contains(user(space.ownerId).email.toLowerCase())) {
        _refuse(404, 'no such invitation');
      }
      _requireTerms(userId);
      space.invites.remove(token);
      space.members[userId] = SpaceRole.member;
      announceSpace(space.id, null);
      return _wire(space, userId);
    }
    _refuse(404, 'no such invitation');
  }

  void declineInvite(String userId, String token) {
    final email = user(userId).email.toLowerCase();
    for (final space in spaces.values) {
      if (space.invites[token] == email) {
        space.invites.remove(token);
        return;
      }
    }
    _refuse(404, 'no such invitation');
  }

  void grantKey(String userId, String spaceId, String target, int generation, SealedToPublicKey key) {
    calls.add('grant:$target');
    final space = _member(userId, spaceId);
    if (!space.keys.containsKey(userId)) _refuse(403, 'you do not hold this space key');
    if (!space.members.containsKey(target)) _refuse(404, 'not a member');
    if (space.keyGeneration != generation) {
      _refuse(409, 'stale-key-generation', {'keyGeneration': space.keyGeneration});
    }
    if (space.keys.containsKey(target)) _refuse(409, 'already granted');
    space.keys[target] = key;
    announceUsers([target]);
    announceSpace(spaceId, null);
  }

  void removeMember(String userId, String spaceId, String target) {
    calls.add('remove:$target');
    final space = _member(userId, spaceId);
    final role = space.members[userId]!;
    if (target == userId) {
      if (role == SpaceRole.owner) _refuse(400, 'the owner cannot leave');
    } else if (role != SpaceRole.owner) {
      _refuse(403, 'only the owner can remove someone');
    }
    if (!space.members.containsKey(target)) _refuse(404, 'not a member');
    space.members.remove(target);
    space.keys.remove(target);
    space.rotationPending = true;
    announceUsers([target]);
    final reaped = _reapIfEmpty(spaceId);
    if (reaped.isNotEmpty) {
      announceUsers(reaped);
    } else {
      announceSpace(spaceId, null);
    }
  }

  List<WireNoteKey> noteKeys(String userId, String spaceId) {
    final space = _member(userId, spaceId);
    return [
      for (final note in _liveNotes(spaceId))
        if (space.noteKeys[note.id] case final key?)
          WireNoteKey(
            wrapped: key.wrapped,
            keyGeneration: key.keyGeneration,
            contentKeyEpoch: key.contentKeyEpoch,
            contentKeyGeneration: key.contentKeyGeneration,
            noteId: note.id,
          ),
    ];
  }

  void rotate(
    String userId,
    String spaceId,
    int expected,
    Map<String, SealedToPublicKey> spaceKeys,
    Map<String, ({WrappedKey key, int fromEpoch})> wraps,
  ) {
    calls.add('rotate');
    final space = _member(userId, spaceId);
    if (space.keyGeneration != expected) {
      _refuse(409, 'stale-key-generation', {'keyGeneration': space.keyGeneration});
    }
    for (final holder in space.keys.keys) {
      if (!spaceKeys.containsKey(holder)) _refuse(409, 'incomplete', {'missingMember': holder});
    }
    for (final target in spaceKeys.keys) {
      if (!space.members.containsKey(target)) _refuse(409, 'not a member');
    }
    for (final note in _liveNotes(spaceId)) {
      final wrap = wraps[note.id];
      final stored = space.noteKeys[note.id];
      if (wrap == null || stored == null) _refuse(409, 'incomplete', {'missingNote': note.id});
      if (wrap.fromEpoch != stored.contentKeyEpoch) {
        _refuse(409, 'content-key-epoch', {'noteId': note.id});
      }
    }
    final generation = expected + 1;
    space.keys
      ..clear()
      ..addAll(spaceKeys);
    for (final note in _liveNotes(spaceId)) {
      final stored = space.noteKeys[note.id]!;
      space.noteKeys[note.id] = FakeNoteKey(
        wrapped: wraps[note.id]!.key,
        keyGeneration: generation,
        contentKeyEpoch: stored.contentKeyEpoch,
        contentKeyGeneration: stored.contentKeyGeneration,
      );
    }
    space.noteKeys.removeWhere((_, key) => key.keyGeneration != generation);
    space.keyGeneration = generation;
    space.rotationPending = false;
    announceSpace(spaceId, null);
  }

  Space transfer(String userId, String spaceId, String target) {
    final space = _member(userId, spaceId);
    if (space.members[userId] != SpaceRole.owner) _refuse(403, 'only the owner can do this');
    if (space.members[target] != SpaceRole.member) _refuse(404, 'not a member');
    if (!space.keys.containsKey(target)) _refuse(409, 'the new owner does not hold the key yet');
    space.ownerId = target;
    space.members[userId] = SpaceRole.member;
    space.members[target] = SpaceRole.owner;
    announceSpace(spaceId, null);
    return _wire(space, userId);
  }

  void stopSharing(String userId, String spaceId, List<WireNote> notes) {
    calls.add('stop');
    final space = _member(userId, spaceId);
    if (space.members[userId] != SpaceRole.owner) _refuse(403, 'only the owner can do this');
    final personalId = personal(userId).id;
    final expected = {for (final note in _liveNotes(spaceId)) note.id};
    final carried = <String>{};
    for (final note in notes) {
      if (note.spaceId != personalId || note.isTombstone) {
        _refuse(400, 'every note must be live and re-sealed for your personal space');
      }
      if (!expected.contains(note.id)) _refuse(409, 'not in this space');
      carried.add(note.id);
    }
    for (final id in expected) {
      if (!carried.contains(id)) _refuse(409, 'incomplete', {'missingNote': id});
    }
    if (notes.isNotEmpty) {
      final result = push(userId, notes);
      if (result.conflicts.isNotEmpty) _refuse(409, 'conflict');
    }
    final members = space.members.keys.toList();
    spaces.remove(spaceId);
    _rows.remove(spaceId);
    announceUsers(members);
    announceSpace(personalId, null);
  }

  void deleteAccount(String userId, String confirmation) {
    calls.add('deleteAccount');
    final account = user(userId);
    if (confirmation.trim().toLowerCase() != account.email.trim().toLowerCase()) {
      throw const SyncRefusedException(400, 'confirmation does not match this account', {});
    }
    final owned = [
      for (final space in spaces.values)
        if (space.kind == SpaceKind.team && space.ownerId == userId)
          {'id': space.id, 'name': space.name},
    ];
    if (owned.isNotEmpty) {
      throw SyncRefusedException(409, 'owned-spaces', {'error': 'owned-spaces', 'spaces': owned});
    }
    for (final space in spaces.values.toList()) {
      if (space.kind == SpaceKind.team && space.members.containsKey(userId)) {
        space.members.remove(userId);
        space.keys.remove(userId);
        space.rotationPending = true;
        _reapIfEmpty(space.id);
      }
    }
    final own = personal(userId).id;
    spaces.remove(own);
    _rows.remove(own);
    account.deleted = true;
    account.bundle = null;
  }
}

class FakeUser {
  FakeUser({required this.id, required this.email});
  final String id;
  String email;
  KeyBundle? bundle;
  bool deleted = false;

  /// Accepted by default, because almost every test is about something else.
  /// Set to 0 for an account that has agreed to nothing.
  int termsVersion = sharingTermsVersion;

  /// Lower-cased addresses this account will not accept invitations from.
  final Set<String> blocks = {};
}

class FakeReport {
  const FakeReport({
    required this.kind,
    required this.reason,
    required this.reporter,
    this.reportedEmail,
    this.spaceId,
    this.noteId,
    this.content,
    this.details,
  });

  final ReportKind kind;
  final ReportReason reason;
  final String reporter;
  final String? reportedEmail;
  final String? spaceId;
  final String? noteId;

  /// Null unless the person reporting explicitly chose to attach the note.
  final String? content;
  final String? details;
}

class FakeSpace {
  FakeSpace({
    required this.id,
    required this.kind,
    required this.name,
    required this.ownerId,
  });

  final String id;
  final SpaceKind kind;
  String? name;
  String ownerId;
  int keyGeneration = 1;
  bool rotationPending = false;
  final Map<String, SpaceRole> members = {};
  final Map<String, SealedToPublicKey> keys = {};
  final Map<String, String> invites = {};
  final Map<String, FakeNoteKey> noteKeys = {};
}

class FakeNoteKey {
  const FakeNoteKey({
    required this.wrapped,
    required this.keyGeneration,
    required this.contentKeyEpoch,
    required this.contentKeyGeneration,
  });
  final WrappedKey wrapped;
  final int keyGeneration;
  final int contentKeyEpoch;
  final int contentKeyGeneration;
}

/// One device's connection to [FakeServer], as one account.
class FakeApi implements SyncApi {
  FakeApi(this.server, {this.device = 'device', this.userId = 'user-1'});

  final FakeServer server;

  /// Which device this connection belongs to, so the server can skip waking
  /// the one that pushed.
  final String device;
  final String userId;

  /// What this build claims to speak. Lower it to see the server refuse.
  int protocol = protocolVersion;

  void _gate() {
    final failure = server.failNext;
    if (failure != null) {
      server.failNext = null;
      throw failure;
    }
    if (protocol < server.minProtocol) {
      throw SyncOutdatedException(server.minProtocol);
    }
    if (server.user(userId).deleted) {
      throw const SyncAuthException('session rejected');
    }
  }

  @override
  Future<PullPage> pull({String? space, String? cursor, int limit = pullDefaultLimit}) async {
    _gate();
    return server.pull(userId, space: space, cursor: cursor);
  }

  @override
  Future<PushResult> push(List<WireNote> notes) async {
    _gate();
    return server.push(userId, notes, origin: device);
  }

  StreamController<LiveSignal>? _channel;

  @override
  Stream<LiveSignal> live() {
    // One controller however many times this is called, and broadcast so it
    // can be listened to again after a pause — both because that is what the
    // real api does, and a fake that made a fresh single-subscription stream
    // each time would hide the bug where resuming throws.
    final channel = _channel ??= StreamController<LiveSignal>.broadcast(
      onListen: () {
        server.live[device] = (signal) {
          final open = _channel;
          if (open != null && !open.isClosed) open.add(signal);
        };
        server._deviceUser[device] = userId;
        _channel!.add(LiveSignal.connected);
      },
      onCancel: () {
        server.live.remove(device);
        server._deviceUser.remove(device);
      },
    );
    return channel.stream;
  }

  @override
  Future<KeyBundle?> fetchKeyBundle() async {
    _gate();
    return server.user(userId).bundle;
  }

  @override
  Future<void> createKeyBundle(KeyBundle bundle) async {
    _gate();
    server.user(userId).bundle = bundle;
  }

  @override
  Future<void> rotateKeyBundle(KeyBundle bundle) async {
    _gate();
    final existing = server.user(userId).bundle;
    server.user(userId).bundle = KeyBundle(
      wrappedMasterKey: bundle.wrappedMasterKey,
      kdf: bundle.kdf,
      recoveryWrappedMasterKey: bundle.recoveryWrappedMasterKey,
      identity: existing?.identity,
    );
  }

  @override
  Future<void> publishIdentity(WireIdentity identity) async {
    _gate();
    final account = server.user(userId);
    final existing = account.bundle;
    if (existing == null) throw const SyncRefusedException(404, 'no key bundle', {});
    if (existing.identity != null) {
      throw const SyncRefusedException(409, 'identity keys already exist', {});
    }
    account.bundle = KeyBundle(
      wrappedMasterKey: existing.wrappedMasterKey,
      kdf: existing.kdf,
      recoveryWrappedMasterKey: existing.recoveryWrappedMasterKey,
      identity: identity,
    );
  }

  @override
  Future<void> deleteAccount(String confirmation) async {
    _gate();
    server.deleteAccount(userId, confirmation);
  }

  @override
  Future<List<Space>> fetchSpaces() async {
    _gate();
    server.calls.add('spaces');
    return server.spacesFor(userId);
  }

  @override
  Future<Space> createSpace({required String name, required SealedToPublicKey spaceKey}) async {
    _gate();
    return server.createSpace(userId, name, spaceKey);
  }

  @override
  Future<Space> renameSpace(String spaceId, String name) async {
    _gate();
    final space = server._member(userId, spaceId);
    space.name = name;
    return server._wire(space, userId);
  }

  @override
  Future<InviteResult> invite(String spaceId, String email) async {
    _gate();
    return server.invite(userId, spaceId, email);
  }

  @override
  Future<void> revokeInvite(String spaceId, String token) async {
    _gate();
    server._member(userId, spaceId).invites.remove(token);
  }

  @override
  Future<List<PendingInvite>> fetchInvites() async {
    _gate();
    return server.invitesFor(userId);
  }

  @override
  Future<Space> acceptInvite(String token) async {
    _gate();
    return server.acceptInvite(userId, token);
  }

  @override
  Future<void> declineInvite(String token) async {
    _gate();
    server.declineInvite(userId, token);
  }

  @override
  Future<void> grantKey({
    required String spaceId,
    required String userId,
    required int keyGeneration,
    required SealedToPublicKey spaceKey,
  }) async {
    _gate();
    server.grantKey(this.userId, spaceId, userId, keyGeneration, spaceKey);
  }

  @override
  Future<void> removeMember(String spaceId, String userId) async {
    _gate();
    server.removeMember(this.userId, spaceId, userId);
  }

  @override
  Future<List<WireNoteKey>> fetchNoteKeys(String spaceId) async {
    _gate();
    return server.noteKeys(userId, spaceId);
  }

  @override
  Future<void> rotate({
    required String spaceId,
    required int expectedGeneration,
    required Map<String, SealedToPublicKey> spaceKeys,
    required Map<String, ({WrappedKey key, int fromEpoch})> noteKeys,
  }) async {
    _gate();
    server.rotate(userId, spaceId, expectedGeneration, spaceKeys, noteKeys);
  }

  @override
  Future<Space> transfer(String spaceId, String userId) async {
    _gate();
    return server.transfer(this.userId, spaceId, userId);
  }

  @override
  Future<void> stopSharing(String spaceId, List<WireNote> notes) async {
    _gate();
    server.stopSharing(userId, spaceId, notes);
  }

  @override
  Future<List<Block>> fetchBlocks() async {
    _gate();
    return [
      for (final email in server.user(userId).blocks)
        Block(email: email, createdAt: DateTime.utc(2026, 9, 1)),
    ];
  }

  @override
  Future<void> block(String email) async {
    _gate();
    final address = email.trim().toLowerCase();
    if (address == server.user(userId).email.toLowerCase()) {
      throw const SyncRefusedException(400, 'you cannot block yourself', {});
    }
    server.user(userId).blocks.add(address);
    // Anything already sent stops being visible in the same moment.
    for (final space in server.spaces.values) {
      space.invites.removeWhere(
        (_, invited) =>
            invited == server.user(userId).email.toLowerCase() &&
            server.user(space.ownerId).email.toLowerCase() == address,
      );
    }
  }

  @override
  Future<void> unblock(String email) async {
    _gate();
    server.user(userId).blocks.remove(email.trim().toLowerCase());
  }

  @override
  Future<TermsStatus> fetchTerms() async {
    _gate();
    return TermsStatus(
      acceptedVersion: server.user(userId).termsVersion,
      currentVersion: sharingTermsVersion,
    );
  }

  @override
  Future<TermsStatus> acceptTerms() async {
    _gate();
    server.user(userId).termsVersion = sharingTermsVersion;
    return const TermsStatus(
      acceptedVersion: sharingTermsVersion,
      currentVersion: sharingTermsVersion,
    );
  }

  @override
  Future<void> report({
    required ReportTarget target,
    required ReportReason reason,
    String? details,
    bool includeContent = false,
  }) async {
    _gate();
    final attach = includeContent && target.canAttachContent;
    server.reports.add(
      FakeReport(
        kind: target.kind,
        reason: reason,
        reporter: server.user(userId).email,
        reportedEmail: target.email,
        spaceId: target.spaceId,
        noteId: target.noteId,
        details: details,
        content: attach ? target.noteBody : null,
      ),
    );
  }
}

/// Both devices in these tests hold the same master key, which is what having
/// unlocked the same account means.
Vault sharedVault() =>
    Vault.fromMasterKey(Uint8List(Vault.keyLength)..fillRange(0, 32, 42));

/// A distinct master key per account, so two people's devices are plainly
/// not the same person.
Vault vaultFor(String userId) => Vault.fromMasterKey(
  Uint8List(Vault.keyLength)..fillRange(0, 32, 40 + userId.hashCode % 200),
);

/// A signed-in account, without a server to sign in to.
class FakeAuth implements AuthApi {
  FakeAuth({this.id = 'user-1', this.email = 'someone@example.com'});
  String id;
  String email;
  AuthResult? nextResult;
  bool sessionValid = true;
  int signOutCalls = 0;

  AccountUser get _user =>
      AccountUser(id: id, email: email, emailVerified: true);

  @override
  Future<AuthResult> signIn({
    required String email,
    required String password,
  }) async => nextResult ?? AuthSignedIn('token-$id', _user);

  /// The code a test types back. Real enough: it is compared, not guessed.
  String code = '123456';
  String? sentCodeTo;

  @override
  Future<AuthResult> sendCode(String email) async {
    sentCodeTo = email;
    return nextResult ?? AuthCodeSent(email);
  }

  @override
  Future<AuthResult> signInWithCode({
    required String email,
    required String code,
  }) async => code == this.code
      ? (nextResult ?? AuthSignedIn('token-$id', _user))
      : const AuthRejected('That code is not right.');

  /// The password the fake currently believes in, so a reset can be seen to
  /// have changed something.
  String password = 'original';

  @override
  Future<AuthResult> requestPasswordReset(String email) async {
    sentCodeTo = email;
    return nextResult ?? AuthCodeSent(email);
  }

  @override
  Future<AuthResult> resetPassword({
    required String email,
    required String code,
    required String password,
  }) async {
    if (code != this.code) return const AuthRejected('That code is not right.');
    this.password = password;
    return const AuthPasswordChanged();
  }

  @override
  Future<void> signOut(String token) async => signOutCalls++;

  @override
  Future<AccountUser?> currentUser(String token) async =>
      sessionValid ? _user : null;
}

/// Waits for something that nothing in the test asked for — a wake-up, a
/// reconnect — since there is no future to await for it. Fails rather than
/// hanging: a signal that never arrives is the bug these tests exist to
/// catch, and a timeout says so where a hang does not.
Future<void> until(bool Function() done, {String? reason}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(reason ?? 'the condition never became true');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
