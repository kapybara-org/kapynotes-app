import 'package:flutter/foundation.dart';

import '../data/note.dart';
import '../data/note_attachment.dart';
import '../data/notes_store.dart';
import '../data/blob_store.dart';
import 'aead.dart';
import 'sealed_box.dart';
import 'sync_api.dart';

/// Moves image bytes between this device and object storage.
///
/// Deliberately separate from note sync, because the two have almost nothing
/// in common. A note is small, ordered, and must arrive as a set; an image is
/// large, unordered, immutable once written, and can arrive whenever. Pinning
/// a 20 MB upload to the same round trip as a keystroke would make both worse.
///
/// Nothing here is on the critical path of anything the user is looking at. An
/// image that has not uploaded is still in the note, still on disk, and still
/// exported; it is simply not yet on the other device.
class ImageSync {
  ImageSync({
    required SyncApi api,
    required BlobStore store,
    required NotesStore notes,
    this.downloadRetryDelays = const [
      Duration(milliseconds: 300),
      Duration(milliseconds: 1200),
      Duration(seconds: 3),
    ],
  }) : _api = api,
       _store = store,
       _notes = notes;

  final SyncApi _api;
  final BlobStore _store;
  final NotesStore _notes;
  final List<Duration> downloadRetryDelays;

  /// Hashes currently being fetched, so ten images in one note that all point
  /// at the same picture cost one download rather than ten.
  final Map<String, Future<Uint8List?>> _inFlight = {};

  /// Uploads whatever [note] holds that the server does not.
  ///
  /// Returns the note with server ids filled in, or the same note when there
  /// was nothing to do. A failure is not an error: the ref keeps its null id,
  /// so the next pass tries again.
  Future<Note> upload(Note note) async {
    if (note.attachments.every((ref) => ref.isUploaded)) return note;

    var changed = false;
    final updated = <NoteAttachmentRef>[];
    for (final ref in note.attachments) {
      if (ref.isUploaded) {
        updated.add(ref);
        continue;
      }
      final uploaded = await _uploadOne(note, ref);
      updated.add(uploaded ?? ref);
      if (uploaded != null) changed = true;
    }
    if (!changed) return note;

    // An id is not an edit: the note's text is untouched, so `updatedAt` must
    // not move and the note must not be dragged to the top of the list.
    return note.copyWith(attachments: updated, updatedAt: note.updatedAt);
  }

  Future<NoteAttachmentRef?> _uploadOne(
    Note note,
    NoteAttachmentRef ref,
  ) async {
    var current = ref;
    try {
      var id = current.attachmentId;
      if (id == null) {
        id = await _put(note, current.hash, current.key);
        if (id == null) return null;
        current = current.copyWith(attachmentId: id);
      }

      // Only a picture has a second object to upload. Every other kind is one
      // blob, and uploads by the same path.
      if (current is NoteImageRef) {
        var thumbId = current.thumbId;
        if (current.thumbHash != null && thumbId == null) {
          thumbId = await _put(note, current.thumbHash!, current.key);
          if (thumbId == null) return current;
        }
        return current.copyWith(attachmentId: id, thumbId: thumbId);
      }
      return current;
    } catch (error) {
      // Quota refusals land here too, and are the ordinary reason an upload
      // does not happen. Preserve whichever object already completed so a
      // thumbnail interruption never retransmits and bills the full image.
      debugPrint('KapyNotes: could not upload image ${current.hash}: $error');
      return current.attachmentId == null ? null : current;
    }
  }

  /// Seals one blob under its file key and stores it. Null when the bytes are
  /// not on this device, which happens on a device that pulled the note but
  /// never had the picture.
  Future<String?> _put(Note note, String hash, Uint8List key) async {
    final plaintext = await _store.read(hash);
    if (plaintext == null) return null;

    final sealed = await sealBytes(plaintext, key);
    final body = sealed.toBytes();
    final slot = await _api.createAttachment(
      noteId: note.id,
      spaceId: note.spaceId,
      bytes: body.length,
    );
    await _api.putBlob(slot.uploadUrl, body);
    await _api.completeAttachment(slot.id);
    return slot.id;
  }

