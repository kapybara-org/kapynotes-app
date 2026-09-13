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

enum SpaceRole { owner, member, viewer }

extension SpaceRoleAccess on SpaceRole {
  bool get canEdit => this != SpaceRole.viewer;

  String get accessLabel => switch (this) {
    SpaceRole.owner => 'Owner',
    SpaceRole.member => 'Editor',
    SpaceRole.viewer => 'View only',
  };
}

SpaceRole _spaceRole(Object? raw) => switch (raw) {
  'owner' => SpaceRole.owner,
  'viewer' => SpaceRole.viewer,
  _ => SpaceRole.member,
};

class SpaceMember {
  final String userId;
  final String email;
  final String name;
  final String? image;
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
    this.name = '',
    this.image,
    required this.role,
    required this.joinedAt,
    required this.hasKey,
    this.x25519Public,
    this.ed25519Public,
  });

  bool get isOwner => role == SpaceRole.owner;
  bool get isViewer => role == SpaceRole.viewer;
  bool get canEdit => role.canEdit;

  String get displayName {
    final clean = name.trim();
    if (clean.isNotEmpty && clean.toLowerCase() != email.toLowerCase()) {
      return clean;
    }
    return _localPart(email);
  }

  /// What to call them in a sentence — "Priya is typing" — where a full name
  /// would crowd the line.
  String get firstName => _firstWord(displayName);

  /// Whether they have a name of their own, so the address need not stand in
  /// for one. The address stays reachable, for checking who somebody is.
  bool get hasName {
    final clean = name.trim();
    return clean.isNotEmpty && clean.toLowerCase() != email.toLowerCase();
  }

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
      name: raw['name'] is String ? raw['name'] as String : '',
      image: raw['image'] is String && (raw['image'] as String).isNotEmpty
          ? raw['image'] as String
          : null,
      role: _spaceRole(raw['role']),
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
  final SpaceRole role;
  final DateTime expiresAt;
  final DateTime createdAt;

  const SpaceInvite({
    required this.token,
    required this.email,
    this.role = SpaceRole.member,
    required this.expiresAt,
    required this.createdAt,
  });

  /// An invitation has an address and nothing else: until they accept there
  /// is no profile to take a name from.
  String get displayName => _localPart(email);

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
      role: _spaceRole(raw['role']),
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

  /// The inviter's verified address.
  final String invitedBy;

  /// The inviter's own name, where the server sent one. Servers before it
  /// did send only the address, which is then all there is to show.
  final String? invitedByName;
  final SpaceRole role;
  final DateTime expiresAt;

  const PendingInvite({
    required this.token,
    required this.spaceId,
    required this.spaceName,
    required this.invitedBy,
    this.invitedByName,
    this.role = SpaceRole.member,
    required this.expiresAt,
  });

  /// Who sent it, by name where they have one.
  String get inviterDisplayName => invitedByName ?? invitedBy;

  /// Whether the space still carries the placeholder it was made with.
  ///
  /// To the invitee that placeholder is "With" and a piece of their *own*
  /// address, so it tells them nothing and is better left unsaid. Judged by
  /// shape alone — one word after "With" — because an invitation carries no
  /// member list to check it against; a chosen name of that shape is merely
  /// not repeated back.
  bool get hasGeneratedSpaceName =>
      RegExp(r'^With \S+$').hasMatch(spaceName.trim());

  static PendingInvite? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final token = raw['token'];
    final spaceId = raw['spaceId'];
    final name = raw['spaceName'];
    final by = raw['invitedBy'];
    final byName = raw['invitedByName'];
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
      invitedByName:
          byName is String &&
              byName.trim().isNotEmpty &&
              byName.trim().toLowerCase() != by.toLowerCase()
          ? byName.trim()
          : null,
      role: _spaceRole(raw['role']),
      expiresAt: expires.toLocal(),
    );
  }
}

/// Somebody a space is shared with: a member, or an address with an
/// invitation still outstanding. Enough to name them and draw an avatar.
class SpacePerson {
  const SpacePerson._({
    required this.id,
    required this.name,
    required this.fullName,
    required this.seed,
    this.image,
    this.member,
    this.invite,
  });

  /// The member's account id, or the invited address.
  final String id;

  /// What to call them in a sentence. Unique among the people in the space.
  final String name;

  /// What to call them in a list.
  final String fullName;

  /// What a default avatar is drawn from.
  final String seed;
  final String? image;
  final SpaceMember? member;
  final SpaceInvite? invite;

