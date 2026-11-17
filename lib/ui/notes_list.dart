import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../calc/engine.dart';
import '../core/editor_font.dart';
import '../core/theme.dart';
import '../data/note.dart';
import '../data/note_attachment.dart';
import '../data/note_drawing.dart';
import 'checklist_pie.dart';
import 'compact_icon_button.dart';
import 'draw/drawing_geometry.dart';
import 'draw/drawing_painter.dart';
import 'sidebar.dart' show archiveIcon, hiddenIcon;

/// What a note can hold besides words, in the order the media filter lists
/// them.
enum NoteMedia {
  drawing('Drawing', KapyIcons.penRounded),
  voice('Voice', KapyIcons.micRounded),
  video('Video', KapyIcons.videoOutlined),
  image('Image', KapyIcons.photoLibraryOutlined);

  const NoteMedia(this.label, this.icon);

  final String label;
  final KapyIconData icon;

  static Set<NoteMedia> inNote(Note note) => {
    if (note.isDrawing) drawing,
    for (final ref in note.attachments)
      if (ref is NoteVoiceRef)
        voice
      else if (ref is NoteVideoRef)
        video
      else if (ref is NoteImageRef)
        image,
  };

  /// Whether [note] stays in a list narrowed to [ticked]: every note while
  /// every kind is ticked, and otherwise the notes holding a kind still
  /// ticked.
  static bool shows(Note note, Set<NoteMedia> ticked) =>
      ticked.length == values.length || inNote(note).any(ticked.contains);
}

/// What the notes list shows of a note under its title.
///
/// Read once per version of a note: notes are immutable, so a card that
/// repaints on hover does not split the body again.
class NoteGlance {
  const NoteGlance._({
    required this.line,
    required this.result,
    required this.done,
    required this.boxes,
    required this.media,
  });

  /// The first line under the title, without a checkbox or heading mark.
  final String? line;

  /// What [line] calculates to, when it is a calculation.
  final String? result;

  /// [line] as written when it is nothing but an amount, "₹75,60,000", which
  /// a card shows as its figure whether or not there are rates to read it by.
  String? get amount {
    final line = this.line;
    return line != null && _amount.hasMatch(line) ? line : null;
  }

  /// Ticked boxes, of [boxes] checkboxes in the whole note.
  final int done;
  final int boxes;
  final Set<NoteMedia> media;

  static final _read = Expando<(CalcEngine?, NoteGlance)>();
  static final _amount = RegExp(
    r'^\p{Sc}?\s?-?\d[\d,]*(\.\d+)?$',
    unicode: true,
  );
  static final _marks = RegExp(r'^(#{1,6}\s*|[☐☑•]\s*)');

  static NoteGlance of(Note note, CalcEngine? engine) {
    final cached = _read[note];
    if (cached != null && identical(cached.$1, engine)) return cached.$2;
    final lines = note.body.split('\n');
    var titled = false;
    int? at;
    var done = 0;
    var boxes = 0;
    for (var i = 0; i < lines.length; i++) {
      final text = lines[i]
          .replaceAll(NoteAttachmentRef.placeholder, '')
          .trim();
      if (text.startsWith('☑')) done++;
      if (text.startsWith('☐') || text.startsWith('☑')) boxes++;
      if (text.isEmpty) continue;
      if (titled) {
        at ??= i;
      } else {
        titled = true;
      }
    }
    final glance = NoteGlance._(
      line: at == null
          ? null
          : lines[at]
                .replaceAll(NoteAttachmentRef.placeholder, '')
                .trim()
                .replaceFirst(_marks, ''),
      result: at == null || engine == null
          ? null
          : engine.evaluateDocument(lines.take(at + 1).join('\n'))[at]?.text,
      done: done,
      boxes: boxes,
      media: NoteMedia.inNote(note),
    );
    _read[note] = (engine, glance);
    return glance;
  }

  /// The line a list row gives the note: how far its checklist has got, then
  /// its first line, with the answer when that line is a sum.
  String get summary {
    final line = this.line;
    final result = this.result;
    final said = line == null
        ? null
        : result == null
        ? line
        : '${line.split('=').first.trim()} = $result';
    return [if (boxes > 0) '$done of $boxes done', ?said].join(' · ');
  }
}

/// Which sticky note a card is drawn on, and how far it leans. Both follow
/// the moment the note was made rather than its place in the list, so a card
/// keeps its colour as the list reorders around it, and on every device.
int _stickySeed(Note note) =>
    (note.createdAt.millisecondsSinceEpoch ~/ 1000 * 2654435761) & 0x7fffffff;

const _stickyTilts = [-1.2, 1.0, 0.8, -0.8, -0.6, 1.1, 0.9, -1.1, -0.9, 0.7];

