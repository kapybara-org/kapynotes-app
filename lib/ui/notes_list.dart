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
import '../data/task_lines.dart';
import 'checklist_pie.dart';
import 'compact_icon_button.dart';
import 'draw/drawing_geometry.dart';
import 'draw/drawing_painter.dart';
import 'editor/voice_chip.dart' show formatVoiceDuration;
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

  /// Ticked boxes, of [boxes] tasks in the whole note: its checklist lines
  /// as [taskLines] reads them for the header and Tasks, ☐ and ☑ or markdown
  /// boxes, each with words after it.
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
    final tasks = taskLines(note.body);
    var titled = false;
    int? at;
    var atStart = 0;
    var start = 0;
    for (var i = 0; i < lines.length; i++) {
      final text = lines[i]
          .replaceAll(NoteAttachmentRef.placeholder, '')
          .trim();
      if (text.isNotEmpty) {
        if (!titled) {
          titled = true;
        } else if (at == null) {
          at = i;
          atStart = start;
        }
      }
      start += lines[i].length + 1;
    }
    String? line;
    if (at != null) {
      final task = tasks.where((task) => task.start == atStart).firstOrNull;
      final text =
          (task == null
                  ? lines[at]
                  : note.body.substring(task.textStart, task.end))
              .replaceAll(NoteAttachmentRef.placeholder, '')
              .trim();
      line = task == null ? text.replaceFirst(_marks, '') : text;
    }
    final glance = NoteGlance._(
      line: line,
      result: at == null || engine == null
          ? null
          : engine
                .evaluateDocument(
                  lines.take(at + 1).join('\n'),
                  titled: true,
                )[at]
                ?.text,
      done: tasks.where((task) => task.done).length,
      boxes: tasks.length,
      media: NoteMedia.inNote(note),
    );
    _read[note] = (engine, glance);
    return glance;
  }

  /// The note's first line, with the answer when that line is a sum.
  String? get preview {
    final line = this.line;
    final result = this.result;
    return line == null
        ? null
        : result == null
        ? line
        : '${line.split('=').first.trim()} = $result';
  }
}

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

/// A card's one fill, opaque on the theme's own card colour so its shadow
/// never shows through: a step up while the pointer is on it, and another
/// while it is open or picked. It never takes an outline for being open.
Color _cardFill(
  CalcPalette palette, {
  required bool selected,
  required bool hovering,
}) => selected
    ? Color.alphaBlend(palette.fillControl, palette.cardBackground)
    : hovering
    ? Color.alphaBlend(palette.fillRest, palette.cardBackground)
    : palette.cardBackground;

/// The ring round a card open in another pane.
Border? _ringOf(CalcPalette palette, {required bool ringed}) => ringed
    ? Border.all(
        color: palette.selectedBorder.withValues(alpha: 0.5),
        width: 1.5,
      )
    : null;

/// A tick box: the media menu's, a note's while notes are being picked, and
/// one in Add notes beside a folder.
class PickBox extends StatelessWidget {
  const PickBox({super.key, required this.checked});

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

/// A note as a card of three fixed lines: its title, a line of it, and the
/// meta row, on the list's quiet card fill.
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
    final marked = selected || this.picking == true;
    final fill = _cardFill(palette, selected: marked, hovering: hovering);
    final glance = this.glance;
    final result = snippet == null ? glance.amount ?? glance.result : null;
    final text = snippet ?? glance.line;
    final picking = this.picking;
    final types = [
      for (final kind in NoteMedia.values.reversed)
        if (glance.media.contains(kind)) kind.icon,
    ].take(2).toList();

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 10),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: _cardRadius,
        border: _ringOf(palette, ringed: ringed),
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
                            right: picking == null ? 0 : PickBox.size + 6,
                          ),
                          child: Text(
                            note.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: _figtree(
                              13,
                              18,
                              FontWeight.w500,
                              palette.textPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          result ?? text ?? _noText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: result != null
                              ? chromeStyle(
                                  size: 12,
                                  line: 16,
                                  weight: AppWeight.page,
                                  color: palette.resultPillText,
                                  tabular: true,
                                )
                              : _figtree(
                                  12,
                                  16,
                                  FontWeight.w400,
                                  palette.textSecondary,
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
                ground: fill,
                selected: marked,
              ),
            ],
          ),
          if (picking != null)
            Positioned(top: 0, right: 0, child: PickBox(checked: picking)),
        ],
      ),
    );
  }
}

/// A phone's card for a pinned note, on Home's sideways row and on the
/// Pinned page's grid: the Mac's card in the phone's type sizes, the title
/// in the hand face, then the first line or its sum's value, then the date
/// and the tags. Its height is its lines' at the person's text size, so it
/// grows with the text and nothing on it is cut.
class PhoneCardFace extends StatelessWidget {
  const PhoneCardFace({
    super.key,
    required this.note,
    required this.glance,
    required this.date,
    required this.selected,
    this.day,
    this.locked = false,
    this.shared = false,
    this.picking,
  });

  /// The padding round it, and its three lines with the space between them,
  /// each as tall as the text draws it, its font size scaled and its line
  /// height kept, and rounded up to a whole point so no line is cut. Android
  /// scales larger sizes less, so the line heights can't be scaled alone.
  static double height(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    double line(double size, double height) =>
        (scaler.scale(size) * height / size).ceilToDouble();
    return 14 + line(16, 22) + 2 + line(13, 18) + 12 + line(12, 16) + 14;
  }

  final Note note;
  final NoteGlance glance;

  /// When it was changed, in the list's own words.
  final String date;

