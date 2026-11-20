import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../data/note.dart';
import 'compact_icon_button.dart';
import 'context_menu.dart';
import 'note_tabs.dart' show clickOpensTabBehind;
import 'notes_grouping.dart';
import 'sidebar_timestamp.dart';
import 'tag_ui.dart' show PopoverAtPoint;

TextStyle _figtree(double size, double line, FontWeight weight, Color color) =>
    chromeStyle(
      size: size,
      line: line,
      weight: AppWeight.axisOf(weight),
      color: color,
    );

const _figures = [FontFeature.tabularFigures()];

/// A day as the keys of the week and the calendar name it: "2026-11-7".
String _date(DateTime day) => '${day.year}-${day.month}-${day.day}';

/// How many notes a day holds: "No notes", "1 note", "3 notes".
String _noteCount(int count) => switch (count) {
  0 => 'No notes',
  1 => '1 note',
  _ => '$count notes',
};

/// A day as a screen reader says it: "Today, Thursday, 19 November, 3 notes".
String _spoken(DateTime day, {required bool today, required int notes}) => [
  if (today) 'Today',
  SidebarTimestamp.fullDay(day),
  _noteCount(notes),
].join(', ');

/// The page's days, between its month and its actions, on one line: ‹, the
/// week, ›. Seven days with today in the middle (Sun 16 to Sat 22 when today
/// is Wed 19), and five, three, or today alone on a narrower page. ‹ and ›
/// move a week at a time. A day has a dot for each of its notes, up to three.
///
/// A click on a day with notes narrows the list to it, and a click on a day
/// with none opens a page to write on that day. The month opens a calendar
/// that picks a day the same way.
class DayStrip extends StatefulWidget {
  const DayStrip({
    super.key,
    required this.today,
    required this.when,
    required this.onWhenChanged,
    required this.notes,
    required this.displayTime,
    required this.firstWeekday,
    this.ownDay,
    this.onOpenNote,
    this.onWriteOn,
    this.compact = false,
  });

  /// The day the list shows as today.
  final DateTime today;

  /// What When narrows the list to. The day it picks is filled, and while it
  /// picks none, today is, only to mark it.
  final WhenFilter when;
  final ValueChanged<WhenFilter> onWhenChanged;

  /// What the days count: the notes the list or the folder in front shows
  /// with its tags and Show, on any day.
  final List<Note> notes;
  final DateTime Function(DateTime) displayTime;

  /// The day a note was given, where it has one: those waiting for a later
  /// day have their dots on it, and no note of theirs sits on its last edit.
  final DateTime? Function(Note note)? ownDay;

  /// The [DateTime.weekday] the calendar's weeks start on.
  final int firstWeekday;

  /// Set while there is no list on screen to narrow: a day then lists its
  /// notes under the strip, and the one picked there opens, in a tab behind
  /// on ⌘-click.
  final void Function(String noteId, {required bool behind})? onOpenNote;

  /// A day with no notes picked in the strip or the calendar: a page opens to
  /// write that day, and no note exists until the first letter.
  final ValueChanged<DateTime>? onWriteOn;

  /// One button for the picked day in place of the week.
  final bool compact;

  /// The chip a day sits in, and the room the whole week needs at [days] of
  /// them: the chips, 2 between them, and a 24 arrow with 2 clear at each end.
  /// Seven days need 540, five 400, three 260, and today alone 120.
  static const double _dayWidth = 68;
  static const double _dayGap = 2;
  static const double _arrowWidth = 24;
  static const double _arrowGap = 2;

  /// How many days [room] holds, on the widths Sanjay fixed: 7 days from 980
  /// of header, then 5 from 840, 3 from 700, and today alone below that.
  static int daysIn(double room) => switch (room) {
    _ when room >= _weekWidth(7) => 7,
    _ when room >= _weekWidth(5) => 5,
    _ when room >= _weekWidth(3) => 3,
    _ when room >= _weekWidth(1) => 1,
    _ => 0,
  };

  static double _weekWidth(int days) =>
      days * _dayWidth + (days - 1) * _dayGap + 2 * (_arrowWidth + _arrowGap);

  /// Whether the strip keyed [key] shows its days, rather than its one button
  /// or nothing.
  static bool showsWeek(GlobalKey key) => switch (key.currentState) {
    _DayStripState(days: > 0) => true,
    _ => false,
  };

  @override
  State<DayStrip> createState() => _DayStripState();
}

class _DayStripState extends State<DayStrip> {
  /// How many days the strip last had the room for.
  int days = 0;

