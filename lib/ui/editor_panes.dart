import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../data/editor_workspace.dart';

/// A note on its way to a pane: out of the notes list, or by a pane's title.
@immutable
class NoteDragData {
  const NoteDragData({required this.noteId, required this.title});

  final String noteId;
  final String title;
}

/// Lets [child] be dragged towards the panes, carrying [data].
///
/// Only ever built where there is a mouse. The primary button alone starts a
/// drag, so a right click still opens a row's menu, and on touch a drag is
/// what scrolls the list.
class NoteDraggable extends StatelessWidget {
  const NoteDraggable({super.key, required this.data, required this.child});

  final NoteDragData data;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Draggable<NoteDragData>(
      data: data,
      // The drop targets read the pointer, not the card, so the card is set
      // off from it below rather than moved by the anchor.
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: NoteDragFeedback(title: data.title),
      childWhenDragging: Opacity(opacity: 0.45, child: child),
      child: child,
    );
  }
}

/// The card that follows the pointer while a note is dragged.
///
/// Below and to the right of the pointer, so neither the pointer nor the
/// highlight under it is covered by the thing being moved.
class NoteDragFeedback extends StatelessWidget {
  const NoteDragFeedback({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Transform.translate(
      offset: const Offset(14, 10),
      child: Material(
        color: palette.surfaceBackground,
        elevation: 6,
        shadowColor: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              KapyIcon(
                KapyIcons.descriptionOutlined,
                size: AppControlMetrics.iconControl,
                color: palette.textSecondary,
              ),
              const SizedBox(width: 7),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppTypeScale.control,
                    fontWeight: FontWeight.w400,
                    color: palette.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One pane: a title bar while the row is split, the note or the empty pane
/// below it, and the highlight that shows where a dragged note would land.
class EditorPaneFrame extends StatefulWidget {
  const EditorPaneFrame({
    super.key,
    required this.index,
    required this.paneCount,
    required this.active,
    required this.onActivate,
    required this.planDrop,
    required this.onDrop,
    required this.child,
    this.title,
    this.shared = false,
    this.dragData,
    this.onTitlePressed,
    this.onClose,
    this.closeShortcut,
  });

  final int index;
  final int paneCount;
  final bool active;

  /// Focuses this pane, on any press inside it and before that press does
  /// anything else, so a click in a pane always acts on that pane.
  final VoidCallback onActivate;

  /// What dropping a note on part of this pane would do. Null refuses it.
  final PaneDropPlan? Function(NoteDragData data, PaneDropZone zone) planDrop;
  final void Function(NoteDragData data, PaneDropZone zone) onDrop;
  final Widget child;

  /// The note's title for the title bar. Null in an empty pane.
  final String? title;
  final bool shared;

  /// What dragging the title bar carries. Null in an empty pane, which has
  /// nothing to move.
  final NoteDragData? dragData;
  final VoidCallback? onTitlePressed;

  /// Null leaves the title bar out. A lone pane is the whole editor and looks
  /// exactly as the editor always has; the bar only earns its height once
  /// there is more than one note to tell apart.
  final VoidCallback? onClose;
  final String? closeShortcut;

  static const double headerHeight = 30;

  /// Which zone of a pane [width] wide the horizontal position [dx] is in.
  ///
  /// The outer part of each side means "beside this note", the middle means
  /// "in its place". Capped, so on a wide pane the middle stays the larger
  /// target rather than a sliver between two vast edges.
  static PaneDropZone zoneAt(double dx, double width) {
    final edge = math.min(width * 0.3, 180.0);
    if (dx < edge) return PaneDropZone.left;
    if (dx > width - edge) return PaneDropZone.right;
    return PaneDropZone.center;
  }

  /// What the highlight says, so a drop is never a guess.
  static String describe(PaneDropPlan plan) => switch (plan.action) {
    PaneDropAction.replace => 'Open here',
    PaneDropAction.swap => 'Swap places',
    PaneDropAction.insert =>
      plan.zone == PaneDropZone.left ? 'Open on the left' : 'Open on the right',
    PaneDropAction.move => switch (plan.zone) {
      PaneDropZone.left => 'Move to the left',
      PaneDropZone.right => 'Move to the right',
      PaneDropZone.center => 'Move here',
    },
  };

  @override
  State<EditorPaneFrame> createState() => _EditorPaneFrameState();
}

class _EditorPaneFrameState extends State<EditorPaneFrame> {
  /// What a drop right now would do, while a note is over this pane.
  PaneDropPlan? _plan;

  /// The last plan shown, kept while its highlight fades out.
  PaneDropPlan? _shown;

  PaneDropZone? _zoneAt(Offset globalPosition) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    final local = box.globalToLocal(globalPosition);
    return EditorPaneFrame.zoneAt(local.dx, box.size.width);
  }

  void _hover(DragTargetDetails<NoteDragData> details) {
    // With the pointer as the drag anchor, the offset is the pointer.
    final zone = _zoneAt(details.offset);
    final plan = zone == null ? null : widget.planDrop(details.data, zone);
    if (plan == _plan) return;
    setState(() {
      _plan = plan;
      if (plan != null) _shown = plan;
    });
  }

  void _leave() {
    if (_plan != null) setState(() => _plan = null);
  }

  void _accept(DragTargetDetails<NoteDragData> details) {
    final zone = _zoneAt(details.offset);
    // Straight away rather than faded: the panes are about to change under
    // the highlight, and a label left over would describe the old ones.
    setState(() {
      _plan = null;
      _shown = null;
    });
    if (zone != null) widget.onDrop(details.data, zone);
  }

  @override
  Widget build(BuildContext context) {
    final onClose = widget.onClose;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => widget.onActivate(),
      child: DragTarget<NoteDragData>(
        // Every note is welcome over every pane; whether a drop does anything
        // depends on where in the pane it is, which only a move can say.
        onWillAcceptWithDetails: (_) => true,
        onMove: _hover,
        onLeave: (_) => _leave(),
        onAcceptWithDetails: _accept,
        builder: (context, _, _) => Stack(
          children: [
            Positioned.fill(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (onClose != null)
                    _PaneHeader(
                      index: widget.index,
                      paneCount: widget.paneCount,
                      title: widget.title,
                      shared: widget.shared,
                      active: widget.active,
                      dragData: widget.dragData,
                      onPressed: widget.onTitlePressed,
                      onClose: onClose,
                      closeShortcut: widget.closeShortcut,
                    ),
                  Expanded(child: widget.child),
                ],
              ),
            ),
            if (_shown case final shown?)
              Positioned.fill(
                child: IgnorePointer(child: _dropHighlight(context, shown)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _dropHighlight(BuildContext context, PaneDropPlan plan) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final half = constraints.maxWidth / 2;
        final (left, right) = switch (plan.zone) {
          PaneDropZone.left => (0.0, half),
          PaneDropZone.right => (half, 0.0),
          PaneDropZone.center => (0.0, 0.0),
        };
        return AnimatedOpacity(
          opacity: _plan == null ? 0 : 1,
          duration: const Duration(milliseconds: 120),
          onEnd: () {
            if (mounted && _plan == null && _shown != null) {
              setState(() => _shown = null);
            }
          },
          child: Stack(
            children: [
              AnimatedPositioned(
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOutCubic,
                left: left + 6,
                right: right + 6,
                top: 6,
                bottom: 6,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.10),
                    border: Border.all(
                      color: scheme.primary.withValues(alpha: 0.55),
                      width: 1.5,
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 11,
                            vertical: 5,
                          ),
                          child: Text(
                            EditorPaneFrame.describe(plan),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: AppTypeScale.small,
                              fontWeight: FontWeight.w400,
                              color: scheme.onPrimary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A split pane's title bar: which note it is, a handle to move it by, and
/// the way to close it.
class _PaneHeader extends StatefulWidget {
  const _PaneHeader({
    required this.index,
    required this.paneCount,
    required this.title,
    required this.shared,
    required this.active,
    required this.dragData,
    required this.onPressed,
    required this.onClose,
    required this.closeShortcut,
  });

  final int index;
  final int paneCount;
  final String? title;
  final bool shared;
  final bool active;
  final NoteDragData? dragData;
  final VoidCallback? onPressed;
  final VoidCallback onClose;
  final String? closeShortcut;

  @override
  State<_PaneHeader> createState() => _PaneHeaderState();
}

class _PaneHeaderState extends State<_PaneHeader> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    final title = widget.title;
    final dragData = widget.dragData;

    final bar = MouseRegion(
      cursor: dragData == null ? MouseCursor.defer : SystemMouseCursors.grab,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        key: ValueKey('pane-title-${widget.index}'),
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        child: Container(
          height: EditorPaneFrame.headerHeight,
          decoration: BoxDecoration(
            color: palette.paperColor,
            border: Border(
              bottom: BorderSide(color: palette.separator, width: 0.5),
            ),
          ),
          child: Stack(
            children: [
              // The focused pane is marked the way a selected tab is in most
              // editors: a rule of accent along its top edge.
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: 2,
                child: AnimatedOpacity(
                  opacity: widget.active ? 1 : 0,
                  duration: const Duration(milliseconds: 120),
                  child: ColoredBox(color: accent),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 6, right: 4),
                child: Row(
                  children: [
                    // Held open while hidden, so the title does not shift
                    // sideways every time the pointer crosses the bar.
                    SizedBox(
                      width: 14,
                      child: AnimatedOpacity(
                        opacity: dragData != null && _hovering ? 1 : 0,
                        duration: const Duration(milliseconds: 100),
                        child: KapyIcon(
                          KapyIcons.dragRounded,
                          size: 14,
                          color: palette.textTertiary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    if (widget.shared) ...[
                      KapyIcon(
                        KapyIcons.peopleOutlined,
                        size: 13,
                        color: palette.textTertiary,
                      ),
                      const SizedBox(width: 5),
                    ],
                    Expanded(
                      child: Text(
                        title ?? 'Empty pane',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppTypeScale.small,
                          height: 1,
                          fontWeight: widget.active
                              ? FontWeight.w400
                              : FontWeight.w400,
                          fontStyle: title == null ? FontStyle.italic : null,
                          color: widget.active
                              ? palette.textPrimary
                              : palette.textSecondary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Tooltip(
                      // The chord closes the focused pane, so only the focused
                      // pane's button can promise it.
                      message: [
                        'Close pane',
                        if (widget.active) ?widget.closeShortcut,
                      ].join('  '),
                      child: InkResponse(
                        key: ValueKey('close-pane-${widget.index}'),
                        onTap: widget.onClose,
                        radius: 12,
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: KapyIcon(
                            KapyIcons.closeRounded,
                            size: 14,
                            color: _hovering || widget.active
                                ? palette.textSecondary
                                : palette.textTertiary,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return Semantics(
      container: true,
      selected: widget.active,
      label: title == null
          ? 'Empty pane ${widget.index + 1} of ${widget.paneCount}'
          : '$title, pane ${widget.index + 1} of ${widget.paneCount}',
      child: dragData == null ? bar : NoteDraggable(data: dragData, child: bar),
    );
  }
}

/// What a pane shows before it has been given a note.
class EmptyPane extends StatefulWidget {
  const EmptyPane({
    super.key,
    required this.active,
    required this.onCreate,
    this.onShowNotes,
  });

  final bool active;
  final VoidCallback onCreate;

  /// Opens the notes list. Null while the list is already on screen.
  final VoidCallback? onShowNotes;

  @override
  State<EmptyPane> createState() => _EmptyPaneState();
}

class _EmptyPaneState extends State<EmptyPane> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'empty-pane');

  @override
  void initState() {
    super.initState();
    if (widget.active) _takeKeyboard();
  }

  @override
  void didUpdateWidget(EmptyPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _takeKeyboard();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  /// Takes the keyboard from the editor this pane was split off from, so
  /// typing cannot land in a note that is no longer the focused one — while
  /// the window's shortcuts, which sit above every pane, keep answering.
  void _takeKeyboard() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active) _focusNode.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final onShowNotes = widget.onShowNotes;
    return Focus(
      focusNode: _focusNode,
      child: ColoredBox(
        color: palette.paperColor,
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SplitViewIcon(size: 30, color: palette.textTertiary),
                const SizedBox(height: 12),
                Text(
                  'Choose a note',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: AppTypeScale.title,
                    fontWeight: FontWeight.w400,
                    color: palette.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  // Broken by hand, so a narrow pane shows two even halves
                  // rather than a word left alone on the second line.
                  onShowNotes == null
                      ? 'Pick one from the list,\nor drag one here.'
                      : 'Open the list to pick one,\nor drag one here.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: AppTypeScale.body,
                    height: 1.45,
                    color: palette.textSecondary,
                  ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    if (onShowNotes != null)
                      TextButton.icon(
                        onPressed: onShowNotes,
                        icon: KapyIcon(
                          KapyIcons.menuRounded,
                          size: AppControlMetrics.iconControl,
                        ),
                        label: const Text('Show notes'),
                      ),
                    TextButton.icon(
                      key: const ValueKey('empty-pane-new-note'),
                      onPressed: widget.onCreate,
                      icon: KapyIcon(
                        KapyIcons.addRounded,
                        size: AppControlMetrics.iconControl,
                      ),
                      label: const Text('New note here'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Panes side by side. The divider between each pair drags to resize the two
/// of them and double-clicks to give every pane the same width.
class PaneSplitView extends StatefulWidget {
  const PaneSplitView({
    super.key,
    required this.children,
    required this.weights,
    required this.onWeightsChanged,
    required this.onEqualize,
  });

  /// One per pane, left to right, each keyed to its pane so it keeps its
  /// state when the panes are reordered.
  final List<Widget> children;
  final List<double> weights;
  final ValueChanged<List<double>> onWeightsChanged;
  final VoidCallback onEqualize;

  /// No pane is squeezed narrower than this while the row has room for all
  /// of them at this width. Below that, they share what there is.
  static const double preferredMinimumPaneWidth = 220;

  /// Lays [weights] out across [total] pixels, lifting any pane squeezed
  /// below the minimum and taking the difference from the panes that can
  /// spare it.
  static List<double> widthsFor(List<double> weights, double total) {
    if (weights.isEmpty) return const [];
    if (!total.isFinite || total <= 0) return [for (final _ in weights) 0];
    final floor = math.min(preferredMinimumPaneWidth, total / weights.length);
    final widths = [
      for (final weight in weights) math.max(0.0, weight * total),
    ];
    final deficit = widths.fold(
      0.0,
      (sum, width) => sum + math.max(0.0, floor - width),
    );
    if (deficit <= 0) return widths;
    final spare = widths.fold(
      0.0,
      (sum, width) => sum + math.max(0.0, width - floor),
    );
    if (spare <= 0) return [for (final _ in weights) total / weights.length];
    return [
      for (final width in widths)
        width <= floor ? floor : width - (width - floor) / spare * deficit,
    ];
  }

  @override
  State<PaneSplitView> createState() => _PaneSplitViewState();
}

class _PaneSplitViewState extends State<PaneSplitView> {
  /// Wide enough to catch, thin enough to leave both panes' edges clickable.
  static const double _handleWidth = 9;

  List<double> _widths = const [];
  int? _hovered;
  int? _dragging;

  void _drag(int divider, double dx) {
    final widths = List<double>.of(_widths);
    if (divider + 1 >= widths.length) return;
    final total = widths.fold(0.0, (sum, width) => sum + width);
    if (total <= 0) return;
    final pair = widths[divider] + widths[divider + 1];
    final floor = math.min(
      PaneSplitView.preferredMinimumPaneWidth,
      math.min(total / widths.length, pair / 2),
    );
    final left = (widths[divider] + dx).clamp(floor, pair - floor);
    widths[divider] = left;
    widths[divider + 1] = pair - left;
    _widths = widths;
    widget.onWeightsChanged([for (final width in widths) width / total]);
  }

  @override
  Widget build(BuildContext context) {
    final children = widget.children;
    return LayoutBuilder(
      builder: (context, constraints) {
        final total = constraints.maxWidth;
        final widths = _widths = PaneSplitView.widthsFor(
          widget.weights.length == children.length
              ? widget.weights
              : [for (final _ in children) 1 / children.length],
          total,
        );
        final boundaries = <double>[];
        var edge = 0.0;
        for (var index = 0; index < widths.length - 1; index++) {
          edge += widths[index];
          boundaries.add(edge);
        }

        return Stack(
          children: [
            Positioned.fill(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var index = 0; index < children.length; index++)
                    SizedBox(
                      key: children[index].key,
                      // The last pane takes whatever rounding left over, so
                      // the row always meets the window's edge exactly.
                      width: index == children.length - 1
                          ? math.max(0.0, total - edge)
                          : widths[index],
                      child: children[index],
                    ),
                ],
              ),
            ),
            for (var index = 0; index < boundaries.length; index++)
              Positioned(
                left: boundaries[index] - _handleWidth / 2,
                top: 0,
                bottom: 0,
                width: _handleWidth,
                child: _divider(context, index),
              ),
          ],
        );
      },
    );
  }

  Widget _divider(BuildContext context, int index) {
    final palette = context.palette;
    final lit = _hovered == index || _dragging == index;
    return Semantics(
      label: 'Resize panes',
      hint: 'Drag to resize. Double click to make every pane the same width.',
      child: Tooltip(
        message: 'Drag to resize. Double click for equal widths.',
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeLeftRight,
          onEnter: (_) => setState(() => _hovered = index),
          onExit: (_) => setState(() {
            if (_hovered == index) _hovered = null;
          }),
          child: GestureDetector(
            key: ValueKey('editor-split-divider-$index'),
            behavior: HitTestBehavior.opaque,
            onDoubleTap: widget.onEqualize,
            onHorizontalDragStart: (_) => setState(() => _dragging = index),
            onHorizontalDragUpdate: (details) => _drag(index, details.delta.dx),
            onHorizontalDragEnd: (_) => setState(() => _dragging = null),
            onHorizontalDragCancel: () => setState(() => _dragging = null),
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: lit ? 1.5 : 0.5,
                decoration: BoxDecoration(
                  color: lit
                      ? Theme.of(context).colorScheme.primary
                      : palette.separator,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A frame split down the middle: the split-view glyph.
///
/// Drawn rather than taken from the icon font, whose nearest glyphs are a
/// phone's split screen and a table of columns, neither of which reads as
/// "put another note beside this one" at toolbar size.
class SplitViewIcon extends StatelessWidget {
  const SplitViewIcon({super.key, this.size, this.color});

  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final extent = size ?? iconTheme.size ?? 24;
    return SizedBox.square(
      dimension: extent,
      child: CustomPaint(
        painter: _SplitViewIconPainter(
          color ?? iconTheme.color ?? context.palette.textSecondary,
        ),
      ),
    );
  }
}

class _SplitViewIconPainter extends CustomPainter {
  const _SplitViewIconPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // Proportions of a 24pt Material glyph, so the stroke sits beside the
    // font's own icons without looking heavier or lighter than them.
    final unit = size.width / 24;
    final stroke = 1.8 * unit;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    final frame = Rect.fromLTRB(3 * unit, 4.5 * unit, 21 * unit, 19.5 * unit);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        frame.deflate(stroke / 2),
        Radius.circular(2.5 * unit),
      ),
      paint,
    );
    canvas.drawLine(
      Offset(frame.center.dx, frame.top + stroke / 2),
      Offset(frame.center.dx, frame.bottom - stroke / 2),
      paint,
    );
  }

  @override
  bool shouldRepaint(_SplitViewIconPainter oldDelegate) =>
      oldDelegate.color != color;
}
