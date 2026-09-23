import 'dart:math' as math;
import 'dart:ui' show BoxHeightStyle, BoxWidthStyle;

// Needed for the key types the Tab handling below reads: material_ui does not
// re-export KeyDownEvent, LogicalKeyboardKey or HardwareKeyboard.
import 'package:flutter/rendering.dart' show RenderEditable;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../compact_icon_button.dart';
import 'markdown_syntax.dart';

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
  Rect? _bounds;
  double _tableLeft = 0;
  double _tableTop = 0;
  TextStyle _style = const TextStyle();
  TextAlign _textAlign = TextAlign.left;
  double _padding = 10;
  bool _showToolbar = true;
  Color _background = const Color(0x00000000);
  Color _toolbarBackground = const Color(0x00000000);

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
  VoidCallback? _onAddRowAbove;
  VoidCallback? _onAddRow;
  VoidCallback? _onRemoveRow;
  VoidCallback? _onAddColumnBefore;
  VoidCallback? _onAddColumn;
  VoidCallback? _onRemoveColumn;
  ValueChanged<MarkdownCellAlign>? _onAlign;
  VoidCallback? _onUndo;
  VoidCallback? _onRedo;
  MarkdownCellAlign _alignment = MarkdownCellAlign.start;

  /// Claims Tab, Shift+Tab, Return, Escape, undo and redo, and an arrow key
  /// pressed at the edge of the cell's words; every other key belongs to the
  /// field.
  ///
  /// Any other modifier is left alone, so `Ctrl+Tab` still walks to the next
  /// note — the same rule the note's own Tab handling follows — and Shift with
  /// an arrow still extends a selection.
  bool _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
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
    required Rect? bounds,
    required double tableLeft,
    required double tableTop,
    required String text,
    required bool caretAtStart,
    required bool reset,
    required TextStyle style,
    required TextAlign textAlign,
    required double padding,
    required bool showToolbar,
    required Color cursorColor,
    required Color background,
    required Color border,
    required Color toolbarBackground,
    required ValueChanged<String> onChanged,
    required VoidCallback onDone,
    required ValueChanged<Offset> onTapOutside,
    required ValueChanged<bool> onTab,
    required VoidCallback onEnter,
    required ValueChanged<AxisDirection> onArrow,
    required VoidCallback? onAddRowAbove,
    required VoidCallback onAddRow,
    required VoidCallback? onRemoveRow,
    required VoidCallback onAddColumnBefore,
    required VoidCallback onAddColumn,
    required VoidCallback? onRemoveColumn,
    required ValueChanged<MarkdownCellAlign> onAlign,
    required VoidCallback onUndo,
    required VoidCallback onRedo,
    required MarkdownCellAlign alignment,
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    _anchor = anchor;
    _bounds = bounds;
    _tableLeft = tableLeft;
    _tableTop = tableTop;
    _style = style;
    _textAlign = textAlign;
    _padding = padding;
    _showToolbar = showToolbar;
    _background = background;
    _toolbarBackground = toolbarBackground;
    _onChanged = onChanged;
    _onDone = onDone;
    _onTapOutside = onTapOutside;
    _onTab = onTab;
    _onEnter = onEnter;
    _onArrow = onArrow;
    _onAddRowAbove = onAddRowAbove;
    _onAddRow = onAddRow;
    _onRemoveRow = onRemoveRow;
    _onAddColumnBefore = onAddColumnBefore;
    _onAddColumn = onAddColumn;
    _onRemoveColumn = onRemoveColumn;
    _onAlign = onAlign;
    _onUndo = onUndo;
    _onRedo = onRedo;
    _alignment = alignment;
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
  void moveTo(
    Rect anchor, {
    Rect? bounds,
    double? tableLeft,
    double? tableTop,
  }) {
    if (_entry == null) return;
    if (anchor == _anchor &&
        (bounds == null || bounds == _bounds) &&
        (tableLeft == null || tableLeft == _tableLeft) &&
        (tableTop == null || tableTop == _tableTop)) {
      return;
    }
    _anchor = anchor;
    _bounds = bounds ?? _bounds;
    _tableLeft = tableLeft ?? _tableLeft;
    _tableTop = tableTop ?? _tableTop;
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
    _onAddRowAbove = null;
    _onAddRow = null;
    _onRemoveRow = null;
    _onAddColumnBefore = null;
    _onAddColumn = null;
    _onRemoveColumn = null;
    _onAlign = null;
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

  String _safe(String text) => text
      .replaceAll('\r\n', ' ')
      .replaceAll('\r', ' ')
      .replaceAll('\n', ' ')
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
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 2.0;
        const screenGap = 8.0;
        final bounds =
            editor._bounds ??
            Rect.fromLTWH(0, 0, constraints.maxWidth, constraints.maxHeight);

        // Above the table where there is room, so that no row of it is covered.
        // With the top of a long table scrolled away, it stays at the top of
        // the note instead — unless the cell being edited is up there, when it
        // goes under that cell.
        final above = editor._tableTop - _TableToolbar.height - gap;
        final double toolbarTop;
        if (above >= bounds.top) {
          toolbarTop = above;
        } else if (bounds.top + gap + _TableToolbar.height + gap <=
            anchor.top) {
          toolbarTop = bounds.top + gap;
        } else {
          toolbarTop = anchor.bottom + gap;
        }
        final toolbarLeft = editor._tableLeft
            .clamp(
              screenGap,
              math.max(
                screenGap,
                constraints.maxWidth - _TableToolbar.width - screenGap,
              ),
            )
            .toDouble();

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
                onTapOutside: (event) =>
                    editor._onTapOutside?.call(event.position),
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
            if (editor._showToolbar)
              Positioned(
                left: toolbarLeft,
                top: toolbarTop,
                child: TextFieldTapRegion(
                  groupId: editor,
                  child: ExcludeFocus(
                    child: _TableToolbar(
                      editor: editor,
                      background: editor._toolbarBackground,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
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

/// What can be done to the table around the open cell: add a row above or
/// below it, a column either side, align its column, or take its row or column
/// away.
///
/// Desktop only. On a phone the same actions sit in the note's footer, above
/// the keyboard, where a thumb already is — a bar floating over the note there
/// would cover the rows being edited.
class _TableToolbar extends StatelessWidget {
  const _TableToolbar({required this.editor, required this.background});

  final TableCellEditor editor;
  final Color background;

  static const double _button = 26;
  static const double _divider = 9;
  static const double height = _button + 2;
  static const double width = 9 * _button + 2 * _divider + 2;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final alignment = editor._alignment;
    Widget button(
      String key,
      KapyIconData icon,
      String tooltip,
      VoidCallback? onPressed, {
      bool selected = false,
    }) => CompactIconButton(
      key: ValueKey(key),
      extent: _button,
      tooltip: tooltip,
      selected: selected,
      foregroundColor: onPressed == null
          ? palette.textTertiary.withValues(alpha: 0.38)
          : selected
          ? palette.textPrimary
          : palette.textSecondary,
      onPressed: onPressed,
      icon: KapyIcon(icon, size: 15),
    );
    Widget align(
      String key,
      KapyIconData icon,
      String tooltip,
      MarkdownCellAlign to,
    ) => button(
      key,
      icon,
      tooltip,
      editor._onAlign == null ? null : () => editor._onAlign!(to),
      selected: alignment == to,
    );
    final divider = SizedBox(
      width: _divider,
      height: _button - 10,
      child: Center(
        child: SizedBox(
          width: 1,
          height: double.infinity,
          child: ColoredBox(color: palette.controlBorder),
        ),
      ),
    );

    return Material(
      key: const ValueKey('table-cell-toolbar'),
      color: background,
      elevation: 3,
      shadowColor: Colors.black26,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: palette.controlBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(1),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            button(
              'table-add-row-above',
              KapyIcons.tableRowAbove,
              'Insert row above',
              editor._onAddRowAbove,
            ),
            button(
              'table-add-row',
              KapyIcons.tableRowBelow,
              'Insert row below',
              editor._onAddRow,
            ),
            button(
              'table-add-column-before',
              KapyIcons.tableColumnLeft,
              'Insert column left',
              editor._onAddColumnBefore,
            ),
            button(
              'table-add-column',
              KapyIcons.tableColumnRight,
              'Insert column right',
              editor._onAddColumn,
            ),
            divider,
            align(
              'table-align-left',
              KapyIcons.alignLeft,
              'Align column left',
              MarkdownCellAlign.start,
            ),
            align(
              'table-align-center',
              KapyIcons.alignCenter,
              'Center column',
              MarkdownCellAlign.center,
            ),
            align(
              'table-align-right',
              KapyIcons.alignRight,
              'Align column right',
              MarkdownCellAlign.end,
            ),
            divider,
            button(
              'table-remove-row',
              KapyIcons.tableDeleteRow,
              'Delete row',
              editor._onRemoveRow,
            ),
            button(
              'table-remove-column',
              KapyIcons.tableDeleteColumn,
              'Delete column',
              editor._onRemoveColumn,
            ),
          ],
        ),
      ),
    );
  }
}
