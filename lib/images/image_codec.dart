import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// What kind of picture this is, which is the only thing that decides whether
/// re-encoding it may throw information away.
enum ImageKind {
  /// A photograph: continuous tone, sensor noise, no flat regions. Lossy
  /// encoding at high quality is invisible here and saves an order of
  /// magnitude.
  photo,

  /// A screenshot, diagram, logo or chart: flat colour, hard edges, often
  /// text. Lossy encoding is *visible* here — it rings around every glyph —
  /// so these are only ever re-encoded losslessly.
  graphic,
}

/// The result of preparing one image for storage.
class EncodedImage {
  const EncodedImage({
    required this.bytes,
    required this.mime,
    required this.width,
    required this.height,
    required this.kind,
    required this.resized,
    required this.reencoded,
  });

  final Uint8List bytes;
  final String mime;
  final int width;
  final int height;
  final ImageKind kind;

  /// True when the stored pixels are smaller than the ones handed in.
  final bool resized;

  /// False when the original bytes were kept verbatim, which happens whenever
  /// our best effort came out no smaller.
  final bool reencoded;
}

/// Long edge beyond which even a graphic is scaled down.
///
/// Deliberately generous: a 4K screenshot is a real thing people paste into
/// notes and 3200px keeps it legible at any zoom a note view offers, while
/// still refusing the 12000px scans that would otherwise sit in a quota
/// forever.
const int maxLongEdge = 3200;

/// Long edge of the preview stored beside the full image.
const int thumbnailLongEdge = 600;

/// Below this, a thumbnail costs more than it saves.
const int thumbnailMinSourceBytes = 96 * 1024;

/// MIME types accepted on the way in. Anything the platform can decode is
/// fair game; this list is what the file picker advertises.
const Set<String> supportedImageMimes = {
  'image/png',
  'image/jpeg',
  'image/webp',
  'image/gif',
  'image/bmp',
  'image/tiff',
  'image/heic',
  'image/heif',
};

const Set<String> supportedImageExtensions = {
  'png',
  'jpg',
  'jpeg',
  'webp',
  'gif',
  'bmp',
  'tif',
  'tiff',
  'heic',
  'heif',
};

/// Tells a photograph from a screenshot by how flat it is.
///
/// The discriminator is runs of byte-identical neighbouring pixels. A camera
/// sensor never produces two exactly equal adjacent pixels — there is always
/// noise in the last bit — while a screenshot is mostly large fields of one
/// colour. That single measure separates the two populations far more sharply
/// than colour counts do, and costs one pass over a sample.
ImageKind classifyImage(img.Image image) {
  final width = image.width;
  final height = image.height;
  if (width < 2 || height < 2) return ImageKind.graphic;

  // Sample on a grid rather than a block, so a photo with a blown-out sky in
  // one corner is not judged entirely on the sky.
  const targetSamples = 20000;
  final step = math.max(1, math.sqrt((width * height) / targetSamples).floor());

  var pairs = 0;
  var flatPairs = 0;
  final distinct = <int>{};

  for (var y = 0; y < height; y += step) {
    for (var x = 0; x + step < width; x += step) {
      final a = image.getPixel(x, y);
      final b = image.getPixel(x + step, y);
      final aKey = (a.r.toInt() << 16) | (a.g.toInt() << 8) | a.b.toInt();
      final bKey = (b.r.toInt() << 16) | (b.g.toInt() << 8) | b.b.toInt();
      distinct.add(aKey);
      pairs++;
      if (aKey == bKey) flatPairs++;
    }
  }
  if (pairs == 0) return ImageKind.graphic;

  final flatRatio = flatPairs / pairs;
  final distinctRatio = distinct.length / pairs;

  // Flat neighbours dominate: anything above a quarter is not a photograph.
  if (flatRatio > 0.25) return ImageKind.graphic;
  // A very small palette says the same thing about images that were dithered
  // or scaled, which breaks up the flat runs without adding real tone.
  if (distinctRatio < 0.10) return ImageKind.graphic;
  return ImageKind.photo;
}

