import 'package:flutter/foundation.dart';

import '../data/note.dart';
import '../data/note_attachment.dart';
import '../data/notes_store.dart';
import '../images/image_store.dart';
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
    required ImageStore store,
    required NotesStore notes,
  }) : _api = api,
       _store = store,
       _notes = notes;

  final SyncApi _api;
  final ImageStore _store;
  final NotesStore _notes;

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

  Future<NoteAttachmentRef?> _uploadOne(Note note, NoteAttachmentRef ref) async {
    try {
      final id = await _put(note, ref.hash, ref.key);
      if (id == null) return null;

      String? thumbId;
      if (ref.thumbHash != null) {
        thumbId = await _put(note, ref.thumbHash!, ref.key);
      }
      return ref.copyWith(attachmentId: id, thumbId: thumbId);
    } catch (error) {
      // Quota refusals land here too, and are the ordinary reason an upload
      // does not happen. The note still syncs; the picture waits.
      debugPrint('KapyNotes: could not upload image ${ref.hash}: $error');
      return null;
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
      final urls = await _api.attachmentUrls([located.id]);
      final url = urls[located.id];
      if (url == null) return null;

      final sealed = await _api.getBlob(url);
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
      if (ImageStore.hashOf(plaintext) != hash) {
        debugPrint('KapyNotes: image $hash did not match its address');
        return null;
      }
      // Kept, so opening this note tomorrow is a disk read rather than
      // another download of bytes we already paid to transfer.
      await _store.put(plaintext);
      return plaintext;
    } catch (error) {
      debugPrint('KapyNotes: could not fetch image $hash: $error');
      return null;
    }
  }

  /// The server id and file key for a hash, from whichever note refers to it.
  ({String id, Uint8List key})? _locate(String hash) {
    for (final note in _notes.notes) {
      for (final ref in note.attachments) {
        if (ref.hash == hash && ref.attachmentId != null) {
          return (id: ref.attachmentId!, key: ref.key);
        }
        if (ref.thumbHash == hash && ref.thumbId != null) {
          return (id: ref.thumbId!, key: ref.key);
        }
      }
    }
    return null;
  }
}
