import 'dart:async';

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/platform.dart';
import '../../core/theme.dart';
import '../context_menu.dart';
import 'markdown_syntax.dart';

/// One table where it is drawn now, in global coordinates: the top of every
/// row and the bottom of the last, and the left of every column and the right
/// of the last.
@immutable
class TableFrame {
  const TableFrame({
    required this.table,
    required this.rowEdges,
    required this.columnEdges,
  });

  /// Where the table's source starts, which is how the editor finds it again.
  final int table;
  final List<double> rowEdges;
  final List<double> columnEdges;

  int get rows => rowEdges.length - 1;
  int get columns => columnEdges.length - 1;

  /// The row [y] is in, or null off the grid.
  int? rowAt(double y) => _indexIn(rowEdges, y);

  /// The column [x] is in, or null off the grid.
  int? columnAt(double x) => _indexIn(columnEdges, x);

  Rect get grid => Rect.fromLTRB(
    columnEdges.first,
    rowEdges.first,
    columnEdges.last,
    rowEdges.last,
  );

  Rect band(TableAxis axis, int index) => axis == TableAxis.row
      ? Rect.fromLTRB(
          columnEdges.first,
          rowEdges[index],
          columnEdges.last,
          rowEdges[index + 1],
        )
      : Rect.fromLTRB(
          columnEdges[index],
          rowEdges.first,
          columnEdges[index + 1],
          rowEdges.last,
        );
}

int? _indexIn(List<double> edges, double at) {
  if (at < edges.first || at >= edges.last) return null;
  for (var i = 0; i < edges.length - 1; i++) {
    if (at < edges[i + 1]) return i;
  }
  return null;
}

enum TableAxis { row, column }

/// A whole row or column of one table.
typedef TableLine = ({int table, TableAxis axis, int index});

/// Everything that can be done to a table from its menus and shortcuts.
enum TableCommand {
  cut('Cut', KapyIcons.cutRounded, '⌘X', 'Ctrl+X'),
  copy('Copy', KapyIcons.copyRounded, '⌘C', 'Ctrl+C'),
  paste('Paste', KapyIcons.pasteRounded, '⌘V', 'Ctrl+V'),
  rowAbove('Row above', KapyIcons.tableRowAbove, '⌥⌘↑', 'Ctrl+Alt+↑'),
  rowBelow('Row below', KapyIcons.tableRowBelow, '⌥⌘↓', 'Ctrl+Alt+↓'),
  columnLeft('Column left', KapyIcons.tableColumnLeft, '⌥⌘←', 'Ctrl+Alt+←'),
  columnRight('Column right', KapyIcons.tableColumnRight, '⌥⌘→', 'Ctrl+Alt+→'),
  rowUp('Move up', KapyIcons.chevronUpRounded, '⌥⇧↑', 'Alt+Shift+↑'),
  rowDown('Move down', KapyIcons.chevronDownRounded, '⌥⇧↓', 'Alt+Shift+↓'),
  columnBack('Move left', KapyIcons.chevronLeftRounded, '⌥⇧←', 'Alt+Shift+←'),
  columnForward(
    'Move right',
    KapyIcons.chevronRightRounded,
    '⌥⇧→',
    'Alt+Shift+→',
  ),
  alignStart('Align left', KapyIcons.alignLeft, null, null),
  alignCenter('Align centre', KapyIcons.alignCenter, null, null),
  alignEnd('Align right', KapyIcons.alignRight, null, null),
  deleteRow(
    'Delete row',
    KapyIcons.tableDeleteRow,
    '⇧⌘⌫',
    'Ctrl+Shift+Backspace',
  ),
  deleteColumn(
    'Delete column',
    KapyIcons.tableDeleteColumn,
    '⌥⌘⌫',
    'Ctrl+Alt+Backspace',
  );

  const TableCommand(this.label, this.icon, this._mac, this._other);

  final String label;
  final KapyIconData icon;
  final String? _mac;
  final String? _other;

  /// The keys as a menu prints them, on a keyboard of this platform.
  String? get keys => !AppPlatform.hasPointer
      ? null
      : AppPlatform.isMacOS
      ? _mac
      : _other;

  bool get destructive => this == deleteRow || this == deleteColumn;

  MarkdownCellAlign? get align => switch (this) {
    alignStart => MarkdownCellAlign.start,
    alignCenter => MarkdownCellAlign.center,
    alignEnd => MarkdownCellAlign.end,
    _ => null,
  };
}

