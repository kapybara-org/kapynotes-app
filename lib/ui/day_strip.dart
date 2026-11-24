import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show Drag;
import 'package:flutter/physics.dart';
import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
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

/// Where the page's bar puts the days: [month] at its top left, and [week],
/// when there is one, centred on the page.
typedef PlaceDays = Widget Function(Widget month, Widget? week);

/// The page's days: the month in full at the bar's top left, and in the
/// middle, on one line, ‹, the week, ›. Seven days with today in the middle (Sun 16 to Sat 22 when today
/// is Wed 19), and five, three, or today alone on a narrower page. ‹ and ›
/// move a week at a time. A day has a dot for each of its notes, up to three.
///
/// A click on a day picks it: the page opens its latest note, or a page to
/// write on that day when it has none, and the list stays whole. The month
/// opens a calendar that picks a day the same way. On a narrow page one button for the day
/// stands in the month's place with no week.
class DayStrip extends StatefulWidget {
  const DayStrip({
    super.key,
    required this.place,
    required this.today,
    required this.picked,
    required this.onPick,
    required this.notes,
    required this.displayTime,
    required this.firstWeekday,
    this.ownDay,
    this.onOpenNote,
    this.compact = false,
    this.phone = false,
  });

  /// The day the list shows as today.
  final DateTime today;

  /// The day last picked, which is filled; while none is, today is, only to
  /// mark it.
  final DateTime? picked;

  /// A day picked in the week or the calendar, with the notes on it, latest
  /// edit first.
  final void Function(DateTime day, List<Note> notes) onPick;

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

  /// Puts the month and the week where the bar has them.
  final PlaceDays place;

  /// One button for the picked day in place of the month, and no week.
  final bool compact;

  /// A phone note's week: always seven days, the calendar week from
  /// [firstWeekday] that holds the picked day, each day its weekday over its
  /// date across the whole width, and no month. A day picked goes to
  /// [onPick], which opens its one note, its several as tabs, or with none a
  /// page to write on it. A swipe on it turns the weeks under the finger, a
  /// fling carries on for as many as its speed would, and it comes to rest on
  /// a whole week; ‹ and › turn one.
  final bool phone;

  /// A phone's arrows: the strip's height to press, and this wide, or down
  /// to the least where a narrower phone needs the room for its days.
  static const double _phoneArrowWidth = 28;
  static const double _phoneArrowMin = 20;

  /// The chip a day sits in, and the room the whole week needs at [days] of
  /// them: the chips, 2 between them, and an arrow with 2 clear at each end.
  /// With the Mac's 24 arrows, seven days need 540, five 400, three 260, and
  /// today alone 120; a touch screen's arrows keep their 48 to press.
  static const double _dayWidth = 68;
  static const double _dayGap = 2;
  static const double _arrowGap = 2;

  /// How wide an arrow is: 24 under a pointer, and the 48 a finger needs.
  static double get _arrowWidth =>
      AppPlatform.hasPointer ? 24 : kMinInteractiveDimension;

  /// How many days [room] holds with arrows [arrow] wide, on the widths
  /// Sanjay fixed: 7 days from 980 of header, then 5 from 840, 3 from 700,
  /// and today alone below that.
  static int daysIn(double room, {double arrow = 24}) {
    double week(int days) =>
        days * _dayWidth + (days - 1) * _dayGap + 2 * (arrow + _arrowGap);
    for (final days in const [7, 5, 3, 1]) {
      if (room >= week(days)) return days;
    }
    return 0;
  }

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

  /// The week, or with none the month's button, which a day's list opens
  /// under.
  final _weekRow = GlobalKey();
  final _monthButton = GlobalKey();

  /// A phone's weeks, one a page, from the week that holds 1 January 1900.
  PageController? _weeks;

  /// The page an arrow is turning the weeks to, until they are there.
  int? _turning;

  /// A swipe begun on an arrow, which turns the weeks as one on the days
  /// does.
  Drag? _drag;

  /// The days on show, oldest first, with today in the middle and the whole
  /// window moved [_shift] days.
  List<DateTime> get _shown => _week(days);