Color stickyTint(CalcPalette palette, Note note) => [
  palette.stickyMustard,
  palette.stickyTeal,
  palette.stickyOlive,
  palette.stickyRust,
][_stickySeed(note) % 4];

double _stickyTilt(Note note) =>
    _stickyTilts[_stickySeed(note) ~/ 4 % _stickyTilts.length] * math.pi / 180;

const _cardRadius = BorderRadius.only(
  topLeft: Radius.circular(6),
  topRight: Radius.circular(6),
  bottomLeft: Radius.circular(6),
  bottomRight: Radius.circular(14),
);

List<BoxShadow> _cardShadow(CalcPalette palette) => [
  BoxShadow(color: palette.shadowAt(0x33), offset: const Offset(0, 1)),
  BoxShadow(
    color: palette.shadowAt(0x73),
    offset: Offset(0, 8),
    blurRadius: 14,
    spreadRadius: -10,
  ),
];

TextStyle _handwritten(
  double size,
  double line,
  FontWeight weight,
  Color color,
) {
  const face = WritingFont.handwritten;
  return TextStyle(
    fontFamily: face.fontFamily,
    fontFamilyFallback: face.fontFamilyFallback,
    fontVariations: face.fontVariations,
    fontSize: size,
    height: line / size,
    leadingDistribution: TextLeadingDistribution.even,
    fontWeight: weight,
    color: color,
  );
}

TextStyle _figtree(double size, double line, FontWeight weight, Color color) =>
    TextStyle(
      fontSize: size,
      height: line / size,
      leadingDistribution: TextLeadingDistribution.even,
      fontWeight: weight,
      color: color,
    );

/// The small icons a card or row carries before its date: the media in the
/// note, then whether it is read-only or shared.
List<KapyIconData> _marksOf(
  Set<NoteMedia> media, {
  required bool locked,
  required bool shared,
}) => [
  for (final kind in NoteMedia.values.reversed)
    if (media.contains(kind)) kind.icon,
  if (locked) KapyIcons.lockRounded,
  if (shared) KapyIcons.peopleOutlined,
];

Border? _cardBorder(
  CalcPalette palette, {
  required bool selected,
  required bool ringed,
  Color? resting,
}) => selected
    ? Border.all(color: palette.selectedBorder, width: 1.5)
    : ringed
    ? Border.all(
        color: palette.selectedBorder.withValues(alpha: 0.5),
        width: 1.5,
      )
    : resting == null
    ? null
    : Border.all(color: resting);

/// A tick box: the media menu's, and a note's while the archive is picking
/// notes.
class _PickBox extends StatelessWidget {
  const _PickBox({required this.checked});

  final bool checked;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: checked ? palette.selectedBorder : null,
        border: checked
            ? null
            : Border.all(color: palette.textTertiary, width: 1.5),
        borderRadius: BorderRadius.circular(4.5),
      ),
      child: checked
          ? KapyIcon(
              KapyIcons.checkRounded,
              size: 11,
              strokeWidth: 2.6,
              color: palette.sidebarBackground,
            )
          : null,
    );
  }
}

/// A note as a sticky card: its title in the handwriting face, a line of it
/// or how far its checklist has got, and when it was last changed.
class NoteCardFace extends StatelessWidget {
  const NoteCardFace({
    super.key,
    required this.note,
    required this.glance,
    required this.date,
    required this.selected,
    required this.hovering,
    this.snippet,
    this.ringed = false,
    this.locked = false,
    this.shared = false,
    this.picking,
  });

  static const double height = 84;

  final Note note;
  final NoteGlance glance;

  /// When it was changed, or who is in it right now.
  final String date;

  /// The line a search matched, in place of the card's own preview.
  final String? snippet;
  final bool selected;
  final bool hovering;

  /// Open in another pane.
  final bool ringed;
  final bool locked;
  final bool shared;

  /// Ticked or not while the archive is picking notes; null otherwise.
  final bool? picking;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final blank = note.isEmpty;
    final title = _handwritten(14, 18, FontWeight.w500, palette.cardTitle);
    final glance = this.glance;
    final result = snippet == null ? glance.amount ?? glance.result : null;
    final preview =
        snippet ??
        (blank ? 'Empty' : glance.line ?? (note.isDrawing ? 'Sketch' : null));
    final marks = _marksOf(glance.media, locked: locked, shared: shared);
    final tint = blank ? palette.surfaceBackground : stickyTint(palette, note);
    final picking = this.picking;

