import 'dart:ui' show SemanticsRole;

import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
import '../core/theme.dart';

/// The quiet desktop menu used by note rows and things embedded in a note.
///
/// Flutter's stock popup grows its width, then its height, then fades each
/// item in. That motion is useful for a Material overflow menu, but a context
/// menu should feel attached to the click that summoned it. This route keeps
/// its final geometry from the first frame and only fades it in quickly.
///
/// [onClosed] is told where the menu sat as it closes, for a list or a field
/// its choice opens to take its place.
Future<T?> showKapyContextMenu<T>({
  required BuildContext context,
  required Offset globalPosition,
  required List<PopupMenuEntry<T>> items,
  Rect? preferredGlobalBounds,
  bool requestFocus = true,
  bool useRootNavigator = false,
  ValueSetter<MenuSpot>? onClosed,
}) async {
  assert(items.isNotEmpty);
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  final overlay = navigator.overlay?.context.findRenderObject() as RenderBox?;
  if (overlay == null) return null;

  Rect? preferredBounds;
  if (preferredGlobalBounds case final bounds?) {
    preferredBounds = Rect.fromPoints(
      overlay.globalToLocal(bounds.topLeft),
      overlay.globalToLocal(bounds.bottomRight),
    );
  }

  final route = _KapyContextMenuRoute<T>(
    position: overlay.globalToLocal(globalPosition),
    preferredBounds: preferredBounds,
    items: items,
    capturedThemes: InheritedTheme.capture(
      from: context,
      to: navigator.context,
    ),
    barrierLabel: MaterialLocalizations.of(context).menuDismissLabel,
    requestFocus: requestFocus,
  );
  final choice = await navigator.push<T>(route);
  final menu = route.surface.currentContext?.findRenderObject() as RenderBox?;
  if (onClosed != null && menu != null && menu.hasSize) {
    final bounds = menu.localToGlobal(Offset.zero) & menu.size;
    onClosed((
      bounds: bounds,
      corner: Alignment(
        globalPosition.dx > bounds.center.dx ? 1 : -1,
        globalPosition.dy > bounds.center.dy ? 1 : -1,
      ),
    ));
  }
  return choice;
}

/// The shared compact surface for popup-route and editable-text menus.
class KapyContextMenuSurface extends StatelessWidget {
  const KapyContextMenuSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(vertical: 4),
  });

  /// As wide as its longest line where there is a pointer, so every label
  /// shows in full beside its shortcut. On touch, wide enough for a phone's
  /// longer labels, which have no shortcut beside them.
  static BoxConstraints get constraints => BoxConstraints(
    minWidth: 144,
    maxWidth: AppPlatform.hasPointer ? 320 : 256,
  );

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
            borderRadius: BorderRadius.circular(AppRadii.control),
            side: BorderSide(
              color: palette.controlBorder,
              width: AppHairline.of(context),
            ),
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

  /// The menu, which says where it sat as it closes.
  final surface = GlobalKey();

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
        child: KeyedSubtree(
          key: surface,
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

  static const _preferredGap = 4.0;

  final Offset position;
  final Rect? preferredBounds;
  final EdgeInsets mediaPadding;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(constraints.biggest).deflate(_clear(mediaPadding));

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final safe = _clear(mediaPadding).deflateRect(Offset.zero & size);
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

/// What a menu, and a list or a field its choice opens, keep clear of: the
/// screen's insets, and 8 more inside the window.
EdgeInsets _clear(EdgeInsets mediaPadding) =>
    mediaPadding + const EdgeInsets.all(8);

/// Where a menu sat, and the corner it hung from: the one at the point it
/// opened at. A list or a field one of its choices opens hangs from the same
/// corner, so it opens where the menu was.
typedef MenuSpot = ({Rect bounds, Alignment corner});

/// The spot for a list with no menu before it: [point], with the list
/// growing right and down from there.
MenuSpot spotAt(Offset point) =>
    (bounds: point & Size.zero, corner: Alignment.topLeft);

/// Lays a list or a field out from its [spot], growing away from the spot's
/// corner, and keeps it inside the window as a menu is kept.
class PopoverAtSpot extends SingleChildLayoutDelegate {
  const PopoverAtSpot(this.spot, {required this.mediaPadding});

  final MenuSpot spot;
  final EdgeInsets mediaPadding;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(constraints.biggest).deflate(_clear(mediaPadding));

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final safe = _clear(mediaPadding).deflateRect(Offset.zero & size);
    final (:bounds, :corner) = spot;
    final at = corner.withinRect(bounds) - corner.alongSize(childSize);
    return Offset(
      at.dx.clamp(safe.left, safe.right - childSize.width).toDouble(),
      at.dy.clamp(safe.top, safe.bottom - childSize.height).toDouble(),
    );
  }

  @override
  bool shouldRelayout(PopoverAtSpot oldDelegate) =>
      spot != oldDelegate.spot || mediaPadding != oldDelegate.mediaPadding;
}

