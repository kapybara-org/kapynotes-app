import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../../calc/engine.dart';
import '../../core/theme.dart';
import '../../core/toast.dart';
import 'line_metrics.dart';

/// The fixed column of live results a phone keeps beside its text, one chip
/// per calculated line. Everywhere else results sit at the ends of their
/// lines; see `InlineResults`.
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
      color: palette.gutterColor,
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
        clipper: const VerticalClipper(),
        clipBehavior: Clip.hardEdge,
        child: Stack(clipBehavior: Clip.none, children: chips),
      ),
    );
  }
}

/// Clips top and bottom only.
class VerticalClipper extends CustomClipper<Rect> {
  const VerticalClipper();

  @override
  Rect getClip(Size size) => Rect.fromLTRB(-4000, 0, size.width, size.height);

  @override
  bool shouldReclip(covariant CustomClipper<Rect> oldClipper) => false;
}

/// How a result is drawn.
enum ResultChipLook {
  /// A quiet annotation in the phone's results column.
  rail,

  /// A pill at the end of its line. A total's pill is the strongest.
  pill,
}

/// One result. Truncates to fit the room it is given, expands on hover to
/// reveal the full value, and copies full precision when clicked.
class ResultChip extends StatefulWidget {
  const ResultChip({
    super.key,
    required this.result,
    required this.collapsedWidth,
    this.look = ResultChipLook.rail,
  });

  final LineResult result;

  /// The widest the chip is until hovered.
  final double collapsedWidth;

  final ResultChipLook look;

  @override
  State<ResultChip> createState() => _ResultChipState();
}

class _ResultChipState extends State<ResultChip> {
  bool _hovering = false;
  bool _justCopied = false;

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
        icon: KapyIcons.errorOutlined,
        isError: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final pill = widget.look == ResultChipLook.pill;
    // The figure a list of amounts builds up to gets the strongest pill.
    final total = pill && widget.result.isTotal;
    final ink = total ? palette.totalPillText : palette.resultPillText;
    final background = total
        ? palette.totalPillBackground
        : palette.resultPillBackground;
    final Color fill;
    if (pill) {
      fill = KapyTheme.fillStates(
        background,
        ink: ink,
        disabled: background,
      ).resolve({if (_hovering) WidgetState.hovered});
    } else {
      // Results read like quiet annotations on the page. The pill only
      // appears under the pointer to make the copy target clear.
      fill = _hovering ? background : Colors.transparent;
    }

    final chip = AnimatedContainer(
      duration: const Duration(milliseconds: 130),
      curve: Curves.easeOutCubic,
      padding: pill
          ? const EdgeInsets.symmetric(horizontal: 10, vertical: 5)
          : const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(pill ? 999 : 5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_justCopied) ...[
            KapyIcon(
              KapyIcons.checkRounded,
              size: AppControlMetrics.iconInline,
              color: ink,
            ),
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
                fontFamily: AppFonts.mono,
                fontFamilyFallback: AppFonts.monoFallback,
                fontSize: AppTypeScale.result,
                fontWeight: !pill
                    ? null
                    : total
                    ? FontWeight.w600
                    : FontWeight.w500,
                height: pill ? 16 / 13 : 1.2,
                leadingDistribution: TextLeadingDistribution.even,
                color: ink,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );

    return MouseRegion(
      // A result copies itself when clicked, so it has to look clickable.
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: _copy,
        behavior: HitTestBehavior.opaque,
        child: Tooltip(
          message: widget.result.tooltipText,
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