  /// Fetches the bytes behind [hash], decrypts them, and caches them on disk.
  ///
  /// The hash is looked up across every local note, because an image is
  /// identified by its content and the note that happens to hold it is not
  /// interesting here — the same picture in two notes is one download.
  Future<Uint8List?> fetch(String hash) {
    final existing = _inFlight[hash];
    if (existing != null) return existing;
    // Braces matter here. An expression body would *return*
    // `_inFlight.remove(hash)`, which is this very future — and `whenComplete`
    // waits on a future its callback returns, so the future would wait for
    // itself and the picture would never arrive.
    final started = _fetch(hash).whenComplete(() {
      _inFlight.remove(hash);
    });
    _inFlight[hash] = started;
    return started;
  }

  Future<Uint8List?> _fetch(String hash) async {
    final located = _locate(hash);
    if (located == null) return null;

    try {
      final sealed = await _download(located.id);
      if (sealed == null) return null;

      final box = SealedBox.fromBytes(sealed);
      if (box == null) return null;
      final plaintext = await openBytes(box, located.key);
      if (plaintext == null) {
        // The bytes are there but this device cannot open them, which means
        // the key beside them is not the key they were sealed under. Nothing
        // retrying will fix, so it fails quietly rather than looping.
        debugPrint('KapyNotes: image $hash did not open');
        return null;
      }
      // Verified by construction: the store addresses by content, so writing
      // it back under a hash that did not match would be caught immediately.
      if (BlobStore.hashOf(plaintext) != hash) {
        debugPrint('KapyNotes: image $hash did not match its address');
        return null;
      }
      // Kept, so opening this note tomorrow is a disk read rather than
      // another download of bytes we already paid to transfer.
      await _store.put(plaintext, extension: _extensionFor(hash));
      return plaintext;
    } catch (error) {
      debugPrint('KapyNotes: could not fetch image $hash: $error');
      return null;
    }
  }

  /// Presigned URLs and object-store reads can briefly lag the note op that
  /// announced them, especially across a phone network transition. Retry only
  /// that transport boundary; bad ciphertext and bad keys still fail once.
  Future<Uint8List?> _download(String attachmentId) async {
    for (var attempt = 0; ; attempt++) {
      try {
        final urls = await _api.attachmentUrls([attachmentId]);
        final url = urls[attachmentId];
        final bytes = url == null ? null : await _api.getBlob(url);
        if (bytes != null) return bytes;
      } on SyncTransientException catch (error) {
        if (attempt >= downloadRetryDelays.length) rethrow;
        debugPrint('KapyNotes: image download retry: ${error.message}');
      }
      if (attempt >= downloadRetryDelays.length) return null;
      await Future<void>.delayed(downloadRetryDelays[attempt]);
    }
  }

  /// The file extension a hash must be stored under on this device.
  ///
  /// Not cosmetic for audio: iOS picks its decoder from the extension, so a
  /// recording pulled down as a bare hash is silent there and nowhere else —
  /// the kind of bug that only appears on one platform, after a sync, on
  /// somebody else's device.
  String _extensionFor(String hash) {
    for (final note in _notes.allNotes) {
      for (final ref in note.attachments) {
        if (ref.hash != hash) continue;
        if (ref is NoteVoiceRef) return NoteVoiceRef.voiceExtension;
        // Images keep the empty extension they have always had, so nothing
        // already on disk has to be migrated.
        return '';
      }
    }
    return '';
  }

  /// The server id and file key for a hash, from whichever note refers to it.
  ({String id, Uint8List key})? _locate(String hash) {
    for (final note in _notes.allNotes) {
      for (final ref in note.attachments) {
        if (ref.hash == hash && ref.attachmentId != null) {
          return (id: ref.attachmentId!, key: ref.key);
        }
        if (ref is NoteImageRef &&
            ref.thumbHash == hash &&
            ref.thumbId != null) {
          return (id: ref.thumbId!, key: ref.key);
        }
      }
    }
    return null;
  }
}