    return Transform.rotate(
      angle: _stickyTilt(note),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 11, 12, 10),
        decoration: BoxDecoration(
          color: hovering
              ? Color.alphaBlend(
                  palette.textPrimary.withValues(alpha: 0.04),
                  tint,
                )
              : tint,
          borderRadius: _cardRadius,
          border: _cardBorder(
            palette,
            selected: selected || picking == true,
            ringed: ringed,
            resting: blank ? palette.separator : null,
          ),
          boxShadow: _cardShadow(palette),
        ),
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The title takes two lines where it needs them and the card
                // has room, and a line of the note follows only under a title
                // that fits on one. Anything a larger text size pushes past
                // the card is cut at its edge rather than overflowing it.
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final heading = note.title;
                      final scaler = MediaQuery.textScalerOf(context);
                      final painter = TextPainter(
                        text: TextSpan(text: heading, style: title),
                        textDirection: Directionality.of(context),
                        textScaler: scaler,
                        maxLines: 1,
                      )..layout(maxWidth: constraints.maxWidth);
                      final oneLine = !painter.didExceedMaxLines;
                      painter.dispose();
                      final roomy =
                          constraints.maxHeight >= scaler.scale(18 + 3 + 15);
                      return ClipRect(
                        child: OverflowBox(
                          alignment: Alignment.topLeft,
                          maxHeight: double.infinity,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                heading,
                                maxLines:
                                    constraints.maxHeight >=
                                        scaler.scale(36 + 6)
                                    ? 2
                                    : 1,
                                overflow: TextOverflow.ellipsis,
                                style: title,
                              ),
                              if (oneLine && roomy && glance.boxes == 0) ...[
                                if (result != null || preview != null)
                                  const SizedBox(height: 3),
                                if (result != null)
                                  Text(
                                    result,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontFamily: AppFonts.mono,
                                      fontFamilyFallback: AppFonts.monoFallback,
                                      fontSize: 12,
                                      height: 15 / 12,
                                      leadingDistribution:
                                          TextLeadingDistribution.even,
                                      fontWeight: FontWeight.w600,
                                      color: palette.resultPillText,
                                    ),
                                  )
                                else if (preview != null)
                                  Text(
                                    preview,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: _figtree(
                                      AppTypeScale.caption,
                                      15,
                                      FontWeight.w500,
                                      blank
                                          ? palette.textTertiary
                                          : palette.textMuted,
                                    ),
                                  ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                Row(
                  children: [
                    if (glance.boxes > 0) ...[
                      ChecklistPie(
                        done: glance.done,
                        total: glance.boxes,
                        fill: palette.selectedBorder,
                        check: tint,
                        size: 12,
                      ),
                      const SizedBox(width: 6),
                    ],
                    for (final mark in marks) ...[
                      KapyIcon(
                        mark,
                        size: 13,
                        strokeWidth: 1.8,
                        color: palette.textMuted,
                      ),
                      const SizedBox(width: 5),
                    ],
                    Flexible(
                      child: Text(
                        date,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _figtree(
                          AppTypeScale.caption,
                          14,
                          FontWeight.w600,
                          palette.textMuted,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            if (picking != null)
              Positioned(top: 0, right: 0, child: _PickBox(checked: picking)),
          ],
        ),
      ),
    );
  }
}

/// A note as a row: its title and date, then its media and a line of it.
class NoteListRowFace extends StatelessWidget {
  const NoteListRowFace({
    super.key,
    required this.note,
    required this.glance,
    required this.date,
    required this.selected,
    required this.hovering,
    this.snippet,
    this.ringed = false,
    this.locked = false,
    this.shared = false,
    this.picking,
  });

  final Note note;
  final NoteGlance glance;
  final String date;
  final String? snippet;
  final bool selected;
  final bool hovering;
  final bool ringed;
  final bool locked;
  final bool shared;
  final bool? picking;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final marks = _marksOf(glance.media, locked: locked, shared: shared);
    final summary = snippet ?? (note.isEmpty ? 'Empty' : glance.summary);
    final picking = this.picking;
    final marked = selected || picking == true;
    // The border is always there, clear until the row is open or ringed, so
    // opening a note does not nudge its text.
    return Container(
      padding: const EdgeInsets.all(6.5),
      decoration: BoxDecoration(
        color: marked
            ? stickyTint(palette, note)
            : hovering
            ? palette.hover
            : null,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: marked
              ? palette.selectedBorder
              : ringed
              ? palette.selectedBorder.withValues(alpha: 0.5)
              : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: Row(
        children: [
          if (picking != null) ...[
            _PickBox(checked: picking),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        note.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _figtree(
                          14,
                          18,
                          FontWeight.w600,
                          palette.cardTitle,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      date,
                      maxLines: 1,
                      style: _figtree(
                        AppTypeScale.small,
                        16,
                        FontWeight.w500,
                        palette.textTertiary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    for (final mark in marks) ...[
                      KapyIcon(
                        mark,
                        size: 13,
                        strokeWidth: 1.8,
                        color: palette.textMuted,
                      ),
                      const SizedBox(width: 5),
                    ],
                    Expanded(
                      child: Text(
                        summary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _figtree(
                          AppTypeScale.body,
                          16,
                          FontWeight.w400,
                          note.isEmpty
                              ? palette.textTertiary
                              : palette.textMuted,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A drawing shrunk to fit a card or a row, centred, in the theme's ink.
class DrawingThumbnail extends StatelessWidget {
  const DrawingThumbnail({super.key, required this.drawing});

  final NoteDrawing? drawing;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _ThumbnailPainter(
      elements: drawing?.elements ?? const [],
      ink: context.palette.textPrimary,
      textStyle: Theme.of(context).textTheme.bodyLarge ?? const TextStyle(),
    ),
    child: const SizedBox.expand(),
  );
}

class _ThumbnailPainter extends CustomPainter {
  _ThumbnailPainter({
    required this.elements,
    required this.ink,
    required this.textStyle,
  });

  final List<DrawElement> elements;
  final Color ink;
  final TextStyle textStyle;

  static const double _margin = 8;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = drawingBounds(elements);
    if (bounds == null) return;
    final zoom = math.min(
      1.0,
      math.min(
        (size.width - _margin * 2) / math.max(bounds.width, 1),
        (size.height - _margin * 2) / math.max(bounds.height, 1),
      ),
    );
    canvas.clipRect(Offset.zero & size);
    DrawingPainter(
      elements: elements,
      hidden: const {},
      extra: const [],
      selection: const [],
      marquee: null,
      pan: size.center(Offset.zero) - bounds.center * zoom,
      zoom: zoom,
      ink: ink,
      grid: const Color(0x00000000),
      accent: ink,
      textStyle: textStyle,
    ).paint(canvas, size);
  }

  @override
  bool shouldRepaint(_ThumbnailPainter old) =>
      !identical(old.elements, elements) ||
      old.ink != ink ||
      old.textStyle != textStyle;
}

/// A drawing as a card in the Drawings space: a thumbnail of it on the
/// paper, its title in the handwriting face, and when it was last changed.
class DrawingCardFace extends StatelessWidget {
  const DrawingCardFace({
    super.key,
    required this.note,
    required this.date,
    required this.selected,
    required this.hovering,
    this.ringed = false,
    this.locked = false,
    this.shared = false,
    this.picking,
  });

  static const double height = 148;

  final Note note;
  final String date;
  final bool selected;
  final bool hovering;
  final bool ringed;
  final bool locked;
  final bool shared;
  final bool? picking;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final picking = this.picking;
    final marks = _marksOf(const {}, locked: locked, shared: shared);
    return Transform.rotate(
      angle: _stickyTilt(note),
      child: Container(
        padding: const EdgeInsets.fromLTRB(6, 6, 6, 10),
        decoration: BoxDecoration(
          color: hovering
              ? Color.alphaBlend(
                  palette.textPrimary.withValues(alpha: 0.04),
                  palette.editorBackground,
                )
              : palette.editorBackground,
          borderRadius: _cardRadius,
          border: _cardBorder(
            palette,
            selected: selected || picking == true,
            ringed: ringed,
            resting: palette.separator,
          ),
          boxShadow: _cardShadow(palette),
        ),
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: ColoredBox(
                      color: palette.sidebarBackground,
                      child: DrawingThumbnail(drawing: note.drawing),
                    ),
                  ),
                ),
                const SizedBox(height: 7),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        note.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _handwritten(
                          14,
                          18,
                          FontWeight.w500,
                          palette.cardTitle,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          for (final mark in marks) ...[
                            KapyIcon(
                              mark,
                              size: 13,
                              strokeWidth: 1.8,
                              color: palette.textMuted,
                            ),
                            const SizedBox(width: 5),
                          ],
                          Flexible(
                            child: Text(
                              date,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: _figtree(
                                AppTypeScale.caption,
                                14,
                                FontWeight.w600,
                                palette.textMuted,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (picking != null)
              Positioned(top: 4, right: 4, child: _PickBox(checked: picking)),
          ],
        ),
      ),
    );
  }
}

/// A drawing as a row in the Drawings space: a small thumbnail of it, then
/// its title over when it was last changed.
class DrawingListRowFace extends StatelessWidget {
  const DrawingListRowFace({
    super.key,
    required this.note,
    required this.date,
    required this.selected,
    required this.hovering,
    this.ringed = false,
    this.locked = false,
    this.shared = false,
    this.picking,
  });

  final Note note;
  final String date;
  final bool selected;
  final bool hovering;
  final bool ringed;
  final bool locked;
  final bool shared;
  final bool? picking;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final picking = this.picking;
    final marked = selected || picking == true;
    final marks = _marksOf(const {}, locked: locked, shared: shared);
    return Container(
      padding: const EdgeInsets.all(6.5),
      decoration: BoxDecoration(
        color: marked
            ? palette.editorBackground
            : hovering
            ? palette.hover
            : null,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: marked
              ? palette.selectedBorder
              : ringed
              ? palette.selectedBorder.withValues(alpha: 0.5)
              : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: Row(
        children: [
          if (picking != null) ...[
            _PickBox(checked: picking),
            const SizedBox(width: 10),
          ],
          Container(
            width: 56,
            height: 40,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: palette.editorBackground,
              border: Border.all(color: palette.separator),
              borderRadius: BorderRadius.circular(6),
            ),
            child: DrawingThumbnail(drawing: note.drawing),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  note.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _figtree(14, 18, FontWeight.w600, palette.cardTitle),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    for (final mark in marks) ...[
                      KapyIcon(
                        mark,
                        size: 13,
                        strokeWidth: 1.8,
                        color: palette.textMuted,
                      ),
                      const SizedBox(width: 5),
                    ],
                    Flexible(
                      child: Text(
                        date,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _figtree(
                          AppTypeScale.small,
                          16,
                          FontWeight.w500,
                          palette.textTertiary,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The heading over a group of notes: Pinned or Notes, with how many there
/// are, and whatever the group offers at its far end.
class NotesListHeading extends StatelessWidget {
  const NotesListHeading({
    super.key,
    required this.label,
    required this.count,
    this.noun = 'note',
    this.height = 24,
    this.leading,
    this.trailing,
  });

  final String label;
  final int count;

  /// What the list holds, for the count's spoken form: "3 drawings".
  final String noun;
  final double height;
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return SizedBox(
      height: height,
      child: Row(
        children: [
          if (leading case final leading?) ...[
            leading,
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Semantics(
                    header: true,
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _handwritten(
                        14,
                        20,
                        FontWeight.w600,
                        palette.textSubheading,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 7),
                Tooltip(
                  message: count == 1 ? '1 $noun' : '$count ${noun}s',
                  child: Text(
                    '$count',
                    style:
                        _figtree(
                          AppTypeScale.small,
                          16,
                          FontWeight.w600,
                          palette.textTertiary,
                        ).copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                  ),
                ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// "See all", at the end of the Pinned heading.
class SeeAllLink extends StatelessWidget {
  const SeeAllLink({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      container: true,
      button: true,
      label: 'See all pinned notes',
      excludeSemantics: true,
      onTap: onPressed,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onPressed,
          behavior: HitTestBehavior.opaque,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'See all',
                style: _figtree(
                  AppTypeScale.small,
                  16,
                  FontWeight.w600,
                  palette.accentText,
                ),
              ),
              const SizedBox(width: 1),
              KapyIcon(
                KapyIcons.chevronRightRounded,
                size: 13,
                strokeWidth: 2,
                color: palette.accentText,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Which notes the list shows: the notes filter's first group. Hidden Notes
/// and the archive are not places on the rail but this choice, so they combine
/// with the media ticks and keep the space the list is in.
enum NotesShow {
  all,
  hidden,
  archive;

  String get label => switch (this) {
    NotesShow.all => 'All notes',
    NotesShow.hidden => 'Hidden',
    NotesShow.archive => 'Archive',
  };
}

/// The notes filter and the list/cards switch, on one row under the search,
/// with the ✕ that clears the filter while anything is narrowed.
class NotesListControls extends StatelessWidget {
  const NotesListControls({
    super.key,
    required this.show,
    this.offersShow = true,
    required this.onShowChanged,
    required this.hiddenListed,
    this.hiddenShortcut,
    required this.archivedCount,
    this.media,
    this.onMediaChanged,
    required this.onClear,
    required this.cards,
    required this.onCardsChanged,
  });

  final NotesShow show;

  /// Whether the menu starts with the choice of which notes. Shared leaves it
  /// out: Hidden Notes are only ever the person's own, and the archive is
  /// one place for every note filed away.
  final bool offersShow;
  final ValueChanged<NotesShow> onShowChanged;

  /// Whether the menu offers Hidden: while the setting that lists it is on
  /// and something is in it, and whenever the list is showing it.
  final bool hiddenListed;

  /// The chord that opens Hidden, named on its row.
  final String? hiddenShortcut;
  final int archivedCount;

  /// The kinds the list is narrowed to, every kind when it is not. Null
  /// leaves the media group out, as in Drawings, where every item is a
  /// drawing.
  final Set<NoteMedia>? media;
  final ValueChanged<Set<NoteMedia>>? onMediaChanged;

  /// Back to every note: All notes, every kind ticked.
  final VoidCallback onClear;
  final bool cards;
  final ValueChanged<bool> onCardsChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    Widget segment(bool forCards) {
      final on = cards == forCards;
      return Tooltip(
        message: forCards ? 'Card view' : 'List view',
        child: Semantics(
          button: true,
          selected: on,
          label: forCards ? 'Cards' : 'List',
          excludeSemantics: true,
          onTap: on ? null : () => onCardsChanged(forCards),
          child: MouseRegion(
            cursor: on ? MouseCursor.defer : SystemMouseCursors.click,
            child: GestureDetector(
              key: ValueKey(
                forCards ? 'sidebar-view-cards' : 'sidebar-view-list',
              ),
              onTap: on ? null : () => onCardsChanged(forCards),
              child: Container(
                width: 26,
                height: 24,
                decoration: on
                    ? BoxDecoration(
                        color: palette.selectedBackground,
                        borderRadius: BorderRadius.circular(7),
                        boxShadow: [
                          BoxShadow(
                            color: palette.shadowAt(0x4D),
                            offset: Offset(0, 1),
                            blurRadius: 2,
                          ),
                        ],
                      )
                    : null,
                alignment: Alignment.center,
                child: KapyIcon(
                  forCards
                      ? KapyIcons.gridViewRounded
                      : KapyIcons.listViewRounded,
                  size: 14,
                  strokeWidth: 1.8,
                  color: on ? palette.textPrimary : palette.textTertiary,
                ),
              ),
            ),
          ),
        ),
      );
    }

    final media = this.media;
    final everything = media == null ? 'All drawings' : NotesShow.all.label;
    final narrowed =
        show != NotesShow.all ||
        (media != null && media.length < NoteMedia.values.length);
    return Row(
      children: [
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: _NotesFilter(
                  show: show,
                  offersShow: offersShow,
                  onShowChanged: onShowChanged,
                  hiddenListed: hiddenListed,
                  hiddenShortcut: hiddenShortcut,
                  archivedCount: archivedCount,
                  media: media,
                  onMediaChanged: onMediaChanged,
                  everything: everything,
                  narrowed: narrowed,
                ),
              ),
              if (narrowed) ...[
                const SizedBox(width: 4),
                CompactIconButton(
                  key: const ValueKey('sidebar-filter-clear'),
                  tooltip: 'Back to $everything',
                  extent: 28,
                  foregroundColor: palette.textSecondary,
                  onPressed: onClear,
                  icon: const KapyIcon(
                    KapyIcons.closeRounded,
                    size: 14,
                    strokeWidth: 1.8,
                  ),
                ),
              ],
              const SizedBox(width: 4),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: palette.cardBackground,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            children: [segment(false), const SizedBox(width: 2), segment(true)],
          ),
        ),
      ],
    );
  }
}

/// The notes filter's button and menu: one choice of which notes, then the
/// media ticks. Every kind is ticked by default, and unticking kinds narrows
/// the list to notes holding a kind still ticked.
class _NotesFilter extends StatefulWidget {
  const _NotesFilter({
    required this.show,
    required this.offersShow,
    required this.onShowChanged,
    required this.hiddenListed,
    required this.hiddenShortcut,
    required this.archivedCount,
    required this.media,
    required this.onMediaChanged,
    required this.everything,
    required this.narrowed,
  });

  final NotesShow show;
  final bool offersShow;
  final ValueChanged<NotesShow> onShowChanged;
  final bool hiddenListed;
  final String? hiddenShortcut;
  final int archivedCount;
  final Set<NoteMedia>? media;
  final ValueChanged<Set<NoteMedia>>? onMediaChanged;

  /// What the button says while nothing is narrowed.
  final String everything;
  final bool narrowed;

  @override
  State<_NotesFilter> createState() => _NotesFilterState();
}

class _NotesFilterState extends State<_NotesFilter> {
  final _menu = OverlayPortalController();
  final _link = LayerLink();

  void _toggle() => setState(_menu.isShowing ? _menu.hide : _menu.show);

  void _close() {
    if (_menu.isShowing) setState(_menu.hide);
  }

  void _choose(NotesShow show) {
    _close();
    if (show != widget.show) widget.onShowChanged(show);
  }

  /// A kind is unticked only while another stays ticked: a list narrowed to
  /// nothing would look like a library that had lost its notes.
  void _tick(NoteMedia? media) {
    final ticked = widget.media!;
    final onChanged = widget.onMediaChanged!;
    if (media == null) {
      if (ticked.length < NoteMedia.values.length) {
        onChanged(NoteMedia.values.toSet());
      }
      return;
    }
    if (!ticked.contains(media)) {
      onChanged({...ticked, media});
    } else if (ticked.length > 1) {
      onChanged({...ticked}..remove(media));
    }
  }

  /// What the button says: one narrowed group names itself ("Archive",
  /// "Voice, Image"); combined, each gives its first choice and how many
  /// more ("Archive · Voice +1"). Where that runs out of [room], the choice
  /// of notes goes, since the title over the list already names it.
  String _label(TextStyle style, double room) {
    final show = widget.show == NotesShow.all ? null : widget.show.label;
    final ticked = [
      for (final media in NoteMedia.values)
        if (widget.media?.contains(media) ?? false) media.label,
    ];
    if (widget.media == null || ticked.length == NoteMedia.values.length) {
      return show ?? widget.everything;
    }
    if (show == null) return ticked.join(', ');
    final head = ticked.first;
    final more = ticked.length - 1;
    final kinds = more == 0 ? head : '$head +$more';
    final both = '$show · $kinds';
    final painter = TextPainter(
      text: TextSpan(text: both, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout(maxWidth: room);
    final fits = !painter.didExceedMaxLines;
    painter.dispose();
    return fits ? both : kinds;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final open = _menu.isShowing;
    final narrowed = widget.narrowed;
    final style = _figtree(
      AppTypeScale.body,
      16,
      FontWeight.w600,
      narrowed ? palette.tonalForeground : palette.textSubheading,
    );
    final button = LayoutBuilder(
      // A list dragged to its narrowest keeps the filter's icon, which still
      // opens the menu and still turns sage when the list is narrowed.
      builder: (context, constraints) {
        if (constraints.maxWidth < 28) return const SizedBox.shrink();
        final roomy = constraints.maxWidth >= 72;
        // The padding, border, filter icon and chevron around the label.
        const chrome = 9 + 8 + 2 + 14 + 6 + 6 + 13;
        final label = roomy
            ? _label(style, constraints.maxWidth - chrome)
            : widget.everything;
        return Semantics(
          button: true,
          expanded: open,
          label: 'Notes filter, $label',
          excludeSemantics: true,
          onTap: _toggle,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              key: const ValueKey('sidebar-notes-filter'),
              onTap: _toggle,
              behavior: HitTestBehavior.opaque,
              child: Container(
                height: 28,
                padding: roomy
                    ? const EdgeInsets.only(left: 9, right: 8)
                    : const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(
                  color: narrowed
                      ? palette.tonalBackground
                      : palette.controlBackground,
                  border: Border.all(
                    color: open
                        ? palette.selectedBorder
                        : narrowed
                        ? palette.tonalKeyBackground
                        : palette.controlBorder,
                  ),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    KapyIcon(
                      KapyIcons.filterRounded,
                      size: 14,
                      strokeWidth: 1.8,
                      color: narrowed ? style.color : palette.textSecondary,
                    ),
                    if (roomy) ...[
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: style,
                        ),
                      ),
                      const SizedBox(width: 6),
                      KapyIcon(
                        KapyIcons.chevronDownRounded,
                        size: 13,
                        strokeWidth: 2,
                        color: narrowed
                            ? palette.tonalKeyText
                            : palette.textTertiary,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );

    return TapRegion(
      groupId: _menu,
      onTapOutside: (_) => _close(),
      child: CompositedTransformTarget(
        link: _link,
        child: OverlayPortal(
          controller: _menu,
          overlayChildBuilder: (context) => Align(
            alignment: Alignment.topLeft,
            child: CompositedTransformFollower(
              link: _link,
              targetAnchor: Alignment.bottomLeft,
              offset: const Offset(0, 8),
              child: TapRegion(
                groupId: _menu,
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.escape): _close,
                  },
                  child: Focus(
                    autofocus: true,
                    child: _FilterMenu(
                      show: widget.show,
                      offersShow: widget.offersShow,
                      onShow: _choose,
                      hiddenListed: widget.hiddenListed,
                      hiddenShortcut: widget.hiddenShortcut,
                      archivedCount: widget.archivedCount,
                      everything: widget.everything,
                      media: widget.media,
                      onTick: _tick,
                    ),
                  ),
                ),
              ),
            ),
          ),
          child: button,
        ),
      ),
    );
  }
}

class _FilterMenu extends StatelessWidget {
  const _FilterMenu({
    required this.show,
    required this.offersShow,
    required this.onShow,
    required this.hiddenListed,
    required this.hiddenShortcut,
    required this.archivedCount,
    required this.everything,
    required this.media,
    required this.onTick,
  });

  final NotesShow show;
  final bool offersShow;
  final ValueChanged<NotesShow> onShow;
  final bool hiddenListed;
  final String? hiddenShortcut;
  final int archivedCount;
  final String everything;
  final Set<NoteMedia>? media;

  /// Null for All media.
  final ValueChanged<NoteMedia?> onTick;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final media = this.media;
    final hiddenShortcut = this.hiddenShortcut;
    Widget choice(NotesShow choice, KapyIconData icon, {Widget? trailing}) =>
        _ShowMenuRow(
          key: ValueKey('notes-filter-${choice.name}'),
          label: choice == NotesShow.all ? everything : choice.label,
          icon: icon,
          chosen: show == choice,
          trailing: trailing,
          onTap: () => onShow(choice),
        );

    return Container(
      key: const ValueKey('notes-filter-menu'),
      width: 232,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: palette.controlBackground,
        border: Border.all(color: palette.separator),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: palette.shadowAt(0x80),
            offset: Offset(0, 12),
            blurRadius: 28,
            spreadRadius: -14,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (offersShow) ...[
            choice(
              NotesShow.all,
              media == null ? KapyIcons.penRounded : KapyIcons.noteOutlined,
            ),
            if (hiddenListed) ...[
              const SizedBox(height: 1),
              choice(
                NotesShow.hidden,
                hiddenIcon,
                trailing: hiddenShortcut == null
                    ? null
                    : Text(
                        hiddenShortcut,
                        style: TextStyle(
                          fontFamily: AppFonts.mono,
                          fontFamilyFallback: AppFonts.monoFallback,
                          fontSize: 11,
                          height: 14 / 11,
                          color: palette.textTertiary,
                        ),
                      ),
              ),
            ],
            const SizedBox(height: 1),
            choice(
              NotesShow.archive,
              archiveIcon,
              trailing: Text(
                '$archivedCount',
                style: _figtree(
                  AppTypeScale.small,
                  16,
                  FontWeight.w400,
                  palette.textTertiary,
                ),
              ),
            ),
          ],
          if (media != null) ...[
            if (offersShow)
              Container(
                height: 1,
                margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                color: palette.separator,
              ),
            _MediaMenuRow(
              key: const ValueKey('media-filter-all'),
              label: 'All media',
              ticked: media.length == NoteMedia.values.length,
              onTap: () => onTick(null),
            ),
            for (final kind in NoteMedia.values) ...[
              const SizedBox(height: 1),
              _MediaMenuRow(
                key: ValueKey('media-filter-${kind.name}'),
                label: kind.label,
                icon: kind.icon,
                ticked: media.contains(kind),
                onTap: () => onTick(kind),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// One of the menu's single choice of which notes: the chosen one lit, with
/// a tick where the others show their shortcut or count.
class _ShowMenuRow extends StatefulWidget {
  const _ShowMenuRow({
    super.key,
    required this.label,
    required this.icon,
    required this.chosen,
    required this.onTap,
    this.trailing,
  });

  final String label;
  final KapyIconData icon;
  final bool chosen;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  State<_ShowMenuRow> createState() => _ShowMenuRowState();
}

class _ShowMenuRowState extends State<_ShowMenuRow> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final chosen = widget.chosen;
    final trailing = chosen
        ? KapyIcon(
            KapyIcons.checkRounded,
            size: 14,
            strokeWidth: 1.8,
            color: palette.accentText,
          )
        : widget.trailing;
    return Semantics(
      selected: chosen,
      button: true,
      label: widget.label,
      excludeSemantics: true,
      onTap: widget.onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: chosen
                  ? palette.separator
                  : _hovering
                  ? palette.hover
                  : null,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Row(
              children: [
                KapyIcon(
                  widget.icon,
                  size: 15,
                  strokeWidth: 1.8,
                  color: chosen ? palette.textPrimary : palette.textSecondary,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _figtree(
                      AppTypeScale.control,
                      16,
                      chosen ? FontWeight.w600 : FontWeight.w500,
                      chosen ? palette.textPrimary : palette.textSubheading,
                    ),
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 9), trailing],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MediaMenuRow extends StatefulWidget {
  const _MediaMenuRow({
    super.key,
    required this.label,
    required this.ticked,
    required this.onTap,
    this.icon,
  });

  final String label;
  final KapyIconData? icon;
  final bool ticked;
  final VoidCallback onTap;

  @override
  State<_MediaMenuRow> createState() => _MediaMenuRowState();
}

class _MediaMenuRowState extends State<_MediaMenuRow> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final icon = widget.icon;
    return Semantics(
      checked: widget.ticked,
      label: widget.label,
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: _hovering ? palette.hover : null,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Row(
              children: [
                _PickBox(checked: widget.ticked),
                const SizedBox(width: 9),
                if (icon != null) ...[
                  KapyIcon(
                    icon,
                    size: 15,
                    strokeWidth: 1.8,
                    color: palette.textSecondary,
                  ),
                  const SizedBox(width: 9),
                ],
                Text(
                  widget.label,
                  style: _figtree(
                    AppTypeScale.control,
                    16,
                    FontWeight.w500,
                    palette.textSubheading,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
