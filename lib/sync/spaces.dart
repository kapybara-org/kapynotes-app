import 'dart:convert';
import 'dart:typed_data';

import 'key_wrap.dart';

/// Spaces, as the server describes them. Mirrors `Space` in the contract.
///
/// Every note lives in exactly one. A personal account is a team of one: its
/// personal space has an owner, a membership and a key like any other, so
/// nothing about sync or the key model treats it specially. A team space adds
/// members, and its notes' content keys are wrapped to a space key that is in
/// turn wrapped to each member's public key.
enum SpaceKind { personal, team }

enum SpaceRole { owner, member }

class SpaceMember {
  final String userId;
  final String email;
  final SpaceRole role;
  final DateTime joinedAt;

  /// False for someone who accepted but has not been granted the key yet.
  /// Any member holding it grants it the next time they sync.
  final bool hasKey;

  /// Null until they have uploaded identity keys; nothing can be wrapped to
  /// them until then.
  final Uint8List? x25519Public;
  final Uint8List? ed25519Public;

  const SpaceMember({
    required this.userId,
    required this.email,
    required this.role,
    required this.joinedAt,
    required this.hasKey,
    this.x25519Public,
    this.ed25519Public,
  });

  bool get isOwner => role == SpaceRole.owner;

  /// True when this member can be granted the key: they have a public key
  /// and do not hold the space key yet.
  bool get awaitsGrant => !hasKey && x25519Public != null;

  static SpaceMember? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final userId = raw['userId'];
    final email = raw['email'];
    final joinedAt = raw['joinedAt'];
    if (userId is! String || email is! String || joinedAt is! String) {
      return null;
    }
    final joined = DateTime.tryParse(joinedAt);
    if (joined == null) return null;
    return SpaceMember(
      userId: userId,
      email: email,
      role: raw['role'] == 'owner' ? SpaceRole.owner : SpaceRole.member,
      joinedAt: joined.toLocal(),
      hasKey: raw['hasKey'] == true,
      x25519Public: _bytes(raw['x25519Public']),
      ed25519Public: _bytes(raw['ed25519Public']),
    );
  }
}

class SpaceInvite {
  final String token;
  final String email;
  final DateTime expiresAt;
  final DateTime createdAt;

  const SpaceInvite({
    required this.token,
    required this.email,
    required this.expiresAt,
    required this.createdAt,
  });

  static SpaceInvite? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final token = raw['token'];
    final email = raw['email'];
    final expires = DateTime.tryParse(raw['expiresAt'] as String? ?? '');
    final created = DateTime.tryParse(raw['createdAt'] as String? ?? '');
    if (token is! String || email is! String || expires == null) return null;
    return SpaceInvite(
      token: token,
      email: email,
      expiresAt: expires.toLocal(),
      createdAt: (created ?? expires).toLocal(),
    );
  }
}

/// An invitation waiting for this account, from `GET /invites`.
class PendingInvite {
  final String token;
  final String spaceId;
  final String spaceName;
  final String invitedBy;
  final DateTime expiresAt;

  const PendingInvite({
    required this.token,
    required this.spaceId,
    required this.spaceName,
    required this.invitedBy,
    required this.expiresAt,
  });

  static PendingInvite? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final token = raw['token'];
    final spaceId = raw['spaceId'];
    final name = raw['spaceName'];
    final by = raw['invitedBy'];
    final expires = DateTime.tryParse(raw['expiresAt'] as String? ?? '');
    if (token is! String ||
        spaceId is! String ||
        name is! String ||
        by is! String ||
        expires == null) {
      return null;
    }
    return PendingInvite(
      token: token,
      spaceId: spaceId,
      spaceName: name,
      invitedBy: by,
      expiresAt: expires.toLocal(),
    );
  }
}

class Space {
  final String id;
  final SpaceKind kind;

  /// Null for the personal space.
  final String? name;
  final String ownerId;

  /// This account's role in it.
  final SpaceRole role;

  /// Bumped on every space-key rotation. Every note key written must carry
  /// it, and a client holding an older one is refused until it refreshes.
  final int keyGeneration;

  /// Set by a removal; cleared by the rotation that answers it. Any member
  /// holding the key performs the rotation when they see this.
  final bool rotationPending;

