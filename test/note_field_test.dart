// The note's text field as the platform's text input client, with the
// platform sent a window of the note around the selection.
//
// The platform side is FakeMacTextInput, which keeps the macOS plugin's model
// and sends the deltas the plugin sends for an input method and the keyboard.
import 'package:flutter/gestures.dart';
import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/calc/highlight.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/editor/highlighting_controller.dart';
import 'package:kapy_notes/ui/editor/note_field.dart';
import 'package:kapy_notes/ui/editor/note_sliver.dart';
import 'package:material_ui/material_ui.dart';

import 'support/fake_mac_text_input.dart';

final _macOS = TargetPlatformVariant.only(TargetPlatform.macOS);

/// [count] lines of about 28 characters, each one row: 1,000 of them are
/// 28 KB, seven times the window.
String _note(int count) =>
    [for (var i = 0; i < count; i++) 'Line $i, a few words in it.'].join('\n');

int _lineStart(String text, int line) {
  var offset = 0;
  for (var i = 0; i < line; i++) {
    offset = text.indexOf('\n', offset) + 1;
  }
  return offset;
}

NoteField _field(
  HighlightingController controller,
  FocusNode focusNode,
  ScrollController scroll, {
  bool readOnly = false,
  List<TextInputFormatter> inputFormatters = const [],
}) => NoteField(
  controller: controller,
  focusNode: focusNode,
  scrollController: scroll,
  style: EditorMetrics.textStyle(
    const Color(0xFF000000),
    WritingFont.handwritten,
  ),
  strut: EditorMetrics.strut(WritingFont.handwritten),
  readOnly: readOnly,
  autofocus: true,
  inputFormatters: inputFormatters,
);

Widget _app(NoteField field) => MaterialApp(
  theme: KapyTheme.light(),
  home: Align(
    alignment: Alignment.topLeft,
    child: SizedBox(
      width: EditorMetrics.columnWidth,
      height: 600,
      child: field,
    ),
  ),
);

/// A focused field over [text], 600 high.
Future<NoteFieldState> _pumpField(
  WidgetTester tester,
  String text, {
  bool readOnly = false,
  List<TextInputFormatter> inputFormatters = const [],
}) async {
  final controller = HighlightingController(
    highlighter: Highlighter(CalcEngine().registry),
    palette: KapyTheme.lightPalette,
    writingFont: WritingFont.handwritten,
    text: text,
  );
  addTearDown(controller.dispose);
  final focusNode = FocusNode();
  addTearDown(focusNode.dispose);
  final scroll = ScrollController();
  addTearDown(scroll.dispose);
  await tester.pumpWidget(
    _app(
      _field(
        controller,
        focusNode,
        scroll,
        readOnly: readOnly,
        inputFormatters: inputFormatters,
      ),
    ),
  );
  await tester.pump();
  return tester.state<NoteFieldState>(find.byType(NoteField));
}

/// Moves the selection as a click would.
Future<void> _select(
  WidgetTester tester,
  NoteFieldState field,
  TextSelection selection,
) async {
  field.userUpdateTextEditingValue(
    field.widget.controller.value.copyWith(selection: selection),
    SelectionChangedCause.tap,
  );
  await tester.pump();
}

/// Checks that the platform holds a stretch of the note, with the selection
/// and anything being composed at the same places in it, and returns where
/// the stretch starts.
int _expectInSync(NoteFieldState field, FakeMacTextInput ime) {
  ime.sync();
  final value = field.widget.controller.value;
  final start = value.selection.baseOffset - ime.selectionBase;
  expect(start, greaterThanOrEqualTo(0));
  expect(value.text.substring(start, start + ime.text.length), ime.text);
  expect(ime.selectionExtent + start, value.selection.extentOffset);
  final composing = value.composing;
  expect(ime.composingActive, composing.isValid && !composing.isCollapsed);
  if (ime.composingActive) {
    expect(
      TextRange(
        start: ime.composingBase + start,
        end: ime.composingExtent + start,
      ),
      composing,
    );
  }
  return start;
}

/// How many editing states the field has sent the platform.
int _sent(WidgetTester tester) => tester.testTextInput.log
    .where((call) => call.method == 'TextInput.setEditingState')
    .length;

Map<String, Object?> _lastCall(WidgetTester tester, String method) =>
    (tester.testTextInput.log
                .lastWhere((call) => call.method == method)
                .arguments
            as Map<Object?, Object?>)
        .cast<String, Object?>();

Rect _rect(Map<String, Object?> arguments) => Rect.fromLTWH(
  arguments['x']! as double,
  arguments['y']! as double,
  arguments['width']! as double,
  arguments['height']! as double,
);

Future<void> _command(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pump();
}

