import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../data/note_attachment.dart';
import '../sync/aead.dart';
import 'image_codec.dart';
import '../data/blob_store.dart';

/// Largest file accepted from disk, before compression.
///
/// Not a quota — that lives on the server — but a guard on memory. Decoding is
/// width × height × 4 bytes whatever the file weighs, so the real ceiling is
/// pixels; this is the crude proxy that stops a 400 MB scan from taking the
/// app down before anything has a chance to measure it.
const int maxSourceBytes = 80 * 1024 * 1024;

/// Why an image could not be added, in words a person can act on.
enum ImageRejection { tooLarge, unreadable, empty }

class IngestedImage {
  const IngestedImage({
    required this.ref,
    required this.originalBytes,
    required this.kind,
    required this.reencoded,
  });

  /// Anchored at offset zero. The caller places it.
  final NoteAttachmentRef ref;
  final int originalBytes;
  final ImageKind kind;
  final bool reencoded;

  /// What the compression actually bought, as a fraction. Zero when the
  /// original was kept.
  double get saved => originalBytes <= 0
      ? 0
      : (originalBytes - ref.bytes) / originalBytes;
}

class ImageIngestResult {
  const ImageIngestResult.ok(this.image) : rejection = null;
  const ImageIngestResult.rejected(this.rejection) : image = null;

  final IngestedImage? image;
  final ImageRejection? rejection;

  bool get isOk => image != null;
}

/// Turns bytes from a file, a drop or a picker into something a note can hold.
///
/// The heavy half runs off the UI isolate. Compressing a 12 MP photograph is
/// hundreds of milliseconds of pure arithmetic, and doing it inline is the
/// difference between "the image appears" and "the app stopped responding
/// while the image appeared".
Future<ImageIngestResult> ingestImage({
  required Uint8List source,
  required String sourceMime,
  required BlobStore store,
}) async {
  if (source.isEmpty) {
    return const ImageIngestResult.rejected(ImageRejection.empty);
  }
  if (source.length > maxSourceBytes) {
    return const ImageIngestResult.rejected(ImageRejection.tooLarge);
  }

  // Fast path: hand the isolate the compressed bytes, which are small, and
  // let it do both the decode and the encode. This covers PNG, JPEG, GIF,
  // BMP, TIFF and WebP.
  //
  // The fallback covers formats only the platform can read — HEIC above all,
  // which is what an iPhone camera actually produces. dart:ui needs the
  // engine, so that decode happens here and only the encode is moved off.
  final prepared =
      await _compress(() => _prepareFromEncoded(source, sourceMime)) ??
      await _compressWithPlatform(source, sourceMime);
  if (prepared == null) {
    return const ImageIngestResult.rejected(ImageRejection.unreadable);
  }

  final hash = await store.put(prepared.bytes);
  String? thumbHash;
  if (prepared.thumbBytes != null) {
    thumbHash = await store.put(prepared.thumbBytes!);
  }

  return ImageIngestResult.ok(
    IngestedImage(
      ref: NoteImageRef(
        offset: 0,
        hash: hash,
        key: randomKey(),
        mime: prepared.mime,
        width: prepared.width,
        height: prepared.height,
        bytes: prepared.bytes.length,
        thumbHash: thumbHash,
      ),
      originalBytes: source.length,
      kind: prepared.kind,
      reencoded: prepared.reencoded,
    ),
  );
}

/// Runs one compression attempt in an isolate, treating a throw as a miss so
/// the caller can fall through to the next strategy.
Future<_Prepared?> _compress(_Prepared? Function() work) async {
  try {
    return await Isolate.run(work);
  } catch (error) {
    debugPrint('KapyNotes: image compression failed: $error');
    return null;
  }
}

Future<_Prepared?> _compressWithPlatform(
  Uint8List source,
  String sourceMime,
) async {
  final raw = await _decodeWithPlatform(source);
  if (raw == null) return null;
  return _compress(() => _prepareFromRaw(source, sourceMime, raw));
}

/// Raw pixels handed back by the platform decoder.
class _RawPixels {
  const _RawPixels({
    required this.rgba,
    required this.width,
    required this.height,
    required this.frameCount,
  });

  final Uint8List rgba;
  final int width;
  final int height;
  final int frameCount;
}

Future<_RawPixels?> _decodeWithPlatform(Uint8List source) async {
  try {
    final codec = await ui.instantiateImageCodec(source);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final result = data == null
        ? null
        : _RawPixels(
            rgba: data.buffer.asUint8List(),
            width: image.width,
            height: image.height,
            frameCount: codec.frameCount,
          );
    image.dispose();
    codec.dispose();
    return result;
  } catch (error) {
    debugPrint('KapyNotes: platform could not decode the image: $error');
    return null;
  }
}

/// What comes back from the compression isolate.
class _Prepared {
  const _Prepared({
    required this.bytes,
    required this.mime,
    required this.width,
    required this.height,
    required this.kind,
    required this.reencoded,
    required this.thumbBytes,
  });

  final Uint8List bytes;
  final String mime;
  final int width;
  final int height;
  final ImageKind kind;
  final bool reencoded;
  final Uint8List? thumbBytes;
}

_Prepared? _prepareFromEncoded(Uint8List source, String sourceMime) {
  final decoder = img.findDecoderForData(source);
  if (decoder == null) return null;
  final decoded = decoder.decode(source);
  if (decoded == null) return null;
  final frameCount = decoded.numFrames;
  return _prepare(source, sourceMime, decoded, frameCount);
}

_Prepared _prepareFromRaw(
  Uint8List source,
  String sourceMime,
  _RawPixels raw,
) {
  final decoded = img.Image.fromBytes(
    width: raw.width,
    height: raw.height,
    bytes: raw.rgba.buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return _prepare(source, sourceMime, decoded, raw.frameCount);
}

_Prepared _prepare(
  Uint8List source,
  String sourceMime,
  img.Image decoded,
  int frameCount,
) {
  final stored = encodeForStorage(
    original: source,
    decoded: decoded,
    sourceMime: sourceMime,
    frameCount: frameCount,
  );
  // The thumbnail is built from the *stored* pixels, not the originals, so it
  // can never look sharper than the image it stands in for.
  final thumbSource = stored.resized ? img.decodeImage(stored.bytes) : decoded;
  final thumb = thumbSource == null
      ? null
      : encodeThumbnail(decoded: thumbSource, storedBytes: stored.bytes.length);
  return _Prepared(
    bytes: stored.bytes,
    mime: stored.mime,
    width: stored.width,
    height: stored.height,
    kind: stored.kind,
    reencoded: stored.reencoded,
    thumbBytes: thumb?.bytes,
  );
}

/// Best guess at a MIME type from a filename, for pickers and drops that do
/// not supply one. The decoder is authoritative; this only labels bytes we
/// end up keeping verbatim.
String mimeForFilename(String? name) {
  final dot = name?.lastIndexOf('.') ?? -1;
  if (name == null || dot < 0) return 'application/octet-stream';
  return switch (name.substring(dot + 1).toLowerCase()) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'webp' => 'image/webp',
    'gif' => 'image/gif',
    'bmp' => 'image/bmp',
    'tif' || 'tiff' => 'image/tiff',
    'heic' => 'image/heic',
    'heif' => 'image/heif',
    _ => 'application/octet-stream',
  };
}
