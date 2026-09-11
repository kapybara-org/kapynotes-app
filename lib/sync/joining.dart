import 'package:flutter/foundation.dart';

import 'config.dart';
import 'spaces.dart' show SpaceRole;
import 'sync_api.dart' show SyncRefusedException;

/// Two easier ways into a shared space than one email address at a time.
///
/// Both keep the rule sharing rests on: the server never holds a space key,
/// so somebody who holds it hands it over. An email invitation names one
/// person, which is why the handover after it can be automatic. A space's
/// link names nobody — it is meant for a family group chat — so it only lets
/// people *ask*, and the owner letting them in is the moment the key moves.
/// A link that escapes produces requests, never access.

/// The one door these calls go through: the same session, device and
/// protocol headers every sync call carries. A function rather than
/// [SyncApi] itself so that nothing implementing [SyncApi] has to learn
/// about joining.
typedef ApiSend =
    Future<Map<String, Object?>> Function(
      String method,
      String path, {
      Map<String, Object?>? payload,
    });

SpaceRole _role(Object? raw) =>
    raw == 'viewer' ? SpaceRole.viewer : SpaceRole.member;

String _roleWire(SpaceRole role) =>
    role == SpaceRole.viewer ? 'viewer' : 'member';

DateTime? _time(Object? raw) =>
    raw is String ? DateTime.tryParse(raw)?.toLocal() : null;

// ---------------------------------------------------------------------------
// Several invitations at once
// ---------------------------------------------------------------------------

/// The most addresses one batch may carry: the server's
/// `BATCH_INVITE_MAX`, which is as many as may be pending in a space at once.
const int kBatchInviteMax = 20;

/// What happened to one address. There is no "blocked": an address that has
/// blocked the sender is invited like any other and simply never emailed,
/// because telling the sender would disclose the block.
enum BatchInviteOutcome { invited, renewed, alreadyMember, invalid }

class BatchInviteResult {
  final String email;
  final BatchInviteOutcome outcome;

  /// Whether the invitation email went out. Only meaningful for [invited]
  /// and [renewed]; a failed send leaves a working link to pass on by hand.
  final bool emailed;

  /// The invitation's token, for revoking it from the list.
  final String? token;

  const BatchInviteResult({
    required this.email,
    required this.outcome,
    this.emailed = false,
    this.token,
  });

  bool get sent =>
      outcome == BatchInviteOutcome.invited ||
      outcome == BatchInviteOutcome.renewed;

  static BatchInviteResult? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final email = raw['email'];
    final outcome = switch (raw['outcome']) {
      'invited' => BatchInviteOutcome.invited,
      'renewed' => BatchInviteOutcome.renewed,
      'already-member' => BatchInviteOutcome.alreadyMember,
      'invalid' => BatchInviteOutcome.invalid,
      _ => null,
    };
    if (email is! String || outcome == null) return null;
    final invite = raw['invite'];
    return BatchInviteResult(
      email: email,
      outcome: outcome,
      emailed: invite is Map && invite['emailed'] == true,
      token: invite is Map && invite['token'] is String
          ? invite['token'] as String
          : null,
    );
  }
}

/// A batch the server refused whole, because it would have passed a limit.
/// Nothing was sent; [room] is how many would have fitted.
class InviteLimitException implements Exception {
  const InviteLimitException(this.reason, this.room);

  final InviteLimitReason reason;
  final int room;

  @override
  String toString() => 'InviteLimitException($reason, room: $room)';
}

enum InviteLimitReason { pending, full, today }

/// Splits what somebody typed or pasted into addresses. Commas, semicolons,
/// spaces and new lines all separate; `Name <a@b.c>` is read as its address,
/// which is what a list copied out of a mail client looks like.
List<String> splitAddresses(String typed) {
  // A display name before an angled address is the name, not an address:
  // `Priya Shah <priya@x.com>` is one address. Collapsed first, because
  // splitting on spaces before this turns every name into two addresses.
  // A stray word with no angled address after it survives as itself, so a
  // forgotten domain comes back from the server as invalid, not silently gone.
  final named = typed.replaceAllMapped(
    RegExp(r'[^,;<>\n]*<([^<>]+)>'),
    (m) => ' ${m.group(1)} ',
  );
  final found = <String>[];
  final seen = <String>{};
  for (final part in named.split(RegExp(r'[,;\s]+'))) {
    final address = part.trim().replaceAll(RegExp(r'^[<("]+|[>)"]+$'), '');
    if (address.isEmpty) continue;
    if (seen.add(address.toLowerCase())) found.add(address);
  }
  return found;
}

