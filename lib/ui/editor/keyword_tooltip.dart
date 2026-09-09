import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';

/// A small, non-interactive explanation anchored to a calculator keyword.
///
/// It lives in the root overlay so the editor's clipping never cuts it off,
/// and ignores pointers so clicking a word still places the caret normally.
class KeywordTooltip {
  const KeywordTooltip._();

  static OverlayEntry? _current;
  static bool _observingPointers = false;

  static void show(
    BuildContext context, {
    required Rect anchor,
    required String keyword,
    required String message,
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    hide();
    final entry = OverlayEntry(
      builder: (context) => Positioned.fill(
        child: IgnorePointer(
          child: CustomSingleChildLayout(
            delegate: _KeywordTooltipPosition(
              anchor: anchor,
              safeArea: MediaQuery.paddingOf(context),
            ),
            child: _KeywordTooltipBody(keyword: keyword, message: message),
          ),
        ),
      ),
    );
    _current = entry;
    overlay.insert(entry);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_handleGlobalPointer);
    _observingPointers = true;
  }

  static void hide() {
    _current?.remove();
    _current = null;
    if (_observingPointers) {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(
        _handleGlobalPointer,
      );
      _observingPointers = false;
    }
  }

  /// Watches without participating in hit testing, so the dismissing click
  /// still reaches the editor or control beneath the tooltip.
  static void _handleGlobalPointer(PointerEvent event) {
    if (event is PointerDownEvent) hide();
  }
}

class _KeywordTooltipBody extends StatelessWidget {
  const _KeywordTooltipBody({required this.keyword, required this.message});

  final String keyword;
  final String message;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      key: const ValueKey('calc-keyword-tooltip'),
      constraints: const BoxConstraints(maxWidth: 300),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: BoxDecoration(
        color: palette.surfaceBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.controlBorder, width: 0.5),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            keyword,
            style: TextStyle(
              fontSize: AppTypeScale.caption,
              fontWeight: FontWeight.w500,
              color: palette.keyword,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            message,
            style: TextStyle(
              fontSize: AppTypeScale.small,
              height: 1.3,
              color: palette.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _KeywordTooltipPosition extends SingleChildLayoutDelegate {
  const _KeywordTooltipPosition({required this.anchor, required this.safeArea});

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
      ).copyWith(maxWidth: math.min(300, constraints.maxWidth - _margin * 2));

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

  static double _clamp(double value, double low, double high) =>
      high <= low ? low : math.min(math.max(value, low), high);

  @override
  bool shouldRelayout(_KeywordTooltipPosition oldDelegate) =>
      oldDelegate.anchor != anchor || oldDelegate.safeArea != safeArea;
}
