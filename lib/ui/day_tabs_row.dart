import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
import '../core/theme.dart';
import '../data/note.dart';
import 'compact_icon_button.dart';
import 'context_menu.dart';
import 'sidebar_timestamp.dart';

/// A day's notes as tabs under a phone note's week (A1 to A8): a row that
/// glides sideways and keeps the open tab in view, with a fade at an end
/// that has more tabs past it, the count of the day's notes once they don't
/// all fit, which lists them all, and + at the end, which never scrolls away.
///
/// A hold lifts a tab. Let go and it offers Pin tab, or Unpin tab on a
/// pinned one; slide instead and the tab follows the finger while the others
/// make room, and near either end the row glides on by itself. Pinned tabs
/// come first, each with a small pin, and a drag keeps a tab among its kind.
class DayTabsRow extends StatefulWidget {
  const DayTabsRow({
    super.key,
    required this.notes,
    required this.pinned,
    required this.open,
    required this.onOpen,
    required this.onNew,
    required this.onList,
    required this.onPin,
    required this.onMove,
  });

  /// The day's notes in the order their tabs show, the first [pinned] of
  /// them pinned.
  final List<Note> notes;
  final int pinned;

  /// The note open on the page, whose tab is underlined.
  final String? open;

  final ValueChanged<String> onOpen;

  /// + : a new note on the day, as a tab at the end.
  final VoidCallback onNew;

  /// The count: every note on the day, in a list.
  final VoidCallback onList;

  /// Pin tab, or with [pin] false Unpin tab.
  final void Function(String noteId, {required bool pin}) onPin;

  /// A tab let go of [to] places from the front.
  final void Function(String noteId, int to) onMove;

  /// The row's height, every tab's height to press.
  static const double height = 44;

  @override
  State<DayTabsRow> createState() => _DayTabsRowState();
}

/// A tab held and slid along the row: its note, the finger along the row,
/// where on the tab the finger holds it, and the place among the other tabs
/// it goes to if let go now.
typedef _Drag = ({String id, double finger, double grab, int to});

