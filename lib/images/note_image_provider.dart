import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../data/blob_store.dart';

/// Identifies one decoded image by its content and painted pixel size.
///
/// This is the key Flutter's own [ImageCache] holds decoded frames under, so
/// the same picture at the same size in five notes decodes once. Keying on the
/// hash rather than a URL is not an optimisation, it is the whole point:
/// presigned URLs are re-minted on every fetch, so a URL-keyed cache misses
/// every single time and re-downloads bytes it already has. Keeping the target
/// size in the key also prevents a small editor preview from being reused in
/// the full-screen viewer.
@immutable
class NoteImageKey {
  const NoteImageKey({
    required this.hash,
    required this.fallbackHash,
    required this.scale,
    required this.cover,
    required this.canFetch,
    this.cacheWidth,
    this.cacheHeight,
  });

  final String hash;
  final String? fallbackHash;
  final double scale;
  final bool cover;
  final bool canFetch;
  final int? cacheWidth;
  final int? cacheHeight;

  @override
  bool operator ==(Object other) =>
      other is NoteImageKey &&
      other.hash == hash &&
      other.fallbackHash == fallbackHash &&
      other.scale == scale &&
      other.cover == cover &&
      other.canFetch == canFetch &&
      other.cacheWidth == cacheWidth &&
      other.cacheHeight == cacheHeight;

  @override
  int get hashCode => Object.hash(
    hash,
    fallbackHash,
    scale,
    cover,
    canFetch,
    cacheWidth,
    cacheHeight,
  );

  @override
  String toString() =>
      'NoteImageKey($hash, ${cacheWidth ?? "source"}x${cacheHeight ?? "source"})';
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
    this.fallbackHash,
    this.fetch,
    this.scale = 1.0,
    this.cover = false,
  });

  final String hash;
  final String? fallbackHash;
  final BlobStore store;
  final NoteImageFetcher? fetch;
  final double scale;

  /// Decode enough pixels to fill both target dimensions. This preserves the
  /// sharpness of cropped gallery tiles without retaining the source image.
  final bool cover;

  @override
  Future<NoteImageKey> obtainKey(ImageConfiguration configuration) {
    final size = configuration.size;
    final pixelRatio = configuration.devicePixelRatio ?? 1;
    final width = size == null || !size.width.isFinite || size.width <= 0
        ? null
        : (size.width * pixelRatio).ceil();
    final height = size == null || !size.height.isFinite || size.height <= 0
        ? null
        : (size.height * pixelRatio).ceil();
    return SynchronousFuture(
      NoteImageKey(
        hash: hash,
        fallbackHash: fallbackHash,
        scale: scale,
        cover: cover,
        canFetch: fetch != null,
        cacheWidth: width,
        cacheHeight: height,
      ),
    );
  }

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
    var bytes = await _bytesFor(key.hash);
    if ((bytes == null || bytes.isEmpty) && key.fallbackHash != null) {
      bytes = await _bytesFor(key.fallbackHash!);
    }

    if (bytes == null || bytes.isEmpty) {
      // Thrown, and deliberately not evicted alongside. Evicting a key while
      // resolving it makes the widget resolve it again at once, which fails
      // again, and the two spin until something gives up. Nothing is lost by
      // leaving it: [ImageCache] drops a failed entry rather than remembering
      // it, so the next time this note is built the picture is tried afresh.
      throw StateError('image ${key.hash} is not available');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(
      buffer,
      getTargetSize: key.cacheWidth == null && key.cacheHeight == null
          ? null
          : (intrinsicWidth, intrinsicHeight) {
              final scales = [
                if (key.cacheWidth != null) key.cacheWidth! / intrinsicWidth,
                if (key.cacheHeight != null) key.cacheHeight! / intrinsicHeight,
              ];
              final targetScale = scales.reduce(
                key.cover ? (a, b) => a > b ? a : b : (a, b) => a < b ? a : b,
              );
              final bounded = targetScale.clamp(0.0, 1.0);
              return ui.TargetImageSize(
                width: (intrinsicWidth * bounded).round().clamp(
                  1,
                  intrinsicWidth,
                ),
                height: (intrinsicHeight * bounded).round().clamp(
                  1,
                  intrinsicHeight,
                ),
              );
            },
    );
  }

  Future<Uint8List?> _bytesFor(String wantedHash) async {
    var bytes = await store.read(wantedHash);
    if (bytes == null && fetch != null) {
      bytes = await fetch!(wantedHash);
      // Whatever came back is written before it is decoded, so the next open
      // of this note is a disk read rather than another billed download.
      if (bytes != null) await store.put(bytes);
    }
    return bytes;
  }

  @override
  bool operator ==(Object other) =>
      other is NoteImageProvider &&
      other.hash == hash &&
      other.fallbackHash == fallbackHash &&
      other.scale == scale &&
      other.cover == cover &&
      (other.fetch == null) == (fetch == null) &&
      identical(other.store, store);

  @override
  int get hashCode => Object.hash(
    hash,
    fallbackHash,
    scale,
    cover,
    fetch != null,
    identityHashCode(store),
  );

  @override
  String toString() => 'NoteImageProvider($hash)';
}
