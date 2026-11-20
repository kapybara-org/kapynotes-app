import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// The notes picked to act on together, in every list.
///
/// A click with ⌘ (Ctrl off a Mac) or with Shift, a press dragged down the
/// rows, ⌘A, Shift with an arrow, and the archive's Select start it or add to
/// it. While it is on, a plain click picks too, as the archive's Select
/// always has, so one stray click never drops what was gathered: Esc, Done
/// or the action itself ends it, and so does letting go of the last pick,
/// unless Select began it.
///
/// A range runs across the list as painted, from the anchor: the note the
/// last click or sweep began on. It replaces the range before it and keeps
/// every other pick, so the next Shift-click or arrow can take it back.
class NotePicks extends ChangeNotifier {
  final _ids = <String>{};
  Set<String> _kept = const {};
  bool _on = false;
  bool _held = false;
  String? _anchor;
  String? _end;

  bool get on => _on;
  Set<String> get ids => UnmodifiableSetView(_ids);
  bool contains(String id) => _ids.contains(id);

  /// The archive's Select: on, with nothing picked yet, until Done.
  void start() {
    if (_on) return;
    _on = _held = true;
    notifyListeners();
  }

  /// Off, with nothing picked.
  void clear() {
    if (!_on && _ids.isEmpty) return;
    _stop();
    notifyListeners();
  }

  /// [id] in, or out again. From rest the [open] note comes along: it is
  /// the selection a ⌘-click adds to, so a ⌘-click on the open note alone
  /// picks nothing.
  void toggle(String id, {String? open}) {
    if (!_on && open != null) _ids.add(open);
    _on = true;
    if (!_ids.remove(id)) _ids.add(id);
    _anchor = _end = id;
    _kept = {..._ids};
    if (_ids.isEmpty && !_held) _stop();
    notifyListeners();
  }

  /// Every note from the anchor to [id] in [order]. From rest the range
  /// begins at the [open] note, where a Shift-click begins it.
  void extendTo(List<String> order, String id, {String? open}) {
    if (!_on) {
      _anchor = open != null && order.contains(open) ? open : id;
      _kept = const {};
      _on = true;
    }
    _anchor ??= id;
    _span(order, id);
  }

  /// Shift with an arrow: the far end of the range [delta] rows on.
  void step(List<String> order, int delta, {String? open}) {
    if (order.isEmpty) return;
    final from = order.indexOf((_on ? _end : null) ?? open ?? '');
    final to = from < 0
        ? (delta > 0 ? 0 : order.length - 1)
        : (from + delta).clamp(0, order.length - 1);
    extendTo(order, order[to], open: open);
  }

  /// ⌘A, and Select all. A list with nothing in it has nothing to pick, so
  /// it starts nothing.
  void all(List<String> order) {
    if (order.isEmpty) return;
    _on = true;
    _ids.addAll(order);
    _kept = {..._ids};
    notifyListeners();
  }

  /// A press dragged along the rows, from [id]: its range goes on top of
  /// what was picked before it, or of nothing from rest.
  void sweepFrom(String id) {
    _kept = _on ? {..._ids} : const {};
    _anchor = _end = id;
  }

  /// The sweep is over [id]. Still on the note it began on, from rest, it
  /// has picked nothing: that is a click.
  void sweepTo(List<String> order, String id) {
    if (!_on && id == _anchor) return;
    _on = true;
    _span(order, id);
  }

  /// Lets go of notes that have left the list. Nothing left picked is the
  /// end of picking.
  void drop(Iterable<String> ids) {
    final gone = ids.where(_ids.contains).toSet();
    if (gone.isEmpty) return;
    _ids.removeAll(gone);
    _kept = _kept.difference(gone);
    if (_ids.isEmpty) _stop();
    notifyListeners();
  }

  void _stop() {
    _on = _held = false;
    _ids.clear();
    _kept = const {};
    _anchor = _end = null;
  }

