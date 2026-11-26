import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// A text field that is not an [EditableText] and can still take what was
/// typed while it was on its way.
abstract interface class TypeAheadField {
  /// Puts [text] in place of the selection, as typing it would.
  void takeTyping(String text);
}

/// Keeps the keys typed just after a shortcut that opens a field, and gives
/// them to that field once it has the keyboard (KAP-388).
///
/// A field opened by a shortcut takes the keyboard on a later frame: its
/// note, menu or bubble has to be built first. Until then the field the
/// person was in still has it, so on a slow frame whatever they type next
/// lands there. With a selection, as after select all, that replaces it, and
/// after a new note the old note's editor goes with its undo history on that
/// same frame.
///
/// [hold] takes those keys before the focused field sees them. Letters,
/// spaces, ↵ and ⌫ are kept, other plain keys are dropped, and a paste is
/// kept to be done in the new field. Chords with ⌘ or Ctrl still reach the
/// shortcuts, apart from the ones that edit (cut, undo, redo, delete), which
/// are dropped. Once the keyboard has moved, or after a few frames when it
/// stays where it was, everything kept goes into the field that has it, in
/// the order it was typed.
abstract final class TypeAhead {
  static _Hold? _hold;

  /// Starts keeping keys, from the shortcut that opens a field. A second
  /// call while keys are kept adds to the same hold.
  static void hold() {
    if (_hold != null) return;
    final hold = _hold = _Hold(FocusManager.instance.primaryFocus);
    FocusManager.instance.addEarlyKeyEventHandler(hold.key);
    hold.nextFrame();
  }
}

final class _Hold {
  _Hold(this.from);

  /// Where the keyboard was when the hold began.
  final FocusNode? from;

  /// What was typed, in order: text, or [_paste].
  final List<Object> typed = [];
  var _frames = 0;
  var _releasing = false;

  static const _paste = Object();
  static const _maxFrames = 4;

  KeyEventResult key(KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.backspace) {
      _erase();
      return KeyEventResult.handled;
    }
    if (keys.isControlPressed || keys.isMetaPressed) {
      if (key == LogicalKeyboardKey.keyV) {
        typed.add(_paste);
        return KeyEventResult.handled;
      }
      return key == LogicalKeyboardKey.keyX ||
              key == LogicalKeyboardKey.keyZ ||
              key == LogicalKeyboardKey.keyY ||
              key == LogicalKeyboardKey.delete
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      typed.add('\n');
      return KeyEventResult.handled;
    }
    final character = event.character;
    if (character != null &&
        character.isNotEmpty &&
        character.runes.every((rune) => rune >= 0x20 && rune != 0x7f)) {
      typed.add(character);
    }
    return KeyEventResult.handled;
  }

  void _erase() {
    if (typed.isEmpty) return;
    final last = typed.removeLast();
    if (last is! String) return;
    final runes = last.runes.toList()..removeLast();
    if (runes.isNotEmpty) typed.add(String.fromCharCodes(runes));
  }

  /// Looks again as the next frame begins, when the one before it and the
  /// focus changes it asked for are done.
  void nextFrame() =>
      SchedulerBinding.instance.scheduleFrameCallback((_) => _settle());

  void _settle() {
    if (TypeAhead._hold != this || _releasing) return;
    _frames++;
    final focused = FocusManager.instance.primaryFocus;
    if (focused == from && _frames < _maxFrames) return nextFrame();
    unawaited(_release(focused?.context));
  }

  Future<void> _release(BuildContext? context) async {
    _releasing = true;
    try {
      var i = 0;
      while (i < typed.length) {
        if (context == null || !context.mounted) break;
        if (identical(typed[i], _paste)) {
          i++;
          final pasted = Actions.maybeInvoke(
            context,
            const PasteTextIntent(SelectionChangedCause.keyboard),
          );
          await (pasted is Future
              ? pasted
              : Clipboard.getData(Clipboard.kTextPlain));
          continue;
        }
        final text = StringBuffer();
        while (i < typed.length && typed[i] is String) {
          text.write(typed[i++]);
        }
        _type(context, text.toString());
      }
    } finally {
      FocusManager.instance.removeEarlyKeyEventHandler(key);
      TypeAhead._hold = null;
    }
  }

  /// Puts [text] into the field [context], the keyboard's focus, belongs to.
  static void _type(BuildContext context, String text) {
    context.visitAncestorElements((element) {
      if (element is! StatefulElement) return true;
      switch (element.state) {
        case final TypeAheadField field:
          field.takeTyping(text);
        case final EditableTextState field when !field.widget.readOnly:
          final value = field.textEditingValue;
          final selection = value.selection.isValid
              ? value.selection
              : TextSelection.collapsed(offset: value.text.length);
          field.userUpdateTextEditingValue(
            value.replaced(selection, text),
            SelectionChangedCause.keyboard,
          );
        case EditableTextState():
          break;
        default:
          return true;
      }
      return false;
    });
  }
}