/// The table command [event] is the shortcut for, if any.
///
/// The primary modifier is ⌘ on a Mac and Ctrl elsewhere. Moving a column is
/// left out where [columnMoves] is false: in a cell, ⌥⇧← and ⌥⇧→ select a
/// word, and that has to keep working.
TableCommand? tableCommandFor(KeyEvent event, {required bool columnMoves}) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) return null;
  final keyboard = HardwareKeyboard.instance;
  final mac = AppPlatform.isMacOS;
  final primary = mac ? keyboard.isMetaPressed : keyboard.isControlPressed;
  final other = mac ? keyboard.isControlPressed : keyboard.isMetaPressed;
  if (other) return null;
  final alt = keyboard.isAltPressed;
  final shift = keyboard.isShiftPressed;
  final key = event.logicalKey;
  if (primary && alt && !shift) {
    return switch (key) {
      LogicalKeyboardKey.arrowUp => TableCommand.rowAbove,
      LogicalKeyboardKey.arrowDown => TableCommand.rowBelow,
      LogicalKeyboardKey.arrowLeft => TableCommand.columnLeft,
      LogicalKeyboardKey.arrowRight => TableCommand.columnRight,
      LogicalKeyboardKey.backspace => TableCommand.deleteColumn,
      _ => null,
    };
  }
  if (primary && shift && !alt && key == LogicalKeyboardKey.backspace) {
    return TableCommand.deleteRow;
  }
  if (!primary && alt && shift) {
    return switch (key) {
      LogicalKeyboardKey.arrowUp => TableCommand.rowUp,
      LogicalKeyboardKey.arrowDown => TableCommand.rowDown,
      LogicalKeyboardKey.arrowLeft when columnMoves => TableCommand.columnBack,
      LogicalKeyboardKey.arrowRight when columnMoves =>
        TableCommand.columnForward,
      _ => null,
    };
  }
  return null;
}

/// The sections of a table's menu: text editing when it opens on a cell, then
/// inserting, moving (from a grip only; a cell's menu would not fit a small
/// window with them, and a cell has the shortcuts and drag), alignment for a
/// column, and deleting.
List<List<TableCommand>> tableMenuSections({
  required bool text,
  required bool row,
  required bool column,
}) => [
  if (text) [TableCommand.cut, TableCommand.copy, TableCommand.paste],
  [
    if (row) ...[TableCommand.rowAbove, TableCommand.rowBelow],
    if (column) ...[TableCommand.columnLeft, TableCommand.columnRight],
  ],
  if (row != column)
    [
      if (row) ...[TableCommand.rowUp, TableCommand.rowDown],
      if (column) ...[TableCommand.columnBack, TableCommand.columnForward],
    ],
  if (column)
    [TableCommand.alignStart, TableCommand.alignCenter, TableCommand.alignEnd],
  [if (row) TableCommand.deleteRow, if (column) TableCommand.deleteColumn],
];

/// Shows a table's menu at [position] with a pointer, or as a sheet on a
/// phone, and returns what was picked.
Future<TableCommand?> showTableMenu({
  required BuildContext context,
  required Offset position,
  required List<List<TableCommand>> sections,
  required bool Function(TableCommand command) enabled,
  required MarkdownCellAlign? alignment,
}) {
  if (!AppPlatform.hasPointer) {
    return _showTableSheet(context, sections, enabled, alignment);
  }
  return showKapyContextMenu<TableCommand>(
    context: context,
    globalPosition: position,
    items: [
      for (final (index, section) in sections.indexed) ...[
        if (index > 0) const PopupMenuDivider(height: 9),
        if (section.first == TableCommand.rowAbove ||
            section.first == TableCommand.columnLeft)
          const _MenuHeading('Insert'),
        if (section.first.align != null)
          _AlignEntry(current: alignment, touch: false)
        else
          for (final command in section)
            PopupMenuItem(
              key: ValueKey('table-menu-${command.name}'),
              value: command,
              enabled: enabled(command),
              height: 32,
              child: KapyMenuActionRow(_action(command), touch: false),
            ),
      ],
    ],
  );
}

KapyMenuAction _action(TableCommand command) => KapyMenuAction(
  value: command.name,
  label: command.label,
  icon: command.icon,
  hint: command.keys,
  destructive: command.destructive,
);

Future<TableCommand?> _showTableSheet(
  BuildContext context,
  List<List<TableCommand>> sections,
  bool Function(TableCommand command) enabled,
  MarkdownCellAlign? alignment,
) {
  final palette = context.palette;
  return showModalBottomSheet<TableCommand>(
    context: context,
    isScrollControlled: true,
    backgroundColor: palette.surfaceBackground,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(AppRadii.dialog),
      ),
    ),
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 34,
                height: 4,
                margin: const EdgeInsets.only(bottom: 4),
                decoration: BoxDecoration(
                  color: palette.controlBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            for (final (index, section) in sections.indexed) ...[
              if (index > 0) Divider(height: 9, color: palette.separator),
              if (section.first.align != null)
                _AlignRow(
                  current: alignment,
                  touch: true,
                  onPick: (command) => Navigator.of(sheetContext).pop(command),
                )
              else
                for (final command in section)
                  InkWell(
                    key: ValueKey('table-menu-${command.name}'),
                    onTap: enabled(command)
                        ? () => Navigator.of(sheetContext).pop(command)
                        : null,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      child: KapyMenuActionRow(
                        KapyMenuAction(
                          value: command.name,
                          label: command.label,
                          icon: command.icon,
                          destructive: command.destructive,
                          enabled: enabled(command),
                        ),
                        touch: true,
                      ),
                    ),
                  ),
            ],
          ],
        ),
      ),
    ),
  );
}