  /// The [count] days in view, today in the middle until paged away.
  List<DateTime> _week(int count) {
    final today = widget.today;
    final centre = (count - 1) ~/ 2;
    return [
      for (var index = 0; index < count; index++)
        DateTime(today.year, today.month, today.day - centre + _shift + index),
    ];
  }

  /// The first day of [day]'s calendar week.
  DateTime _weekStart(DateTime day) => DateTime(
    day.year,
    day.month,
    day.day - (day.weekday - widget.firstWeekday) % 7,
  );

  /// The first day of a phone's first page.
  DateTime get _firstWeek => _weekStart(DateTime(1900));

  /// The page of the week that holds [day].
  int _pageOf(DateTime day) {
    final first = _firstWeek;
    final week = _weekStart(day);
    return DateTime.utc(
          week.year,
          week.month,
          week.day,
        ).difference(DateTime.utc(first.year, first.month, first.day)).inDays ~/
        7;
  }

  /// The seven days of [page]'s week.
  List<DateTime> _weekOn(int page) {
    final first = _firstWeek;
    return [
      for (var index = 0; index < 7; index++)
        DateTime(first.year, first.month, first.day + 7 * page + index),
    ];
  }

  @override
  void initState() {
    super.initState();
    if (!widget.phone) return;
    days = 7;
    _weeks = PageController(
      initialPage: _pageOf(widget.picked ?? widget.today),
      keepPage: false,
    );
  }

  @override
  void dispose() {
    _weeks?.dispose();
    super.dispose();
  }

