import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'highlighting_controller.dart';
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

  @override
  State<NoteField> createState() => NoteFieldState();
}

/// Characters the platform is sent either side of the selection.
const _margin = 2048;

/// How near the window's edge the selection may come before the window moves.
const _edge = _margin ~/ 4;

/// What the platform holds, and where it starts in the note.
typedef _Remote = ({int start, TextEditingValue value});

class NoteFieldState extends State<NoteField>
    with TextInputClient, DeltaTextInputClient
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
  bool _geometryScheduled = false;
  bool _revealScheduled = false;

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
    _window = _placeWindow();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensureLayout();
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
    _ensureLayout();
  }

  @override
  void dispose() {
    _controller.removeListener(_didChangeValue);
    widget.focusNode.removeListener(_didChangeFocus);
    _closeConnection();
    super.dispose();
  }

  /// A layout for the style, strut and text scale the field has now; a new
  /// one when any of them changes, since every line's paragraph does too.
  void _ensureLayout() {
    final scaler = MediaQuery.textScalerOf(context);
    final current = _layout;
    if (current != null &&
        current.style == widget.style &&
        current.strut == widget.strut &&
        current.scaler == scaler) {
      return;
    }
    _layout = NoteLayout(
      lines: _lines,
      spanOf: (line) => _spansIn!(_lines.startOf(line), _lines.endOf(line)),
      style: widget.style,
      strut: widget.strut,
      scaler: scaler,
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
    _scheduleGeometry();
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
        previous.start + oldText.length <= _text.length &&
        _text.substring(previous.start, previous.start + oldText.length) ==
            oldText) {
      base = previous;
    } else {
      _remote = null;
      _sendIfChanged();
      return;
    }
    var platform = base.value;
    for (final delta in deltas) {
      platform = delta.apply(platform);
    }
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
    final start = _window.start;
    _remote = (start: start, value: value);
    _formatAndSetValue(
      TextEditingValue(
        text: _text.replaceRange(start, _window.end, value.text),
        selection: value.selection.isValid
            ? value.selection.copyWith(
                baseOffset: value.selection.baseOffset + start,
                extentOffset: value.selection.extentOffset + start,
              )
            : _value.selection,
        composing: value.composing.isValid && !value.composing.isCollapsed
            ? TextRange(
                start: value.composing.start + start,
                end: value.composing.end + start,
              )
            : TextRange.empty,
      ),
      SelectionChangedCause.keyboard,
    );
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
    _scheduleGeometry();
  }

  void _closeConnection() {
    _connection?.close();
    _connection = null;
    _remote = null;
    _previousRemote = null;
  }

  /// After every frame while connected, tells the platform where the field
  /// is and where the selection's start and the composing range are drawn,
  /// which is where an input method puts its candidates. Scrolling moves
  /// them too. The connection passes on only what changed.
  void _scheduleGeometry() {
    if (_geometryScheduled || !_hasConnection) return;
    _geometryScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _geometryScheduled = false;
      final connection = _connection;
      if (!mounted || connection == null || !connection.attached) return;
      _scheduleGeometry();
      final box = context.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      connection.setEditableSizeAndTransform(
        box.size,
        box.getTransformTo(null),
      );
      final selection = _value.selection;
      if (!selection.isValid) return;
      final caret = _caretRect(TextPosition(offset: selection.start));
      if (caret == null) return;
      connection.setCaretRect(caret);
      connection.setComposingRect(_composingRect() ?? caret);
    });
  }

  // Changes the field makes itself.

  /// Takes [value] as if the user had made it, through the input formatters.
  void userUpdateTextEditingValue(
    TextEditingValue value,
    SelectionChangedCause? cause,
  ) {
    if (value == _value) return;
    _formatAndSetValue(value, cause);
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
    _controller.value = value;
    if (moved || cause == SelectionChangedCause.keyboard) {
      if (_verticalRun?.selection != value.selection) _verticalRun = null;
      _scheduleReveal();
    }
  }

  /// Copies the selection, as plain text.
  void copySelection(SelectionChangedCause cause) {
    final selection = _value.selection;
    if (!selection.isValid || selection.isCollapsed) return;
    unawaited(
      Clipboard.setData(ClipboardData(text: selection.textInside(_text))),
    );
  }

  void cutSelection(SelectionChangedCause cause) {
    final selection = _value.selection;
    if (widget.readOnly || !selection.isValid || selection.isCollapsed) return;
    copySelection(cause);
    userUpdateTextEditingValue(_value.replaced(selection, ''), cause);
  }

  Future<void> pasteText(SelectionChangedCause cause) async {
    final selection = _value.selection;
    if (widget.readOnly || !selection.isValid) return;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (!mounted || text == null) return;
    userUpdateTextEditingValue(_value.replaced(_value.selection, text), cause);
  }

  void selectAll(SelectionChangedCause cause) => userUpdateTextEditingValue(
    _value.copyWith(
      selection: TextSelection(baseOffset: 0, extentOffset: _text.length),
    ),
    cause,
  );

  // Where things are drawn.

  /// The caret at [position], in the field's coordinates, if the field has
  /// been laid out.
  Rect? _caretRect(TextPosition position) {
    final line = _lines.lineAt(position.offset);
    final top = _topOf(line);
    if (top == null) return null;
    layout.measure(line);
    final paragraph = layout.paragraphOf(line);
    final local = _local(position, line);
    final offset = paragraph.getOffsetForCaret(local, Rect.zero);
    return Rect.fromLTWH(
      offset.dx,
      top + offset.dy,
      0,
      paragraph.getFullHeightForCaret(local, Rect.zero),
    );
  }

  /// Around what is being composed, in the line it starts in, in the field's
  /// coordinates.
  Rect? _composingRect() {
    if (!_composing) return null;
    final composing = _value.composing;
    final line = _lines.lineAt(composing.start);
    final top = _topOf(line);
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

  /// Where [line]'s top is in the field, once the field has been laid out.
  double? _topOf(int line) {
    final heights = _layout?.heights;
    if (heights == null) return null;
    final scroll = widget.scrollController;
    return heights.topOf(line) - (scroll.hasClients ? scroll.offset : 0.0);
  }

  TextPosition _local(TextPosition position, int line) => TextPosition(
    offset: math.min(
      position.offset - _lines.startOf(line),
      _lines[line].length,
    ),
    affinity: position.affinity,
  );

  /// Shows the caret once the frame is laid out, and again after the next
  /// one if lines measured on the way moved it.
  void _scheduleReveal([int attempts = 3]) {
    if (_revealScheduled || attempts == 0) return;
    _revealScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _revealScheduled = false;
      if (!mounted || !_value.selection.isValid) return;
      if (bringIntoView(_value.selection.extent)) _scheduleReveal(attempts - 1);
    });
  }

  /// Scrolls the least distance that shows the caret at [position], and
  /// says whether it scrolled. The end of the note is landed on exactly,
  /// measuring the last screenful first.
  bool bringIntoView(TextPosition position) {
    final scroll = widget.scrollController;
    if (!scroll.hasClients) return false;
    final scrollPosition = scroll.position;
    if (position.offset >= _text.length) {
      if (scrollPosition.pixels >= scrollPosition.maxScrollExtent) {
        return false;
      }
      layout.jumpToEnd();
      return true;
    }
    final caret = _caretRect(position);
    if (caret == null) return false;
    final viewport = scrollPosition.viewportDimension;
    final double by;
    if (caret.top < 0 || caret.height >= viewport) {
      by = caret.top;
    } else if (caret.bottom > viewport) {
      by = caret.bottom - viewport;
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

  @override
  TextRange getWordBoundary(TextPosition position) {
    final line = _lines.lineAt(position.offset);
    final start = _lines.startOf(line);
    final word = layout
        .paragraphOf(line)
        .getWordBoundary(_local(position, line));
    final length = _lines[line].length;
    return TextRange(
      start: start + math.min(word.start, length),
      end: start + math.min(word.end, length),
    );
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
    final x = run != null && run.selection == selection
        ? run.x
        : _caretRect(extent)?.left ?? 0;
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
    _spansIn = _controller.spansIn(
      context,
      widget.style,
      composing: _composing ? _value.composing : null,
    );
    layout.restyled();
    return Actions(
      actions: _actions,
      child: UndoHistory<TextEditingValue>(
        value: _controller,
        controller: widget.undoController,
        focusNode: widget.focusNode,
        onTriggered: (value) =>
            userUpdateTextEditingValue(value, SelectionChangedCause.keyboard),
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
          child: CustomScrollView(
            controller: widget.scrollController,
            scrollBehavior: ScrollConfiguration.of(
              context,
            ).copyWith(overscroll: false),
            slivers: [NoteSliver(layout: layout)],
          ),
        ),
      ),
    );
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

bool _isLowSurrogate(int unit) => unit & 0xFC00 == 0xDC00;
