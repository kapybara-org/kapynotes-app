import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show BoxHeightStyle;

import 'package:cupertino_ui/cupertino_ui.dart'
    show
        cupertinoDesktopTextSelectionHandleControls,
        cupertinoTextSelectionHandleControls;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'highlighting_controller.dart';
import 'note_gestures.dart';
import 'note_lines.dart';
import 'note_sliver.dart';

/// The note's text field.
///
/// Its lines are laid out one paragraph each, and only where they show (see
/// [NoteSliver]). The platform's text input holds a window of the note around
/// the selection rather than the whole of it, which is what keeps a key's
/// cost in the platform from growing with the note: about 4 KB, widened to
/// whole lines, moved when the selection nears its edge and never while
/// something is being composed.
class NoteField extends StatefulWidget {
  const NoteField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.scrollController,
    required this.style,
    required this.strut,
    this.readOnly = false,
    this.autofocus = false,
    this.inputFormatters = const [],
    this.undoController,
    this.cursorColor,
    this.cursorWidth = 2,
    this.cursorHeight,
    this.cursorRadius,
    this.mouseCursor = SystemMouseCursors.text,
    this.contextMenuBuilder,
    this.magnifierConfiguration,
    this.columnWidth,
    this.trailingOf,
    this.selectionOf,
    this.adjustSpan,
  });

  final HighlightingController controller;
  final FocusNode focusNode;
  final ScrollController scrollController;

  /// The note's base style: what an unstyled run is drawn in.
  final TextStyle style;

  final StrutStyle strut;
  final bool readOnly;
  final bool autofocus;

  /// Run over every change the user makes, in order, before it lands.
  final List<TextInputFormatter> inputFormatters;

  final UndoHistoryController? undoController;

  /// The caret's colour: the selection style's, or the theme's, when null.
  final Color? cursorColor;

  final double cursorWidth;

  /// The caret's height: a row of [style] when null.
  final double? cursorHeight;

  /// The rounding of the caret's corners: two pixels on Apple's platforms
  /// when null, as [TextField] has it.
  final Radius? cursorRadius;

  final MouseCursor mouseCursor;

  /// Builds the toolbar that a secondary click, a long press or a double
  /// tap opens: the platform's own, with [NoteFieldState]'s editing items,
  /// when null.
  final Widget Function(BuildContext context, NoteFieldState field)?
  contextMenuBuilder;

  /// The magnifier shown while a finger moves the selection: the
  /// platform's, as [TextField] shows it, when null.
  final TextMagnifierConfiguration? magnifierConfiguration;

  /// How wide the writing runs, when the field is wider: past it is room for
  /// what [trailingOf] shows. The field's width, less room at the end of each
  /// row for the caret, when null.
  final double? columnWidth;

  /// What a line shows past its writing, such as a calculation's result,
  /// built while the line is in view.
  final LineTrailing? Function(int line)? trailingOf;

  /// Rewrites a line's span after the note's own styling. Used to hide a
  /// task's details when they are folded, without changing the note.
  final LineSpan Function(int start, int end, LineSpan span)? adjustSpan;

  /// Where the selection shows on a line its writing doesn't draw: see
  /// [NoteLayout.selectionOf].
  final List<Rect>? Function(int line, TextRange selected)? selectionOf;

  @override
  State<NoteField> createState() => NoteFieldState();
}

/// Characters the platform is sent either side of the selection.
const _margin = 2048;

/// How near the window's edge the selection may come before the window moves.
const _edge = _margin ~/ 4;

/// What the platform holds, and where it starts in the note.
typedef _Remote = ({int start, TextEditingValue value});

/// How long the caret is shown, and then hidden, as it blinks.
const _blinkHalfPeriod = Duration(milliseconds: 500);

/// How long the caret blinks on Linux after the last key or move before it
/// stays on, as GTK's own fields do (its gtk-cursor-blink-timeout). Each blink
/// draws the whole window again, which a machine without a graphics card
/// pays for on the processor, so an idle window should draw nothing.
const _linuxBlinkTimeout = Duration(seconds: 10);

bool get _apple => switch (defaultTargetPlatform) {
  TargetPlatform.iOS || TargetPlatform.macOS => true,
  _ => false,
};

bool get _desktop => switch (defaultTargetPlatform) {
  TargetPlatform.linux ||
  TargetPlatform.macOS ||
  TargetPlatform.windows => true,
  _ => false,
};