class _MenuHeading extends PopupMenuEntry<TableCommand> {
  const _MenuHeading(this.label);

  final String label;

  @override
  double get height => 22;

  @override
  bool represents(TableCommand? value) => false;

  @override
  State<_MenuHeading> createState() => _MenuHeadingState();
}

class _MenuHeadingState extends State<_MenuHeading> {
  @override
  Widget build(BuildContext context) => Container(
    height: widget.height,
    alignment: AlignmentDirectional.bottomStart,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Text(
      widget.label,
      style: TextStyle(
        fontSize: AppTypeScale.caption,
        fontWeight: FontWeight.w400,
        color: context.palette.textTertiary,
      ),
    ),
  );
}

/// The three alignments on one line of the menu.
class _AlignEntry extends PopupMenuEntry<TableCommand> {
  const _AlignEntry({required this.current, required this.touch});

  final MarkdownCellAlign? current;
  final bool touch;

  @override
  double get height => 32;

  @override
  bool represents(TableCommand? value) => value?.align != null;

  @override
  State<_AlignEntry> createState() => _AlignEntryState();
}

class _AlignEntryState extends State<_AlignEntry> {
  @override
  Widget build(BuildContext context) => SizedBox(
    height: widget.height,
    child: _AlignRow(
      current: widget.current,
      touch: widget.touch,
      onPick: (command) => Navigator.of(context).pop(command),
    ),
  );
}

class _AlignRow extends StatelessWidget {
  const _AlignRow({
    required this.current,
    required this.touch,
    required this.onPick,
  });

