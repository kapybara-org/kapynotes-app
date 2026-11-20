import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'note_field.dart';

/// What a pointer does to a [NoteField]'s selection: what
/// [TextSelectionGestureDetectorBuilder] does for [TextField] on each
/// platform, over the field's lines instead of a [RenderEditable]. Positions
/// are global.
class NoteGestures {
  NoteGestures(this.field);

  final NoteFieldState field;

  /// Whether the gesture under way began with a finger or a stylus, which
  /// the toolbar shows for and a mouse doesn't.
  bool _showsToolbar = true;

  /// The same for the selection handles, which a secondary tap shows the
  /// toolbar without.
  bool get showsHandles => _showsHandles;
  bool _showsHandles = true;

  /// Whether Shift was held when the gesture's pointer went down.
  bool _shift = false;

  /// The selection, and how far the note was scrolled, when a drag began.
  TextSelection? _dragStartSelection;
  double _dragStartScroll = 0;

  /// Whether a long press began while the field didn't have focus, which on
  /// Apple's platforms selects word by word instead of moving the caret.
  bool _longPressWithoutFocus = false;

  TextEditingValue get _value => field.widget.controller.value;
  TextSelection get _selection => _value.selection;
  bool get _focused => field.widget.focusNode.hasFocus;
  bool get _readOnly => field.widget.readOnly;

  double get _scroll {
    final scroll = field.widget.scrollController;
    return scroll.hasClients ? scroll.offset : 0;
  }

  /// How far the note has scrolled under the pointer since the drag began.
  Offset get _scrolled => Offset(0, _scroll - _dragStartScroll);

  static bool get _apple => switch (defaultTargetPlatform) {
    TargetPlatform.iOS || TargetPlatform.macOS => true,
    _ => false,
  };

  static bool _byTouch(PointerDeviceKind? kind) =>
      kind == null ||
      kind == PointerDeviceKind.touch ||
      kind == PointerDeviceKind.stylus;

  static bool _precise(PointerDeviceKind? kind) =>
      kind == PointerDeviceKind.mouse || kind == PointerDeviceKind.trackpad;

  /// A run of taps as the platform counts it: Apple's stop at three, Windows
  /// goes back and forth between two and three, and the rest start over.
  static int _taps(int count) => switch (defaultTargetPlatform) {
    TargetPlatform.iOS || TargetPlatform.macOS => math.min(count, 3),
    TargetPlatform.windows => count < 2 ? count : 2 + count % 2,
    TargetPlatform.android || TargetPlatform.fuchsia || TargetPlatform.linux =>
      count <= 3 ? count : (count % 3 == 0 ? 3 : count % 3),
  };

  void _showMagnifier(Offset at) {
    if (defaultTargetPlatform
        case TargetPlatform.android || TargetPlatform.iOS) {
      field.showMagnifier(at);
    }
  }

  void _hideMagnifier() {
    if (!field.mounted) return;
    if (defaultTargetPlatform
        case TargetPlatform.android || TargetPlatform.iOS) {
      field.hideMagnifier();
    }
  }

  void _select(TextSelection selection, SelectionChangedCause cause) => field
      .userUpdateTextEditingValue(_value.copyWith(selection: selection), cause);

  /// Moves whichever end of the selection, or of [from], is nearer [at] to
  /// it, so that the selection only grows.
  void _expand(Offset at, SelectionChangedCause cause, [TextSelection? from]) {
    final tapped = field.positionAt(at).offset;
    final selection = from ?? _selection;
    final baseIsCloser =
        (tapped - selection.baseOffset).abs() <
        (tapped - selection.extentOffset).abs();
    _select(
      selection.copyWith(
        baseOffset: baseIsCloser
            ? selection.extentOffset
            : selection.baseOffset,
        extentOffset: tapped,
      ),
      cause,
    );
  }

  /// Moves the selection's extent to [at], holding its base.
  void _extend(Offset at, SelectionChangedCause cause) => _select(
    _selection.copyWith(extentOffset: field.positionAt(at).offset),
    cause,
  );