/// A clipboard the test keeps, holding [text] to begin with: what is on it.
String? Function() _clipboard(WidgetTester tester, [String? text]) {
  var clipboard = text;
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    switch (call.method) {
      case 'Clipboard.setData':
        clipboard =
            (call.arguments as Map<Object?, Object?>)['text'] as String?;
      case 'Clipboard.getData':
        return <String, Object?>{'text': clipboard};
      case 'Clipboard.hasStrings':
        return <String, Object?>{'value': clipboard?.isNotEmpty ?? false};
    }
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
  return () => clipboard;
}

/// The middle of [line]'s first row on the screen, [dx] in from the
/// field's left.
Offset _rowOf(
  WidgetTester tester,
  NoteFieldState field,
  int line, {
  double dx = 8,
}) {
  final top =
      field.layout.heights!.topOf(line) - field.widget.scrollController.offset;
  final row = field.layout.paragraphOf(line).preferredLineHeight;
  return tester.getTopLeft(find.byType(NoteField)) + Offset(dx, top + row / 2);
}

/// What draws [line].
RenderNoteLine _drawn(WidgetTester tester, int line) => tester.allRenderObjects
    .whereType<RenderNoteLine>()
    .firstWhere((object) => object.line == line);

/// The selection handle at the selection's start or end, following its
/// line.
Finder _handle(NoteFieldState field, {required bool start}) {
  final handles = field.layout.marks.handles!;
  final link = start ? handles.start : handles.end;
  return find.byWidgetPredicate(
    (widget) => widget is CompositedTransformFollower && widget.link == link,
  );
}

/// How far [handle] has faded in.
double _opacity(WidgetTester tester, Finder handle) => tester
    .widget<FadeTransition>(
      find.descendant(of: handle, matching: find.byType(FadeTransition)).first,
    )
    .opacity
    .value;

/// A focused field over [text], settled with the caret at the note's start
/// and its first line at the top.
Future<NoteFieldState> _pumpFieldAtStart(
  WidgetTester tester,
  String text,
) async {
  final field = await _pumpField(tester, text);
  await _select(tester, field, const TextSelection.collapsed(offset: 0));
  await tester.pumpAndSettle();
  return field;
}

/// Clicks [times] in a row at [at] with the mouse's [buttons], then waits
/// until another click would begin a new run.
Future<void> _click(
  WidgetTester tester,
  Offset at, {
  int times = 1,
  int buttons = kPrimaryButton,
}) async {
  final mouse = await tester.createGesture(
    kind: PointerDeviceKind.mouse,
    buttons: buttons,
  );
  for (var i = 0; i < times; i++) {
    await mouse.down(at);
    await tester.pump();
    await mouse.up();
    await tester.pump(const Duration(milliseconds: 50));
  }
  await mouse.removePointer();
  await tester.pump(kDoubleTapTimeout * 2);
}

