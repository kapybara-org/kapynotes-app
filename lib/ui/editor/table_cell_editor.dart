import 'dart:math' as math;
import 'dart:ui' show BoxHeightStyle, BoxWidthStyle;

// Needed for the key types the Tab handling below reads: material_ui does not
// re-export KeyDownEvent, LogicalKeyboardKey or HardwareKeyboard.
import 'package:flutter/rendering.dart' show RenderEditable;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/platform.dart';
import 'table_controls.dart';

/// The field that opens over one cell of a table.
///
/// A table is drawn as a grid and its own text is hidden, so there is nothing in
/// the note to type into: the caret cannot sit among pipes nobody can see, and a
/// cell whose words wrap onto three lines has no single line of the note to be.
/// So a real [TextField] is placed exactly over the painted cell, holding that
/// cell's source, and every keystroke is spliced back into the one note string.
///
/// A real field rather than hand-rolled key handling, because everything a cell
/// needs comes with it: composition for an IME, selection handles and the edit
/// menu on a phone, and a caret that behaves.
///
/// It covers the whole painted cell, with the cell's own padding, alignment and
/// weight, so that opening it moves no word: the grid simply gains a caret.
///
/// It lives in the **root** overlay. The text pane clips its children, so a cell
/// on the first row would otherwise have its editor sliced off — the same reason
/// `LinkPopover` does this. It is an overlay rather than a route, so the mobile
/// popup keyboard policy leaves it alone and it can raise a keyboard.
class TableCellEditor extends ChangeNotifier {
  OverlayEntry? _entry;
  Rect _anchor = Rect.zero;
  TextStyle _style = const TextStyle();
  TextAlign _textAlign = TextAlign.left;
  double _padding = 10;
  Color _background = const Color(0x00000000);

  final TextEditingController field = TextEditingController();

  /// The handler sits on the field's own node, so Tab is seen before focus
  /// traversal can claim it. The note's field is watched the same way, one level
  /// above it.
  late final FocusNode focus = FocusNode(
    debugLabel: 'table cell',
    onKeyEvent: (node, event) =>
        _handleKey(event) ? KeyEventResult.handled : KeyEventResult.ignored,
  );

  ValueChanged<String>? _onChanged;
  VoidCallback? _onDone;
  ValueChanged<Offset>? _onTapOutside;
  ValueChanged<bool>? _onTab;
  VoidCallback? _onEnter;
  ValueChanged<AxisDirection>? _onArrow;
  ValueChanged<TableCommand>? _onCommand;
  ValueChanged<({Offset at, List<ContextMenuButtonItem> items})>?
  _onContextMenu;
  VoidCallback? _onUndo;
  VoidCallback? _onRedo;

