import 'dart:math' as math;

import '../../data/note_attachment.dart';

/// The box one image occupies in the editor.
class NoteImageBox {
  const NoteImageBox({
    required this.width,
    required this.height,
    required this.cropped,
  });

  final double width;
  final double height;

  /// True when the image is a tile in a grid and is filled rather than fitted.
  ///
  /// A row of tiles only reads as a row if the tiles agree on a height, and
  /// they can only agree by cropping. A single image is never cropped: it is
  /// the thing the reader is looking at, and showing three quarters of it to
  /// keep a rectangle tidy is the wrong trade.
  final bool cropped;
}

/// Gap between tiles in a grid, and the vertical air around any image.
const double noteImageGap = 8;

/// How much narrower than the writing column an attachment is laid out.
///
/// It buys one thing, and it is not a margin: a line whose placeholder fills
/// the available width to the pixel makes Flutter drop the empty line that
/// follows it. Not shorten — drop. The line box is never created, the caret
/// for that position collapses onto the placeholder's own line at its right
/// edge, and since the attachment is painted over that spot there is nothing
/// to click and nothing to see. A note ending in a picture or a recording had
/// no line under it to write on.
///
/// Measured rather than guessed: the line survives from three pixels of slack
/// and the threshold does not move with the font size, from 12pt to 40pt. Eight
/// is that with room to spare, and is checked by a test — if a future Flutter
/// lays the line out either way, that test says so rather than this quietly
/// mattering or quietly not.
const double noteAttachmentColumnSlack = 8;

/// Tiles are 4:3, which is close enough to both a phone photo and a laptop
/// screenshot that neither is badly served.
const double noteImageTileAspect = 4 / 3;

/// How many tiles sit across a row of [count] images.
///
/// Four goes to two-by-two rather than three-then-one: a lone straggler under
/// a full row is the thing that makes a gallery look broken rather than
/// composed.
int tilesPerRow(int count) {
  if (count <= 1) return 1;
  if (count == 2) return 2;
  if (count == 4) return 2;
  return 3;
}

/// Sizes one image, given how many share its line.
///
/// A line with a single image is the blog case: it fills the text column, and
/// is only ever shortened by [maxHeight], so a tall portrait photograph does
/// not push the writing off the screen. A line with several is a gallery, and
/// the images become equal tiles that wrap.
NoteImageBox imageBoxFor({
  required int countOnLine,
  required double columnWidth,
  required double aspectRatio,
  required double maxHeight,
  double widthFactor = 1,
  double gap = noteImageGap,
}) {
  final safeWidth = math.max(1.0, columnWidth);
  final safeAspect = aspectRatio <= 0 ? 1.0 : aspectRatio;

  if (countOnLine <= 1) {
    // The chosen width is honoured before the height cap, so shrinking an
    // image never makes it taller and a tall one that was already capped
    // simply gets shorter.
    var width = safeWidth * clampImageWidthFactor(widthFactor);
    var height = width / safeAspect;
    if (maxHeight > 0 && height > maxHeight) {
      // Give back width rather than cropping, so the whole picture survives.
      height = maxHeight;
      width = math.min(width, height * safeAspect);
    }
    return NoteImageBox(
      width: width,
      height: math.max(1, height),
      cropped: false,
    );
  }

  // A gallery sizes itself: the tiles have to agree on a width to read as a
  // row, so a per-image setting has nothing to act on here.
  final perRow = tilesPerRow(countOnLine);
  final tileWidth = math.max(1.0, (safeWidth - (perRow - 1) * gap) / perRow);
  return NoteImageBox(
    width: tileWidth,
    height: math.max(1, tileWidth / noteImageTileAspect),
    cropped: true,
  );
}

/// How many images sit on the line containing [offset].
///
/// Images that share a line become a gallery, and they share a line because
/// the writer added several at once — the insert puts them side by side
/// deliberately. Splitting them onto their own lines is one Return away, and
/// turns the gallery back into a stack of full-width images.
int imagesOnLineAt(String body, int offset, List<NoteAttachmentRef> refs) {
  final line = _lineRangeAt(body, offset);
  var count = 0;
  for (final ref in refs) {
    if (ref.offset >= line.start && ref.offset < line.end) count++;
  }
  return count;
}

/// The index of [offset] among the images on its own line, counting from zero.
int imageIndexOnLineAt(
  String body,
  int offset,
  List<NoteAttachmentRef> refs,
) {
  final line = _lineRangeAt(body, offset);
  var index = 0;
  for (final ref in refs) {
    if (ref.offset >= line.start && ref.offset < offset) index++;
  }
  return line.start <= offset ? index : 0;
}

({int start, int end}) _lineRangeAt(String body, int offset) {
  if (offset < 0 || offset > body.length) return (start: 0, end: body.length);
  var start = offset;
  while (start > 0 && body.codeUnitAt(start - 1) != 0x0A) {
    start--;
  }
  var end = offset;
  while (end < body.length && body.codeUnitAt(end) != 0x0A) {
    end++;
  }
  return (start: start, end: end);
}
