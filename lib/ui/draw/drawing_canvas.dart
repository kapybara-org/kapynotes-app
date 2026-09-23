import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../data/note_drawing.dart';
import '../../data/notes_store.dart';
import '../compact_icon_button.dart';
import '../floating_surface.dart';
import '../mobile_page_swipe.dart';
import '../sidebar_swipe.dart';
import 'drawing_geometry.dart';
import 'drawing_painter.dart';
import 'note_mode_switch.dart';

/// What a pointer does on the canvas.
enum DrawTool {
  select('Select', 'V', KapyIcons.selectRounded),
  pan('Hand', 'H', KapyIcons.panRounded),
  pen('Pen', 'P', KapyIcons.penRounded),
  rect('Rectangle', 'R', KapyIcons.rectangleRounded),
  ellipse('Ellipse', 'O', KapyIcons.circleOutlined),
  arrow('Arrow', 'A', KapyIcons.arrowRounded),
  line('Line', 'L', KapyIcons.lineRounded),
  text('Text', 'T', KapyIcons.textFieldsRounded),
  eraser('Eraser', 'E', KapyIcons.eraserRounded);

  const DrawTool(this.label, this.key, this.icon);

  final String label;
  final String key;
  final KapyIconData icon;

  DrawKind? get kind => switch (this) {
    pen => DrawKind.pen,
    rect => DrawKind.rect,
    ellipse => DrawKind.ellipse,
    arrow => DrawKind.arrow,
    line => DrawKind.line,
    _ => null,
  };
}

/// Colours that read on the light paper and the dark one alike. Null is the
/// theme's ink, which is the one that has to flip.
const List<int?> drawColors = [
  null,
  0xFFE03131,
  0xFFF08C00,
  0xFF2F9E44,
  0xFF1971C2,
  0xFF7048E8,
];

const List<double> drawWidths = [2, 4, 8];

/// A minimal whiteboard: a title, an endless canvas, and a handful of tools.
///
/// The canvas owns the drawing while it is on screen and reports each change
/// once, when the gesture that made it ends — a stroke is one write, not one
/// per pointer move. A drawing that changes underneath it (another device, a
/// collaborator) is adopted as it arrives, and what this device's undo
/// remembers is per element, so undoing a stroke never undoes somebody
/// else's.
class DrawingCanvas extends StatefulWidget {
  const DrawingCanvas({
    super.key,
    required this.drawing,
    required this.title,
    required this.onChanged,
    required this.onTitleChanged,
    this.readOnly = false,
    this.onSwitchToWrite,
    this.onFocus,
  });

  final NoteDrawing drawing;
  final String title;
  final ValueChanged<NoteDrawing> onChanged;
  final ValueChanged<String> onTitleChanged;
  final bool readOnly;

  /// Offered only while the canvas and its title are both blank.
  final VoidCallback? onSwitchToWrite;

  final VoidCallback? onFocus;

  @override
  State<DrawingCanvas> createState() => DrawingCanvasState();
}

/// One step of undo: each touched element's value before and after. Null is
/// "not there".
typedef _Change = ({
  Map<String, DrawElement?> before,
  Map<String, DrawElement?> after,
});

sealed class _Gesture {}

class _Drafting extends _Gesture {
  _Drafting(this.element);
  DrawElement element;
}

class _Moving extends _Gesture {
  _Moving(this.start, this.originals);
  final Offset start;
  final Map<String, DrawElement> originals;
  Offset delta = Offset.zero;
}

class _Marquee extends _Gesture {
  _Marquee(this.start) : end = start;
  final Offset start;
  Offset end;
  Rect get rect => Rect.fromPoints(start, end);
}

class _Erasing extends _Gesture {
  final Set<String> ids = {};
  Offset? last;
}

class _Panning extends _Gesture {
  _Panning(this.lastScreen);
  Offset lastScreen;
}

class DrawingCanvasState extends State<DrawingCanvas> {
  static const double _minZoom = 0.1;
  static const double _maxZoom = 8;
  static const int _undoLimit = 200;

  // Set in initState rather than by `late` initialisers, which run on first
  // read: a first read inside didUpdateWidget would take the *new* widget's
  // drawing as the one already reported, and never adopt it.
  late NoteDrawing _drawing;
  late NoteDrawing _lastReported;

