import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../calc/engine.dart';
import '../../core/theme.dart';
import 'line_metrics.dart';
import 'results_gutter.dart';
import 'scroll_passthrough.dart';

/// Each result at the right-hand end of its own line: a pill on the line's
/// last visual row, with a faint leader running to it from where the writing
/// stops.
///
/// Laid over the text field rather than inside it, and placed from the same
/// measurement of the note the field's own layout produces, so nothing here
/// is ever part of the note's text: the caret, the selection, copy and paste
/// and undo never meet it. Only the pills take the pointer. Everything around
/// them, the leaders included, reaches the field underneath.
class InlineResults extends StatelessWidget {
  const InlineResults({
    super.key,
    required this.results,
    required this.offsets,
    required this.scroll,
    required this.padding,
    required this.columnWidth,
  });

  final Map<int, LineResult> results;

  /// Must have been measured with every line in [results] in its
  /// `lastRowsOf`.
  final LineOffsets offsets;

  /// The field's own, so the pills move with the text.
  final ScrollController scroll;

  /// Where the field's text starts inside this layer, and the bands above and
  /// below it that the text scrolls under.
  final EdgeInsets padding;

  /// How wide the text wraps. A pill's right edge sits on it.
  final double columnWidth;

  /// Between the end of the writing and the leader, and between the leader
  /// and the pill.
  static const double gap = 12;

  @override
  Widget build(BuildContext context) {
    final leader = context.palette.textTertiary.withValues(alpha: 0.3);
    return Padding(
      padding: EdgeInsets.only(top: padding.top, bottom: padding.bottom),
      // Top and bottom only: a pill scrolls under the padding as the text
      // does, but may run on into the margin beside the column.
      child: ClipRect(
        clipper: const VerticalClipper(),
        child: LayoutBuilder(
          builder: (context, constraints) => ListenableBuilder(
            listenable: scroll,
            builder: (context, _) {
              final scrolled = scroll.hasClients ? scroll.offset : 0.0;
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  for (final MapEntry(key: line, value: result)
                      in results.entries)
                    if (offsets.lastRows[line] case final row?)
                      // Only what can be seen; a long note stays cheap.
                      if (row.bottom - scrolled >= 0 &&
                          row.top - scrolled <= constraints.maxHeight)
                        Positioned(
                          key: ValueKey(line),
                          left: 0,
                          right: 0,
                          top: row.top - scrolled,
                          height: row.height,
                          child: CustomMultiChildLayout(
                            delegate: _ResultLineLayout(
                              textEnd: padding.left + row.right,
                              columnRight: padding.left + columnWidth,
                            ),
                            children: [
                              LayoutId(
                                id: _Part.leader,
                                child: IgnorePointer(
                                  child: CustomPaint(
                                    key: ValueKey('result-leader-$line'),
                                    painter: _LeaderPainter(leader),
                                  ),
                                ),
                              ),
                              LayoutId(
                                id: _Part.pill,
                                child: ScrollPassthrough(
                                  controller: scroll,
                                  child: ResultChip(
                                    result: result,
                                    collapsedWidth: columnWidth / 2,
                                    look: ResultChipLook.pill,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

enum _Part { leader, pill }

/// Puts a line's pill at the right-hand end of the column and runs the
/// leader up to it.
///
/// The writing always wins the row. When it already reaches past where the
/// pill would go, the pill follows the writing instead, out into the margin
/// as far as the page allows, and only once there is no margin left does it
/// cover the end of the line.
class _ResultLineLayout extends MultiChildLayoutDelegate {
  _ResultLineLayout({required this.textEnd, required this.columnRight});

  final double textEnd;
  final double columnRight;

  @override
  void performLayout(Size size) {
    final pill = layoutChild(_Part.pill, BoxConstraints(maxWidth: size.width));
    final start = textEnd + InlineResults.gap;
    var left = columnRight - pill.width;
    if (left < start) left = math.min(start, size.width - pill.width);
    left = math.max(0.0, left);
    positionChild(_Part.pill, Offset(left, (size.height - pill.height) / 2));

    final length = math.max(0.0, left - InlineResults.gap - start);
    layoutChild(_Part.leader, BoxConstraints.tight(Size(length, size.height)));
    positionChild(_Part.leader, Offset(start, 0));
  }

  @override
  bool shouldRelayout(_ResultLineLayout oldDelegate) =>
      oldDelegate.textEnd != textEnd || oldDelegate.columnRight != columnRight;
}

/// A dotted rule across the middle of the row: square dots a dot apart.
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
