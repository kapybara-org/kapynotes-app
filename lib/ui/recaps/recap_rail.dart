import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../data/note.dart';
import '../../data/task_board.dart';
import '../../recaps/recap_digest.dart';
import '../../recaps/recap_maker.dart';
import '../../recaps/recap_period.dart';
import '../../recaps/recap_timeline.dart';
import '../sidebar_timestamp.dart';
import 'recap_drawer.dart';

/// What Home's notes list needs to lay its notes out on the timeline's rail.
class SidebarTimeline {
  const SidebarTimeline({
    required this.notes,
    required this.tasks,
    required this.firstWeekday,
    required this.folds,
    this.reveal,
    this.recaps,
  });

  /// NotesStore's active notes, which the folded cards count: never notes
  /// waiting to be deleted.
  final List<Note> notes;
  final TaskBoard tasks;

  /// The [DateTime.weekday] weeks start on.
  final int firstWeekday;

  /// Which cards are open, for as long as the app runs.
  final RecapFolds folds;

  /// The note whose cards open once, so it is in view: the note open, or on
  /// a phone the note just left, which the list doesn't light.
  final String? reveal;

  /// What each row's recap icon makes and opens. Null where Kapy AI isn't
  /// there to make one, and then no row draws an icon.
  final ({RecapMaker maker, RecapDrawerHooks hooks})? recaps;
}

/// How a row on the rail names [period] aloud and in its icon's labels:
/// "Sun 16", "10–16 November", "October" or "2025".
String recapSpokenLabel(RecapPeriod period) {
  final first = period.first;
  final last = period.last;
  return switch (period.kind) {
    RecapKind.day => period.label,
    RecapKind.week when first.month == last.month =>
      '${first.day}–${last.day} ${SidebarTimestamp.monthName(last)}',
    RecapKind.week =>
      '${first.day} ${SidebarTimestamp.monthName(first)} – '
          '${last.day} ${SidebarTimestamp.monthName(last)}',
    RecapKind.month => SidebarTimestamp.monthName(first),
    RecapKind.year => '${first.year}',
  };
}

/// [counts] as a screen reader says them: "14 notes, 9 tasks done, 2 voice
/// notes", leaving out what is none.
String recapSpokenCounts(RecapCounts counts) {
  String count(int n, String one, String many) => '$n ${n == 1 ? one : many}';
  return [
    if (counts.notes > 0) count(counts.notes, 'note', 'notes'),
    if (counts.tasksDone > 0)
      count(counts.tasksDone, 'task done', 'tasks done'),
    if (counts.voiceNotes > 0)
      count(counts.voiceNotes, 'voice note', 'voice notes'),
  ].join(', ');
}

/// The heading over the folded cards a [RecapSectionRow] gathers: "Earlier
/// in November", "Earlier in 2026" or "Earlier years".
String recapSectionLabel(RecapPeriod? period) => switch (period) {
  RecapPeriod(kind: RecapKind.month, :final first) =>
    'Earlier in ${SidebarTimestamp.monthName(first)}',
  RecapPeriod(kind: RecapKind.year, :final first) => 'Earlier in ${first.year}',
  _ => 'Earlier years',
};

/// The rail behind a row of the timeline: a dotted line down the rail's
/// column, from [start] to the row's foot. Painted only, so screen readers
/// never meet it.
class RecapRailLine extends StatelessWidget {
  const RecapRailLine({
    super.key,
    required this.x,
    required this.child,
    this.start = 0,
  });

  /// Where the line runs, from the row's left edge.
  final double x;

  /// How far down the row the line starts: the first node's middle on the
  /// first row, and the top on every other.
  final double start;
  final Widget child;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _RailPainter(
      x: x,
      start: start,
      color: context.palette.timelineLine,
    ),
    child: child,
  );
}

class _RailPainter extends CustomPainter {
  _RailPainter({required this.x, required this.start, required this.color});

  final double x;
  final double start;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const width = AppTimeline.rail;
    final paint = Paint()..color = color;
    for (var y = start + width / 2; y < size.height; y += width * 2) {
      canvas.drawCircle(Offset(x, y), width / 2, paint);
    }
  }

  @override
  bool shouldRepaint(_RailPainter old) =>
      old.x != x || old.start != start || old.color != color;
}

/// A heading's line from its words to its recap icon: [AppTimeline.rowLine]
/// dots in the rail's colour.
class _RowLine extends StatelessWidget {
  const _RowLine();

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size(double.infinity, AppTimeline.rowLine),
    painter: _RowLinePainter(context.palette.timelineLine),
  );
}

