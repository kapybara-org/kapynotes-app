import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';

/// The small panel that a click on a link raises, offering to open it.
///
/// Links live in editable text, so a click on one has to keep doing what a
/// click on text does: place the caret. That leaves nowhere to put "open
/// this", which is why opening was a modifier away and undiscoverable. The
/// panel is the answer — the caret still lands where it was clicked, and the
/// two things you might want to do with the address are offered next to it.
///
/// It goes in the root overlay rather than in the editor's own stack. The
/// text pane clips its children, and a link on the first line would have its
/// panel sliced off at the top edge.
class LinkPopover {
  const LinkPopover._();

  static OverlayEntry? _current;

  static bool get isVisible => _current != null;

  /// Anchors a panel to [anchor], in global coordinates — the rect of the
  /// clicked line of the link rather than the whole link, so a URL that wraps
  /// across two lines is pointed at where it was actually clicked.
  static void show(
    BuildContext context, {
    required Rect anchor,
    required String label,
    required VoidCallback onOpen,
    required VoidCallback onCopy,
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    hide();
    final entry = OverlayEntry(
      builder: (context) => _LinkPopoverBody(
        anchor: anchor,
        label: label,
        onOpen: () {
          hide();
          onOpen();
        },
        onCopy: () {
          hide();
          onCopy();
        },
        onDismiss: hide,
      ),
    );
    _current = entry;
    overlay.insert(entry);
  }

  static void hide() {
    _current?.remove();
    _current = null;
  }
}

class _LinkPopoverBody extends StatefulWidget {
  const _LinkPopoverBody({
    required this.anchor,
    required this.label,
    required this.onOpen,
    required this.onCopy,
    required this.onDismiss,
  });

  final Rect anchor;
  final String label;
  final VoidCallback onOpen;
  final VoidCallback onCopy;
  final VoidCallback onDismiss;

  @override
  State<_LinkPopoverBody> createState() => _LinkPopoverBodyState();
}

class _LinkPopoverBodyState extends State<_LinkPopoverBody>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 120),
  )..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final curve = CurvedAnimation(parent: _controller, curve: Curves.easeOut);

    return Stack(
      children: [
        // Translucent, so the press that dismisses the panel still reaches
        // whatever it landed on. Clicking somewhere else in the note puts the
        // caret there in the one click it would have taken anyway.
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => widget.onDismiss(),
          ),
        ),
        Positioned.fill(
          child: CustomSingleChildLayout(
            delegate: _AnchoredAbove(
              anchor: widget.anchor,
              safeArea: MediaQuery.of(context).padding,
            ),
            child: FadeTransition(
              opacity: curve,
              child: ScaleTransition(
                scale: Tween(begin: 0.96, end: 1.0).animate(curve),
                alignment: Alignment.bottomCenter,
                child: Container(
                  key: const ValueKey('link-popover'),
                  padding: const EdgeInsets.fromLTRB(11, 5, 5, 5),
                  decoration: BoxDecoration(
                    color: palette.surfaceBackground,
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(
                      color: palette.controlBorder,
                      width: 0.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(
                          alpha: dark ? 0.22 : 0.09,
                        ),
                        blurRadius: 14,
                        offset: const Offset(0, 5),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          widget.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppTypeScale.small,
                            color: palette.textSecondary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      TextButton(
                        key: const ValueKey('link-popover-open'),
                        onPressed: widget.onOpen,
                        style: TextButton.styleFrom(
                          minimumSize: Size(
                            0,
                            AppControlMetrics.popoverActionExtent,
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          backgroundColor: palette.selectedBackground,
                          foregroundColor: palette.textPrimary,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                        child: Text(
                          'Open link',
                          style: TextStyle(
                            fontSize: AppTypeScale.caption,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      const SizedBox(width: 2),
                      IconButton(
                        key: const ValueKey('link-popover-copy'),
                        onPressed: widget.onCopy,
                        icon: Icon(
                          Icons.content_copy_rounded,
                          size: AppControlMetrics.iconAdornment,
                        ),
                        color: palette.textTertiary,
                        tooltip: 'Copy link',
                        visualDensity: VisualDensity.compact,
                        constraints: BoxConstraints.tightFor(
                          width: AppControlMetrics.popoverActionExtent,
                          height: AppControlMetrics.popoverActionExtent,
                        ),
                        padding: EdgeInsets.zero,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Sits the panel just above the clicked line, centred on it, and falls below
/// when there is no room — the same choice a selection toolbar makes, for the
/// same reason: the text being acted on has to stay visible.
class _AnchoredAbove extends SingleChildLayoutDelegate {
  const _AnchoredAbove({required this.anchor, required this.safeArea});

  final Rect anchor;
  final EdgeInsets safeArea;

  static const double _margin = 8;
  static const double _gap = 6;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(
        Size(
          math.max(0, constraints.maxWidth - _margin * 2),
          constraints.maxHeight,
        ),
      ).copyWith(maxWidth: math.min(360, constraints.maxWidth - _margin * 2));

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final left = _clamp(
      anchor.center.dx - childSize.width / 2,
      _margin,
      size.width - childSize.width - _margin,
    );
    final above = anchor.top - _gap - childSize.height;
    final top = above >= safeArea.top + _margin
        ? above
        : _clamp(
            anchor.bottom + _gap,
            safeArea.top + _margin,
            size.height - safeArea.bottom - childSize.height - _margin,
          );
    return Offset(left, top);
  }

  /// [num.clamp] asserts when the range inverts, which is exactly what a
  /// panel wider or taller than the window produces. Pinning to the low edge
  /// is the better answer there.
  static double _clamp(double value, double low, double high) =>
      high <= low ? low : math.min(math.max(value, low), high);

  @override
  bool shouldRelayout(_AnchoredAbove oldDelegate) =>
      oldDelegate.anchor != anchor || oldDelegate.safeArea != safeArea;
}
