import 'dart:typed_data';

import '../data/note_format.dart';

/// What a paste reads as, between the clipboard's markup and the note.
///
/// Every source — a page's HTML, the HTML Apple builds from RTF, the
/// markdown an AI's copy button writes — is read into this one shape, and
/// the note's text is written from it: as markdown in a markdown note, as
/// the editor's own plain format in one that is not. Keeping the reading and
/// the writing apart is what lets the two writers agree on what a paste
/// contains while disagreeing about how to say it.
sealed class PasteBlock {
  const PasteBlock();
}

final class PasteParagraph extends PasteBlock {
  const PasteParagraph(this.inlines);

  final List<PasteInline> inlines;
}

final class PasteHeading extends PasteBlock {
  const PasteHeading(this.level, this.inlines);

  /// 1 to 6.
  final int level;
  final List<PasteInline> inlines;
}

final class PasteList extends PasteBlock {
  const PasteList({
    required this.ordered,
    required this.items,
    this.start = 1,
    this.afterEmptyLine = false,
  });

  final bool ordered;

  /// The first item's number, for an ordered list.
  final int start;
  final List<PasteListItem> items;

  /// Whether the source had an empty line just before this list, which
  /// keeps it apart from a list just before that.
  final bool afterEmptyLine;
}

final class PasteListItem {
  const PasteListItem(this.blocks, {this.checked});

  final List<PasteBlock> blocks;

  /// Null for an ordinary item; true or false for a to-do.
  final bool? checked;
}

final class PasteQuote extends PasteBlock {
  const PasteQuote(this.blocks);

  final List<PasteBlock> blocks;
}

final class PasteCode extends PasteBlock {
  const PasteCode(this.text, {this.language});

  final String text;

  /// The info string a fence carries: `python`, `ts`. Null when the source
  /// did not say.
  final String? language;
}

enum PasteAlign { none, center, right }

final class PasteTable extends PasteBlock {
  const PasteTable(this.rows, this.aligns);

  /// The first row is the header. Every row has [aligns].length cells; a
  /// merged cell's value is in its first cell and the rest are empty.
  final List<List<List<PasteInline>>> rows;
  final List<PasteAlign> aligns;
}

final class PasteRule extends PasteBlock {
  const PasteRule();
}

final class PasteMathBlock extends PasteBlock {
  const PasteMathBlock(this.tex);

  final String tex;
}

/// One run of a block's words.
sealed class PasteInline {
  const PasteInline();
}

enum PasteStyle { bold, italic, underline, strike, superscript, subscript }

final class PasteText extends PasteInline {
  const PasteText(this.text, {this.styles = const {}, this.href});

  final String text;
  final Set<PasteStyle> styles;

  /// Where the words link to, already resolved against the page.
  final String? href;
}

final class PasteCodeSpan extends PasteInline {
  const PasteCodeSpan(this.code, {this.styles = const {}, this.href});

  final String code;
  final Set<PasteStyle> styles;
  final String? href;
}

final class PasteMath extends PasteInline {
  const PasteMath(this.tex);

  final String tex;
}

/// A line break inside a block.
final class PasteBreak extends PasteInline {
  const PasteBreak();
}

final class PasteImageInline extends PasteInline {
  const PasteImageInline(this.image, {this.href});

  final PasteImage image;
  final String? href;
}

/// A picture the paste carries, before it is anything in the note.
///
/// Either its bytes came with the clipboard — a data URI, an RTFD attachment,
/// a Safari web archive's resource — or [src] says where to fetch them.
class PasteImage {
  const PasteImage({
    this.src,
    this.bytes,
    this.mime,
    this.alt = '',
    this.width,
    this.height,
  });

  /// An absolute http(s) or file URL, or null when [bytes] are here.
  final String? src;
  final Uint8List? bytes;
  final String? mime;
  final String alt;

  /// The size the source displayed it at, in CSS pixels, when it said.
  final double? width;
  final double? height;

  bool get hasBytes => bytes != null && bytes!.isNotEmpty;

  /// How much of the writing column the picture takes: its displayed width
  /// against a 720px column, so a logo stays a logo and a figure stays wide.
  double get widthFactor {
    final shown = width;
    if (shown == null || shown <= 0) return 1;
    return (shown / referenceColumnWidth).clamp(0.25, 1.0);
  }

  static const double referenceColumnWidth = 720;
}

/// What a paste puts into a note: its text, the styles a note without
/// markdown holds beside the text, and its pictures.
class PasteOutput {
  const PasteOutput({
    required this.text,
    this.formats = const [],
    this.images = const [],
  });

  /// One U+FFFC stands for each of [images], on a line of its own.
  final String text;

  /// Bold, italic, heading and subtitle over [text], for a note written
  /// without markdown. Always empty for markdown, which says it in the text.
  final List<NoteFormatRange> formats;
  final List<PastedImage> images;

  bool get isEmpty => text.isEmpty;

  /// Whether there is anything here besides pictures.
  bool get hasWords => text.replaceAll('\uFFFC', '').trim().isNotEmpty;

  /// The same paste for a note that can't hold pictures, with every style
  /// moved along with the words.
  PasteOutput withoutPictures() {
    if (images.isEmpty) return this;
    int moved(int offset) =>
        offset - '\uFFFC'.allMatches(text.substring(0, offset)).length;
    return PasteOutput(
      text: text.replaceAll('\uFFFC', ''),
      formats: [
        for (final range in formats)
          NoteFormatRange(
            start: moved(range.start),
            end: moved(range.end),
            format: range.format,
          ),
      ],
    );
  }
}

/// A picture and the offset of its U+FFFC in [PasteOutput.text].
class PastedImage {
  const PastedImage(this.offset, this.image);

  final int offset;
  final PasteImage image;
}

/// Pairs each U+FFFC in [text] with the next of [images], in order.
List<PastedImage> placeImages(String text, List<PasteImage> images) {
  final placed = <PastedImage>[];
  var next = 0;
  for (var i = 0; i < text.length && next < images.length; i++) {
    if (text.codeUnitAt(i) == 0xFFFC) {
      placed.add(PastedImage(i, images[next++]));
    }
  }
  return placed;
}
