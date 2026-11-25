import 'package:material_ui/material_ui.dart';

/// The note field's scroll controller.
///
/// When the text, or the room it has, gets shorter than the offset (the
/// keyboard going down, the end of a note deleted), the field's position
/// puts itself back in range while it lays out, and a [ScrollPosition] does
/// that without telling its listeners. What is placed over the text by the
/// offset, the time line under the title and the folder path above it among
/// them, would then stay where the text was. This one tells its listeners
/// once that frame is done, so they move back with the text.
class FieldScrollController extends ScrollController {
  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _FieldScrollPosition(
    physics: physics,
    context: context,
    initialPixels: initialScrollOffset,
    keepScrollOffset: keepScrollOffset,
    oldPosition: oldPosition,
    debugLabel: debugLabel,
  );
}

class _FieldScrollPosition extends ScrollPositionWithSingleContext {
  _FieldScrollPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  bool _telling = false;
  bool _disposed = false;

  @override
  void correctPixels(double value) {
    final moved = hasPixels && haveDimensions && value != pixels;
    super.correctPixels(value);
    if (!moved || _telling) return;
    _telling = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _telling = false;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