  /// [date] without its time of day, for a meta row short of room.
  final String? day;
  final bool selected;
  final bool locked;
  final bool shared;

  /// Ticked or not while notes are being picked; null otherwise.
  final bool? picking;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final picking = this.picking;
    final marked = selected || picking == true;
    final fill = marked ? palette.fillSelected : palette.fillRest;
    final result = glance.amount ?? glance.result;
    final text = glance.line;
    final card = Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.only(
              right: picking == null ? 0 : PickBox.size + 6,
            ),
            child: Text(
              note.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _handwritten(16, 22, FontWeight.w400, palette.textPrimary),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            result ?? text ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: result != null
                ? chromeStyle(
                    size: 13,
                    line: 18,
                    weight: 600,
                    color: palette.resultPillText,
                    tabular: true,
                  )
                : _figtree(13, 18, FontWeight.w400, palette.textSecondary),
          ),
          const SizedBox(height: 12),
          _MetaRow(
            date: date,
            day: day,
            done: glance.done,
            boxes: glance.boxes,
            types: const [],
            locked: locked,
            shared: shared,
            tags: TagMarks.of(context, note.id),
            ground: fill,
            selected: false,
          ),
        ],
      ),
    );
    if (picking == null) return card;
    return Stack(
      children: [
        card,
        Positioned(top: 14, right: 14, child: PickBox(checked: picking)),
      ],
    );
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
    required this.selected,
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

  /// On the open card the quiet words step up a grey, to stay legible on its
  /// lighter fill.
  final bool selected;

  static const double _glyph = 14;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final ink = selected ? palette.textSecondary : palette.textTertiary;
    final style = DefaultTextStyle.of(
      context,
    ).style.merge(_figtree(12, 16, FontWeight.w400, ink));
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
            KapyIcon(glyph, size: _glyph, color: ink),
          if (first != null)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TagDots(tags: tags),
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
                fill: ink,
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
    this.live,
    this.viewOnly = false,
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

  /// Who is typing in the note, or in it, which a phone's row says first on
  /// its last line, after a sage dot. Null while nobody else is.
  final String? live;

  /// Somebody else's note this account may only read, which a phone's row
  /// says on its last line.
  final bool viewOnly;

  /// The folders the note is in, as "Work › Clients", which start the second
  /// line in the date's quieter ink. Null for a note in no folder.
  final String? place;

  /// Who a shared note is open to, at the end of a phone's last line.
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
    final people = this.people;
    // What the note holds shows while the row is under the pointer or open;
    // whether it is locked or shared always does.
    final marks = touch
        ? const <KapyIconData>[]
        : _marksOf(
            hovering || selected ? glance.media : const {},
            locked: locked,
            shared: shared,
          );
    final holds = touch ? _holdsOf(palette) : const <Widget>[];
    final summary = snippet ?? (note.isEmpty ? 'Empty' : glance.preview ?? '');
    // A phone's note with nothing to preview goes from its title straight to
    // its bottom line, or ends at the title when it has none.
    final previewed =
        !touch || snippet != null || place != null || summary.isNotEmpty;
    final bottom = holds.isNotEmpty || (!previewed && people != null);
    final picking = this.picking;
    final marked = selected || picking == true;
    final tagMarks = TagMarks.of(context, note.id);
    final first = tagMarks.firstOrNull;
    // The border is always there, clear unless the row is ringed, so a ring
    // does not nudge its text. Open, a row takes a fill, never an outline.
    return Container(
      padding: touch
          ? const EdgeInsets.symmetric(horizontal: 20, vertical: 12)
          : const EdgeInsets.all(6.5),
      decoration: BoxDecoration(
        color: marked
            ? palette.fillSelected
            : hovering
            ? palette.fillControl
            : null,
        borderRadius: touch ? null : BorderRadius.circular(AppRadii.surface),
        border: touch
            ? null
            : Border.all(
                color: ringed
                    ? palette.selectedBorder.withValues(alpha: 0.5)
                    : Colors.transparent,
                width: 1.5,
              ),
      ),
      child: Row(
        children: [
          if (picking != null) ...[
            PickBox(checked: picking),
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
                        child: first == null ? null : TagDots(tags: [first]),
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
                                17,
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
                    if (touch) ...[
                      Text(
                        date,
                        maxLines: 1,
                        style: chromeStyle(
                          size: 13,
                          line: 16,
                          weight: AppWeight.axisOf(FontWeight.w400),
                          color: palette.textTertiary,
                          tabular: true,
                        ),
                      ),
                      const SizedBox(width: 8),
                      // The tag dots follow the time in room for the most a
                      // row shows, kept on untagged rows so times line up.
                      SizedBox(
                        width: TagDots.widthFor(TagDots.most),
                        child: tagMarks.isEmpty
                            ? null
                            : Align(
                                alignment: Alignment.centerLeft,
                                child: TagDots(tags: tagMarks),
                              ),
                      ),
                    ] else ...[
                      // How far the checklist has got, before the date, so
                      // the line under the title is the note's own words.
                      if (glance.boxes > 0) ...[
                        Tooltip(
                          message: '${glance.done} of ${glance.boxes} done',
                          child: ChecklistPie(
                            done: glance.done,
                            total: glance.boxes,
                            fill: palette.textTertiary,
                            check: palette.sidebarBackground,
                            size: 12,
                          ),
                        ),
                        const SizedBox(width: 5),
                      ],
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
                  ],
                ),
                if (previewed) ...[
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      if (!touch) SizedBox(width: TagDots.size + 8),
                      for (final mark in marks) ...[
                        KapyIcon(mark, size: 14, color: palette.textMuted),
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
                            touch ? 14 : AppTypeScale.body,
                            touch ? 20 : 16,
                            FontWeight.w400,
                            note.isEmpty
                                ? palette.textTertiary
                                : touch
                                ? palette.textSecondary
                                : palette.textMuted,
                          ),
                        ),
                      ),
                      if (people != null && !bottom) ...[
                        const SizedBox(width: 8),
                        people,
                      ],
                    ],
                  ),
                ],
                if (bottom) ...[
                  const SizedBox(height: 3),
                  Row(
                    key: const ValueKey('note-row-holds'),
                    spacing: 12,
                    children: [
                      // At large text the last holds are cut off at the
                      // edge, so the people at the end stay whole.
                      Expanded(
                        child: UnconstrainedBox(
                          alignment: AlignmentDirectional.centerStart,
                          constrainedAxis: Axis.vertical,
                          clipBehavior: Clip.hardEdge,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            spacing: 12,
                            children: holds,
                          ),
                        ),
                      ),
                      ?people,
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// A phone row's third line: who is in the note, then what it holds: how
  /// far its checklist has got, how long its recordings and videos run, how
  /// many pictures it has, then whether it is read-only or [viewOnly]. Each
  /// is a 14 pt icon 6 from its words, 12 from the next. Empty when it holds
  /// only words and nobody else is in it. Who it is shared with is its
  /// people's faces, or the heading over it in Shared, never a mark here.
  List<Widget> _holdsOf(CalcPalette palette) {
    final ink = palette.textTertiary;
    final words = chromeStyle(
      size: 12,
      line: 16,
      weight: AppWeight.axisOf(FontWeight.w400),
      color: ink,
      tabular: true,
    );
    var voice = Duration.zero;
    var video = Duration.zero;
    var pictures = 0;
    for (final ref in note.attachments) {
      switch (ref) {
        case NoteVoiceRef():
          voice += ref.duration;
        case NoteVideoRef():
          video += ref.duration;
        case NoteImageRef():
          pictures++;
        default:
      }
    }
    Widget hold(Widget icon, [String? text]) => Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 6,
      children: [
        icon,
        if (text != null) Text(text, maxLines: 1, style: words),
      ],
    );
    Widget mark(KapyIconData icon) => KapyIcon(icon, size: 14, color: ink);
    return [
      if (live case final live?)
        Row(
          key: const ValueKey('note-row-live'),
          mainAxisSize: MainAxisSize.min,
          spacing: 6,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: palette.accentText,
                shape: BoxShape.circle,
              ),
            ),
            Text(
              live,
              maxLines: 1,
              style: words.copyWith(color: palette.textSecondary),
            ),
          ],
        ),
      if (glance.boxes > 0)
        hold(
          ChecklistPie(
            done: glance.done,
            total: glance.boxes,
            fill: ink,
            check: palette.sidebarBackground,
          ),
          '${glance.done} of ${glance.boxes}',
        ),
      if (glance.media.contains(NoteMedia.voice))
        hold(mark(NoteMedia.voice.icon), formatVoiceDuration(voice)),
      if (glance.media.contains(NoteMedia.video))
        hold(mark(NoteMedia.video.icon), formatVoiceDuration(video)),
      if (pictures > 0) hold(mark(NoteMedia.image.icon), '$pictures'),
      if (locked) hold(mark(KapyIcons.lockRounded)),
      if (viewOnly) hold(mark(KapyIcons.visibilityOutlined), 'View only'),
    ];
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