// ---------------------------------------------------------------------------
// A space's link
// ---------------------------------------------------------------------------

class JoinLink {
  final String token;
  final Uri url;

  /// What people let in through it can do.
  final SpaceRole role;
  final DateTime expiresAt;

  const JoinLink({
    required this.token,
    required this.url,
    required this.role,
    required this.expiresAt,
  });

  static JoinLink? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final token = raw['token'];
    final url = raw['url'];
    final expires = _time(raw['expiresAt']);
    if (token is! String || url is! String || expires == null) return null;
    final parsed = Uri.tryParse(url);
    if (parsed == null) return null;
    return JoinLink(
      token: token,
      url: parsed,
      role: _role(raw['role']),
      expiresAt: expires,
    );
  }
}

/// Somebody waiting to be let in, as the owner sees them.
class JoinRequest {
  final String userId;

  /// Verified, so accountable: it is what the owner decides on.
  final String email;

  /// Self-chosen, so shown beside the address, never instead of it.
  final String? name;
  final SpaceRole role;
  final DateTime requestedAt;

  const JoinRequest({
    required this.userId,
    required this.email,
    this.name,
    required this.role,
    required this.requestedAt,
  });

  static JoinRequest? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final userId = raw['userId'];
    final email = raw['email'];
    final at = _time(raw['requestedAt']);
    if (userId is! String || email is! String || at == null) return null;
    final name = raw['name'];
    return JoinRequest(
      userId: userId,
      email: email,
      name: name is String && name.trim().isNotEmpty ? name.trim() : null,
      role: _role(raw['role']),
      requestedAt: at,
    );
  }
}

/// Where the person holding a link stands.
///
/// [invited] means an email invitation to this very space is waiting for
/// them: accepting it needs nobody's approval, so it is offered instead.
enum JoinStatus { none, pending, declined, member, invited }

class JoinLinkPreview {
  final String spaceId;
  final String spaceName;
  final String ownerEmail;
  final String? ownerName;
  final SpaceRole role;
  final JoinStatus status;
  final String? inviteToken;

  const JoinLinkPreview({
    required this.spaceId,
    required this.spaceName,
    required this.ownerEmail,
    this.ownerName,
    required this.role,
    required this.status,
    this.inviteToken,
  });

  /// The owner as a person would say it: their name where they chose one,
  /// with the address that makes it accountable.
  String get ownerLabel =>
      ownerName == null ? ownerEmail : '$ownerName ($ownerEmail)';

  /// Just the name, or the address where there is none — for sentences.
  String get ownerShort => ownerName ?? ownerEmail;

  JoinLinkPreview withStatus(JoinStatus next) => JoinLinkPreview(
    spaceId: spaceId,
    spaceName: spaceName,
    ownerEmail: ownerEmail,
    ownerName: ownerName,
    role: role,
    status: next,
    inviteToken: inviteToken,
  );

  static JoinLinkPreview? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final spaceId = raw['spaceId'];
    final name = raw['spaceName'];
    final owner = raw['ownerEmail'];
    final status = switch (raw['status']) {
      'none' => JoinStatus.none,
      'pending' => JoinStatus.pending,
      'declined' => JoinStatus.declined,
      'member' => JoinStatus.member,
      'invited' => JoinStatus.invited,
      _ => null,
    };
    if (spaceId is! String ||
        name is! String ||
        owner is! String ||
        status == null) {
      return null;
    }
    final ownerName = raw['ownerName'];
    final invite = raw['inviteToken'];
    return JoinLinkPreview(
      spaceId: spaceId,
      spaceName: name,
      ownerEmail: owner,
      ownerName: ownerName is String && ownerName.trim().isNotEmpty
          ? ownerName.trim()
          : null,
      role: _role(raw['role']),
      status: status,
      inviteToken: invite is String ? invite : null,
    );
  }
}

// ---------------------------------------------------------------------------
// What a pasted or opened link is
// ---------------------------------------------------------------------------

/// Where an opened link wants to take somebody.
sealed class JoinTarget {
  const JoinTarget(this.token);
  final String token;
}

