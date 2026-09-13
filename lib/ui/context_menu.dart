import 'dart:ui' show SemanticsRole;

import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';

/// The quiet desktop menu used by note rows and things embedded in a note.
///
/// Flutter's stock popup grows its width, then its height, then fades each
/// item in. That motion is useful for a Material overflow menu, but a context
/// menu should feel attached to the click that summoned it. This route keeps
/// its final geometry from the first frame and only fades it in quickly.
Future<T?> showKapyContextMenu<T>({
  required BuildContext context,
  required Offset globalPosition,
  required List<PopupMenuEntry<T>> items,
  Rect? preferredGlobalBounds,
  bool requestFocus = true,
}) {
  assert(items.isNotEmpty);
  final navigator = Navigator.of(context);
  final overlay = navigator.overlay?.context.findRenderObject() as RenderBox?;
  if (overlay == null) return Future<T?>.value();

  Rect? preferredBounds;
  if (preferredGlobalBounds case final bounds?) {
    preferredBounds = Rect.fromPoints(
      overlay.globalToLocal(bounds.topLeft),
      overlay.globalToLocal(bounds.bottomRight),
    );
  }

  return navigator.push<T>(
    _KapyContextMenuRoute<T>(
      position: overlay.globalToLocal(globalPosition),
      preferredBounds: preferredBounds,
      items: items,
      capturedThemes: InheritedTheme.capture(
        from: context,
        to: navigator.context,
      ),
      barrierLabel: MaterialLocalizations.of(context).menuDismissLabel,
      requestFocus: requestFocus,
    ),
  );
}

/// The shared compact surface for popup-route and editable-text menus.
class KapyContextMenuSurface extends StatelessWidget {
  const KapyContextMenuSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(vertical: 4),
  });

  static const constraints = BoxConstraints(minWidth: 144, maxWidth: 208);

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return ConstrainedBox(
      constraints: constraints,
      child: IntrinsicWidth(
        child: Material(
          color: palette.surfaceBackground,
          elevation: 0,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(9),
            side: BorderSide(color: palette.controlBorder, width: 0.5),
          ),
          clipBehavior: Clip.antiAlias,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

class _KapyContextMenuRoute<T> extends PopupRoute<T> {
  _KapyContextMenuRoute({
    required this.position,
    required this.preferredBounds,
    required this.items,
    required this.capturedThemes,
    required this.barrierLabel,
    required bool requestFocus,
  }) : super(requestFocus: requestFocus);

  final Offset position;
  final Rect? preferredBounds;
  final List<PopupMenuEntry<T>> items;
  final CapturedThemes capturedThemes;

  @override
  final String barrierLabel;

  @override
  bool get barrierDismissible => true;

  @override
  Color? get barrierColor => null;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 90);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 65);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final mediaPadding = MediaQuery.paddingOf(context);
    return MediaQuery.removePadding(
      context: context,
      removeTop: true,
      removeRight: true,
      removeBottom: true,
      removeLeft: true,
      child: CustomSingleChildLayout(
        delegate: _KapyContextMenuLayout(
          position: position,
          preferredBounds: preferredBounds,
          mediaPadding: mediaPadding,
        ),
        child: capturedThemes.wrap(
          KapyContextMenuSurface(
            key: const ValueKey('kapy-context-menu'),
            padding:
                PopupMenuTheme.of(context).menuPadding ??
                const EdgeInsets.symmetric(vertical: 4),
            child: Semantics(
              role: SemanticsRole.menu,
              scopesRoute: true,
              namesRoute: true,
              explicitChildNodes: true,
              label: MaterialLocalizations.of(context).popupMenuLabel,
              child: SingleChildScrollView(child: ListBody(children: items)),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => FadeTransition(
    opacity: CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    ),
    child: child,
  );
}

class _KapyContextMenuLayout extends SingleChildLayoutDelegate {
  const _KapyContextMenuLayout({
    required this.position,
    required this.preferredBounds,
    required this.mediaPadding,
  });

  static const _screenGap = 8.0;
  static const _preferredGap = 4.0;

  final Offset position;
  final Rect? preferredBounds;
  final EdgeInsets mediaPadding;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(constraints.biggest).deflate(
        EdgeInsets.fromLTRB(
          _screenGap + mediaPadding.left,
          _screenGap + mediaPadding.top,
          _screenGap + mediaPadding.right,
          _screenGap + mediaPadding.bottom,
        ),
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final safe = Rect.fromLTRB(
      _screenGap + mediaPadding.left,
      _screenGap + mediaPadding.top,
      size.width - _screenGap - mediaPadding.right,
      size.height - _screenGap - mediaPadding.bottom,
    );
    final preferred = preferredBounds?.intersect(safe);

    double x;
    if (preferred != null &&
        preferred.width >= childSize.width + _preferredGap * 2) {
      // A note-row menu belongs to the notes list when the list can hold it.
      // Its right edge follows the click, then clamps inside that column.
      x = (position.dx - childSize.width).clamp(
        preferred.left + _preferredGap,
        preferred.right - childSize.width - _preferredGap,
      );
    } else if (position.dx + childSize.width <= safe.right) {
      x = position.dx;
    } else {
      x = position.dx - childSize.width;
    }

    var y = position.dy;
    if (y + childSize.height > safe.bottom) y -= childSize.height;
    return Offset(
      x.clamp(safe.left, safe.right - childSize.width).toDouble(),
      y.clamp(safe.top, safe.bottom - childSize.height).toDouble(),
    );
  }

  @override
  bool shouldRelayout(_KapyContextMenuLayout oldDelegate) =>
      position != oldDelegate.position ||
      preferredBounds != oldDelegate.preferredBounds ||
      mediaPadding != oldDelegate.mediaPadding;
}
