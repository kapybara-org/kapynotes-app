import 'dart:math' as math;
import 'dart:ui' show BoxHeightStyle, BoxWidthStyle;

// Needed for the key types the Tab handling below reads: material_ui does not
// re-export KeyDownEvent, LogicalKeyboardKey or HardwareKeyboard.
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

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
/// It lives in the **root** overlay. The text pane clips its children, so a cell
/// on the first row would otherwise have its editor sliced off — the same reason
/// `LinkPopover` does this. It is an overlay rather than a route, so the mobile
/// popup keyboard policy leaves it alone and it can raise a keyboard.
class TableCellEditor extends ChangeNotifier {
  OverlayEntry? _entry;
  Rect _anchor = Rect.zero;
  TextStyle _style = const TextStyle();

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
  ValueChanged<bool>? _onTab;
  VoidCallback? _onEnter;
  VoidCallback? _onAddRow;
  VoidCallback? _onRemoveRow;
  VoidCallback? _onAddColumn;
  VoidCallback? _onRemoveColumn;
  VoidCallback? _onCycleAlignment;
  VoidCallback? _onUndo;
  VoidCallback? _onRedo;
  String _alignmentLabel = 'L';
  String _alignmentTooltip = 'Align column left';

  /// Claims Tab, Shift+Tab and Escape; every other key belongs to the field.
  ///
  /// Any other modifier is left alone, so `Ctrl+Tab` still walks to the next
  /// note — the same rule the note's own Tab handling follows.
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
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (keyboard.isControlPressed ||
          keyboard.isMetaPressed ||
          keyboard.isAltPressed) {
        return false;
      }
      _onEnter?.call();
      return true;
    }
    if (key != LogicalKeyboardKey.tab) return false;
    if (keyboard.isControlPressed ||
        keyboard.isMetaPressed ||
        keyboard.isAltPressed) {
      return false;
    }
    _onTab?.call(keyboard.isShiftPressed);
    return true;
  }

  bool get isVisible => _entry != null;
  Rect get anchor => _anchor;

  /// Opens over [anchor], or moves an open one there — which is how it follows
  /// the note as it scrolls, rather than being dismissed by the scroll the way a
  /// popover is.
  void show(
    BuildContext context, {
    required Rect anchor,
    required String text,
    required TextStyle style,
    required Color cursorColor,
    required Color background,
    required Color border,
    required ValueChanged<String> onChanged,
    required VoidCallback onDone,
    required ValueChanged<bool> onTab,
    required VoidCallback onEnter,
    required VoidCallback onAddRow,
    required VoidCallback? onRemoveRow,
    required VoidCallback onAddColumn,
    required VoidCallback? onRemoveColumn,
    required VoidCallback onCycleAlignment,
    required VoidCallback onUndo,
    required VoidCallback onRedo,
    required String alignmentLabel,
    required String alignmentTooltip,
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    _anchor = anchor;
    _style = style;
    _onChanged = onChanged;
    _onDone = onDone;
    _onTab = onTab;
    _onEnter = onEnter;
    _onAddRow = onAddRow;
    _onRemoveRow = onRemoveRow;
    _onAddColumn = onAddColumn;
    _onRemoveColumn = onRemoveColumn;
    _onCycleAlignment = onCycleAlignment;
    _onUndo = onUndo;
    _onRedo = onRedo;
    _alignmentLabel = alignmentLabel;
    _alignmentTooltip = alignmentTooltip;
    if (field.text != text) {
      field.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
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
        background: background,
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
    _onTab = null;
    _onEnter = null;
    _onAddRow = null;
    _onRemoveRow = null;
    _onAddColumn = null;
    _onRemoveColumn = null;
    _onCycleAlignment = null;
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
    required this.background,
    required this.border,
  });

  final TableCellEditor editor;
  final Color cursorColor;
  final Color background;
  final Color border;

  @override
  Widget build(BuildContext context) {
    final anchor = editor._anchor;
    return LayoutBuilder(
      builder: (context, constraints) {
        const screenGap = 8.0;
        const toolbarGap = 4.0;
        const toolbarHeight = 32.0;
        const toolbarWidth = 5 * _TableToolButton.width;
        final media = MediaQuery.of(context);
        final safeTop = media.padding.top + screenGap;
        final safeBottom =
            constraints.maxHeight -
            media.padding.bottom -
            media.viewInsets.bottom -
            screenGap;
        final keyboardUp = media.viewInsets.bottom > 0;
        final editorTop = keyboardUp
            ? math
                  .min(anchor.top, safeBottom - math.max(anchor.height, 29))
                  .clamp(safeTop, safeBottom)
                  .toDouble()
            : anchor.top;
        final toolbarLeft = anchor.left
            .clamp(
              screenGap,
              math.max(
                screenGap,
                constraints.maxWidth - toolbarWidth - screenGap,
              ),
            )
            .toDouble();
        var toolbarTop = editorTop - toolbarHeight - toolbarGap;
        if (keyboardUp && toolbarTop < safeTop) {
          toolbarTop = math.min(
            safeBottom - toolbarHeight,
            editorTop + math.max(anchor.height, 29) + toolbarGap,
          );
        }

        return Stack(
          children: [
            Positioned(
              left: anchor.left,
              top: editorTop,
              width: anchor.width,
              // Deliberately no height. The field sizes to its own words, so a
              // cell whose text wraps grows exactly as its painted row does.
              child: TapRegion(
                groupId: editor,
                // This remains active even while the field briefly loses
                // focus during a note rebuild. Unlike a full-screen Listener,
                // it observes the press without blocking the note underneath.
                onTapOutside: (_) => editor._onDone?.call(),
                child: Material(
                  // A TextField requires a Material ancestor, and the root
                  // overlay sits above the one the Scaffold provides.
                  color: background,
                  shape: RoundedRectangleBorder(
                    side: BorderSide(color: border, width: 1.5),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Padding(
                    // The cell's own padding, so the words sit where the grid
                    // drew them and editing does not shift them sideways.
                    padding: const EdgeInsets.symmetric(horizontal: 9),
                    child: TextField(
                      key: const ValueKey('table-cell-editor'),
                      groupId: editor,
                      controller: editor.field,
                      focusNode: editor.focus,
                      style: editor._style,
                      cursorColor: cursorColor,
                      cursorWidth: 1.7,
                      cursorRadius: const Radius.circular(1),
                      maxLines: null,
                      expands: false,
                      // A cell is one line of the note however many lines its
                      // words wrap onto, so Return moves down rather than
                      // splitting the row.
                      keyboardType: TextInputType.text,
                      textInputAction: TextInputAction.next,
                      onSubmitted: (_) => editor._onEnter?.call(),
                      onChanged: (value) => editor._onChanged?.call(value),
                      inputFormatters: const [_TableCellInputFormatter()],
                      // The same refusals the note itself makes: the calculator
                      // must never have a value, operator or unit rewritten.
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
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: toolbarLeft,
              top: toolbarTop,
              child: TextFieldTapRegion(
                groupId: editor,
                child: ExcludeFocus(
                  child: Material(
                    key: const ValueKey('table-cell-toolbar'),
                    color: background,
                    elevation: 2,
                    shadowColor: Colors.black26,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(7),
                      side: BorderSide(color: border.withValues(alpha: 0.55)),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _TableToolButton(
                          key: const ValueKey('table-add-row'),
                          label: 'R+',
                          tooltip: 'Add row below',
                          onPressed: editor._onAddRow,
                        ),
                        _TableToolButton(
                          key: const ValueKey('table-remove-row'),
                          label: 'R−',
                          tooltip: 'Remove row',
                          onPressed: editor._onRemoveRow,
                        ),
                        _TableToolButton(
                          key: const ValueKey('table-add-column'),
                          label: 'C+',
                          tooltip: 'Add column after',
                          onPressed: editor._onAddColumn,
                        ),
                        _TableToolButton(
                          key: const ValueKey('table-remove-column'),
                          label: 'C−',
                          tooltip: 'Remove column',
                          onPressed: editor._onRemoveColumn,
                        ),
                        _TableToolButton(
                          key: const ValueKey('table-align-column'),
                          label: editor._alignmentLabel,
                          tooltip: editor._alignmentTooltip,
                          onPressed: editor._onCycleAlignment,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _TableToolButton extends StatelessWidget {
  const _TableToolButton({
    super.key,
    required this.label,
    required this.tooltip,
    required this.onPressed,
  });

  static const width = 40.0;

  final String label;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurface;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: onPressed != null,
        label: tooltip,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(
            width: width,
            height: 32,
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  color: onPressed == null
                      ? color.withValues(alpha: 0.28)
                      : color.withValues(alpha: 0.72),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  height: 1,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
