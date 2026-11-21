import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../calc/engine.dart';
import '../core/editor_font.dart';
import '../core/platform.dart';
import '../core/theme.dart';
import '../data/layout_prefs.dart' show NotesGrouping;
import '../data/note.dart';
import '../data/note_attachment.dart';
import '../data/note_drawing.dart';
import '../data/tags.dart';
import 'checklist_pie.dart';
import 'compact_icon_button.dart';
import 'draw/drawing_geometry.dart';
import 'draw/drawing_painter.dart';
import 'notes_grouping.dart';
import 'sidebar.dart' show archiveIcon, hiddenIcon;
import 'tag_colours.dart';
import 'tag_ui.dart';

/// What a note can hold besides words, in the order the media filter lists
/// them.
enum NoteMedia {
  voice('Voice', KapyIcons.micRounded),
  video('Video', KapyIcons.videoOutlined),
  image('Image', KapyIcons.photoLibraryOutlined);

  const NoteMedia(this.label, this.icon);

  final String label;
  final KapyIconData icon;

  static Set<NoteMedia> inNote(Note note) => {
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
          : engine
                .evaluateDocument(
                  lines.take(at + 1).join('\n'),
                  titled: true,
                )[at]
                ?.text,
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

/// How far the open note's card leans; every other card sits straight.
const _selectedTilt = -math.pi / 180;

const _cardRadius = BorderRadius.only(
  topLeft: Radius.circular(AppRadii.compact),
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
  return chromeStyle(
    size: size,
    line: line,
    weight: AppWeight.axisOf(weight),
    color: color,
    family: face.fontFamily,
    fallback: face.fontFamilyFallback,
    extra: face.faceVariations,
  );
}

TextStyle _figtree(double size, double line, FontWeight weight, Color color) =>
    chromeStyle(
      size: size,
      line: line,
      weight: AppWeight.axisOf(weight),
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
  if (shared) KapyIcons.groupOutlined,
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

/// A tick box: the media menu's, and a note's while notes are being picked.
class _PickBox extends StatelessWidget {
  const _PickBox({required this.checked});

  /// Its side, which a card's title leaves room for.
  static const double size = 16;

  final bool checked;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: checked ? palette.selectedBorder : null,
        border: checked
            ? null
            : Border.all(color: palette.textTertiary, width: 1.5),
        borderRadius: BorderRadius.circular(AppRadii.small),
      ),
      child: checked
          ? KapyIcon(
              KapyIcons.checkRounded,
              size: 11,
              color: palette.sidebarBackground,
            )
          : null,
    );
  }
}

/// A note as a card of three fixed lines: its title in the handwriting face,
/// a line of it, and the meta row. It sits on its first tag's colour, or on
/// the plain card when it has none.
class NoteCardFace extends StatelessWidget {
  const NoteCardFace({
    super.key,
    required this.note,
    required this.glance,
    required this.date,
    required this.selected,
    required this.hovering,
    this.day,
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

  /// [date] without its time of day, for a meta row short of room.
  final String? day;

  /// The line a search matched, in place of the card's own text.
  final String? snippet;
  final bool selected;
  final bool hovering;

  /// Open in another pane.
  final bool ringed;
  final bool locked;
  final bool shared;

  /// Ticked or not while notes are being picked; null otherwise.
  final bool? picking;

  /// What a card with no line of text says instead, by what the note holds.
  String get _noText {
    final media = glance.media;
    if (note.isEmpty) return 'No text yet';
    if (note.isDrawing) return 'Drawing';
    if (media.contains(NoteMedia.voice)) return 'Voice note';
    if (media.contains(NoteMedia.image)) return 'Image';
    if (media.contains(NoteMedia.video)) return 'Video';
    return 'No text yet';
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final tags = TagMarks.of(context, note.id);
    final colour = tags.firstOrNull?.colour;
    final tint = colour?.card(palette) ?? palette.surfaceBackground;
    final glance = this.glance;
    final result = snippet == null ? glance.amount ?? glance.result : null;
    final text = snippet ?? glance.line;
    final picking = this.picking;
    final types = [
      for (final kind in NoteMedia.values.reversed)
        if (glance.media.contains(kind)) kind.icon,
    ].take(2).toList();

    final card = Container(
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
          resting: colour == null ? palette.separator : null,
        ),
        boxShadow: _cardShadow(palette),
      ),
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Anything a larger text size pushes past the card is cut at
              // its edge, so the meta row always keeps its place at the foot.
              Expanded(
                child: ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.topLeft,
                    maxHeight: double.infinity,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: EdgeInsets.only(
                            right: picking == null ? 0 : _PickBox.size + 6,
                          ),
                          child: Text(
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
                        ),
                        const SizedBox(height: 3),
                        Text(
                          result ?? text ?? _noText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: result != null
                              ? TextStyle(
                                  fontFamily: AppFonts.mono,
                                  fontFamilyFallback: AppFonts.monoFallback,
                                  fontSize: 12,
                                  height: 15 / 12,
                                  leadingDistribution:
                                      TextLeadingDistribution.even,
                                  fontWeight: FontWeight.w500,
                                  color: palette.resultPillText,
                                )
                              : _figtree(
                                  12,
                                  15,
                                  FontWeight.w400,
                                  palette.textMuted,
                                ).copyWith(
                                  fontStyle: text == null
                                      ? FontStyle.italic
                                      : null,
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              _MetaRow(
                date: date,
                day: day,
                done: glance.done,
                boxes: glance.boxes,
                types: types,
                locked: locked,
                shared: shared,
                tags: tags,
                ground: tint,
              ),
            ],
          ),
          if (picking != null)
            Positioned(top: 0, right: 0, child: _PickBox(checked: picking)),
        ],
      ),
    );
    return selected
        ? Transform.rotate(angle: _selectedTilt, child: card)
        : card;
  }
}