  bool get isInvited => invite != null;
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
  final int? attachmentMaxBytes;
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
    this.attachmentMaxBytes,
    required this.createdAt,
  });

  bool get isPersonal => kind == SpaceKind.personal;
  bool get isTeam => kind == SpaceKind.team;
  bool get isOwner => role == SpaceRole.owner;
  bool get isViewer => role == SpaceRole.viewer;
  bool get canEdit => role.canEdit;
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

  /// Whether [name] is the placeholder this app gave the space when it made
  /// it — "With" and a piece of the first invitee's address — rather than a
  /// name somebody chose.
  ///
  /// The placeholder is part of an email address, and to the invitee it
  /// names themselves. Where it is one, the space goes by its people instead.
  bool get hasGeneratedName {
    final raw = name?.trim();
    if (raw == null || !raw.startsWith('With ')) return false;
    final rest = raw.substring(5).trim().toLowerCase();
    bool matches(String email) {
      final address = email.trim().toLowerCase();
      return rest == address || rest == address.split('@').first;
    }

    return members.any((m) => matches(m.email)) ||
        invites.any((i) => matches(i.email));
  }

  /// A name somebody chose for the space, or null for one that has none.
  String? get chosenName {
    final raw = name?.trim();
    if (!isTeam || raw == null || raw.isEmpty || hasGeneratedName) return null;
    return raw;
  }

  /// What to call [userId] in a sentence here: their first name, or their
  /// full one where somebody else in the space shares the first.
  String shortNameOf(String userId) {
    final member = this.member(userId);
    if (member == null) return 'Someone';
    final first = member.firstName.toLowerCase();
    final clash = members.any(
      (other) =>
          other.userId != userId && other.firstName.toLowerCase() == first,
    );
    return clash ? member.displayName : member.firstName;
  }

  /// Everyone but [userId], in the order a sentence names them: the owner,
  /// then members as they joined, then anyone whose invitation is waiting.
  List<SpacePerson> peopleExcept(String userId) {
    final others = othersThan(userId).toList()
      ..sort((a, b) {
        if (a.isOwner != b.isOwner) return a.isOwner ? -1 : 1;
        return a.joinedAt.compareTo(b.joinedAt);
      });
    final pending = invites.toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return [
      for (final member in others)
        SpacePerson._(
          id: member.userId,
          name: shortNameOf(member.userId),
          fullName: member.displayName,
          seed: member.userId.isEmpty ? member.email : member.userId,
          image: member.image,
          member: member,
        ),
      for (final invite in pending)
        SpacePerson._(
          id: invite.email,
          name: invite.displayName,
          fullName: invite.email,
          seed: invite.email,
          invite: invite,
        ),
    ];
  }

  /// "Priya", "Priya and Sam", "Priya and 4 others": who [userId] shares
  /// this space with, or null while that is nobody.
  String? peoplePhrase(String userId) {
    final people = peopleExcept(userId);
    return switch (people.length) {
      0 => null,
      1 => people[0].name,
      2 => '${people[0].name} and ${people[1].name}',
      _ => '${people[0].name} and ${people.length - 1} others',
    };
  }

  /// What to call the space in a heading: the name somebody gave it, or else
  /// the current account's relationship to it.
  String titleFor(String userId) {
    if (isPersonal) return displayName;
    final chosen = chosenName;
    if (chosen != null) return chosen;
    if (ownerId != userId) return 'Shared by ${shortNameOf(ownerId)}';
    final phrase = peoplePhrase(userId);
    return phrase == null ? 'Only you' : 'Shared with $phrase';
  }

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
          'name': m.name,
          'image': m.image,
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
          'role': i.role.name,
          'expiresAt': i.expiresAt.toUtc().toIso8601String(),
          'createdAt': i.createdAt.toUtc().toIso8601String(),
        },
    ],
    'liveNotes': liveNotes,
    'attachmentMaxBytes': attachmentMaxBytes,
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
      role: _spaceRole(raw['role']),
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
      attachmentMaxBytes: switch (raw['attachmentMaxBytes']) {
        final int value when value > 0 => value,
        _ => null,
      },
      createdAt: (created ?? DateTime.fromMillisecondsSinceEpoch(0)).toLocal(),
    );
  }
}

/// What `POST /spaces/:id/invites` answers with.
class InviteResult {
  final String token;
  final String email;
  final SpaceRole role;
  final DateTime expiresAt;

  /// Whether the server managed to email the link. It works either way; a
  /// failed send just means handing it over yourself.
  final bool emailed;

  const InviteResult({
    required this.token,
    required this.email,
    this.role = SpaceRole.member,
    required this.expiresAt,
    required this.emailed,
  });
}

String _localPart(String email) {
  final local = email.split('@').first.trim();
  return local.isEmpty ? email : local;
}

String _firstWord(String value) {
  final clean = value.trim();
  final gap = RegExp(r'\s').firstMatch(clean);
  return gap == null ? clean : clean.substring(0, gap.start);
}

Uint8List? _bytes(Object? raw) {
  if (raw is! String) return null;
  try {
    return base64.decode(raw);
  } on FormatException {
    return null;
  }
}
