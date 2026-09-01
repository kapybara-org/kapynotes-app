import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../../calc/engine.dart';
import '../../calc/value.dart';
import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../core/toast.dart';
import 'line_metrics.dart';

/// The right-hand column of live results, one chip per calculated line.
class ResultsGutter extends StatelessWidget {
  const ResultsGutter({
    super.key,
    required this.results,
    required this.offsets,
    required this.scrollOffset,
    required this.viewportHeight,
    required this.padding,
    required this.width,
  });

  final Map<int, LineResult> results;
  final LineOffsets offsets;
  final double scrollOffset;
  final double viewportHeight;
  final EdgeInsets padding;
  final double width;

  static const double _leftInset = 8;
  static const double _rightInset = 16;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final visibleHeight = viewportHeight - padding.vertical;
    final columnWidth = width - _leftInset - _rightInset;

    final chips = <Widget>[];
    for (final entry in results.entries) {
      final index = entry.key;
      if (index >= offsets.tops.length) continue;

      final top = offsets.tops[index] - scrollOffset;
      // Only build what can be seen; a long note stays cheap to scroll.
      if (top + offsets.lineHeight < -offsets.lineHeight ||
          top > visibleHeight + offsets.lineHeight) {
        continue;
      }

      chips.add(
        Positioned(
          top: top,
          right: 0,
          // No left bound: a hovered chip grows leftward, over the text.
          height: offsets.lineHeight,
          child: Align(
            alignment: Alignment.centerRight,
            child: ResultChip(result: entry.value, collapsedWidth: columnWidth),
          ),
        ),
      );
    }

    return Container(
      color: palette.gutterBackground,
      padding: EdgeInsets.only(
        top: padding.top,
        bottom: padding.bottom,
        right: _rightInset,
        left: _leftInset,
      ),
      // Clip vertically so chips never spill into the fixed padding as the
      // note scrolls, but leave the left edge open so an expanded chip can
      // reach across the text.
      child: ClipRect(
        clipper: const _VerticalClipper(),
        clipBehavior: Clip.hardEdge,
        child: Stack(clipBehavior: Clip.none, children: chips),
      ),
    );
  }
}

/// Clips top and bottom only.
class _VerticalClipper extends CustomClipper<Rect> {
  const _VerticalClipper();

  @override
  Rect getClip(Size size) => Rect.fromLTRB(-4000, 0, size.width, size.height);

  @override
  bool shouldReclip(covariant CustomClipper<Rect> oldClipper) => false;
}

/// One result. Truncates to fit the column, expands on hover to reveal the
/// full value, and copies full precision when clicked.
class ResultChip extends StatefulWidget {
  const ResultChip({
    super.key,
    required this.result,
    required this.collapsedWidth,
  });

  final LineResult result;

  /// Width of the results column. A chip is truncated to this until hovered.
  final double collapsedWidth;

  @override
  State<ResultChip> createState() => _ResultChipState();
}

class _ResultChipState extends State<ResultChip> {
  bool _hovering = false;
  bool _justCopied = false;

  Color _colorFor(CalcPalette palette) {
    switch (widget.result.kind) {
      case ResultKind.currency:
        return palette.chipCurrency;
      case ResultKind.unit:
        return palette.chipUnit;
      case ResultKind.number:
        return palette.chipNumber;
      case ResultKind.boolean:
        return palette.chipBoolean;
      case ResultKind.other:
        return palette.chipOther;
    }
  }

  /// Copies the full-precision value, not the truncated chip text.
  Future<void> _copy() async {
    final value = widget.result.copyText;
    try {
      await Clipboard.setData(ClipboardData(text: value));
      if (!mounted) return;
      setState(() => _justCopied = true);
      Toast.show(context, 'Copied $value');
      Future.delayed(const Duration(milliseconds: 900), () {
        if (mounted) setState(() => _justCopied = false);
      });
    } catch (_) {
      if (!mounted) return;
      Toast.show(
        context,
        "Couldn't copy to clipboard",
        icon: Icons.error_outline_rounded,
        isError: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final color = _colorFor(palette);

    final chip = AnimatedContainer(
      duration: const Duration(milliseconds: 130),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: _hovering
            ? palette.controlBackground
            : color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_justCopied) ...[
            Icon(Icons.check_rounded, size: 12, color: color),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              widget.result.text,
              maxLines: 1,
              softWrap: false,
              // Long results clip from the left so the significant digits and
              // the unit — the parts you actually read — stay visible.
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontFamily: AppPlatform.monoFontFallback.first,
                fontFamilyFallback: AppPlatform.monoFontFallback,
                fontSize: 12.5,
                height: 1.2,
                color: color,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );

    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: _copy,
        behavior: HitTestBehavior.opaque,
        child: Tooltip(
          message: 'Copy result',
          child: ConstrainedBox(
            // Hovering lets a truncated result grow leftward over the text.
            constraints: BoxConstraints(
              maxWidth: _hovering
                  ? widget.collapsedWidth + 340
                  : widget.collapsedWidth,
            ),
            child: chip,
          ),
        ),
      ),
    );
  }
}

/// The draggable edge between the text and its results.
class GutterDivider extends StatefulWidget {
  const GutterDivider({super.key, required this.onDrag, required this.onReset});

  final void Function(double delta) onDrag;
  final VoidCallback onReset;

  static const double width = 11;

  @override
  State<GutterDivider> createState() => _GutterDividerState();
}

class _GutterDividerState extends State<GutterDivider> {
  bool _active = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Semantics(
      label: 'Resize results column',
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        onEnter: (_) => setState(() => _active = true),
        onExit: (_) => setState(() => _active = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (details) => widget.onDrag(details.delta.dx),
          onDoubleTap: widget.onReset,
          child: SizedBox(
            width: GutterDivider.width,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: _active ? 1.5 : 0.5,
                decoration: BoxDecoration(
                  color: _active
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
