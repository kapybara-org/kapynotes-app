import 'dart:io';
import 'dart:typed_data';

import '../data/blob_store.dart';
import '../data/note_attachment.dart';

/// The file a recording plays from on this device, fetched first when it
/// arrived by sync. Null when it is not here and cannot be got.
///
/// A recording made on another device reaches this one as a ref — its length,
/// its waveform, its transcript — while the audio stays on the server until
/// somebody asks to hear it, the way a full-size picture waits for a tap.
///
/// [fetch] is the signed-in account's, and null without one. It keeps what it
/// downloads under the extension the ref's kind asks for; the fallback below
/// does the same for a fetcher that does not, so a recording is never kept as
/// a bare hash, which iOS will not decode.
Future<File?> openRecording(
  String hash, {
  required BlobStore blobs,
  Future<Uint8List?> Function(String hash)? fetch,
}) async {
  final local = await blobs.fileFor(hash);
  if (local != null || fetch == null) return local;

  final bytes = await fetch(hash);
  if (bytes == null) return null;
  final kept = await blobs.fileFor(hash);
  if (kept != null) return kept;
  if (BlobStore.hashOf(bytes) != hash) return null;
  await blobs.put(bytes, extension: NoteVoiceRef.voiceExtension);
  return blobs.fileFor(hash);
}