  /// Selects whole paragraphs, or on Linux whole rows, from the one at
  /// [from] to the one at [to].
  void _selectParagraphs(Offset from, Offset? to, SelectionChangedCause cause) {
    final text = _value.text;
    final TextBoundary boundary = defaultTargetPlatform == TargetPlatform.linux
        ? LineBoundary(field)
        : ParagraphBoundary(text);
    TextRange around(TextPosition position) => TextRange(
      start:
          boundary.getLeadingTextBoundaryAt(
            position.offset == text.length
                ? position.offset - 1
                : position.offset,
          ) ??
          0,
      end: boundary.getTrailingTextBoundaryAt(position.offset) ?? text.length,
    );
    final fromPosition = field.positionAt(from);
    final fromRange = around(fromPosition);
    final toPosition = to == null ? fromPosition : field.positionAt(to);
    final toRange = toPosition == fromPosition ? fromRange : around(toPosition);
    _select(
      fromRange.start < toRange.end
          ? TextSelection(
              baseOffset: fromRange.start,
              extentOffset: toRange.end,
            )
          : TextSelection(
              baseOffset: fromRange.end,
              extentOffset: toRange.start,
            ),
      cause,
    );
  }

  void onTapTrackStart() {
    _shift = HardwareKeyboard.instance.logicalKeysPressed.intersection({
      LogicalKeyboardKey.shiftLeft,
      LogicalKeyboardKey.shiftRight,
    }).isNotEmpty;
  }

  void onTapTrackReset() => _shift = false;