  final List<_Change> _undo = [];
  final List<_Change> _redo = [];

  DrawTool _tool = DrawTool.pen;
  int? _color;
  double _width = drawWidths[1];
  bool _styleOpen = false;

  Offset _pan = Offset.zero;
  double _zoom = 1;
  bool _fitted = false;
  Size _viewport = Size.zero;

  Set<String> _selected = {};
  _Gesture? _gesture;

  final Map<int, Offset> _pointers = {};
  ({double distance, Offset focal, double zoom, Offset pan})? _pinch;

  /// Set when a second finger turned a stroke into a pinch: the finger left
  /// behind must not start drawing again until every finger has lifted.
  bool _waitForAllUp = false;
  double _panZoomStartZoom = 1;
  bool _spaceHeld = false;

  // Text being typed onto the canvas.
  String? _textId;
  Offset? _textAt;
  final TextEditingController _textController = TextEditingController();
  final FocusNode _textFocus = FocusNode(debugLabel: 'drawing text');

  late final TextEditingController _titleController;
  final FocusNode _titleFocus = FocusNode(debugLabel: 'drawing title');
  final FocusNode _canvasFocus = FocusNode(debugLabel: 'drawing canvas');

  NoteDrawing get drawing => _drawing;
  DrawTool get tool => _tool;
  double get zoom => _zoom;
  Set<String> get selection => Set.unmodifiable(_selected);

  @override
  void initState() {
    super.initState();
    _drawing = widget.drawing;
    _lastReported = widget.drawing;
    _titleController = TextEditingController(text: widget.title);
    if (widget.readOnly) _tool = DrawTool.select;
    _textFocus.addListener(_onTextFocusChanged);
  }