  /// This account's wrapped copy of the space key, or null while waiting for
  /// somebody who holds it to grant one.
  final SealedToPublicKey? spaceKey;
  final List<SpaceMember> members;
  final List<SpaceInvite> invites;
  final int liveNotes;
  final DateTime createdAt;

  const Space({
    required this.id,
    required this.kind,
    required this.name,
    required this.ownerId,
    required this.role,
    required this.keyGeneration,
    required this.rotationPending,
    required this.spaceKey,
    required this.members,
    required this.invites,
    required this.liveNotes,
    required this.createdAt,
  });

  bool get isPersonal => kind == SpaceKind.personal;
  bool get isTeam => kind == SpaceKind.team;
  bool get isOwner => role == SpaceRole.owner;
  bool get hasKey => spaceKey != null;

  /// What to call it in a list. The personal space has no name of its own.
  String get displayName => name ?? 'My notes';

  SpaceMember? member(String userId) {
    for (final member in members) {
      if (member.userId == userId) return member;
    }
    return null;
  }

  /// Members other than [userId] — what "who is this shared with" means.
  List<SpaceMember> othersThan(String userId) =>
      members.where((m) => m.userId != userId).toList(growable: false);

  /// A team space whose only member is its owner, with no unexpired invite
  /// and live notes still in it, is owed a trip home: only the owner's client
  /// can re-seal the notes, so it does so on its next sync.
  bool get owedTripHome =>
      isTeam && members.length == 1 && invites.isEmpty && liveNotes > 0;

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'name': name,
    'ownerId': ownerId,
    'role': role.name,
    'keyGeneration': keyGeneration,
    'rotationPending': rotationPending,
    'spaceKey': spaceKey?.toJson(),
    'members': [
      for (final m in members)
        {
          'userId': m.userId,
          'email': m.email,
          'role': m.role.name,
          'joinedAt': m.joinedAt.toUtc().toIso8601String(),
          'hasKey': m.hasKey,
          'x25519Public': m.x25519Public == null
              ? null
              : base64.encode(m.x25519Public!),
          'ed25519Public': m.ed25519Public == null
              ? null
              : base64.encode(m.ed25519Public!),
        },
    ],
    'invites': [
      for (final i in invites)
        {
          'token': i.token,
          'email': i.email,
          'expiresAt': i.expiresAt.toUtc().toIso8601String(),
          'createdAt': i.createdAt.toUtc().toIso8601String(),
        },
    ],
    'liveNotes': liveNotes,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };

  static Space? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final ownerId = raw['ownerId'];
    final generation = raw['keyGeneration'];
    final created = DateTime.tryParse(raw['createdAt'] as String? ?? '');
    if (id is! String || ownerId is! String || generation is! int) return null;
    final members = raw['members'];
    final invites = raw['invites'];
    final liveNotes = raw['liveNotes'];
    return Space(
      id: id,
      kind: raw['kind'] == 'team' ? SpaceKind.team : SpaceKind.personal,
      name: raw['name'] is String ? raw['name'] as String : null,
      ownerId: ownerId,
      role: raw['role'] == 'owner' ? SpaceRole.owner : SpaceRole.member,
      keyGeneration: generation,
      rotationPending: raw['rotationPending'] == true,
      spaceKey: SealedToPublicKey.fromJson(raw['spaceKey']),
      members: members is List
          ? members.map(SpaceMember.fromJson).whereType<SpaceMember>().toList()
          : const [],
      invites: invites is List
          ? invites.map(SpaceInvite.fromJson).whereType<SpaceInvite>().toList()
          : const [],
      liveNotes: liveNotes is int ? liveNotes : 0,
      createdAt: (created ?? DateTime.fromMillisecondsSinceEpoch(0)).toLocal(),
    );
  }
}

/// What `POST /spaces/:id/invites` answers with.
class InviteResult {
  final String token;
  final String email;
  final DateTime expiresAt;

  /// Whether the server managed to email the link. It works either way; a
  /// failed send just means handing it over yourself.
  final bool emailed;

  const InviteResult({
    required this.token,
    required this.email,
    required this.expiresAt,
    required this.emailed,
  });
}

Uint8List? _bytes(Object? raw) {
  if (raw is! String) return null;
  try {
    return base64.decode(raw);
  } on FormatException {
    return null;
  }
}
