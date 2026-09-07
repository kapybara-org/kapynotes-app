import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:kapy_notes/images/image_codec.dart';

/// A synthetic screenshot: flat fields, hard edges, a little "text".
img.Image fakeScreenshot({int width = 900, int height = 600}) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(246, 246, 248));
  img.fillRect(
    image,
    x1: 0,
    y1: 0,
    x2: width,
    y2: 60,
    color: img.ColorRgb8(32, 34, 40),
  );
  for (var row = 0; row < 12; row++) {
    final y = 110 + row * 34;
    img.fillRect(
      image,
      x1: 40,
      y1: y,
      x2: 40 + 180 + (row * 37) % 420,
      y2: y + 12,
      color: img.ColorRgb8(70, 74, 84),
    );
  }
  return image;
}

/// A synthetic photograph: a smooth gradient plus per-pixel sensor noise, so
/// no two neighbouring pixels are ever byte-identical.
img.Image fakePhoto({int width = 900, int height = 600, int seed = 7}) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  final random = Random(seed);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final base = 40 + (x * 160 ~/ width) + (y * 40 ~/ height);
      int channel(int shift) =>
          (base + shift + random.nextInt(11) - 5).clamp(0, 255);
      image.setPixelRgb(x, y, channel(0), channel(25), channel(60));
    }
  }
  return image;
}

void main() {
  group('classifyImage', () {
    test('calls a flat-field screenshot a graphic', () {
      expect(classifyImage(fakeScreenshot()), ImageKind.graphic);
    });

    test('calls a noisy gradient a photo', () {
      expect(classifyImage(fakePhoto()), ImageKind.photo);
    });

    test('a tiny image is a graphic, not a division by zero', () {
      expect(classifyImage(img.Image(width: 1, height: 1)), ImageKind.graphic);
    });
  });

  group('encodeForStorage', () {
    test('a screenshot is re-encoded losslessly, never to JPEG', () {
      final source = fakeScreenshot();
      final original = Uint8List.fromList(img.encodePng(source, level: 1));
      final result = encodeForStorage(
        original: original,
        decoded: source,
        sourceMime: 'image/png',
      );
      expect(result.kind, ImageKind.graphic);
      expect(result.mime, 'image/png');
      // Decoding it back must give the exact pixels: that is what lossless is.
      final round = img.decodeImage(result.bytes)!;
      expect(round.width, source.width);
      final a = source.getPixel(300, 120);
      final b = round.getPixel(300, 120);
      expect([b.r, b.g, b.b], [a.r, a.g, a.b]);
    });

    test('a photo becomes a high-quality JPEG and gets much smaller', () {
      final source = fakePhoto();
      final original = Uint8List.fromList(img.encodePng(source, level: 6));
      final result = encodeForStorage(
        original: original,
        decoded: source,
        sourceMime: 'image/png',
      );
      expect(result.kind, ImageKind.photo);
      expect(result.mime, 'image/jpeg');
      expect(result.bytes.length, lessThan(original.length ~/ 2));
    });

    test('never returns bytes larger than it was given', () {
      // A PNG already packed tighter than our own encoder manages.
      final source = fakeScreenshot();
      final original = Uint8List.fromList(img.encodePng(source, level: 9));
      final result = encodeForStorage(
        original: original,
        decoded: source,
        sourceMime: 'image/png',
      );
      expect(result.bytes.length, lessThanOrEqualTo(original.length));
    });

    test('an oversized image is scaled to the long-edge cap', () {
      final source = fakePhoto(width: 5000, height: 2500);
      final result = encodeForStorage(
        original: Uint8List.fromList(img.encodeJpg(source, quality: 95)),
        decoded: source,
        sourceMime: 'image/jpeg',
        maxEdge: 3200,
      );
      expect(result.resized, isTrue);
      expect(result.width, 3200);
      expect(result.height, 1600);
    });

    test('transparency forces the lossless path even for a photo', () {
      final source = fakePhoto(width: 300, height: 200);
      final withAlpha = source.convert(numChannels: 4);
      withAlpha.setPixelRgba(10, 10, 0, 0, 0, 0);
      final result = encodeForStorage(
        original: Uint8List.fromList(img.encodePng(withAlpha, level: 6)),
        decoded: withAlpha,
        sourceMime: 'image/png',
      );
      expect(result.mime, 'image/png');
    });
  });

  group('encodeThumbnail', () {
    test('is skipped for an image that is already small', () {
      final source = fakePhoto(width: 400, height: 300);
      expect(
        encodeThumbnail(decoded: source, storedBytes: 20 * 1024),
        isNull,
      );
    });

    test('scales a large photo down to the preview edge', () {
      final source = fakePhoto(width: 2400, height: 1600);
      final thumb = encodeThumbnail(
        decoded: source,
        storedBytes: 900 * 1024,
      )!;
      expect(thumb.width, 600);
      expect(thumb.height, 400);
      expect(thumb.mime, 'image/jpeg');
    });
  });
}