class _DayTabsRowState extends State<DayTabsRow>
    with SingleTickerProviderStateMixin {
  /// The room before the first tab and after the last, between two tabs, a
  /// fade at either end, and the widest a title runs before it is cut short.
  static const double _start = 20;
  static const double _end = 16;
  static const double _gap = 18;
  static const double _fade = 44;
  static const double _titleMax = 180;

  /// How far a held finger moves before the tab follows it.
  static const double _slop = 8;

  /// The fastest the row glides under a dragged tab, a frame at a time.
  static const double _glideMax = 8;

  final _scroll = ScrollController();
  final _area = GlobalKey();
  late final Ticker _glider = createTicker((_) => _glide());

  /// The tab a hold lifted, until its menu closes or its drag ends.
  String? _lifted;

  /// Where the hold began, until the finger moves far enough to drag.
  Offset? _holdAt;

  _Drag? _drag;

  /// Whether there are tabs past each end of the row.
  bool _moreBefore = false;
  bool _moreAfter = false;

  /// The titles up to the open tab's when the row last brought it into view,
  /// so a title that grows before it, or its own as it is typed, is followed
  /// too.
  List<String> _titlesToOpen = const [];

  List<String> _titlesUpToOpen() => [
    for (final note in widget.notes.take(
      widget.notes.indexWhere((note) => note.id == widget.open) + 1,
    ))
      note.title,
  ];

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_edges);
    _titlesToOpen = _titlesUpToOpen();
    WidgetsBinding.instance.addPostFrameCallback((_) => _showOpen());
  }

  @override
  void didUpdateWidget(DayTabsRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    int openAt(DayTabsRow row) =>
        row.notes.indexWhere((note) => note.id == row.open);
    final titles = _titlesUpToOpen();
    if (widget.open != oldWidget.open ||
        openAt(widget) != openAt(oldWidget) ||
        widget.pinned != oldWidget.pinned ||
        widget.notes.length != oldWidget.notes.length ||
        !listEquals(titles, _titlesToOpen)) {
      _titlesToOpen = titles;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _showOpen(glide: true),
      );
    }
  }

  @override
  void dispose() {
    _glider.dispose();
    _scroll.dispose();
    super.dispose();
  }

  TextStyle _titleStyle(BuildContext context, {required bool open}) {
    final palette = context.palette;
    return chromeStyle(
      size: AppTypeScale.control,
      line: 20,
      weight: open ? AppWeight.regular : AppWeight.regular,
      color: open ? palette.textPrimary : palette.textSecondary,
    );
  }

  /// How wide a tab's title and pin are.
  double _labelWidth(
    BuildContext context,
    Note note, {
    required bool open,
    required bool pinned,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: note.title,
        style: _titleStyle(context, open: open),
      ),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = math.min(painter.width, _titleMax);
    painter.dispose();
    return (pinned ? 13 + 4 : 0) + width;
  }

  List<double> _widths(BuildContext context) => [
    for (final (index, note) in widget.notes.indexed)
      _labelWidth(
        context,
        note,
        open: note.id == widget.open,
        pinned: index < widget.pinned,
      ),
  ];

  /// The room a tab of [width] takes to press: half a gap either side, and
  /// never under 44.
  static double _slot(double width) =>
      math.max(width + _gap, DayTabsRow.height);

  /// Where the tab at [index] begins along the row's tabs.
  static double _leftOf(List<double> widths, int index) {
    var left = _start - _gap / 2;
    for (var i = 0; i < index; i++) {
      left += _slot(widths[i]);
    }
    return left;
  }

  void _edges() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    final before = position.pixels > 0.5;
    final after = position.pixels < position.maxScrollExtent - 0.5;
    if (before == _moreBefore && after == _moreAfter) return;
    setState(() {
      _moreBefore = before;
      _moreAfter = after;
    });
  }

  /// Brings the open tab clear of the fades, gliding there with [glide].
  void _showOpen({bool glide = false}) {
    if (!mounted || !_scroll.hasClients) return;
    final index = widget.notes.indexWhere((note) => note.id == widget.open);
    if (index < 0) return;
    final widths = _widths(context);
    final position = _scroll.position;
    final slot = _slot(widths[index]);
    final margin = math.min(
      _fade - _gap / 2,
      math.max(0.0, (position.viewportDimension - slot) / 2),
    );
    final left = _leftOf(widths, index) - margin;
    final right = _leftOf(widths, index) + slot + margin;
    var to = position.pixels;
    if (left < to) {
      to = left;
    } else if (right > to + position.viewportDimension) {
      to = right - position.viewportDimension;
    }
    to = to.clamp(0, position.maxScrollExtent);
    if ((to - position.pixels).abs() < 0.5) return;
    if (glide) {
      unawaited(
        _scroll.animateTo(
          to,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
        ),
      );
    } else {
      _scroll.jumpTo(to);
    }
  }

  RenderBox? get _areaBox =>
      _area.currentContext?.findRenderObject() as RenderBox?;

  void _lift(Note note, LongPressStartDetails details) {
    if (AppPlatform.isIOS) {
      unawaited(HapticFeedback.lightImpact());
    } else {
      unawaited(Feedback.forLongPress(context));
    }
    setState(() {
      _lifted = note.id;
      _holdAt = details.globalPosition;
    });
  }

  void _slide(Note note, LongPressMoveUpdateDetails details) {
    final area = _areaBox;
    if (area == null || _lifted != note.id) return;
    final finger = area.globalToLocal(details.globalPosition).dx;
    final drag = _drag;
    if (drag != null) return _dragTo(finger);
    if (details.offsetFromOrigin.distance < _slop) return;
    final widths = _widths(context);
    final index = widget.notes.indexOf(note);
    final chipLeft =
        _leftOf(widths, index) +
        (_slot(widths[index]) - widths[index]) / 2 -
        10 -
        _scroll.offset;
    final start = area.globalToLocal(_holdAt ?? details.globalPosition).dx;
    setState(() {
      _drag = (id: note.id, finger: finger, grab: start - chipLeft, to: index);
    });
    _dragTo(finger);
    unawaited(_glider.start());
  }

  /// The dragged tab's chip under [finger], and its place among the others.
  void _dragTo(double finger) {
    final drag = _drag;
    final area = _areaBox;
    if (drag == null || area == null) return;
    final widths = _widths(context);
    final dragged = widget.notes.indexWhere((note) => note.id == drag.id);
    if (dragged < 0) return;
    final chip = widths[dragged] + 20;
    final left = (finger - drag.grab).clamp(
      0.0,
      math.max(0.0, area.size.width - chip),
    );
    final middle = left + chip / 2 + _scroll.offset;
    final ofPinned = dragged < widget.pinned;
    final first = ofPinned ? 0 : widget.pinned;
    final last = ofPinned ? widget.pinned - 1 : widths.length - 1;
    final slot = _slot(widths[dragged]);
    var at = _start - _gap / 2;
    var place = first;
    var nearest = double.infinity;
    var before = 0;
    for (var index = 0; index <= widths.length; index++) {
      if (index == dragged) continue;
      if (before >= first && before <= last) {
        final distance = (at + slot / 2 - middle).abs();
        if (distance < nearest) {
          nearest = distance;
          place = before;
        }
      }
      if (index < widths.length) at += _slot(widths[index]);
      before++;
    }
    setState(
      () => _drag = (id: drag.id, finger: finger, grab: drag.grab, to: place),
    );
  }

  /// Near either end of the row, the row glides under the dragged tab.
  void _glide() {
    final drag = _drag;
    final area = _areaBox;
    if (drag == null || area == null || !_scroll.hasClients) return;
    final finger = drag.finger;
    final width = area.size.width;
    final speed = finger < _fade
        ? -_glideMax * (_fade - finger) / _fade
        : finger > width - _fade
        ? _glideMax * (finger - (width - _fade)) / _fade
        : 0.0;
    if (speed == 0) return;
    final position = _scroll.position;
    final to = (position.pixels + speed).clamp(0.0, position.maxScrollExtent);
    if (to == position.pixels) return;
    _scroll.jumpTo(to);
    _dragTo(finger);
  }

  Future<void> _letGo(Note note) async {
    final drag = _drag;
    _glider.stop();
    if (drag != null) {
      setState(() {
        _drag = null;
        _lifted = null;
        _holdAt = null;
      });
      widget.onMove(drag.id, drag.to);
      return;
    }
    final area = _areaBox;
    if (area == null || _lifted != note.id) return _drop();
    final widths = _widths(context);
    final index = widget.notes.indexOf(note);
    final pinned = index < widget.pinned;
    final right =
        _leftOf(widths, index) +
        (_slot(widths[index]) + widths[index]) / 2 +
        10 -
        _scroll.offset;
    final screen = MediaQuery.sizeOf(context);
    final choice = await showKapyContextMenu<String>(
      context: context,
      globalPosition: area.localToGlobal(Offset(right, DayTabsRow.height + 4)),
      preferredGlobalBounds: Rect.fromLTRB(
        12,
        0,
        screen.width - 12,
        screen.height,
      ),
      items: kapyMenuItems(
        (
          heading: null,
          groups: [
            [
              KapyMenuAction(
                value: 'pin',
                label: pinned ? 'Unpin tab' : 'Pin tab',
                icon: KapyIcons.pinOutlined,
              ),
            ],
          ],
        ),
        key: (value) => 'day-tab-$value',
        height: 44,
      ),
    );
    if (!mounted) return;
    _drop();
    if (choice == 'pin') widget.onPin(note.id, pin: !pinned);
  }

  void _drop() {
    _glider.stop();
    if (_lifted == null && _drag == null) return;
    setState(() {
      _lifted = null;
      _holdAt = null;
      _drag = null;
    });
  }

  BoxDecoration _card(BuildContext context) {
    final palette = context.palette;
    return BoxDecoration(
      color: palette.cardBackground,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(
        color: palette.controlBorder,
        width: AppHairline.of(context),
      ),
      boxShadow: [
        BoxShadow(
          color: palette.shadowAt(89),
          blurRadius: 16,
          offset: const Offset(0, 6),
        ),
      ],
    );
  }

  Widget _label(
    BuildContext context,
    Note note, {
    required bool open,
    required bool pinned,
  }) {
    final palette = context.palette;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (pinned) ...[
          KapyIcon(
            KapyIcons.pinOutlined,
            size: 13,
            color: open ? palette.textSecondary : palette.textTertiary,
          ),
          const SizedBox(width: 4),
        ],
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _titleMax),
          child: Text(
            note.title,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: _titleStyle(context, open: open),
          ),
        ),
      ],
    );
  }

  Widget _tab(
    BuildContext context,
    Note note,
    int index,
    double width, {
    bool dragged = false,
  }) {
    final palette = context.palette;
    final open = note.id == widget.open;
    final pinned = index < widget.pinned;
    final first = pinned ? 0 : widget.pinned;
    final last = pinned ? widget.pinned - 1 : widget.notes.length - 1;
    return Semantics(
      key: ValueKey('day-tab-${note.id}'),
      button: true,
      selected: open,
      label: pinned ? '${note.title}, pinned' : note.title,
      onTap: () => widget.onOpen(note.id),
      customSemanticsActions: {
        CustomSemanticsAction(label: pinned ? 'Unpin tab' : 'Pin tab'): () =>
            widget.onPin(note.id, pin: !pinned),
        if (index > first)
          const CustomSemanticsAction(label: 'Move left'): () =>
              widget.onMove(note.id, index - 1),
        if (index < last)
          const CustomSemanticsAction(label: 'Move right'): () =>
              widget.onMove(note.id, index + 1),
      },
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.onOpen(note.id),
        onLongPressStart: (details) => _lift(note, details),
        onLongPressMoveUpdate: (details) => _slide(note, details),
        onLongPressEnd: (_) => unawaited(_letGo(note)),
        onLongPressCancel: _drop,
        child: SizedBox(
          width: _slot(width),
          height: DayTabsRow.height,
          child: Opacity(
            opacity: dragged ? 0 : 1,
            child: Center(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  if (_lifted == note.id)
                    Positioned(
                      left: -10,
                      right: -10,
                      top: 5,
                      bottom: 5,
                      child: DecoratedBox(decoration: _card(context)),
                    ),
                  SizedBox(
                    height: DayTabsRow.height,
                    child: Center(
                      widthFactor: 1,
                      child: _label(context, note, open: open, pinned: pinned),
                    ),
                  ),
                  if (open)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: 2,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: palette.accentText,
                          borderRadius: BorderRadius.circular(1),
                        ),
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

  Widget _fadeAt(BuildContext context, {required bool start}) {
    final paper = context.palette.paperColor;
    return Positioned(
      left: start ? 0 : null,
      right: start ? null : 0,
      top: 0,
      bottom: 0,
      width: _fade,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: start ? Alignment.centerRight : Alignment.centerLeft,
              end: start ? Alignment.centerLeft : Alignment.centerRight,
              colors: [paper.withValues(alpha: 0), paper],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tabs(BuildContext context, List<double> widths) {
    final notes = widget.notes;
    final drag = _drag;
    final dragged = drag == null
        ? -1
        : notes.indexWhere((note) => note.id == drag.id);
    final row = [
      for (final (index, note) in notes.indexed)
        _tab(context, note, index, widths[index], dragged: index == dragged),
    ];
    final area = _areaBox;
    double? chipLeft;
    if (drag != null && dragged >= 0) {
      // The tab held stays in the row, out of sight where it would go, so
      // the hold that drags it carries on.
      row.insert(drag.to, row.removeAt(dragged));
      chipLeft = (drag.finger - drag.grab).clamp(
        0.0,
        math.max(0.0, (area?.size.width ?? 0) - widths[dragged] - 20),
      );
    }
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        _edges();
        return false;
      },
      child: Stack(
        key: _area,
        children: [
          SingleChildScrollView(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            physics: drag == null ? null : const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.only(
              left: _start - _gap / 2,
              right: _end - _gap / 2,
            ),
            child: Row(children: row),
          ),
          if (_moreBefore) _fadeAt(context, start: true),
          if (_moreAfter) _fadeAt(context, start: false),
          if (chipLeft != null)
            Positioned(
              key: const ValueKey('day-tab-dragged'),
              left: chipLeft,
              top: (DayTabsRow.height - 36) / 2,
              height: 36,
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: _card(context),
                  child: Center(
                    widthFactor: 1,
                    child: _label(
                      context,
                      notes[dragged],
                      open: notes[dragged].id == widget.open,
                      pinned: dragged < widget.pinned,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _count(BuildContext context) {
    final palette = context.palette;
    final count = widget.notes.length;
    return Semantics(
      button: true,
      label: 'All $count notes on this day',
      excludeSemantics: true,
      onTap: widget.onList,
      child: GestureDetector(
        key: const ValueKey('day-tabs-count'),
        behavior: HitTestBehavior.opaque,
        onTap: widget.onList,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: DayTabsRow.height,
            minHeight: DayTabsRow.height,
          ),
          child: Center(
            child: Container(
              height: 30,
              padding: const EdgeInsets.only(left: 10, right: 6),
              decoration: BoxDecoration(
                color: palette.selectedBackground,
                borderRadius: BorderRadius.circular(15),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$count',
                    style: chromeStyle(
                      size: AppTypeScale.small,
                      line: 18,
                      weight: AppWeight.regular,
                      color: palette.textPrimary,
                      tabular: true,
                    ),
                  ),
                  const SizedBox(width: 2),
                  KapyIcon(
                    KapyIcons.chevronDownRounded,
                    size: 14,
                    color: palette.textSecondary,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final widths = _widths(context);
    final content =
        _start +
        _end -
        _gap +
        widths.fold(0.0, (sum, width) => sum + _slot(width));
    return SizedBox(
      key: const ValueKey('day-tabs'),
      height: DayTabsRow.height,
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            Expanded(child: _tabs(context, widths)),
            if (content > constraints.maxWidth - DayTabsRow.height)
              Visibility(
                visible: _drag == null,
                maintainSize: true,
                maintainAnimation: true,
                maintainState: true,
                child: _count(context),
              ),
            CompactIconButton(
              key: const ValueKey('day-tabs-new'),
              tooltip: 'New note on this day',
              extent: DayTabsRow.height,
              radius: 10,
              onPressed: widget.onNew,
              icon: KapyIcon(
                KapyIcons.addRounded,
                size: 18,
                color: palette.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Every note on [day] in a sheet (A4), in the order of its tabs, scrolled to
/// [open], which has a tick, each with the time it was started. A tap picks a
/// note and closes the sheet; a swipe down, or a tap above it, closes it.
Future<String?> showDayNotes(
  BuildContext context, {
  required DateTime day,
  required List<Note> notes,
  required String? open,
  required DateTime Function(DateTime) displayTime,
}) {
  const row = 46.0;
  const top = 17 + 44.0;
  final screen = MediaQuery.sizeOf(context);
  final room = screen.height - MediaQuery.paddingOf(context).top;
  final fits =
      (top + notes.length * row + 16 + MediaQuery.paddingOf(context).bottom) /
      room;
  final most = math.min(fits, 0.92);
  final first = math.min(most, 0.55);
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Theme.of(context).drawerTheme.scrimColor,
    builder: (sheet) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: first,
      minChildSize: math.min(first, 0.25),
      maxChildSize: most,
      builder: (sheet, scroll) {
        final palette = sheet.palette;
        final index = notes.indexWhere((note) => note.id == open);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (index < 0 || !scroll.hasClients || scroll.offset > 0) return;
          final position = scroll.position;
          final to = ((index + 1) * row - position.viewportDimension + row / 2)
              .clamp(0.0, position.maxScrollExtent);
          if (to > 0) scroll.jumpTo(to);
        });
        return DecoratedBox(
          key: const ValueKey('day-notes-sheet'),
          decoration: BoxDecoration(
            color: palette.paperColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 5,
                  margin: const EdgeInsets.only(top: 8, bottom: 4),
                  decoration: BoxDecoration(
                    color: palette.controlBorder,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Flexible(
                      child: Text(
                        SidebarTimestamp.fullDay(day),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: chromeStyle(
                          size: 19,
                          line: 24,
                          weight: AppWeight.regular,
                          color: palette.textPrimary,
                          family: AppFonts.ui,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      notes.length == 1 ? '1 note' : '${notes.length} notes',
                      style: chromeStyle(
                        size: AppTypeScale.caption,
                        line: 16,
                        weight: AppWeight.regular,
                        color: palette.textTertiary,
                        tabular: true,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  controller: scroll,
                  itemExtent: row,
                  padding: EdgeInsets.only(
                    bottom: 16 + MediaQuery.paddingOf(sheet).bottom,
                  ),
                  itemCount: notes.length,
                  itemBuilder: (context, at) {
                    final note = notes[at];
                    return Semantics(
                      selected: note.id == open,
                      child: InkWell(
                        key: ValueKey('day-notes-${note.id}'),
                        onTap: () => Navigator.of(sheet).pop(note.id),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Row(
                            children: [
                              SizedBox.square(
                                dimension: 18,
                                child: note.id == open
                                    ? KapyIcon(
                                        KapyIcons.checkRounded,
                                        size: 16,
                                        color: palette.accentText,
                                      )
                                    : null,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  note.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: chromeStyle(
                                    size: AppTypeScale.row,
                                    line: 22,
                                    weight: AppWeight.regular,
                                    color: palette.textPrimary,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                SidebarTimestamp.clock(
                                  displayTime(note.createdAt),
                                ),
                                style: chromeStyle(
                                  size: AppTypeScale.caption,
                                  line: 16,
                                  weight: AppWeight.regular,
                                  color: palette.textTertiary,
                                  tabular: true,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}
