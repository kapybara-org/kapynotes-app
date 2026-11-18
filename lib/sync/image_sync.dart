import 'dart:async';
import 'dart:convert';

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

  /// Reservations made on the server and not yet confirmed, by the blob and
  /// key they are for.
  ///
  /// An upload interrupted anywhere after its reservation — mid-PUT, or
  /// after the PUT but before the confirmation — used to be retried with a
  /// brand-new one, so a flaky connection left a trail of reservations and
  /// sometimes whole objects that nothing would ever confirm. Now the retry
  /// picks up the reservation it already has: it asks to confirm first, in
  /// case the bytes did land, and uploads again only if they did not.
  ///
  /// Only for this session. After a restart the server's collector clears
  /// what was left, a day later.
  final Map<String, AttachmentSlot> _slots = {};

  /// How long before its URL expires a reservation stops being worth
  /// reusing. Room for a large PUT to start in time.
  static const Duration _slotMargin = Duration(minutes: 2);

  /// One listenable per local blob that has appeared in the editor. A media
  /// tile listens only to its own hash, so upload chunks do not rebuild the
  /// note around it.
  final Map<String, ValueNotifier<double?>> _uploadProgress = {};

  ValueListenable<double?> progressFor(String hash) =>
      _uploadProgress.putIfAbsent(hash, () => ValueNotifier<double?>(null));

  void _setProgress(String hash, double? value) {
    _uploadProgress
            .putIfAbsent(hash, () => ValueNotifier<double?>(null))
            .value =
        value;
  }

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
    // The preview is visible, but compression has not produced the durable
    // object yet. Uploading this temporary source would race the replacement.
    if (ref case NoteImageRef(isPreparing: true)) return null;

    var current = ref;
    try {
      var id = current.attachmentId;
      if (id == null) {
        _setProgress(current.hash, 0);
        final mainShare = current is NoteImageRef && current.thumbHash != null
            ? 0.9
            : 1.0;
        id = await _put(
          note,
          current.hash,
          current.key,
          onProgress: (value) => _setProgress(current.hash, value * mainShare),
        );
        if (id == null) return null;
        current = current.copyWith(attachmentId: id);
      }

      // Only a picture has a second object to upload. Every other kind is one
      // blob, and uploads by the same path.
      if (current is NoteImageRef) {
        var thumbId = current.thumbId;
        if (current.thumbHash != null && thumbId == null) {
          _setProgress(current.hash, 0.9);
          thumbId = await _put(
            note,
            current.thumbHash!,
            current.key,
            onProgress: (value) =>
                _setProgress(current.hash, 0.9 + value * 0.1),
          );
          if (thumbId == null) return current;
        }
        _setProgress(current.hash, 1);
        return current.copyWith(attachmentId: id, thumbId: thumbId);
      }
      _setProgress(current.hash, 1);
      return current;
    } catch (error) {
      // Quota refusals land here too, and are the ordinary reason an upload
      // does not happen. Preserve whichever object already completed so a
      // thumbnail interruption never retransmits and bills the full image.
      debugPrint('KapyNotes: could not upload image ${current.hash}: $error');
      _setProgress(current.hash, null);
      return current.attachmentId == null ? null : current;
    }
  }

  /// Seals one blob under its file key and stores it. Null when the bytes are
  /// not on this device, which happens on a device that pulled the note but
  /// never had the picture.
  Future<String?> _put(
    Note note,
    String hash,
    Uint8List key, {
    void Function(double progress)? onProgress,
  }) async {
    final plaintext = await _store.read(hash);
    if (plaintext == null) return null;

    final slotKey = '$hash:${base64.encode(key)}';
    final previous = _slots[slotKey];
    if (previous != null) {
      final resumed = await _resume(slotKey, previous);
      if (resumed) {
        onProgress?.call(1);
        return previous.id;
      }
    }

    final sealed = await sealBytes(plaintext, key);
    final body = sealed.toBytes();
    var slot = _slots[slotKey];
    if (slot != null && !_stillUsable(slot)) {
      _release(_slots.remove(slotKey)!);
      slot = null;
    }
    slot ??= _slots[slotKey] = await _api.createAttachment(
      noteId: note.id,
      spaceId: note.spaceId,
      bytes: body.length,
    );

    try {
      await _api.putBlob(slot.uploadUrl, body, onProgress: onProgress);
      await _api.completeAttachment(slot.id);
    } on SyncTransientException {
      // Kept: the next pass resumes this reservation.
      rethrow;
    } on SyncRefusedException catch (error) {
      // Refused for good — an expired URL, an object over the limit, a plan
      // that lapsed. This reservation will never be confirmed, so it is given
      // back now rather than left for the collector.
      if (identical(_slots[slotKey], slot)) _slots.remove(slotKey);
      _release(slot);
      debugPrint('KapyNotes: upload refused: ${error.code}');
      rethrow;
    }
    _slots.remove(slotKey);
    return slot.id;
  }

  /// Tries to finish an earlier attempt without sending the bytes again.
  ///
  /// True when the server confirmed it — the PUT had landed and only the
  /// confirmation was lost. False when there is still uploading to do, with
  /// the reservation kept if its URL is still good and given back if it is not.
  Future<bool> _resume(String slotKey, AttachmentSlot slot) async {
    try {
      await _api.completeAttachment(slot.id);
      _slots.remove(slotKey);
      return true;
    } on SyncRefusedException catch (error) {
      // 409: the object is not there, so the PUT still has to happen.
      if (error.status == 409 && _stillUsable(slot)) return false;
      // Anything else — gone, too large, expired — ends this reservation.
      _slots.remove(slotKey);
      if (error.status != 404) _release(slot);
      return false;
    }
  }

  bool _stillUsable(AttachmentSlot slot) {
    final expiresAt = slot.expiresAt;
    if (expiresAt == null) return false;
    return DateTime.now().add(_slotMargin).isBefore(expiresAt);
  }

  /// Best effort. A release that fails is not retried here: the server's
  /// collector gives up unconfirmed reservations on its own.
  void _release(AttachmentSlot slot) {
    unawaited(
      _api.deleteAttachment(slot.id).catchError((Object error) {
        debugPrint('KapyNotes: could not release upload ${slot.id}: $error');
      }),
    );
  }

  /// Ids asked about in one request by [forgetSwept]; the most the server
  /// takes at once.
  static const int sweptBatch = 100;

  /// Before a device that comes back after a reset publishes its notes again:
  /// lets go of each server id among [notes] that the server no longer has,
  /// when this device holds the bytes to upload again.
  ///
  /// A reset leaves pictures where they are, but those of notes no device
  /// brought back within 30 days are swept with the rest of what it set
  /// aside. An id that is gone and has no bytes here stays as it is: nothing
  /// could replace it, and another device that holds the picture can.
  ///
  /// False when the server could not be asked, with nothing changed, so the
  /// caller can ask again on its next pass.
  Future<bool> forgetSwept(List<Note> notes) async {
    final ids = <String>{
      for (final note in notes)
        for (final ref in note.attachments)
          if (ref is! NoteUnknownRef) ...[
            ?ref.attachmentId,
            if (ref is NoteImageRef) ?ref.thumbId,
          ],
    }.toList();
    if (ids.isEmpty) return true;

    final kept = <String>{};
    try {
      for (var start = 0; start < ids.length; start += sweptBatch) {
        final end = start + sweptBatch < ids.length
            ? start + sweptBatch
            : ids.length;
        kept.addAll((await _api.attachmentUrls(ids.sublist(start, end))).keys);
      }
    } on SyncTransientException {
      return false;
    } on SyncException catch (error) {
      // Not a question this server can answer, which is no reason to keep
      // the notes from going back up: the ids stay as they are.
      debugPrint('KapyNotes: rejoin could not check attachments: $error');
      return true;
    }

    var cleared = 0;
    var unrecoverable = 0;
    for (final note in notes) {
      for (final ref in note.attachments) {
        if (ref is NoteUnknownRef) continue;
        final id = ref.attachmentId;
        final (thumbId, thumbHash) = ref is NoteImageRef
            ? (ref.thumbId, ref.thumbHash)
            : (null, null);
        final mainGone = id != null && !kept.contains(id);
        final thumbGone = thumbId != null && !kept.contains(thumbId);
        if (!mainGone && !thumbGone) continue;
        final clearMain = mainGone && await _store.has(ref.hash);
        final clearThumb =
            thumbGone && thumbHash != null && await _store.has(thumbHash);
        if (mainGone && !clearMain) unrecoverable++;
        if (thumbGone && !clearThumb) unrecoverable++;
        if (!clearMain && !clearThumb) continue;
        final updated = _notes.updateAttachment(
          note.id,
          ref.hash,
          (current) {
            final json = {...current.toJson()};
            if (clearMain && json['attachmentId'] == id) {
              json.remove('attachmentId');
            }
            if (clearThumb && json['thumbId'] == thumbId) {
              json.remove('thumbId');
            }
            return NoteAttachmentRef.fromJson(json) ?? current;
          },
          touch: true,
          key: ref.key,
        );
        if (updated) {
          if (clearMain) cleared++;
          if (clearThumb) cleared++;
        }
      }
    }
    if (cleared > 0 || unrecoverable > 0) {
      debugPrint(
        'KapyNotes: rejoin found ${ids.length - kept.length} attachments '
        'gone: $cleared to upload again, $unrecoverable not on this device',
      );
    }
    return true;
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
        if (ref is NoteVideoRef) return ref.extension;
        // Kept so the file opens on this device the way it did on the one it
        // came from; the name itself is only ever used for copies handed out.
        if (ref is NoteFileRef) return ref.extension;
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

  void dispose() {
    for (final notifier in _uploadProgress.values) {
      notifier.dispose();
    }
    _uploadProgress.clear();
  }
}
