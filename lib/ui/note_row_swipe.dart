import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
import '../core/theme.dart';

/// One thing a phone row's swipe does: a button behind the row's trailing
/// edge, or what a swipe all the way across does.
typedef NoteRowSwipeAction = ({
  String key,
  String label,
  KapyIconData icon,
  Color background,
  Color foreground,
  VoidCallback onPressed,
});

/// A phone's note row that slides left. A short swipe shows [actions] at its
/// trailing edge, such as Pin and Delete; a swipe past [fullFraction] of the
/// row does [full], such as Archive, with a tick on iOS as it passes, and the
/// row slides out. A swipe back, a tap anywhere but on the row's buttons, or
/// a scroll of its list closes it, so only one row stays open.
///
/// The buttons stand in for the row's menu, whose choices VoiceOver and
/// TalkBack already offer as actions on the row, so they keep out of the
/// semantics tree.
class NoteRowSwipe extends StatefulWidget {
  const NoteRowSwipe({
    super.key,
    required this.id,
    required this.actions,
    this.full,
    required this.child,
  });

  /// The note's id, which keys each button as `swipe-<key>-<id>`.
  final String id;
  final List<NoteRowSwipeAction> actions;

  /// Null stops a long swipe at the buttons.
  final NoteRowSwipeAction? full;
  final Widget child;

  /// Each button's width, while the row has room for them.
  static const double actionWidth = 76;

  /// How much of the row the buttons may take at most, on a narrow card.
  static const double actionsFraction = 0.6;

  /// How far across the row a swipe has to go to do [full]: this much of
  /// its width, and always a little past the buttons.
  static const double fullFraction = 0.6;
  static const double fullPastActions = 40;

  /// How fast a flick opens or closes the row whatever its distance.
  static const double flick = 300;

  @override
  State<NoteRowSwipe> createState() => _NoteRowSwipeState();
}

class _NoteRowSwipeState extends State<NoteRowSwipe>
    with SingleTickerProviderStateMixin {
  /// How far left the row has slid, in logical pixels.
  late final _offset = AnimationController.unbounded(vsync: this);

  double _width = 0;

  /// Whether the swipe in hand is past the point that does [NoteRowSwipe.full].
  bool _past = false;

  /// Whether the row is sliding out to do [NoteRowSwipe.full].
  bool _leaving = false;

  ScrollPosition? _scroll;

  double get _extent => math.min(
    widget.actions.length * NoteRowSwipe.actionWidth,
    _width * NoteRowSwipe.actionsFraction,
  );

  double get _threshold => math.max(
    _width * NoteRowSwipe.fullFraction,
    _extent + NoteRowSwipe.fullPastActions,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scroll = Scrollable.maybeOf(context)?.position;
    if (scroll == _scroll) return;
    _scroll?.isScrollingNotifier.removeListener(_onScroll);
    _scroll = scroll?..isScrollingNotifier.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll?.isScrollingNotifier.removeListener(_onScroll);
    _offset.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll?.isScrollingNotifier.value ?? false) _close();
  }

  void _close() {
    if (_leaving || _offset.value == 0) return;
    _settle(open: false);
  }

  void _settle({required bool open}) => unawaited(
    _offset.animateTo(
      open ? _extent : 0,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    ),
  );

  void _start(DragStartDetails details) {
    if (_leaving) return;
    _width = context.size?.width ?? 0;
    _past = false;
    _offset.stop();
  }

  void _update(DragUpdateDetails details) {
    if (_leaving) return;
    final full = widget.full != null;
    final next = (_offset.value - (details.primaryDelta ?? 0)).clamp(
      0.0,
      full ? _width : _extent,
    );
    _offset.value = next;
    final past = full && next >= _threshold;
    if (past == _past) return;
    setState(() => _past = past);
    if (AppPlatform.isIOS) unawaited(HapticFeedback.lightImpact());
  }

  void _end(DragEndDetails details) {
    if (_leaving) return;
    if (widget.full case final full? when _past) {
      unawaited(_leave(full));
      return;
    }
    final velocity = details.primaryVelocity ?? 0;
    _settle(
      open:
          _extent > 0 &&
          (velocity < -NoteRowSwipe.flick ||
              (velocity <= NoteRowSwipe.flick && _offset.value > _extent / 2)),
    );
  }

  /// Slides the row out, then does [full]. A row still here afterwards,
  /// whose note stayed, comes back.
  Future<void> _leave(NoteRowSwipeAction full) async {
    setState(() => _leaving = true);
    await _offset.animateTo(
      _width,
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
    );
    if (!mounted) return;
    full.onPressed();
    if (!mounted) return;
    _offset.value = 0;
    setState(() {
      _leaving = false;
      _past = false;
    });
  }

  void _run(NoteRowSwipeAction action) {
    _offset.value = 0;
    action.onPressed();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.actions.isEmpty && widget.full == null) return widget.child;
    final paper = context.palette.paperColor;
    return TapRegion(
      onTapOutside: (_) => _close(),
      child: GestureDetector(
        excludeFromSemantics: true,
        onHorizontalDragStart: _start,
        onHorizontalDragUpdate: _update,
        onHorizontalDragEnd: _end,
        child: AnimatedBuilder(
          animation: _offset,
          builder: (context, child) {
            final dx = _offset.value;
            final open = dx > 0;
            return ClipRect(
              clipBehavior: open ? Clip.hardEdge : Clip.none,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: open ? _behind(dx) : const SizedBox.shrink(),
                  ),
                  Transform.translate(
                    offset: Offset(-dx, 0),
                    child: GestureDetector(
                      onTap: open ? _close : null,
                      behavior: HitTestBehavior.opaque,
                      child: AbsorbPointer(
                        absorbing: open,
                        child: ColoredBox(
                          color: open ? paper : const Color(0x00000000),
                          child: child,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
          child: widget.child,
        ),
      ),
    );
  }

  /// What the row uncovers as it slides: its buttons, which stretch to
  /// fill a longer swipe, or past the point of no return, [full]'s colour
  /// across the row.
  Widget _behind(double dx) {
    final full = widget.full;
    if (full != null && (_past || _leaving)) {
      return ColoredBox(
        key: ValueKey('swipe-${full.key}-${widget.id}'),
        color: full.background,
        child: Align(
          alignment: AlignmentDirectional.centerEnd,
          child: SizedBox(
            width: NoteRowSwipe.actionWidth,
            child: _SwipeActionFace(full),
          ),
        ),
      );
    }
    final width = math.max(dx, _extent) / widget.actions.length;
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        for (final action in widget.actions)
          SizedBox(
            width: width,
            child: Material(
              color: action.background,
              child: InkWell(
                key: ValueKey('swipe-${action.key}-${widget.id}'),
                onTap: () => _run(action),
                child: _SwipeActionFace(action),
              ),
            ),
          ),
      ],
    );
  }
}

/// A swipe action's icon over its name.
class _SwipeActionFace extends StatelessWidget {
  const _SwipeActionFace(this.action);

  final NoteRowSwipeAction action;

  @override
  Widget build(BuildContext context) {
    final foreground = action.foreground;
    return ExcludeSemantics(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        spacing: 4,
        children: [
          KapyIcon(action.icon, size: 20, color: foreground),
          Text(
            action.label,
            maxLines: 1,
            overflow: TextOverflow.clip,
            softWrap: false,
            style: TextStyle(
              fontFamily: AppFonts.ui,
              fontSize: 12.5,
              fontWeight: AppWeight.font(AppWeight.button),
              fontVariations: AppWeight.wght(AppWeight.button),
              color: foreground,
            ),
          ),
        ],
      ),
    );
  }
}