/// A drawing as a card in the Drawings space: a thumbnail of it, its title,
/// and the meta row with no type glyph, on the list's quiet card fill.
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
    final marked = selected || picking == true;
    final fill = _cardFill(palette, selected: marked, hovering: hovering);
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 10),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: _cardRadius,
        border: _ringOf(palette, ringed: ringed),
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
                      style: _figtree(
                        13,
                        18,
                        FontWeight.w500,
                        palette.textPrimary,
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
                      ground: fill,
                      selected: marked,
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (picking != null)
            Positioned(top: 4, right: 4, child: PickBox(checked: picking)),
        ],
      ),
    );
  }
}

/// A drawing as a phone's row, full width between hairlines: a small
/// thumbnail of it, then its title in the hand face over its day or time.
class PhoneDrawingRowFace extends StatelessWidget {
  const PhoneDrawingRowFace({
    super.key,
    required this.note,
    required this.date,
    required this.selected,
    required this.hovering,
    this.picking,
  });

  final Note note;
  final String date;
  final bool selected;
  final bool hovering;
  final bool? picking;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final picking = this.picking;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      color: selected || picking == true
          ? palette.fillSelected
          : hovering
          ? palette.fillControl
          : null,
      child: Row(
        children: [
          if (picking != null) ...[
            PickBox(checked: picking),
            const SizedBox(width: 10),
          ],
          Container(
            key: const ValueKey('phone-drawing-thumbnail'),
            width: 64,
            height: 40,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              // Sunk a little below the list it sits on, as on the cards.
              color: Color.alphaBlend(
                Colors.black.withValues(alpha: 0.18),
                palette.sidebarBackground,
              ),
              borderRadius: BorderRadius.circular(AppRadii.compact),
            ),
            child: DrawingThumbnail(drawing: note.drawing),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  note.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _handwritten(
                    17,
                    22,
                    FontWeight.w400,
                    palette.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  date,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _figtree(13, 16, FontWeight.w400, palette.textMuted),
                ),
              ],
            ),
          ),
        ],
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
            ? palette.fillSelected
            : hovering
            ? palette.fillControl
            : null,
        borderRadius: BorderRadius.circular(AppRadii.surface),
        border: Border.all(
          color: ringed
              ? palette.selectedBorder.withValues(alpha: 0.5)
              : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: Row(
        children: [
          if (picking != null) ...[
            PickBox(checked: picking),
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
                      KapyIcon(mark, size: 14, color: palette.textMuted),
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
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              // The count waits in the tooltip, which is also what a screen
              // reader hears after the label.
              child: Tooltip(
                message: count == 1 ? '1 $noun' : '$count ${noun}s',
                child: Semantics(
                  header: true,
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _sectionLabel(palette),
                  ),
                ),
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// "View all", at the end of the Pinned heading. A phone's is larger and
/// quieter, as its Home draws it beside Pinned's serif.
class ViewAllLink extends StatelessWidget {
  const ViewAllLink({super.key, required this.onPressed, this.phone = false});

  final VoidCallback onPressed;
  final bool phone;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final ink = phone ? palette.textSecondary : palette.accentText;
    return Semantics(
      container: true,
      button: true,
      label: 'View all pinned notes',
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
                'View all',
                style: phone
                    ? _figtree(13, 16, FontWeight.w400, ink)
                    : _figtree(AppTypeScale.small, 16, FontWeight.w500, ink),
              ),
              SizedBox(width: phone ? 2 : 1),
              KapyIcon(
                KapyIcons.chevronRightRounded,
                size: phone ? 14 : 12,
                color: ink,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A section label over the notes list: small, quiet and in sentence case,
/// set apart by the space round it rather than by size or a rule.
TextStyle _sectionLabel(CalcPalette palette) => chromeStyle(
  size: 12,
  line: 16,
  weight: AppWeight.section,
  color: palette.textTertiary,
);

/// A count or a date after a section label: the label's size, at rest.
TextStyle _sectionDetail(CalcPalette palette) => chromeStyle(
  size: 12,
  line: 16,
  weight: AppWeight.body,
  color: palette.textTertiary,
  tabular: true,
);

/// The heading over one group of the notes list: a day, a tag or a letter.
class NotesGroupHeading extends StatelessWidget {
  const NotesGroupHeading({super.key, required this.label, this.detail});

  final String label;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final detail = this.detail;
    return SizedBox(
      height: MediaQuery.textScalerOf(context).scale(16),
      child: CustomMultiChildLayout(
        delegate: _GroupHeadingLayout(),
        children: [
          LayoutId(
            id: _GroupHeadingPart.label,
            child: Semantics(
              header: true,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _sectionLabel(palette),
              ),
            ),
          ),
          if (detail != null)
            LayoutId(
              id: _GroupHeadingPart.detail,
              child: Text(
                detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _sectionDetail(palette),
              ),
            ),
        ],
      ),
    );
  }
}

enum _GroupHeadingPart { label, detail }

/// Lays a group heading out: the label takes up to 200 and the count what
/// the label leaves, so a narrow list shortens the words.
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
    final start = label.width + 8;
    if (hasChild(_GroupHeadingPart.detail)) {
      final detail = layoutChild(_GroupHeadingPart.detail, upTo(end - start));
      positionChild(_GroupHeadingPart.detail, centred(detail, start));
    }
  }

  @override
  bool shouldRelayout(_GroupHeadingLayout oldDelegate) => false;
}

/// The ground of the View menu and its submenus.
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

/// Whether the list is narrowed beyond everything its space holds: another
/// Show, some of the kinds, or a tag. What a phone's filter button carries a
/// dot for while the row is put away.
bool filtersNarrowed({
  required NotesShow show,
  required Set<NoteMedia>? media,
  required TagFilter? tags,
}) =>
    show != NotesShow.all ||
    (media != null && media.length < NoteMedia.values.length) ||
    (tags?.narrowed ?? false);

/// How the list is shown and what it holds. Beside the rail it is the View
/// menu's icon beside the search, with what the list shows (Show, When,
/// Media, Tags), how it groups the notes and List or Grid in one menu. A
/// phone's is its filter row instead: a filled pill for the menu, then a
/// pill per tag, scrolling sideways.
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
    this.cards = false,
    this.onCardsChanged,
    this.tags,
    this.onTagsChanged,
    this.when,
    this.onWhenChanged,
    required this.today,
    this.grouping,
    this.onGroupingChanged,
    this.phone = false,
  });

  final NotesShow show;

  /// A phone's filter row.
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
  final bool cards;

  /// Null leaves Layout out of the menu, where the list has no cards.
  final ValueChanged<bool>? onCardsChanged;

  /// The tags the list is narrowed to; null where there are no tags.
  final TagFilter? tags;
  final ValueChanged<TagFilter>? onTagsChanged;

  /// What When narrows the list to; null leaves When out of the menu.
  final NotesWhen? when;
  final ValueChanged<NotesWhen>? onWhenChanged;

  /// The day When's spans count back from, as the list shows days.
  final DateTime today;

  /// How the list groups what Pinned leaves; without a grouping the menu has
  /// no Group by.
  final NotesGrouping? grouping;
  final ValueChanged<NotesGrouping>? onGroupingChanged;

  @override
  Widget build(BuildContext context) {
    final media = this.media;
    final filter = _NotesFilter(
      show: show,
      offersShow: offersShow,
      onShowChanged: onShowChanged,
      hiddenListed: hiddenListed,
      hiddenShortcut: hiddenShortcut,
      archivedCount: archivedCount,
      media: media,
      onMediaChanged: onMediaChanged,
      tags: this.tags,
      onTagsChanged: this.onTagsChanged,
      when: when,
      onWhenChanged: onWhenChanged,
      today: today,
      everything: media == null ? 'All drawings' : NotesShow.all.label,
      grouping: phone ? null : grouping,
      onGroupingChanged: phone ? null : onGroupingChanged,
      cards: cards,
      onCardsChanged: phone ? null : onCardsChanged,
      phone: phone,
    );
    if (!phone) return filter;
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
}