/// `/join/<token>`: an email invitation.
class InviteTarget extends JoinTarget {
  const InviteTarget(super.token);

  @override
  bool operator ==(Object other) =>
      other is InviteTarget && other.token == token;
  @override
  int get hashCode => Object.hash('invite', token);
}

/// `/space/<token>`: a space's link, which lets somebody ask to join.
class SpaceLinkTarget extends JoinTarget {
  const SpaceLinkTarget(super.token);

  @override
  bool operator ==(Object other) =>
      other is SpaceLinkTarget && other.token == token;
  @override
  int get hashCode => Object.hash('space', token);
}

/// The alphabet tokens are minted from, at the lengths they come in. Checked
/// before a token goes anywhere, so a link can carry nothing but a token.
final RegExp _token = RegExp(r'^[A-Za-z0-9_-]{16,64}$');

/// The hosts a pasted https link may name. The configured site first, so a
/// staging build reads its own links; kapynotes.com always, because that is
/// what every email and every shared link says.
Set<String> _siteHosts() {
  final configured = Uri.tryParse(kSiteBaseUrl)?.host;
  return {
    'kapynotes.com',
    'www.kapynotes.com',
    if (configured != null && configured.isNotEmpty) configured,
  };
}

/// Reads anything that might be a way into a space.
///
/// `https://kapynotes.com/join/<token>`, `…/space/<token>`, the app's own
/// `kapynotes://join/<token>` and `kapynotes://space/<token>`, and — because
/// the paste box has always taken it — a bare invitation token. Anything
/// else, including a link to another host, is null.
JoinTarget? parseJoinTarget(String input) {
  final text = input.trim();
  if (text.isEmpty) return null;
  if (_token.hasMatch(text)) return InviteTarget(text);

  final uri = Uri.tryParse(text);
  if (uri == null) return null;

  final List<String> segments;
  if (uri.scheme == 'kapynotes') {
    // `kapynotes://space/abc` parses with `space` as the host.
    segments = [
      uri.host,
      ...uri.pathSegments,
    ].where((s) => s.isNotEmpty).toList();
  } else if ((uri.scheme == 'https' || uri.scheme == 'http') &&
      _siteHosts().contains(uri.host.toLowerCase())) {
    segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  } else {
    return null;
  }

  if (segments.length != 2 || !_token.hasMatch(segments[1])) return null;
  return switch (segments[0]) {
    'join' => InviteTarget(segments[1]),
    'space' => SpaceLinkTarget(segments[1]),
    _ => null,
  };
}

// ---------------------------------------------------------------------------
// The service
// ---------------------------------------------------------------------------

/// Everything the UI does with batches, links and requests.
///
/// Holds, per space the account owns, its link and who is waiting, so a
/// sheet reopened shows what it showed. The server remains the only
/// authority: every action goes there first, and this only mirrors what came
/// back.
class Joining extends ChangeNotifier {
  Joining({
    required ApiSend send,
    required Future<void> Function() refreshSpaces,
    required void Function() requestSync,
  }) : _send = send,
       _refreshSpaces = refreshSpaces,
       _requestSync = requestSync;

  final ApiSend _send;
  final Future<void> Function() _refreshSpaces;
  final void Function() _requestSync;

  final Map<String, JoinLink?> _links = {};
  final Map<String, List<JoinRequest>> _requests = {};
  bool _disposed = false;

  /// The space's live link, or null. Null too until [loadLink] has asked.
  JoinLink? linkOf(String spaceId) => _links[spaceId];

  /// Whether the link has been asked about yet, as opposed to being absent.
  bool knowsLinkOf(String spaceId) => _links.containsKey(spaceId);

  List<JoinRequest> requestsOf(String spaceId) =>
      _requests[spaceId] ?? const [];

  /// Everyone waiting, across every space this device has asked about.
  int get waitingCount =>
      _requests.values.fold(0, (total, list) => total + list.length);

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  // --- several at once ---------------------------------------------------