  @override
  void didUpdateWidget(DrawingCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.drawing != _lastReported && widget.drawing != _drawing) {
      // Somebody else's change. Adopt it; anything selected that went away
      // goes out of the selection with it.
      _drawing = widget.drawing;
      _lastReported = widget.drawing;
      _selected = {
        for (final id in _selected)
          if (_drawing.byId(id) != null) id,
      };
    }
    if (!_titleFocus.hasFocus && widget.title != _titleController.text) {
      _titleController.text = widget.title;
    }
    if (widget.readOnly && !oldWidget.readOnly) {
      _tool = DrawTool.select;
      _gesture = null;
    }
  }

  void _onTextFocusChanged() {
    if (!_textFocus.hasFocus) _commitText();
  }

  @override
  void dispose() {
    // Leaving the note while typing on the canvas must not report the words
    // from a widget that is already coming out of the tree.
    _textFocus.removeListener(_onTextFocusChanged);
    _textController.dispose();
    _textFocus.dispose();
    _titleController.dispose();
    _titleFocus.dispose();
    _canvasFocus.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Changes and history

  void _apply(Map<String, DrawElement?> after, {bool record = true}) {
    if (after.isEmpty) return;
    final before = {for (final id in after.keys) id: _drawing.byId(id)};
    if (_sameValues(before, after)) return;
    _drawing = _drawing
        .remove([
          for (final e in after.entries)
            if (e.value == null) e.key,
        ])
        .upsert(after.values.whereType<DrawElement>());
    if (record) {
      _undo.add((before: before, after: after));
      if (_undo.length > _undoLimit) _undo.removeAt(0);
      _redo.clear();
    }
    _report();
  }

  static bool _sameValues(
    Map<String, DrawElement?> a,
    Map<String, DrawElement?> b,
  ) => a.keys.every((id) => a[id] == b[id]);

  void _report() {
    _lastReported = _drawing;
    widget.onChanged(_drawing);
  }

  void undo() {
    if (_undo.isEmpty || widget.readOnly) return;
    final change = _undo.removeLast();
    setState(() {
      _apply(change.before, record: false);
      _redo.add(change);
      _selected = {};
    });
  }

  void redo() {
    if (_redo.isEmpty || widget.readOnly) return;
    final change = _redo.removeLast();
    setState(() {
      _apply(change.after, record: false);
      _undo.add(change);
      _selected = {};
    });
  }

  void deleteSelection() {
    if (_selected.isEmpty || widget.readOnly) return;
    setState(() {
      _apply({for (final id in _selected) id: null});
      _selected = {};
    });
  }

  void selectTool(DrawTool tool) {
    if (widget.readOnly && tool != DrawTool.select && tool != DrawTool.pan) {
      return;
    }
    _commitText();
    setState(() {
      _tool = tool;
      _styleOpen = false;
      if (tool != DrawTool.select) _selected = {};
    });
  }

  void _setColor(int? color) {
    setState(() {
      _color = color;
      _restyleSelection((e) => e.copyWith(color: color));
    });
  }

  void _setWidth(double width) {
    setState(() {
      _width = width;
      _restyleSelection(
        (e) => e.kind == DrawKind.text
            ? e.copyWith(fontSize: _fontSizeFor(width))
            : e.copyWith(width: width),
      );
    });
  }

  void _restyleSelection(DrawElement Function(DrawElement) restyle) {
    if (_selected.isEmpty || widget.readOnly) return;
    _apply({
      for (final id in _selected)
        if (_drawing.byId(id) case final element?) id: restyle(element),
    });
  }

  static double _fontSizeFor(double width) => switch (width) {
    <= 2 => 16,
    <= 4 => 24,
    _ => 36,
  };

  // ---------------------------------------------------------------------------
  // Viewport

  Offset _toCanvas(Offset screen) => (screen - _pan) / _zoom;

  Offset _toScreen(Offset canvas) => canvas * _zoom + _pan;

  void _zoomAbout(Offset screen, double zoom) {
    final clamped = zoom.clamp(_minZoom, _maxZoom);
    final anchor = _toCanvas(screen);
    _zoom = clamped;
    _pan = screen - anchor * _zoom;
  }

  /// Frames everything drawn, or goes back to the origin at 100% when there
  /// is nothing to frame.
  void fitToContent() {
    final bounds = _drawing.isEmpty ? null : drawingBounds(_drawing.elements);
    setState(() {
      if (bounds == null || _viewport.isEmpty) {
        _zoom = 1;
        _pan = Offset.zero;
        return;
      }
      const margin = 48.0;
      final room = Size(
        math.max(1, _viewport.width - margin * 2),
        math.max(1, _viewport.height - margin * 2 - 64),
      );
      _zoom = math
          .min(room.width / bounds.width, room.height / bounds.height)
          .clamp(_minZoom, 1.0);
      _pan =
          Offset(_viewport.width / 2, (_viewport.height - 64) / 2) -
          bounds.center * _zoom;
    });
  }

  // ---------------------------------------------------------------------------
  // Pointers

  void _onPointerDown(PointerDownEvent event) {
    widget.onFocus?.call();
    if (_textId != null) {
      // A tap away from the text being typed finishes it, and does nothing
      // else: nobody means that same tap to start a stroke.
      _commitText();
      _waitForAllUp = true;
    }
    if (!_titleFocus.hasFocus || event.kind != PointerDeviceKind.touch) {
      _canvasFocus.requestFocus();
    }
    _pointers[event.pointer] = event.localPosition;
    if (_styleOpen) setState(() => _styleOpen = false);

    if (_pointers.length == 2) {
      _cancelGesture();
      final points = _pointers.values.toList();
      _pinch = (
        distance: math.max(1, (points[0] - points[1]).distance),
        focal: (points[0] + points[1]) / 2,
        zoom: _zoom,
        pan: _pan,
      );
      _waitForAllUp = true;
      return;
    }
    if (_pointers.length > 2 || _waitForAllUp) return;

    final panning =
        _tool == DrawTool.pan ||
        _spaceHeld ||
        event.buttons & kMiddleMouseButton != 0;
    if (panning) {
      _gesture = _Panning(event.localPosition);
      return;
    }
    if (event.buttons & kSecondaryMouseButton != 0) return;
    _begin(_toCanvas(event.localPosition), shift: _shiftHeld);
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers[event.pointer] = event.localPosition;
    final pinch = _pinch;
    if (pinch != null && _pointers.length >= 2) {
      final points = _pointers.values.take(2).toList();
      final distance = math.max(1.0, (points[0] - points[1]).distance);
      final focal = (points[0] + points[1]) / 2;
      final zoom = (pinch.zoom * distance / pinch.distance).clamp(
        _minZoom,
        _maxZoom,
      );
      final anchor = (pinch.focal - pinch.pan) / pinch.zoom;
      setState(() {
        _zoom = zoom;
        _pan = focal - anchor * zoom;
      });
      return;
    }
    final gesture = _gesture;
    if (gesture is _Panning) {
      setState(() {
        _pan += event.localPosition - gesture.lastScreen;
        gesture.lastScreen = event.localPosition;
      });
      return;
    }
    if (gesture != null) {
      _update(gesture, _toCanvas(event.localPosition), shift: _shiftHeld);
    }
  }

  void _onPointerUp(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.length < 2) _pinch = null;
    if (_pointers.isEmpty) _waitForAllUp = false;
    final gesture = _gesture;
    if (gesture == null) return;
    _gesture = null;
    if (event is PointerCancelEvent) {
      _cancel(gesture);
    } else {
      _end(gesture);
    }
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      final keys = HardwareKeyboard.instance;
      setState(() {
        if (keys.isControlPressed || keys.isMetaPressed) {
          _zoomAbout(
            event.localPosition,
            _zoom * math.exp(-event.scrollDelta.dy / 300),
          );
        } else {
          _pan -= keys.isShiftPressed && event.scrollDelta.dx == 0
              ? Offset(event.scrollDelta.dy, 0)
              : event.scrollDelta;
        }
      });
    } else if (event is PointerScaleEvent) {
      setState(() => _zoomAbout(event.localPosition, _zoom * event.scale));
    }
  }

  void _onPanZoomStart(PointerPanZoomStartEvent event) {
    _panZoomStartZoom = _zoom;
  }

  void _onPanZoomUpdate(PointerPanZoomUpdateEvent event) {
    setState(() {
      if (event.scale != 1) {
        _zoomAbout(event.localPosition, _panZoomStartZoom * event.scale);
      }
      _pan += event.panDelta;
    });
  }

  bool get _shiftHeld => HardwareKeyboard.instance.isShiftPressed;

  double get _tolerance => 8 / _zoom;

  void _begin(Offset at, {required bool shift}) {
    if (widget.readOnly && _tool != DrawTool.select) return;
    switch (_tool) {
      case DrawTool.select:
        final hit = hitTestElements(_drawing.elements, at, _tolerance);
        if (widget.readOnly) {
          setState(() => _selected = hit == null ? {} : {hit.id});
          return;
        }
        if (hit == null) {
          if (!shift) setState(() => _selected = {});
          _gesture = _Marquee(at);
          return;
        }
        setState(() {
          if (shift) {
            _selected = _selected.contains(hit.id)
                ? ({..._selected}..remove(hit.id))
                : {..._selected, hit.id};
          } else if (!_selected.contains(hit.id)) {
            _selected = {hit.id};
          }
        });
        _gesture = _Moving(at, {
          for (final id in _selected) id: ?_drawing.byId(id),
        });
      case DrawTool.eraser:
        final gesture = _Erasing();
        _gesture = gesture;
        _erase(gesture, at);
      case DrawTool.text:
        final hit = hitTestElements(_drawing.elements, at, _tolerance);
        if (hit != null && hit.kind == DrawKind.text) {
          _editText(hit);
        } else {
          _startText(at);
        }
      case DrawTool.pan:
        break;
      case DrawTool.pen ||
          DrawTool.rect ||
          DrawTool.ellipse ||
          DrawTool.arrow ||
          DrawTool.line:
        setState(() {
          _gesture = _Drafting(
            DrawElement(
              id: NotesStore.newId(),
              kind: _tool.kind!,
              points: _tool == DrawTool.pen
                  ? [at.dx, at.dy]
                  : [at.dx, at.dy, at.dx, at.dy],
              z: _drawing.nextZ,
              color: _color,
              width: _width,
            ),
          );
        });
    }
  }

  void _update(_Gesture gesture, Offset at, {required bool shift}) {
    switch (gesture) {
      case _Drafting():
        final element = gesture.element;
        setState(() {
          if (element.kind == DrawKind.pen) {
            final last = element.pointAt(element.pointCount - 1);
            // Points closer than a pixel on screen add bytes, not shape.
            if ((last - at).distance * _zoom < 1.5) return;
            gesture.element = element.copyWith(
              points: [...element.points, at.dx, at.dy],
            );
          } else {
            final start = element.pointAt(0);
            gesture.element = element.copyWith(
              points: [
                start.dx,
                start.dy,
                ...constrainEnd(element.kind, start, at, shift: shift).asList,
              ],
            );
          }
        });
      case _Moving():
        setState(() => gesture.delta = at - gesture.start);
      case _Marquee():
        setState(() => gesture.end = at);
      case _Erasing():
        _erase(gesture, at);
      case _Panning():
        break;
    }
  }

  void _end(_Gesture gesture) {
    switch (gesture) {
      case _Drafting():
        final element = gesture.element;
        final size = element.bounds.size;
        final tiny = size.width * _zoom < 2 && size.height * _zoom < 2;
        setState(() {
          if (element.kind == DrawKind.pen) {
            // A tap with the pen is a dot, and a dot is a stroke.
            _apply({element.id: element});
          } else if (!tiny) {
            _apply({element.id: element});
          }
        });
      case _Moving():
        setState(() {
          if (gesture.delta != Offset.zero) {
            _apply({
              for (final e in gesture.originals.entries)
                e.key: e.value.translated(gesture.delta),
            });
          }
        });
      case _Marquee():
        final area = gesture.rect;
        setState(() {
          final inside = {
            for (final element in _drawing.elements)
              if (area.contains(elementBounds(element).topLeft) &&
                  area.contains(elementBounds(element).bottomRight))
                element.id,
          };
          _selected = _shiftHeld ? {..._selected, ...inside} : inside;
        });
      case _Erasing():
        setState(() => _apply({for (final id in gesture.ids) id: null}));
      case _Panning():
        break;
    }
  }

  void _cancel(_Gesture gesture) {
    setState(() {});
  }

  void _cancelGesture() {
    final gesture = _gesture;
    _gesture = null;
    if (gesture != null) _cancel(gesture);
  }

  /// Erases along the path since the last pointer event, not just at its
  /// ends: a quick swipe moves further between two events than any stroke
  /// is wide, and would otherwise pass straight through it.
  void _erase(_Erasing gesture, Offset at) {
    final from = gesture.last ?? at;
    gesture.last = at;
    final step = _tolerance;
    final steps = math.max(1, ((at - from).distance / step).ceil());
    final found = <String>{};
    for (var i = 0; i <= steps; i++) {
      final point = Offset.lerp(from, at, i / steps)!;
      final hit = hitTestElements(
        _drawing.elements.where(
          (e) => !gesture.ids.contains(e.id) && !found.contains(e.id),
        ),
        point,
        _tolerance * 1.5,
      );
      if (hit != null) found.add(hit.id);
    }
    if (found.isNotEmpty) setState(() => gesture.ids.addAll(found));
  }

  // ---------------------------------------------------------------------------
  // Text

  void _startText(Offset at) {
    setState(() {
      _textId = NotesStore.newId();
      _textAt = at;
      _textController.text = '';
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _textFocus.requestFocus();
    });
  }

  void _editText(DrawElement element) {
    setState(() {
      _textId = element.id;
      _textAt = element.pointAt(0);
      _textController.text = element.text;
      _selected = {};
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _textFocus.requestFocus();
    });
  }

  void _commitText() {
    final id = _textId;
    final at = _textAt;
    if (id == null || at == null) return;
    _textId = null;
    _textAt = null;
    final text = _textController.text.trimRight();
    final existing = _drawing.byId(id);
    setState(() {
      if (text.trim().isEmpty) {
        if (existing != null) _apply({id: null});
      } else {
        _apply({
          id:
              existing?.copyWith(text: text) ??
              DrawElement(
                id: id,
                kind: DrawKind.text,
                points: [at.dx, at.dy],
                z: _drawing.nextZ,
                color: _color,
                text: text,
                fontSize: _fontSizeFor(_width),
              ),
        });
        if (existing == null) {
          _tool = DrawTool.select;
          _selected = {id};
        }
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Keys

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.space) {
      _spaceHeld = event is! KeyUpEvent;
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final command = (AppPlatform.isMacOS || AppPlatform.isIOS)
        ? keys.isMetaPressed
        : keys.isControlPressed;
    final key = event.logicalKey;

    if (command && key == LogicalKeyboardKey.keyZ) {
      keys.isShiftPressed ? redo() : undo();
      return KeyEventResult.handled;
    }
    if (command && key == LogicalKeyboardKey.keyY) {
      redo();
      return KeyEventResult.handled;
    }
    if (command && key == LogicalKeyboardKey.keyA) {
      setState(() {
        _tool = DrawTool.select;
        _selected = {for (final e in _drawing.elements) e.id};
      });
      return KeyEventResult.handled;
    }
    if (command || keys.isAltPressed) return KeyEventResult.ignored;

    if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      if (_selected.isEmpty) return KeyEventResult.ignored;
      deleteSelection();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (_selected.isEmpty && _tool == DrawTool.select) {
        return KeyEventResult.ignored;
      }
      setState(() {
        _selected = {};
        _tool = DrawTool.select;
      });
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter && _selected.length == 1) {
      final element = _drawing.byId(_selected.single);
      if (element?.kind == DrawKind.text && !widget.readOnly) {
        _editText(element!);
        return KeyEventResult.handled;
      }
    }
    final label = event.character?.toUpperCase();
    for (final tool in DrawTool.values) {
      if (tool.key == label) {
        selectTool(tool);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  // ---------------------------------------------------------------------------
  // Build

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final ink = palette.textPrimary;
    final gesture = _gesture;

    final hidden = <String>{
      ?_textId,
      if (gesture is _Erasing) ...gesture.ids,
      if (gesture is _Moving) ...gesture.originals.keys,
    };
    final extra = <DrawElement>[
      if (gesture is _Drafting) gesture.element,
      if (gesture is _Moving)
        for (final e in gesture.originals.values) e.translated(gesture.delta),
    ];
    final selectionBoxes = [
      for (final id in _selected)
        if (gesture is _Moving && gesture.originals[id] != null)
          elementBounds(gesture.originals[id]!.translated(gesture.delta))
        else if (_drawing.byId(id) case final element?)
          elementBounds(element),
    ];

    final canvas = LayoutBuilder(
      builder: (context, constraints) {
        _viewport = constraints.biggest;
        if (!_fitted && !_viewport.isEmpty) {
          _fitted = true;
          if (!_drawing.isEmpty) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) fitToContent();
            });
          }
        }
        return Focus(
          focusNode: _canvasFocus,
          onKeyEvent: _onKey,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerCancel: _onPointerUp,
            onPointerSignal: _onPointerSignal,
            onPointerPanZoomStart: _onPanZoomStart,
            onPointerPanZoomUpdate: _onPanZoomUpdate,
            child: MouseRegion(
              cursor: _cursor,
              child: CustomPaint(
                key: const ValueKey('drawing-surface'),
                size: Size.infinite,
                painter: DrawingPainter(
                  elements: _drawing.elements,
                  hidden: hidden,
                  extra: extra,
                  selection: selectionBoxes,
                  marquee: gesture is _Marquee ? gesture.rect : null,
                  pan: _pan,
                  zoom: _zoom,
                  ink: ink,
                  grid: palette.separator.withValues(alpha: 0.5),
                  accent: Theme.of(context).colorScheme.primary,
                  textStyle: _textStyle(context),
                ),
              ),
            ),
          ),
        );
      },
    );

    return ColoredBox(
      color: palette.paperColor,
      child: Stack(
        children: [
          // Every stroke and pan belongs to the canvas: neither a phone's
          // page swipe nor a desktop's sidebar swipe may take one.
          Positioned.fill(
            child: SidebarSwipeExclusion(
              child: PageSwipeExclusion(child: canvas),
            ),
          ),
          if (_textId != null && _textAt != null) _buildTextField(context),
          Positioned(left: 0, right: 0, top: 0, child: _buildHeader(context)),
          if (!widget.readOnly && _drawing.isEmpty && _gesture == null)
            const Positioned.fill(child: IgnorePointer(child: _EmptyHint())),
          Positioned(
            left: 8,
            right: 8,
            bottom: 12 + MediaQuery.paddingOf(context).bottom,
            child: _buildToolbar(context),
          ),
        ],
      ),
    );
  }

  MouseCursor get _cursor {
    if (_gesture is _Panning) return SystemMouseCursors.grabbing;
    if (_spaceHeld || _tool == DrawTool.pan) return SystemMouseCursors.grab;
    return switch (_tool) {
      DrawTool.select => SystemMouseCursors.basic,
      DrawTool.text => SystemMouseCursors.text,
      _ => SystemMouseCursors.precise,
    };
  }

  TextStyle _textStyle(BuildContext context) =>
      (Theme.of(context).textTheme.bodyLarge ?? const TextStyle()).copyWith(
        height: 1.25,
        decoration: TextDecoration.none,
      );

  Widget _buildHeader(BuildContext context) {
    final palette = context.palette;
    final touch = !AppPlatform.hasPointer;
    return Padding(
      padding: EdgeInsets.fromLTRB(touch ? 16 : 24, 10, 12, 0),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('drawing-title'),
              controller: _titleController,
              focusNode: _titleFocus,
              readOnly: widget.readOnly,
              maxLines: 1,
              textInputAction: TextInputAction.done,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: palette.textPrimary,
                fontWeight: FontWeight.w600,
              ),
              decoration: InputDecoration(
                hintText: 'Untitled drawing',
                hintStyle: TextStyle(color: palette.textTertiary),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
              ),
              onChanged: widget.onTitleChanged,
              onSubmitted: (_) => _canvasFocus.requestFocus(),
            ),
          ),
          if (widget.onSwitchToWrite != null &&
              _drawing.isEmpty &&
              _titleController.text.trim().isEmpty)
            NoteModeSwitch(
              drawing: true,
              onChanged: (drawing) {
                if (!drawing) widget.onSwitchToWrite!();
              },
            ),
        ],
      ),
    );
  }

  Widget _buildTextField(BuildContext context) {
    final at = _toScreen(_textAt!);
    final existing = _drawing.byId(_textId!);
    final fontSize = (existing?.fontSize ?? _fontSizeFor(_width)) * _zoom;
    final color = existing?.color ?? _color;
    return Positioned(
      left: at.dx,
      top: at.dy,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: 40,
          maxWidth: math.max(120, _viewport.width - at.dx - 16),
        ),
        child: IntrinsicWidth(
          child: TextField(
            key: const ValueKey('drawing-text-field'),
            controller: _textController,
            focusNode: _textFocus,
            maxLines: null,
            keyboardType: TextInputType.multiline,
            style: _textStyle(context).copyWith(
              fontSize: fontSize,
              color: color == null ? context.palette.textPrimary : Color(color),
            ),
            cursorColor: Theme.of(context).colorScheme.primary,
            decoration: const InputDecoration(
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              filled: false,
              isCollapsed: true,
              contentPadding: EdgeInsets.zero,
            ),
            onTapOutside: (_) => _textFocus.unfocus(),
          ),
        ),
      ),
    );
  }

  Widget _buildToolbar(BuildContext context) {
    final palette = context.palette;
    final touch = !AppPlatform.hasPointer;
    // Two fingers already pan on a touch screen, and a phone has no room for
    // a tool that only repeats them.
    final tools = [
      for (final tool
          in widget.readOnly
              ? const [DrawTool.select, DrawTool.pan]
              : DrawTool.values)
        if (!(touch && tool == DrawTool.pan && !widget.readOnly)) tool,
    ];
    final divider = Container(
      width: 1,
      height: 20,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: palette.separator,
    );

    final toolButtons = [
      for (final tool in tools)
        CompactIconButton(
          key: ValueKey('draw-tool-${tool.name}'),
          icon: KapyIcon(tool.icon),
          tooltip: touch ? tool.label : '${tool.label} · ${tool.key}',
          selected: _tool == tool,
          onPressed: () => selectTool(tool),
          // Each button is already a 44pt target on touch; the padding
          // around it is what pushed the last tool off a phone.
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
    ];
    final actions = [
      if (!widget.readOnly) ...[
        CompactIconButton(
          key: const ValueKey('draw-style'),
          tooltip: 'Colour and size',
          selected: _styleOpen,
          onPressed: () => setState(() => _styleOpen = !_styleOpen),
          icon: _Swatch(
            color: _color == null ? palette.textPrimary : Color(_color!),
            size: 6 + _width * 1.2,
          ),
        ),
        divider,
        CompactIconButton(
          key: const ValueKey('draw-undo'),
          icon: const KapyIcon(KapyIcons.undoRounded),
          tooltip: 'Undo',
          onPressed: _undo.isEmpty ? null : undo,
        ),
        CompactIconButton(
          key: const ValueKey('draw-redo'),
          icon: const KapyIcon(KapyIcons.redoRounded),
          tooltip: 'Redo',
          onPressed: _redo.isEmpty ? null : redo,
        ),
        if (_selected.isNotEmpty)
          CompactIconButton(
            key: const ValueKey('draw-delete'),
            icon: const KapyIcon(KapyIcons.deleteOutlined),
            tooltip: 'Delete',
            onPressed: deleteSelection,
          ),
        divider,
      ],
      Tooltip(
        message: 'Zoom to fit',
        child: TextButton(
          key: const ValueKey('draw-zoom'),
          onPressed: fitToContent,
          style: TextButton.styleFrom(
            minimumSize: Size(52, AppControlMetrics.iconButtonExtent),
            padding: const EdgeInsets.symmetric(horizontal: 6),
            foregroundColor: palette.textSecondary,
            textStyle: Theme.of(context).textTheme.labelMedium?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          child: Text('${(_zoom * 100).round()}%'),
        ),
      ),
    ];

    Widget bar(List<Widget> children) => FloatingSurface(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );

    // One bar where it fits; on a phone the tools get a row to themselves
    // and everything else sits above them, closer to the drawing.
    return LayoutBuilder(
      builder: (context, constraints) {
        final oneRow =
            constraints.maxWidth >=
            (tools.length + 6) * AppControlMetrics.iconButtonExtent + 120;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_styleOpen && !widget.readOnly) ...[
              _StylePanel(
                color: _color,
                width: _width,
                onColor: _setColor,
                onWidth: _setWidth,
              ),
              const SizedBox(height: 8),
            ],
            if (oneRow)
              Center(child: bar([...toolButtons, divider, ...actions]))
            else ...[
              Center(child: bar(actions)),
              const SizedBox(height: 8),
              Center(child: bar(toolButtons)),
            ],
          ],
        );
      },
    );
  }
}