/// True when any pixel is not fully opaque.
///
/// This overrides classification: JPEG cannot carry an alpha channel, so a
/// photo with transparency has to take the lossless path or it would come
/// back with a black background.
bool hasTransparency(img.Image image) {
  if (image.numChannels < 4) return false;
  for (final pixel in image) {
    if (pixel.a < 255) return true;
  }
  return false;
}

/// Prepares [original] for storage.
///
/// The contract is: never make a file bigger, and never make a graphic worse.
/// Photos are re-encoded lossily at a quality where the difference is not
/// visible at 1:1; everything else is re-encoded losslessly, and if that comes
/// out larger than what we were handed — which is common, since a PNG from a
/// screenshot tool is already well packed — the original bytes are kept
/// untouched.
///
/// [decoded] must be the decoding of [original]. It is passed in rather than
/// decoded here so the caller can use the platform's decoder, which knows
/// formats (HEIC above all) that no pure-Dart decoder does — and a platform
/// decode yields frame zero only, which is why [frameCount] is separate.
EncodedImage encodeForStorage({
  required Uint8List original,
  required img.Image decoded,
  required String sourceMime,
  int frameCount = 1,
  int maxEdge = maxLongEdge,
  int photoQuality = 90,
}) {
  final longEdge = math.max(decoded.width, decoded.height);
  final needsResize = longEdge > maxEdge;

  // An animated image cannot survive a still re-encode, so it is stored
  // exactly as it arrived. That is lossless by the only definition that
  // matters here.
  if (frameCount > 1 && !needsResize) {
    return EncodedImage(
      bytes: original,
      mime: sourceMime,
      width: decoded.width,
      height: decoded.height,
      kind: ImageKind.graphic,
      resized: false,
      reencoded: false,
    );
  }

  var working = decoded;
  if (needsResize) {
    final scale = maxEdge / longEdge;
    working = img.copyResize(
      decoded,
      width: math.max(1, (decoded.width * scale).round()),
      height: math.max(1, (decoded.height * scale).round()),
      interpolation: img.Interpolation.cubic,
    );
  }

  final transparent = hasTransparency(working);
  final kind = transparent ? ImageKind.graphic : classifyImage(working);

  final Uint8List candidate;
  final String candidateMime;
  if (kind == ImageKind.photo) {
    candidate = img.encodeJpg(working, quality: photoQuality);
    candidateMime = 'image/jpeg';
  } else {
    candidate = img.encodePng(working, level: 9);
    candidateMime = 'image/png';
  }

  // Keeping the original is only safe when the pixels are unchanged. Once a
  // resize has happened the original is a different image, however small it
  // was.
  if (!needsResize && candidate.length >= original.length) {
    return EncodedImage(
      bytes: original,
      mime: sourceMime,
      width: decoded.width,
      height: decoded.height,
      kind: kind,
      resized: false,
      reencoded: false,
    );
  }

  return EncodedImage(
    bytes: candidate,
    mime: candidateMime,
    width: working.width,
    height: working.height,
    kind: kind,
    resized: needsResize,
    reencoded: true,
  );
}

/// Builds the preview stored beside a full image.
///
/// Always lossy and always JPEG unless the source has alpha: a thumbnail is
/// only ever shown small, so quality below the full image is invisible, and
/// the whole point is that a note full of pictures costs one small fetch each.
EncodedImage? encodeThumbnail({
  required img.Image decoded,
  required int storedBytes,
  int longEdge = thumbnailLongEdge,
}) {
  if (storedBytes < thumbnailMinSourceBytes) return null;
  final sourceLongEdge = math.max(decoded.width, decoded.height);
  if (sourceLongEdge <= longEdge) return null;

  final scale = longEdge / sourceLongEdge;
  final resized = img.copyResize(
    decoded,
    width: math.max(1, (decoded.width * scale).round()),
    height: math.max(1, (decoded.height * scale).round()),
    interpolation: img.Interpolation.cubic,
  );

  final transparent = hasTransparency(resized);
  final bytes = transparent
      ? img.encodePng(resized, level: 9)
      : img.encodeJpg(resized, quality: 82);

  return EncodedImage(
    bytes: bytes,
    mime: transparent ? 'image/png' : 'image/jpeg',
    width: resized.width,
    height: resized.height,
    kind: ImageKind.photo,
    resized: true,
    reencoded: true,
  );
}