  /// Claims Tab, Shift+Tab, Return, Escape, undo and redo, and an arrow key
  /// pressed at the edge of the cell's words; every other key belongs to the
  /// field.
  ///
  /// Any other modifier is left alone, so `Ctrl+Tab` still walks to the next
  /// note — the same rule the note's own Tab handling follows — and Shift with
  /// an arrow still extends a selection.
  bool _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    // A table's own shortcuts first: they are chords nothing in a cell uses.
    // Moving a column is not among them, because in a cell those keys extend
    // the selection by a word.
    if (tableCommandFor(event, columnMoves: false) case final command?) {
      _onCommand?.call(command);
      return true;
    }
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    final command = keyboard.isControlPressed || keyboard.isMetaPressed;
    if (command && !keyboard.isAltPressed) {
      if (key == LogicalKeyboardKey.keyZ) {
        (keyboard.isShiftPressed ? _onRedo : _onUndo)?.call();
        return true;
      }
      if (key == LogicalKeyboardKey.keyY && keyboard.isControlPressed) {
        _onRedo?.call();
        return true;
      }
    }
    if (key == LogicalKeyboardKey.escape) {
      _onDone?.call();
      return true;
    }
    final modified =
        keyboard.isControlPressed ||
        keyboard.isMetaPressed ||
        keyboard.isAltPressed;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (modified) return false;
      _onEnter?.call();
      return true;
    }
    final direction = switch (key) {
      LogicalKeyboardKey.arrowUp => AxisDirection.up,
      LogicalKeyboardKey.arrowDown => AxisDirection.down,
      LogicalKeyboardKey.arrowLeft => AxisDirection.left,
      LogicalKeyboardKey.arrowRight => AxisDirection.right,
      _ => null,
    };
    if (direction != null) {
      if (modified || keyboard.isShiftPressed || !_atEdge(direction)) {
        return false;
      }
      _onArrow?.call(direction);
      return true;
    }
    if (key != LogicalKeyboardKey.tab) return false;
    if (modified) return false;
    _onTab?.call(keyboard.isShiftPressed);
    return true;
  }

  /// Whether an arrow key has nowhere left to go inside the cell: Left with
  /// the caret before the first character, Right after the last, Up on the
  /// first line the words wrap onto, Down on the last.
  bool _atEdge(AxisDirection direction) {
    final selection = field.selection;
    if (!selection.isValid || !selection.isCollapsed) return false;
    final offset = selection.baseOffset;
    final length = field.text.length;
    switch (direction) {
      case AxisDirection.left:
        return offset == 0;
      case AxisDirection.right:
        return offset == length;
      case AxisDirection.up:
      case AxisDirection.down:
        final editable = _renderEditable();
        if (editable == null) return true;
        double lineOf(int at) =>
            editable.getLocalRectForCaret(TextPosition(offset: at)).center.dy;
        final here = lineOf(offset);
        final edge = direction == AxisDirection.up ? lineOf(0) : lineOf(length);
        return (here - edge).abs() < 1;
    }
  }

  RenderEditable? _renderEditable() {
    final root = focus.context?.findRenderObject();
    if (root == null) return null;
    RenderEditable? found;
    void visit(RenderObject object) {
      if (found != null) return;
      if (object is RenderEditable) {
        found = object;
        return;
      }
      object.visitChildren(visit);
    }

    visit(root);
    return found;
  }

  bool get isVisible => _entry != null;
  Rect get anchor => _anchor;

  /// Opens over [anchor], or moves an open one there — which is how it follows
  /// the note as it scrolls, rather than being dismissed by the scroll the way a
  /// popover is.
  ///
  /// [reset] says the editor has moved to a different cell, so its words and
  /// caret start afresh — at the end of the words, or at the start when
  /// [caretAtStart], which is where Right from the cell before arrives. Showing
  /// the same cell again keeps the caret where the writer left it unless the
  /// words themselves have changed underneath it.
  void show(
    BuildContext context, {
    required Rect anchor,
    required String text,
    required bool caretAtStart,
    required bool reset,
    required TextStyle style,
    required TextAlign textAlign,
    required double padding,
    required Color cursorColor,
    required Color background,
    required Color border,
    required ValueChanged<String> onChanged,
    required VoidCallback onDone,
    required ValueChanged<Offset> onTapOutside,
    required ValueChanged<bool> onTab,
    required VoidCallback onEnter,
    required ValueChanged<AxisDirection> onArrow,
    required ValueChanged<TableCommand> onCommand,
    required ValueChanged<({Offset at, List<ContextMenuButtonItem> items})>
    onContextMenu,
    required VoidCallback onUndo,
    required VoidCallback onRedo,
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    _anchor = anchor;
    _style = style;
    _textAlign = textAlign;
    _padding = padding;
    _background = background;
    _onChanged = onChanged;
    _onDone = onDone;
    _onTapOutside = onTapOutside;
    _onTab = onTab;
    _onEnter = onEnter;
    _onArrow = onArrow;
    _onCommand = onCommand;
    _onContextMenu = onContextMenu;
    _onUndo = onUndo;
    _onRedo = onRedo;
    if (reset || field.text != text) {
      field.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(
          offset: caretAtStart ? 0 : text.length,
        ),
      );
    }

    if (_entry != null) {
      _entry!.markNeedsBuild();
      notifyListeners();
      focus.requestFocus();
      return;
    }

    _entry = OverlayEntry(
      builder: (context) => _TableCellEditorBody(
        editor: this,
        cursorColor: cursorColor,
        border: border,
      ),
    );
    overlay.insert(_entry!);
    notifyListeners();
    focus.requestFocus();
  }

  /// Moves an already open editor, for a scroll or a re-layout.
  void moveTo(Rect anchor) {
    if (_entry == null || anchor == _anchor) return;
    _anchor = anchor;
    _entry!.markNeedsBuild();
  }

  void hide() {
    if (_entry == null) return;
    _entry!.remove();
    _entry = null;
    _onChanged = null;
    _onDone = null;
    _onTapOutside = null;
    _onTab = null;
    _onEnter = null;
    _onArrow = null;
    _onCommand = null;
    _onContextMenu = null;
    _onUndo = null;
    _onRedo = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _entry?.remove();
    _entry = null;
    field.dispose();
    focus.dispose();
    super.dispose();
  }
}

/// Keeps one field valid as table source before it reaches the note.
///
/// The pure mutation layer repeats the same checks because edits do not all
/// originate in this widget. Doing it here as well keeps paste and dictation
/// from briefly turning the field into a different value and moving its caret
/// when the note rebuilds.
class _TableCellInputFormatter extends TextInputFormatter {
  const _TableCellInputFormatter();

