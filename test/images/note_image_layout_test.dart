import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ui/editor/note_image_layout.dart';

void main() {
  group('tilesPerRow', () {
    test('one, two and three go across as they are', () {
      expect(tilesPerRow(1), 1);
      expect(tilesPerRow(2), 2);
      expect(tilesPerRow(3), 3);
    });

    test('four is two by two, not three and a straggler', () {
      expect(tilesPerRow(4), 2);
    });

    test('more than four wraps in threes', () {
      expect(tilesPerRow(5), 3);
      expect(tilesPerRow(9), 3);
    });
  });

  group('imageBoxFor', () {
    test('a lone image fills the column and keeps its shape', () {
      final box = imageBoxFor(
        countOnLine: 1,
        columnWidth: 600,
        aspectRatio: 2,
        maxHeight: 1000,
      );
      expect(box.width, 600);
      expect(box.height, 300);
      expect(box.cropped, isFalse);
    });

    test('a tall image is shortened rather than cropped', () {
      final box = imageBoxFor(
        countOnLine: 1,
        columnWidth: 600,
        aspectRatio: 0.5,
        maxHeight: 400,
      );
      expect(box.height, 400);
      // Width given back to preserve the shape, so nothing is cut off.
      expect(box.width, 200);
      expect(box.cropped, isFalse);
    });

    test('a width factor narrows a lone image', () {
      final box = imageBoxFor(
        countOnLine: 1,
        columnWidth: 600,
        aspectRatio: 2,
        maxHeight: 1000,
        widthFactor: 0.5,
      );
      expect(box.width, 300);
      expect(box.height, 150);
    });

    test('a width factor is ignored inside a gallery', () {
      final plain = imageBoxFor(
        countOnLine: 3,
        columnWidth: 600,
        aspectRatio: 2,
        maxHeight: 1000,
      );
      final narrowed = imageBoxFor(
        countOnLine: 3,
        columnWidth: 600,
        aspectRatio: 2,
        maxHeight: 1000,
        widthFactor: 0.4,
      );
      expect(narrowed.width, plain.width);
      expect(narrowed.cropped, isTrue);
    });

    test('tiles share the column, minus the gaps between them', () {
      final box = imageBoxFor(
        countOnLine: 3,
        columnWidth: 316,
        aspectRatio: 1,
        maxHeight: 1000,
        gap: 8,
      );
      expect(box.width, 100);
      expect(box.height, closeTo(75, 0.01));
    });

    test('a zero-sized column does not divide by zero', () {
      final box = imageBoxFor(
        countOnLine: 1,
        columnWidth: 0,
        aspectRatio: 0,
        maxHeight: 0,
      );
      expect(box.width, greaterThan(0));
      expect(box.height, greaterThan(0));
    });
  });
}