  final MarkdownCellAlign? current;
  final bool touch;
  final ValueChanged<TableCommand> onPick;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final side = touch ? 44.0 : 26.0;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: touch ? 20 : 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Align',
              style: TextStyle(
                fontSize: touch ? AppTypeScale.body : AppTypeScale.control,
                fontWeight: FontWeight.w400,
                color: palette.textPrimary,
              ),
            ),
          ),
          for (final command in const [
            TableCommand.alignStart,
            TableCommand.alignCenter,
            TableCommand.alignEnd,
          ])
            Semantics(
              button: true,
              selected: command.align == current,
              label: command.label,
              child: InkWell(
                key: ValueKey('table-menu-${command.name}'),
                onTap: () => onPick(command),
                borderRadius: BorderRadius.circular(AppRadii.compact),
                hoverColor: palette.hover,
                child: Container(
                  width: side,
                  height: side,
                  alignment: Alignment.center,
                  decoration: command.align == current
                      ? BoxDecoration(
                          color: palette.selectedBackground,
                          borderRadius: BorderRadius.circular(AppRadii.compact),
                        )
                      : null,
                  child: KapyIcon(
                    command.icon,
                    size: touch
                        ? AppControlMetrics.iconAction
                        : AppControlMetrics.iconControl,
                    color: command.align == current
                        ? Theme.of(context).colorScheme.primary
                        : palette.textSecondary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The row or column picked with its grip, which Delete takes away, and where
/// the controls on screen are, so that a press on one never reaches the note.
class TableControlsController extends ChangeNotifier {
  TableLine? _selected;
  TableLine? get selected => _selected;
  set selected(TableLine? value) {
    if (value == _selected) return;
    _selected = value;
    notifyListeners();
  }

  List<Rect> _handles = const [];

  /// Whether a press at [global] lands on one of the controls.
  bool claims(Offset global) => _handles.any((rect) => rect.contains(global));
}

/// The handles a table is edited by, over the grid the backdrop paints.
///
/// With a pointer they appear only over the table the pointer is on: a grip on
/// the left edge of the row and the top edge of the column under it, a "+"
/// where two rows or two columns meet when the pointer nears that edge, a "+"
/// past the last row and the last column, and a column's border that drags
/// its width. On a phone they show for the table being edited instead, at a
/// finger's size.
class TableControlsLayer extends StatefulWidget {
  const TableControlsLayer({
    super.key,
    required this.frames,
    required this.repaint,
    required this.scroll,
    required this.controller,
    required this.editing,
    required this.touch,
    required this.onInsert,
    required this.onMove,
    required this.onResize,
    required this.onMenu,
  });

  final List<TableFrame> Function() frames;

  /// Fires when the grid may have moved: a scroll, or an edit.
  final Listenable repaint;

  /// Scrolled while a row is dragged past the top or bottom of the note.
  final ScrollController scroll;
  final TableControlsController controller;

  /// The cell open for editing, whose table keeps its controls on screen where
  /// there is no pointer to hover with.
  final ({int table, int row, int column})? editing;
  final bool touch;

  /// Adds an empty row or column so that it becomes number [at].
  final void Function(TableFrame frame, TableAxis axis, int at) onInsert;

  /// Moves row or column [from] so that it becomes number [to].
  final void Function(TableFrame frame, TableAxis axis, int from, int to)
  onMove;

  /// Sets [column] to [width] pixels, or back to fitting its words when null.
  final void Function(TableFrame frame, int column, double? width) onResize;

  /// Opens the table's menu for a row, a column, or a cell when both are
  /// given.
  final void Function(
    TableFrame frame, {
    int? row,
    int? column,
    required Rect anchor,
  })
  onMenu;

  /// How close to an edge the pointer has to be to be offered the "+" there.
  static const double gapReach = 6;

  /// How far either side of the grid's left and top edge the pointer counts
  /// as being at the grips.
  static const double gripReach = 14;

  /// How near the top or bottom of the note a dragged row scrolls it.
  static const double scrollReach = 40;

  @override
  State<TableControlsLayer> createState() => _TableControlsLayerState();
}

typedef _Drag = ({int table, TableAxis axis, int from, Offset pointer});
typedef _Resize = ({int table, int column, double start, double width});

class _TableControlsLayerState extends State<TableControlsLayer> {
  Offset? _pointer;
  bool _rebuildScheduled = false;
  _Drag? _drag;
  _Resize? _resize;
  double _resizeDelta = 0;
  Timer? _autoScroll;

  @override
  void initState() {
    super.initState();
    widget.repaint.addListener(_afterLayout);
    widget.controller.addListener(_afterLayout);
  }

  @override
  void didUpdateWidget(TableControlsLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repaint != widget.repaint) {
      oldWidget.repaint.removeListener(_afterLayout);
      widget.repaint.addListener(_afterLayout);
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_afterLayout);
      widget.controller.addListener(_afterLayout);
    }
  }

  @override
  void dispose() {
    _clearGesture();
    widget.repaint.removeListener(_afterLayout);
    widget.controller.removeListener(_afterLayout);
    super.dispose();
  }

  /// The grid is measured by the field's own layout, so the controls follow it
  /// once that layout is done rather than reading last frame's.
  void _afterLayout() {
    if (_rebuildScheduled) return;
    _rebuildScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _rebuildScheduled = false;
      if (mounted) setState(() {});
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  TableFrame? _frame(int table) {
    for (final frame in widget.frames()) {
      if (frame.table == table) return frame;
    }
    return null;
  }

  // Dragging a row or a column ----------------------------------------------

  void _startDrag(TableFrame frame, TableAxis axis, int from, Offset at) {
    widget.controller.selected = null;
    HardwareKeyboard.instance.addHandler(_escape);
    setState(
      () => _drag = (table: frame.table, axis: axis, from: from, pointer: at),
    );
  }

  void _updateDrag(Offset at) {
    final drag = _drag;
    if (drag == null) return;
    setState(
      () => _drag = (
        table: drag.table,
        axis: drag.axis,
        from: drag.from,
        pointer: at,
      ),
    );
    _scrollNear(at);
  }

  void _endDrag() {
    final drag = _drag;
    _endGesture();
    if (drag == null) return;
    final frame = _frame(drag.table);
    if (frame == null) return;
    final to = _dropIndex(frame, drag);
    if (to != drag.from) widget.onMove(frame, drag.axis, drag.from, to);
  }

  /// Where a dragged row or column would land: rows below the header only,
  /// since the header is what makes the lines a table.
  static int _dropIndex(TableFrame frame, _Drag drag) {
    if (drag.axis == TableAxis.row) {
      final y = drag.pointer.dy.clamp(
        frame.rowEdges[1],
        frame.rowEdges.last - 0.01,
      );
      return (frame.rowAt(y) ?? drag.from).clamp(1, frame.rows - 1);
    }
    final x = drag.pointer.dx.clamp(
      frame.columnEdges.first,
      frame.columnEdges.last - 0.01,
    );
    return frame.columnAt(x) ?? drag.from;
  }

  /// Scrolls the note while a dragged row is held near its top or bottom.
  void _scrollNear(Offset at) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || !widget.scroll.hasClients) return;
    final top = box.localToGlobal(Offset.zero).dy;
    final bottom = top + box.size.height;
    final reach = TableControlsLayer.scrollReach;
    final step = at.dy < top + reach
        ? -8.0
        : at.dy > bottom - reach
        ? 8.0
        : 0.0;
    if (step == 0) {
      _autoScroll?.cancel();
      _autoScroll = null;
      return;
    }
    _autoScroll ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
      final position = widget.scroll.position;
      final next = (position.pixels + step).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if (next != position.pixels) widget.scroll.jumpTo(next);
    });
  }

  // Resizing a column -------------------------------------------------------

  void _startResize(TableFrame frame, int column, double x) {
    HardwareKeyboard.instance.addHandler(_escape);
    setState(() {
      _resize = (
        table: frame.table,
        column: column,
        start: x,
        width: frame.columnEdges[column + 1] - frame.columnEdges[column],
      );
      _resizeDelta = 0;
    });
  }

  void _updateResize(double x) {
    final resize = _resize;
    if (resize == null) return;
    setState(() => _resizeDelta = x - resize.start);
  }

  void _endResize() {
    final resize = _resize;
    final delta = _resizeDelta;
    _endGesture();
    if (resize == null || delta == 0) return;
    final frame = _frame(resize.table);
    if (frame == null) return;
    widget.onResize(frame, resize.column, _resizedWidth(resize, delta));
  }

  static double _resizedWidth(_Resize resize, double delta) =>
      (resize.width + delta).clamp(48, double.infinity);

  /// Escape lets go of a drag or a resize, leaving the table as it was.
  bool _escape(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return false;
    }
    _endGesture();
    return true;
  }

  void _endGesture() {
    if (!mounted) return;
    // A grip let go of while the layer rebuilds without it ends its gesture
    // from inside the build, where only clearing it is allowed.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      _clearGesture();
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
      return;
    }
    setState(_clearGesture);
  }

  void _clearGesture() {
    HardwareKeyboard.instance.removeHandler(_escape);
    _autoScroll?.cancel();
    _autoScroll = null;
    _drag = null;
    _resize = null;
    _resizeDelta = 0;
  }

  @override
  Widget build(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    final origin = box != null && box.hasSize && box.attached
        ? box.localToGlobal(Offset.zero)
        : null;
    if (origin == null) _afterLayout();
    final children = origin == null
        ? const <Widget>[]
        : _controls(context, origin);
    return MouseRegion(
      opaque: false,
      hitTestBehavior: HitTestBehavior.translucent,
      onHover: widget.touch
          ? null
          : (event) => setState(() => _pointer = event.position),
      onExit: (_) => setState(() => _pointer = null),
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: widget.touch ? null : _secondaryClick,
        child: Stack(clipBehavior: Clip.none, children: children),
      ),
    );
  }

  void _secondaryClick(PointerDownEvent event) {
    if (event.buttons != kSecondaryButton) return;
    for (final frame in widget.frames()) {
      final row = frame.rowAt(event.position.dy);
      final column = frame.columnAt(event.position.dx);
      if (row == null || column == null) continue;
      widget.onMenu(
        frame,
        row: row,
        column: column,
        anchor: Rect.fromCenter(center: event.position, width: 0, height: 0),
      );
      return;
    }
  }

  static int? _gap(List<double> edges, double at) {
    for (var i = 1; i < edges.length - 1; i++) {
      if ((at - edges[i]).abs() <= TableControlsLayer.gapReach) return i;
    }
    return null;
  }

  bool _isPicked(TableFrame frame, TableAxis axis, int index) {
    final selected = widget.controller.selected;
    return selected != null &&
        selected.table == frame.table &&
        selected.axis == axis &&
        selected.index == index;
  }

  List<Widget> _controls(BuildContext context, Offset origin) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    final selected = widget.controller.selected;
    final drag = _drag;
    final resize = _resize;
    final pointer = _pointer;
    final children = <Widget>[];
    final handles = <Rect>[];
    widget.controller._handles = handles;
    Rect local(Rect rect) => rect.shift(-origin);
    Rect handle(Rect rect) {
      handles.add(rect);
      return rect.shift(-origin);
    }

    Widget rule(Rect rect) => Positioned.fromRect(
      rect: local(rect),
      child: IgnorePointer(child: ColoredBox(color: accent)),
    );

    Widget tint(TableFrame frame, TableAxis axis, int index) =>
        Positioned.fromRect(
          rect: local(frame.grid),
          child: IgnorePointer(
            child: CustomPaint(
              painter: _BandTint(
                band: frame.band(axis, index).shift(-frame.grid.topLeft),
                color: palette.selection,
              ),
            ),
          ),
        );

    Widget grip(TableFrame frame, TableAxis axis, int index, Rect rect) {
      final band = frame.band(axis, index);
      final movable = axis == TableAxis.column || index > 0;
      final row = axis == TableAxis.row;
      return Positioned.fromRect(
        key: ValueKey('table-${axis.name}-grip-$index'),
        rect: handle(rect),
        child: _Grip(
          axis: axis,
          selected: _isPicked(frame, axis, index) || drag?.from == index,
          touch: widget.touch,
          label: row
              ? (index == 0 ? 'Header row' : 'Row $index')
              : 'Column ${index + 1}',
          onTap: () => _pick(frame, axis, index, band),
          onDragStart: movable
              ? (at) => _startDrag(frame, axis, index, at)
              : null,
          onDragUpdate: _updateDrag,
          onDragEnd: _endDrag,
          onDragCancel: _endGesture,
        ),
      );
    }

    for (final frame in widget.frames()) {
      final grid = frame.grid;
      if (selected != null && selected.table == frame.table) {
        children.add(tint(frame, selected.axis, selected.index));
      }

      if (drag != null && drag.table == frame.table) {
        children.add(tint(frame, drag.axis, drag.from));
        final to = _dropIndex(frame, drag);
        if (to != drag.from) {
          final edges = drag.axis == TableAxis.row
              ? frame.rowEdges
              : frame.columnEdges;
          final at = to > drag.from ? edges[to + 1] : edges[to];
          children.add(
            rule(
              drag.axis == TableAxis.row
                  ? Rect.fromLTRB(grid.left, at - 1, grid.right, at + 1)
                  : Rect.fromLTRB(at - 1, grid.top, at + 1, grid.bottom),
            ),
          );
        }
        final band = frame.band(drag.axis, drag.from);
        children.add(
          grip(frame, drag.axis, drag.from, _gripRect(frame, drag.axis, band)),
        );
        continue;
      }

      if (resize != null && resize.table == frame.table) {
        final x =
            frame.columnEdges[resize.column] +
            _resizedWidth(resize, _resizeDelta);
        children
          ..add(rule(Rect.fromLTRB(x - 1, grid.top, x + 1, grid.bottom)))
          ..add(_resizeStrip(frame, resize.column + 1, handle));
        continue;
      }

      if (widget.touch) {
        final editing = widget.editing;
        if (editing == null || editing.table != frame.table) continue;
        children
          ..add(
            grip(
              frame,
              TableAxis.row,
              editing.row,
              _gripRect(
                frame,
                TableAxis.row,
                frame.band(TableAxis.row, editing.row),
              ),
            ),
          )
          ..add(
            grip(
              frame,
              TableAxis.column,
              editing.column,
              _gripRect(
                frame,
                TableAxis.column,
                frame.band(TableAxis.column, editing.column),
              ),
            ),
          );
        continue;
      }

      final hovered = pointer != null && grid.inflate(24).contains(pointer);
      final row = hovered ? frame.rowAt(pointer.dy) : null;
      final column = hovered ? frame.columnAt(pointer.dx) : null;
      final atLeft =
          hovered &&
          (pointer.dx - grid.left).abs() <= TableControlsLayer.gripReach;
      final atTop =
          hovered &&
          (pointer.dy - grid.top).abs() <= TableControlsLayer.gripReach;
      final rowGap = atLeft ? _gap(frame.rowEdges, pointer.dy) : null;
      final columnGap = atTop ? _gap(frame.columnEdges, pointer.dx) : null;
      int? border;
      if (hovered &&
          !atTop &&
          pointer.dy > grid.top &&
          pointer.dy < grid.bottom) {
        for (var i = 1; i < frame.columnEdges.length; i++) {
          if ((pointer.dx - frame.columnEdges[i]).abs() <= 4) border = i;
        }
      }

      for (var r = 0; r < frame.rows; r++) {
        if (!_isPicked(frame, TableAxis.row, r) &&
            (r != row || rowGap != null || border != null)) {
          continue;
        }
        children.add(
          grip(
            frame,
            TableAxis.row,
            r,
            _gripRect(frame, TableAxis.row, frame.band(TableAxis.row, r)),
          ),
        );
      }
      for (var c = 0; c < frame.columns; c++) {
        if (!_isPicked(frame, TableAxis.column, c) &&
            (c != column || columnGap != null || border != null)) {
          continue;
        }
        children.add(
          grip(
            frame,
            TableAxis.column,
            c,
            _gripRect(frame, TableAxis.column, frame.band(TableAxis.column, c)),
          ),
        );
      }

      if (!hovered) continue;

      if (rowGap != null) {
        final y = frame.rowEdges[rowGap];
        children
          ..add(rule(Rect.fromLTRB(grid.left, y - 1, grid.right, y + 1)))
          ..add(
            Positioned.fromRect(
              rect: handle(
                Rect.fromCenter(
                  center: Offset(grid.left, y),
                  width: 18,
                  height: 18,
                ),
              ),
              child: _Plus(
                key: ValueKey('table-row-gap-$rowGap'),
                label: 'Insert row here',
                onTap: () => widget.onInsert(frame, TableAxis.row, rowGap),
              ),
            ),
          );
      }
      if (columnGap != null) {
        final x = frame.columnEdges[columnGap];
        children
          ..add(rule(Rect.fromLTRB(x - 1, grid.top, x + 1, grid.bottom)))
          ..add(
            Positioned.fromRect(
              rect: handle(
                Rect.fromCenter(
                  center: Offset(x, grid.top),
                  width: 18,
                  height: 18,
                ),
              ),
              child: _Plus(
                key: ValueKey('table-column-gap-$columnGap'),
                label: 'Insert column here',
                onTap: () =>
                    widget.onInsert(frame, TableAxis.column, columnGap),
              ),
            ),
          );
      }
      if (border != null) {
        final x = frame.columnEdges[border];
        children.add(rule(Rect.fromLTRB(x - 1, grid.top, x + 1, grid.bottom)));
      }
      for (var i = 1; i < frame.columnEdges.length; i++) {
        children.add(_resizeStrip(frame, i, handle));
      }

      children
        ..add(
          Positioned.fromRect(
            rect: handle(
              Rect.fromLTRB(
                grid.left,
                grid.bottom + 4,
                grid.right,
                grid.bottom + 20,
              ),
            ),
            child: _EdgePlus(
              key: const ValueKey('table-add-row'),
              label: 'Add row',
              onTap: () => widget.onInsert(frame, TableAxis.row, frame.rows),
            ),
          ),
        )
        ..add(
          Positioned.fromRect(
            rect: handle(
              Rect.fromLTRB(
                grid.right + 4,
                grid.top,
                grid.right + 20,
                grid.bottom,
              ),
            ),
            child: _EdgePlus(
              key: const ValueKey('table-add-column'),
              label: 'Add column',
              onTap: () =>
                  widget.onInsert(frame, TableAxis.column, frame.columns),
            ),
          ),
        );
    }
    return children;
  }

  /// Where a grip sits: across the table's left edge for a row and its top
  /// edge for a column, or just outside them on a phone, clear of the open
  /// cell's field, which is drawn over everything in the note.
  Rect _gripRect(TableFrame frame, TableAxis axis, Rect band) {
    final grid = frame.grid;
    if (widget.touch) {
      return axis == TableAxis.row
          ? Rect.fromCenter(
              center: Offset(grid.left - _touchOutset, band.center.dy),
              width: 44,
              height: 44,
            )
          : Rect.fromCenter(
              center: Offset(band.center.dx, grid.top - _touchOutset),
              width: 44,
              height: 44,
            );
    }
    return axis == TableAxis.row
        ? Rect.fromCenter(
            center: Offset(grid.left, band.center.dy),
            width: 18,
            height: band.height,
          )
        : Rect.fromCenter(
            center: Offset(band.center.dx, grid.top),
            width: band.width,
            height: 18,
          );
  }

  static const double _touchOutset = 11;

  /// The border to the right of column [edge] - 1, which drags its width and
  /// fits it to its words again on a double click.
  Widget _resizeStrip(TableFrame frame, int edge, Rect Function(Rect) handle) {
    final grid = frame.grid;
    final x = frame.columnEdges[edge];
    return Positioned.fromRect(
      key: ValueKey('table-resize-${edge - 1}'),
      rect: handle(
        Rect.fromLTRB(
          x - 4,
          grid.top + TableControlsLayer.gripReach,
          x + 4,
          grid.bottom,
        ),
      ),
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (details) =>
              _startResize(frame, edge - 1, details.globalPosition.dx),
          onHorizontalDragUpdate: (details) =>
              _updateResize(details.globalPosition.dx),
          onHorizontalDragEnd: (_) => _endResize(),
          onHorizontalDragCancel: _endGesture,
          onDoubleTap: () => widget.onResize(frame, edge - 1, null),
        ),
      ),
    );
  }

  void _pick(TableFrame frame, TableAxis axis, int index, Rect band) {
    widget.controller.selected = (table: frame.table, axis: axis, index: index);
    widget.onMenu(
      frame,
      row: axis == TableAxis.row ? index : null,
      column: axis == TableAxis.column ? index : null,
      anchor: axis == TableAxis.row
          ? Rect.fromLTWH(band.left - 9, band.top, 18, band.height)
          : Rect.fromLTWH(band.left, band.top - 9, band.width, 18),
    );
  }
}

