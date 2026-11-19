import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/calc/highlight.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/editor/note_field.dart';
import 'package:material_ui/material_ui.dart';

import 'support/note_driver.dart';
import 'test_fonts.dart';

late CalcEngine engine;
late ShortcutPrefs shortcutPrefs;

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'keyboard-caret-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

const _phone = Size(390, 844);
const _keyboard = 300.0;
const _keyboardTop = 844.0 - _keyboard;
const _bar = ValueKey('phone-format-bar');
const _cell = ValueKey('table-cell-editor');

/// The editor as a phone mounts it: the body of a Scaffold, which gives it
/// only the room above the keyboard.
Widget _page(String body, {bool markdown = true}) => MaterialApp(
  theme: KapyTheme.dark(),
  home: Scaffold(
    body: NoteEditor(
      key: ValueKey(body),
      noteId: 'keyboard-caret',
      initialBody: body,
      engine: engine,
      highlighter: Highlighter(engine.registry),
      resultsVisible: true,
      markdownEnabled: markdown,
      onDocumentChanged: (_, _, _, _) {},
      onSettingsPressed: () {},
      shortcuts: shortcutPrefs,
      writingFont: WritingFont.handwritten,
    ),
  ),
);

String _lines(int count) =>
    [for (var i = 1; i <= count; i++) 'Line $i'].join('\n');

ScrollController _scroll(WidgetTester tester) =>
    tester.widget<NoteField>(noteField).scrollController;

/// Moves the keyboard to [height] over a few frames, as a phone animates it.
Future<void> _keyboardTo(WidgetTester tester, double height) async {
  final from = tester.view.viewInsets.bottom;
  for (var step = 1; step <= 4; step++) {
    final inset = from + (height - from) * step / 4;
    tester.view.viewInsets = inset == 0
        ? FakeViewPadding.zero
        : FakeViewPadding(bottom: inset);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pumpAndSettle();
}

/// Types [text] at the caret the way a software keyboard does, as one edit.
Future<void> _type(WidgetTester tester, String text) async {
  final value = NoteDriver(tester).value;
  final caret = value.selection.start;
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: value.text.replaceRange(caret, caret, text),
      selection: TextSelection.collapsed(offset: caret + text.length),
    ),
  );
  await tester.pumpAndSettle();
}

/// The caret's row on the screen.
Rect _caret(WidgetTester tester) {
  final driver = NoteDriver(tester);
  return driver
      .caretRect(driver.value.selection.extent)
      .shift(driver.toGlobal(Offset.zero));
}

/// Where the note stops showing: the top of the formatting bar, which sits
/// on the keyboard.
double _shownBottom(WidgetTester tester) {
  final bar = tester.getRect(find.byKey(_bar));
  expect(bar.bottom, closeTo(_keyboardTop, 0.01));
  return bar.top;
}