/// One line of a note's actions menu, wherever it opens: a note's row in the
/// list, or the page's More button.
class KapyMenuAction {
  const KapyMenuAction({
    required this.value,
    required this.label,
    required this.icon,
    this.hint,
    this.destructive = false,
    this.enabled = true,
    this.checked,
  });

  final String value;
  final String label;
  final KapyIconData icon;
  final String? hint;
  final bool destructive;
  final bool enabled;

  /// Set for a line that turns something on or off, such as Skip pauses:
  /// a tick at its end while it is on.
  final bool? checked;
}

/// A note's actions menu: a heading that names what it acts on, where that
/// isn't plain, then its groups, each set off from the next by a rule.
typedef KapyMenu = ({String? heading, List<List<KapyMenuAction>> groups});

/// [menu]'s lines for [showKapyContextMenu]: its heading, then its groups
/// with a rule between each. [key] names a line by its action's value, and
/// [height] is each line's: a phone's are 44 to tap.
List<PopupMenuEntry<String>> kapyMenuItems(
  KapyMenu menu, {
  required String Function(String value) key,
  double height = 36,
}) {
  final groups = [
    for (final group in menu.groups)
      if (group.isNotEmpty) group,
  ];
  return [
    if (menu.heading case final heading?) _KapyMenuHeading(heading),
    for (final (index, group) in groups.indexed) ...[
      if (index > 0) const PopupMenuDivider(height: 9),
      for (final action in group)
        PopupMenuItem(
          key: ValueKey(key(action.value)),
          value: action.value,
          height: height,
          child: KapyMenuActionRow(action, touch: false),
        ),
    ],
  ];
}

/// The line over a menu's choices that names what they act on, such as
/// "3 notes". It isn't a choice, so it takes no tap and no focus.
class _KapyMenuHeading extends PopupMenuEntry<String> {
  const _KapyMenuHeading(this.label);

  final String label;

  @override
  double get height => 28;

  @override
  bool represents(String? value) => false;

  @override
  State<_KapyMenuHeading> createState() => _KapyMenuHeadingState();
}

class _KapyMenuHeadingState extends State<_KapyMenuHeading> {
  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
      child: Text(
        widget.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: AppTypeScale.small,
          color: context.palette.textTertiary,
        ),
      ),
    ),
  );
}

/// A [KapyMenuAction] as drawn in a desktop menu or a touch sheet.
class KapyMenuActionRow extends StatelessWidget {
  const KapyMenuActionRow(this.action, {super.key, required this.touch});

  final KapyMenuAction action;
  final bool touch;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final foreground = !action.enabled
        ? palette.textTertiary
        : action.destructive
        ? Theme.of(context).colorScheme.error
        : palette.textPrimary;
    final row = Row(
      children: [
        KapyIcon(
          action.icon,
          size: touch
              ? AppControlMetrics.iconAction
              : AppControlMetrics.iconControl,
          color: action.destructive || !action.enabled
              ? foreground
              : palette.textSecondary,
        ),
        SizedBox(width: touch ? 14 : 10),
        Expanded(
          child: Text(
            action.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: touch ? AppTypeScale.body : AppTypeScale.control,
              color: foreground,
            ),
          ),
        ),
        if (action.hint case final hint?) ...[
          SizedBox(width: touch ? 18 : 10),
          Text(
            hint,
            maxLines: 1,
            style: TextStyle(
              fontSize: AppTypeScale.control,
              color: palette.textTertiary,
            ),
          ),
        ],
        if (action.checked == true) ...[
          SizedBox(width: touch ? 18 : 10),
          KapyIcon(
            KapyIcons.checkRounded,
            size: touch
                ? AppControlMetrics.iconAction
                : AppControlMetrics.iconControl,
            color: palette.textSecondary,
          ),
        ],
      ],
    );
    if (action.checked == null) return row;
    return Semantics(checked: action.checked, child: row);
  }
}
