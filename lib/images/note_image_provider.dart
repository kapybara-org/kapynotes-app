import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../data/blob_store.dart';

/// Identifies one image by its content, and nothing else.
///
/// This is the key Flutter's own [ImageCache] holds decoded frames under, so
/// the same picture in five notes decodes once. Keying on the hash rather than
/// a URL is not an optimisation, it is the whole point: presigned URLs are
/// re-minted on every fetch, so a URL-keyed cache misses every single time and
/// re-downloads bytes it already has.
@immutable
class NoteImageKey {
  const NoteImageKey({required this.hash, required this.scale});

  final String hash;
  final double scale;

  @override
  bool operator ==(Object other) =>
      other is NoteImageKey && other.hash == hash && other.scale == scale;

  @override
  int get hashCode => Object.hash(hash, scale);

  @override
  String toString() => 'NoteImageKey($hash)';
}

/// Fetches bytes for an image the local store does not have.
///
/// Null on a device with no account, which is the ordinary case and not an
/// error: every image the user added themselves is already on disk. This only
/// has work to do for images that arrived by sync.
typedef NoteImageFetcher = Future<Uint8List?> Function(String hash);

/// Paints a note's image from local bytes, fetching them once if they are not
/// here yet.
class NoteImageProvider extends ImageProvider<NoteImageKey> {
  const NoteImageProvider({
    required this.hash,
    required this.store,
    this.fetch,
    this.scale = 1.0,
  });

  final String hash;
  final BlobStore store;
  final NoteImageFetcher? fetch;
  final double scale;

  @override
  Future<NoteImageKey> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(NoteImageKey(hash: hash, scale: scale));

  @override
  ImageStreamCompleter loadImage(
    NoteImageKey key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(
    codec: _load(key, decode),
    scale: key.scale,
    debugLabel: 'note image ${key.hash}',
  );

  Future<ui.Codec> _load(NoteImageKey key, ImageDecoderCallback decode) async {
    var bytes = await store.read(key.hash);

    if (bytes == null && fetch != null) {
      bytes = await fetch!(key.hash);
      // Whatever came back is written before it is decoded, so the next open
      // of this note is a disk read rather than another billed download.
      if (bytes != null) await store.put(bytes);
    }

    if (bytes == null || bytes.isEmpty) {
      // Thrown, and deliberately not evicted alongside. Evicting a key while
      // resolving it makes the widget resolve it again at once, which fails
      // again, and the two spin until something gives up. Nothing is lost by
      // leaving it: [ImageCache] drops a failed entry rather than remembering
      // it, so the next time this note is built the picture is tried afresh.
      throw StateError('image ${key.hash} is not available');
    }
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) =>
      other is NoteImageProvider &&
      other.hash == hash &&
      other.scale == scale &&
      identical(other.store, store);

  @override
  int get hashCode => Object.hash(hash, scale, identityHashCode(store));

  @override
  String toString() => 'NoteImageProvider($hash)';
}