  /// A day picked in the calendar brings its week into view.
  @override
  void didUpdateWidget(DayStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.picked case final picked? when picked != oldWidget.picked) {
      _bringIntoView(picked);
    }
  }

  /// Pages the week to the one that holds [day].
  void _bringIntoView(DateTime day) {
    if (_weeks case final weeks?) {
      final page = _pageOf(day);
      if (weeks.hasClients && weeks.page?.round() != page) {
        weeks.jumpToPage(page);
      }
      return;
    }
    if (_shown.contains(day)) return;
    final today = widget.today;
    final apart = DateTime.utc(
      day.year,
      day.month,
      day.day,
    ).difference(DateTime.utc(today.year, today.month, today.day)).inDays;
    _shift = (apart ~/ 7) * 7;
  }

  /// How many of the notes fall on each day that has any.
  Map<DateTime, int> _countsByDay() {
    final counts = <DateTime, int>{};
    for (final note in widget.notes) {
      final day = noteDay(
        note,
        widget.displayTime,
        ownDay: widget.ownDay?.call(note),
      );
      counts[day] = (counts[day] ?? 0) + 1;
    }
    return counts;
  }

  /// How many of the notes fall on each of [days].
  Map<DateTime, int> _counts(Iterable<DateTime> days) {
    final counts = _countsByDay();
    return {for (final day in days) day: counts[day] ?? 0};
  }

  /// A click on [day] in the week or the calendar: lists its notes where
  /// there is no list beside the page, and otherwise picks it, as a phone
  /// always does.
  void _choose(DateTime day, {BuildContext? at}) {
    if (widget.phone || widget.onOpenNote == null) {
      widget.onPick(day, _notesOn(day));
      return;
    }
    unawaited(_list(day, at: at));
  }

  /// The notes on [day], in the order the strip was given them.
  List<Note> _notesOn(DateTime day) => [
    for (final note in widget.notes)
      if (noteDay(note, widget.displayTime, ownDay: widget.ownDay?.call(note)) ==
          day)
        note,
  ];

  /// Lists [day]'s notes 4 under the week, from the left of the day tapped
  /// [at], or under the button that stands in for it, and opens the one
  /// picked.
  Future<void> _list(DateTime day, {BuildContext? at}) async {
    final box =
        (days > 0 ? _weekRow : _monthButton).currentContext?.findRenderObject()
            as RenderBox?;
    final tapped = at?.findRenderObject() as RenderBox?;
    final onOpen = widget.onOpenNote;
    if (box == null || onOpen == null) return;
    final palette = context.palette;
    final notes = _notesOn(day);
    setState(() {
      _bringIntoView(day);
      _listing = day;
    });
    final noteId = await showKapyContextMenu<String>(
      context: context,
      globalPosition: box.localToGlobal(
        Offset(
          tapped == null
              ? 0
              : box.globalToLocal(tapped.localToGlobal(Offset.zero)).dx,
          box.size.height + 4,
        ),
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
    final picked = widget.picked;
    final shown = picked ?? _shown.lastOrNull ?? today;
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
    if (day != null) _choose(day);
  }

  /// The month over the week, or the two its days span: "November",
  /// "November–December". Spelled out in full (Sanjay, 20 Nov).
  String _monthOver(List<DateTime> shown) {
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

  /// The room the month's button needs (8, the month, 4, a 12 chevron and
  /// 8), or with compact the one button's: 12, the calendar 16, 4, [label],
  /// 4, a 12 chevron and 12.
  static double _buttonWidth(
    BuildContext context,
    String label, {
    required bool compact,
  }) => (compact ? 60 : 32) + _labelWidth(context, label);

  @override
  Widget build(BuildContext context) {
    if (widget.phone) {
      return widget.place(const SizedBox.shrink(), _phoneWeek());
    }
    final palette = context.palette;
    final compact = widget.compact;
    final picked = widget.picked;
    if (compact) days = 0;
    final label = !compact
        ? _monthOver(_shown)
        : picked == null || picked == widget.today
        ? 'Today'
        : switch (SidebarTimestamp.dayHeading(picked, today: widget.today)) {
            (_, final date?) => date,
            (final heading, _) => heading,
          };
    return widget.place(
      LayoutBuilder(
        builder: (context, constraints) =>
            _buttonWidth(context, label, compact: compact) <=
                constraints.maxWidth
            ? KeyedSubtree(
                key: _monthButton,
                child: _calendarButton(label, palette, compact: compact),
              )
            : const SizedBox.shrink(),
      ),
      compact
          ? null
          : LayoutBuilder(
              builder: (context, constraints) {
                final fits = DayStrip.daysIn(
                  constraints.maxWidth,
                  arrow: DayStrip._arrowWidth,
                );
                if (fits != days) {
                  days = fits;
                  // The month over the week names the days that fit.
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) setState(() {});
                  });
                }
                if (days == 0) return const SizedBox.shrink();
                final today = widget.today;
                final shown = _shown;
                final counts = _counts(shown);
                final filled = _listing ?? picked ?? today;
                return Row(
                  key: _weekRow,
                  mainAxisSize: MainAxisSize.min,
                  children: [
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
                      ),
                    ),
                    const SizedBox(width: DayStrip._arrowGap),
                    for (final (index, day) in shown.indexed) ...[
                      if (index > 0) const SizedBox(width: DayStrip._dayGap),
                      Builder(
                        builder: (tapped) => _Day(
                          key: ValueKey('day-strip-${_date(day)}'),
                          day: day,
                          today: day == today,
                          picked: day == picked,
                          filled: day == filled,
                          count: counts[day]!,
                          onTap: () => _choose(day, at: tapped),
                        ),
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
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }

  /// A phone's week across the whole width: ‹, the seven days sharing what
  /// is left, ›. The days are pages of weeks, which a swipe that starts
  /// anywhere on the strip turns, on an arrow too.
  Widget _phoneWeek() {
    final weeks = _weeks!;
    final today = widget.today;
    final counts = _countsByDay();
    final picked = widget.picked;
    final filled = picked ?? today;
    final height = _Day.stackedHeight(MediaQuery.textScalerOf(context));
    // As narrow as M09 draws them, and narrower on a small phone, so each of
    // the seven days keeps 44 to tap; the arrows keep the strip's whole
    // height. Under 44 wide they are no target for a screen reader, which
    // turns the week with a scroll over the days.
    Widget arrow(String key, KapyIconData icon, int by, double width) =>
        ExcludeSemantics(
          child: InkResponse(
            key: ValueKey(key),
            onTap: () => _turn(by),
            radius: width,
            child: SizedBox(
              width: width,
              height: height,
              child: Center(
                child: KapyIcon(
                  icon,
                  size: 16,
                  color: context.palette.textSecondary,
                ),
              ),
            ),
          ),
        );
    Widget week(BuildContext context, int page) => Row(
      children: [
        for (final day in _weekOn(page))
          Expanded(
            child: _Day(
              key: ValueKey('day-strip-${_date(day)}'),
              day: day,
              today: day == today,
              picked: day == picked,
              filled: day == filled,
              count: counts[day] ?? 0,
              stacked: true,
              onTap: () => _choose(day),
            ),
          ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = ((constraints.maxWidth - 7 * 44) / 2).clamp(
          DayStrip._phoneArrowMin,
          DayStrip._phoneArrowWidth,
        );
        return GestureDetector(
          onHorizontalDragStart: (details) =>
              _drag = weeks.position.drag(details, () => _drag = null),
          onHorizontalDragUpdate: (details) => _drag?.update(details),
          onHorizontalDragEnd: (details) => _drag?.end(details),
          onHorizontalDragCancel: () => _drag?.cancel(),
          child: SizedBox(
            height: height,
            child: Row(
              children: [
                arrow(
                  'day-strip-back',
                  KapyIcons.chevronLeftRounded,
                  -1,
                  width,
                ),
                Expanded(
                  child: PageView.builder(
                    controller: weeks,
                    pageSnapping: false,
                    physics: const _WeekScrollPhysics(),
                    itemBuilder: week,
                  ),
                ),
                arrow(
                  'day-strip-forward',
                  KapyIcons.chevronRightRounded,
                  1,
                  width,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// An arrow's turn: [by] weeks on from the week the weeks are already
  /// turning to, or else the one in view, sliding there unless animations
  /// are off.
  void _turn(int by) {
    final weeks = _weeks!;
    final to = (_turning ?? weeks.page!.round()) + by;
    if (MediaQuery.disableAnimationsOf(context)) {
      weeks.jumpToPage(to);
      return;
    }
    _turning = to;
    unawaited(
      weeks
          .animateToPage(
            to,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
          )
          .whenComplete(() {
            if (_turning == to) _turning = null;
          }),
    );
  }

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
            textStyle: _figtree(13, 18, FontWeight.w500, palette.textPrimary),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (compact) ...[
                KapyIcon(KapyIcons.calendarOutlined, size: 16, color: icons),
                const SizedBox(width: 4),
              ],
              Text(label),
              const SizedBox(width: 4),
              KapyIcon(KapyIcons.chevronDownRounded, size: 12, color: icons),
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
    this.stacked = false,
  });

  /// How tall a phone's day is: its weekday, its date and its dots.
  static const double phoneHeight = 52;

  /// How tall a phone's day is with its text scaled by [scaler]: the
  /// weekday's 16 line, the date's 22, the 3 under them and the dots' 3, or
  /// [phoneHeight] where that is more. A whole number of points, so no
  /// fraction of the text's own rounding overflows it.
  static double stackedHeight(TextScaler scaler) => math.max(
    phoneHeight,
    (scaler.scale(13) * 16 / 13 + scaler.scale(17) * 22 / 17 + 6)
        .ceilToDouble(),
  );

  final DateTime day;
  final bool today;

  /// A phone's day: its weekday over its date, both in the day's colour,
  /// and a quiet fill while it is the note's.
  final bool stacked;

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
    final dotRow = SizedBox(
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
    );
    final column = widget.stacked
        ? Container(
            constraints: const BoxConstraints(minHeight: _Day.phoneHeight),
            decoration: BoxDecoration(
              color: filled
                  ? palette.controlBackground
                  : _focused
                  ? palette.hover
                  : null,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  SidebarTimestamp.shortWeekday(day),
                  maxLines: 1,
                  style: _figtree(
                    13,
                    16,
                    widget.today ? FontWeight.w600 : FontWeight.w400,
                    widget.today ? sage : palette.textSecondary,
                  ),
                ),
                Text(
                  '${day.day}',
                  maxLines: 1,
                  style: _figtree(
                    17,
                    22,
                    widget.today ? FontWeight.w600 : FontWeight.w500,
                    widget.today ? sage : palette.textPrimary,
                  ).copyWith(fontFeatures: _figures),
                ),
                const SizedBox(height: 3),
                dotRow,
              ],
            ),
          )
        : SizedBox(
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
                      widget.today || filled
                          ? FontWeight.w600
                          : FontWeight.w500,
                      filled
                          ? palette.tonalForeground
                          : widget.today
                          ? sage
                          : palette.textPrimary,
                    ).copyWith(fontFeatures: _figures),
                  ),
                ),
                const SizedBox(height: 4),
                dotRow,
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

/// How a phone's weeks scroll: under the finger, and let go, on to rest on
/// the whole week nearest to where the fling's [_reach] takes them, and at
/// least the next one in its direction, as a page does. Up to the next week
/// they spring there; further, they slow to a stop on the week.
class _WeekScrollPhysics extends ScrollPhysics {
  const _WeekScrollPhysics({super.parent});

  /// How far a fling carries the weeks on: as far as it goes in this many
  /// seconds at its speed. An everyday swipe turns one week, a firm one two,
  /// and the hardest four. A scroll's own momentum goes much further (two
  /// weeks for an everyday swipe on an iPhone, months on Android), too far
  /// for a week with no month on it.
  static const double _reach = 0.15;

  @override
  _WeekScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      _WeekScrollPhysics(parent: buildParent(ancestor));

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    final from = position.pixels;
    if ((velocity <= 0 && from <= position.minScrollExtent) ||
        (velocity >= 0 && from >= position.maxScrollExtent)) {
      return super.createBallisticSimulation(position, velocity);
    }
    final tolerance = toleranceFor(position);
    final week = position.viewportDimension;
    final page = from / week;
    var target = ((from + velocity * _reach) / week).roundToDouble();
    if (velocity > tolerance.velocity) {
      target = math.max(target, page.floorToDouble() + 1);
    } else if (velocity < -tolerance.velocity) {
      target = math.min(target, page.ceilToDouble() - 1);
    }
    final to = (target * week).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (to == from) return null;
    if ((to - from).abs() > week && (to - from).sign == velocity.sign) {
      return FrictionSimulation.through(
        from,
        to,
        velocity,
        tolerance.velocity * velocity.sign,
      );
    }
    return ScrollSpringSimulation(
      spring,
      from,
      to,
      velocity,
      tolerance: tolerance,
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
    this.sheet = false,
  });

  /// The month it opens on, as its first day.
  final DateTime month;
  final DateTime today;
  final DateTime filled;
  final Map<DateTime, int> Function(Iterable<DateTime> days) counts;
  final int firstWeekday;
  final ValueChanged<DateTime> onPicked;

  /// Inside a phone's sheet (M12): the month's name with Today beside it,
  /// days the sheet's width across, and a swipe to the month either side.
  final bool sheet;

  @override
  State<DayPicker> createState() => _DayPickerState();
}

class _DayPickerState extends State<DayPicker> {
  late DateTime _month = widget.month;

  void _page(int by) =>
      setState(() => _month = DateTime(_month.year, _month.month + by));

  @override
  Widget build(BuildContext context) {
    final sheet = widget.sheet;
    final extent = sheet ? 44.0 : 32.0;
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

    Widget cell(DateTime? day) {
      if (day == null) return SizedBox(width: extent, height: extent);
      final filled = day == widget.filled;
      final notes = counts[day] ?? 0;
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
          fixedSize: WidgetStatePropertyAll(
            sheet ? Size.fromHeight(extent) : Size.square(extent),
          ),
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
            (sheet
                    ? _figtree(17, 22, weight, color)
                    : _figtree(13, 16, weight, color))
                .copyWith(fontFeatures: _figures),
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

    Widget spaced(List<Widget> children) => Row(
      children: [
        for (var index = 0; index < children.length; index++) ...[
          if (index > 0) const SizedBox(width: 4),
          sheet ? Expanded(child: children[index]) : children[index],
        ],
      ],
    );

    final monthName = SidebarTimestamp.monthName(month);
    final header = sheet
        ? Row(
            children: [
              Expanded(
                child: Text(
                  month.year == today.year
                      ? monthName
                      : '$monthName ${month.year}',
                  key: const ValueKey('day-month-name'),
                  style: _figtree(15, 20, FontWeight.w600, palette.textPrimary),
                ),
              ),
              TextButton(
                key: const ValueKey('day-month-today'),
                onPressed: () => widget.onPicked(today),
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  backgroundColor: palette.controlBackground,
                  foregroundColor: palette.textPrimary,
                  textStyle: _figtree(
                    14,
                    18,
                    FontWeight.w500,
                    palette.textPrimary,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: const Text('Today'),
              ),
            ],
          )
        : Row(
            children: [
              Expanded(
                child: Text(
                  '$monthName ${month.year}',
                  style: _figtree(13, 16, FontWeight.w500, palette.textPrimary),
                ),
              ),
              CompactIconButton(
                key: const ValueKey('day-month-back'),
                tooltip: 'Previous month',
                extent: 24,
                onPressed: () => _page(-1),
                icon: const KapyIcon(KapyIcons.chevronLeftRounded, size: 16),
              ),
              const SizedBox(width: 4),
              CompactIconButton(
                key: const ValueKey('day-month-forward'),
                tooltip: 'Next month',
                extent: 24,
                onPressed: () => _page(1),
                icon: const KapyIcon(KapyIcons.chevronRightRounded, size: 16),
              ),
            ],
          );
    final grid = Column(
      key: const ValueKey('day-month'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        SizedBox(height: sheet ? 16 : 8),
        ExcludeSemantics(
          child: spaced([
            for (var column = 0; column < 7; column++)
              SizedBox(
                width: 32,
                child: Text(
                  weekdays[(widget.firstWeekday + column) % 7],
                  textAlign: TextAlign.center,
                  style: sheet
                      ? _figtree(13, 16, FontWeight.w500, palette.textTertiary)
                      : _figtree(11, 12, FontWeight.w500, palette.textTertiary),
                ),
              ),
          ]),
        ),
        for (var start = 0; start < cells.length; start += 7) ...[
          const SizedBox(height: 4),
          spaced([
            for (var index = start; index < start + 7; index++)
              cell(index < cells.length ? cells[index] : null),
          ]),
        ],
      ],
    );
    if (sheet) {
      return Semantics(
        label: '$monthName ${month.year}',
        onIncrease: () => _page(1),
        onDecrease: () => _page(-1),
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragEnd: (details) => switch (details.primaryVelocity) {
            final speed? when speed < -200 => _page(1),
            final speed? when speed > 200 => _page(-1),
            _ => null,
          },
          child: grid,
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
        child: SizedBox(width: 7 * 32 + 6 * 4, child: grid),
      ),
    );
  }
}

/// Asks for a day on a month to pick from, and gives the day picked: Move to
/// another day. In the middle of the window, or on a phone as a sheet over
/// the dimmed page under its name (M12).
Future<DateTime?> showDayPicker(
  BuildContext context, {
  required DateTime today,
  required DateTime filled,
  required int firstWeekday,
  bool sheet = false,
}) {
  Widget picker(BuildContext context) => DayPicker(
    month: DateTime(filled.year, filled.month),
    today: today,
    filled: filled,
    counts: (_) => const {},
    firstWeekday: firstWeekday,
    sheet: sheet,
    onPicked: (day) => Navigator.of(context).pop(day),
  );
  if (!sheet) {
    return showDialog<DateTime>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: picker(context),
      ),
    );
  }
  return showModalBottomSheet<DateTime>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      top: false,
      child: Padding(
        key: const ValueKey('day-sheet'),
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Move to another day',
              style: _figtree(
                17,
                22,
                FontWeight.w600,
                context.palette.textPrimary,
              ),
            ),
            const SizedBox(height: 20),
            picker(context),
          ],
        ),
      ),
    ),
  );
}
