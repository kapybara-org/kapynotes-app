import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';

/// Full-page touch swipes for the two actions beside a compact note.
///
/// This observes raw pointer movement instead of joining Flutter's gesture
/// arena. The editor therefore keeps ordinary vertical scrolling, taps, and
/// long-press text selection. An action happens only after a mostly-horizontal
/// drag crosses a substantial threshold and the finger is released.
class MobilePageSwipe extends StatefulWidget {
  const MobilePageSwipe({
    super.key,
    required this.child,
    required this.onOpenNotes,
    required this.onCreateNote,
    this.enabled = true,
  });

  final Widget child;
  final VoidCallback onOpenNotes;
  final VoidCallback onCreateNote;
  final bool enabled;

  /// A swipe always needs at least this much real travel, even when it begins
  /// close to the edge it is moving towards.
  static const double minimumActivationDistance = 72;

  /// The ordinary threshold is roughly a third of a phone, capped so it does
  /// not become unreasonable on a tablet in compact mode.
  static const double activationWidthFraction = 0.32;
  static const double maximumActivationDistance = 152;

  /// Sideways movement must outweigh vertical drift by this much. This is the
  /// guard that lets a thumb scroll a note diagonally without making a note.
  static const double horizontalDominance = 1.5;

  @override
  State<MobilePageSwipe> createState() => _MobilePageSwipeState();
}

enum _PageSwipeAction { openNotes, createNote }

class _MobilePageSwipeState extends State<MobilePageSwipe> {
  final Set<int> _touchesDown = {};
  int? _pointer;
  Offset? _origin;
  Duration? _startedAt;
  double _viewportWidth = 0;
  _PageSwipeAction? _action;
  double _progress = 0;
  bool _armed = false;
  bool _thresholdHapticSent = false;
  bool _showCreatedConfirmation = false;
  Timer? _longPressGuardTimer;
  Timer? _confirmationTimer;

  @override
  void didUpdateWidget(MobilePageSwipe oldWidget) {
    super.didUpdateWidget(oldWidget);
    // This update already rebuilds the widget, so clearing here must not ask
    // for another build from inside the current one.
    if (oldWidget.enabled && !widget.enabled) _clearGesture(notify: false);
  }

  @override
  void dispose() {
    _longPressGuardTimer?.cancel();
    _confirmationTimer?.cancel();
    super.dispose();
  }