/// The row being typed on is all in sight, between the top of the note and
/// the formatting bar.
void _expectCaretShown(WidgetTester tester) {
  final caret = _caret(tester);
  expect(caret.bottom, lessThanOrEqualTo(_shownBottom(tester)));
  expect(caret.top, greaterThanOrEqualTo(tester.getRect(noteField).top));
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() {
    engine = CalcEngine();
    shortcutPrefs = ShortcutPrefs(_MemoryStore())..load();
  });

  final phones = TargetPlatformVariant({
    TargetPlatform.android,
    TargetPlatform.iOS,
  });

  Future<void> open(
    WidgetTester tester,
    String body, {
    bool markdown = true,
  }) async {
    AppPlatform.debugTargetPlatformOverride = defaultTargetPlatform;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    tester.view.physicalSize = _phone;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_page(body, markdown: markdown));
    await tester.pumpAndSettle();
  }

  /// Taps [at] with the keyboard down, as the reader does to write there,
  /// which asks for the keyboard.
  Future<void> tapWithKeyboardDown(WidgetTester tester, Offset at) async {
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.tapAt(at);
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);
  }

  Offset nearTheBottom(WidgetTester tester) {
    final field = tester.getRect(noteField);
    return Offset(field.left + 40, field.bottom - 12);
  }

  for (final markdown in [true, false]) {
    final mode = markdown ? 'markdown on' : 'markdown off';

    testWidgets('a tap low in a long note keeps the row being typed above '
        'the keyboard, $mode', (tester) async {
      await open(tester, _lines(80), markdown: markdown);
      await tapWithKeyboardDown(tester, nearTheBottom(tester));
      expect(_caret(tester).top, greaterThan(_keyboardTop));
      await _keyboardTo(tester, _keyboard);
      _expectCaretShown(tester);

      await _type(tester, ' and more');
      _expectCaretShown(tester);
      for (var i = 1; i <= 8; i++) {
        await _type(tester, '\nA new line $i');
        _expectCaretShown(tester);
      }

      final typed = _scroll(tester).offset;
      expect(typed, greaterThan(0));
      await _keyboardTo(tester, 0);
      expect(_scroll(tester).offset, typed);
    }, variant: phones);

    testWidgets('a tap low in a note that fits the screen keeps the row being '
        'typed above the keyboard, $mode', (tester) async {
      await open(tester, 'Probe', markdown: markdown);
      final rows =
          tester.getRect(noteField).height ~/ NoteDriver(tester).rowHeight;
      await open(tester, _lines(rows - 2), markdown: markdown);
      expect(_scroll(tester).position.maxScrollExtent, 0);

      await tapWithKeyboardDown(tester, nearTheBottom(tester));
      expect(_caret(tester).top, greaterThan(_keyboardTop));
      await _keyboardTo(tester, _keyboard);
      _expectCaretShown(tester);
      for (var i = 1; i <= 4; i++) {
        await _type(tester, '\nA new line $i');
        _expectCaretShown(tester);
      }
    }, variant: phones);
  }

  testWidgets('a cell low in a note stays above the keyboard as it is typed '
      'in', (tester) async {
    final body = [
      _lines(14),
      '',
      '| Item | Cost |',
      '| --- | --- |',
      for (var i = 1; i <= 12; i++) '| Thing $i | $i |',
    ].join('\n');
    await open(tester, body);
    final field = tester.getRect(noteField);
    final driver = NoteDriver(tester);
    late Offset lowCell;
    for (var i = 12; i >= 1; i--) {
      final start = body.indexOf('Thing $i ');
      final boxes = driver.boxesFor(
        TextSelection(baseOffset: start, extentOffset: start + 5),
      );
      if (boxes.isEmpty) continue;
      lowCell = driver.toGlobal(boxes.first.toRect().center);
      if (lowCell.dy < field.bottom - 8) break;
    }
    expect(lowCell.dy, greaterThan(_keyboardTop));

    await tapWithKeyboardDown(tester, lowCell);
    await _keyboardTo(tester, _keyboard);
    final cell = find.byKey(_cell);
    expect(cell, findsOneWidget);
    expect(
      tester.getRect(cell).bottom,
      lessThanOrEqualTo(_shownBottom(tester)),
    );

    await tester.enterText(
      cell,
      'A long cell that wraps onto a second row, and then onto a third',
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(cell).height, greaterThan(60));
    expect(
      tester.getRect(cell).bottom,
      lessThanOrEqualTo(_shownBottom(tester)),
    );
  }, variant: phones);

  for (final long in [true, false]) {
    final note = long ? 'a long note' : 'a note that fits the screen';

    testWidgets('a table from the slash menu at the end of $note opens its '
        'first cell above the keyboard', (tester) async {
      var body = _lines(80);
      if (!long) {
        await open(tester, 'Probe');
        final rows =
            tester.getRect(noteField).height ~/ NoteDriver(tester).rowHeight;
        body = _lines(rows - 2);
      }
      await open(tester, body);
      await tapWithKeyboardDown(tester, nearTheBottom(tester));
      await _keyboardTo(tester, _keyboard);
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: body,
          selection: TextSelection.collapsed(offset: body.length),
        ),
      );
      await tester.pumpAndSettle();
      await _type(tester, '\n');
      await _type(tester, '/table');
      expect(find.byKey(const ValueKey('slash-command-menu')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('slash-command-table')));
      await tester.pumpAndSettle();
      await tester.tap(
        find
            .descendant(
              of: find.byKey(const ValueKey('table-size-grid')),
              matching: find.byType(GestureDetector),
            )
            .at(7),
      );
      await tester.pumpAndSettle();

      final cell = find.byKey(_cell);
      expect(cell, findsOneWidget);
      expect(
        tester.getRect(cell).bottom,
        lessThanOrEqualTo(_shownBottom(tester)),
      );
      expect(
        tester.getRect(cell).top,
        greaterThanOrEqualTo(tester.getRect(noteField).top),
      );
      final typing = tester
          .widget<EditableText>(
            find.descendant(of: cell, matching: find.byType(EditableText)),
          )
          .controller
          .value;
      expect(typing.text, 'Column 1');
      expect(
        typing.selection,
        const TextSelection(baseOffset: 0, extentOffset: 8),
      );

      await tester.enterText(cell, 'cell one');
      await tester.pumpAndSettle();
      expect(
        NoteDriver(tester).value.text,
        contains('| cell one | Column 2 |'),
      );
      expect(
        tester.getRect(cell).bottom,
        lessThanOrEqualTo(_shownBottom(tester)),
      );
    }, variant: phones);
  }

  testWidgets('a desktop window made shorter leaves the note where it was', (
    tester,
  ) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_page(_lines(80)));
    await tester.pumpAndSettle();
    await tester.tapAt(nearTheBottom(tester));
    await tester.pumpAndSettle();
    expect(_caret(tester).top, greaterThan(420));
    final tapped = _scroll(tester).offset;

    tester.view.physicalSize = const Size(900, 420);
    await tester.pumpAndSettle();
    expect(_scroll(tester).offset, tapped);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