  /// On the desktop the caret goes where the pointer went down; on phones it
  /// waits for the tap to end.
  void onTapDown(TapDragDownDetails details) {
    field.lastSecondaryTapDownPosition = null;
    _showsToolbar = _showsHandles = _byTouch(details.kind);
    final at = details.globalPosition;
    final shift = _shift && _selection.isValid;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android ||
          TargetPlatform.fuchsia ||
          TargetPlatform.iOS:
        break;
      case TargetPlatform.macOS:
        field.hideToolbar();
        if (shift) {
          // An unfocused field expands from its start.
          _expand(
            at,
            SelectionChangedCause.tap,
            _focused ? null : const TextSelection.collapsed(offset: 0),
          );
          return;
        }
        field.selectPositionAt(from: at, cause: SelectionChangedCause.tap);
      case TargetPlatform.linux || TargetPlatform.windows:
        field.hideToolbar();
        if (shift) return _extend(at, SelectionChangedCause.tap);
        field.selectPositionAt(from: at, cause: SelectionChangedCause.tap);
    }
  }

  void onSingleTapUp(TapDragUpDetails details) {
    final at = details.globalPosition;
    final shift = _shift && _selection.isValid;
    switch (defaultTargetPlatform) {
      case TargetPlatform.linux ||
          TargetPlatform.macOS ||
          TargetPlatform.windows:
        break;
      case TargetPlatform.android || TargetPlatform.fuchsia:
        field.hideToolbar(false);
        if (shift) return _extend(at, SelectionChangedCause.tap);
        field.selectPositionAt(from: at, cause: SelectionChangedCause.tap);
      case TargetPlatform.iOS:
        if (shift) {
          return _expand(
            at,
            SelectionChangedCause.tap,
            _focused ? null : const TextSelection.collapsed(offset: 0),
          );
        }
        if (details.kind != PointerDeviceKind.touch &&
            details.kind != PointerDeviceKind.unknown) {
          field.selectPositionAt(from: at, cause: SelectionChangedCause.tap);
          field.hideToolbar();
          break;
        }
        // A tap on the selection, or on the caret, shows or hides the
        // toolbar; anywhere else the caret goes to the nearer end of the
        // word tapped.
        final previous = _selection;
        final position = field.positionAt(at);
        final onSelection =
            previous.isValid &&
            ((!previous.isCollapsed &&
                    previous.start < position.offset &&
                    previous.end > position.offset) ||
                (previous.isCollapsed &&
                    previous.start <= position.offset &&
                    previous.end >= position.offset &&
                    position.affinity == previous.affinity &&
                    !_readOnly));
        if (onSelection && _focused) {
          field.toggleToolbar(false);
        } else {
          field.selectWordEdge(at, SelectionChangedCause.tap);
          if (previous == _selection && _focused && !_readOnly) {
            field.toggleToolbar(false);
          } else {
            field.hideToolbar(false);
          }
        }
    }
    field.requestKeyboard();
  }

  void onSingleLongTapStart(LongPressStartDetails details) {
    final at = details.globalPosition;
    if (_apple && _focused && !_readOnly) {
      field.selectPositionAt(from: at, cause: SelectionChangedCause.longPress);
    } else {
      _longPressWithoutFocus = _apple && !_focused;
      field.selectWordsInRange(
        from: at,
        cause: SelectionChangedCause.longPress,
      );
      if (!_longPressWithoutFocus) Feedback.forLongPress(field.context);
    }
    _showMagnifier(at);
    _dragStartScroll = _scroll;
  }

  void onSingleLongTapMoveUpdate(LongPressMoveUpdateDetails details) {
    final at = details.globalPosition;
    if (_apple && !_longPressWithoutFocus && !_readOnly) {
      field.selectPositionAt(from: at, cause: SelectionChangedCause.longPress);
    } else {
      field.selectWordsInRange(
        from: at - details.offsetFromOrigin - _scrolled,
        to: at,
        cause: SelectionChangedCause.longPress,
      );
    }
    _showMagnifier(at);
  }

  void onSingleLongTapEnd(LongPressEndDetails details) {
    _endLongPress();
    if (_showsToolbar) field.showToolbar();
  }

  void _endLongPress() {
    _hideMagnifier();
    _longPressWithoutFocus = false;
    _dragStartScroll = 0;
  }

  void onSecondaryTapDown(TapDownDetails details) {
    field.lastSecondaryTapDownPosition = details.globalPosition;
    _showsToolbar = true;
    _showsHandles = _byTouch(details.kind);
  }

  /// Opens the context menu. On Apple's platforms a secondary click away
  /// from the selection selects the word under it first.
  void onSecondaryTap() {
    final at = field.lastSecondaryTapDownPosition;
    if (at == null) return;
    if (_apple) {
      final offset = field.positionAt(at).offset;
      final onSelection =
          _selection.start <= offset && _selection.end >= offset;
      if (!onSelection || !_focused) {
        field.selectWordsInRange(from: at, cause: SelectionChangedCause.tap);
      }
      if (_showsToolbar) {
        field.hideToolbar();
        field.showToolbar();
      }
      return;
    }
    if (!_focused) {
      field.selectPositionAt(from: at, cause: SelectionChangedCause.tap);
    }
    field.toggleToolbar();
  }

  void onDoubleTapDown(TapDragDownDetails details) {
    field.selectWordsInRange(
      from: details.globalPosition,
      cause: SelectionChangedCause.doubleTap,
    );
    if (_showsToolbar) field.showToolbar();
  }

  void onTripleTapDown(TapDragDownDetails details) {
    _selectParagraphs(details.globalPosition, null, SelectionChangedCause.tap);
    if (_showsToolbar) field.showToolbar();
  }

  void onDragSelectionStart(TapDragStartDetails details) {
    _showsToolbar = _showsHandles = _byTouch(details.kind);
    _dragStartSelection = _selection;
    _dragStartScroll = _scroll;
    // A drag after a double or triple tap goes on from what the taps chose.
    if (_taps(details.consecutiveTapCount) > 1) return;
    final at = details.globalPosition;
    if (_shift && _selection.isValid) {
      return _apple
          ? _expand(at, SelectionChangedCause.drag)
          : _extend(at, SelectionChangedCause.drag);
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        if (_precise(details.kind)) {
          field.selectPositionAt(from: at, cause: SelectionChangedCause.drag);
        }
      case TargetPlatform.android || TargetPlatform.fuchsia:
        if (_precise(details.kind)) {
          field.selectPositionAt(from: at, cause: SelectionChangedCause.drag);
        } else if (details.kind != null && _focused) {
          field.selectPositionAt(from: at, cause: SelectionChangedCause.drag);
          _showMagnifier(at);
        }
      case TargetPlatform.linux ||
          TargetPlatform.macOS ||
          TargetPlatform.windows:
        field.selectPositionAt(from: at, cause: SelectionChangedCause.drag);
    }
  }

  void onDragSelectionUpdate(TapDragUpdateDetails details) {
    final at = details.globalPosition;
    if (_shift) return _shiftDrag(at);
    // Where the drag began, in the note as it now lies under the pointer.
    final from = at - details.offsetFromOrigin - _scrolled;
    final kind = details.kind;
    switch (_taps(details.consecutiveTapCount)) {
      case 2:
        field.selectWordsInRange(
          from: from,
          to: at,
          cause: SelectionChangedCause.drag,
        );
        if (kind != null && !_precise(kind)) _showMagnifier(at);
      case 3:
        if (_precise(kind) ||
            switch (defaultTargetPlatform) {
              TargetPlatform.android ||
              TargetPlatform.fuchsia ||
              TargetPlatform.iOS => false,
              _ => true,
            }) {
          _selectParagraphs(from, at, SelectionChangedCause.drag);
        }
      default:
        switch (defaultTargetPlatform) {
          case TargetPlatform.iOS:
            if (_precise(kind)) {
              field.selectPositionAt(
                from: from,
                to: at,
                cause: SelectionChangedCause.drag,
              );
            }
          case TargetPlatform.android || TargetPlatform.fuchsia:
            if (_precise(kind) ||
                kind == PointerDeviceKind.stylus ||
                kind == PointerDeviceKind.invertedStylus) {
              field.selectPositionAt(
                from: from,
                to: at,
                cause: SelectionChangedCause.drag,
              );
            } else if (kind != null && _focused) {
              field.selectPositionAt(
                from: at,
                cause: SelectionChangedCause.drag,
              );
              _showMagnifier(at);
            }
          case TargetPlatform.linux ||
              TargetPlatform.macOS ||
              TargetPlatform.windows:
            field.selectPositionAt(
              from: from,
              to: at,
              cause: SelectionChangedCause.drag,
            );
        }
    }
  }

  /// A drag with Shift held moves the selection's extent; on Apple's
  /// platforms, passing back over the selection's base swaps its ends, so
  /// that what was selected stays selected.
  void _shiftDrag(Offset at) {
    final start = _dragStartSelection!;
    if (start.isCollapsed || !_apple) {
      return _extend(at, SelectionChangedCause.drag);
    }
    final selection = _selection;
    final next = field.positionAt(at).offset;
    final inverted = start.baseOffset < start.extentOffset
        ? next < start.baseOffset
        : next > start.baseOffset;
    if (inverted && selection.baseOffset == start.baseOffset) {
      _select(
        TextSelection(baseOffset: start.extentOffset, extentOffset: next),
        SelectionChangedCause.drag,
      );
    } else if (!inverted &&
        next != start.baseOffset &&
        selection.baseOffset != start.baseOffset) {
      _select(
        TextSelection(baseOffset: start.baseOffset, extentOffset: next),
        SelectionChangedCause.drag,
      );
    } else {
      _extend(at, SelectionChangedCause.drag);
    }
  }

  void onDragSelectionEnd(TapDragEndDetails details) {
    if (_showsToolbar && _taps(details.consecutiveTapCount) == 2) {
      field.showToolbar();
    }
    if (_shift) _dragStartSelection = null;
    _hideMagnifier();
  }

  Widget build({required Widget child}) => TextSelectionGestureDetector(
    onTapTrackStart: onTapTrackStart,
    onTapTrackReset: onTapTrackReset,
    onTapDown: onTapDown,
    onSecondaryTap: onSecondaryTap,
    onSecondaryTapDown: onSecondaryTapDown,
    onSingleTapUp: onSingleTapUp,
    onSingleLongTapStart: onSingleLongTapStart,
    onSingleLongTapMoveUpdate: onSingleLongTapMoveUpdate,
    onSingleLongTapEnd: onSingleLongTapEnd,
    onSingleLongTapCancel: _endLongPress,
    onDoubleTapDown: onDoubleTapDown,
    onTripleTapDown: onTripleTapDown,
    onDragSelectionStart: onDragSelectionStart,
    onDragSelectionUpdate: onDragSelectionUpdate,
    onDragSelectionEnd: onDragSelectionEnd,
    behavior: HitTestBehavior.translucent,
    child: child,
  );
}