/// A row's or a column's handle: dots on a small chip sitting on the table's
/// edge, the way the rest of the app marks something that can be dragged.
///
/// A click picks the row or column and opens its menu; a drag moves it. On a
/// phone a tap does the same, and a press-and-hold starts the drag, so that a
/// scroll that happens to start on a grip still scrolls.
class _Grip extends StatefulWidget {
  const _Grip({
    required this.axis,
    required this.selected,
    required this.touch,
    required this.label,
    required this.onTap,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDragCancel,
  });

  final TableAxis axis;
  final bool selected;
  final bool touch;
  final String label;
  final VoidCallback onTap;
  final ValueChanged<Offset>? onDragStart;
  final ValueChanged<Offset> onDragUpdate;
  final VoidCallback onDragEnd;
  final VoidCallback onDragCancel;

  @override
  State<_Grip> createState() => _GripState();
}

class _GripState extends State<_Grip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    final row = widget.axis == TableAxis.row;
    final long = widget.touch ? 28.0 : 20.0;
    final short = widget.touch ? 14.0 : 12.0;
    final start = widget.onDragStart;
    final chip = Container(
      width: row ? short : long,
      height: row ? long : short,
      decoration: BoxDecoration(
        color: widget.selected
            ? palette.selectedBackground
            : _hovered
            ? palette.hover
            : palette.paperColor,
        border: Border.all(
          color: widget.selected
              ? palette.selectedBorder
              : palette.controlBorder,
        ),
        borderRadius: BorderRadius.circular(AppRadii.small),
      ),
      alignment: Alignment.center,
      child: RotatedBox(
        quarterTurns: row ? 0 : 1,
        child: KapyIcon(
          KapyIcons.dragRounded,
          size: widget.touch ? 14 : 12,
          color: widget.selected ? accent : palette.textTertiary,
        ),
      ),
    );
    return Semantics(
      container: true,
      button: true,
      label: widget.label,
      hint: start == null ? 'Shows actions' : 'Shows actions; drag to move',
      child: MouseRegion(
        cursor: start == null
            ? SystemMouseCursors.click
            : SystemMouseCursors.grab,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onPanStart: widget.touch || start == null
              ? null
              : (details) => start(details.globalPosition),
          onPanUpdate: widget.touch || start == null
              ? null
              : (details) => widget.onDragUpdate(details.globalPosition),
          onPanEnd: widget.touch || start == null
              ? null
              : (_) => widget.onDragEnd(),
          onPanCancel: widget.touch || start == null
              ? null
              : widget.onDragCancel,
          onLongPressStart: !widget.touch || start == null
              ? null
              : (details) {
                  HapticFeedback.selectionClick();
                  start(details.globalPosition);
                },
          onLongPressMoveUpdate: !widget.touch || start == null
              ? null
              : (details) => widget.onDragUpdate(details.globalPosition),
          onLongPressEnd: !widget.touch || start == null
              ? null
              : (_) => widget.onDragEnd(),
          onLongPressCancel: !widget.touch || start == null
              ? null
              : widget.onDragCancel,
          child: Center(child: chip),
        ),
      ),
    );
  }
}

