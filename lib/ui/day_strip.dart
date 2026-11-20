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

/// Where the page's bar puts the days: [month] at its top left, and [week],
/// when there is one, centred on the page.
typedef PlaceDays = Widget Function(Widget month, Widget? week);

/// The page's days: the month in full at the bar's top left, and in the
/// middle ‹, five days with today second to last, and ›. A day has a dot for
/// each of its notes, up to three. Clicking a day narrows the list to it, and
/// clicking it again lets the list go; the month opens a calendar that picks
/// a day the same way. On a narrow page one button for the day stands in the
/// month's place with no week. The week gives way in a middle with no room
/// for it, and the month or the button in a slot with none for them.
class DayStrip extends StatefulWidget {
  const DayStrip({
    super.key,
    required this.place,
    required this.today,
    required this.when,
    required this.onWhenChanged,
    required this.notes,
    required this.displayTime,
    required this.firstWeekday,
    this.onOpenNote,
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

  /// The [DateTime.weekday] the calendar's weeks start on.
  final int firstWeekday;

  /// Set while there is no list on screen to narrow: a day then lists its
  /// notes under the strip, and the one picked there opens, in a tab behind
  /// on ⌘-click.
  final void Function(String noteId, {required bool behind})? onOpenNote;

  /// Puts the month and the week where the bar has them.
  final PlaceDays place;

  /// One button for the day in place of the month, and no week.
  final bool compact;

  /// Whether the strip keyed [key] shows its week, rather than its one
  /// button or nothing.
  static bool showsWeek(GlobalKey key) => switch (key.currentState) {
    _DayStripState(_weekShown: final shown) => shown,
    _ => false,
  };

  @override
  State<DayStrip> createState() => _DayStripState();
}

class _DayStripState extends State<DayStrip> {
  /// How many fives of days the week is paged back from today's.
  int _page = 0;

  /// The day whose notes are listed under the strip, filled while they are.
  DateTime? _listing;

  /// Whether the calendar is open, which turns its button tonal.
  bool _choosing = false;

  /// Whether the week had the room it needs when last laid out.
  bool _weekShown = false;

  /// The week, or with none the month or its one button, which a day's list
  /// opens under.
  final _week = GlobalKey();
  final _button = GlobalKey();

  /// The day When narrows the list to, if it is one day.
  DateTime? get _picked => switch (widget.when) {
    WhenDay(:final day) => day,
    NotesWhen.today => widget.today,
    _ => null,
  };

  /// The five days on show, oldest first: today second to last on the first
  /// page, and five days earlier for each page back.
  List<DateTime> get _days {
    final today = widget.today;
    return [
      for (var index = 0; index < 5; index++)
        DateTime(today.year, today.month, today.day - 3 - 5 * _page + index),
    ];
  }

  /// A day picked in the calendar brings its five days into view.
  @override
  void didUpdateWidget(DayStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_picked case final picked? when widget.when != oldWidget.when) {
      _bringIntoView(picked);
    }
  }

  /// Pages the week to the five days that hold [day].
  void _bringIntoView(DateTime day) {
    if (_days.contains(day)) return;
    final today = widget.today;
    final back = DateTime.utc(
      today.year,
      today.month,
      today.day,
    ).difference(DateTime.utc(day.year, day.month, day.day)).inDays;
    _page = (back + 1) ~/ 5;
  }

  /// How many of the notes fall on each of [days].
  Map<DateTime, int> _counts(Iterable<DateTime> days) {
    final counts = {for (final day in days) day: 0};
    for (final note in widget.notes) {
      final day = noteDay(note, widget.displayTime);
      if (counts[day] case final count?) counts[day] = count + 1;
    }
    return counts;
  }

  /// A click on [day] in the week or the calendar: lists its notes where
  /// there is no list to narrow, and otherwise narrows the list to it, or
  /// lets the list go if it already is.
  void _choose(DateTime day) {
    if (widget.onOpenNote != null) {
      unawaited(_list(day));
      return;
    }
    final today = widget.today;
    final when = day == today ? NotesWhen.today : WhenDay(day, today: today);
    widget.onWhenChanged(when == widget.when ? NotesWhen.anyTime : when);
  }

  /// Lists [day]'s notes 4 under the days' dots, or under the button that
  /// stands in for them, and opens the one picked.
  Future<void> _list(DateTime day) async {
    final box =
        (_weekShown ? _week : _button).currentContext?.findRenderObject()
            as RenderBox?;
    final onOpen = widget.onOpenNote;
    if (box == null || onOpen == null) return;
    final palette = context.palette;
    final notes = [
      for (final note in widget.notes)
        if (noteDay(note, widget.displayTime) == day) note,
    ];
    setState(() {
      _bringIntoView(day);
      _listing = day;
    });
    final noteId = await showKapyContextMenu<String>(
      context: context,
      globalPosition: box.localToGlobal(Offset(0, box.size.height + 4)),
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
    final shown = picked ?? (_page == 0 ? today : _days.last);
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
        child: _Month(
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

  /// The month over the week in full, or the two its days span:
  /// "November", "November–December".
  String get _month {
    final days = _days;
    final first = days.first;
    final last = days.last;
    return first.month == last.month
        ? SidebarTimestamp.monthName(last)
        : '${SidebarTimestamp.monthName(first)}–'
              '${SidebarTimestamp.monthName(last)}';
  }

  /// How wide [label] is on one of the strip's buttons.
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

  /// The room the week needs: ‹ 24, 4, five days 36 wide and 4 apart, 4 and
  /// › 24. It counts the Today button a page back adds (4, then 12, Today and
  /// 12), so paging never sends the week away.
  double _weekWidth(BuildContext context) =>
      252 + 28 + _labelWidth(context, 'Today');

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
    final palette = context.palette;
    final compact = widget.compact;
    final when = widget.when;
    final label = !compact
        ? _month
        : when is WhenDay
        ? when.label
        : 'Today';
    _weekShown = false;
    return widget.place(
      LayoutBuilder(
        builder: (context, constraints) =>
            _buttonWidth(context, label, compact: compact) <=
                constraints.maxWidth
            ? KeyedSubtree(
                key: _button,
                child: _calendarButton(label, palette, compact: compact),
              )
            : const SizedBox.shrink(),
      ),
      compact
          ? null
          : LayoutBuilder(
              builder: (context, constraints) {
                _weekShown = _weekWidth(context) <= constraints.maxWidth;
                if (!_weekShown) return const SizedBox.shrink();
                final today = widget.today;
                final days = _days;
                final counts = _counts(days);
                final picked = _picked;
                final filled = _listing ?? picked ?? today;
                final paged = _page > 0;
                return Row(
                  key: _week,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CompactIconButton(
                      key: const ValueKey('day-strip-back'),
                      tooltip: 'Earlier days',
                      extent: 32,
                      width: 24,
                      radius: 8,
                      onPressed: () => setState(() => _page++),
                      icon: const KapyIcon(
                        KapyIcons.chevronLeftRounded,
                        size: 16,
                        strokeWidth: 1.8,
                      ),
                    ),
                    const SizedBox(width: 4),
                    for (final (index, day) in days.indexed) ...[
                      if (index > 0) const SizedBox(width: 4),
                      _Day(
                        key: ValueKey('day-strip-${_date(day)}'),
                        day: day,
                        today: day == today,
                        picked: day == picked,
                        filled: day == filled,
                        count: counts[day]!,
                        onTap: day.isAfter(today) ? null : () => _choose(day),
                      ),
                    ],
                    const SizedBox(width: 4),
                    CompactIconButton(
                      key: const ValueKey('day-strip-forward'),
                      tooltip: 'Later days',
                      extent: 32,
                      width: 24,
                      radius: 8,
                      onPressed: paged ? () => setState(() => _page--) : null,
                      icon: KapyIcon(
                        KapyIcons.chevronRightRounded,
                        size: 16,
                        strokeWidth: 1.8,
                        color: paged ? null : palette.textDivider,
                      ),
                    ),
                    if (paged) ...[
                      const SizedBox(width: 4),
                      TextButton(
                        key: const ValueKey('day-strip-today'),
                        onPressed: () => setState(() => _page = 0),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(0, 32),
                          fixedSize: const Size.fromHeight(32),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                          foregroundColor: palette.textSecondary,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                            side: BorderSide(color: palette.controlBorder),
                          ),
                          textStyle: _figtree(
                            13,
                            16,
                            FontWeight.w500,
                            palette.textSecondary,
                          ),
                        ),
                        child: const Text('Today'),
                      ),
                    ],
                  ],
                );
              },
            ),
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

/// One day in the week: its weekday, its date in a fill on the band's middle
/// line, and a dot for each of its notes up to three. Hovered or focused, the
/// fill rises. A day still to come is greyed out and takes no click.
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
  final VoidCallback? onTap;

  @override
  State<_Day> createState() => _DayState();
}

class _DayState extends State<_Day> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final day = widget.day;
    final filled = widget.filled;
    final onTap = widget.onTap;
    final ahead = onTap == null;
    final dots = ahead ? 0 : math.min(widget.count, 3);
    final column = SizedBox(
      width: 36,
      height: 52,
      child: Column(
        children: [
          Text(
            SidebarTimestamp.shortWeekday(day),
            maxLines: 1,
            style: _figtree(
              11,
              12,
              widget.today || filled ? FontWeight.w600 : FontWeight.w500,
              ahead
                  ? palette.textDivider
                  : widget.today
                  ? Theme.of(context).colorScheme.primary
                  : filled
                  ? palette.textPrimary
                  : palette.textTertiary,
            ),
          ),
          const SizedBox(height: 2),
          Container(
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: filled
                  ? palette.tonalBackground
                  : _hovered || _focused
                  ? palette.controlBackground
                  : null,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '${day.day}',
              style: _figtree(
                14,
                16,
                filled ? FontWeight.w600 : FontWeight.w500,
                ahead
                    ? palette.textDivider
                    : filled
                    ? palette.tonalForeground
                    : palette.textPrimary,
              ).copyWith(fontFeatures: _figures),
            ),
          ),
          const SizedBox(height: 2),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var dot = 0; dot < dots; dot++) ...[
                if (dot > 0) const SizedBox(width: 2),
                Container(
                  width: 4,
                  height: 4,
                  decoration: BoxDecoration(
                    color: palette.textTertiary,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
    if (ahead) return ExcludeSemantics(child: column);
    return TextButton(
      onPressed: onTap,
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
        textStyle: _figtree(14, 16, FontWeight.w500, palette.textPrimary),
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

/// A month to pick a day from: the strip's filled day in the same fill,
/// today's date in sage, days with notes brighter than days without, and the
/// days still to come greyed out. ‹ and › move a month, never past today's.
class _Month extends StatefulWidget {
  const _Month({
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
  State<_Month> createState() => _MonthState();
}

class _MonthState extends State<_Month> {
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
      if (day.isAfter(today)) {
        return SizedBox.square(
          dimension: 32,
          child: Center(
            child: ExcludeSemantics(
              child: Text(
                '${day.day}',
                style: _figtree(
                  13,
                  16,
                  FontWeight.w400,
                  palette.textDivider,
                ).copyWith(fontFeatures: _figures),
              ),
            ),
          ),
        );
      }
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
                    onPressed: current
                        ? null
                        : () => setState(
                            () =>
                                _month = DateTime(month.year, month.month + 1),
                          ),
                    icon: KapyIcon(
                      KapyIcons.chevronRightRounded,
                      size: 16,
                      strokeWidth: 1.8,
                      color: current ? palette.textDivider : null,
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