  void _span(List<String> order, String id) {
    final from = order.indexOf(_anchor!);
    final to = order.indexOf(id);
    _ids
      ..clear()
      ..addAll(_kept);
    if (from < 0 || to < 0) {
      _ids.add(id);
    } else {
      _ids.addAll(order.sublist(math.min(from, to), math.max(from, to) + 1));
    }
    _end = id;
    notifyListeners();
  }
}

/// Which way a press has begun to move: sideways, which carries a note to
/// the panes; along the list, which picks the notes it crosses; null while
/// it has not gone past [slop] either way. Whichever way is the furthest, so
/// the two never both take one press.
bool? movesSideways(Offset delta, double slop) {
  final across = delta.dx.abs();
  final along = delta.dy.abs();
  if (across <= slop && along <= slop) return null;
  return across > along;
}

/// Marks a note's row, for the sweep to find under the pointer.
@immutable
class NotePickTarget {
  const NotePickTarget(this.id);

  final String id;
}

/// Picks the notes a mouse press is dragged across, up or down the list.
///
/// Only a press on a row ([NotePickTarget]) begins one: on a heading or the
/// scroll bar it is left alone. Sideways is the note's own drag onto the
/// panes, told apart by [movesSideways]. A press that barely moves is still
/// a click.
class NoteSweep extends StatefulWidget {
  const NoteSweep({
    super.key,
    required this.onStart,
    required this.onUpdate,
    required this.child,
  });

  /// The note the press began on, once it is a sweep.
  final ValueChanged<String> onStart;

  /// Each note the pointer reaches after that.
  final ValueChanged<String> onUpdate;
  final Widget child;

  @override
  State<NoteSweep> createState() => _NoteSweepState();
}

class _NoteSweepState extends State<NoteSweep> {
  String? _over;

  String? _noteAt(Offset position) {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(
      result,
      position,
      View.of(context).viewId,
    );
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderMetaData && target.metaData is NotePickTarget) {
        return (target.metaData as NotePickTarget).id;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) => RawGestureDetector(
    gestures: {
      _SweepRecognizer: GestureRecognizerFactoryWithHandlers<_SweepRecognizer>(
        () => _SweepRecognizer(debugOwner: this),
        (recognizer) => recognizer
          ..noteAt = _noteAt
          ..onStart = (id) {
            _over = id;
            widget.onStart(id);
          }
          ..onUpdate = (position) {
            final id = _noteAt(position);
            if (id == null || id == _over) return;
            _over = id;
            widget.onUpdate(id);
          },
      ),
    },
    child: widget.child,
  );
}

class _SweepRecognizer extends OneSequenceGestureRecognizer {
  _SweepRecognizer({super.debugOwner})
    : super(
        supportedDevices: const {PointerDeviceKind.mouse},
        allowedButtonsFilter: (buttons) => buttons == kPrimaryButton,
      );

  String? Function(Offset position)? noteAt;
  ValueChanged<String>? onStart;
  ValueChanged<Offset>? onUpdate;

  Offset? _origin;
  String? _from;
  bool _sweeping = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (_origin != null) return;
    final from = noteAt?.call(event.position);
    if (from == null) return;
    super.addAllowedPointer(event);
    _origin = event.position;
    _from = from;
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      stopTrackingPointer(event.pointer);
      return;
    }
    if (event is! PointerMoveEvent) return;
    if (!_sweeping) {
      final sideways = movesSideways(
        event.position - _origin!,
        computeHitSlop(event.kind, gestureSettings),
      );
      if (sideways == null) return;
      if (sideways) {
        resolve(GestureDisposition.rejected);
        return;
      }
      _sweeping = true;
      resolve(GestureDisposition.accepted);
      onStart?.call(_from!);
    }
    onUpdate?.call(event.position);
  }

  @override
  void acceptGesture(int pointer) {}

  @override
  void rejectGesture(int pointer) => stopTrackingPointer(pointer);

  @override
  void didStopTrackingLastPointer(int pointer) {
    _sweeping = false;
    _origin = null;
    _from = null;
  }

  @override
  String get debugDescription => 'note sweep';
}