class _StylePanel extends StatelessWidget {
  const _StylePanel({
    required this.color,
    required this.width,
    required this.onColor,
    required this.onWidth,
  });

  final int? color;
  final double width;
  final ValueChanged<int?> onColor;
  final ValueChanged<double> onWidth;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return FloatingSurface(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      // Wraps rather than overflowing: six colours and three sizes are wider
      // than a phone.
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        runSpacing: 4,
        children: [
          for (final option in drawColors)
            CompactIconButton(
              key: ValueKey('draw-color-${option ?? 'ink'}'),
              tooltip: option == null ? 'Ink' : 'Colour',
              selected: option == color,
              onPressed: () => onColor(option),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              icon: _Swatch(
                color: option == null ? palette.textPrimary : Color(option),
                size: 14,
              ),
            ),
          Container(
            width: 1,
            height: 20,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            color: palette.separator,
          ),
          for (final option in drawWidths)
            CompactIconButton(
              key: ValueKey('draw-width-${option.round()}'),
              tooltip: switch (option) {
                <= 2 => 'Thin',
                <= 4 => 'Medium',
                _ => 'Bold',
              },
              selected: option == width,
              onPressed: () => onWidth(option),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              icon: Container(
                width: 16,
                height: option,
                decoration: BoxDecoration(
                  color: palette.textPrimary,
                  borderRadius: BorderRadius.circular(option),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final touch = !AppPlatform.hasPointer;
    return Center(
      child: Text(
        touch
            ? 'Draw with a finger · pinch to zoom'
            : 'Draw anywhere · scroll to pan · ${(AppPlatform.isMacOS || AppPlatform.isIOS) ? '⌘' : 'Ctrl'}-scroll to zoom',
        style: TextStyle(color: palette.textTertiary, fontSize: 13),
      ),
    );
  }
}
