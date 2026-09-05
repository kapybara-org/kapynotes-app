import 'package:flutter/foundation.dart';

import '../calc/engine.dart';
import '../data/note.dart';
import 'share_api.dart';
import 'share_link.dart';
import 'share_secrets.dart';
import 'vault.dart';

/// One note's sharing state, as the dialog needs to see it.
@immutable
class NoteShare {
  /// What the server knows. Null when the note has never been published.
  final ShareState? state;

  /// The link, when this device still holds the key that opens it.
  final Uri? link;

  const NoteShare({this.state, this.link});

  bool get isShared => state != null;

  /// Published, but by a device whose key this one does not have. The link
  /// still works for whoever holds it; it just cannot be shown here.
  bool get isOrphaned => state != null && link == null;

  ShareVisibility get visibility => state?.visibility ?? ShareVisibility.public;
}

/// Publishing, pausing and revoking note links.
///
/// Deliberately not part of `SyncService`. Sync is a background loop with a
/// cursor and a retry queue; this is a handful of one-shot actions a user is
/// watching a dialog for, and folding them together would mean either sharing
/// inherits a retry policy it does not want or sync inherits error surfaces it
/// does not need.
class ShareService extends ChangeNotifier {
  ShareService({
    required ShareApi api,
    required ShareSecrets secrets,
    required CalcEngine Function() engine,
    required Uri siteOrigin,
  }) : _api = api,
       _secrets = secrets,
       _engine = engine,
       _siteOrigin = siteOrigin;

  final ShareApi _api;
  final ShareSecrets _secrets;
  final CalcEngine Function() _engine;
  final Uri _siteOrigin;

  /// Server state by note id, as of the last [refresh].
  final Map<String, ShareState> _states = {};

  bool _loaded = false;
  bool get loaded => _loaded;

  /// Pulls the authoritative list. Cheap, and worth doing when the sidebar
  /// appears so a note published on another device shows as shared here.
  Future<void> refresh() async {
    final shares = await _api.list();
    _states
      ..clear()
      ..addEntries(shares.map((share) => MapEntry(share.noteId, share)));
    _loaded = true;
    notifyListeners();
  }

  NoteShare forNote(String noteId) {
    final state = _states[noteId];
    if (state == null) return const NoteShare();
    final secret = _secrets.forNote(noteId);
    return NoteShare(
      state: state,
      link: secret?.linkFor(_siteOrigin),
    );
  }

  /// Publishes [note], or republishes it under the link it already has.
  ///
  /// A fresh key every time this mints a *new* share. Re-using a key across
  /// two publications of different notes would let one link's holder read the
  /// other, and re-using it after a revoke would resurrect access somebody was
  /// deliberately cut off from.
  Future<NoteShare> publish(
    Note note, {
    ShareVisibility visibility = ShareVisibility.public,
    ShareExpiry expiry = ShareExpiry.forever,
  }) async {
    final existing = _secrets.forNote(note.id);
    final key = existing?.key ?? ShareSecret.newKey();

    final state = await _api.publish(
      noteId: note.id,
      sealed: await sealJsonUnderKey(_snapshot(note).toJson(), key),
      visibility: visibility,
      expiry: expiry,
    );

    _secrets.remember(note.id, ShareSecret(token: state.token, key: key));
    return _record(state);
  }

  /// Pushes the note's current text to an existing link.
  ///
  /// A share is a snapshot: publishing does not subscribe the link to every
  /// later keystroke, because that would mean re-sealing and re-uploading a
  /// note on every edit for as long as it stays shared. The dialog offers this
  /// instead, and says when the published copy is behind.
  Future<NoteShare> republish(Note note) async {
    final secret = _secrets.forNote(note.id);
    final state = _states[note.id];
    if (secret == null || state == null) return publish(note);

    return _record(
      await _api.update(
        secret.token,
        sealed: await sealJsonUnderKey(_snapshot(note).toJson(), secret.key),
      ),
    );
  }

  Future<NoteShare> setVisibility(String noteId, ShareVisibility value) async {
    final state = _states[noteId];
    if (state == null) return const NoteShare();
    return _record(await _api.update(state.token, visibility: value));
  }

  Future<NoteShare> setExpiry(String noteId, ShareExpiry value) async {
    final state = _states[noteId];
    if (state == null) return const NoteShare();
    return _record(await _api.update(state.token, expiry: value));
  }

  /// Takes the link down for good and forgets its key.
  Future<void> revoke(String noteId) async {
    final state = _states[noteId];
    if (state != null) await _api.revoke(state.token);
    _states.remove(noteId);
    _secrets.forget(noteId);
    notifyListeners();
  }

  /// Mints a new key for a note whose old one this device does not have.
  ///
  /// The only honest repair for that case: the old link cannot be recovered,
  /// so it is replaced rather than pretended about. Anyone holding the old URL
  /// stops being able to read it the moment this lands, which is the same
  /// guarantee revoking gives and is why the dialog says so plainly.
  Future<NoteShare> replaceLink(Note note) async {
    _secrets.forget(note.id);
    final current = _states[note.id];
    return publish(
      note,
      visibility: current?.visibility ?? ShareVisibility.public,
      expiry: ShareExpiry.forever,
    );
  }

  /// Builds the plaintext a visitor will read, results included.
  SharedNote _snapshot(Note note) {
    final evaluated = _engine().evaluateDocument(note.body);
    return SharedNote.of(
      note,
      results: [
        for (final entry in evaluated.entries)
          SharedResult(line: entry.key, text: entry.value.text),
      ]..sort((a, b) => a.line.compareTo(b.line)),
    );
  }

  NoteShare _record(ShareState state) {
    _states[state.noteId] = state;
    notifyListeners();
    return forNote(state.noteId);
  }
}
