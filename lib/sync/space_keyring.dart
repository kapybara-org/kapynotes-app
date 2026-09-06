import 'package:flutter/foundation.dart';

import '../data/local_store.dart';
import 'identity.dart';
import 'key_wrap.dart';
import 'spaces.dart';
import 'sync_api.dart';
import 'trust.dart';
import 'vault.dart';

/// What this device knows about the spaces it is in, and the keys to them.
///
/// The server's list of spaces, refreshed at the start of every sync pass and
/// on every wake-up that says the list changed; this account's identity
/// keypairs, generated on first unlock and unwrapped on every one after; and
/// the space keys those identity keys open, held in memory only. The list is
/// cached to disk so the sidebar can name a shared space while offline; the
/// keys never are, because the master key in the platform keystore already
/// opens everything they open.
class SpaceKeyring extends ChangeNotifier {
  SpaceKeyring({
    required String userId,
    required LocalStore store,
    required TrustStore trust,
  }) : _userId = userId,
       _store = store,
       _trust = trust {
    _loadCached();
  }

  final String _userId;
  final LocalStore _store;
  final TrustStore _trust;

  static const String _cacheKey = 'spaces.v1';

  List<Space> _spaces = const [];
  List<PendingInvite> _invites = const [];
  final Map<String, Uint8List> _keys = {};
  IdentityKeys? _identity;

  String get userId => _userId;
  List<Space> get spaces => _spaces;
  List<PendingInvite> get invites => _invites;
  IdentityKeys? get identity => _identity;
  TrustStore get trust => _trust;

  /// True once a sync has talked to the server about spaces.
  bool get isFresh => _fresh;
  bool _fresh = false;

  Space? get personal {
    for (final space in _spaces) {
      if (space.isPersonal) return space;
    }
    return null;
  }

  List<Space> get teams => _spaces.where((s) => s.isTeam).toList();

  Space? byId(String? id) {
    if (id == null) return personal;
    for (final space in _spaces) {
      if (space.id == id) return space;
    }
    return null;
  }

  /// The unwrapped space key, or null while this device is waiting on a grant
  /// or has not unlocked yet.
  Uint8List? keyFor(String spaceId) => _keys[spaceId];

  bool holdsKey(String spaceId) => _keys.containsKey(spaceId);

  /// Remembers a key this device minted itself, before the server has echoed
  /// it back — the moment between creating a space and the next refresh.
  void remember(String spaceId, Uint8List key) {
    _keys[spaceId] = key;
  }

  /// Makes sure this account has identity keys, generating and publishing
  /// them if it does not, and unwraps them into memory.
  ///
  /// The moment to generate keys is the moment the master key is in memory,
  /// which is now. A device that finds keys it cannot unwrap — sealed under a
  /// master key other than this one — reports that rather than overwriting
  /// them: replacing a published public key is precisely what every other
  /// member is watching for.
  Future<IdentityKeys> ensureIdentity(SyncApi api, Vault vault) async {
    final existing = _identity;
    if (existing != null) return existing;

    final bundle = await api.fetchKeyBundle();
    final master = vault.masterKeyForKeystore;
    final wire = bundle?.identity;
    if (wire != null) {
      final unwrapped = await IdentityKeys.unwrap(wire, master);
      if (unwrapped == null) {
        throw const SyncProtocolException(
          'the identity keys on the server are sealed under a different key',
        );
      }
      _identity = unwrapped;
      return unwrapped;
    }

    final generated = await IdentityKeys.generate();
    try {
      await api.publishIdentity(await generated.wrapUnder(master));
    } on SyncRefusedException catch (error) {
      // Another device of this account got there first. Use theirs.
      if (error.status != 409) rethrow;
      final theirs = (await api.fetchKeyBundle())?.identity;
      final unwrapped = theirs == null
          ? null
          : await IdentityKeys.unwrap(theirs, master);
      if (unwrapped == null) {
        throw const SyncProtocolException('could not read the identity keys');
      }
      _identity = unwrapped;
      return unwrapped;
    }
    _identity = generated;
    return generated;
  }

  /// Fetches the list of spaces and this account's invitations, unwraps every
  /// space key this device has been granted, and pins members' keys.
  Future<void> refresh(SyncApi api, Vault vault) async {
    final identity = await ensureIdentity(api, vault);
    final spaces = await api.fetchSpaces();
    final invites = await api.fetchInvites();

    for (final space in spaces) {
      final wrapped = space.spaceKey;
      if (wrapped == null) {
        // A grant that was revoked — removal, or a rotation this device was
        // not part of — must not leave the old key usable for new writes.
        if (space.isTeam) _keys.remove(space.id);
        continue;
      }
      final key = await openSealedToPublicKey(
        wrapped,
        identity.x25519Private,
        identity.x25519Public,
      );
      if (key != null) {
        _keys[space.id] = key;
      } else {
        _keys.remove(space.id);
        debugPrint('KapyNotes: could not open the key for space ${space.id}');
      }
    }
    final live = {for (final space in spaces) space.id};
    _keys.removeWhere((id, _) => !live.contains(id));

    _spaces = List.unmodifiable(spaces);
    _invites = List.unmodifiable(invites);
    _fresh = true;
    _trust.observe(spaces);
    _store.put(_cacheKey, {
      'spaces': [for (final space in spaces) space.toJson()],
    });
    notifyListeners();
  }

  /// Signing out: nothing about spaces or keys outlives the session.
  void clear() {
    _spaces = const [];
    _invites = const [];
    _keys.clear();
    _identity = null;
    _fresh = false;
    _store.put(_cacheKey, null);
    notifyListeners();
  }

  void _loadCached() {
    final cached = _store.read<Map<String, Object?>>(_cacheKey);
    final spaces = cached?['spaces'];
    if (spaces is! List) return;
    // Names and membership only. Wrapped keys in the cache are useless
    // without the identity keys, which arrive with the next refresh.
    _spaces = List.unmodifiable(
      spaces.map(Space.fromJson).whereType<Space>(),
    );
  }
}