  /// How many days the week is paged away from today's, in days.
  int _shift = 0;

  /// The day whose notes are listed under the strip, filled while they are.
  DateTime? _listing;

  /// Whether the calendar is open, which turns its button tonal.
  bool _choosing = false;

  /// The day When narrows the list to, if it is one day.
  DateTime? get _picked => switch (widget.when) {
    WhenDay(:final day) => day,
    NotesWhen.today => widget.today,
    _ => null,
  };

  /// The days on show, oldest first, with today in the middle and the whole
  /// window moved [_shift] days.
  List<DateTime> get _shown {
    final today = widget.today;
    final centre = (days - 1) ~/ 2;
    return [
      for (var index = 0; index < days; index++)
        DateTime(today.year, today.month, today.day - centre + _shift + index),
    ];
  }

  /// A day picked in the calendar brings its week into view.
  @override
  void didUpdateWidget(DayStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_picked case final picked? when widget.when != oldWidget.when) {
      _bringIntoView(picked);
    }
  }

  /// Pages the week to the one that holds [day].
  void _bringIntoView(DateTime day) {
    if (_shown.contains(day)) return;
    final today = widget.today;
    final apart = DateTime.utc(
      day.year,
      day.month,
      day.day,
    ).difference(DateTime.utc(today.year, today.month, today.day)).inDays;
    _shift = (apart ~/ 7) * 7;
  }

  /// How many of the notes fall on each of [days].
  Map<DateTime, int> _counts(Iterable<DateTime> days) {
    final counts = {for (final day in days) day: 0};
    for (final note in widget.notes) {
      final day = noteDay(
        note,
        widget.displayTime,
        ownDay: widget.ownDay?.call(note),
      );
      if (counts[day] case final count?) counts[day] = count + 1;
    }
    return counts;
  }

  /// A click on [day] in the week or the calendar: lists its notes where
  /// there is no list to narrow, narrows the list to it, or opens a page to
  /// write it when it holds none.
  void _choose(DateTime day, {int notes = 0}) {
    if (widget.onOpenNote != null) {
      unawaited(_list(day));
      return;
    }
    final today = widget.today;
    final when = day == today ? NotesWhen.today : WhenDay(day, today: today);
    widget.onWhenChanged(when == widget.when ? NotesWhen.anyTime : when);
    if (notes == 0) widget.onWriteOn?.call(day);
  }

  /// Lists [day]'s notes 4 under the days' dots, or under the one button,
  /// and opens the one picked.
  Future<void> _list(DateTime day) async {
    final box = context.findRenderObject() as RenderBox?;
    final onOpen = widget.onOpenNote;
    if (box == null || onOpen == null) return;
    final palette = context.palette;
    final notes = [
      for (final note in widget.notes)
        if (noteDay(
              note,
              widget.displayTime,
              ownDay: widget.ownDay?.call(note),
            ) ==
            day)
          note,
    ];
    setState(() {
      _bringIntoView(day);
      _listing = day;
    });
    final noteId = await showKapyContextMenu<String>(
      context: context,
      globalPosition: box.localToGlobal(
        Offset(0, days > 0 ? 48 : box.size.height + 4),
      ),
      items: [
        PopupMenuItem(
          enabled: false,
          height: 32,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  SidebarTimestamp.fullDay(day),
                  maxLines: 1,
                  style: _figtree(13, 16, FontWeight.w500, palette.textPrimary),
                ),
              ),
              const SizedBox(width: 16),
              Text(
                _noteCount(notes.length),
                style: _figtree(12, 16, FontWeight.w400, palette.textTertiary),
              ),
            ],
          ),
        ),
        for (final note in notes)
          PopupMenuItem(
            key: ValueKey('day-list-${note.id}'),
            value: note.id,
            height: 32,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    note.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _figtree(
                      13,
                      16,
                      FontWeight.w400,
                      palette.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Text(
                  SidebarTimestamp.clock(widget.displayTime(note.updatedAt)),
                  style: _figtree(
                    12,
                    16,
                    FontWeight.w400,
                    palette.textTertiary,
                  ).copyWith(fontFeatures: _figures),
                ),
              ],
            ),
          ),
      ],
    );
    if (!mounted) return;
    setState(() => _listing = null);
    if (noteId != null) onOpen(noteId, behind: clickOpensTabBehind());
  }

  /// Opens the calendar 4 under [button], on the month of the picked day or
  /// of the latest day in view, and does with the day picked there what a
  /// click on it in the week would.
  Future<void> _showMonth(BuildContext button) async {
    final box = button.findRenderObject() as RenderBox?;
    if (box == null) return;
    final today = widget.today;
    final picked = _picked;
    final shown = picked ?? _shown.lastOrNull ?? today;
    final counts = _counts([
      for (var index = -31; index <= 31; index++)
        DateTime(shown.year, shown.month, shown.day + index),
    ]);
    setState(() => _choosing = true);
    final day = await showGeneralDialog<DateTime>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close the calendar',
      barrierColor: Colors.transparent,
      transitionDuration: Duration.zero,
      pageBuilder: (context, _, _) => CustomSingleChildLayout(
        delegate: PopoverAtPoint(
          box.localToGlobal(Offset(0, box.size.height + 4)),
        ),
        child: DayPicker(
          month: DateTime(shown.year, shown.month),
          today: today,
          filled: picked ?? today,
          counts: _counts,
          firstWeekday: widget.firstWeekday,
          onPicked: (day) => Navigator.of(context).pop(day),
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _choosing = false);
    if (day != null) _choose(day, notes: counts[day] ?? 0);
  }

  /// The month over the week, or the two its days span: "November",
  /// "November–December". Spelled out in full (Sanjay, 20 Nov).
  String get _month {
    final shown = _shown;
    if (shown.isEmpty) return SidebarTimestamp.monthName(widget.today);
    final first = shown.first;
    final last = shown.last;
    return first.month == last.month
        ? SidebarTimestamp.monthName(last)
        : '${SidebarTimestamp.monthName(first)}–'
              '${SidebarTimestamp.monthName(last)}';
  }

  /// How wide [label] is: 8, its text, 4, a 12 chevron and 8.
  static double _labelWidth(BuildContext context, String label) {
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: _figtree(13, 16, FontWeight.w500, context.palette.textPrimary),
      ),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  /// The room the one button needs: 12, the calendar 16, 4, [label], 4, a 12
  /// chevron and 12.
  static double _buttonWidth(BuildContext context, String label) =>
      60 + _labelWidth(context, label);

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final palette = context.palette;
      // The month sits at the strip's own left, so the week has what it
      // leaves: 8, the label, 4, a 12 chevron and 8, then 2 clear.
      final room =
          constraints.maxWidth - (_labelWidth(context, _month) + 32 + DayStrip._arrowGap);
      days = widget.compact ? 0 : DayStrip.daysIn(room);
      if (days == 0) {
        final when = widget.when;
        final label = when is WhenDay ? when.label : 'Today';
        return _buttonWidth(context, label) <= room
            ? _calendarButton(label, palette, compact: true)
            : const SizedBox.shrink();
      }
      final today = widget.today;
      final shown = _shown;
      final counts = _counts(shown);
      final picked = _picked;
      final filled = _listing ?? picked ?? today;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _calendarButton(_month, palette, compact: false),
          const SizedBox(width: DayStrip._arrowGap),
          CompactIconButton(
            key: const ValueKey('day-strip-back'),
            tooltip: 'The week before',
            extent: 32,
            width: DayStrip._arrowWidth,
            radius: 8,
            onPressed: () => setState(() => _shift -= 7),
            icon: const KapyIcon(
              KapyIcons.chevronLeftRounded,
              size: 16,
              strokeWidth: 1.8,
            ),
          ),
          for (final day in shown) ...[
            const SizedBox(width: DayStrip._dayGap),
            _Day(
              key: ValueKey('day-strip-${_date(day)}'),
              day: day,
              today: day == today,
              picked: day == picked,
              filled: day == filled,
              count: counts[day]!,
              onTap: () => _choose(day, notes: counts[day]!),
            ),
          ],
          const SizedBox(width: DayStrip._arrowGap),
          CompactIconButton(
            key: const ValueKey('day-strip-forward'),
            tooltip: 'The week after',
            extent: 32,
            width: DayStrip._arrowWidth,
            radius: 8,
            onPressed: () => setState(() => _shift += 7),
            icon: const KapyIcon(
              KapyIcons.chevronRightRounded,
              size: 16,
              strokeWidth: 1.8,
            ),
          ),
        ],
      );
    },
  );

  /// What opens the calendar, tonal while it is open: the month over the
  /// week, or the one button for the day in its place, raised and led by a
  /// calendar.
  Widget _calendarButton(
    String label,
    CalcPalette palette, {
    required bool compact,
  }) {
    final icons = _choosing ? palette.tonalForeground : palette.textSecondary;
    return Builder(
      builder: (button) => Tooltip(
        message: 'Pick a day',
        child: TextButton(
          key: ValueKey(compact ? 'day-strip-date' : 'day-strip-month'),
          onPressed: () => unawaited(_showMonth(button)),
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 32),
            fixedSize: const Size.fromHeight(32),
            padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 8),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
            backgroundColor: _choosing
                ? palette.tonalBackground
                : compact
                ? palette.controlBackground
                : null,
            foregroundColor: _choosing
                ? palette.tonalForeground
                : palette.textPrimary,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: compact && !_choosing
                  ? BorderSide(color: palette.controlBorder)
                  : BorderSide.none,
            ),
            textStyle: _figtree(13, 16, FontWeight.w500, palette.textPrimary),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (compact) ...[
                KapyIcon(
                  KapyIcons.calendarOutlined,
                  size: 16,
                  strokeWidth: 1.8,
                  color: icons,
                ),
                const SizedBox(width: 4),
              ],
              Text(label),
              const SizedBox(width: 4),
              KapyIcon(
                KapyIcons.chevronDownRounded,
                size: 12,
                strokeWidth: 1.8,
                color: icons,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One day in the week, on one line: its weekday and date in a fill, and a
/// dot under it for each of its notes up to three. Hovered or focused, the
/// fill rises. A day still to come is as writable as any other.
class _Day extends StatefulWidget {
  const _Day({
    super.key,
    required this.day,
    required this.today,
    required this.picked,
    required this.filled,
    required this.count,
    required this.onTap,
  });

  final DateTime day;
  final bool today;

  /// Whether the list is narrowed to this day.
  final bool picked;

  /// Whether the fill marks it: the day picked or listed, or today while no
  /// day is.
  final bool filled;
  final int count;
  final VoidCallback onTap;

  @override
  State<_Day> createState() => _DayState();
}

class _DayState extends State<_Day> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final sage = Theme.of(context).colorScheme.primary;
    final day = widget.day;
    final filled = widget.filled;
    final dots = math.min(widget.count, 3);
    final column = SizedBox(
      width: DayStrip._dayWidth,
      height: 40,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: filled
                  ? palette.tonalBackground
                  : _hovered || _focused
                  ? palette.controlBackground
                  : null,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              SidebarTimestamp.weekdayAndDay(day),
              maxLines: 1,
              style: _figtree(
                13,
                16,
                widget.today || filled ? FontWeight.w600 : FontWeight.w500,
                filled
                    ? palette.tonalForeground
                    : widget.today
                    ? sage
                    : palette.textPrimary,
              ).copyWith(fontFeatures: _figures),
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 3,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var dot = 0; dot < dots; dot++) ...[
                  if (dot > 0) const SizedBox(width: 2),
                  Container(
                    width: 3,
                    height: 3,
                    decoration: BoxDecoration(
                      color: widget.today ? sage : palette.textTertiary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
    return TextButton(
      onPressed: widget.onTap,
      onHover: (hovered) => setState(() => _hovered = hovered),
      onFocusChange: (focused) => setState(() => _focused = focused),
      style: TextButton.styleFrom(
        minimumSize: Size.zero,
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.standard,
        overlayColor: Colors.transparent,
        splashFactory: NoSplash.splashFactory,
        shape: const RoundedRectangleBorder(),
        textStyle: _figtree(13, 16, FontWeight.w500, palette.textPrimary),
      ),
      child: Semantics(
        selected: widget.picked,
        label: _spoken(day, today: widget.today, notes: widget.count),
        excludeSemantics: true,
        child: column,
      ),
    );
  }
}

/// A month to pick a day from: the turned-to day in the same fill, today's
/// date in sage, and the rest plain. Any day can be picked, ahead or behind.
/// ‹ and › move a month.
class DayPicker extends StatefulWidget {
  const DayPicker({
    super.key,
    required this.month,
    required this.today,
    required this.filled,
    required this.counts,
    required this.firstWeekday,
    required this.onPicked,
  });

  /// The month it opens on, as its first day.
  final DateTime month;
  final DateTime today;
  final DateTime filled;
  final Map<DateTime, int> Function(Iterable<DateTime> days) counts;
  final int firstWeekday;
  final ValueChanged<DateTime> onPicked;

  @override
  State<DayPicker> createState() => _DayPickerState();
}

class _DayPickerState extends State<DayPicker> {
  late DateTime _month = widget.month;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final sage = Theme.of(context).colorScheme.primary;
    final weekdays = MaterialLocalizations.of(context).narrowWeekdays;
    final month = _month;
    final today = widget.today;
    final length = DateTime(month.year, month.month + 1, 0).day;
    final days = [
      for (var date = 1; date <= length; date++)
        DateTime(month.year, month.month, date),
    ];
    final counts = widget.counts(days);
    final cells = <DateTime?>[
      ...List.filled((month.weekday - widget.firstWeekday) % 7, null),
      ...days,
    ];
    final current = month.year == today.year && month.month == today.month;

    Widget cell(DateTime? day) {
      if (day == null) return const SizedBox.square(dimension: 32);
      final filled = day == widget.filled;
      final notes = counts[day]!;
      final (weight, color) = filled
          ? (FontWeight.w600, palette.tonalForeground)
          : day == today
          ? (FontWeight.w600, sage)
          : notes > 0
          ? (FontWeight.w500, palette.textPrimary)
          : (FontWeight.w400, palette.textTertiary);
      return TextButton(
        key: ValueKey('day-month-${_date(day)}'),
        onPressed: () => widget.onPicked(day),
        style: ButtonStyle(
          fixedSize: const WidgetStatePropertyAll(Size.square(32)),
          minimumSize: const WidgetStatePropertyAll(Size.zero),
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.standard,
          splashFactory: NoSplash.splashFactory,
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          foregroundColor: WidgetStatePropertyAll(color),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => filled
                ? palette.tonalBackground
                : states.contains(WidgetState.hovered) ||
                      states.contains(WidgetState.focused)
                ? palette.controlBackground
                : null,
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          textStyle: WidgetStatePropertyAll(
            _figtree(13, 16, weight, color).copyWith(fontFeatures: _figures),
          ),
        ),
        child: Semantics(
          selected: filled,
          label: _spoken(day, today: day == today, notes: notes),
          excludeSemantics: true,
          child: Text('${day.day}'),
        ),
      );
    }

    return Material(
      color: palette.surfaceBackground,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.control),
        side: BorderSide(
          color: palette.controlBorder,
          width: AppHairline.of(context),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: SizedBox(
          width: 7 * 32 + 6 * 4,
          child: Column(
            key: const ValueKey('day-month'),
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${SidebarTimestamp.monthName(month)} ${month.year}',
                      style: _figtree(
                        13,
                        16,
                        FontWeight.w500,
                        palette.textPrimary,
                      ),
                    ),
                  ),
                  CompactIconButton(
                    key: const ValueKey('day-month-back'),
                    tooltip: 'Previous month',
                    extent: 24,
                    onPressed: () => setState(
                      () => _month = DateTime(month.year, month.month - 1),
                    ),
                    icon: const KapyIcon(
                      KapyIcons.chevronLeftRounded,
                      size: 16,
                      strokeWidth: 1.8,
                    ),
                  ),
                  const SizedBox(width: 4),
                  CompactIconButton(
                    key: const ValueKey('day-month-forward'),
                    tooltip: 'Next month',
                    extent: 24,
                    onPressed: () => setState(
                      () => _month = DateTime(month.year, month.month + 1),
                    ),
                    icon: const KapyIcon(
                      KapyIcons.chevronRightRounded,
                      size: 16,
                      strokeWidth: 1.8,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ExcludeSemantics(
                child: Row(
                  children: [
                    for (var column = 0; column < 7; column++) ...[
                      if (column > 0) const SizedBox(width: 4),
                      SizedBox(
                        width: 32,
                        child: Text(
                          weekdays[(widget.firstWeekday + column) % 7],
                          textAlign: TextAlign.center,
                          style: _figtree(
                            11,
                            12,
                            FontWeight.w500,
                            palette.textTertiary,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              for (var start = 0; start < cells.length; start += 7) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    for (var index = start; index < start + 7; index++) ...[
                      if (index > start) const SizedBox(width: 4),
                      cell(index < cells.length ? cells[index] : null),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Asks for a day on a month to pick from, 4 under [context]'s box or in the
/// middle of the window, and gives the day picked: Move to another day.
Future<DateTime?> showDayPicker(
  BuildContext context, {
  required DateTime today,
  required DateTime filled,
  required int firstWeekday,
}) => showDialog<DateTime>(
  context: context,
  barrierColor: Colors.transparent,
  builder: (context) => Dialog(
    backgroundColor: Colors.transparent,
    elevation: 0,
    child: DayPicker(
      month: DateTime(filled.year, filled.month),
      today: today,
      filled: filled,
      counts: (_) => const {},
      firstWeekday: firstWeekday,
      onPicked: (day) => Navigator.of(context).pop(day),
    ),
  ),
);