void main() {
  testWidgets(
    'the platform holds whole lines around the caret, and typing lands in the note',
    (tester) async {
      final text = _note(1000);
      final field = await _pumpField(tester, text);
      final controller = field.widget.controller;
      final ime = FakeMacTextInput(tester);
      final caret = _lineStart(text, 500) + 'Line 500'.length;
      await _select(tester, field, TextSelection.collapsed(offset: caret));
      final start = _expectInSync(field, ime);
      final end = start + ime.text.length;
      expect(text.length, greaterThan(25000));
      expect(end - start, inInclusiveRange(4096, 4160));
      expect(text[start - 1], '\n');
      expect(text[end], '\n');

      await ime.insertText('x');
      expect(controller.text, text.replaceRange(caret, caret, 'x'));
      expect(controller.selection, TextSelection.collapsed(offset: caret + 1));
      _expectInSync(field, ime);
      expect(
        ime.editingStates,
        everyElement(lessThan(4160)),
        reason: 'the platform is never sent the whole note',
      );
    },
    variant: _macOS,
  );

  testWidgets(
    'Japanese kana composes and commits to kanji with nothing sent back while composing',
    (tester) async {
      final text = _note(1000);
      final field = await _pumpField(tester, text);
      final controller = field.widget.controller;
      final ime = FakeMacTextInput(tester);
      final caret = _lineStart(text, 500) + 'Line 500'.length;
      await _select(tester, field, TextSelection.collapsed(offset: caret));
      final start = _expectInSync(field, ime);
      final sent = _sent(tester);

      for (final kana in const ['ｋ', 'か', 'かｎ', 'かん', 'かんｊ', 'かんじ']) {
        await ime.setMarkedText(kana);
        expect(
          controller.value.composing,
          TextRange(start: caret, end: caret + kana.length),
        );
        expect(
          controller.selection,
          TextSelection.collapsed(offset: caret + kana.length),
        );
        expect(_expectInSync(field, ime), start);
      }

      // Space converts, and the input method selects the converted clause.
      await ime.setMarkedText('漢字', selectedLocation: 0, selectedLength: 2);
      expect(controller.text.substring(caret, caret + 2), '漢字');
      expect(
        controller.value.composing,
        TextRange(start: caret, end: caret + 2),
      );
      expect(
        controller.selection,
        TextSelection(baseOffset: caret, extentOffset: caret + 2),
      );
      _expectInSync(field, ime);

      // Return commits.
      await ime.insertText('漢字');
      expect(controller.value.composing, TextRange.empty);
      expect(controller.selection, TextSelection.collapsed(offset: caret + 2));
      expect(controller.text, text.replaceRange(caret, caret, '漢字'));
      expect(_sent(tester), sent, reason: 'the platform made every change');
      _expectInSync(field, ime);
    },
    variant: _macOS,
  );

  testWidgets(
    "a composition near the window's end grows the window and is never cut off",
    (tester) async {
      final text = _note(1000);
      final field = await _pumpField(tester, text);
      final controller = field.widget.controller;
      final ime = FakeMacTextInput(tester);
      await _select(
        tester,
        field,
        TextSelection.collapsed(offset: _lineStart(text, 500)),
      );
      final start = _expectInSync(field, ime);
      final end = start + ime.text.length;
      // As near the window's end as the caret comes without moving it.
      final caret = end - 520;
      await _select(tester, field, TextSelection.collapsed(offset: caret));
      expect(_expectInSync(field, ime), start);
      expect(ime.text.length, end - start);
      final sent = _sent(tester);

      var marked = '';
      for (var i = 0; i < 6; i++) {
        marked += 'あいうえおかきくけこ' * 10;
        await ime.setMarkedText(marked);
        expect(
          controller.value.composing,
          TextRange(start: caret, end: caret + marked.length),
        );
        expect(_expectInSync(field, ime), start);
        expect(ime.text.length, end - start + marked.length);
      }
      expect(caret + marked.length, greaterThan(end));
      await ime.insertText(marked);
      expect(controller.text, text.replaceRange(caret, caret, marked));
      expect(_sent(tester), sent);
      _expectInSync(field, ime);

      // A reconversion: the input method marks text just committed again,
      // through a replacement range that starts before the caret.
      final at = controller.selection.baseOffset;
      await ime.setMarkedText(
        'かな',
        replacement: TextRange(start: at - start - 3, end: at - start),
      );
      expect(controller.value.composing, TextRange(start: at - 3, end: at - 1));
      await ime.insertText('仮名');
      expect(controller.text.substring(at - 3, at - 1), '仮名');
      _expectInSync(field, ime);
    },
    variant: _macOS,
  );

  testWidgets(
    'an edit from elsewhere above the window moves it and sends the platform nothing, mid-composition too',
    (tester) async {
      final text = _note(1000);
      final field = await _pumpField(tester, text);
      final controller = field.widget.controller;
      final ime = FakeMacTextInput(tester);
      final caret = _lineStart(text, 500) + 4;
      await _select(tester, field, TextSelection.collapsed(offset: caret));
      await ime.setMarkedText('かん');
      final start = _expectInSync(field, ime);
      final sent = _sent(tester);

      const line = 'A line from another device.\n';
      final value = controller.value;
      controller.value = TextEditingValue(
        text: line + value.text,
        selection: TextSelection.collapsed(
          offset: value.selection.baseOffset + line.length,
        ),
        composing: TextRange(
          start: value.composing.start + line.length,
          end: value.composing.end + line.length,
        ),
      );
      await tester.pump();
      expect(_sent(tester), sent);
      expect(_expectInSync(field, ime), start + line.length);

      await ime.setMarkedText('かんじ');
      await ime.insertText('漢字');
      expect(controller.text, line + text.replaceRange(caret, caret, '漢字'));
      expect(_sent(tester), sent);
      _expectInSync(field, ime);
    },
    variant: _macOS,
  );

  testWidgets(
    'a key typed against the window the platform had before the last one lands where it was typed',
    (tester) async {
      final text = _note(1000);
      final field = await _pumpField(tester, text);
      final controller = field.widget.controller;
      final ime = FakeMacTextInput(tester);
      final caret = _lineStart(text, 500) + 4;
      await _select(tester, field, TextSelection.collapsed(offset: caret));
      _expectInSync(field, ime);

      // A click far below moves the window, and a key typed before the
      // platform has the new one arrives against the old.
      await _select(
        tester,
        field,
        TextSelection.collapsed(offset: _lineStart(text, 900)),
      );
      await ime.insertText('x', racing: true);
      expect(controller.text, text.replaceRange(caret, caret, 'x'));
      expect(controller.selection, TextSelection.collapsed(offset: caret + 1));
      expect(_expectInSync(field, ime), lessThan(caret));

      await ime.insertText('y');
      expect(controller.text, text.replaceRange(caret, caret, 'xy'));
      _expectInSync(field, ime);
    },
    variant: _macOS,
  );

  testWidgets(
    'a delta against text the platform was never sent changes nothing, and the platform gets the window again',
    (tester) async {
      final text = _note(200);
      final field = await _pumpField(tester, text);
      final controller = field.widget.controller;
      final ime = FakeMacTextInput(tester);
      await _select(
        tester,
        field,
        TextSelection.collapsed(offset: _lineStart(text, 100)),
      );
      _expectInSync(field, ime);
      final sent = _sent(tester);

      ime
        ..text = 'Something the field never sent.'
        ..selectionBase = 0
        ..selectionExtent = 0;
      await ime.insertText('x', racing: true);
      expect(controller.text, text);
      expect(_sent(tester), sent + 1);
      _expectInSync(field, ime);
    },
    variant: _macOS,
  );

  testWidgets(
    "arrow keys move the window on past its edge, keeping every offset mapped",
    (tester) async {
      final text = _note(1000);
      final field = await _pumpField(tester, text);
      final controller = field.widget.controller;
      final ime = FakeMacTextInput(tester);
      await _select(
        tester,
        field,
        TextSelection.collapsed(offset: _lineStart(text, 500) + 4),
      );
      final first = _expectInSync(field, ime);
      final firstEnd = first + ime.text.length;
      final starts = <int>{first};
      final sent = _sent(tester);

      for (var i = 0; i < 200; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        starts.add(_expectInSync(field, ime));
      }
      expect(
        controller.selection,
        TextSelection.collapsed(offset: _lineStart(text, 700) + 4),
      );
      expect(starts.length, greaterThan(3), reason: 'the window moved');
      expect(starts.last, greaterThan(firstEnd));
      expect(_sent(tester), sent + 200);

      // Typing after the moves lands at the caret.
      final caret = controller.selection.baseOffset;
      await ime.insertText('x');
      expect(controller.text, text.replaceRange(caret, caret, 'x'));
      _expectInSync(field, ime);

      // Back up past where the first window started, at the column after
      // the x.
      for (var i = 0; i < 300; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
      }
      expect(_expectInSync(field, ime), lessThan(first));
      expect(
        controller.selection,
        TextSelection.collapsed(offset: _lineStart(text, 400) + 5),
      );

      // Left across a line break, and shift-down selecting across lines.
      for (var i = 0; i < 6; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      }
      expect(
        controller.selection,
        TextSelection.collapsed(offset: _lineStart(text, 400) - 1),
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      }
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(
        controller.selection,
        TextSelection(
          baseOffset: _lineStart(text, 400) - 1,
          extentOffset: _lineStart(text, 403) - 1,
        ),
      );
      _expectInSync(field, ime);
    },
    variant: _macOS,
  );

  testWidgets('up and down keep to the column a run of them began at', (
    tester,
  ) async {
    // The first line is the note's title, in a larger face.
    const text =
        'Title\n'
        'A first line, past twenty.\n'
        'Short.\n'
        'A third line, past twenty.';
    final field = await _pumpField(tester, text);
    final controller = field.widget.controller;
    final first = text.indexOf('A first');
    final short = text.indexOf('\nA third');
    final third = text.indexOf('A third');
    await _select(tester, field, TextSelection.collapsed(offset: first + 20));
    for (final (key, offset) in [
      (LogicalKeyboardKey.arrowDown, short),
      (LogicalKeyboardKey.arrowDown, third + 20),
      (LogicalKeyboardKey.arrowUp, short),
      (LogicalKeyboardKey.arrowUp, first + 20),
    ]) {
      await tester.sendKeyEvent(key);
      await tester.pump();
      expect(controller.selection.baseOffset, offset);
    }
  });

  testWidgets(
    'command-down goes to the end, scrolls there exactly and takes the window along',
    (tester) async {
      final text = _note(1000);
      final field = await _pumpField(tester, text);
      final controller = field.widget.controller;
      final scroll = field.widget.scrollController;
      final ime = FakeMacTextInput(tester);
      await _select(
        tester,
        field,
        TextSelection.collapsed(offset: _lineStart(text, 10)),
      );
      await tester.pumpAndSettle();
      expect(scroll.position.pixels, lessThan(scroll.position.maxScrollExtent));

      await _command(tester, LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(
        controller.selection,
        TextSelection.collapsed(offset: text.length),
      );
      expect(scroll.position.pixels, scroll.position.maxScrollExtent);
      final start = _expectInSync(field, ime);
      expect(start + ime.text.length, text.length);

      await ime.insertText('!');
      expect(controller.text, '$text!');
      _expectInSync(field, ime);
    },
    variant: _macOS,
  );

  testWidgets(
    'backspace, option-backspace and return work through the window',
    (tester) async {
      final text = _note(1000);
      final field = await _pumpField(tester, text);
      final controller = field.widget.controller;
      final ime = FakeMacTextInput(tester);
      final caret = _lineStart(text, 400);
      await _select(tester, field, TextSelection.collapsed(offset: caret));

      // Backspace comes back from AppKit as deleteBackward:, which the field
      // does and then sends the platform.
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(controller.text, text.replaceRange(caret - 1, caret, ''));
      _expectInSync(field, ime);

      // Return is the plugin's insertNewline:, an insertText at its selection.
      await ime.insertText('\n');
      expect(controller.text, text);
      expect(controller.selection, TextSelection.collapsed(offset: caret));
      _expectInSync(field, ime);

      // Option-backspace takes the word before the caret.
      final word = caret + 'Line 400, a few'.length;
      await _select(tester, field, TextSelection.collapsed(offset: word));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(controller.text, text.replaceRange(word - 'few'.length, word, ''));
      _expectInSync(field, ime);
    },
    variant: _macOS,
  );

  testWidgets('the window never splits a surrogate pair', (tester) async {
    // Emoji starting at odd offsets, then at even ones.
    final text = 'a${'😀' * 5000}x${'😀' * 5000}';
    final field = await _pumpField(tester, text);
    final ime = FakeMacTextInput(tester);
    for (final caret in [10001, 10002]) {
      await _select(tester, field, const TextSelection.collapsed(offset: 0));
      await _select(tester, field, TextSelection.collapsed(offset: caret));
      _expectInSync(field, ime);
      expect(ime.text.length, lessThan(5000));
      expect(ime.text.codeUnitAt(0) & 0xFC00, isNot(0xDC00));
      expect(ime.text.codeUnitAt(ime.text.length - 1) & 0xFC00, isNot(0xD800));
    }
  }, variant: _macOS);

  testWidgets(
    'assistive tools get a text field holding the window, and what they set '
    'lands in the note',
    (tester) async {
      final handle = tester.ensureSemantics();
      final text = _note(1000);
      final field = await _pumpField(tester, text);
      final controller = field.widget.controller;
      final ime = FakeMacTextInput(tester);
      final caret = _lineStart(text, 500);
      await _select(tester, field, TextSelection.collapsed(offset: caret));
      final start = _expectInSync(field, ime);

      var node = tester.getSemantics(find.byType(NoteField));
      expect(
        node,
        isSemantics(
          isTextField: true,
          isMultiline: true,
          isFocused: true,
          isReadOnly: false,
          value: ime.text,
        ),
      );
      expect(
        node.textSelection,
        TextSelection.collapsed(offset: caret - start),
      );
      expect(node.value.length, lessThan(text.length ~/ 4));

      node.owner!.performAction(node.id, SemanticsAction.setSelection, {
        'base': caret - start,
        'extent': caret - start + 4,
      });
      await tester.pump();
      expect(
        controller.selection,
        TextSelection(baseOffset: caret, extentOffset: caret + 4),
      );

      node = tester.getSemantics(find.byType(NoteField));
      final windowStart = _expectInSync(field, ime);
      final written = node.value.replaceFirst('Line 500,', 'Row 500,');
      node.owner!.performAction(node.id, SemanticsAction.setText, written);
      await tester.pump();
      expect(controller.text, text.replaceFirst('Line 500,', 'Row 500,'));
      expect(
        controller.selection,
        TextSelection.collapsed(offset: windowStart + written.length),
      );
      _expectInSync(field, ime);
      expect(tester.getSemantics(find.byType(NoteField)).value, ime.text);
      handle.dispose();
    },
    variant: _macOS,
  );

  testWidgets('a read-only note is a read-only text field to assistive tools', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pumpField(tester, _note(3), readOnly: true);
    final node = tester.getSemantics(find.byType(NoteField));
    expect(node, isSemantics(isTextField: true, isReadOnly: true));
    expect(node.getSemanticsData().hasAction(SemanticsAction.setText), isFalse);
    expect(node.getSemanticsData().hasAction(SemanticsAction.paste), isFalse);
    handle.dispose();
  });

  testWidgets('a caret moved out of view is scrolled into it', (tester) async {
    final text = _note(1000);
    final field = await _pumpField(tester, text);
    await tester.pumpAndSettle();
    for (final line in [600, 120, 999, 0]) {
      await _select(
        tester,
        field,
        TextSelection.collapsed(offset: _lineStart(text, line) + 3),
      );
      await tester.pumpAndSettle();
      final caret = _rect(_lastCall(tester, 'TextInput.setCaretRect'));
      expect(caret.top, greaterThanOrEqualTo(0), reason: 'line $line');
      expect(caret.bottom, lessThanOrEqualTo(600), reason: 'line $line');
    }
  });

  testWidgets('undo and redo take typing back and forth', (tester) async {
    final text = _note(100);
    final field = await _pumpField(tester, text);
    final controller = field.widget.controller;
    final ime = FakeMacTextInput(tester);
    final caret = _lineStart(text, 50);
    await _select(tester, field, TextSelection.collapsed(offset: caret));
    await tester.pump(const Duration(seconds: 1));
    await ime.insertText('typed ');
    await tester.pump(const Duration(seconds: 1));

    await _command(tester, LogicalKeyboardKey.keyZ);
    expect(controller.text, text);
    _expectInSync(field, ime);

    await _command(tester, LogicalKeyboardKey.keyZ, shift: true);
    expect(controller.text, text.replaceRange(caret, caret, 'typed '));
    _expectInSync(field, ime);
  }, variant: _macOS);

  testWidgets('copy, cut, paste and select all', (tester) async {
    String? clipboard;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      switch (call.method) {
        case 'Clipboard.setData':
          clipboard =
              (call.arguments as Map<Object?, Object?>)['text'] as String?;
        case 'Clipboard.getData':
          return <String, Object?>{'text': clipboard};
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final text = _note(100);
    final field = await _pumpField(tester, text);
    final controller = field.widget.controller;
    final ime = FakeMacTextInput(tester);
    final start = _lineStart(text, 50);
    await _select(
      tester,
      field,
      TextSelection(baseOffset: start, extentOffset: start + 'Line 50'.length),
    );

    await _command(tester, LogicalKeyboardKey.keyC);
    expect(clipboard, 'Line 50');
    expect(controller.text, text);

    await _command(tester, LogicalKeyboardKey.keyX);
    final cut = text.replaceRange(start, start + 'Line 50'.length, '');
    expect(controller.text, cut);
    expect(controller.selection, TextSelection.collapsed(offset: start));
    _expectInSync(field, ime);

    await _select(tester, field, const TextSelection.collapsed(offset: 0));
    await _command(tester, LogicalKeyboardKey.keyV);
    await tester.pump();
    expect(controller.text, 'Line 50$cut');
    expect(controller.selection, const TextSelection.collapsed(offset: 7));
    _expectInSync(field, ime);

    await _command(tester, LogicalKeyboardKey.keyA);
    expect(
      controller.selection,
      TextSelection(baseOffset: 0, extentOffset: controller.text.length),
    );
    _expectInSync(field, ime);
  }, variant: _macOS);

  testWidgets(
    'the input method is told where the field, the caret and the composing text are',
    (tester) async {
      final text = _note(1000);
      final field = await _pumpField(tester, text);
      final ime = FakeMacTextInput(tester);
      await _select(
        tester,
        field,
        TextSelection.collapsed(
          offset: _lineStart(text, 500) + 'Line 500,'.length,
        ),
      );
      await tester.pumpAndSettle();
      final box = _lastCall(tester, 'TextInput.setEditableSizeAndTransform');
      expect(box['width'], EditorMetrics.columnWidth);
      expect(box['height'], 600);
      final caret = _rect(_lastCall(tester, 'TextInput.setCaretRect'));
      expect(caret.height, greaterThan(0));
      expect(caret.top, greaterThanOrEqualTo(0));
      expect(caret.bottom, lessThanOrEqualTo(600));

      await ime.setMarkedText('かんじ');
      await tester.pump();
      // The caret is drawn two pixels left of where the text goes, as
      // TextField draws it on Apple's platforms, and the platform is told
      // where it is drawn.
      final nudge = 2 / tester.view.devicePixelRatio;
      final marked = _rect(_lastCall(tester, 'TextInput.setMarkedTextRect'));
      expect(marked.left, moreOrLessEquals(caret.left + nudge, epsilon: 0.01));
      expect(marked.width, greaterThan(0));
      expect(marked.center.dy, inInclusiveRange(caret.top, caret.bottom));
      final after = _rect(_lastCall(tester, 'TextInput.setCaretRect'));
      expect(after.left + nudge, moreOrLessEquals(marked.right, epsilon: 0.01));
    },
    variant: _macOS,
  );

  testWidgets(
    'input formatters run over typing, and the platform gets what they made',
    (tester) async {
      final text = _note(200);
      final field = await _pumpField(
        tester,
        text,
        inputFormatters: [
          TextInputFormatter.withFunction(
            (oldValue, newValue) =>
                newValue.copyWith(text: newValue.text.replaceAll('!', '?')),
          ),
        ],
      );
      final controller = field.widget.controller;
      final ime = FakeMacTextInput(tester);
      final caret = _lineStart(text, 100);
      await _select(tester, field, TextSelection.collapsed(offset: caret));
      final sent = _sent(tester);
      await ime.insertText('!');
      expect(controller.text, text.replaceRange(caret, caret, '?'));
      expect(_sent(tester), sent + 1);
      _expectInSync(field, ime);
    },
    variant: _macOS,
  );

  testWidgets(
    'a read-only field takes no input, and a connection the platform closes lets go of focus',
    (tester) async {
      final field = await _pumpField(tester, _note(10), readOnly: true);
      final widget = field.widget;
      expect(widget.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.hasAnyClients, isFalse);

      await tester.pumpWidget(
        _app(
          _field(widget.controller, widget.focusNode, widget.scrollController),
        ),
      );
      expect(tester.testTextInput.hasAnyClients, isTrue);

      tester.testTextInput.closeConnection();
      await tester.pump();
      expect(widget.focusNode.hasFocus, isFalse);
    },
  );

  testWidgets('a point on the screen finds the note position under it', (
    tester,
  ) async {
    final text = _note(1000);
    final field = await _pumpFieldAtStart(tester, text);
    final origin = tester.getTopLeft(find.byType(NoteField));
    expect(
      field.positionAt(_rowOf(tester, field, 3, dx: 0)).offset,
      _lineStart(text, 3),
    );
    expect(
      field.positionAt(_rowOf(tester, field, 3, dx: 600)).offset,
      _lineStart(text, 4) - 1,
    );
    expect(field.positionAt(origin + const Offset(0, -40)).offset, 0);

    await _select(tester, field, TextSelection.collapsed(offset: text.length));
    await tester.pumpAndSettle();
    expect(field.widget.scrollController.offset, greaterThan(0));
    expect(
      field.positionAt(_rowOf(tester, field, 990, dx: 0)).offset,
      _lineStart(text, 990),
    );
    expect(
      field.positionAt(origin + const Offset(600, 640)).offset,
      text.length,
    );
  });

  testWidgets(
    'the caret blinks while the field has focus, and a selection is painted while it has',
    (tester) async {
      final text = _note(10);
      final field = await _pumpField(tester, text);
      final caret = _lineStart(text, 2) + 4;
      await _select(tester, field, TextSelection.collapsed(offset: caret));
      final color = field.layout.marks.caretColor;
      expect(color, isNotNull);
      expect(_drawn(tester, 2), paints..rrect(color: color));

      await tester.pump(const Duration(milliseconds: 500));
      expect(field.layout.marks.caretColor, isNull);
      expect(_drawn(tester, 2), isNot(paints..rrect()));
      await tester.pump(const Duration(milliseconds: 500));
      expect(field.layout.marks.caretColor, color);

      // Moving the caret holds it on for another half second.
      await tester.pump(const Duration(milliseconds: 400));
      await _select(tester, field, TextSelection.collapsed(offset: caret + 1));
      await tester.pump(const Duration(milliseconds: 400));
      expect(field.layout.marks.caretColor, color);

      await _select(
        tester,
        field,
        TextSelection(
          baseOffset: _lineStart(text, 3),
          extentOffset: _lineStart(text, 5),
        ),
      );
      final selection = field.layout.marks.selectionColor;
      expect(field.layout.marks.caretColor, isNull);
      expect(selection, isNotNull);
      expect(_drawn(tester, 3), paints..rect(color: selection));
      expect(_drawn(tester, 4), paints..rect(color: selection));
      expect(_drawn(tester, 5), isNot(paints..rect(color: selection)));

      field.widget.focusNode.unfocus();
      await tester.pump();
      expect(field.layout.marks.selectionColor, isNull);
      expect(_drawn(tester, 3), isNot(paints..rect(color: selection)));
    },
    variant: _macOS,
  );

  testWidgets('on iOS the caret fades out and back in as UIKit fades it', (
    tester,
  ) async {
    final field = await _pumpField(tester, _note(10));
    await _select(tester, field, const TextSelection.collapsed(offset: 3));
    double? opacity() => field.layout.marks.caretColor?.a;
    expect(opacity(), 1);
    await tester.pump(const Duration(milliseconds: 400));
    expect(opacity(), 1);
    await tester.pump(const Duration(milliseconds: 180));
    expect(opacity(), 0.5);
    await tester.pump(const Duration(milliseconds: 120));
    expect(opacity(), isNull);
    await tester.pump(const Duration(milliseconds: 300));
    expect(opacity(), 1);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets(
    'a click puts the caret down, Shift extends the selection, two clicks select a word and three a line, and a drag selects what it passes over',
    (tester) async {
      final text = _note(30);
      final field = await _pumpFieldAtStart(tester, text);
      final controller = field.widget.controller;
      int end(int line) => _lineStart(text, line + 1) - 1;

      await _click(tester, _rowOf(tester, field, 5, dx: 0));
      expect(
        controller.selection,
        TextSelection.collapsed(offset: _lineStart(text, 5)),
      );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await _click(tester, _rowOf(tester, field, 7, dx: 600));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(
        controller.selection,
        TextSelection(baseOffset: _lineStart(text, 5), extentOffset: end(7)),
      );

      final word = _lineStart(text, 9);
      await _click(tester, _rowOf(tester, field, 9), times: 2);
      expect(
        controller.selection,
        TextSelection(baseOffset: word, extentOffset: word + 'Line'.length),
      );
      await _click(tester, _rowOf(tester, field, 9), times: 3);
      expect(
        controller.selection,
        TextSelection(baseOffset: word, extentOffset: _lineStart(text, 10)),
      );

      final mouse = await tester.startGesture(
        _rowOf(tester, field, 2, dx: 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await mouse.moveTo(_rowOf(tester, field, 3, dx: 300));
      await tester.pump();
      await mouse.moveTo(_rowOf(tester, field, 4, dx: 600));
      await tester.pump();
      await mouse.up();
      await mouse.removePointer();
      await tester.pump(kDoubleTapTimeout * 2);
      expect(
        controller.selection,
        TextSelection(baseOffset: _lineStart(text, 2), extentOffset: end(4)),
      );
      expect(find.text('Copy'), findsNothing, reason: 'a mouse shows no menu');
    },
    variant: _macOS,
  );

  testWidgets(
    'a secondary click selects the word under it and opens the menu, whose items edit the note',
    (tester) async {
      final clipboard = _clipboard(tester, 'Hello');
      final text = _note(30);
      final field = await _pumpFieldAtStart(tester, text);
      final controller = field.widget.controller;
      final start = _lineStart(text, 6);
      final word = TextSelection(
        baseOffset: start,
        extentOffset: start + 'Line'.length,
      );

      await _click(
        tester,
        _rowOf(tester, field, 6),
        buttons: kSecondaryMouseButton,
      );
      expect(controller.selection, word);
      expect(find.text('Cut'), findsOneWidget);
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Paste'), findsOneWidget);
      expect(find.text('Select All'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('Copy'), findsNothing);
      expect(controller.selection, word);

      await _click(
        tester,
        _rowOf(tester, field, 6),
        buttons: kSecondaryMouseButton,
      );
      expect(controller.selection, word);
      await tester.tap(find.text('Paste'));
      await tester.pumpAndSettle();
      final pasted = text.replaceRange(start, word.end, 'Hello');
      expect(controller.text, pasted);
      expect(find.text('Paste'), findsNothing);

      final next = _lineStart(pasted, 8);
      await _click(
        tester,
        _rowOf(tester, field, 8),
        buttons: kSecondaryMouseButton,
      );
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      expect(clipboard(), 'Line');
      expect(controller.text, pasted);
      expect(
        controller.selection,
        TextSelection(baseOffset: next, extentOffset: next + 'Line'.length),
      );

      await _click(
        tester,
        _rowOf(tester, field, 8),
        buttons: kSecondaryMouseButton,
      );
      await tester.tap(find.text('Cut'));
      await tester.pumpAndSettle();
      expect(controller.text, pasted.replaceRange(next, next + 4, ''));
      expect(controller.selection, TextSelection.collapsed(offset: next));
      expect(find.text('Cut'), findsNothing);
    },
    variant: _macOS,
  );

  testWidgets(
    'a long press selects a word with handles and the toolbar, and dragging a handle moves its end',
    (tester) async {
      _clipboard(tester, 'Hello');
      final text = _note(30);
      final field = await _pumpFieldAtStart(tester, text);
      final controller = field.widget.controller;
      final start = _lineStart(text, 5);

      await tester.longPressAt(_rowOf(tester, field, 5));
      await tester.pumpAndSettle();
      expect(
        controller.selection,
        TextSelection(baseOffset: start, extentOffset: start + 'Line'.length),
      );
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Paste'), findsOneWidget);
      expect(find.text('Select all'), findsOneWidget);
      final end = _handle(field, start: false);
      expect(_opacity(tester, _handle(field, start: true)), 1);
      expect(_opacity(tester, end), 1);

      // Drags the end handle by what it draws, two rows and a bit down.
      final row = field.layout.paragraphOf(5).preferredLineHeight;
      final finger = await tester.startGesture(
        tester.getCenter(
          find.descendant(of: end, matching: find.byType(CustomPaint)).first,
        ),
      );
      await finger.moveBy(const Offset(0, 40));
      await tester.pump();
      await finger.moveBy(Offset(0, row * 2.2));
      await tester.pump();
      await finger.up();
      await tester.pumpAndSettle();
      expect(controller.selection.baseOffset, start);
      expect(
        controller.selection.extentOffset,
        inInclusiveRange(_lineStart(text, 7), _lineStart(text, 8) - 1),
      );

      await tester.tapAt(_rowOf(tester, field, 12, dx: 0));
      await tester.pumpAndSettle();
      expect(
        controller.selection,
        TextSelection.collapsed(offset: _lineStart(text, 12)),
      );
      expect(find.text('Copy'), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