/// What narrows the list, as one quiet chip under the search: every filter
/// that is on, in the View menu's order ("Hidden · Voice, Image · Work ·
/// This week"), ending in "…" where it runs out of room, with the whole of it
/// in the tooltip. Pressed, the list goes back to everything at any time.
class NotesFilterChip extends StatefulWidget {
  const NotesFilterChip({
    super.key,
    required this.show,
    required this.media,
    required this.tags,
    required this.when,
    required this.onClear,
  });

  final NotesShow show;

  /// Null in Drawings, which has no media group.
  final Set<NoteMedia>? media;
  final TagFilter? tags;
  final NotesWhen when;
  final VoidCallback onClear;

  /// Whether anything narrows the list, so there is a chip to show.
  static bool shows({
    required NotesShow show,
    required Set<NoteMedia>? media,
    required TagFilter? tags,
    required NotesWhen when,
  }) =>
      when != NotesWhen.anyTime ||
      filtersNarrowed(show: show, media: media, tags: tags);

  @override
  State<NotesFilterChip> createState() => _NotesFilterChipState();
}

class _NotesFilterChipState extends State<NotesFilterChip> {
  bool _lit = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final media = widget.media;
    final tags = widget.tags ?? const TagFilter();
    final label = [
      if (widget.show != NotesShow.all) widget.show.label,
      if (media != null && media.length < NoteMedia.values.length)
        [
          for (final kind in NoteMedia.values)
            if (media.contains(kind)) kind.label,
        ].join(', '),
      if (tags.narrowed)
        [
          for (final entry
              in TagShelf.maybeOf(context)?.listed() ?? <TagEntry>[])
            if (tags.ids.contains(entry.tag.id)) entry.tag.name.v,
          if (tags.none) 'No tag',
        ].join(', '),
      if (widget.when != NotesWhen.anyTime) widget.when.label,
    ].join(' · ');
    final everything = media == null ? 'All drawings' : NotesShow.all.label;
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: '$label, back to $everything',
        excludeSemantics: true,
        onTap: widget.onClear,
        child: FocusableActionDetector(
          mouseCursor: SystemMouseCursors.click,
          onShowHoverHighlight: (lit) => setState(() => _lit = lit),
          onShowFocusHighlight: (lit) => setState(() => _lit = lit),
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) => widget.onClear(),
            ),
          },
          child: GestureDetector(
            key: const ValueKey('notes-filter-chip'),
            onTap: widget.onClear,
            behavior: HitTestBehavior.opaque,
            child: Container(
              height: 26,
              padding: const EdgeInsets.only(left: 10, right: 8),
              decoration: BoxDecoration(
                color: palette.tonalBackground,
                border: Border.all(
                  color: _lit
                      ? palette.tonalKeyText
                      : palette.tonalKeyBackground,
                ),
                borderRadius: BorderRadius.circular(13),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _figtree(
                        AppTypeScale.small,
                        16,
                        FontWeight.w400,
                        palette.tonalForeground,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
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

/// The View menu's icon and the menu, or a phone's filter pill and popover:
/// one choice of which notes, When with its submenu, the media ticks and
/// Tags, then beside the rail Group by and Layout. Every kind is ticked by
/// default, and unticking kinds narrows the list to notes holding a kind
/// still ticked.
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
    required this.everything,
    required this.grouping,
    required this.onGroupingChanged,
    required this.cards,
    required this.onCardsChanged,
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
  final NotesWhen? when;
  final ValueChanged<NotesWhen>? onWhenChanged;
  final DateTime today;

  /// What the first choice says: All notes, or All drawings.
  final String everything;
  final NotesGrouping? grouping;
  final ValueChanged<NotesGrouping>? onGroupingChanged;
  final bool cards;
  final ValueChanged<bool>? onCardsChanged;

  @override
  State<_NotesFilter> createState() => _NotesFilterState();
}

/// The View menu's submenus, each opened from its row in the menu.
enum _FilterSubmenu { when, tags }

class _NotesFilterState extends State<_NotesFilter> {
  final _menu = OverlayPortalController();
  final _link = LayerLink();
  final _menuKey = GlobalKey();
  final _whenRow = GlobalKey();
  final _tagsRow = GlobalKey();

  /// The open menu's focus, taken as it opens so Escape, Tab and the arrows
  /// work in it at once, and handed back as it closes.
  final _menuScope = FocusScopeNode(debugLabel: 'View menu');

  static const double _submenuWidth = 220;

  @override
  void dispose() {
    _menuScope.dispose();
    super.dispose();
  }

  /// The submenu open beside the menu, or in its place, if any.
  _FilterSubmenu? _submenu;

  /// Whether the open submenu takes the menu's place, with a row back to
  /// it, where the window has no room for it beside the menu.
  bool _inPlace = false;

  /// Where the open submenu's corner goes: beside the menu, level with the
  /// row that opened it. A submenu that would run off the foot of the window
  /// moves up until it fits.
  Offset _submenuAt = Offset.zero;

  /// How tall the menu may be: the room under the icon, measured as it
  /// opens. A short window scrolls the menu rather than cutting it off.
  double _room = double.infinity;

  void _toggleSubmenu(_FilterSubmenu submenu, GlobalKey row) {
    final opener = row.currentContext?.findRenderObject() as RenderBox?;
    final menu = _menuKey.currentContext?.findRenderObject() as RenderBox?;
    final window = MediaQuery.sizeOf(context).width;
    setState(() {
      _submenu = _submenu == submenu ? null : submenu;
      if (opener != null && menu != null) {
        final side = menu.localToGlobal(Offset(menu.size.width + 4, 0)).dx;
        _inPlace = side + _submenuWidth > window - 8;
        _submenuAt = Offset(side, opener.localToGlobal(Offset.zero).dy - 6);
      }
    });
    // In the menu's place, the row that opened it has gone, so the menu's
    // focus starts again at the submenu's first row.
    if (_inPlace) _menuScope.requestFocus();
  }

  void _back() {
    setState(() => _submenu = null);
    _menuScope.requestFocus();
  }

  /// The open submenu, beside the row that opened it or in the menu's place.
  Widget? get _openSubmenu {
    final back = _inPlace
        ? _BackRow(
            label: switch (_submenu) {
              _FilterSubmenu.tags => 'Tags',
              _ => 'When',
            },
            onTap: _back,
          )
        : null;
    return switch (_submenu) {
      _FilterSubmenu.when when widget.when != null => _WhenMenu(
        when: widget.when!,
        today: widget.today,
        onChanged: _chooseWhen,
        back: back,
      ),
      _FilterSubmenu.tags when widget.tags != null => _TagsMenu(
        filter: widget.tags!,
        onChanged: widget.onTagsChanged!,
        back: back,
      ),
      _ => null,
    };
  }

  void _toggle() {
    if (AppPlatform.isMobile) return unawaited(_openPopover());
    final button = context.findRenderObject()! as RenderBox;
    _room = math.max(
      160,
      MediaQuery.sizeOf(context).height -
          button.localToGlobal(Offset(0, button.size.height + 6)).dy -
          MediaQuery.paddingOf(context).bottom -
          12,
    );
    setState(() {
      _submenu = null;
      _menu.isShowing ? _menu.hide() : _menu.show();
    });
    if (!_menu.isShowing) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _menu.isShowing) _menuScope.requestFocus();
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
                  grouping: widget.grouping,
                  onGroupingChanged: widget.onGroupingChanged,
                  cards: widget.cards,
                  onCardsChanged: widget.onCardsChanged,
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

  void _chooseGrouping(NotesGrouping grouping) {
    _close();
    if (grouping != widget.grouping) widget.onGroupingChanged!(grouping);
  }

  void _chooseCards(bool cards) {
    _close();
    if (cards != widget.cards) widget.onCardsChanged!(cards);
  }

  /// A kind is unticked only while another stays ticked: a list narrowed to
  /// nothing would look like a library that had lost its notes.
  void _tick(NoteMedia? media) {
    final ticked = tickedMedia(widget.media!, media);
    if (ticked != null) widget.onMediaChanged!(ticked);
  }

  /// What a phone's pill says: one narrowed group names itself ("Archive",
  /// "Voice, Image", "● Work"); combined, each gives its first choice and
  /// how many more ("Archive · Voice +1 · Work +2"). The dot is the first
  /// tag's, while tags alone narrow.
  ({String text, Tag? dot}) _label() {
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
    return (text: groups.map(part).join(' · '), dot: null);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    if (widget.phone) {
      final pill = _figtree(15, 20, FontWeight.w500, palette.paperColor);
      final (:text, :dot) = _label();
      return Semantics(
        button: true,
        label: 'Notes filter, $text',
        excludeSemantics: true,
        onTap: _toggle,
        child: GestureDetector(
          key: const ValueKey('sidebar-notes-filter'),
          onTap: _toggle,
          behavior: HitTestBehavior.opaque,
          // 30 tall in a 44 target at the regular size, and taller with
          // larger text, so its words are never cut.
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: AppControlMetrics.iconButtonExtent,
            ),
            child: Center(
              child: Container(
                constraints: const BoxConstraints(minHeight: 30),
                padding: const EdgeInsets.fromLTRB(12, 5, 10, 5),
                decoration: BoxDecoration(
                  color: palette.textPrimary,
                  borderRadius: BorderRadius.circular(999),
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
    final button = CompactIconButton(
      key: const ValueKey('notes-view'),
      tooltip: 'View',
      extent: 32,
      radius: 8,
      selected: _menu.isShowing,
      onPressed: _toggle,
      icon: const KapyIcon(KapyIcons.filterRounded, size: 16),
    );
    final submenu = _openSubmenu;
    final menu = submenu != null && _inPlace
        ? submenu
        : _FilterMenu(
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
            when: widget.onWhenChanged == null ? null : widget.when,
            onWhen: () => _toggleSubmenu(_FilterSubmenu.when, _whenRow),
            whenRow: _whenRow,
            onTags: widget.tags == null
                ? null
                : () => _toggleSubmenu(_FilterSubmenu.tags, _tagsRow),
            tagsRow: _tagsRow,
            tags: widget.tags ?? const TagFilter(),
            grouping: widget.onGroupingChanged == null ? null : widget.grouping,
            onGrouping: _chooseGrouping,
            cards: widget.onCardsChanged == null ? null : widget.cards,
            onCards: _chooseCards,
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
            // The arrows walk the rows as Tab does, and Space or Enter
            // chooses the one in focus.
            child: Shortcuts(
              shortcuts: const {
                SingleActivator(LogicalKeyboardKey.arrowDown):
                    NextFocusIntent(),
                SingleActivator(LogicalKeyboardKey.arrowUp):
                    PreviousFocusIntent(),
              },
              child: FocusScope(
                node: _menuScope,
                child: Stack(
                  children: [
                    // Under the icon, right-aligned to it, so the menu stays
                    // inside a list that runs to the window's edge.
                    Align(
                      alignment: Alignment.topLeft,
                      child: CompositedTransformFollower(
                        link: _link,
                        targetAnchor: Alignment.bottomRight,
                        followerAnchor: Alignment.topRight,
                        offset: const Offset(0, 6),
                        child: TapRegion(
                          groupId: _menu,
                          child: submenu != null && _inPlace
                              ? menu
                              : ConstrainedBox(
                                  constraints: BoxConstraints(maxHeight: _room),
                                  child: menu,
                                ),
                        ),
                      ),
                    ),
                    if (submenu != null && !_inPlace)
                      CustomSingleChildLayout(
                        delegate: PopoverAtPoint(_submenuAt),
                        child: TapRegion(groupId: _menu, child: submenu),
                      ),
                  ],
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

/// The row over a submenu that has taken the View menu's place: "‹ When",
/// back to the menu.
class _BackRow extends StatelessWidget {
  const _BackRow({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ShowMenuRow(
          key: const ValueKey('notes-view-back'),
          label: label,
          leading: KapyIcon(
            KapyIcons.chevronLeftRounded,
            size: 12,
            color: palette.textTertiary,
          ),
          semanticLabel: 'Back to the View menu',
          chosen: false,
          onTap: onTap,
        ),
        Container(
          height: 1,
          margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          color: palette.separator,
        ),
      ],
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
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: AppControlMetrics.iconButtonExtent,
          ),
          child: Center(
            child: Container(
              constraints: const BoxConstraints(minHeight: 30),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: on ? palette.tonalBackground : null,
                border: Border.all(
                  color: on
                      ? palette.tonalKeyBackground
                      : palette.controlBorder,
                ),
                borderRadius: BorderRadius.circular(999),
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

/// The View menu: Show with When, Media, Tags, then Group by and Layout. A
/// tick marks a single choice and a box a Media choice.
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
    required this.grouping,
    required this.onGrouping,
    required this.cards,
    required this.onCards,
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
  final NotesWhen? when;

  /// Opens or closes the When submenu.
  final VoidCallback onWhen;
  final Key whenRow;

  /// Opens or closes the Tags submenu; null leaves Tags out.
  final VoidCallback? onTags;
  final Key tagsRow;

  /// What the Tags submenu has ticked, named before its chevron.
  final TagFilter tags;

  /// How the list groups its notes; null leaves Group by out.
  final NotesGrouping? grouping;
  final ValueChanged<NotesGrouping> onGrouping;

  /// Whether the list shows cards; null leaves Layout out.
  final bool? cards;
  final ValueChanged<bool> onCards;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final media = this.media;
    final hiddenShortcut = this.hiddenShortcut;
    final grouping = this.grouping;
    final cards = this.cards;
    Widget choice(NotesShow choice, {Widget? trailing}) => _ShowMenuRow(
      key: ValueKey('notes-filter-${choice.name}'),
      label: choice == NotesShow.all ? everything : choice.label,
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
    Widget opens(Widget value) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        value,
        const SizedBox(width: 6),
        KapyIcon(
          KapyIcons.chevronRightRounded,
          size: 12,
          color: palette.textTertiary,
        ),
      ],
    );
    final groups = <List<Widget>>[
      if (offersShow || when != null)
        [
          if (offersShow) ...[
            heading('Show'),
            choice(NotesShow.all),
            if (hiddenListed) ...[
              const SizedBox(height: 1),
              choice(
                NotesShow.hidden,
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
              trailing: Text('$archivedCount', style: quiet),
            ),
          ],
          if (when != null) ...[
            if (offersShow) const SizedBox(height: 1),
            KeyedSubtree(
              key: whenRow,
              child: _ShowMenuRow(
                key: const ValueKey('notes-filter-when'),
                label: 'When',
                chosen: false,
                trailing: opens(Text(when.label, style: quiet)),
                onTap: onWhen,
              ),
            ),
          ],
        ],
      if (media != null || onTags != null)
        [
          if (media != null) ...[
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
                ticked: media.contains(kind),
                onTap: () => onTick(kind),
              ),
            ],
          ],
          if (onTags case final onTags?) ...[
            if (media != null) const SizedBox(height: 1),
            KeyedSubtree(
              key: tagsRow,
              child: _ShowMenuRow(
                key: const ValueKey('notes-filter-tags'),
                label: 'Tags',
                chosen: false,
                trailing: opens(
                  tags.ticked == 0
                      ? Text('All', style: quiet)
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
      if (grouping != null)
        [
          heading('Group by'),
          for (final (index, each) in NotesGrouping.values.indexed) ...[
            if (index > 0) const SizedBox(height: 1),
            _ShowMenuRow(
              key: ValueKey('notes-grouping-${each.name}'),
              label: each.label,
              chosen: each == grouping,
              onTap: () => onGrouping(each),
            ),
          ],
        ],
      if (cards != null)
        [
          heading('Layout'),
          _ShowMenuRow(
            key: const ValueKey('notes-layout-list'),
            label: 'List',
            chosen: !cards,
            onTap: () => onCards(false),
          ),
          const SizedBox(height: 1),
          _ShowMenuRow(
            key: const ValueKey('notes-layout-grid'),
            label: 'Grid',
            chosen: cards,
            onTap: () => onCards(true),
          ),
        ],
    ];

    return Container(
      key: const ValueKey('notes-filter-menu'),
      width: 232,
      padding: const EdgeInsets.all(6),
      decoration: _menuSurface(palette),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (index, group) in groups.indexed) ...[
              if (index > 0) rule(),
              ...group,
            ],
          ],
        ),
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

/// A row of the View menu that the pointer, Tab and the arrows all reach,
/// lit while it is under the pointer or in focus. Space or Enter presses it.
class _MenuRowFrame extends StatefulWidget {
  const _MenuRowFrame({required this.onTap, required this.builder, this.fill});

  final VoidCallback onTap;
  final Widget Function(bool lit) builder;

  /// The row's own fill at rest, as the chosen one has.
  final Color? fill;

  @override
  State<_MenuRowFrame> createState() => _MenuRowFrameState();
}

class _MenuRowFrameState extends State<_MenuRowFrame> {
  bool _hovering = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final lit = _hovering || _focused;
    return FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      onShowHoverHighlight: (on) => setState(() => _hovering = on),
      onShowFocusHighlight: (on) => setState(() => _focused = on),
      onFocusChange: (focused) {
        if (focused) unawaited(Scrollable.ensureVisible(context));
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) => widget.onTap(),
        ),
      },
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: widget.fill ?? (lit ? palette.hover : null),
            border: _focused ? Border.all(color: palette.selectedBorder) : null,
            borderRadius: BorderRadius.circular(AppRadii.compact),
          ),
          child: widget.builder(lit),
        ),
      ),
    );
  }
}

/// One of the menu's single choices: the chosen one lit, with a tick where
/// the others show their shortcut, count or value.
class _ShowMenuRow extends StatelessWidget {
  const _ShowMenuRow({
    super.key,
    required this.label,
    required this.chosen,
    required this.onTap,
    this.leading,
    this.trailing,
    this.semanticLabel,
  });

  final String label;
  final bool chosen;
  final VoidCallback onTap;
  final Widget? leading;
  final Widget? trailing;

  /// What a screen reader hears, where it differs from [label].
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final trailing = chosen
        ? KapyIcon(KapyIcons.checkRounded, size: 14, color: palette.accentText)
        : this.trailing;
    return Semantics(
      selected: chosen,
      button: true,
      label: semanticLabel ?? label,
      excludeSemantics: true,
      onTap: onTap,
      child: _MenuRowFrame(
        onTap: onTap,
        fill: chosen ? palette.separator : null,
        builder: (_) => Row(
          children: [
            if (leading case final leading?) ...[
              leading,
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text(
                label,
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
    );
  }
}

/// One of the menu's Media choices, with its box at the end.
class _MediaMenuRow extends StatelessWidget {
  const _MediaMenuRow({
    super.key,
    required this.label,
    required this.ticked,
    required this.onTap,
  });

  final String label;
  final bool ticked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      checked: ticked,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: _MenuRowFrame(
        onTap: onTap,
        builder: (_) => Row(
          children: [
            Expanded(
              child: Text(
                label,
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
            const SizedBox(width: 9),
            PickBox(checked: ticked),
          ],
        ),
      ),
    );
  }
}

/// The filter's When submenu, beside the When row: each span with the days
/// it covers, and a tick on the one the list reaches back over.
class _WhenMenu extends StatelessWidget {
  const _WhenMenu({
    required this.when,
    required this.today,
    required this.onChanged,
    this.back,
  });

  final NotesWhen when;
  final DateTime today;
  final ValueChanged<NotesWhen> onChanged;

  /// The row back to the View menu, where this has taken its place.
  final Widget? back;

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
          ?back,
          for (final (index, span) in NotesWhen.values.indexed) ...[
            if (index > 0) const SizedBox(height: 1),
            row(span),
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
  const _TagsMenu({required this.filter, required this.onChanged, this.back});

  final TagFilter filter;
  final ValueChanged<TagFilter> onChanged;

  /// The row back to the View menu, where this has taken its place.
  final Widget? back;

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
              ?widget.back,
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
          ?widget.back,
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
                PickBox(checked: widget.ticked),
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
    required this.grouping,
    required this.onGroupingChanged,
    required this.cards,
    required this.onCardsChanged,
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

  /// A tablet's Group by and Layout, as the View menu has them beside the
  /// rail; a phone's list has neither here.
  final NotesGrouping? grouping;
  final ValueChanged<NotesGrouping>? onGroupingChanged;
  final bool cards;
  final ValueChanged<bool>? onCardsChanged;

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

  /// A single choice of Group by or Layout, ticked while it is the one.
  Widget _pick(Key key, String label, bool chosen, VoidCallback onChosen) =>
      _row(
        key: key,
        label: label,
        chosen: chosen,
        trailing: chosen
            ? KapyIcon(
                KapyIcons.checkRounded,
                size: 16,
                color: context.palette.accentText,
              )
            : null,
        onTap: () {
          Navigator.of(context).pop();
          if (!chosen) onChosen();
        },
      );

  Widget _row({
    required Key key,
    Widget? leading,
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
              ?leading,
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
        if ((widget.grouping, widget.onGroupingChanged) case (
          final grouping?,
          final onChanged?,
        )) ...[
          _heading('Group by'),
          for (final each in NotesGrouping.values)
            _pick(
              ValueKey('notes-grouping-${each.name}'),
              each.label,
              each == grouping,
              () => onChanged(each),
            ),
        ],
        if (widget.onCardsChanged case final onChanged?) ...[
          _heading('Layout'),
          _pick(
            const ValueKey('notes-layout-list'),
            'List',
            !widget.cards,
            () => onChanged(false),
          ),
          _pick(
            const ValueKey('notes-layout-grid'),
            'Grid',
            widget.cards,
            () => onChanged(true),
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
          PickBox(checked: ticked),
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
                                fontWeight: AppWeight.font(AppWeight.button),
                                fontVariations: AppWeight.wght(
                                  AppWeight.button,
                                ),
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