  /// A cell holds one line of source: pasted lines are kept apart as the
  /// <br> a cell draws as a line break, and a bare pipe is escaped so it
  /// can't end the cell.
  String _safe(String text) => text
      .replaceAll(RegExp(r'[ \t]*(\r\n|\r|\n)+[ \t]*'), '<br>')
      .replaceAll(RegExp(r'(?<!\\)\|'), r'\|');

  int _map(String text, int offset) =>
      _safe(text.substring(0, offset.clamp(0, text.length))).length;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = _safe(newValue.text);
    if (text == newValue.text) return newValue;
    return TextEditingValue(
      text: text,
      selection: TextSelection(
        baseOffset: _map(newValue.text, newValue.selection.baseOffset),
        extentOffset: _map(newValue.text, newValue.selection.extentOffset),
        affinity: newValue.selection.affinity,
        isDirectional: newValue.selection.isDirectional,
      ),
    );
  }
}

class _TableCellEditorBody extends StatelessWidget {
  const _TableCellEditorBody({
    required this.editor,
    required this.cursorColor,
    required this.border,
  });

  final TableCellEditor editor;
  final Color cursorColor;
  final Color border;

  /// The gap `RenderEditable` keeps free for its caret at the end of every
  /// line — [EditableText]'s one-pixel caret gap plus the caret itself. Taken
  /// off the right padding so that the words wrap exactly where the grid's
  /// painter wrapped them.
  static const _cursorWidth = 1.7;
  static const _caretMargin = 1 + _cursorWidth;

  @override
  Widget build(BuildContext context) {
    final anchor = editor._anchor;
    return Stack(
      children: [
        Positioned(
          left: anchor.left,
          top: anchor.top,
          width: anchor.width,
          // Deliberately no height. The cell is at least as tall as its
          // painted row, and grows with its words rather than scrolling them
          // away, exactly as the row itself will once they reach the note.
          child: TapRegion(
            groupId: editor,
            // This remains active even while the field briefly loses
            // focus during a note rebuild. Unlike a full-screen Listener,
            // it observes the press without blocking the note underneath.
            onTapOutside: (event) => editor._onTapOutside?.call(event.position),
            child: Material(
              // A TextField requires a Material ancestor, and the root
              // overlay sits above the one the Scaffold provides. Opaque:
              // the painted words under it must not show through.
              color: editor._background,
              child: DecoratedBox(
                // In front of the words rather than around them, so the
                // outline takes no room and moves nothing.
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                  border: Border.all(color: border, width: 1.5),
                  borderRadius: BorderRadius.circular(2),
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: anchor.height),
                  child: Align(
                    // Centred in the row, as the grid centres its words.
                    alignment: Alignment.centerLeft,
                    heightFactor: 1,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        editor._padding,
                        0,
                        math.max(0, editor._padding - _caretMargin),
                        0,
                      ),
                      child: _field(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _field() => TextField(
    key: const ValueKey('table-cell-editor'),
    groupId: editor,
    controller: editor.field,
    focusNode: editor.focus,
    style: editor._style,
    textAlign: editor._textAlign,
    cursorColor: cursorColor,
    cursorWidth: _cursorWidth,
    cursorRadius: const Radius.circular(1),
    maxLines: null,
    expands: false,
    // A cell is one line of the note however many lines its words wrap onto,
    // so Return moves down rather than splitting the row.
    keyboardType: TextInputType.text,
    textInputAction: TextInputAction.next,
    onSubmitted: (_) => editor._onEnter?.call(),
    onChanged: (value) => editor._onChanged?.call(value),
    // With a pointer, a right-click in the cell gets the table's own menu,
    // which leads with this field's Cut, Copy and Paste. A phone keeps its
    // familiar toolbar around the selection handles.
    contextMenuBuilder: AppPlatform.hasPointer
        ? (context, state) {
            final items = state.contextMenuButtonItems;
            final at = state.contextMenuAnchors.primaryAnchor;
            state.hideToolbar(false);
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => editor._onContextMenu?.call((at: at, items: items)),
            );
            return const SizedBox.shrink();
          }
        : null,
    inputFormatters: const [_TableCellInputFormatter()],
    // The same refusals the note itself makes: the calculator must never have
    // a value, operator or unit rewritten.
    autocorrect: false,
    enableSuggestions: false,
    textCapitalization: TextCapitalization.none,
    smartDashesType: SmartDashesType.disabled,
    smartQuotesType: SmartQuotesType.disabled,
    selectionHeightStyle: BoxHeightStyle.strut,
    selectionWidthStyle: BoxWidthStyle.tight,
    decoration: const InputDecoration(
      isCollapsed: true,
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      filled: false,
      hoverColor: Colors.transparent,
      contentPadding: EdgeInsets.zero,
    ),
  );
}