class NoteFieldState extends State<NoteField>
    with
        SingleTickerProviderStateMixin,
        TextInputClient,
        DeltaTextInputClient,
        WidgetsBindingObserver
    implements TextLayoutMetrics {
  /// The note as the field lays it out, kept equal to the controller's text.
  late final NoteLines _lines = NoteLines(_text);
  late String _text = widget.controller.text;

  NoteLayout? _layout;
  LineSpan Function(int start, int end)? _spansIn;

  /// The stretch of the note the platform is sent.
  TextRange _window = TextRange.empty;

  /// What the platform holds, as far as the field knows, and where it starts
  /// in the note; and what it held before the last editing state the field
  /// sent it, which a key typed before that state arrived is made against.
  _Remote? _remote;
  _Remote? _previousRemote;

  TextInputConnection? _connection;
  bool _afterFrameScheduled = false;
  bool _revealScheduled = false;

  /// The caret's opacity as it blinks, and what times the blink. The timer
  /// stays set, cancelled, while the caret rests on Linux, so that the next
  /// key or move starts the blink again.
  late final AnimationController _blink = AnimationController(vsync: this)
    ..addListener(_mark);
  Timer? _blinkTimer;

  /// Whether the field's tickers run: the caret stops blinking while they
  /// don't, as on a route that is covered.
  bool _tickersEnabled = true;

  /// How the caret and the selection are drawn, from the theme, once built.
  NoteCaret? _caret;
  late Color _cursorColor;
  late Color _selectionColor;

  /// The pointer gestures over the lines.
  late final NoteGestures _gestures = NoteGestures(this);

  /// Where the last secondary tap went down, which the toolbar it opens
  /// points at.
  Offset? lastSecondaryTapDownPosition;

  /// The selection handles, the toolbar and the magnifier, made by the first
  /// change to the selection after the field gains focus; and what the
  /// handles and the toolbar follow.
  SelectionOverlay? _overlay;
  final _startLink = LayerLink();
  final _endLink = LayerLink();
  final _toolbarLink = LayerLink();

  /// Whether the last change to the selection called for the handles. Each
  /// shows while its end of the selection is in view, and the toolbar while
  /// either is.
  bool _handlesWanted = false;
  final _startHandleShows = ValueNotifier(false);
  final _endHandleShows = ValueNotifier(false);
  final _toolbarShows = ValueNotifier(false);

  /// Whether the clipboard holds anything to paste, for the toolbar.
  final clipboardStatus = ClipboardStatusNotifier();

  /// While a handle is dragged: on Apple's platforms the selection when the
  /// drag began, whose other end stays put; where the handle is, moved a
  /// row at a time; and how far the middle of its row is from the pointer.
  TextSelection? _handleDragStartSelection;
  double _handleDragY = 0;
  double _handleDragToRow = 0;

  /// Whether the change under way moved the selection's base by a drag,
  /// which then shows the base rather than the extent, off Apple's
  /// platforms.
  bool _revealBase = false;

  /// The caret's distance from the left of its line when a run of up and down
  /// moves began, and the selection the last of them left.
  ({double x, TextSelection selection})? _verticalRun;

  HighlightingController get _controller => widget.controller;
  TextEditingValue get _value => _controller.value;

  /// The note's lines and their layout, for the editor around the field.
  NoteLines get lines => _lines;

  NoteLayout get layout => _layout!;

  bool get _hasConnection => _connection?.attached ?? false;

  bool get _composing =>
      _value.composing.isValid && !_value.composing.isCollapsed;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_didChangeValue);
    widget.focusNode.addListener(_didChangeFocus);
    clipboardStatus.addListener(_rebuildOverlay);
    _window = _placeWindow();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensureLayout();
    final tickersEnabled = TickerMode.valuesOf(context).enabled;
    if (tickersEnabled != _tickersEnabled) {
      _tickersEnabled = tickersEnabled;
      _startOrStopBlink();
    }
  }

  @override
  void didUpdateWidget(NoteField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_didChangeValue);
      widget.controller.addListener(_didChangeValue);
      _didChangeValue();
    }
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_didChangeFocus);
      widget.focusNode.addListener(_didChangeFocus);
    }
    if (widget.readOnly && !oldWidget.readOnly) _closeConnection();
    if (!widget.readOnly && oldWidget.readOnly) _didChangeFocus();
    _startOrStopBlink();
    _ensureLayout();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_didChangeValue);
    widget.focusNode.removeListener(_didChangeFocus);
    _closeConnection();
    _blinkTimer?.cancel();
    _blink.dispose();
    _overlay?.dispose();
    _words?.painter.dispose();
    _words = null;
    clipboardStatus.dispose();
    _startHandleShows.dispose();
    _endHandleShows.dispose();
    _toolbarShows.dispose();
    super.dispose();
  }

  /// A layout for the style, strut and text scale the field has now; a new
  /// one when any of them changes, since every line's paragraph does too.
  void _ensureLayout() {
    final scaler = MediaQuery.textScalerOf(context);
    final current = _layout;
    final caretRoom = 1 + widget.cursorWidth;
    if (current != null &&
        current.style == widget.style &&
        current.strut == widget.strut &&
        current.scaler == scaler &&
        current.caretRoom == caretRoom) {
      return;
    }
    _layout = NoteLayout(
      lines: _lines,
      spanOf: (line) => _spansIn!(_lines.startOf(line), _lines.endOf(line)),
      style: widget.style,
      strut: widget.strut,
      scaler: scaler,
      caretRoom: caretRoom,
    );
  }

  // The note's text, kept in step with the controller.

  void _didChangeValue() {
    if (widget.focusNode.hasFocus && !_value.selection.isValid) {
      _controller.removeListener(_didChangeValue);
      _controller.selection = TextSelection.collapsed(
        offset: _controller.text.length,
      );
      _controller.addListener(_didChangeValue);
    }
    final text = _controller.text;
    if (!identical(text, _text) && text != _text) {
      var start = 0;
      final shorter = math.min(text.length, _text.length);
      while (start < shorter &&
          text.codeUnitAt(start) == _text.codeUnitAt(start)) {
        start++;
      }
      var end = 0;
      while (end < shorter - start &&
          text.codeUnitAt(text.length - 1 - end) ==
              _text.codeUnitAt(_text.length - 1 - end)) {
        end++;
      }
      final oldEnd = _text.length - end;
      final newEnd = text.length - end;
      _layout?.edited(
        _lines.replace(start, oldEnd, text.substring(start, newEnd)),
      );
      _shiftWindow(start, oldEnd, newEnd);
    }
    _text = text;
    _reconcileWindow();
    _sendIfChanged();
    _scheduleAfterFrame();
    _startOrStopBlink();
    _rebuildOverlay();
    setState(() {});
  }

  // The window.

  /// A window around the selection and anything being composed.
  TextRange _placeWindow() {
    final selection = _value.selection;
    if (!selection.isValid) return TextRange(start: 0, end: _text.length);
    var from = selection.start;
    var to = selection.end;
    if (_composing) {
      from = math.min(from, _value.composing.start);
      to = math.max(to, _value.composing.end);
    }
    var start = math.max(0, from - _margin);
    var end = math.min(_text.length, to + _margin);
    final lineStart = _lines.startOf(_lines.lineAt(start));
    if (start - lineStart <= _margin) start = lineStart;
    final lineEnd = _lines.endOf(_lines.lineAt(end));
    if (lineEnd - end <= _margin) end = lineEnd;
    if (start > 0 && _isLowSurrogate(_text.codeUnitAt(start))) start--;
    if (end < _text.length && _isLowSurrogate(_text.codeUnitAt(end))) end++;
    return TextRange(start: start, end: end);
  }

  /// Keeps the window, and what the platform holds, over the same text
  /// across an edit that replaced `[start, oldEnd)` with text ending at
  /// [newEnd]. An edit before them moves them and sends nothing.
  void _shiftWindow(int start, int oldEnd, int newEnd) {
    final change = newEnd - oldEnd;
    _Remote? shift(_Remote? remote) =>
        remote != null && start < remote.start && oldEnd <= remote.start
        ? (start: remote.start + change, value: remote.value)
        : remote;
    _remote = shift(_remote);
    _previousRemote = shift(_previousRemote);
    if (start >= _window.start && oldEnd <= _window.end) {
      _window = TextRange(start: _window.start, end: _window.end + change);
    } else if (oldEnd <= _window.start) {
      _window = TextRange(
        start: _window.start + change,
        end: _window.end + change,
      );
    } else if (start < _window.end) {
      _window = _placeWindow();
    }
  }

  /// Moves the window once the selection comes near its edge or leaves it,
  /// but never while composing: a composition grows the window instead.
  void _reconcileWindow() {
    final selection = _value.selection;
    if (_composing || !selection.isValid) return;
    final length = _text.length;
    final keep =
        selection.start >= _window.start &&
        selection.end <= _window.end &&
        (selection.start - _window.start >= _edge || _window.start == 0) &&
        (_window.end - selection.end >= _edge || _window.end == length) &&
        _window.end - _window.start <=
            6 * _margin + selection.end - selection.start;
    if (!keep) _window = _placeWindow();
  }

  TextEditingValue get _windowValue {
    final start = _window.start;
    final selection = _value.selection;
    final composing = _value.composing;
    return TextEditingValue(
      text: _text.substring(start, _window.end),
      selection: selection.isValid
          ? selection.copyWith(
              baseOffset: selection.baseOffset - start,
              extentOffset: selection.extentOffset - start,
            )
          : selection,
      composing: _composing
          ? TextRange(
              start: composing.start - start,
              end: composing.end - start,
            )
          : TextRange.empty,
    );
  }

  /// Sends the platform the window, if it holds anything else. Never while
  /// no connection is attached: the macOS plugin has no model to put it in.
  void _sendIfChanged() {
    final connection = _connection;
    if (connection == null || !connection.attached) return;
    final value = _windowValue;
    final remote = _remote;
    if (remote != null &&
        remote.start == _window.start &&
        remote.value == value) {
      return;
    }
    _previousRemote = remote;
    _remote = (start: _window.start, value: value);
    connection.setEditingState(value);
  }

  // TextInputClient.

  @override
  TextEditingValue get currentTextEditingValue => _windowValue;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValueWithDeltas(List<TextEditingDelta> deltas) {
    if (deltas.isEmpty || widget.readOnly) return;
    final oldText = deltas.first.oldText;
    final remote = _remote;
    final previous = _previousRemote;
    final fromRemote = remote != null && oldText == remote.value.text;
    final _Remote base;
    if (fromRemote) {
      base = remote;
    } else if (previous != null &&
        oldText == previous.value.text &&
        _holds(previous)) {
      base = previous;
    } else {
      _resync();
      return;
    }
    var platform = base.value;
    for (final delta in deltas) {
      platform = delta.apply(platform);
    }
    _applyRemote(base, platform, fromRemote: fromRemote);
  }

  /// Whether the note still holds, where [remote] was taken, the text the
  /// platform was sent.
  bool _holds(_Remote remote) {
    final end = remote.start + remote.value.text.length;
    return end <= _text.length &&
        _text.substring(remote.start, end) == remote.value.text;
  }

  /// Drops an edit made to text the note no longer holds, and sends the
  /// platform the window again.
  void _resync() {
    _remote = null;
    _sendIfChanged();
  }

  /// Puts [platform], the platform's edit of what [base] sent it, into the
  /// note in place of the text [base] covers.
  void _applyRemote(
    _Remote base,
    TextEditingValue platform, {
    required bool fromRemote,
  }) {
    final start = base.start;
    final end = start + base.value.text.length;
    TextSelection shift(TextSelection selection) => selection.isValid
        ? selection.copyWith(
            baseOffset: selection.baseOffset + start,
            extentOffset: selection.extentOffset + start,
          )
        : _value.selection;
    final composing = platform.composing;
    final value = TextEditingValue(
      text: _text.replaceRange(start, end, platform.text),
      selection: shift(platform.selection),
      composing: composing.isValid && !composing.isCollapsed
          ? TextRange(
              start: composing.start + start,
              end: composing.end + start,
            )
          : TextRange.empty,
    );
    if (fromRemote) _remote = (start: start, value: platform);
    _formatAndSetValue(value, SelectionChangedCause.keyboard);
  }

  @override
  void updateEditingValue(TextEditingValue value) {
    if (widget.readOnly) return;
    final remote = _remote ?? (start: _window.start, value: _windowValue);
    final previous = _previousRemote;
    final holdsPrevious = previous != null && _holds(previous);
    if (_holds(remote)) {
      // Without the text it was made from, a whole value fits either window
      // the platform was sent, when the window has moved and both are still
      // in the note. Send the current one again rather than guess. Over the
      // same start, as after a formatter's edit, the current one is it.
      if (holdsPrevious && previous.start != remote.start) {
        _resync();
      } else {
        _applyRemote(remote, value, fromRemote: true);
      }
    } else if (holdsPrevious) {
      _applyRemote(previous, value, fromRemote: false);
    } else {
      _resync();
    }
  }

  @override
  void performAction(TextInputAction action) {}

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void insertTextPlaceholder(Size size) {}

  @override
  void removeTextPlaceholder() {}

  @override
  void performSelector(String selectorName) {
    final intent = intentForMacOSSelector(selectorName);
    final context = primaryFocus?.context;
    if (intent != null && context != null) Actions.invoke(context, intent);
  }

  @override
  void connectionClosed() {
    _connection?.connectionClosedReceived();
    _connection = null;
    _remote = null;
    _previousRemote = null;
    widget.focusNode.unfocus();
  }

  // Focus and the connection.

  /// Gaining focus puts the caret at the end if there is no selection, as
  /// [EditableText] does, and shows it.
  void _didChangeFocus() {
    final focused = widget.focusNode.hasFocus;
    if (focused && !_value.selection.isValid) {
      _controller.selection = TextSelection.collapsed(offset: _text.length);
    }
    if (focused && !widget.readOnly) {
      _openConnection();
      _scheduleReveal();
    } else {
      _closeConnection();
    }
    if (!focused) {
      _overlay?.dispose();
      _overlay = null;
    }
    _startOrStopBlink();
    setState(() {});
  }

  void _openConnection() {
    if (_hasConnection) return;
    final connection = TextInput.attach(
      this,
      TextInputConfiguration(
        viewId: View.of(context).viewId,
        inputType: TextInputType.multiline,
        inputAction: TextInputAction.newline,
        keyboardAppearance: Theme.of(context).brightness,
        autocorrect: false,
        enableSuggestions: false,
        smartDashesType: SmartDashesType.disabled,
        smartQuotesType: SmartQuotesType.disabled,
        enableDeltaModel: true,
      ),
    );
    _connection = connection;
    _remote = null;
    _previousRemote = null;
    _window = _placeWindow();
    connection.updateStyle(
      TextInputStyle(
        fontFamily: widget.style.fontFamily,
        fontSize: widget.style.fontSize,
        fontWeight: widget.style.fontWeight,
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.start,
      ),
    );
    _sendIfChanged();
    connection.show();
    _scheduleAfterFrame();
  }

  void _closeConnection() {
    _connection?.close();
    _connection = null;
    _remote = null;
    _previousRemote = null;
  }

  /// After every frame while connected, or while the selection overlay is
  /// up, brings what follows the lines up to date. Scrolling moves the lines
  /// too.
  void _scheduleAfterFrame() {
    if (_afterFrameScheduled || (!_hasConnection && _overlay == null)) return;
    _afterFrameScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _afterFrameScheduled = false;
      if (!mounted) return;
      _scheduleAfterFrame();
      final box = context.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      _sendGeometry(box);
      _updateOverlay(box);
    });
  }

  /// Tells the platform where the field is and where the selection's start
  /// and the composing range are drawn, which is where an input method puts
  /// its candidates. The connection passes on only what changed.
  void _sendGeometry(RenderBox box) {
    final connection = _connection;
    if (connection == null || !connection.attached) return;
    connection.setEditableSizeAndTransform(box.size, box.getTransformTo(null));
    final selection = _value.selection;
    if (!selection.isValid) return;
    final caret = caretRectAt(TextPosition(offset: selection.start));
    if (caret == null) return;
    connection.setCaretRect(caret);
    connection.setComposingRect(_composingRect() ?? caret);
  }

  // Changes the field makes itself.

  /// Takes [value] as if the user had made it, through the input formatters.
  /// One that changes nothing still focuses the field, as a click where the
  /// caret already is does.
  void userUpdateTextEditingValue(
    TextEditingValue value,
    SelectionChangedCause? cause,
  ) {
    if (value != _value) return _formatAndSetValue(value, cause);
    if (!widget.focusNode.hasFocus) widget.focusNode.requestFocus();
  }

  /// Takes the value an undo or redo restores, exactly, as [UndoHistory]
  /// requires, then moves the caret to the text the step changed before the
  /// frame reveals it.
  void _undoOrRedo(TextEditingValue value) {
    final caret = _caretAfterStep(_value, value);
    userUpdateTextEditingValue(value, SelectionChangedCause.keyboard);
    if (caret == value.selection) return;
    scheduleMicrotask(() {
      if (!mounted || _value.text != value.text) return;
      userUpdateTextEditingValue(
        _value.copyWith(selection: caret),
        SelectionChangedCause.keyboard,
      );
    });
  }

  void _formatAndSetValue(
    TextEditingValue value,
    SelectionChangedCause? cause,
  ) {
    final old = _value;
    final committed = !old.composing.isCollapsed && value.composing.isCollapsed;
    if (old.text != value.text || committed) {
      value = widget.inputFormatters.fold(
        value,
        (value, formatter) => formatter.formatEditUpdate(old, value),
      );
    }
    final moved = old.selection != value.selection;
    if (cause == SelectionChangedCause.keyboard && old.text != value.text) {
      hideToolbar(false);
    }
    _controller.value = value;
    if (moved ||
        cause == SelectionChangedCause.keyboard ||
        cause == SelectionChangedCause.longPress) {
      if (_verticalRun?.selection != value.selection) _verticalRun = null;
      _revealBase =
          cause == SelectionChangedCause.drag &&
          !_apple &&
          old.selection.baseOffset != value.selection.baseOffset;
      _scheduleReveal();
      _selectionChanged(cause);
    }
    // Solid while the user types or moves it.
    if (_caretShows && _blinkTimer != null) {
      _stopBlink();
      _startBlink();
    }
  }

  // The caret and the selection.

  bool get _caretShows =>
      widget.focusNode.hasFocus &&
      !widget.readOnly &&
      _value.selection.isValid &&
      _value.selection.isCollapsed;

  /// What a change to the selection does besides moving it, as
  /// [EditableText] and [TextField] have it: anything but a key focuses the
  /// field, and the overlay follows, with the handles if the gesture that
  /// made the change calls for them.
  void _selectionChanged(SelectionChangedCause? cause) {
    if (cause != SelectionChangedCause.keyboard) requestKeyboard();
    _handlesWanted =
        _gestures.showsHandles &&
        cause != SelectionChangedCause.keyboard &&
        !(widget.readOnly && _value.selection.isCollapsed) &&
        (cause == SelectionChangedCause.longPress || _text.isNotEmpty);
    _ensureOverlay().showHandles();
    if (cause == SelectionChangedCause.drag && _desktop) hideToolbar();
  }

  /// Tells the lines what to draw besides their text, once built.
  void _mark() {
    final caret = _caret;
    if (caret == null) return;
    layout.marks = (
      selection: _value.selection,
      selectionColor: widget.focusNode.hasFocus ? _selectionColor : null,
      caretColor: _caretShows && _blink.value > 0
          ? _cursorColor.withValues(
              alpha: math.min(_cursorColor.a, _blink.value),
            )
          : null,
      caret: caret,
      handles: _overlay == null ? null : (start: _startLink, end: _endLink),
    );
  }

  /// Blinks the caret while it shows, as [EditableText] does: on and off
  /// each half second, or on iOS fading as UIKit's does.
  void _startOrStopBlink() {
    if (!_caretShows || !_tickersEnabled) {
      _stopBlink();
    } else if (_blinkTimer == null) {
      _startBlink();
    }
  }

  void _startBlink() {
    _blinkTimer?.cancel();
    _blink.value = 1;
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      _blink.animateWith(_CaretBlink()).whenComplete(_blinkTick);
    } else {
      _blinkTimer = Timer.periodic(_blinkHalfPeriod, (timer) {
        _blinkTick();
        if (defaultTargetPlatform == TargetPlatform.linux &&
            _blinkHalfPeriod * timer.tick >= _linuxBlinkTimeout) {
          timer.cancel();
          _blink.value = 1;
        }
      });
    }
  }

  void _blinkTick() {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      _blink.value = _blink.value == 0 ? 1 : 0;
      return;
    }
    // A moment later, so that settling a test's frames doesn't wait on it.
    _blinkTimer?.cancel();
    _blinkTimer = Timer(
      Duration.zero,
      () => _blink.animateWith(_CaretBlink()).whenComplete(_blinkTick),
    );
  }

  void _stopBlink() {
    _blink.value = 0;
    _blinkTimer?.cancel();
    _blinkTimer = null;
  }

  // Pointer gestures, and the selection they make, as [RenderEditable] makes
  // it for [TextSelectionGestureDetectorBuilder] (see [NoteGestures]).

  /// The note position under [global], a point on the screen: in the line at
  /// that height, or in the first or last line above or below the note.
  TextPosition positionAt(Offset global) {
    final local = (context.findRenderObject()! as RenderBox).globalToLocal(
      global,
    );
    final heights = layout.heights!;
    final scroll = widget.scrollController;
    final y = local.dy + (scroll.hasClients ? scroll.offset : 0.0);
    final line = heights.lineAt(y);
    final found = layout
        .paragraphOf(line)
        .getPositionForOffset(Offset(local.dx, y - heights.topOf(line)));
    return TextPosition(
      offset:
          _lines.startOf(line) + math.min(found.offset, _lines[line].length),
      affinity: found.affinity,
    );
  }

  /// The field as assistive tools see it: a text field holding the window
  /// the platform's input has, not the note, so that what VoiceOver and
  /// dictation tools read and write is what typing goes through. Offsets
  /// they hand back are the window's.
  Widget _semantics(Widget child) {
    final window = _windowValue;
    final start = _window.start;
    final end = _window.end;
    final selection = _value.selection;
    final focused = widget.focusNode.hasFocus;
    final selected = selection.isValid && !selection.isCollapsed;
    final writable = !widget.readOnly;
    final moves = focused && selection.isValid;
    final direction = Directionality.maybeOf(context);
    void move(Intent intent) =>
        Actions.invoke(widget.focusNode.context!, intent);
    int inNote(int offset) => (start + offset).clamp(0, _text.length);
    return _FieldSemantics(
      describe: (config) {
        config
          ..isTextField = true
          ..isMultiline = true
          ..isReadOnly = widget.readOnly
          ..isFocused = focused
          ..value = window.text
          ..textDirection = direction
          ..onTap = requestKeyboard
          ..onSetSelection = (selection) => _setSelection(
            TextSelection(
              baseOffset: inNote(selection.baseOffset),
              extentOffset: inNote(selection.extentOffset),
            ),
            SelectionChangedCause.keyboard,
          );
        if (window.selection.isValid) config.textSelection = window.selection;
        if (writable) {
          config.onSetText = (text) {
            if (end > _text.length ||
                _text.substring(start, end) != window.text) {
              return;
            }
            userUpdateTextEditingValue(
              TextEditingValue(
                text: _text.replaceRange(start, end, text),
                selection: TextSelection.collapsed(offset: start + text.length),
              ),
              SelectionChangedCause.keyboard,
            );
          };
          config.onPaste = () =>
              unawaited(pasteText(SelectionChangedCause.keyboard));
        }
        if (selected) {
          config.onCopy = () => copySelection(SelectionChangedCause.keyboard);
          if (writable) {
            config.onCut = () => cutSelection(SelectionChangedCause.keyboard);
          }
        }
        if (!moves) return;
        void Function(bool extend) by(Intent Function(bool extend) intent) =>
            (extend) => move(intent(extend));
        config.onMoveCursorForwardByCharacter = by(
          (extend) => ExtendSelectionByCharacterIntent(
            forward: true,
            collapseSelection: !extend,
          ),
        );
        config.onMoveCursorBackwardByCharacter = by(
          (extend) => ExtendSelectionByCharacterIntent(
            forward: false,
            collapseSelection: !extend,
          ),
        );
        config.onMoveCursorForwardByWord = by(
          (extend) => ExtendSelectionToNextWordBoundaryIntent(
            forward: true,
            collapseSelection: !extend,
          ),
        );
        config.onMoveCursorBackwardByWord = by(
          (extend) => ExtendSelectionToNextWordBoundaryIntent(
            forward: false,
            collapseSelection: !extend,
          ),
        );
      },
      child: child,
    );
  }

  void _setSelection(TextSelection selection, SelectionChangedCause cause) =>
      userUpdateTextEditingValue(_value.copyWith(selection: selection), cause);

  /// Puts the caret at [from], or selects from there to [to].
  void selectPositionAt({
    required Offset from,
    Offset? to,
    required SelectionChangedCause cause,
  }) {
    final base = positionAt(from);
    final extent = to == null ? base : positionAt(to);
    _setSelection(
      TextSelection(
        baseOffset: base.offset,
        extentOffset: extent.offset,
        affinity: base.affinity,
      ),
      cause,
    );
  }

  /// Selects the word at [from], or the words from there to [to].
  void selectWordsInRange({
    required Offset from,
    Offset? to,
    required SelectionChangedCause cause,
  }) {
    final fromPosition = positionAt(from);
    final fromWord = _wordAt(fromPosition);
    final toPosition = to == null ? fromPosition : positionAt(to);
    final toWord = toPosition == fromPosition ? fromWord : _wordAt(toPosition);
    final forward = fromWord.start < toWord.end;
    _setSelection(
      TextSelection(
        baseOffset: forward ? fromWord.base.offset : fromWord.extent.offset,
        extentOffset: forward ? toWord.extent.offset : toWord.base.offset,
        affinity: fromWord.affinity,
      ),
      cause,
    );
  }

  /// Puts the caret at whichever end of the word at [at] is nearer.
  void selectWordEdge(Offset at, SelectionChangedCause cause) {
    final position = positionAt(at);
    final word = getWordBoundary(position);
    _setSelection(
      position.offset <= word.start
          ? TextSelection.collapsed(offset: word.start)
          : TextSelection.collapsed(
              offset: word.end,
              affinity: TextAffinity.upstream,
            ),
      cause,
    );
  }

  /// The word a long press or a double tap at [position] selects, as
  /// [RenderEditable.getWordAtOffset] finds it. On whitespace, iOS takes the
  /// word before it, or else the one after, along with the whitespace, and a
  /// read-only field on Android the word before it.
  TextSelection _wordAt(TextPosition position) {
    if (position.offset >= _text.length) {
      return TextSelection.fromPosition(
        TextPosition(offset: _text.length, affinity: TextAffinity.upstream),
      );
    }
    final word = getWordBoundary(position);
    final at = position.affinity == TextAffinity.upstream
        ? position.offset - 1
        : position.offset;
    final iOS = defaultTargetPlatform == TargetPlatform.iOS;
    final readOnlyAndroid =
        defaultTargetPlatform == TargetPlatform.android && widget.readOnly;
    if (at <= 0 ||
        !TextLayoutMetrics.isWhitespace(_text.codeUnitAt(at)) ||
        !(iOS || readOnlyAndroid)) {
      return TextSelection(baseOffset: word.start, extentOffset: word.end);
    }
    final previous = _previousWord(word.start);
    if (previous != null) {
      return TextSelection(
        baseOffset: previous.start,
        extentOffset: position.offset,
      );
    }
    if (readOnlyAndroid) {
      return TextSelection(
        baseOffset: position.offset,
        extentOffset: position.offset + 1,
      );
    }
    final next = _nextWord(word.start);
    return next == null
        ? TextSelection.collapsed(offset: position.offset)
        : TextSelection(baseOffset: position.offset, extentOffset: next.end);
  }

  /// The nearest word that isn't only whitespace, at [offset] or before it.
  TextRange? _previousWord(int offset) {
    var at = offset;
    while (at >= 0) {
      final range = getWordBoundary(TextPosition(offset: at));
      if (!range.isValid || range.isCollapsed) return null;
      if (!_onlyWhitespace(range)) return range;
      at = range.start - 1;
    }
    return null;
  }

  /// The nearest word that isn't only whitespace, at [offset] or after it.
  TextRange? _nextWord(int offset) {
    var at = offset;
    while (true) {
      final range = getWordBoundary(TextPosition(offset: at));
      if (!range.isValid || range.isCollapsed || range.end <= at) return null;
      if (!_onlyWhitespace(range)) return range;
      at = range.end;
    }
  }

  bool _onlyWhitespace(TextRange range) {
    for (var i = range.start; i < range.end; i++) {
      if (!TextLayoutMetrics.isWhitespace(_text.codeUnitAt(i))) return false;
    }
    return true;
  }

  /// Shows the keyboard, focusing the field first if it hasn't focus.
  void requestKeyboard() {
    if (!widget.focusNode.hasFocus) {
      widget.focusNode.requestFocus();
    } else if (_hasConnection) {
      _connection!.show();
    } else if (!widget.readOnly) {
      _openConnection();
    }
  }

  /// A tap outside the field takes its focus, as from a [TextField]: on
  /// phones, only when it isn't a finger's.
  void _tappedOutside(PointerDownEvent event) {
    if (_desktop || event.kind != PointerDeviceKind.touch) {
      widget.focusNode.unfocus();
    }
  }

  // The selection handles, the toolbar and the magnifier: the framework's
  // [SelectionOverlay], run as [TextSelectionOverlay] runs it.

  SelectionOverlay _ensureOverlay() {
    final existing = _overlay;
    if (existing != null) return existing;
    final selection = _value.selection.isValid
        ? _value.selection
        : TextSelection.collapsed(offset: _text.length);
    final overlay = _overlay = SelectionOverlay(
      context: context,
      debugRequiredFor: widget,
      startHandleType: _handleType(selection, TextSelectionHandleType.left),
      lineHeightAtStart: _rowHeightAt(selection.start),
      startHandlesVisible: _startHandleShows,
      onStartHandleDragStart: (details) =>
          _startHandleDrag(details, start: true),
      onStartHandleDragUpdate: (details) => _dragHandle(details, start: true),
      onStartHandleDragEnd: _endHandleDrag,
      endHandleType: _handleType(selection, TextSelectionHandleType.right),
      lineHeightAtEnd: _rowHeightAt(selection.end),
      endHandlesVisible: _endHandleShows,
      onEndHandleDragStart: (details) =>
          _startHandleDrag(details, start: false),
      onEndHandleDragUpdate: (details) => _dragHandle(details, start: false),
      onEndHandleDragEnd: _endHandleDrag,
      toolbarVisible: _toolbarShows,
      selectionEndpoints: _endpoints(selection),
      selectionControls: switch (defaultTargetPlatform) {
        TargetPlatform.iOS => cupertinoTextSelectionHandleControls,
        TargetPlatform.macOS => cupertinoDesktopTextSelectionHandleControls,
        TargetPlatform.android ||
        TargetPlatform.fuchsia => materialTextSelectionHandleControls,
        TargetPlatform.linux ||
        TargetPlatform.windows => desktopTextSelectionHandleControls,
      },
      // ignore: deprecated_member_use
      selectionDelegate: null,
      clipboardStatus: clipboardStatus,
      startHandleLayerLink: _startLink,
      endHandleLayerLink: _endLink,
      toolbarLayerLink: _toolbarLink,
      onSelectionHandleTapped: () {
        if (_value.selection.isCollapsed) toggleToolbar();
      },
      magnifierConfiguration:
          widget.magnifierConfiguration ??
          TextMagnifier.adaptiveMagnifierConfiguration,
    );
    _mark();
    _scheduleAfterFrame();
    return overlay;
  }

  /// Rebuilds the toolbar, whose items follow the note and the clipboard.
  void _rebuildOverlay() => _overlay?.markNeedsBuild();

  static TextSelectionHandleType _handleType(
    TextSelection selection,
    TextSelectionHandleType type,
  ) => selection.isCollapsed ? TextSelectionHandleType.collapsed : type;

  /// The height of a row of the line holding [offset].
  double _rowHeightAt(int offset) =>
      layout.paragraphOf(_lines.lineAt(offset)).preferredLineHeight;

  /// Where the selection handles point, in the field: under the selection's
  /// first and last boxes, or under the caret.
  List<TextSelectionPoint> _endpoints(TextSelection selection) {
    Offset pointAt(int offset, {required bool start}) {
      final line = _lines.lineAt(offset);
      final lineStart = _lines.startOf(line);
      final range = TextSelection(
        baseOffset: math.max(selection.start, lineStart) - lineStart,
        extentOffset: math.min(selection.end, _lines.endOf(line)) - lineStart,
        affinity: selection.affinity,
      );
      return handlePointIn(
            layout.paragraphOf(line),
            range,
            start: start,
            width: layout.width ?? 0,
          ) +
          Offset(0, lineTop(line) ?? 0);
    }

    final start = pointAt(selection.start, start: true);
    if (selection.isCollapsed) return [TextSelectionPoint(start, null)];
    return [
      TextSelectionPoint(start, TextDirection.ltr),
      TextSelectionPoint(
        pointAt(selection.end, start: false),
        TextDirection.ltr,
      ),
    ];
  }

  /// Brings the handles and the toolbar up to date with the selection as it
  /// is drawn now: each handle shows while its end of the selection is in
  /// view, and the toolbar while either is, as [RenderEditable] has them.
  void _updateOverlay(RenderBox box) {
    final overlay = _overlay;
    final selection = _value.selection;
    if (overlay == null || !selection.isValid) return;
    overlay
      ..startHandleType = _handleType(selection, TextSelectionHandleType.left)
      ..endHandleType = _handleType(selection, TextSelectionHandleType.right)
      ..lineHeightAtStart = _rowHeightAt(selection.start)
      ..lineHeightAtEnd = _rowHeightAt(selection.end)
      ..selectionEndpoints = _endpoints(selection);
    final view = (Offset.zero & box.size).inflate(0.5);
    bool inView(int offset) {
      final line = _lines.lineAt(offset);
      final top = lineTop(line);
      if (top == null) return false;
      final caret = layout
          .paragraphOf(line)
          .getOffsetForCaret(
            _local(
              TextPosition(offset: offset, affinity: selection.affinity),
              line,
            ),
            Rect.zero,
          );
      return view.contains(caret.translate(0, top));
    }

    final start = inView(selection.start);
    final end = inView(selection.end);
    _startHandleShows.value = _handlesWanted && start;
    _endHandleShows.value = _handlesWanted && end;
    _toolbarShows.value = start || end;
  }

  void _startHandleDrag(DragStartDetails details, {required bool start}) {
    final box = context.findRenderObject() as RenderBox?;
    final overlay = _overlay;
    if (box == null || !box.attached || overlay == null) return;
    final selection = _value.selection;
    final point = start
        ? overlay.selectionEndpoints.first.point
        : overlay.selectionEndpoints.last.point;
    final row = _rowHeightAt(start ? selection.start : selection.end);
    final middle = box.localToGlobal(Offset(0, point.dy - row / 2)).dy;
    _handleDragY = details.globalPosition.dy;
    _handleDragToRow = middle - details.globalPosition.dy;
    if (_apple) _handleDragStartSelection ??= selection;
    overlay.showMagnifier(
      _magnifierInfo(
        details.globalPosition,
        positionAt(Offset(details.globalPosition.dx, middle)),
      ),
    );
  }

  /// Moves the dragged handle's end of the selection under the pointer, a
  /// row at a time. On Apple's platforms the other end stays where it was
  /// when the drag began, and the ends may cross; elsewhere they may not.
  void _dragHandle(DragUpdateDetails details, {required bool start}) {
    final box = context.findRenderObject() as RenderBox?;
    final overlay = _overlay;
    if (box == null || !box.attached || overlay == null) return;
    final selection = _value.selection;
    final row = _rowHeightAt(start ? selection.start : selection.end);
    final handle = box.globalToLocal(Offset(0, _handleDragY)).dy;
    final dragged = box.globalToLocal(details.globalPosition).dy - handle;
    if (row <= 0 || !dragged.isFinite) return;
    final rows = dragged.sign * (dragged.abs() / row).floor();
    _handleDragY = box.localToGlobal(Offset(0, handle + rows * row)).dy;
    final position = positionAt(
      Offset(details.globalPosition.dx, _handleDragY + _handleDragToRow),
    );
    final from = _handleDragStartSelection;
    final TextSelection next;
    if (from?.isCollapsed ?? selection.isCollapsed) {
      next = TextSelection.fromPosition(position);
    } else if (from != null) {
      next = TextSelection(
        baseOffset: start == (from.extentOffset >= from.baseOffset)
            ? from.extentOffset
            : from.baseOffset,
        extentOffset: position.offset,
      );
    } else {
      next = start
          ? TextSelection(
              baseOffset: position.offset,
              extentOffset: selection.extentOffset,
            )
          : TextSelection(
              baseOffset: selection.baseOffset,
              extentOffset: position.offset,
            );
      if (next.baseOffset >= next.extentOffset) return;
    }
    _setSelection(next, SelectionChangedCause.drag);
    overlay.updateMagnifier(
      _magnifierInfo(
        details.globalPosition,
        start && next.baseOffset < next.extentOffset ? next.base : next.extent,
      ),
    );
  }

  void _endHandleDrag(DragEndDetails details) {
    final overlay = _overlay;
    if (!mounted || overlay == null) return;
    _handleDragStartSelection = null;
    if (overlay.isDraggingStartHandle || overlay.isDraggingEndHandle) return;
    overlay.hideMagnifier();
    if (!_value.selection.isCollapsed) showToolbar();
  }

  /// What the magnifier shows for a pointer at [global] over the caret at
  /// [position], in the overlay's coordinates.
  MagnifierInfo _magnifierInfo(Offset global, TextPosition position) {
    final box = context.findRenderObject()! as RenderBox;
    final overlay =
        Overlay.of(context, rootOverlay: true).context.findRenderObject()
            as RenderBox?;
    final toOverlay = box.getTransformTo(overlay);
    final caret = caretRectAt(position) ?? Rect.zero;
    final row = getLineAtOffset(position);
    final rowStart = caretRectAt(TextPosition(offset: row.baseOffset)) ?? caret;
    final rowEnd =
        caretRectAt(
          TextPosition(
            offset: row.extentOffset,
            affinity: TextAffinity.upstream,
          ),
        ) ??
        caret;
    return MagnifierInfo(
      fieldBounds: MatrixUtils.transformRect(toOverlay, box.paintBounds),
      globalGesturePosition: overlay?.globalToLocal(global) ?? global,
      caretRect: MatrixUtils.transformRect(toOverlay, caret),
      currentLineBoundaries: MatrixUtils.transformRect(
        toOverlay,
        Rect.fromPoints(rowStart.topCenter, rowEnd.bottomCenter),
      ),
    );
  }

  /// Shows the toolbar, unless it shows already, and says whether it did.
  /// The platform asks for it too, after it changes the selection itself.
  @override
  bool showToolbar() {
    final overlay = _ensureOverlay();
    if (overlay.toolbarIsVisible) return false;
    clipboardStatus.update();
    overlay.showToolbar(
      context: context,
      contextMenuBuilder: (context) =>
          (widget.contextMenuBuilder ?? _platformMenu)(context, this),
    );
    return true;
  }

  /// Hides the toolbar, and with [hideHandles] the handles and the magnifier.
  void hideToolbar([bool hideHandles = true]) {
    final overlay = _overlay;
    if (overlay == null) return;
    if (hideHandles) {
      overlay.hide();
    } else if (overlay.toolbarIsVisible) {
      overlay.hideToolbar();
    }
  }

  void toggleToolbar([bool hideHandles = true]) {
    if (_ensureOverlay().toolbarIsVisible) {
      hideToolbar(hideHandles);
    } else {
      showToolbar();
    }
  }

  /// Escape puts the toolbar away while it shows, and otherwise goes on to
  /// whatever is around the field.
  Object? _dismissToolbar(DismissIntent intent) {
    if (_overlay?.toolbarIsVisible ?? false) {
      hideToolbar(false);
      return null;
    }
    return Actions.invoke(context, intent);
  }

  /// Shows the magnifier over [global], or moves it there.
  void showMagnifier(Offset global) {
    final overlay = _overlay;
    if (overlay == null) return;
    final info = _magnifierInfo(global, positionAt(global));
    if (overlay.magnifierIsVisible) {
      overlay.updateMagnifier(info);
    } else {
      overlay.showMagnifier(info);
    }
  }

  void hideMagnifier() => _overlay?.hideMagnifier();

  /// Where the toolbar goes: at the secondary tap that opened it, or else
  /// above the selection, or below it where there is no room above.
  TextSelectionToolbarAnchors get contextMenuAnchors {
    final secondary = lastSecondaryTapDownPosition;
    if (secondary != null) {
      return TextSelectionToolbarAnchors(primaryAnchor: secondary);
    }
    final selection = _value.selection;
    return TextSelectionToolbarAnchors.fromSelection(
      renderBox: context.findRenderObject()! as RenderBox,
      startGlyphHeight: _rowHeightAt(selection.start),
      endGlyphHeight: _rowHeightAt(selection.end),
      selectionEndpoints: _endpoints(selection),
    );
  }

  /// Whether the toolbar offers Copy, Cut, Paste and Select All, on the
  /// platforms [EditableText] offers each on.
  bool get copyEnabled =>
      _value.selection.isValid && !_value.selection.isCollapsed;
  bool get cutEnabled => copyEnabled && !widget.readOnly;
  bool get pasteEnabled => !widget.readOnly;
  bool get selectAllEnabled {
    final selection = _value.selection;
    return switch (defaultTargetPlatform) {
      TargetPlatform.macOS => false,
      TargetPlatform.iOS => _text.isNotEmpty && selection.isCollapsed,
      _ =>
        _text.isNotEmpty &&
            !(selection.start == 0 && selection.end == _text.length),
    };
  }

  /// The toolbar's editing items, on the platforms [EditableText] offers
  /// each on.
  List<ContextMenuButtonItem> get contextMenuButtonItems {
    final selection = _value.selection;
    final selected = copyEnabled ? selection.textInside(_text) : '';
    final words = selected.trim().isNotEmpty;
    final platform = defaultTargetPlatform;
    const cause = SelectionChangedCause.toolbar;
    void system(String method) =>
        unawaited(SystemChannels.platform.invokeMethod<void>(method, selected));
    return EditableText.getEditableButtonItems(
      clipboardStatus: clipboardStatus.value,
      onCopy: copyEnabled ? () => copySelection(cause) : null,
      onCut: cutEnabled ? () => cutSelection(cause) : null,
      onPaste: pasteEnabled ? () => pasteText(cause) : null,
      onSelectAll: selectAllEnabled ? () => selectAll(cause) : null,
      onLookUp: words && platform == TargetPlatform.iOS
          ? () => system('LookUp.invoke')
          : null,
      onSearchWeb: words && platform == TargetPlatform.iOS
          ? () => system('SearchWeb.invoke')
          : null,
      onShare:
          words &&
              (platform == TargetPlatform.iOS ||
                  platform == TargetPlatform.android)
          ? () => system('Share.invoke')
          : null,
      onLiveTextInput: null,
    );
  }

  static Widget _platformMenu(BuildContext context, NoteFieldState field) =>
      AdaptiveTextSelectionToolbar.buttonItems(
        anchors: field.contextMenuAnchors,
        buttonItems: field.contextMenuButtonItems,
      );

  /// Copies the selection, as plain text. From the toolbar, the toolbar
  /// goes away, and on Android the selection with it.
  void copySelection(SelectionChangedCause cause) {
    final selection = _value.selection;
    if (!selection.isValid || selection.isCollapsed) return;
    unawaited(
      Clipboard.setData(ClipboardData(text: selection.textInside(_text))),
    );
    if (cause == SelectionChangedCause.toolbar) {
      hideToolbar(false);
      if (defaultTargetPlatform
          case TargetPlatform.android || TargetPlatform.fuchsia) {
        userUpdateTextEditingValue(
          TextEditingValue(
            text: _text,
            selection: TextSelection.collapsed(offset: selection.end),
          ),
          cause,
        );
      }
    }
    clipboardStatus.update();
  }

  void cutSelection(SelectionChangedCause cause) {
    final selection = _value.selection;
    if (widget.readOnly || !selection.isValid || selection.isCollapsed) return;
    unawaited(
      Clipboard.setData(ClipboardData(text: selection.textInside(_text))),
    );
    userUpdateTextEditingValue(_value.replaced(selection, ''), cause);
    if (cause == SelectionChangedCause.toolbar) hideToolbar();
    clipboardStatus.update();
  }

  Future<void> pasteText(SelectionChangedCause cause) async {
    final selection = _value.selection;
    if (widget.readOnly || !selection.isValid) return;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (!mounted || text == null) return;
    userUpdateTextEditingValue(_value.replaced(_value.selection, text), cause);
    if (cause == SelectionChangedCause.toolbar) hideToolbar();
  }

  void selectAll(SelectionChangedCause cause) {
    userUpdateTextEditingValue(
      _value.copyWith(
        selection: TextSelection(baseOffset: 0, extentOffset: _text.length),
      ),
      cause,
    );
    if (cause == SelectionChangedCause.toolbar && _desktop) hideToolbar();
  }

  // Where things are drawn.

  /// The caret at [position], in the field's coordinates, if the field has
  /// been laid out.
  Rect? caretRectAt(TextPosition position) {
    final line = _lines.lineAt(position.offset);
    final top = lineTop(line);
    final width = _layout?.width;
    final caret = _caret;
    if (top == null || width == null || caret == null) return null;
    layout.measure(line);
    return caretRectIn(
      layout.paragraphOf(line),
      _local(position, line),
      caret,
      width,
    ).translate(0, top);
  }

  /// Around what is being composed, in the line it starts in, in the field's
  /// coordinates.
  Rect? _composingRect() {
    if (!_composing) return null;
    final composing = _value.composing;
    final line = _lines.lineAt(composing.start);
    final top = lineTop(line);
    if (top == null) return null;
    final start = _lines.startOf(line);
    final boxes = layout
        .paragraphOf(line)
        .getBoxesForSelection(
          TextSelection(
            baseOffset: composing.start - start,
            extentOffset: math.min(composing.end, _lines.endOf(line)) - start,
          ),
        );
    if (boxes.isEmpty) return null;
    return boxes
        .map((box) => box.toRect())
        .reduce((all, box) => all.expandToInclude(box))
        .translate(0, top);
  }

  /// Where [line]'s top is in the field, once the field has been laid out:
  /// for the number of lines, where the last one ends.
  double? lineTop(int line) {
    final heights = _layout?.heights;
    if (heights == null) return null;
    final scroll = widget.scrollController;
    return heights.topOf(line) - (scroll.hasClients ? scroll.offset : 0.0);
  }

  /// The field's box, once laid out.
  RenderBox? get box {
    final box = context.findRenderObject();
    return box is RenderBox && box.attached && box.hasSize ? box : null;
  }

  /// The boxes around the text [selection] holds, row by row, in the field's
  /// coordinates: on the lines within a screen of the view.
  List<TextBox> boxesFor(TextSelection selection) {
    final heights = _layout?.heights;
    final box = this.box;
    if (heights == null ||
        box == null ||
        !selection.isValid ||
        selection.isCollapsed) {
      return const [];
    }
    final scroll = widget.scrollController;
    final scrolled = scroll.hasClients ? scroll.offset : 0.0;
    final view = box.size.height;
    final first = math.max(
      _lines.lineAt(selection.start),
      heights.lineAt(scrolled - view),
    );
    final last = math.min(
      _lines.lineAt(selection.end),
      heights.lineAt(scrolled + 2 * view),
    );
    final boxes = <TextBox>[];
    for (var line = first; line <= last; line++) {
      final start = _lines.startOf(line);
      final from = math.max(selection.start, start) - start;
      final to = math.min(selection.end, _lines.endOf(line)) - start;
      if (from >= to) continue;
      layout.measure(line);
      final top = heights.topOf(line) - scrolled;
      for (final box
          in layout
              .paragraphOf(line)
              .getBoxesForSelection(
                TextSelection(baseOffset: from, extentOffset: to),
                boxHeightStyle: BoxHeightStyle.strut,
              )) {
        boxes.add(
          TextBox.fromLTRBD(
            box.left,
            box.top + top,
            box.right,
            box.bottom + top,
            box.direction,
          ),
        );
      }
    }
    return boxes;
  }

  TextPosition _local(TextPosition position, int line) => TextPosition(
    offset: math.min(
      position.offset - _lines.startOf(line),
      _lines[line].length,
    ),
    affinity: position.affinity,
  );

  /// How far up the window a soft keyboard reached when it last moved.
  double _keyboard = 0;

  /// Shows the caret again as a soft keyboard comes up, as [EditableText]
  /// does. A phone gives the note only the room above the keyboard, so a
  /// caret put near the bottom of the screen would otherwise stay under it
  /// until something else moved the note. A keyboard going down only gives
  /// the room back, and a desktop has no keyboard, so neither scrolls.
  @override
  void didChangeMetrics() {
    final keyboard = View.of(context).viewInsets.bottom;
    if (keyboard > _keyboard && widget.focusNode.hasFocus) _scheduleReveal();
    _keyboard = keyboard;
  }

  /// Shows the caret once the frame is laid out, and again after the next
  /// one if lines measured on the way moved it.
  void _scheduleReveal([int attempts = 3]) {
    if (_revealScheduled || attempts == 0) return;
    _revealScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _revealScheduled = false;
      final selection = _value.selection;
      if (!mounted || !selection.isValid) return;
      final shown = _revealBase ? selection.base : selection.extent;
      if (bringIntoView(shown)) _scheduleReveal(attempts - 1);
    });
  }

  /// Scrolls the least distance that shows the caret at [position] and a
  /// row's height around it, or centres it when it is taller than the view,
  /// as [EditableText] does, and says whether it scrolled. The end of the
  /// note is landed on exactly, measuring the last screenful first, and the
  /// title brings the page's top margin with it.
  bool bringIntoView(TextPosition position) {
    final scroll = widget.scrollController;
    if (!scroll.hasClients) return false;
    final scrollPosition = scroll.position;
    if (position.offset >= _text.length) {
      if (scrollPosition.pixels >= scrollPosition.maxScrollExtent) {
        return false;
      }
      layout.jumpToEnd(scrollPosition);
      return true;
    }
    if (_lines.lineAt(position.offset) == 0) {
      if (scrollPosition.pixels <= scrollPosition.minScrollExtent) return false;
      scroll.jumpTo(scrollPosition.minScrollExtent);
      return true;
    }
    final caret = caretRectAt(position);
    if (caret == null) return false;
    final shown = Rect.fromCenter(
      center: caret.center,
      width: caret.width,
      height: math.max(
        caret.height,
        layout.paragraphOf(_lines.lineAt(position.offset)).preferredLineHeight,
      ),
    );
    final viewport = scrollPosition.viewportDimension;
    final double by;
    if (shown.height >= viewport) {
      by = shown.center.dy - viewport / 2;
    } else if (shown.top < 0) {
      by = shown.top;
    } else if (shown.bottom > viewport) {
      by = shown.bottom - viewport;
    } else {
      return false;
    }
    final target = clampDouble(
      scrollPosition.pixels + by,
      scrollPosition.minScrollExtent,
      scrollPosition.maxScrollExtent,
    );
    if ((target - scrollPosition.pixels).abs() < precisionErrorTolerance) {
      return false;
    }
    scroll.jumpTo(target);
    return true;
  }

  // TextLayoutMetrics, over the paragraph of each line.

  @override
  TextSelection getLineAtOffset(TextPosition position) {
    final line = _lines.lineAt(position.offset);
    final start = _lines.startOf(line);
    final row = layout
        .paragraphOf(line)
        .getLineBoundary(_local(position, line));
    final length = _lines[line].length;
    return TextSelection(
      baseOffset: start + math.min(row.start, length),
      extentOffset: start + math.min(row.end, length),
    );
  }

  /// The last line [getWordBoundary] laid out, kept for the next call, which
  /// a double click's drag makes on every move.
  ({String text, TextPainter painter})? _words;

  @override
  TextRange getWordBoundary(TextPosition position) {
    final line = _lines.lineAt(position.offset);
    final start = _lines.startOf(line);
    final text = _lines[line];
    if (_words?.text != text) {
      _words?.painter.dispose();
      _words = (
        text: text,
        painter: TextPainter(
          text: TextSpan(text: text, style: widget.style),
          textDirection: TextDirection.ltr,
        )..layout(),
      );
    }
    final word = _words!.painter.getWordBoundary(_local(position, line));
    return TextRange(start: start + word.start, end: start + word.end);
  }

  @override
  TextPosition getTextPositionAbove(TextPosition position) =>
      _verticalFrom(position, -1);

  @override
  TextPosition getTextPositionBelow(TextPosition position) =>
      _verticalFrom(position, 1);

  /// The position [rows] rows above or below [position], at the same
  /// distance from the left as [x], or as [position] when [x] is null.
  TextPosition _verticalFrom(TextPosition position, int rows, {double? x}) {
    var line = _lines.lineAt(position.offset);
    var paragraph = layout.paragraphOf(line);
    final local = _local(position, line);
    final caret = paragraph.getOffsetForCaret(local, Rect.zero);
    final goal = x ?? caret.dx;
    final metrics = paragraph.computeLineMetrics();
    var row = _rowAt(metrics, caret.dy);
    for (var step = 0; step < rows.abs(); step++) {
      row += rows.sign;
      if (row < 0) {
        if (line == 0) return const TextPosition(offset: 0);
        line--;
        paragraph = layout.paragraphOf(line);
        row = paragraph.computeLineMetrics().length - 1;
      } else if (row >= paragraph.computeLineMetrics().length) {
        if (line == _lines.length - 1) {
          return TextPosition(offset: _text.length);
        }
        line++;
        paragraph = layout.paragraphOf(line);
        row = 0;
      }
    }
    final target = paragraph.computeLineMetrics()[row];
    final found = paragraph.getPositionForOffset(
      Offset(goal, target.baseline - target.ascent / 2),
    );
    return TextPosition(
      offset:
          _lines.startOf(line) + math.min(found.offset, _lines[line].length),
      affinity: found.affinity,
    );
  }

  static int _rowAt(List<LineMetrics> metrics, double y) {
    for (var row = 0; row < metrics.length; row++) {
      final metric = metrics[row];
      if (y < metric.baseline + metric.descent) return row;
    }
    return metrics.length - 1;
  }

  // Keys.

  TextBoundary _characterBoundary() => CharacterBoundary(_text);
  TextBoundary _wordBoundary() => _NoteWordBoundary(this);
  TextBoundary _lineBreak() => LineBoundary(this);
  TextBoundary _paragraphBoundary() => ParagraphBoundary(_text);
  TextBoundary _documentBoundary() => DocumentBoundary(_text);

  /// The nearest boundary past [extent] in the direction given.
  TextPosition _beyondBoundary(
    TextPosition extent,
    bool forward,
    TextBoundary boundary,
  ) => TextPosition(
    offset: forward
        ? boundary.getTrailingTextBoundaryAt(extent.offset) ?? _text.length
        : boundary.getLeadingTextBoundaryAt(extent.offset - 1) ?? 0,
  );

  /// The nearest boundary at or past [extent] in the direction given, for
  /// line ends, where moving again from one shouldn't go on to the next.
  TextPosition _toBoundary(
    TextPosition extent,
    bool forward,
    TextBoundary boundary,
  ) {
    final caret = extent.affinity == TextAffinity.upstream
        ? math.max(0, extent.offset - 1)
        : extent.offset;
    return forward
        ? TextPosition(
            offset: boundary.getTrailingTextBoundaryAt(caret) ?? _text.length,
            affinity: TextAffinity.upstream,
          )
        : TextPosition(offset: boundary.getLeadingTextBoundaryAt(caret) ?? 0);
  }

  void _replaceText(ReplaceTextIntent intent) => userUpdateTextEditingValue(
    intent.currentTextEditingValue.replaced(
      intent.replacementRange,
      intent.replacementText,
    ),
    intent.cause,
  );

  void _updateSelection(UpdateSelectionIntent intent) =>
      userUpdateTextEditingValue(
        intent.currentTextEditingValue.copyWith(selection: intent.newSelection),
        intent.cause,
      );

  void _transposeCharacters(TransposeCharactersIntent intent) {
    final selection = _value.selection;
    if (_text.characters.length <= 1 ||
        !selection.isCollapsed ||
        selection.baseOffset == 0) {
      return;
    }
    final transposing = CharacterRange.at(_text, selection.baseOffset);
    if (selection.baseOffset == _text.length) {
      transposing.moveBack(2);
    } else {
      transposing
        ..moveBack()
        ..expandNext();
    }
    userUpdateTextEditingValue(
      TextEditingValue(
        text:
            transposing.stringBefore +
            transposing.currentCharacters.last +
            transposing.currentCharacters.first +
            transposing.stringAfter,
        selection: TextSelection.collapsed(
          offset: transposing.stringBeforeLength + transposing.current.length,
        ),
      ),
      SelectionChangedCause.keyboard,
    );
  }

  void _moveVertically(
    DirectionalCaretMovementIntent intent,
    BuildContext context,
  ) {
    final selection = _value.selection;
    if (!selection.isValid) return;
    final run = _verticalRun;
    final extent = selection.extent;
    final line = _lines.lineAt(extent.offset);
    final x = run != null && run.selection == selection
        ? run.x
        : layout
              .paragraphOf(line)
              .getOffsetForCaret(_local(extent, line), Rect.zero)
              .dx;
    final TextPosition target;
    if (intent is ExtendSelectionVerticallyToAdjacentPageIntent) {
      target = _pageFrom(extent, intent.forward, x);
    } else {
      target = _verticalFrom(extent, intent.forward ? 1 : -1, x: x);
    }
    final moved = intent.collapseSelection
        ? TextSelection.fromPosition(target)
        : selection.extendTo(target);
    Actions.invoke(
      context,
      UpdateSelectionIntent(_value, moved, SelectionChangedCause.keyboard),
    );
    _verticalRun = (x: x, selection: _value.selection);
  }

  /// The position a viewport's height above or below [extent].
  TextPosition _pageFrom(TextPosition extent, bool forward, double x) {
    final heights = layout.heights!;
    final scroll = widget.scrollController;
    final page = scroll.hasClients ? scroll.position.viewportDimension : 0.0;
    final line = _lines.lineAt(extent.offset);
    final caret = layout
        .paragraphOf(line)
        .getOffsetForCaret(_local(extent, line), Rect.zero);
    final y = heights.topOf(line) + caret.dy + (forward ? page : -page);
    if (y < 0) return const TextPosition(offset: 0);
    if (y >= heights.total) return TextPosition(offset: _text.length);
    final target = heights.lineAt(y);
    final found = layout
        .paragraphOf(target)
        .getPositionForOffset(Offset(x, y - heights.topOf(target)));
    return TextPosition(
      offset:
          _lines.startOf(target) +
          math.min(found.offset, _lines[target].length),
      affinity: found.affinity,
    );
  }

  void _scroll(ScrollIntent intent) {
    if (intent.type != ScrollIncrementType.page) return;
    final scroll = widget.scrollController;
    if (!scroll.hasClients) return;
    final position = scroll.position;
    final page = position.viewportDimension * 0.8;
    final forward = switch (intent.direction) {
      AxisDirection.down || AxisDirection.right => true,
      AxisDirection.up || AxisDirection.left => false,
    };
    scroll.jumpTo(
      clampDouble(
        position.pixels + (forward ? page : -page),
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
  }

  Action<T> _overridable<T extends Intent>(Action<T> action) =>
      Action<T>.overridable(context: context, defaultAction: action);

  late final Map<Type, Action<Intent>> _actions = {
    DoNothingAndStopPropagationTextIntent: DoNothingAction(consumesKey: false),
    ReplaceTextIntent: CallbackAction<ReplaceTextIntent>(
      onInvoke: _replaceText,
    ),
    UpdateSelectionIntent: CallbackAction<UpdateSelectionIntent>(
      onInvoke: _updateSelection,
    ),
    DirectionalFocusIntent: DirectionalFocusAction.forTextField(),
    DismissIntent: CallbackAction<DismissIntent>(onInvoke: _dismissToolbar),
    DeleteCharacterIntent: _overridable(
      _DeleteAction<DeleteCharacterIntent>(
        this,
        _characterBoundary,
        _beyondBoundary,
      ),
    ),
    DeleteToNextWordBoundaryIntent: _overridable(
      _DeleteAction<DeleteToNextWordBoundaryIntent>(
        this,
        _wordBoundary,
        _beyondBoundary,
      ),
    ),
    DeleteToLineBreakIntent: _overridable(
      _DeleteAction<DeleteToLineBreakIntent>(this, _lineBreak, _toBoundary),
    ),
    ExtendSelectionByCharacterIntent: _overridable(
      _SelectAction<ExtendSelectionByCharacterIntent>(
        this,
        _characterBoundary,
        _beyondBoundary,
        ignoreNonCollapsed: false,
      ),
    ),
    ExtendSelectionToNextWordBoundaryIntent: _overridable(
      _SelectAction<ExtendSelectionToNextWordBoundaryIntent>(
        this,
        _wordBoundary,
        _beyondBoundary,
      ),
    ),
    ExtendSelectionToNextParagraphBoundaryIntent: _overridable(
      _SelectAction<ExtendSelectionToNextParagraphBoundaryIntent>(
        this,
        _paragraphBoundary,
        _beyondBoundary,
      ),
    ),
    ExtendSelectionToLineBreakIntent: _overridable(
      _SelectAction<ExtendSelectionToLineBreakIntent>(
        this,
        _lineBreak,
        _toBoundary,
      ),
    ),
    ExtendSelectionVerticallyToAdjacentLineIntent: _overridable(
      _VerticalAction<ExtendSelectionVerticallyToAdjacentLineIntent>(this),
    ),
    ExtendSelectionVerticallyToAdjacentPageIntent: _overridable(
      _VerticalAction<ExtendSelectionVerticallyToAdjacentPageIntent>(this),
    ),
    ExtendSelectionToNextParagraphBoundaryOrCaretLocationIntent: _overridable(
      _SelectAction<
        ExtendSelectionToNextParagraphBoundaryOrCaretLocationIntent
      >(this, _paragraphBoundary, _beyondBoundary),
    ),
    ExtendSelectionToDocumentBoundaryIntent: _overridable(
      _SelectAction<ExtendSelectionToDocumentBoundaryIntent>(
        this,
        _documentBoundary,
        _beyondBoundary,
      ),
    ),
    ExtendSelectionToNextWordBoundaryOrCaretLocationIntent: _overridable(
      _SelectAction<ExtendSelectionToNextWordBoundaryOrCaretLocationIntent>(
        this,
        _wordBoundary,
        _beyondBoundary,
      ),
    ),
    ExpandSelectionToLineBreakIntent: _overridable(
      _SelectAction<ExpandSelectionToLineBreakIntent>(
        this,
        _lineBreak,
        _toBoundary,
        expand: true,
      ),
    ),
    ExpandSelectionToDocumentBoundaryIntent: _overridable(
      _SelectAction<ExpandSelectionToDocumentBoundaryIntent>(
        this,
        _documentBoundary,
        _toBoundary,
        expand: true,
        extentAtIndex: true,
      ),
    ),
    ScrollToDocumentBoundaryIntent: _overridable(
      CallbackAction<ScrollToDocumentBoundaryIntent>(
        onInvoke: (intent) => bringIntoView(
          TextPosition(offset: intent.forward ? _text.length : 0),
        ),
      ),
    ),
    ScrollIntent: CallbackAction<ScrollIntent>(onInvoke: _scroll),
    SelectAllTextIntent: _overridable(
      CallbackAction<SelectAllTextIntent>(
        onInvoke: (intent) => selectAll(intent.cause),
      ),
    ),
    CopySelectionTextIntent: _overridable(
      CallbackAction<CopySelectionTextIntent>(
        onInvoke: (intent) => intent.collapseSelection
            ? cutSelection(intent.cause)
            : copySelection(intent.cause),
      ),
    ),
    PasteTextIntent: _overridable(
      CallbackAction<PasteTextIntent>(
        onInvoke: (intent) => pasteText(intent.cause),
      ),
    ),
    TransposeCharactersIntent: _overridable(
      CallbackAction<TransposeCharactersIntent>(onInvoke: _transposeCharacters),
    ),
  };

  @override
  Widget build(BuildContext context) {
    final spans = _controller.spansIn(
      context,
      widget.style,
      composing: _composing ? _value.composing : null,
    );
    final adjust = widget.adjustSpan;
    _spansIn = adjust == null
        ? spans
        : (start, end) => adjust(start, end, spans(start, end));
    layout
      ..columnWidth = widget.columnWidth
      ..trailingOf = widget.trailingOf
      ..selectionOf = widget.selectionOf
      ..restyled();
    final theme = Theme.of(context);
    final selectionStyle = DefaultSelectionStyle.of(context);
    final apple = _apple;
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    _cursorColor =
        widget.cursorColor ??
        selectionStyle.cursorColor ??
        theme.colorScheme.primary;
    _selectionColor =
        selectionStyle.selectionColor ??
        theme.colorScheme.primary.withValues(alpha: 0.4);
    _caret = (
      width: widget.cursorWidth,
      height: widget.cursorHeight,
      radius: widget.cursorRadius ?? (apple ? const Radius.circular(2) : null),
      offset: apple ? Offset(-2 / pixelRatio, 0) : Offset.zero,
      aboveText: apple,
      pixelRatio: pixelRatio,
    );
    _mark();
    return Actions(
      actions: _actions,
      child: UndoHistory<TextEditingValue>(
        value: _controller,
        controller: widget.undoController,
        focusNode: widget.focusNode,
        onTriggered: _undoOrRedo,
        shouldChangeUndoStack: (oldValue, newValue) {
          if (!newValue.selection.isValid) return false;
          if (oldValue == null) return true;
          if (defaultTargetPlatform != TargetPlatform.android &&
              !_value.composing.isCollapsed) {
            return false;
          }
          return oldValue.text != newValue.text ||
              oldValue.composing != newValue.composing;
        },
        undoStackModifier: (value) =>
            defaultTargetPlatform == TargetPlatform.android
            ? value.copyWith(composing: TextRange.empty)
            : value,
        child: Focus(
          focusNode: widget.focusNode,
          autofocus: widget.autofocus,
          includeSemantics: false,
          child: _semantics(
            TextFieldTapRegion(
              onTapOutside: widget.focusNode.hasFocus ? _tappedOutside : null,
              child: MouseRegion(
                cursor: widget.mouseCursor,
                child: CompositedTransformTarget(
                  link: _toolbarLink,
                  child: _gestures.build(
                    child: CustomScrollView(
                      controller: widget.scrollController,
                      scrollBehavior: ScrollConfiguration.of(
                        context,
                      ).copyWith(overscroll: false),
                      slivers: [NoteSliver(layout: layout)],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The field's own node in the semantics tree, described afresh with every
/// build. The [Semantics] widget can't carry a text selection.
class _FieldSemantics extends SingleChildRenderObjectWidget {
  const _FieldSemantics({required this.describe, required super.child});

  final void Function(SemanticsConfiguration config) describe;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFieldSemantics(describe);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderFieldSemantics renderObject,
  ) => renderObject.describe = describe;
}

class _RenderFieldSemantics extends RenderProxyBox {
  _RenderFieldSemantics(this._describe);

  void Function(SemanticsConfiguration config) _describe;
  set describe(void Function(SemanticsConfiguration config) value) {
    _describe = value;
    markNeedsSemanticsUpdate();
  }

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config.isSemanticBoundary = true;
    _describe(config);
  }
}

/// Moves the caret, or extends the selection, a row or a page up or down,
/// keeping to the distance from the left that a run of such moves began at.
class _VerticalAction<T extends DirectionalCaretMovementIntent>
    extends ContextAction<T> {
  _VerticalAction(this.state);

  final NoteFieldState state;

  @override
  void invoke(T intent, [BuildContext? context]) =>
      state._moveVertically(intent, context!);

  @override
  bool get isActionEnabled => state._value.selection.isValid;
}

typedef _ApplyBoundary =
    TextPosition Function(
      TextPosition extent,
      bool forward,
      TextBoundary boundary,
    );

/// Deletes the selection, or from the caret to the next boundary.
class _DeleteAction<T extends DirectionalTextEditingIntent>
    extends ContextAction<T> {
  _DeleteAction(this.state, this.boundary, this.apply);

  final NoteFieldState state;
  final TextBoundary Function() boundary;
  final _ApplyBoundary apply;

  @override
  Object? invoke(T intent, [BuildContext? context]) {
    final value = state._value;
    final selection = value.selection;
    final characters = state._characterBoundary();
    if (!selection.isCollapsed) {
      return Actions.invoke(
        context!,
        ReplaceTextIntent(
          value,
          '',
          TextRange(
            start:
                characters.getLeadingTextBoundaryAt(selection.start) ??
                value.text.length,
            end: characters.getTrailingTextBoundaryAt(selection.end - 1) ?? 0,
          ),
          SelectionChangedCause.keyboard,
        ),
      );
    }
    final target = apply(selection.base, intent.forward, boundary()).offset;
    return Actions.invoke(
      context!,
      ReplaceTextIntent(
        value,
        '',
        TextSelection(
          baseOffset: intent.forward
              ? characters.getLeadingTextBoundaryAt(selection.baseOffset) ??
                    value.text.length
              : characters.getTrailingTextBoundaryAt(
                      selection.baseOffset - 1,
                    ) ??
                    0,
          extentOffset: target,
        ),
        SelectionChangedCause.keyboard,
      ),
    );
  }

  @override
  bool get isActionEnabled =>
      !state.widget.readOnly && state._value.selection.isValid;
}

/// Moves the caret, or extends or expands the selection, to the next
/// boundary.
class _SelectAction<T extends DirectionalCaretMovementIntent>
    extends ContextAction<T> {
  _SelectAction(
    this.state,
    this.boundary,
    this.apply, {
    this.ignoreNonCollapsed = true,
    this.expand = false,
    this.extentAtIndex = false,
  });

  final NoteFieldState state;
  final TextBoundary Function() boundary;
  final _ApplyBoundary apply;
  final bool ignoreNonCollapsed;
  final bool expand;
  final bool extentAtIndex;

  bool _atWrapUpstream(TextPosition position) {
    final end = TextPosition(
      offset: state.getLineAtOffset(position).end,
      affinity: TextAffinity.upstream,
    );
    return end == position &&
        end.offset != state._text.length &&
        state._text.codeUnitAt(position.offset) != 0x0A;
  }

  bool _atWrapDownstream(TextPosition position) {
    final start = TextPosition(offset: state.getLineAtOffset(position).start);
    return start == position &&
        start.offset != 0 &&
        state._text.codeUnitAt(position.offset - 1) != 0x0A;
  }

  @override
  Object? invoke(T intent, [BuildContext? context]) {
    final value = state._value;
    final selection = value.selection;
    final collapse = intent.collapseSelection;
    if (!selection.isCollapsed && !ignoreNonCollapsed && collapse) {
      return Actions.invoke(
        context!,
        UpdateSelectionIntent(
          value,
          TextSelection.collapsed(
            offset: intent.forward ? selection.end : selection.start,
          ),
          SelectionChangedCause.keyboard,
        ),
      );
    }
    var extent = selection.extent;
    if (intent.continuesAtWrap) {
      if (intent.forward && _atWrapUpstream(extent)) {
        extent = TextPosition(offset: extent.offset);
      } else if (!intent.forward && _atWrapDownstream(extent)) {
        extent = TextPosition(
          offset: extent.offset,
          affinity: TextAffinity.upstream,
        );
      }
    }
    final targetBase =
        expand &&
        (intent.forward
            ? selection.baseOffset > selection.extentOffset
            : selection.baseOffset < selection.extentOffset);
    final next = apply(
      targetBase ? selection.base : extent,
      intent.forward,
      boundary(),
    );
    final moved = collapse || (!expand && next.offset == selection.baseOffset)
        ? TextSelection.fromPosition(next)
        : expand
        ? selection.expandTo(next, extentAtIndex || selection.isCollapsed)
        : selection.extendTo(next);
    final reversed =
        intent.collapseAtReversal &&
        (selection.baseOffset - selection.extentOffset) *
                (selection.baseOffset - moved.extentOffset) <
            0;
    return Actions.invoke(
      context!,
      UpdateSelectionIntent(
        value,
        reversed ? TextSelection.fromPosition(selection.base) : moved,
        SelectionChangedCause.keyboard,
      ),
    );
  }

  @override
  bool get isActionEnabled => state._value.selection.isValid;
}

/// Words by the rules of the paragraph they are laid out in, and across a
/// line break as a whole paragraph of the note would take them.
class _NoteWordBoundary extends TextBoundary {
  _NoteWordBoundary(this.state);

  final NoteFieldState state;

  /// What [find] finds at [offset] among the words of the note's lines
  /// around it, laid out as one paragraph.
  int? _around(int offset, int? Function(TextBoundary words, int at) find) {
    final lines = state._lines;
    final line = lines.lineAt(offset);
    final first = math.max(0, line - 1);
    final last = math.min(lines.length - 1, line + 1);
    final start = lines.startOf(first);
    final painter = TextPainter(
      text: TextSpan(
        text: state._text.substring(start, lines.endOf(last)),
        style: state.widget.style,
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final found = find(
      painter.wordBoundaries.moveByWordBoundary,
      offset - start,
    );
    painter.dispose();
    return found == null ? null : found + start;
  }

  @override
  int? getLeadingTextBoundaryAt(int position) => position < 0
      ? null
      : _around(position, (words, at) => words.getLeadingTextBoundaryAt(at));

  @override
  int? getTrailingTextBoundaryAt(int position) => position >= state._text.length
      ? null
      : _around(position, (words, at) => words.getTrailingTextBoundaryAt(at));
}

/// The caret's opacity through each second of its blink on iOS: UIKit's
/// key frames, as [EditableText] has them.
class _CaretBlink extends Simulation {
  static const _frames = [
    (time: 0.0, opacity: 1.0),
    (time: 0.5, opacity: 1.0),
    (time: 0.5375, opacity: 0.75),
    (time: 0.575, opacity: 0.5),
    (time: 0.6125, opacity: 0.25),
    (time: 0.65, opacity: 0.0),
    (time: 0.85, opacity: 0.0),
    (time: 0.8875, opacity: 0.25),
    (time: 0.925, opacity: 0.5),
    (time: 0.9625, opacity: 0.75),
    (time: 1.0, opacity: 1.0),
  ];

  @override
  double x(double time) => _frames
      .lastWhere((frame) => frame.time <= time, orElse: () => _frames.first)
      .opacity;

  @override
  double dx(double time) => 0;

  @override
  bool isDone(double time) => time >= 1;
}

bool _isLowSurrogate(int unit) => unit & 0xFC00 == 0xDC00;

/// Where the caret goes when undo or redo turns [from] into [to]: after the
/// text the step brings back, or where the text it takes away was, rather
/// than wherever it stood when [to] was recorded. A step that keeps the
/// text's length, such as ticking a box, leaves the caret where it is.
TextSelection _caretAfterStep(TextEditingValue from, TextEditingValue to) {
  final before = from.text;
  final after = to.text;
  if (before == after) return to.selection;
  if (before.length == after.length && from.selection.isValid) {
    return from.selection;
  }
  final shorter = math.min(before.length, after.length);
  var start = 0;
  while (start < shorter &&
      before.codeUnitAt(start) == after.codeUnitAt(start)) {
    start++;
  }
  var end = 0;
  while (end < shorter - start &&
      before.codeUnitAt(before.length - 1 - end) ==
          after.codeUnitAt(after.length - 1 - end)) {
    end++;
  }
  var offset = after.length - end;
  if (offset > 0 &&
      offset < after.length &&
      _isLowSurrogate(after.codeUnitAt(offset))) {
    offset++;
  }
  return TextSelection.collapsed(offset: offset);
}