class _RowLinePainter extends CustomPainter {
  _RowLinePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const width = AppTimeline.rowLine;
    final paint = Paint()..color = color;
    // On whole pixels, so every heading's dots stay dots rather than
    // blurring into a solid line where the row lands between pixels.
    final at = canvas.getTransform();
    final dx = at[12].roundToDouble() - at[12];
    final y = (at[13] + size.height / 2).roundToDouble() - at[13];
    for (var x = dx; x + width <= size.width; x += width * 2) {
      if (x < 0) continue;
      canvas.drawRect(Rect.fromLTWH(x, y - width / 2, width, width), paint);
    }
  }

  @override
  bool shouldRepaint(_RowLinePainter old) => old.color != color;
}

/// What sits on the rail beside a row: a dot for a day, larger for today; a
/// hollow ring for a week; a firm ring for a month; an orange mark for a
/// year. Each covers the rail behind it, and none reaches a screen reader.
class RecapNode extends StatelessWidget {
  const RecapNode({
    super.key,
    required this.kind,
    required this.ground,
    this.today = false,
  });

  final RecapKind kind;

  /// The list's ground, which a hollow ring is filled with.
  final Color ground;
  final bool today;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final (size, fill, border) = switch (kind) {
      RecapKind.day when today => (9.0, palette.textPrimary, null),
      RecapKind.day => (7.0, palette.textTertiary, null),
      RecapKind.week => (
        9.0,
        ground,
        Border.all(color: palette.textTertiary, width: 1.5),
      ),
      RecapKind.month => (
        11.0,
        ground,
        Border.all(color: palette.textPrimary, width: 2),
      ),
      RecapKind.year => (
        13.0,
        Theme.of(context).colorScheme.primaryContainer,
        Border.all(color: palette.accentText, width: 2),
      ),
    };
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: fill,
          shape: BoxShape.circle,
          border: border,
        ),
      ),
    );
  }
}

/// A row on the rail: its [node], if any, centred in the rail's column, and
/// the row itself beside it.
class RecapRailRow extends StatelessWidget {
  const RecapRailRow({
    super.key,
    required this.phone,
    required this.child,
    this.node,
  });

  final bool phone;
  final Widget? node;
  final Widget child;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(
        width: AppTimeline.column(phone: phone),
        child: Center(child: node),
      ),
      Expanded(child: child),
    ],
  );
}

/// The height of a heading on the rail, a day's or a section's, before
/// the reader's text size.
double recapHeadingHeight({required bool phone}) => phone ? 44 : 28;

/// A heading on the rail: a day's words, or a section's, starting on the
/// note titles' edge ([axis]), then a dotted line to the period's recap
/// icon. With no icon there is no line either.
class RecapHeading extends StatelessWidget {
  const RecapHeading({
    super.key,
    required this.phone,
    required this.axis,
    required this.title,
    this.icon,
  });

  final bool phone;
  final double axis;
  final Widget title;
  final Widget? icon;

  @override
  Widget build(BuildContext context) {
    final icon = this.icon;
    return SizedBox(
      height: MediaQuery.textScalerOf(
        context,
      ).scale(recapHeadingHeight(phone: phone)),
      child: Padding(
        padding: EdgeInsets.only(left: axis, right: phone ? 4 : 0),
        // The words take what they need, short of the icon and a little
        // line, and the line takes the rest.
        child: LayoutBuilder(
          builder: (context, constraints) => Row(
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: icon == null
                      ? constraints.maxWidth
                      : math.max(0, constraints.maxWidth - (phone ? 88 : 60)),
                ),
                child: title,
              ),
              if (icon != null) ...[
                SizedBox(width: phone ? 14 : 12),
                const Expanded(child: _RowLine()),
                const SizedBox(width: 8),
                icon,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A day's words on the rail, sized to themselves so the heading's line
/// takes the rest: on a phone "Today" at 17/600 with "Thu 19" quieter at 15
/// 6 after it, and on a desktop "Today" at 13/600.
class RecapDayTitle extends StatelessWidget {
  const RecapDayTitle({
    super.key,
    required this.label,
    this.date,
    required this.phone,
  });

  final String label;
  final String? date;
  final bool phone;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final date = this.date;
    return Semantics(
      header: true,
      label: [label, ?date].join(', '),
      excludeSemantics: true,
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: label),
            if (date != null) ...[
              const WidgetSpan(child: SizedBox(width: 6)),
              TextSpan(
                text: date,
                style: chromeStyle(
                  size: 15,
                  line: 22,
                  weight: AppWeight.regular,
                  color: palette.textTertiary,
                  tabular: true,
                ),
              ),
            ],
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: chromeStyle(
          size: phone ? 17 : 13,
          line: phone ? 22 : 16,
          weight: AppWeight.semibold,
          color: palette.textPrimary,
          tabular: true,
        ),
      ),
    );
  }
}

/// A section's words over its folded cards: Geist 13/600 on a phone and
/// 12/600 on a desktop, tracked open, in a quiet grey.
class RecapSectionTitle extends StatelessWidget {
  const RecapSectionTitle(this.label, {super.key, required this.phone});

  final String label;
  final bool phone;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      header: true,
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: chromeStyle(
          size: phone ? 13 : 12,
          line: 16,
          weight: AppWeight.semibold,
          color: phone || !dark ? palette.textSecondary : palette.textTertiary,
          letterSpacing: phone ? 0.2 : 0.25,
        ),
      ),
    );
  }
}