  void _handleDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.touch) return;
    _touchesDown.add(event.pointer);
    if (!widget.enabled || _touchesDown.length != 1 || _pointer != null) {
      _clearGesture();
      return;
    }

    _pointer = event.pointer;
    _origin = event.position;
    _startedAt = event.timeStamp;
    _viewportWidth = MediaQuery.sizeOf(context).width;
    _longPressGuardTimer?.cancel();
    _longPressGuardTimer = Timer(kLongPressTimeout, () {
      if (_pointer == event.pointer && _action == null) _clearGesture();
    });
  }

  void _handleMove(PointerMoveEvent event) {
    if (event.pointer != _pointer || !widget.enabled) return;
    final origin = _origin;
    final startedAt = _startedAt;
    if (origin == null || startedAt == null) return;

    final delta = event.position - origin;
    final dx = delta.dx.abs();
    final dy = delta.dy.abs();

    if (_action == null) {
      if (delta.distance < kTouchSlop) return;

      // A long press belongs to text selection, even if the selection handle
      // later travels a long way sideways.
      if (event.timeStamp - startedAt >= kLongPressTimeout) {
        _clearGesture();
        return;
      }

      // Once vertical intent is clear, this whole touch remains a scroll.
      if (dy >= kTouchSlop && dx < dy * MobilePageSwipe.horizontalDominance) {
        _clearGesture();
        return;
      }
      if (dx < kTouchSlop || dx < dy * MobilePageSwipe.horizontalDominance) {
        return;
      }
      _action = delta.dx > 0
          ? _PageSwipeAction.openNotes
          : _PageSwipeAction.createNote;
      _longPressGuardTimer?.cancel();
      _longPressGuardTimer = null;
    }

    final stillMovingTheSameWay = switch (_action!) {
      _PageSwipeAction.openNotes => delta.dx > 0,
      _PageSwipeAction.createNote => delta.dx < 0,
    };
    if (!stillMovingTheSameWay ||
        dx < dy * MobilePageSwipe.horizontalDominance) {
      _clearGesture();
      return;
    }

    final threshold = _activationDistance(_action!, origin);
    final nextProgress = ((dx - kTouchSlop) / (threshold - kTouchSlop)).clamp(
      0.0,
      1.0,
    );
    final nextArmed = dx >= threshold;
    if (nextArmed && !_thresholdHapticSent) {
      _thresholdHapticSent = true;
      unawaited(HapticFeedback.selectionClick());
    }
    if (nextProgress == _progress && nextArmed == _armed) return;
    setState(() {
      _progress = nextProgress;
      _armed = nextArmed;
    });
  }

  double _activationDistance(_PageSwipeAction action, Offset origin) {
    final ordinary = (_viewportWidth * MobilePageSwipe.activationWidthFraction)
        .clamp(
          MobilePageSwipe.minimumActivationDistance,
          MobilePageSwipe.maximumActivationDistance,
        );
    final available = switch (action) {
      _PageSwipeAction.openNotes => _viewportWidth - origin.dx,
      _PageSwipeAction.createNote => origin.dx,
    };
    // Near an edge, use most of the room that actually exists, but never make
    // a tiny twitch actionable. This is what lets a right swipe begun in the
    // right half still open the left sidebar.
    final reachable = math.max(
      MobilePageSwipe.minimumActivationDistance,
      available * 0.8,
    );
    return math.min(ordinary, reachable);
  }

  void _handleUp(PointerUpEvent event) {
    _touchesDown.remove(event.pointer);
    if (event.pointer != _pointer) return;
    final action = _armed ? _action : null;
    _clearGesture();
    if (action == null || !widget.enabled) return;

    switch (action) {
      case _PageSwipeAction.openNotes:
        widget.onOpenNotes();
      case _PageSwipeAction.createNote:
        _showNewNoteConfirmation();
        widget.onCreateNote();
    }
  }

  void _handleCancel(PointerCancelEvent event) {
    _touchesDown.remove(event.pointer);
    if (event.pointer == _pointer) _clearGesture();
  }

  void _clearGesture({bool notify = true}) {
    final hadVisualState = _action != null || _progress != 0 || _armed;
    _longPressGuardTimer?.cancel();
    _longPressGuardTimer = null;
    _pointer = null;
    _origin = null;
    _startedAt = null;
    _viewportWidth = 0;
    _action = null;
    _progress = 0;
    _armed = false;
    _thresholdHapticSent = false;
    if (notify && hadVisualState && mounted) setState(() {});
  }

  void _showNewNoteConfirmation() {
    _confirmationTimer?.cancel();
    setState(() => _showCreatedConfirmation = true);
    _confirmationTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _showCreatedConfirmation = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handleDown,
      onPointerMove: _handleMove,
      onPointerUp: _handleUp,
      onPointerCancel: _handleCancel,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (_showCreatedConfirmation)
            const _PageSwipeCue(
              label: 'New note created',
              icon: Icons.note_add_rounded,
              progress: 1,
              trailing: true,
              complete: true,
            )
          else if (_action != null && _progress > 0)
            _PageSwipeCue(
              key: const ValueKey('mobile-page-swipe-cue'),
              label: switch ((_action!, _armed)) {
                (_PageSwipeAction.openNotes, false) => 'Swipe right for notes',
                (_PageSwipeAction.openNotes, true) => 'Release for notes',
                (_PageSwipeAction.createNote, false) =>
                  'Swipe left for new note',
                (_PageSwipeAction.createNote, true) => 'Release for new note',
              },
              icon: _action == _PageSwipeAction.openNotes
                  ? Icons.menu_open_rounded
                  : Icons.note_add_outlined,
              progress: _progress,
              trailing: _action == _PageSwipeAction.createNote,
              complete: _armed,
            ),
        ],
      ),
    );
  }
}

class _PageSwipeCue extends StatelessWidget {
  const _PageSwipeCue({
    super.key,
    required this.label,
    required this.icon,
    required this.progress,
    required this.trailing,
    required this.complete,
  });

  final String label;
  final IconData icon;
  final double progress;
  final bool trailing;
  final bool complete;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Positioned(
      top: MediaQuery.paddingOf(context).top + 58,
      left: trailing ? null : 12,
      right: trailing ? 12 : null,
      child: IgnorePointer(
        child: Semantics(
          liveRegion: complete,
          label: label,
          child: ExcludeSemantics(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: palette.surfaceBackground,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: palette.controlBorder, width: 0.5),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: dark ? 0.20 : 0.08),
                    blurRadius: 14,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox.square(
                    dimension: 22,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        CircularProgressIndicator(
                          value: progress,
                          strokeWidth: 2,
                          color: palette.chipCurrency,
                          backgroundColor: palette.controlBorder,
                        ),
                        Icon(icon, size: 14, color: palette.chipCurrency),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: TextStyle(
                      color: complete
                          ? palette.textPrimary
                          : palette.textSecondary,
                      fontSize: AppTypeScale.body,
                      fontWeight: complete ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