/// The "+" where two rows or two columns meet.
class _Plus extends StatelessWidget {
  const _Plus({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    return Semantics(
      button: true,
      label: label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              color: palette.paperColor,
              shape: BoxShape.circle,
              border: Border.all(color: accent),
            ),
            alignment: Alignment.center,
            child: KapyIcon(KapyIcons.addRounded, size: 12, color: accent),
          ),
        ),
      ),
    );
  }
}

/// The "+" past the last row or the last column: only its glyph until the
/// pointer is on it.
class _EdgePlus extends StatefulWidget {
  const _EdgePlus({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  State<_EdgePlus> createState() => _EdgePlusState();
}

class _EdgePlusState extends State<_EdgePlus> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      button: true,
      label: widget.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            decoration: BoxDecoration(
              color: _hovered ? palette.hover : null,
              borderRadius: BorderRadius.circular(AppRadii.compact),
            ),
            alignment: Alignment.center,
            child: KapyIcon(
              KapyIcons.addRounded,
              size: 12,
              color: _hovered ? palette.textSecondary : palette.textTertiary,
            ),
          ),
        ),
      ),
    );
  }
}

/// The picked or dragged row or column, washed in the selection colour inside
/// the table's rounded edge.
class _BandTint extends CustomPainter {
  const _BandTint({required this.band, required this.color});

  final Rect band;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..save()
      ..clipRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(10)),
      )
      ..drawRect(band, Paint()..color = color)
      ..restore();
  }

  @override
  bool shouldRepaint(_BandTint old) => old.band != band || old.color != color;
}
