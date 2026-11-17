import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../../calc/engine.dart';
import '../../core/theme.dart';
import '../../core/toast.dart';

/// The column a phone keeps beside its text for live results. Each result
/// is part of its own line, which reaches across this column and puts the
/// result at its right, [rightInset] in; everywhere else results sit at the
/// ends of their lines.
class ResultsGutter extends StatelessWidget {
  const ResultsGutter({super.key});

  /// The room a result keeps from the column's left and right edges.
  static const double leftInset = 8;
  static const double rightInset = 16;

  @override
  Widget build(BuildContext context) =>
      ColoredBox(color: context.palette.gutterColor);
}

/// The faint rule a line runs from where its writing stops to its result:
/// square dots a dot apart, across the middle of the row.
class ResultLeader extends StatelessWidget {
  const ResultLeader({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) =>
      IgnorePointer(child: CustomPaint(painter: _LeaderPainter(color)));
}

class _LeaderPainter extends CustomPainter {
  const _LeaderPainter(this.color);

  final Color color;

  static const double _dot = 1;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final top = (size.height - _dot) / 2;
    for (var x = 0.0; x + _dot <= size.width; x += _dot * 2) {
      canvas.drawRect(Rect.fromLTWH(x, top, _dot, _dot), paint);
    }
  }

  @override
  bool shouldRepaint(_LeaderPainter oldDelegate) => oldDelegate.color != color;
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