/// A card's last line, in the date's quiet style: the checklist's pie and
/// the date on the left; the note's type glyphs, then its first tag's dot
/// and name, on the right, with its other tags as dots behind the first.
///
/// Short of room it drops the tag's name, then the time, then the second
/// type glyph, and only then cuts the date short.
class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.date,
    required this.day,
    required this.types,
    required this.locked,
    required this.shared,
    required this.tags,
    required this.ground,
    this.done = 0,
    this.boxes = 0,
  });

  final String date;
  final String? day;
  final int done;
  final int boxes;

  /// Up to two glyphs for what the note holds besides words.
  final List<KapyIconData> types;
  final bool locked;
  final bool shared;
  final List<TagMark> tags;
  final Color ground;

  static const double _glyph = 13;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final style = DefaultTextStyle.of(
      context,
    ).style.merge(_figtree(12, 16, FontWeight.w500, palette.textMuted));
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final first = tags.firstOrNull;
    final flags = [
      if (locked) KapyIcons.lockRounded,
      if (shared) KapyIcons.groupOutlined,
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        double widthOf(String text) {
          final painter = TextPainter(
            text: TextSpan(text: text, style: style),
            textDirection: direction,
            textScaler: scaler,
            maxLines: 1,
          )..layout();
          final width = painter.width;
          painter.dispose();
          return width;
        }

        var named = first != null;
        var when = date;
        var shown = types;
        bool fits() {
          final glyphs = shown.length + flags.length;
          final parts = [
            if (glyphs > 0) glyphs * _glyph + (glyphs - 1) * 4,
            if (first != null)
              TagDots.widthFor(tags.length) +
                  (named ? 4 + widthOf(first.name) : 0),
          ];
          final right = parts.isEmpty
              ? 0
              : parts.reduce((a, b) => a + b) + (parts.length - 1) * 4 + 8;
          return (boxes > 0 ? 12 + 5 : 0) + widthOf(when) + right <=
              constraints.maxWidth;
        }

        if (named && !fits()) named = false;
        if (day != null && !fits()) when = day!;
        if (shown.length > 1 && !fits()) shown = shown.take(1).toList();

        final right = [
          for (final glyph in [...shown, ...flags])
            KapyIcon(glyph, size: _glyph, color: palette.textMuted),
          if (first != null)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TagDots(tags: tags, ground: ground),
                if (named) ...[
                  const SizedBox(width: 4),
                  Text(first.name, maxLines: 1, style: style),
                ],
              ],
            ),
        ];
        return Row(
          children: [
            if (boxes > 0) ...[
              ChecklistPie(
                done: done,
                total: boxes,
                fill: palette.textMuted,
                check: ground,
                size: 12,
              ),
              const SizedBox(width: 5),
            ],
            Expanded(
              child: Text(
                when,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
            if (right.isNotEmpty) ...[
              const SizedBox(width: 8),
              for (final (index, part) in right.indexed) ...[
                if (index > 0) const SizedBox(width: 4),
                part,
              ],
            ],
          ],
        );
      },
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
    this.place,
    this.people,
    this.ringed = false,
    this.locked = false,
    this.shared = false,
    this.picking,
    this.touch = false,
  });

  final Note note;
  final NoteGlance glance;
  final String date;
  final String? snippet;

  /// The folders the note is in, as "Work › Clients", which start the second
  /// line in the date's quieter ink. Null for a note in no folder.
  final String? place;

  /// Who a shared note is open to, at the end of a phone's last line, in
  /// place of the shared mark.
  final Widget? people;
  final bool selected;
  final bool hovering;
  final bool ringed;
  final bool locked;
  final bool shared;
  final bool? picking;

  /// A phone's row: full width between hairlines, with a larger title.
  final bool touch;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final marks = _marksOf(
      glance.media,
      locked: locked,
      shared: shared && people == null,
    );
    final summary = snippet ?? (note.isEmpty ? 'Empty' : glance.summary);
    final picking = this.picking;
    final marked = selected || picking == true;
    final tagMarks = TagMarks.of(context, note.id);
    final first = tagMarks.firstOrNull;
    final tint = first?.colour?.card(palette) ?? palette.surfaceBackground;
    // The border is always there, clear until the row is open or ringed, so
    // opening a note does not nudge its text.
    return Container(
      padding: touch
          ? const EdgeInsets.symmetric(horizontal: 20, vertical: 12)
          : const EdgeInsets.all(6.5),
      decoration: BoxDecoration(
        color: marked
            ? tint
            : hovering
            ? palette.hover
            : null,
        borderRadius: touch ? null : BorderRadius.circular(AppRadii.surface),
        border: touch
            ? null
            : Border.all(
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
                    // Untagged rows keep the dot's room, so titles line up.
                    // A phone's dots sit in the column after the time.
                    if (!touch) ...[
                      SizedBox(
                        width: TagDots.size,
                        child: first == null
                            ? null
                            : TagDots(
                                tags: [first],
                                ground: marked
                                    ? tint
                                    : palette.sidebarBackground,
                              ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Text(
                        note.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: touch
                            ? _handwritten(
                                18,
                                24,
                                FontWeight.w400,
                                palette.textPrimary,
                              )
                            : _figtree(
                                14,
                                18,
                                FontWeight.w500,
                                palette.cardTitle,
                              ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (touch)
                      // At least as wide as the widest time, so the times line
                      // up down the list, and the tag dots come after the
                      // time rather than leading the title.
                      ConstrainedBox(
                        constraints: const BoxConstraints(minWidth: 72),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Text(
                              date,
                              maxLines: 1,
                              style: _figtree(
                                12.5,
                                16,
                                FontWeight.w400,
                                palette.textTertiary,
                              ),
                            ),
                            if (tagMarks.isNotEmpty) ...[
                              const SizedBox(width: 6),
                              TagDots(
                                tags: tagMarks,
                                ground: marked ? tint : palette.paperColor,
                              ),
                            ],
                          ],
                        ),
                      )
                    else
                      Text(
                        date,
                        maxLines: 1,
                        style: _figtree(
                          AppTypeScale.small,
                          16,
                          FontWeight.w400,
                          palette.textTertiary,
                        ),
                      ),
                  ],
                ),
                SizedBox(height: touch ? 4 : 3),
                Row(
                  children: [
                    if (!touch) const SizedBox(width: TagDots.size + 8),
                    for (final mark in marks) ...[
                      KapyIcon(mark, size: 13, color: palette.textMuted),
                      const SizedBox(width: 5),
                    ],
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            if (place case final place?)
                              TextSpan(
                                text: '$place · ',
                                style: TextStyle(color: palette.textTertiary),
                              ),
                            TextSpan(text: summary),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _figtree(
                          touch ? 13.5 : AppTypeScale.body,
                          touch ? 18 : 16,
                          FontWeight.w400,
                          note.isEmpty
                              ? palette.textTertiary
                              : palette.textMuted,
                        ),
                      ),
                    ),
                    if (people case final people?) ...[
                      const SizedBox(width: 8),
                      people,
                    ],
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

/// A drawing as a card in the Drawings space: a thumbnail of it, its title in
/// the handwriting face, and the meta row with no type glyph, on its first
/// tag's colour or the plain card.
class DrawingCardFace extends StatelessWidget {
  const DrawingCardFace({
    super.key,
    required this.note,
    required this.date,
    required this.selected,
    required this.hovering,
    this.day,
    this.ringed = false,
    this.locked = false,
    this.shared = false,
    this.picking,
  });

  static const double height = 148;

  final Note note;
  final String date;

  /// [date] without its time of day, for a meta row short of room.
  final String? day;
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
    final tags = TagMarks.of(context, note.id);
    final colour = tags.firstOrNull?.colour;
    final tint = colour?.card(palette) ?? palette.editorBackground;
    final card = Container(
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 10),
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
          resting: colour == null ? palette.separator : null,
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
                  borderRadius: BorderRadius.circular(AppRadii.small),
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
                    _MetaRow(
                      date: date,
                      day: day,
                      types: const [],
                      locked: locked,
                      shared: shared,
                      tags: tags,
                      ground: tint,
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
    );
    return selected
        ? Transform.rotate(angle: _selectedTilt, child: card)
        : card;
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
        borderRadius: BorderRadius.circular(AppRadii.surface),
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
              borderRadius: BorderRadius.circular(AppRadii.compact),
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
                  style: _figtree(14, 18, FontWeight.w500, palette.cardTitle),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    for (final mark in marks) ...[
                      KapyIcon(mark, size: 13, color: palette.textMuted),
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
                          FontWeight.w400,
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
            const SizedBox(width: 8),
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
                      style: _figtree(
                        AppTypeScale.body,
                        16,
                        FontWeight.w600,
                        palette.textPrimary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: count == 1 ? '1 $noun' : '$count ${noun}s',
                  child: Text(
                    '$count',
                    style:
                        _figtree(
                          AppTypeScale.small,
                          16,
                          FontWeight.w500,
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
                  FontWeight.w500,
                  palette.accentText,
                ),
              ),
              const SizedBox(width: 1),
              KapyIcon(
                KapyIcons.chevronRightRounded,
                size: 13,
                color: palette.accentText,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The heading over one group of the notes list: a day with its date beside
/// it, a tag or a letter, then a hairline to the edge.
class NotesGroupHeading extends StatelessWidget {
  const NotesGroupHeading({
    super.key,
    required this.label,
    this.detail,
    this.onTap,
    this.folded,
  });

  final String label;
  final String? detail;

  /// Opens or closes the fold this heading names, when it folds.
  final VoidCallback? onTap;

  /// Whether the notes under this heading are folded away: null when the
  /// heading folds nothing.
  final bool? folded;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final heading = SizedBox(
      height: MediaQuery.textScalerOf(context).scale(16),
      child: CustomMultiChildLayout(
        delegate: _GroupHeadingLayout(),
        children: [
          LayoutId(
            id: _GroupHeadingPart.label,
            child: Semantics(
              header: true,
              button: folded != null,
              expanded: folded == null ? null : !folded!,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (folded case final folded?)
                    KapyIcon(
                      folded
                          ? KapyIcons.chevronRightRounded
                          : KapyIcons.chevronDownRounded,
                      size: 12,
                      color: palette.textTertiary,
                    ),
                  if (folded != null) const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _figtree(
                        AppTypeScale.body,
                        16,
                        FontWeight.w600,
                        palette.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (detail case final detail?)
            LayoutId(
              id: _GroupHeadingPart.detail,
              child: Text(
                detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _figtree(
                  AppTypeScale.body,
                  16,
                  FontWeight.w400,
                  palette.textTertiary,
                ),
              ),
            ),
          LayoutId(
            id: _GroupHeadingPart.rule,
            child: ColoredBox(color: palette.separator),
          ),
        ],
      ),
    );
    final onTap = this.onTap;
    if (onTap == null) return heading;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: heading,
    );
  }
}

enum _GroupHeadingPart { label, detail, rule }

/// Lays a group heading out: the label takes up to 200, the date what the
/// label leaves and the hairline the rest, so a narrow list shortens the
/// words.
class _GroupHeadingLayout extends MultiChildLayoutDelegate {
  @override
  void performLayout(Size size) {
    Offset centred(Size child, double x) =>
        Offset(x, (size.height - child.height) / 2);
    BoxConstraints upTo(double width) =>
        BoxConstraints(maxWidth: math.max(0, width), maxHeight: size.height);
    final end = size.width;
    final label = layoutChild(
      _GroupHeadingPart.label,
      upTo(math.min(end, 200)),
    );
    positionChild(_GroupHeadingPart.label, centred(label, 0));
    var start = label.width + 8;
    if (hasChild(_GroupHeadingPart.detail)) {
      final detail = layoutChild(_GroupHeadingPart.detail, upTo(end - start));
      positionChild(_GroupHeadingPart.detail, centred(detail, start));
      start += detail.width + 8;
    }
    layoutChild(
      _GroupHeadingPart.rule,
      BoxConstraints.tightFor(width: math.max(0, end - start), height: 1),
    );
    positionChild(_GroupHeadingPart.rule, Offset(start, (size.height - 1) / 2));
  }

  @override
  bool shouldRelayout(_GroupHeadingLayout oldDelegate) => false;
}

/// "By date ▾", in the list's controls row before the switch: how the notes
/// under Pinned are grouped.
class NotesGroupingMenu extends StatefulWidget {
  const NotesGroupingMenu({
    super.key,
    required this.grouping,
    required this.onChanged,
  });

  final NotesGrouping grouping;
  final ValueChanged<NotesGrouping> onChanged;

  @override
  State<NotesGroupingMenu> createState() => _NotesGroupingMenuState();
}

class _NotesGroupingMenuState extends State<NotesGroupingMenu> {
  final _menu = OverlayPortalController();
  final _link = LayerLink();

  static const double _width = 160;

  /// Whether the menu opens rightwards from the button's left edge, where
  /// the button sits too near the window's left for it to open leftwards
  /// from its right edge, as it does at the end of the row.
  bool _opensRight = false;

  void _toggle() {
    if (!_menu.isShowing) {
      final box = context.findRenderObject() as RenderBox?;
      _opensRight =
          box != null &&
          box.localToGlobal(box.size.topRight(Offset.zero)).dx < _width + 8;
    }
    setState(_menu.isShowing ? _menu.hide : _menu.show);
  }

  void _close() {
    if (_menu.isShowing) setState(_menu.hide);
  }

  void _choose(NotesGrouping grouping) {
    _close();
    if (grouping != widget.grouping) widget.onChanged(grouping);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final color = _menu.isShowing
        ? palette.textSecondary
        : palette.textTertiary;
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
              targetAnchor: _opensRight
                  ? Alignment.bottomLeft
                  : Alignment.bottomRight,
              followerAnchor: _opensRight
                  ? Alignment.topLeft
                  : Alignment.topRight,
              offset: const Offset(0, 8),
              child: TapRegion(
                groupId: _menu,
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.escape): _close,
                  },
                  child: Focus(
                    autofocus: true,
                    child: Container(
                      key: const ValueKey('notes-grouping-menu'),
                      width: _width,
                      padding: const EdgeInsets.all(6),
                      decoration: _menuSurface(palette),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final (index, grouping)
                              in NotesGrouping.values.indexed) ...[
                            if (index > 0) const SizedBox(height: 1),
                            _ShowMenuRow(
                              key: ValueKey('notes-grouping-${grouping.name}'),
                              label: grouping.label,
                              chosen: grouping == widget.grouping,
                              onTap: () => _choose(grouping),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          child: Semantics(
            button: true,
            expanded: _menu.isShowing,
            label: 'Group notes, ${widget.grouping.label}',
            excludeSemantics: true,
            onTap: _toggle,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                key: const ValueKey('notes-grouping'),
                onTap: _toggle,
                behavior: HitTestBehavior.opaque,
                child: SizedBox(
                  height: 28,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.grouping.label,
                        style: _figtree(
                          AppTypeScale.small,
                          16,
                          FontWeight.w500,
                          color,
                        ),
                      ),
                      const SizedBox(width: 4),
                      KapyIcon(
                        KapyIcons.chevronDownRounded,
                        size: 12,
                        color: color,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The ground of the list's menus: the filter's and the grouping's.
BoxDecoration _menuSurface(CalcPalette palette) => BoxDecoration(
  color: palette.controlBackground,
  border: Border.all(color: palette.separator),
  borderRadius: BorderRadius.circular(AppRadii.surface),
  boxShadow: [
    BoxShadow(
      color: palette.shadowAt(0x80),
      offset: const Offset(0, 12),
      blurRadius: 28,
      spreadRadius: -14,
    ),
  ],
);

/// The span When narrows the list to, beside the filter: "This week ×".
/// Pressed, the list reaches back to any time again.
class _WhenChip extends StatelessWidget {
  const _WhenChip({required this.when, required this.onClear});

  final WhenFilter when;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Tooltip(
      message: 'Back to any time',
      child: Semantics(
        button: true,
        label: '${when.label}, back to any time',
        excludeSemantics: true,
        onTap: onClear,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            key: const ValueKey('notes-when-chip'),
            onTap: onClear,
            behavior: HitTestBehavior.opaque,
            child: Container(
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: palette.tonalBackground,
                border: Border.all(color: palette.tonalKeyBackground),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  KapyIcon(
                    KapyIcons.calendarOutlined,
                    size: 16,
                    color: palette.tonalForeground,
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      when.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _figtree(
                        AppTypeScale.body,
                        16,
                        FontWeight.w500,
                        palette.tonalForeground,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  KapyIcon(
                    KapyIcons.closeRounded,
                    size: 12,
                    color: palette.tonalKeyText,
                  ),
                ],
              ),
            ),
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
/// Whether the list is narrowed beyond everything its space holds: another
/// Show, some of the kinds, or a tag. What the filter row says it is doing,
/// and what a phone's filter button carries a dot for while the row is put
/// away.
bool filtersNarrowed({
  required NotesShow show,
  required Set<NoteMedia>? media,
  required TagFilter? tags,
}) =>
    show != NotesShow.all ||
    (media != null && media.length < NoteMedia.values.length) ||
    (tags?.narrowed ?? false);

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
    this.cards = false,
    this.onCardsChanged,
    this.tags,
    this.onTagsChanged,
    this.when,
    this.onWhenChanged,
    required this.today,
    this.weekShown,
    this.grouping,
    this.onGroupingChanged,
    this.alignEnd = false,
    this.phone = false,
  });

  final NotesShow show;

  /// A phone's filter row: a filled pill for the menu, then a pill per tag,
  /// scrolling sideways.
  final bool phone;

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

  /// Null leaves the list/cards switch out, where the list has no cards.
  final ValueChanged<bool>? onCardsChanged;

  /// The tags the list is narrowed to; null where there are no tags.
  final TagFilter? tags;
  final ValueChanged<TagFilter>? onTagsChanged;

  /// What When narrows the list to; null leaves When out of the menu.
  final WhenFilter? when;
  final ValueChanged<WhenFilter>? onWhenChanged;

  /// The day When's spans count back from, as the list shows days.
  final DateTime today;

  /// Whether the page's bar shows the week, for When's menu to point there
  /// for a single day. Asked as the menu opens, since the bar trades the
  /// week for one button where it is short of room.
  final bool Function()? weekShown;

  /// How the list groups what Pinned leaves, and the menu that changes it;
  /// without a grouping there is no menu.
  final NotesGrouping? grouping;
  final ValueChanged<NotesGrouping>? onGroupingChanged;

  /// Whether the filter sits at the row's end beside the switch, as it does
  /// on a folder's page, rather than at its start.
  final bool alignEnd;

  /// The row's narrowest that holds the sort beside the switch: the filter
  /// with its label (72), the sort's longest (64) and the switch (60), with
  /// the gaps between them.
  static const double _sortBesideWidth = 72 + 4 + 64 + 8 + 60;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final onCardsChanged = this.onCardsChanged;
    final onWhenChanged = this.onWhenChanged;
    Widget segment(bool forCards, ValueChanged<bool> onCardsChanged) {
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
                width: 28,
                height: 28,
                decoration: on
                    ? BoxDecoration(
                        color: palette.selectedBackground,
                        borderRadius: BorderRadius.circular(AppRadii.compact),
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
                  size: 16,
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
    final narrowed = filtersNarrowed(show: show, media: media, tags: tags);
    final filter = _NotesFilter(
      show: show,
      offersShow: offersShow,
      onShowChanged: onShowChanged,
      hiddenListed: hiddenListed,
      hiddenShortcut: hiddenShortcut,
      archivedCount: archivedCount,
      media: media,
      onMediaChanged: onMediaChanged,
      tags: tags,
      onTagsChanged: onTagsChanged,
      when: when,
      onWhenChanged: onWhenChanged,
      today: today,
      weekShown: weekShown,
      everything: everything,
      narrowed: narrowed,
      phone: phone,
    );
    if (phone) {
      final tags = this.tags;
      final onTagsChanged = this.onTagsChanged;
      final shelf = tags == null || onTagsChanged == null
          ? null
          : TagShelf.maybeOf(context);
      return SingleChildScrollView(
        key: const ValueKey('phone-filter-row'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          spacing: 8,
          children: [
            filter,
            if (shelf != null)
              for (final entry in shelf.listed())
                _TagPill(
                  tag: entry.tag,
                  on:
                      !tags!.none &&
                      tags.ids.length == 1 &&
                      tags.ids.contains(entry.tag.id),
                  onChanged: (on) => onTagsChanged!(
                    tags.copyWith(ids: on ? {entry.tag.id} : {}, none: false),
                  ),
                ),
          ],
        ),
      );
    }
    final sort = switch ((grouping, onGroupingChanged)) {
      (final grouping?, final onChanged?) => NotesGroupingMenu(
        grouping: grouping,
        onChanged: onChanged,
      ),
      _ => null,
    };
    return LayoutBuilder(
      builder: (context, constraints) {
        // Too narrow to keep the filter's label beside the sort and the
        // switch, the row puts the sort on a line of its own under them.
        final sortBeside = constraints.maxWidth >= _sortBesideWidth;
        final row = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              // A line of its own for the chip where the row is too narrow to
              // hold it beside the filter, the sort and the switch.
              child: Wrap(
                alignment: alignEnd ? WrapAlignment.end : WrapAlignment.start,
                spacing: 4,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  filter,
                  if (narrowed)
                    CompactIconButton(
                      key: const ValueKey('sidebar-filter-clear'),
                      tooltip: 'Back to $everything',
                      extent: 28,
                      foregroundColor: palette.textSecondary,
                      onPressed: onClear,
                      icon: const KapyIcon(KapyIcons.closeRounded, size: 14),
                    ),
                  if (when case final span?
                      when span != NotesWhen.anyTime && onWhenChanged != null)
                    _WhenChip(
                      when: span,
                      onClear: () => onWhenChanged(NotesWhen.anyTime),
                    ),
                ],
              ),
            ),
            // The sort and the switch keep to the filter's line when the chip
            // drops under it.
            SizedBox(
              height: _NotesFilter.lineHeight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(width: 4),
                  if (sort != null && sortBeside) ...[
                    sort,
                    const SizedBox(width: 8),
                  ],
                  if (onCardsChanged != null)
                    Container(
                      padding: const EdgeInsets.all(1),
                      decoration: BoxDecoration(
                        color: palette.cardBackground,
                        border: Border.all(color: palette.controlBorder),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          segment(false, onCardsChanged),
                          segment(true, onCardsChanged),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
        if (sort == null || sortBeside) return row;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: alignEnd
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [row, const SizedBox(height: 4), sort],
        );
      },
    );
  }
}

/// [ticked] after [media] is ticked or unticked, or after All media (null)
/// is; null when nothing changes. A kind is unticked only while another
/// stays ticked: a list narrowed to nothing would look like a library that
/// had lost its notes.
Set<NoteMedia>? tickedMedia(Set<NoteMedia> ticked, NoteMedia? media) {
  if (media == null) {
    return ticked.length < NoteMedia.values.length
        ? NoteMedia.values.toSet()
        : null;
  }
  if (!ticked.contains(media)) return {...ticked, media};
  return ticked.length > 1 ? ({...ticked}..remove(media)) : null;
}

/// The notes filter's button and menu: one choice of which notes, When with
/// its submenu, then the media ticks. Every kind is ticked by default, and
/// unticking kinds narrows the list to notes holding a kind still ticked.
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
    required this.tags,
    required this.onTagsChanged,
    required this.when,
    required this.onWhenChanged,
    required this.today,
    required this.weekShown,
    required this.everything,
    required this.narrowed,
    this.phone = false,
  });

  final bool phone;
  final NotesShow show;
  final bool offersShow;
  final ValueChanged<NotesShow> onShowChanged;
  final bool hiddenListed;
  final String? hiddenShortcut;
  final int archivedCount;
  final Set<NoteMedia>? media;
  final ValueChanged<Set<NoteMedia>>? onMediaChanged;
  final TagFilter? tags;
  final ValueChanged<TagFilter>? onTagsChanged;
  final WhenFilter? when;
  final ValueChanged<WhenFilter>? onWhenChanged;
  final DateTime today;
  final bool Function()? weekShown;

  /// What the button says while nothing is narrowed.
  final String everything;
  final bool narrowed;

  /// The height of the filter's line: its 32 bar with a pointer, and its 28
  /// button with 8 above and below for a finger.
  static double get lineHeight => AppPlatform.hasPointer ? 32 : 28 + 2 * 8;

  @override
  State<_NotesFilter> createState() => _NotesFilterState();
}

/// The filter's submenus, each opened from its row in the menu.
enum _FilterSubmenu { when, tags }

class _NotesFilterState extends State<_NotesFilter> {
  final _menu = OverlayPortalController();
  final _link = LayerLink();
  final _menuKey = GlobalKey();
  final _whenRow = GlobalKey();
  final _tagsRow = GlobalKey();

  /// The submenu open beside the menu, if any.
  _FilterSubmenu? _submenu;

  /// Where the open submenu's corner goes: beside the menu, level with the
  /// row that opened it. A submenu that would run off the foot of the window
  /// moves up until it fits.
  Offset _submenuAt = Offset.zero;

  void _toggleSubmenu(_FilterSubmenu submenu, GlobalKey row) {
    final opener = row.currentContext?.findRenderObject() as RenderBox?;
    final menu = _menuKey.currentContext?.findRenderObject() as RenderBox?;
    setState(() {
      _submenu = _submenu == submenu ? null : submenu;
      if (opener != null && menu != null) {
        _submenuAt = Offset(
          menu.localToGlobal(Offset(menu.size.width + 4, 0)).dx,
          opener.localToGlobal(Offset.zero).dy - 6,
        );
      }
    });
  }

  /// The open submenu, beside the row that opened it.
  Widget? get _openSubmenu => switch (_submenu) {
    _FilterSubmenu.when when widget.when != null => _WhenMenu(
      when: widget.when!,
      today: widget.today,
      footnote: widget.weekShown?.call() ?? false,
      onChanged: _chooseWhen,
    ),
    _FilterSubmenu.tags when widget.tags != null => _TagsMenu(
      filter: widget.tags!,
      onChanged: widget.onTagsChanged!,
    ),
    _ => null,
  };

  void _toggle() {
    if (AppPlatform.isMobile) return unawaited(_openPopover());
    setState(() {
      _submenu = null;
      _menu.isShowing ? _menu.hide() : _menu.show();
    });
  }

  /// Nested menus don't work with touch, so on a touch screen the same
  /// choices are a popover of touch rows under the button.
  Future<void> _openPopover() {
    final button = context.findRenderObject()! as RenderBox;
    final origin = button.localToGlobal(Offset.zero);
    final shelf = TagShelf.maybeOf(context);
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close the filter',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 140),
      transitionBuilder: (context, animation, _, child) => FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: child,
      ),
      pageBuilder: (context, _, _) {
        final screen = MediaQuery.sizeOf(context);
        final top = origin.dy + button.size.height + 4;
        return Stack(
          children: [
            Positioned(
              left: math.max(
                12,
                math.min(origin.dx, screen.width - _FilterPopover.width - 12),
              ),
              top: top,
              width: _FilterPopover.width,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: math.max(
                    160,
                    screen.height -
                        top -
                        MediaQuery.paddingOf(context).bottom -
                        12,
                  ),
                ),
                child: _FilterPopover(
                  show: widget.show,
                  offersShow: widget.offersShow,
                  onShowChanged: widget.onShowChanged,
                  hiddenListed: widget.hiddenListed,
                  archivedCount: widget.archivedCount,
                  everything: widget.everything,
                  media: widget.media,
                  onMediaChanged: widget.onMediaChanged,
                  tags: widget.tags,
                  onTagsChanged: widget.onTagsChanged,
                  shelf: shelf,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _close() {
    if (_menu.isShowing) setState(_menu.hide);
  }

  void _choose(NotesShow show) {
    _close();
    if (show != widget.show) widget.onShowChanged(show);
  }

  void _chooseWhen(NotesWhen when) {
    _close();
    if (when != widget.when) widget.onWhenChanged!(when);
  }

  /// A kind is unticked only while another stays ticked: a list narrowed to
  /// nothing would look like a library that had lost its notes.
  void _tick(NoteMedia? media) {
    final ticked = tickedMedia(widget.media!, media);
    if (ticked != null) widget.onMediaChanged!(ticked);
  }

  /// What the button says: one narrowed group names itself ("Archive",
  /// "Voice, Image", "● Work"); combined, each gives its first choice and
  /// how many more ("Archive · Voice +1 · Work +2"). Where that runs out of
  /// [room], the choice of notes goes, since the title over the list
  /// already names it. The dot is the first tag's, while tags alone narrow.
  ({String text, Tag? dot}) _label(TextStyle style, double room) {
    final show = widget.show == NotesShow.all ? null : widget.show.label;
    final kinds = [
      for (final media in NoteMedia.values)
        if (widget.media?.contains(media) ?? false) media.label,
    ];
    final tags = widget.tags ?? const TagFilter();
    final ticked = [
      for (final entry in TagShelf.maybeOf(context)?.listed() ?? <TagEntry>[])
        if (tags.ids.contains(entry.tag.id)) entry.tag,
    ];
    final groups = [
      if (show != null) [show],
      if (widget.media != null && kinds.length < NoteMedia.values.length) kinds,
      if (tags.narrowed)
        [for (final tag in ticked) tag.name.v, if (tags.none) 'No tag'],
    ];
    if (groups.isEmpty) return (text: widget.everything, dot: null);
    if (groups.length == 1) {
      final tagsAlone = tags.narrowed;
      return (
        text: groups.single.join(', '),
        dot: tagsAlone ? ticked.firstOrNull : null,
      );
    }
    String part(List<String> group) =>
        group.length == 1 ? group.first : '${group.first} +${group.length - 1}';
    final all = groups.map(part).join(' · ');
    if (show == null) return (text: all, dot: null);
    final painter = TextPainter(
      text: TextSpan(text: all, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout(maxWidth: room);
    final fits = !painter.didExceedMaxLines;
    painter.dispose();
    return (text: fits ? all : groups.skip(1).map(part).join(' · '), dot: null);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final open = _menu.isShowing;
    final narrowed = widget.narrowed;
    final style = DefaultTextStyle.of(context).style.merge(
      _figtree(
        AppTypeScale.body,
        16,
        FontWeight.w500,
        narrowed ? palette.tonalForeground : palette.textSubheading,
      ),
    );
    if (widget.phone) {
      final pill = _figtree(15, 20, FontWeight.w500, palette.paperColor);
      final (:text, :dot) = _label(pill, double.infinity);
      return Semantics(
        button: true,
        label: 'Notes filter, $text',
        excludeSemantics: true,
        onTap: _toggle,
        child: GestureDetector(
          key: const ValueKey('sidebar-notes-filter'),
          onTap: _toggle,
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            height: AppControlMetrics.iconButtonExtent,
            child: Center(
              child: Container(
                height: 30,
                padding: const EdgeInsets.only(left: 12, right: 10),
                decoration: BoxDecoration(
                  color: palette.textPrimary,
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (dot != null) ...[
                      TagDot(tagColourOf(dot.colour.v), size: 8),
                      const SizedBox(width: 6),
                    ],
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 200),
                      child: Text(
                        text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: pill,
                      ),
                    ),
                    const SizedBox(width: 5),
                    KapyIcon(
                      KapyIcons.chevronDownRounded,
                      size: 13,
                      color: palette.paperColor,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    final button = LayoutBuilder(
      // A list dragged to its narrowest keeps the filter's icon, which still
      // opens the menu and still turns sage when the list is narrowed.
      builder: (context, constraints) {
        if (constraints.maxWidth < 28) return const SizedBox.shrink();
        final roomy = constraints.maxWidth >= 72;
        final bar = AppPlatform.hasPointer;
        // The padding, border, filter icon and chevron around the label.
        final chrome = bar
            ? 8 + 8 + 2 + 16 + 4 + 4 + 12
            : 9 + 8 + 2 + 14 + 6 + 6 + 13;
        final (:text, :dot) = roomy
            ? _label(style, constraints.maxWidth - chrome)
            : (text: widget.everything, dot: null);
        return Semantics(
          button: true,
          expanded: open,
          label: 'Notes filter, $text',
          excludeSemantics: true,
          onTap: _toggle,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              key: const ValueKey('sidebar-notes-filter'),
              onTap: _toggle,
              behavior: HitTestBehavior.opaque,
              child: Container(
                height: bar ? 32 : 28,
                margin: bar ? null : const EdgeInsets.symmetric(vertical: 8),
                padding: roomy
                    ? EdgeInsets.only(left: bar ? 8 : 9, right: 8)
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
                  borderRadius: BorderRadius.circular(
                    bar ? 8 : AppRadii.control,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    KapyIcon(
                      KapyIcons.filterRounded,
                      size: bar ? 16 : 14,
                      color: narrowed ? style.color : palette.textSecondary,
                    ),
                    if (roomy) ...[
                      SizedBox(width: bar ? 4 : 6),
                      if (dot != null) ...[
                        TagDot(tagColourOf(dot.colour.v), size: 7),
                        const SizedBox(width: 5),
                      ],
                      Flexible(
                        child: Text(
                          text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: style,
                        ),
                      ),
                      SizedBox(width: bar ? 4 : 6),
                      KapyIcon(
                        KapyIcons.chevronDownRounded,
                        size: bar ? 12 : 13,
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
      // A tag's own menu or its delete question sits over the filter's, and
      // a click there leaves the filter open beneath it.
      onTapOutside: (_) {
        if (ModalRoute.of(context)?.isCurrent ?? true) _close();
      },
      child: CompositedTransformTarget(
        link: _link,
        child: OverlayPortal(
          controller: _menu,
          overlayChildBuilder: (context) => CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): _close,
            },
            child: Focus(
              autofocus: true,
              child: Stack(
                children: [
                  Align(
                    alignment: Alignment.topLeft,
                    child: CompositedTransformFollower(
                      link: _link,
                      targetAnchor: Alignment.bottomLeft,
                      offset: const Offset(0, 8),
                      child: TapRegion(
                        groupId: _menu,
                        child: _FilterMenu(
                          key: _menuKey,
                          show: widget.show,
                          offersShow: widget.offersShow,
                          onShow: _choose,
                          hiddenListed: widget.hiddenListed,
                          hiddenShortcut: widget.hiddenShortcut,
                          archivedCount: widget.archivedCount,
                          everything: widget.everything,
                          media: widget.media,
                          onTick: _tick,
                          when: widget.onWhenChanged == null
                              ? null
                              : widget.when,
                          onWhen: () =>
                              _toggleSubmenu(_FilterSubmenu.when, _whenRow),
                          whenRow: _whenRow,
                          onTags: widget.tags == null
                              ? null
                              : () => _toggleSubmenu(
                                  _FilterSubmenu.tags,
                                  _tagsRow,
                                ),
                          tagsRow: _tagsRow,
                          tags: widget.tags ?? const TagFilter(),
                        ),
                      ),
                    ),
                  ),
                  if (_openSubmenu case final submenu?)
                    CustomSingleChildLayout(
                      delegate: PopoverAtPoint(_submenuAt),
                      child: TapRegion(groupId: _menu, child: submenu),
                    ),
                ],
              ),
            ),
          ),
          child: button,
        ),
      ),
    );
  }
}

/// A tag in a phone's filter row: a tap narrows the list to it, and
/// another tap widens it again.
class _TagPill extends StatelessWidget {
  const _TagPill({
    required this.tag,
    required this.on,
    required this.onChanged,
  });

  final Tag tag;
  final bool on;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      button: true,
      selected: on,
      label: 'Tag ${tag.name.v}',
      excludeSemantics: true,
      onTap: () => onChanged(!on),
      child: GestureDetector(
        key: ValueKey('phone-tag-${tag.id}'),
        onTap: () => onChanged(!on),
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          height: AppControlMetrics.iconButtonExtent,
          child: Center(
            child: Container(
              height: 30,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: on ? palette.tonalBackground : null,
                border: Border.all(
                  color: on
                      ? palette.tonalKeyBackground
                      : palette.controlBorder,
                ),
                borderRadius: BorderRadius.circular(15),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 7,
                children: [
                  TagDot(tagColourOf(tag.colour.v), size: 8),
                  Text(
                    tag.name.v,
                    style: _figtree(
                      15,
                      20,
                      FontWeight.w400,
                      on ? palette.tonalForeground : palette.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ),
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
    required this.when,
    required this.onWhen,
    required this.whenRow,
    super.key,
    required this.onTags,
    required this.tagsRow,
    required this.tags,
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

  /// What When narrows the list to; null leaves When out.
  final WhenFilter? when;

  /// Opens or closes the When submenu.
  final VoidCallback onWhen;
  final Key whenRow;

  /// Opens or closes the Tags submenu; null leaves Tags out.
  final VoidCallback? onTags;
  final Key tagsRow;

  /// What the Tags submenu has ticked, named before its chevron.
  final TagFilter tags;

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

    final when = this.when;
    Widget rule() => Container(
      height: 1,
      margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      color: palette.separator,
    );
    Widget heading(String label) => Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Semantics(
        header: true,
        child: Text(
          label,
          style: _figtree(
            AppTypeScale.small,
            16,
            FontWeight.w500,
            palette.textTertiary,
          ),
        ),
      ),
    );
    final quiet = _figtree(
      AppTypeScale.small,
      16,
      FontWeight.w400,
      palette.textTertiary,
    );
    // A row's value, then the chevron of the submenu it opens.
    Widget opens(Widget? value) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (value != null) ...[value, const SizedBox(width: 6)],
        KapyIcon(
          KapyIcons.chevronRightRounded,
          size: 13,
          color: palette.textTertiary,
        ),
      ],
    );

    return Container(
      key: const ValueKey('notes-filter-menu'),
      width: 232,
      padding: const EdgeInsets.all(6),
      decoration: _menuSurface(palette),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (offersShow) ...[
            heading('Show'),
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
          if (when != null) ...[
            if (offersShow) rule(),
            KeyedSubtree(
              key: whenRow,
              child: _ShowMenuRow(
                key: const ValueKey('notes-filter-when'),
                label: 'When',
                icon: KapyIcons.calendarOutlined,
                chosen: false,
                trailing: opens(Text(when.label, style: quiet)),
                onTap: onWhen,
              ),
            ),
          ],
          if (media != null) ...[
            if (offersShow || when != null) rule(),
            heading('Media'),
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
          if (onTags case final onTags?) ...[
            if (offersShow || when != null || media != null) rule(),
            KeyedSubtree(
              key: tagsRow,
              child: _ShowMenuRow(
                key: const ValueKey('notes-filter-tags'),
                label: 'Tags',
                icon: KapyIcons.tagRounded,
                chosen: false,
                trailing: opens(
                  tags.ticked == 0
                      ? null
                      : _TickedTags(
                          key: const ValueKey('notes-filter-tags-ticked'),
                          tags: tags,
                          style: quiet,
                        ),
                ),
                onTap: onTags,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The Tags row's value: one ticked tag by its dot and name, as the filter
/// names it, or how many are ticked.
class _TickedTags extends StatelessWidget {
  const _TickedTags({super.key, required this.tags, required this.style});

  final TagFilter tags;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final one = tags.ticked == 1;
    final tag = one
        ? [
            for (final entry
                in TagShelf.maybeOf(context)?.listed() ?? <TagEntry>[])
              if (tags.ids.contains(entry.tag.id)) entry.tag,
          ].firstOrNull
        : null;
    final name = tag?.name.v ?? (one && tags.none ? 'No tag' : null);
    if (name == null) return Text('${tags.ticked}', style: style);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (tag != null) ...[
          TagDot(tagColourOf(tag.colour.v), size: 7),
          const SizedBox(width: 5),
        ],
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 96),
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
      ],
    );
  }
}

/// One of the menu's single choice of which notes: the chosen one lit, with
/// a tick where the others show their shortcut or count.
class _ShowMenuRow extends StatefulWidget {
  const _ShowMenuRow({
    super.key,
    required this.label,
    this.icon,
    required this.chosen,
    required this.onTap,
    this.trailing,
  });

  final String label;
  final KapyIconData? icon;
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
        ? KapyIcon(KapyIcons.checkRounded, size: 14, color: palette.accentText)
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
              borderRadius: BorderRadius.circular(AppRadii.compact),
            ),
            child: Row(
              children: [
                if (widget.icon case final icon?) ...[
                  KapyIcon(
                    icon,
                    size: 15,
                    color: chosen ? palette.textPrimary : palette.textSecondary,
                  ),
                  const SizedBox(width: 9),
                ],
                Expanded(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _figtree(
                      AppTypeScale.control,
                      16,
                      chosen ? FontWeight.w500 : FontWeight.w400,
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
              borderRadius: BorderRadius.circular(AppRadii.compact),
            ),
            child: Row(
              children: [
                _PickBox(checked: widget.ticked),
                const SizedBox(width: 9),
                if (icon != null) ...[
                  KapyIcon(icon, size: 15, color: palette.textSecondary),
                  const SizedBox(width: 9),
                ],
                Text(
                  widget.label,
                  style: _figtree(
                    AppTypeScale.control,
                    16,
                    FontWeight.w400,
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

/// The filter's When submenu, beside the When row: each span with the days
/// it covers, and a tick on the one the list reaches back over. While the
/// page shows the week, a footnote points there for a single day.
class _WhenMenu extends StatelessWidget {
  const _WhenMenu({
    required this.when,
    required this.today,
    required this.footnote,
    required this.onChanged,
  });

  final WhenFilter when;
  final DateTime today;
  final bool footnote;
  final ValueChanged<NotesWhen> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final weekStart = firstWeekday(context);
    Widget row(NotesWhen span) {
      final detail = span.detail(today: today, firstWeekday: weekStart);
      return _ShowMenuRow(
        key: ValueKey('notes-filter-when-${span.name}'),
        label: span.label,
        chosen: span == when,
        trailing: detail == null
            ? null
            : Text(
                detail,
                style: _figtree(
                  AppTypeScale.small,
                  16,
                  FontWeight.w400,
                  palette.textTertiary,
                ),
              ),
        onTap: () => onChanged(span),
      );
    }

    return Container(
      key: const ValueKey('notes-when-menu'),
      width: 220,
      padding: const EdgeInsets.all(6),
      decoration: _menuSurface(palette),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (index, span) in NotesWhen.values.indexed) ...[
            if (index > 0) const SizedBox(height: 1),
            row(span),
          ],
          if (footnote) ...[
            Container(
              height: 1,
              margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              color: palette.separator,
            ),
            Padding(
              key: const ValueKey('notes-when-footnote'),
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
              child: Text(
                'For one day, click it in the week at the top of the page',
                style: _figtree(
                  AppTypeScale.small,
                  16,
                  FontWeight.w400,
                  palette.textTertiary,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The filter's Tags submenu, beside the Tags row: Match any | all once two
/// are ticked, then the tags in the person's order with their counts and
/// boxes, then No tag. Past eight tags a field finds one.
class _TagsMenu extends StatefulWidget {
  const _TagsMenu({required this.filter, required this.onChanged});

  final TagFilter filter;
  final ValueChanged<TagFilter> onChanged;

  @override
  State<_TagsMenu> createState() => _TagsMenuState();
}

class _TagsMenuState extends State<_TagsMenu> {
  final _query = TextEditingController();
  String? _renaming;

  static const _findPast = 8;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final shelf = TagShelf.maybeOf(context)!;
    final filter = widget.filter;
    final every = shelf.listed();
    final query = _query.text.trim().toLowerCase();
    final quiet = _figtree(
      AppTypeScale.small,
      16,
      FontWeight.w400,
      palette.textTertiary,
    );
    Widget match(bool all) {
      final on = filter.all == all;
      return GestureDetector(
        key: ValueKey(all ? 'tag-filter-all' : 'tag-filter-any'),
        onTap: () => widget.onChanged(filter.copyWith(all: all)),
        child: Container(
          height: 20,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on ? palette.segmentSelected : null,
            borderRadius: BorderRadius.circular(AppRadii.small),
          ),
          child: Text(
            all ? 'all' : 'any',
            style: _figtree(
              AppTypeScale.small,
              16,
              on ? FontWeight.w500 : FontWeight.w400,
              on ? palette.textPrimary : palette.textSecondary,
            ),
          ),
        ),
      );
    }

    if (every.isEmpty) {
      return TagPopover(
        key: const ValueKey('tags-filter-menu'),
        width: 220,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'No tags yet',
                style: _figtree(
                  AppTypeScale.control,
                  16,
                  FontWeight.w500,
                  palette.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Open a note and choose + Tag next to its date.',
                style: quiet,
              ),
            ],
          ),
        ),
      );
    }
    return TagPopover(
      key: const ValueKey('tags-filter-menu'),
      width: 220,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (filter.ticked >= 2)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
              child: Row(
                children: [
                  Text('Match', style: quiet),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: palette.cardBackground,
                      borderRadius: BorderRadius.circular(AppRadii.compact),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [match(false), match(true)],
                    ),
                  ),
                ],
              ),
            ),
          if (every.length > _findPast)
            Container(
              height: 30,
              margin: const EdgeInsets.only(bottom: 4),
              padding: const EdgeInsets.symmetric(horizontal: 9),
              decoration: BoxDecoration(
                color: palette.wellBackground,
                border: Border.all(color: palette.controlBorder),
                borderRadius: BorderRadius.circular(AppRadii.control),
              ),
              child: Row(
                children: [
                  KapyIcon(
                    KapyIcons.searchRounded,
                    size: 14,
                    color: palette.textTertiary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      key: const ValueKey('tag-filter-find'),
                      controller: _query,
                      onChanged: (_) => setState(() {}),
                      style: _figtree(
                        AppTypeScale.control,
                        16,
                        FontWeight.w400,
                        palette.textPrimary,
                      ),
                      decoration: InputDecoration.collapsed(
                        hintText: 'Find a tag',
                        hintStyle: quiet,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 30.0 * 8),
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [
                for (final entry in every)
                  if (entry.tag.name.v.toLowerCase().contains(query))
                    _TagFilterRow(
                      key: ValueKey('tag-filter-${entry.tag.id}'),
                      colour: tagColourOf(entry.tag.colour.v),
                      label: entry.tag.name.v,
                      count: entry.count,
                      ticked: filter.ids.contains(entry.tag.id),
                      entry: entry,
                      renaming: _renaming == entry.tag.id,
                      onTap: () => widget.onChanged(
                        filter.copyWith(
                          ids: filter.ids.contains(entry.tag.id)
                              ? ({...filter.ids}..remove(entry.tag.id))
                              : {...filter.ids, entry.tag.id},
                        ),
                      ),
                      onRename: (renaming) => setState(
                        () => _renaming = renaming ? entry.tag.id : null,
                      ),
                    ),
              ],
            ),
          ),
          Container(
            height: 1,
            margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            color: palette.separator,
          ),
          _TagFilterRow(
            key: const ValueKey('tag-filter-none'),
            colour: null,
            label: 'No tag',
            count: shelf.untagged(),
            ticked: filter.none,
            onTap: () => widget.onChanged(filter.copyWith(none: !filter.none)),
          ),
        ],
      ),
    );
  }
}

/// A row of the Tags submenu: dot, name, count and its box at the right.
/// A tag's row trades its count for ⋯ while the pointer is over it, and its
/// name for a field while it is renamed.
class _TagFilterRow extends StatefulWidget {
  const _TagFilterRow({
    super.key,
    required this.colour,
    required this.label,
    required this.count,
    required this.ticked,
    required this.onTap,
    this.entry,
    this.renaming = false,
    this.onRename,
  });

  final TagColour? colour;
  final String label;
  final int count;
  final bool ticked;
  final VoidCallback onTap;

  /// Null for No tag, which has nothing to rename, recolour or delete.
  final TagEntry? entry;
  final bool renaming;
  final ValueChanged<bool>? onRename;

  @override
  State<_TagFilterRow> createState() => _TagFilterRowState();
}

class _TagFilterRowState extends State<_TagFilterRow> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final entry = widget.entry;
    final onRename = widget.onRename;
    final store = TagShelf.maybeOf(context)!.store;
    return Semantics(
      checked: widget.ticked,
      label: widget.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          onTap: widget.renaming ? null : widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: _hovering ? palette.hover : null,
              borderRadius: BorderRadius.circular(AppRadii.compact),
            ),
            child: Row(
              children: [
                TagDot(widget.colour, size: 7),
                const SizedBox(width: 9),
                Expanded(
                  child: entry != null && onRename != null && widget.renaming
                      ? TagNameField(
                          initial: entry.tag.name.v,
                          onSubmit: (name) {
                            final kept = store.rename(entry.tag.id, name);
                            if (kept) onRename(false);
                            return kept;
                          },
                          onCancel: () => onRename(false),
                        )
                      : Text(
                          widget.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: _figtree(
                            AppTypeScale.control,
                            16,
                            FontWeight.w400,
                            palette.textSubheading,
                          ),
                        ),
                ),
                const SizedBox(width: 8),
                if (entry != null &&
                    onRename != null &&
                    _hovering &&
                    !widget.renaming)
                  GestureDetector(
                    key: ValueKey('tag-filter-more-${entry.tag.id}'),
                    onTapUp: (details) => showTagActions(
                      context,
                      store: store,
                      entry: entry,
                      position: details.globalPosition,
                      onRename: () => onRename(true),
                    ),
                    child: KapyIcon(
                      KapyIcons.moreVerticalRounded,
                      size: 15,
                      color: palette.textSecondary,
                    ),
                  )
                else
                  Text(
                    '${widget.count}',
                    style: _figtree(
                      AppTypeScale.small,
                      16,
                      FontWeight.w400,
                      palette.textTertiary,
                    ),
                  ),
                const SizedBox(width: 9),
                _PickBox(checked: widget.ticked),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The notes filter on a phone (SF5-0): Show, Media and a Tags row, which
/// pushes a second page with the same tag list as the menu's submenu. Every
/// choice applies at once, so Done only closes it; choosing what to show
/// closes it too, as the menu does.
class _FilterPopover extends StatefulWidget {
  const _FilterPopover({
    required this.show,
    required this.offersShow,
    required this.onShowChanged,
    required this.hiddenListed,
    required this.archivedCount,
    required this.everything,
    required this.media,
    required this.onMediaChanged,
    required this.tags,
    required this.onTagsChanged,
    required this.shelf,
  });

  static const double width = 262;

  final NotesShow show;
  final bool offersShow;
  final ValueChanged<NotesShow> onShowChanged;
  final bool hiddenListed;
  final int archivedCount;
  final String everything;
  final Set<NoteMedia>? media;
  final ValueChanged<Set<NoteMedia>>? onMediaChanged;
  final TagFilter? tags;
  final ValueChanged<TagFilter>? onTagsChanged;

  /// The tags the sheet lists: the route it sits in is above the app's own
  /// shelf, so it brings it along.
  final TagShelf? shelf;

  @override
  State<_FilterPopover> createState() => _FilterPopoverState();
}

class _FilterPopoverState extends State<_FilterPopover> {
  late Set<NoteMedia>? _media = widget.media;
  late TagFilter? _tags = widget.tags;
  bool _tagsPage = false;

  void _tick(NoteMedia? media) {
    final ticked = tickedMedia(_media!, media);
    if (ticked == null) return;
    setState(() => _media = ticked);
    widget.onMediaChanged!(ticked);
  }

  void _setTags(TagFilter tags) {
    setState(() => _tags = tags);
    widget.onTagsChanged!(tags);
  }

  void _choose(NotesShow show) {
    Navigator.of(context).pop();
    if (show != widget.show) widget.onShowChanged(show);
  }

  Widget _row({
    required Key key,
    required Widget leading,
    required String label,
    required VoidCallback onTap,
    Widget? trailing,
    bool chosen = false,
  }) {
    final palette = context.palette;
    return Semantics(
      selected: chosen,
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        key: key,
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: 46,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: chosen ? palette.separator : null,
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
          child: Row(
            spacing: 12,
            children: [
              leading,
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _figtree(
                    AppTypeScale.control,
                    20,
                    chosen ? FontWeight.w500 : FontWeight.w400,
                    chosen ? palette.textPrimary : palette.textSubheading,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
        ),
      ),
    );
  }

  Widget _quiet(String text) => Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: _figtree(
      AppTypeScale.small,
      16,
      FontWeight.w400,
      context.palette.textTertiary,
    ),
  );

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
    child: Text(
      text,
      style: _figtree(12, 16, FontWeight.w500, context.palette.textTertiary),
    ),
  );

  Widget _showRow(NotesShow show, KapyIconData icon, {Widget? trailing}) {
    final palette = context.palette;
    final chosen = widget.show == show;
    return _row(
      key: ValueKey('notes-filter-${show.name}'),
      leading: KapyIcon(
        icon,
        size: 18,
        color: chosen ? palette.textPrimary : palette.textSecondary,
      ),
      label: show == NotesShow.all ? widget.everything : show.label,
      chosen: chosen,
      trailing: chosen
          ? KapyIcon(
              KapyIcons.checkRounded,
              size: 16,
              color: palette.accentText,
            )
          : trailing,
      onTap: () => _choose(show),
    );
  }

  Widget _chip(String label, {required bool on, required VoidCallback onTap}) {
    final palette = context.palette;
    return GestureDetector(
      key: ValueKey('media-filter-$label'),
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: on ? palette.tonalBackground : null,
          border: Border.all(
            color: on ? palette.tonalKeyBackground : palette.controlBorder,
          ),
          borderRadius: BorderRadius.circular(AppRadii.dialog),
        ),
        child: Center(
          widthFactor: 1,
          child: Text(
            label,
            style: _figtree(
              AppTypeScale.control,
              18,
              FontWeight.w400,
              on ? palette.tonalForeground : palette.textSubheading,
            ),
          ),
        ),
      ),
    );
  }

  Widget _mainPage() {
    final palette = context.palette;
    final media = _media;
    final tags = _tags;
    final ticked = [
      for (final entry in widget.shelf?.listed() ?? <TagEntry>[])
        if (tags?.ids.contains(entry.tag.id) ?? false) entry.tag.name.v,
      if (tags?.none ?? false) 'No tag',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.offersShow) ...[
          _heading('Show'),
          _showRow(
            NotesShow.all,
            media == null ? KapyIcons.penRounded : KapyIcons.noteOutlined,
          ),
          if (widget.hiddenListed) _showRow(NotesShow.hidden, hiddenIcon),
          _showRow(
            NotesShow.archive,
            archiveIcon,
            trailing: _quiet('${widget.archivedCount}'),
          ),
        ],
        if (media != null) ...[
          _heading('Media'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _chip(
                  'All media',
                  on: media.length == NoteMedia.values.length,
                  onTap: () => _tick(null),
                ),
                for (final kind in NoteMedia.values)
                  _chip(
                    kind.label,
                    on: media.contains(kind),
                    onTap: () => _tick(kind),
                  ),
              ],
            ),
          ),
        ],
        if (tags != null) ...[
          _heading('Tags'),
          _row(
            key: const ValueKey('notes-filter-tags'),
            leading: KapyIcon(
              KapyIcons.tagRounded,
              size: 18,
              color: palette.textSecondary,
            ),
            label: 'Tags',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 8,
              children: [
                if (ticked.isNotEmpty)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 160),
                    child: _quiet(ticked.join(', ')),
                  ),
                KapyIcon(
                  KapyIcons.chevronRightRounded,
                  size: 14,
                  color: palette.textTertiary,
                ),
              ],
            ),
            onTap: () => setState(() => _tagsPage = true),
          ),
        ],
      ],
    );
  }

  Widget _tagsList() {
    final palette = context.palette;
    final filter = _tags!;
    final shelf = widget.shelf!;
    final every = shelf.listed();
    if (every.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
        child: Text(
          'No tags yet. Open a note and choose + Tag next to its date.',
          key: const ValueKey('tags-filter-empty'),
          style: _figtree(
            AppTypeScale.control,
            20,
            FontWeight.w400,
            palette.textTertiary,
          ),
        ),
      );
    }
    Widget match(bool all) {
      final on = filter.all == all;
      return GestureDetector(
        key: ValueKey(all ? 'tag-filter-all' : 'tag-filter-any'),
        onTap: () => _setTags(filter.copyWith(all: all)),
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on ? palette.segmentSelected : null,
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
          child: Text(
            all ? 'all' : 'any',
            style: _figtree(
              AppTypeScale.control,
              18,
              on ? FontWeight.w500 : FontWeight.w400,
              on ? palette.textPrimary : palette.textSecondary,
            ),
          ),
        ),
      );
    }

    Widget tagRow({
      required Key key,
      required Widget dot,
      required String label,
      required int count,
      required bool ticked,
      required VoidCallback onTap,
    }) => _row(
      key: key,
      leading: SizedBox(width: 18, child: Center(child: dot)),
      label: label,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 12,
        children: [
          _quiet('$count'),
          _PickBox(checked: ticked),
        ],
      ),
      onTap: onTap,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (filter.ticked >= 2)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: Row(
              spacing: 12,
              children: [
                _quiet('Match'),
                Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: palette.cardBackground,
                    borderRadius: BorderRadius.circular(AppRadii.control),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [match(false), match(true)],
                  ),
                ),
              ],
            ),
          ),
        for (final entry in every)
          tagRow(
            key: ValueKey('tag-filter-${entry.tag.id}'),
            dot: TagDot(tagColourOf(entry.tag.colour.v), size: 10),
            label: entry.tag.name.v,
            count: entry.count,
            ticked: filter.ids.contains(entry.tag.id),
            onTap: () => _setTags(
              filter.copyWith(
                ids: filter.ids.contains(entry.tag.id)
                    ? ({...filter.ids}..remove(entry.tag.id))
                    : {...filter.ids, entry.tag.id},
              ),
            ),
          ),
        Container(
          height: 1,
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          color: palette.separator,
        ),
        tagRow(
          key: const ValueKey('tag-filter-none'),
          dot: const TagDot(null, size: 10),
          label: 'No tag',
          count: shelf.untagged(),
          ticked: filter.none,
          onTap: () => _setTags(filter.copyWith(none: !filter.none)),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final title = _figtree(
      AppTypeScale.control,
      20,
      FontWeight.w500,
      palette.textPrimary,
    );
    final link = _figtree(
      AppTypeScale.control,
      20,
      FontWeight.w500,
      palette.accentText,
    );
    return Material(
      key: const ValueKey('notes-filter-popover'),
      color: palette.surfaceBackground,
      elevation: 8,
      shadowColor: palette.shadowAt(0x55),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: palette.controlBorder, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 48,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Text(_tagsPage ? 'Tags' : 'Filter', style: title),
                if (_tagsPage)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: GestureDetector(
                      key: const ValueKey('notes-filter-back'),
                      onTap: () => setState(() => _tagsPage = false),
                      behavior: HitTestBehavior.opaque,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          spacing: 4,
                          children: [
                            KapyIcon(
                              KapyIcons.arrowBackRounded,
                              size: 14,
                              color: palette.textSecondary,
                            ),
                            Text(
                              'Filter',
                              style: link.copyWith(
                                color: palette.textSecondary,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                Align(
                  alignment: Alignment.centerRight,
                  child: GestureDetector(
                    key: const ValueKey('notes-filter-done'),
                    onTap: () => Navigator.of(context).pop(),
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text('Done', style: link),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
              child: _tagsPage ? _tagsList() : _mainPage(),
            ),
          ),
        ],
      ),
    );
  }
}
