import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../../calc/engine.dart';
import '../../core/theme.dart';
import '../../core/toast.dart';

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

/// Where a result's pill sits. Either way a total's pill is the strongest.
enum ResultChipLook {
  /// At the right of a phone's line, which its writing wraps short of. A
  /// long result wraps inside its pill, and its line grows to hold it.
  rail,

  /// At the end of its line, on one row.
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

  /// How wide a [ResultChipLook.rail] chip shows [result] whole in
  /// [context], for a line to keep that much room for it. Measured once per
  /// result text, weight and text size: every layout asks again for each
  /// line in view, and a result rarely changes as the writing around it does.
  static double widthOf(BuildContext context, LineResult result) {
    final scaler = MediaQuery.textScalerOf(context);
    final key = (
      result.text,
      result.isTotal,
      scaler.scale(AppTypeScale.result),
    );
    if (_railWidths[key] case final width?) return width;
    final painter = TextPainter(
      text: TextSpan(
        text: result.text,
        style: DefaultTextStyle.of(
          context,
        ).style.merge(_textStyle(total: result.isTotal)),
      ),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    if (_railWidths.length >= 512) _railWidths.clear();
    return _railWidths[key] = math.max(
      _railTarget,
      width.ceilToDouble() + _railPadding.horizontal,
    );
  }

  static final _railWidths = <(String, bool, double), double>{};

  /// How tall a [ResultChipLook.rail] chip's words are in [context] when they
  /// wrap at [width], for a line to be at least that tall.
  static double heightOf(
    BuildContext context,
    LineResult result,
    double width,
  ) {
    final scaler = MediaQuery.textScalerOf(context);
    final key = (
      result.text,
      result.isTotal,
      scaler.scale(AppTypeScale.result),
      width,
    );
    if (_railHeights[key] case final height?) return height;
    final painter = TextPainter(
      text: TextSpan(
        text: result.text,
        style: DefaultTextStyle.of(
          context,
        ).style.merge(_textStyle(total: result.isTotal)),
      ),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout(maxWidth: math.max(0.0, width - _railPadding.horizontal));
    final height = painter.height;
    painter.dispose();
    if (_railHeights.length >= 512) _railHeights.clear();
    return _railHeights[key] = height.ceilToDouble() + _railPadding.vertical;
  }

  static final _railHeights = <(String, bool, double, double), double>{};

  /// The desktop pill's padding, two steps shorter so the pill sits inside a
  /// phone's row at its larger result size with a gap to the next one.
  static const _railPadding = EdgeInsets.symmetric(horizontal: 10, vertical: 3);

  /// Round ends on a pill of one row. A pill a long result wraps in keeps
  /// those corners rather than turning into a lozenge that cuts its words.
  static double _railRadius(TextScaler scaler) =>
      (scaler.scale(AppTypeScale.result) * _pillHeight +
          _railPadding.vertical) /
      2;

  static const double _pillHeight = 16 / 13;

  /// The least a finger gets to tap on the rail. Only the part inside its
  /// line takes a tap, so the lines above and below keep theirs.
  static const double _railTarget = 44;

  static TextStyle _textStyle({bool total = false, Color? color}) {
    final step = total ? AppWeight.section : AppWeight.button;
    return TextStyle(
      fontFamily: AppFonts.mono,
      fontFamilyFallback: AppFonts.monoFallback,
      fontSize: AppTypeScale.result,
      fontWeight: AppWeight.font(step),
      fontVariations: AppWeight.wght(step),
      height: _pillHeight,
      leadingDistribution: TextLeadingDistribution.even,
      color: color,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
  }

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
    final total = widget.result.isTotal;
    final ink = total ? palette.totalPillText : palette.resultPillText;
    final background = total
        ? palette.totalPillBackground
        : palette.resultPillBackground;
    final fill = KapyTheme.fillStates(
      background,
      ink: ink,
      disabled: background,
    ).resolve({if (_hovering) WidgetState.hovered});
    final radius = pill
        ? 999.0
        : ResultChip._railRadius(MediaQuery.textScalerOf(context));

    final words = Text(
      widget.result.text,
      // A phone's result wraps, and its line grows to hold it. A pill keeps to
      // one line and ends with an ellipsis, and grows under the pointer.
      maxLines: pill ? 1 : null,
      softWrap: !pill,
      overflow: pill ? TextOverflow.ellipsis : null,
      textAlign: TextAlign.right,
      // A wrapped result's pill hugs its longest row.
      textWidthBasis: TextWidthBasis.longestLine,
      style: ResultChip._textStyle(total: total, color: ink),
    );
    final check = KapyIcon(
      KapyIcons.checkRounded,
      size: AppControlMetrics.iconInline,
      color: ink,
    );

    final chip = AnimatedContainer(
      duration: const Duration(milliseconds: 130),
      curve: Curves.easeOutCubic,
      padding: pill
          ? const EdgeInsets.symmetric(horizontal: 10, vertical: 5)
          : ResultChip._railPadding,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(radius),
      ),
      // A total's dash sits on the page around its fill, where it shows.
      foregroundDecoration: widget.result.count?.mark == true
          ? DashedOutline(
              (total ? palette.resultPillText : ink).withValues(alpha: 0.45),
              radius,
              outset: total ? 3 : 0,
            )
          : null,
      child: pill
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_justCopied) ...[check, const SizedBox(width: 4)],
                Flexible(child: words),
              ],
            )
          : Stack(
              alignment: Alignment.centerRight,
              children: [
                Opacity(
                  opacity: _justCopied ? 0 : 1,
                  alwaysIncludeSemantics: true,
                  child: words,
                ),
                if (_justCopied) check,
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
              minWidth: pill
                  ? 0
                  : math.min(ResultChip._railTarget, widget.collapsedWidth),
              minHeight: pill ? 0 : ResultChip._railTarget,
              maxWidth: _hovering
                  ? widget.collapsedWidth + 340
                  : widget.collapsedWidth,
            ),
            child: pill
                ? chip
                : Align(
                    alignment: Alignment.centerRight,
                    widthFactor: 1,
                    heightFactor: 1,
                    child: chip,
                  ),
          ),
        ),
      ),
    );
  }
}

/// A thin dashed outline: the quietest way to say that a result is not in the
/// note's total, or that a total left a line out. [outset] draws it that far
/// outside the box, so marking text moves nothing.
class DashedOutline extends Decoration {
  const DashedOutline(this.color, this.radius, {this.outset = 0});

  final Color color;
  final double radius;
  final double outset;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _DashedOutlinePainter(color, radius, outset);
}

class _DashedOutlinePainter extends BoxPainter {
  _DashedOutlinePainter(this.color, this.radius, this.outset);

  final Color color;
  final double radius;
  final double outset;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size;
    if (size == null) return;
    final outline = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (offset & size).inflate(outset).deflate(0.5),
          Radius.circular(radius),
        ),
      );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final metric in outline.computeMetrics()) {
      for (var at = 0.0; at < metric.length; at += 6) {
        canvas.drawPath(metric.extractPath(at, at + 3), paint);
      }
    }
  }
}
