import '../data/local_store.dart';
import 'share_link.dart';

/// Where the key half of every share link is kept.
///
/// The server issues the token and stores the ciphertext; it never sees the
/// key, so it cannot hand one back. If this device loses its copy the link
/// still resolves — the row is there, the ciphertext is there — but nobody can
/// read it and nobody can reconstruct the URL. So the keys are persisted like
/// preferences: written immediately rather than coalesced, because the moment
/// after somebody shares a note is exactly when they might quit.
///
/// Scope worth knowing: these live on the device that published, not in the
/// account. Share a note on the Mac and the phone will see that the note *is*
/// shared — the server lists it — but cannot rebuild that link, and offers to
/// replace it instead. Moving the key inside the note's own sealed payload
/// (where attachment file keys already ride, for the same reason) would close
/// that gap and is the natural next step; it was left out of the first cut
/// because it means changing the sync envelope.
class ShareSecrets {
  ShareSecrets(this._store);

  final LocalStore _store;

  static const String _key = 'shares.v1';

  final Map<String, ShareSecret> _secrets = {};

  /// Reads what this device has published before. Safe to call more than once.
  void load() {
    final raw = _store.read<Map<String, Object?>>(_key);
    if (raw == null) return;
    _secrets.clear();
    for (final entry in raw.entries) {
      final secret = ShareSecret.fromJson(entry.value);
      if (secret != null) _secrets[entry.key] = secret;
    }
  }

  /// The link secret for a note, or null if this device did not publish it.
  ShareSecret? forNote(String noteId) => _secrets[noteId];

  /// True when this device can rebuild the link for [noteId].
  bool canRebuild(String noteId) => _secrets.containsKey(noteId);

  void remember(String noteId, ShareSecret secret) {
    _secrets[noteId] = secret;
    _persist();
  }

  void forget(String noteId) {
    if (_secrets.remove(noteId) != null) _persist();
  }

  /// Drops every key. For sign-out: the links stay live server-side until they
  /// are revoked, but this device stops holding the means to read them.
  void clear() {
    if (_secrets.isEmpty) return;
    _secrets.clear();
    _persist();
  }

  void _persist() => _store.putNow(_key, {
    for (final entry in _secrets.entries) entry.key: entry.value.toJson(),
  });
}