  /// Invites everyone in [emails] to [spaceId] in one go.
  ///
  /// Throws [InviteLimitException] when the batch as a whole would pass a
  /// limit — nothing is sent in that case, so the owner is never left
  /// wondering which half went.
  Future<List<BatchInviteResult>> inviteMany(
    String spaceId,
    List<String> emails, {
    SpaceRole role = SpaceRole.member,
  }) async {
    final Map<String, Object?> body;
    try {
      body = await _send(
        'POST',
        'spaces/$spaceId/invites/batch',
        payload: {'emails': emails, 'role': _roleWire(role)},
      );
    } on SyncRefusedException catch (error) {
      final room = error.body['room'];
      final reason = switch (error.code) {
        'too many pending invitations' => InviteLimitReason.pending,
        'the space is full' => InviteLimitReason.full,
        'too many invitations today' => InviteLimitReason.today,
        _ => null,
      };
      if (error.status == 409 && reason != null && room is int) {
        throw InviteLimitException(reason, room);
      }
      rethrow;
    }
    final raw = body['results'];
    final results = [
      if (raw is List)
        for (final r in raw) ?BatchInviteResult.fromJson(r),
    ];
    if (results.any((r) => r.sent)) await _refreshSpaces();
    return results;
  }

  // --- the owner's link --------------------------------------------------

  Future<JoinLink?> loadLink(String spaceId) async {
    final body = await _send('GET', 'spaces/$spaceId/link');
    final link = JoinLink.fromJson(body['link']);
    _links[spaceId] = link;
    _changed();
    return link;
  }

  /// Makes the link, or replaces it: always a new token, so the old one —
  /// wherever it went — stops working.
  Future<JoinLink> makeLink(
    String spaceId, {
    SpaceRole role = SpaceRole.member,
  }) async {
    final body = await _send(
      'PUT',
      'spaces/$spaceId/link',
      payload: {'role': _roleWire(role)},
    );
    final link = JoinLink.fromJson(body);
    if (link == null) {
      throw StateError('the server answered a new link with nothing usable');
    }
    _links[spaceId] = link;
    _changed();
    return link;
  }

  Future<void> turnOffLink(String spaceId) async {
    await _send('DELETE', 'spaces/$spaceId/link');
    _links[spaceId] = null;
    _changed();
  }

  // --- who is waiting ------------------------------------------------------

  Future<List<JoinRequest>> loadRequests(String spaceId) async {
    final body = await _send('GET', 'spaces/$spaceId/requests');
    final raw = body['requests'];
    final list = [
      if (raw is List)
        for (final r in raw) ?JoinRequest.fromJson(r),
    ];
    _requests[spaceId] = list;
    _changed();
    return list;
  }

  /// Lets people in. This is when the key moves: the memberships are written
  /// server-side, and the sync asked for here is the pass that grants them
  /// the space key — the same pass that follows accepting an invitation.
  Future<List<String>> approve(String spaceId, List<String> userIds) async {
    if (userIds.isEmpty) return const [];
    final body = await _send(
      'POST',
      'spaces/$spaceId/requests/approve',
      payload: {'userIds': userIds},
    );
    final raw = body['approved'];
    final approved = [
      if (raw is List)
        for (final id in raw)
          if (id is String) id,
    ];
    final left = approved.toSet();
    _requests[spaceId] = [
      for (final r in requestsOf(spaceId))
        if (!left.contains(r.userId)) r,
    ];
    _changed();
    if (approved.isNotEmpty) {
      await _refreshSpaces();
      _requestSync();
    }
    return approved;
  }

  Future<void> decline(String spaceId, String userId) async {
    await _send('DELETE', 'spaces/$spaceId/requests/$userId');
    _requests[spaceId] = [
      for (final r in requestsOf(spaceId))
        if (r.userId != userId) r,
    ];
    _changed();
  }

  // --- the person holding a link ------------------------------------------

  /// What a link is and where this account stands with it. Asks nothing.
  Future<JoinLinkPreview> preview(String token) async {
    final preview = JoinLinkPreview.fromJson(
      await _send('GET', 'links/$token'),
    );
    if (preview == null) {
      throw StateError('the server described this link with nothing usable');
    }
    return preview;
  }

  /// Asks to be let in. Asking twice is still one request; a member, or
  /// somebody already invited by email, is just told where they stand.
  Future<JoinLinkPreview> ask(String token) async {
    final preview = JoinLinkPreview.fromJson(
      await _send('POST', 'links/$token/request'),
    );
    if (preview == null) {
      throw StateError('the server answered the request with nothing usable');
    }
    return preview;
  }
}