/// An earlier week, month or year on the rail: folded, a card with its name
/// and counts; open, the same words as a header over what it holds. A tap
/// on either opens or folds it. Its recap icon keeps the column the
/// headings' icons sit in.
class RecapPeriodCard extends StatelessWidget {
  const RecapPeriodCard({
    super.key,
    required this.period,
    required this.counts,
    required this.open,
    required this.phone,
    required this.axis,
    required this.onToggle,
    this.icon,
  });

  final RecapPeriod period;
  final RecapCounts counts;
  final bool open;
  final bool phone;
  final double axis;
  final VoidCallback onToggle;
  final Widget? icon;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final countsStyle = chromeStyle(
      size: phone ? 13 : 12,
      line: phone ? 16 : 14,
      weight: AppWeight.regular,
      color: palette.textSecondary,
      tabular: true,
    );
    final words = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 4,
      children: [
        Text(
          period.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: chromeStyle(
            size: phone ? 15 : 13,
            line: phone ? 20 : 16,
            weight: open ? AppWeight.semibold : AppWeight.medium,
            color: palette.textPrimary,
            tabular: true,
          ),
        ),
        Text.rich(
          TextSpan(
            children: [
              for (final (index, part) in counts.line.split(' · ').indexed) ...[
                if (index > 0)
                  TextSpan(
                    text: ' · ',
                    style: TextStyle(color: palette.textTertiary),
                  ),
                TextSpan(text: part),
              ],
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: countsStyle,
        ),
      ],
    );
    final row = Padding(
      padding: EdgeInsets.only(
        left: axis,
        right: phone ? 4 : 10,
        top: phone ? 12 : 0,
        bottom: phone ? 12 : 0,
      ),
      child: Row(
        children: [
          Expanded(child: words),
          const SizedBox(width: 8),
          ExcludeSemantics(
            child: KapyIcon(
              open ? KapyIcons.chevronUpRounded : KapyIcons.chevronDownRounded,
              size: phone ? 18 : 14,
              color: palette.textSecondary,
            ),
          ),
          if (icon case final icon?) ...[const SizedBox(width: 8), icon],
        ],
      ),
    );
    final height = MediaQuery.textScalerOf(context).scale(phone ? 52 : 54);
    final face = ConstrainedBox(
      constraints: BoxConstraints(minHeight: height),
      child: Align(alignment: Alignment.centerLeft, child: row),
    );
    return Semantics(
      container: true,
      button: true,
      label:
          '${recapSpokenLabel(period)}, ${recapSpokenCounts(counts)}, '
          '${open ? 'open' : 'folded'}',
      hint: open ? 'Double-tap to fold.' : 'Double-tap to open.',
      onTap: onToggle,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onToggle,
          child: open
              ? face
              : DecoratedBox(
                  decoration: BoxDecoration(
                    color: palette.cardBackground,
                    borderRadius: BorderRadius.circular(
                      phone ? AppRadii.phoneList : AppRadii.card,
                    ),
                  ),
                  child: face,
                ),
        ),
      ),
    );
  }
}

/// A period's recap icon, Hugeicons LayersLogo, in a 44 pt target on a phone
/// and 24 px on a desktop. Grey when a recap can be made, orange on a tint
/// once made, faded when there is too little, with a clock-style pie while
/// the period is still going, and a pie filling in the tint while a recap is
/// being made, read live from [RecapMaker.progressOf]. A tap opens the recap
/// drawer: a sheet on a phone, a popover at the icon on a desktop. Too
/// little says why instead.
class RecapIcon extends StatelessWidget {
  const RecapIcon({
    super.key,
    required this.period,
    required this.state,
    required this.maker,
    required this.hooks,
    required this.phone,
    required this.ground,
  });

  final RecapPeriod period;

  /// What the timeline says of it, which [maker] overrides while a recap of
  /// it is being made or once one is.
  final RecapState state;
  final RecapMaker maker;
  final RecapDrawerHooks hooks;
  final bool phone;

  /// What the icon sits on, which the going pie's disc is cut from.
  final Color ground;

  /// What it shows now: one being made first, then one made, then the
  /// timeline's own say.
  RecapStage _stage() {
    if (maker.progressOf(period) != null) return RecapStage.making;
    if (maker.hasRecap(period)) return RecapStage.made;
    return switch (state.stage) {
      RecapStage.made || RecapStage.making =>
        period.isOngoing(maker.today) ? RecapStage.going : RecapStage.ready,
      final stage => stage,
    };
  }

  /// What a screen reader says of it in [stage].
  String _label(RecapStage stage) {
    final name = recapSpokenLabel(period);
    final on = period.kind == RecapKind.day ? 'on' : 'in';
    return switch (stage) {
      RecapStage.ready => 'Make a recap of $name',
      RecapStage.made => 'Watch the recap of $name',
      RecapStage.tooLittle => 'Too little $on $name for a recap',
      RecapStage.going => 'Recap of $name so far',
      RecapStage.making => switch (maker.progressOf(period)) {
        (:final made, :final parts) =>
          'Making the recap of $name, $made of $parts parts done',
        null => 'Making the recap of $name',
      },
    };
  }

  void _open(BuildContext context) {
    final box = phone ? null : context.findRenderObject();
    final pane = Scrollable.maybeOf(context)?.context.findRenderObject();
    Rect? anchor;
    if (box is RenderBox) {
      final icon = box.localToGlobal(Offset.zero) & box.size;
      final edge = pane is RenderBox
          ? pane.localToGlobal(Offset(pane.size.width, 0)).dx
          : icon.right;
      anchor = Rect.fromLTRB(icon.left, icon.top, edge, icon.bottom);
    }
    showRecapDrawer(
      context,
      period,
      maker: maker,
      hooks: hooks,
      anchor: anchor,
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: maker,
    builder: (context, _) {
      final stage = _stage();
      final words = _label(stage);
      final target = SizedBox.square(
        dimension: phone ? 44 : 24,
        child: Center(child: _glyph(context, stage)),
      );
      return Semantics(
        container: true,
        button: true,
        label: words,
        onTap: () => _open(context),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _open(context),
            child: target,
          ),
        ),
      );
    },
  );

  Widget _glyph(BuildContext context, RecapStage stage) {
    final palette = context.palette;
    final size = phone ? 20.0 : 16.0;
    final disc = phone ? 30.0 : 22.0;
    Widget icon(Color color, {double? at}) =>
        KapyIcon(KapyIcons.recapOutlined, size: at ?? size, color: color);
    Widget tinted(Widget child) => Container(
      width: disc,
      height: disc,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        shape: BoxShape.circle,
      ),
      child: child,
    );
    switch (stage) {
      case RecapStage.ready:
        return icon(palette.textSecondary);
      case RecapStage.tooLittle:
        return icon(palette.textDivider);
      case RecapStage.made:
        return tinted(icon(palette.accentText, at: phone ? 18 : 14));
      case RecapStage.making:
        final progress = maker.progressOf(period);
        return tinted(
          RecapPie(
            key: const ValueKey('recap-making-pie'),
            share: progress == null || progress.parts == 0
                ? 0
                : progress.made / progress.parts,
            color: palette.accentText,
            size: phone ? 16 : 12,
          ),
        );
      case RecapStage.going:
        final badge = phone ? 15.0 : 11.0;
        return SizedBox.square(
          dimension: size,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              icon(palette.textSecondary),
              Positioned(
                right: phone ? -3 : -2,
                bottom: phone ? -3 : -1,
                child: Container(
                  width: badge,
                  height: badge,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: ground,
                    shape: BoxShape.circle,
                  ),
                  child: RecapPie(
                    key: const ValueKey('recap-going-pie'),
                    share: state.passed,
                    color: palette.textTertiary,
                    size: phone ? 12 : 9,
                  ),
                ),
              ),
            ],
          ),
        );
    }
  }
}

/// A clock-style pie: a thin ring, and a wedge from twelve o'clock filling
/// clockwise to [share].
class RecapPie extends StatelessWidget {
  const RecapPie({
    super.key,
    required this.share,
    required this.color,
    required this.size,
  });

  final double share;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(size),
    painter: _PiePainter(share.clamp(0, 1).toDouble(), color),
  );
}

class _PiePainter extends CustomPainter {
  _PiePainter(this.share, this.color);

  final double share;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    final stroke = size.shortestSide / 8;
    canvas.drawCircle(
      center,
      radius - stroke / 2,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke,
    );
    if (share <= 0) return;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius - stroke * 1.5),
      -math.pi / 2,
      share * 2 * math.pi,
      true,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_PiePainter old) =>
      old.share != share || old.color != color;
}
