import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, PointerScrollEvent, kSecondaryButton;
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/calc/highlight.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note_format.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/ui/celebrate.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/editor/note_field.dart';
import 'package:kapy_notes/ui/editor/note_sliver.dart';
import 'package:kapy_notes/ui/editor/results_gutter.dart';
import 'package:kapy_notes/ui/kapy_cursor_peek.dart';
import 'package:material_ui/material_ui.dart';

import 'support/note_driver.dart';
import 'test_fonts.dart';

late CalcEngine engine;
late ShortcutPrefs shortcutPrefs;

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'note-editor-markdown-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

Widget harness(
  String body, {
  Key? editorKey,
  bool markdown = true,
  bool autofocus = false,
  bool readOnly = false,
  bool light = false,
  double? width,
  double editorTextScale = 1,
  WritingFont writingFont = WritingFont.handwritten,
  List<NoteFormatRange> initialFormats = const [],
  ValueChanged<String>? onBodyChanged,
  ValueChanged<List<NoteFormatRange>>? onFormatsChanged,
  ValueChanged<bool>? onMarkdownEnabledChanged,
}) {
  Widget bound(Widget editor) => width == null
      ? editor
      // Width in the tree, not on the view: changing tester.view.physicalSize
      // between pumps does not reach the editor, and this does.
      : Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: width, height: double.infinity, child: editor),
        );

  return MaterialApp(
    theme: light ? KapyTheme.light() : KapyTheme.dark(),
    home: Scaffold(
      body: bound(
        NoteEditor(
          key: editorKey ?? ValueKey(body),
          noteId: 'markdown',
          initialBody: body,
          initialFormats: initialFormats,
          editorTextScale: editorTextScale,
          engine: engine,
          highlighter: Highlighter(engine.registry),
          resultsVisible: true,
          markdownEnabled: markdown,
          readOnly: readOnly,
          onMarkdownEnabledChanged: onMarkdownEnabledChanged,
          autofocus: autofocus,
          onDocumentChanged: (body, formats, attachments, _) {
            onBodyChanged?.call(body);
            onFormatsChanged?.call(formats);
          },
          onSettingsPressed: () {},
          writingFont: writingFont,
          shortcuts: shortcutPrefs,
          // A fixed clock, so the meta row's "Edited" is the same every run.
          now: () => DateTime(2026, 9, 1, 15, 38),
        ),
      ),
    ),
  );
}

/// Decodes the Kapy in the page's corner before a golden: it loads off the
/// fake clock, so without this it shows only once an earlier test has cached
/// it, and the same golden differs alone and in the whole file.
Future<void> settleWithPageKapy(WidgetTester tester) async {
  await tester.runAsync(
    () => precacheImage(
      const AssetImage(KapyCursorPeek.assetPath),
      tester.element(find.byType(NoteEditor)),
    ),
  );
  await tester.pumpAndSettle();
}

TextEditingController controllerOf(WidgetTester tester) =>
    tester.widget<NoteField>(noteField).controller;

/// The middle of the first box [needle] is drawn in, on screen.
Offset centerOf(WidgetTester tester, String needle) {
  final start = controllerOf(tester).text.indexOf(needle);
  return centerOfRange(tester, start, start + needle.length);
}

Offset centerOfRange(WidgetTester tester, int start, int end) {
  final editable = NoteDriver(tester);
  final box = editable
      .boxesFor(TextSelection(baseOffset: start, extentOffset: end))
      .first;
  return editable.toGlobal(
    Offset((box.left + box.right) / 2, (box.top + box.bottom) / 2),
  );
}

/// The style the field draws the first character of [needle] in.
TextStyle styleOf(WidgetTester tester, String needle) {
  final editable = NoteDriver(tester);
  final target = controllerOf(tester).text.indexOf(needle);
  TextStyle? found;
  var offset = 0;
  TextStyle inherited = const TextStyle();
  void visit(InlineSpan span, TextStyle parent) {
    if (found != null) return;
    final style = span.style == null ? parent : parent.merge(span.style);
    if (span is TextSpan) {
      final text = span.text ?? '';
      if (target >= offset && target < offset + text.length) {
        found = style;
        return;
      }
      offset += text.length;
      for (final child in span.children ?? const <InlineSpan>[]) {
        visit(child, style);
      }
    } else {
      offset += 1;
    }
  }

  visit(editable.span, inherited);
  return found!;
}

/// The weight the note's writing is set in.
FontWeight? _writingWeight(WidgetTester tester) =>
    tester.widget<NoteField>(noteField).style.fontWeight;

/// Whether the field draws the first character of [needle] at all.
bool isHidden(WidgetTester tester, String needle) {
  final style = styleOf(tester, needle);
  return style.fontSize! < 1 && style.color!.a == 0;
}

/// Types [text] at the caret the way a keyboard does: through the field's
/// input formatters, as one edit.
Future<void> typeAtCaret(WidgetTester tester, String text) async {
  final value = controllerOf(tester).value;
  final caret = value.selection.start;
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: value.text.replaceRange(caret, caret, text),
      selection: TextSelection.collapsed(offset: caret + text.length),
    ),
  );
  await tester.pump();
}

/// Backspace the way a software keyboard sends it: the text without the
/// character before the caret, as one edit.
Future<void> softBackspace(WidgetTester tester) async {
  final value = controllerOf(tester).value;
  final caret = value.selection.start;
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: value.text.replaceRange(caret - 1, caret, ''),
      selection: TextSelection.collapsed(offset: caret - 1),
    ),
  );
  await tester.pump();
}

/// Types [keys] one character at a time, each its own edit.
Future<void> typeKeys(WidgetTester tester, String keys) async {
  for (final key in keys.split('')) {
    await typeAtCaret(tester, key);
  }
}

Future<void> sendShortcut(WidgetTester tester, ShortcutBinding binding) async {
  final modifiers = [
    if (binding.meta) LogicalKeyboardKey.metaLeft,
    if (binding.control) LogicalKeyboardKey.controlLeft,
    if (binding.alt) LogicalKeyboardKey.altLeft,
    if (binding.shift) LogicalKeyboardKey.shiftLeft,
  ];
  for (final key in modifiers) {
    await tester.sendKeyDownEvent(key);
  }
  await tester.sendKeyEvent(binding.logicalKey);
  for (final key in modifiers.reversed) {
    await tester.sendKeyUpEvent(key);
  }
}

Future<void> revealFormatting(WidgetTester tester) async {
  tester.view.viewInsets = const FakeViewPadding(bottom: 300);
  addTearDown(tester.view.resetViewInsets);
  tester.widget<NoteField>(find.byType(NoteField)).focusNode.requestFocus();
  await tester.pumpAndSettle();
}

Finder chipWithText(String text) => find.widgetWithText(ResultChip, text);

void main() {
  setUpAll(loadTestFonts);
  setUp(() {
    engine = CalcEngine();
    shortcutPrefs = ShortcutPrefs(_MemoryStore())..load();
  });

  group('drawing', () {
    testWidgets('a heading is large and bold, its marker hidden', (
      tester,
    ) async {
      await tester.pumpWidget(harness('# Title\nbody'));
      await tester.pumpAndSettle();

      final title = styleOf(tester, 'Title');
      final body = styleOf(tester, 'body');
      expect(title.fontWeight, FontWeight.w600);
      expect(title.fontSize, greaterThan(body.fontSize!));
      expect(isHidden(tester, '#'), isTrue);
      expect(isHidden(tester, 'Title'), isFalse);
    });

    testWidgets('a bullet and a box keep their room, drawn over', (
      tester,
    ) async {
      await tester.pumpWidget(harness('- item\n- [ ] task'));
      await tester.pumpAndSettle();

      for (final needle in ['-', '[ ]']) {
        final style = styleOf(tester, needle);
        expect(style.color!.a, 0, reason: needle);
        expect(style.fontSize, greaterThan(1), reason: needle);
      }
      expect(styleOf(tester, 'item').color!.a, greaterThan(0));
    });

    testWidgets('every item\'s words start in one column, nesting a room in', (
      tester,
    ) async {
      // Under a title, so the lines are the writing rather than the title.
      const body =
          'List\n- [ ] task\n- bullet\n  - nested\n    - deeper\n1. number';
      await tester.pumpWidget(harness(body));
      await tester.pumpAndSettle();
      final editable = NoteDriver(tester);
      double x(String word) =>
          editable.caretRect(TextPosition(offset: body.indexOf(word))).left;
      final margin = editable.caretRect(const TextPosition(offset: 0)).left;

      final column = x('task');
      expect(x('bullet'), moreOrLessEquals(column, epsilon: 0.5));
      expect(x('number'), moreOrLessEquals(column, epsilon: 0.5));
      final room = column - margin;
      expect(room, greaterThan(15));
      expect(x('nested') - column, moreOrLessEquals(room, epsilon: 0.5));
      expect(x('deeper') - x('nested'), moreOrLessEquals(room, epsilon: 0.5));
    });

    testWidgets('emphasis, code and a ticked task', (tester) async {
      await tester.pumpWidget(
        harness('**bold** *it* `code`\n- [x] done\n- [ ] open'),
      );
      await tester.pumpAndSettle();

      expect(styleOf(tester, 'bold').fontWeight, FontWeight.w600);
      expect(styleOf(tester, 'it').fontStyle, FontStyle.italic);
      expect(
        styleOf(tester, 'code').fontFamily,
        WritingFont.monospace.fontFamily,
      );
      expect(styleOf(tester, 'done').decoration, TextDecoration.lineThrough);
      expect(
        styleOf(tester, 'open').decoration,
        isNot(TextDecoration.lineThrough),
      );
    });

    testWidgets('off, the same text is drawn as it always was', (tester) async {
      await tester.pumpWidget(
        harness('Note\n# Title\n**bold**', markdown: false),
      );
      await tester.pumpAndSettle();

      expect(styleOf(tester, 'bold').fontWeight, _writingWeight(tester));
      expect(styleOf(tester, 'Title').fontWeight, _writingWeight(tester));
    });

    testWidgets('off, a table is still drawn as a grid', (tester) async {
      await tester.pumpWidget(
        harness(
          'Note\n# Title\n\n| a | b |\n| --- | --- |\n| Tea | 4 |',
          markdown: false,
        ),
      );
      await tester.pumpAndSettle();

      // The setting is per device, so a table written on one has to be readable
      // on another. This is the whole of why a phone showed walls of pipes.
      expect(isHidden(tester, 'Tea'), isTrue);

      // And nothing else markdown does comes along with it.
      expect(styleOf(tester, 'Title').fontWeight, _writingWeight(tester));
      expect(isHidden(tester, '#'), isFalse);
    });

    testWidgets('switching markdown on redraws the open note', (tester) async {
      await tester.pumpWidget(harness('Note\n**bold**', markdown: false));
      await tester.pumpAndSettle();
      expect(styleOf(tester, 'bold').fontWeight, _writingWeight(tester));

      await tester.pumpWidget(harness('Note\n**bold**'));
      await tester.pumpAndSettle();
      expect(styleOf(tester, 'bold').fontWeight, FontWeight.w600);
    });
  });

  group('typing', () {
    testWidgets('"- " stays markdown instead of becoming a bullet glyph', (
      tester,
    ) async {
      await tester.pumpWidget(harness(''));
      await tester.pumpAndSettle();

      await tester.enterNote('-');
      await tester.pumpAndSettle();
      await tester.enterNote('- ');
      await tester.pumpAndSettle();
      expect(controllerOf(tester).text, '- ');
    });

    testWidgets('Enter continues a markdown list and leaves it when empty', (
      tester,
    ) async {
      await tester.pumpWidget(harness('1. first'));
      await tester.pumpAndSettle();
      controllerOf(tester).selection = const TextSelection.collapsed(offset: 8);
      await tester.pump();

      await tester.enterNote('1. first\n');
      await tester.pumpAndSettle();
      expect(controllerOf(tester).text, '1. first\n2. ');

      await tester.enterNote('1. first\n2. \n');
      await tester.pumpAndSettle();
      expect(controllerOf(tester).text, '1. first\n');
    });

    testWidgets('inside a code block, Enter is only a new line', (
      tester,
    ) async {
      const body = '```\n- not a list\n```';
      await tester.pumpWidget(harness(body));
      await tester.pumpAndSettle();
      controllerOf(tester).selection = const TextSelection.collapsed(
        offset: 16,
      );
      await tester.pump();

      await tester.enterNote('```\n- not a list\n\n```');
      await tester.pumpAndSettle();
      expect(controllerOf(tester).text, '```\n- not a list\n\n```');
    });

    testWidgets('the app\'s own bullets still continue in a markdown note', (
      tester,
    ) async {
      await tester.pumpWidget(harness('• one'));
      await tester.pumpAndSettle();
      controllerOf(tester).selection = const TextSelection.collapsed(offset: 5);
      await tester.pump();

      await tester.enterNote('• one\n');
      await tester.pumpAndSettle();
      expect(controllerOf(tester).text, '• one\n• ');
    });

    testWidgets('[x] and a space makes a ticked task, from either keyboard', (
      tester,
    ) async {
      await tester.pumpWidget(harness(''));
      await tester.pumpAndSettle();
      await tester.enterNote('[x]');
      await tester.enterNote('[x] ');
      await tester.pumpAndSettle();
      expect(controllerOf(tester).text, '- [x] ');

      await tester.pumpWidget(
        harness('', editorKey: const ValueKey('keys'), autofocus: true),
      );
      await tester.pumpAndSettle();
      await typeKeys(tester, '[x] done');
      expect(controllerOf(tester).text, '- [x] done');
      expect(
        styleOf(tester, 'done').decoration,
        TextDecoration.lineThrough,
        reason: 'ticked',
      );
    });

    testWidgets('* and + make bullets, and a list keeps its first number', (
      tester,
    ) async {
      await tester.pumpWidget(harness('', autofocus: true));
      await tester.pumpAndSettle();
      // Return twice: the second, on an empty item, leaves the list.
      await typeKeys(tester, '* star\n\n+ plus\n\n3. three\nfour');
      expect(
        controllerOf(tester).text,
        '* star\n+ plus\n3. three\n4. four',
        reason: 'Return continues the list it is in, numbers and all',
      );
      expect(styleOf(tester, '+ plus').color!.a, 0, reason: 'a bullet');
      expect(isHidden(tester, '* star'), isFalse, reason: 'drawn over');
      expect(styleOf(tester, '* star').color!.a, 0, reason: 'a bullet');
    });

    testWidgets('a fence and Return opens a block and closes it', (
      tester,
    ) async {
      await tester.pumpWidget(harness('Intro\n\nOutro', autofocus: true));
      await tester.pumpAndSettle();
      controllerOf(tester).selection = const TextSelection.collapsed(offset: 6);
      await tester.pump();

      await typeKeys(tester, '```dart\n- item\n');
      expect(
        controllerOf(tester).text,
        'Intro\n```dart\n- item\n\n```\nOutro',
        reason: 'closed, and no list continued inside it',
      );
      expect(controllerOf(tester).selection.baseOffset, 21);
      expect(
        styleOf(tester, 'Outro').fontFamily,
        styleOf(tester, 'Intro').fontFamily,
      );
    });

    testWidgets('--- under words is a divider, not their underline', (
      tester,
    ) async {
      await tester.pumpWidget(harness('Words', autofocus: true));
      await tester.pumpAndSettle();
      final plain = styleOf(tester, 'Words').fontSize;
      controllerOf(tester).selection = const TextSelection.collapsed(offset: 5);
      await tester.pump();

      await typeKeys(tester, '\n-');
      expect(styleOf(tester, 'Words').fontSize, plain, reason: 'not a heading');
      await typeKeys(tester, '--');
      expect(controllerOf(tester).text, 'Words\n\n---');
      expect(styleOf(tester, 'Words').fontSize, plain);
    });

    testWidgets('markdown is drawn as it is typed', (tester) async {
      await tester.pumpWidget(harness('', autofocus: true));
      await tester.pumpAndSettle();
      await typeKeys(
        tester,
        'a *one* _two_ **three** ~~four~~ `five` [six](https://six.example) '
        'snake_case_name https://seven.example',
      );

      expect(styleOf(tester, 'one').fontStyle, FontStyle.italic);
      expect(styleOf(tester, 'two').fontStyle, FontStyle.italic);
      expect(styleOf(tester, 'three').fontWeight, FontWeight.w600);
      expect(styleOf(tester, 'four').decoration, TextDecoration.lineThrough);
      expect(
        styleOf(tester, 'five').fontFamily,
        isNot(styleOf(tester, 'a ').fontFamily),
      );
      expect(styleOf(tester, 'six').color, isNot(styleOf(tester, 'a ').color));
      for (final marker in [
        '*one',
        '_two',
        '**three',
        '~~four',
        '`five',
        '[six',
      ]) {
        expect(isHidden(tester, marker), isTrue, reason: marker);
      }
      expect(isHidden(tester, '](https://six'), isTrue);
      expect(styleOf(tester, 'case').fontStyle, isNot(FontStyle.italic));
      expect(isHidden(tester, '_case'), isFalse, reason: 'snake_case as typed');
      expect(styleOf(tester, 'seven').color, styleOf(tester, 'six').color);
    });

    testWidgets(
      'Backspace straight after a shortcut gives back what was typed',
      (tester) async {
        await tester.pumpWidget(harness('', autofocus: true));
        await tester.pumpAndSettle();

        // A software keyboard: every key an editing-value update.
        await typeKeys(tester, '# ');
        await softBackspace(tester);
        expect(controllerOf(tester).text, r'\# ');
        await typeKeys(tester, 'not a heading');
        expect(isHidden(tester, r'\#'), isTrue, reason: 'the escape is hidden');
        expect(isHidden(tester, '# not'), isFalse);
        expect(
          styleOf(tester, 'not a heading').fontSize,
          styleOf(tester, '# not').fontSize,
        );

        // A hardware keyboard: Backspace a key event.
        await typeKeys(tester, '\n\n- ');
        await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
        await tester.pump();
        expect(controllerOf(tester).text, '\\# not a heading\n\n\\- ');

        // And only straight after.
        await typeKeys(tester, '\n\n> x');
        await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
        await tester.pump();
        expect(controllerOf(tester).text, '\\# not a heading\n\n\\- \n\n> ');
      },
    );

    testWidgets('Undo straight after a shortcut gives back what was typed', (
      tester,
    ) async {
      await tester.pumpWidget(harness('Words', autofocus: true));
      await tester.pumpAndSettle();
      controllerOf(tester).selection = const TextSelection.collapsed(offset: 5);
      // Open a while, so the history holds the note as it was opened.
      await tester.pump(const Duration(seconds: 1));

      await typeKeys(tester, '\n[ ] ');
      expect(controllerOf(tester).text, 'Words\n- [ ] ');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(controllerOf(tester).text, 'Words\n\\[ ] ');

      // The next Undo is an ordinary one.
      await tester.pump(const Duration(seconds: 1));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(controllerOf(tester).text, 'Words');
    });

    testWidgets('nothing is converted while an input method is composing', (
      tester,
    ) async {
      await tester.pumpWidget(harness('', autofocus: true));
      await tester.pumpAndSettle();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '[x] ',
          selection: TextSelection.collapsed(offset: 4),
          composing: TextRange(start: 0, end: 4),
        ),
      );
      await tester.pump();
      expect(controllerOf(tester).text, '[x] ');

      final config = tester.testTextInput.setClientArgs!;
      expect(config['autocorrect'], isFalse);
      expect(
        config['smartQuotesType'],
        SmartQuotesType.disabled.index.toString(),
      );
      expect(
        config['smartDashesType'],
        SmartDashesType.disabled.index.toString(),
      );
    });

    testWidgets('Tab nests an item under the one above it', (tester) async {
      await tester.pumpWidget(harness('1. one\n2. two', autofocus: true));
      await tester.pumpAndSettle();
      controllerOf(tester).selection = const TextSelection.collapsed(
        offset: 13,
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(controllerOf(tester).text, '1. one\n   2. two');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(controllerOf(tester).text, '1. one\n2. two');
    });
  });

  group('formatting controls', () {
    testWidgets('the bold shortcut writes markers, not a hidden style', (
      tester,
    ) async {
      final bodies = <String>[];
      final formats = <List<NoteFormatRange>>[];
      await tester.pumpWidget(
        harness(
          'a word b',
          autofocus: true,
          onBodyChanged: bodies.add,
          onFormatsChanged: formats.add,
        ),
      );
      await tester.pumpAndSettle();
      controllerOf(tester).selection = const TextSelection(
        baseOffset: 2,
        extentOffset: 6,
      );
      await tester.pump();

      await sendShortcut(
        tester,
        shortcutPrefs.bindingFor(ShortcutAction.formatBold)!,
      );
      await tester.pumpAndSettle();

      expect(bodies.last, 'a **word** b');
      expect(formats.last, isEmpty);
      // Still selected, so the same key takes it off again.
      await sendShortcut(
        tester,
        shortcutPrefs.bindingFor(ShortcutAction.formatBold)!,
      );
      await tester.pumpAndSettle();
      expect(bodies.last, 'a word b');
    });

    testWidgets('the bar writes headings and lists as markdown', (
      tester,
    ) async {
      // The bar is a phone's.
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      await tester.pumpWidget(harness('Groceries', autofocus: true));
      await tester.pumpAndSettle();
      controllerOf(tester).selection = const TextSelection.collapsed(offset: 9);
      await tester.pumpAndSettle();
      await revealFormatting(tester);

      await tester.tap(find.byKey(const ValueKey('format-style')));
      await tester.pumpAndSettle();
      expect(controllerOf(tester).text, '# Groceries');

      await tester.tap(find.byKey(const ValueKey('format-style')));
      await tester.pumpAndSettle();
      expect(controllerOf(tester).text, '## Groceries');

      await tester.tap(find.byKey(const ValueKey('format-checklist')));
      await tester.pumpAndSettle();
      expect(controllerOf(tester).text, '- [ ] ## Groceries');
    });

    testWidgets('a legacy style is carried across markers put around it', (
      tester,
    ) async {
      final formats = <List<NoteFormatRange>>[];
      await tester.pumpWidget(
        harness(
          'one two three',
          autofocus: true,
          initialFormats: const [
            NoteFormatRange(start: 8, end: 13, format: NoteFormat.italic),
          ],
          onFormatsChanged: formats.add,
        ),
      );
      await tester.pumpAndSettle();
      controllerOf(tester).selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 3,
      );
      await tester.pump();

      await sendShortcut(
        tester,
        shortcutPrefs.bindingFor(ShortcutAction.formatBold)!,
      );
      await tester.pumpAndSettle();

      expect(controllerOf(tester).text, '**one** two three');
      // The italic on "three" moved with it instead of being dropped.
      expect(formats.last, const [
        NoteFormatRange(start: 12, end: 17, format: NoteFormat.italic),
      ]);
    });
  });

  group('slash commands', () {
    testWidgets('opens only for a slash-led line, never division or a URL', (
      tester,
    ) async {
      await tester.pumpWidget(harness('', autofocus: true));
      await tester.pumpAndSettle();

      await tester.enterNote('/');
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('slash-command-menu')), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(const ValueKey('slash-command-menu')), findsNothing);
      expect(controllerOf(tester).text, '/');

      await tester.enterNote('/table');
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('slash-command-menu')),
        findsNothing,
        reason: 'Escape leaves this slash literal until it is removed',
      );

      await tester.enterNote('10 / 2');
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('slash-command-menu')), findsNothing);

      await tester.enterNote('https://example.com');
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('slash-command-menu')), findsNothing);
    });

    testWidgets('filters commands and inserts the keyboard-picked table size', (
      tester,
    ) async {
      await tester.pumpWidget(harness('', autofocus: true));
      await tester.pumpAndSettle();

      await tester.enterNote('/table');
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('slash-command-table')), findsOneWidget);
      expect(find.text('Checklist'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(find.byKey(const ValueKey('table-size-grid')), findsOneWidget);
      expect(find.text('2 × 2'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(find.text('3 × 3'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(
        controllerOf(tester).text,
        '| Column 1 | Column 2 | Column 3 |\n'
        '| --- | --- | --- |\n'
        '|  |  |  |\n'
        '|  |  |  |',
      );
      expect(
        controllerOf(tester).selection,
        const TextSelection(baseOffset: 2, extentOffset: 10),
      );
      expect(find.byKey(const ValueKey('slash-command-menu')), findsNothing);
    });

    testWidgets('inserts every structural text command from search', (
      tester,
    ) async {
      const cases = <(String, String)>[
        ('todo', '- [ ] '),
        ('bullet', '- '),
        ('number', '1. '),
        ('quote', '> '),
        ('divider', '---\n'),
        ('code', '```\n\n```'),
      ];

      for (final (query, expected) in cases) {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await tester.pumpWidget(harness('', autofocus: true));
        await tester.pumpAndSettle();

        await tester.enterNote('/$query');
        await tester.pump();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();

        expect(controllerOf(tester).text, expected, reason: query);
        expect(
          find.byKey(const ValueKey('slash-command-menu')),
          findsNothing,
          reason: query,
        );
      }
    });

    testWidgets('asks before enabling Markdown for a divider', (tester) async {
      bool? enabled;
      await tester.pumpWidget(
        harness(
          '',
          markdown: false,
          autofocus: true,
          onMarkdownEnabledChanged: (value) => enabled = value,
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterNote('/divider');
      await tester.pump();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(find.text('Turn on Markdown?'), findsOneWidget);
      expect(controllerOf(tester).text, '/divider');
      await tester.tap(find.byKey(const ValueKey('enable-markdown-command')));
      await tester.pumpAndSettle();

      expect(enabled, isTrue);
      expect(controllerOf(tester).text, '---\n');
    });

    testWidgets('a table asks nothing: it needs no Markdown setting', (
      tester,
    ) async {
      bool? enabled;
      await tester.pumpWidget(
        harness(
          '',
          markdown: false,
          autofocus: true,
          onMarkdownEnabledChanged: (value) => enabled = value,
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterNote('/table');
      await tester.pump();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(find.text('Turn on Markdown?'), findsNothing);
      expect(enabled, isNull, reason: 'nothing had to be switched on');
      expect(
        controllerOf(tester).text,
        '| Column 1 | Column 2 |\n'
        '| --- | --- |\n'
        '|  |  |',
      );
    });

    testWidgets('rich-text list commands stay rich without enabling Markdown', (
      tester,
    ) async {
      bool? enabled;
      await tester.pumpWidget(
        harness(
          '',
          markdown: false,
          autofocus: true,
          onMarkdownEnabledChanged: (value) => enabled = value,
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterNote('/todo');
      await tester.pump();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(find.text('Turn on Markdown?'), findsNothing);
      expect(enabled, isNull);
      expect(controllerOf(tester).text, '☐ ');
    });

    testWidgets('turns the line into a heading of the chosen level', (
      tester,
    ) async {
      await tester.pumpWidget(harness('', autofocus: true));
      await tester.pumpAndSettle();

      await tester.enterNote('/heading');
      await tester.pump();
      await tester.pump();
      for (final level in [1, 2, 3]) {
        expect(
          find.byKey(ValueKey('slash-command-heading$level')),
          findsOneWidget,
        );
      }
      await tester.tap(find.byKey(const ValueKey('slash-command-heading2')));
      await tester.pumpAndSettle();
      expect(controllerOf(tester).text, '## ');
    });

    testWidgets('a formula opens as display math around the caret', (
      tester,
    ) async {
      await tester.pumpWidget(harness('', autofocus: true));
      await tester.pumpAndSettle();

      await tester.enterNote('/math');
      await tester.pump();
      await tester.pump();
      expect(find.text('math'), findsOneWidget, reason: 'the alias it found');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(controllerOf(tester).text, '\$\$\n\n\$\$');
      expect(controllerOf(tester).selection.baseOffset, 3);
    });

    testWidgets('table insertion is one undoable editor change', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.windows;
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() {
        AppPlatform.debugTargetPlatformOverride = null;
        debugDefaultTargetPlatformOverride = null;
      });
      await tester.pumpWidget(harness('', autofocus: true));
      await tester.pumpAndSettle();

      await tester.enterNote('/table');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter, platform: 'windows');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter, platform: 'windows');
      await tester.pump();
      expect(controllerOf(tester).text, startsWith('| Column 1'));

      await tester.sendKeyDownEvent(
        LogicalKeyboardKey.controlLeft,
        platform: 'windows',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ, platform: 'windows');
      await tester.sendKeyUpEvent(
        LogicalKeyboardKey.controlLeft,
        platform: 'windows',
      );
      await tester.pump();
      debugDefaultTargetPlatformOverride = null;

      expect(controllerOf(tester).text, '/table');
    });

    testWidgets('the table picker fits above a compact software keyboard', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(harness('', autofocus: true));
      await tester.pumpAndSettle();

      await tester.enterNote('/table');
      await tester.pump();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      final menu = find.byKey(const ValueKey('slash-command-menu'));
      expect(find.byKey(const ValueKey('table-size-grid')), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(tester.getRect(menu).bottom, lessThanOrEqualTo(268));
    });
  });

  group('tasks', () {
    testWidgets('a tap on the box ticks it, and cheers the last one', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness('- [x] milk\n- [ ] bread', autofocus: true),
      );
      await tester.pumpAndSettle();

      final box = controllerOf(tester).text.indexOf('[ ]');
      await tester.tapAt(centerOf(tester, '[ ]'));
      await tester.pump();

      expect(controllerOf(tester).text, '- [x] milk\n- [x] bread');
      expect(controllerOf(tester).text[box + 1], 'x');
      expect(find.byKey(Celebrate.burstKey), findsOneWidget);
      expect(find.byKey(Celebrate.finaleKey), findsOneWidget);
      await tester.pumpAndSettle();

      // Unticking is a correction, and gets no confetti.
      await tester.tapAt(centerOfRange(tester, box, box + 3));
      await tester.pump();
      expect(controllerOf(tester).text, '- [x] milk\n- [ ] bread');
      expect(find.byKey(Celebrate.burstKey), findsNothing);
      await tester.pumpAndSettle();
    });
  });

  group('the calculator', () {
    testWidgets('multiplies with * between operands, however typed', (
      tester,
    ) async {
      for (final (body, result) in [
        ('2*3*4', '24'),
        ('(2+3)*4', '20'),
        ('3 * 4 * 5', '60'),
        ('price = 4\nprice * 3', '12'),
      ]) {
        await tester.pumpWidget(harness(body));
        await tester.pumpAndSettle();
        expect(chipWithText(result), findsOneWidget, reason: body);
      }
    });

    testWidgets('reads list, quote, code and escaped lines as markdown', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness('- 5\n\n> 6 * 7\n\n    9 * 8\n\n~~5~~ 11\n\\- 13'),
      );
      await tester.pumpAndSettle();

      expect(chipWithText('-5'), findsNothing, reason: 'a bullet, not minus');
      expect(chipWithText('42'), findsNothing, reason: 'a quote');
      expect(chipWithText('72'), findsNothing, reason: 'indented code');
      expect(chipWithText('11'), findsOneWidget, reason: 'struck is not read');
      expect(
        chipWithText('-13'),
        findsOneWidget,
        reason: 'an escaped minus is the minus it shows',
      );
    });

    testWidgets('reads a list item as words, and emphasis as what it holds', (
      tester,
    ) async {
      await tester.pumpWidget(harness('10\n- 5 + 3\n**2 + 2**'));
      await tester.pumpAndSettle();

      expect(chipWithText('-2'), findsNothing);
      expect(chipWithText('4'), findsOneWidget);
    });

    testWidgets('does not read a code block', (tester) async {
      await tester.pumpWidget(harness('```\n9 * 9\n```\n2 * 2'));
      await tester.pumpAndSettle();

      expect(chipWithText('81'), findsNothing);
      expect(chipWithText('4'), findsOneWidget);
    });

    testWidgets('reads as it always did with markdown off', (tester) async {
      await tester.pumpWidget(harness('- 5 + 3', markdown: false));
      await tester.pumpAndSettle();
      expect(chipWithText('-2'), findsOneWidget);

      await tester.pumpWidget(harness('- 5 + 3'));
      await tester.pumpAndSettle();
      expect(chipWithText('-2'), findsNothing);
    });
  });

  group('links', () {
    testWidgets('a markdown link offers its destination', (tester) async {
      await tester.pumpWidget(
        harness('Read [the docs](https://docs.example/start) today'),
      );
      await tester.pumpAndSettle();

      await tester.tapAt(centerOf(tester, 'the docs'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('link-popover')), findsOneWidget);
      expect(find.text('https://docs.example/start'), findsOneWidget);
    });

    testWidgets('one written in a comment keeps the comment colour', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(
          'Read [the docs](https://docs.example/start)\n'
          '// or [the guide](https://docs.example/guide)',
        ),
      );
      await tester.pumpAndSettle();

      // The page's links are Paper's sage, underlined.
      expect(
        styleOf(tester, 'the docs').color,
        KapyTheme.darkPalette.accentText,
      );
      expect(styleOf(tester, 'the docs').decoration, TextDecoration.underline);
      expect(styleOf(tester, 'the guide').color, KapyTheme.darkPalette.comment);
      expect(styleOf(tester, 'the guide').fontStyle, FontStyle.italic);

      await tester.tapAt(centerOf(tester, 'the guide'));
      await tester.pumpAndSettle();

      expect(find.text('https://docs.example/guide'), findsOneWidget);
    });
  });

  group('live preview', () {
    testWidgets('markers show beside a caret moved to them, not typed to', (
      tester,
    ) async {
      const body = 'Say **bold** now';
      await tester.pumpWidget(harness(body, autofocus: true));
      await tester.pumpAndSettle();
      expect(isHidden(tester, '**'), isTrue);

      // Moved there: shown, so the writer can see which side they are on.
      controllerOf(tester).selection = TextSelection.collapsed(
        offset: body.indexOf('** now'),
      );
      await tester.pump();
      expect(isHidden(tester, '**'), isFalse);
      expect(styleOf(tester, '**').color, KapyTheme.darkPalette.textTertiary);

      // Typed there: hidden again, the way a word processor shows bold.
      await typeAtCaret(tester, 'er');
      expect(controllerOf(tester).text, 'Say **bolder** now');
      expect(isHidden(tester, '**'), isTrue);

      // Away from them: hidden.
      controllerOf(tester).selection = const TextSelection.collapsed(offset: 1);
      await tester.pump();
      expect(isHidden(tester, '**'), isTrue);
    });

    testWidgets('nothing is shown as written in a note not being edited', (
      tester,
    ) async {
      await tester.pumpWidget(harness('```\ncode\n```'));
      await tester.pumpAndSettle();
      expect(isHidden(tester, '```'), isTrue);
    });

    testWidgets('a code block\'s fences show with the caret in it', (
      tester,
    ) async {
      const body = '```\ncode\n```\nafter';
      await tester.pumpWidget(harness(body, autofocus: true));
      await tester.pumpAndSettle();
      controllerOf(tester).selection = TextSelection.collapsed(
        offset: body.length,
      );
      await tester.pump();
      expect(isHidden(tester, '```'), isTrue);

      controllerOf(tester).selection = const TextSelection.collapsed(offset: 6);
      await tester.pump();
      expect(isHidden(tester, '```'), isFalse);
    });

    testWidgets('a table stays a grid with the caret in it', (tester) async {
      const body = '| a | b |\n|---|---|\n| Tea | 4 |\n\nafter';
      await tester.pumpWidget(harness(body, autofocus: true));
      await tester.pumpAndSettle();
      controllerOf(tester).selection = TextSelection.collapsed(
        offset: body.length,
      );
      await tester.pump();
      expect(styleOf(tester, 'Tea').color!.a, 0);
      expect(styleOf(tester, 'Tea').fontSize, lessThan(1));

      // This is the bug: the caret landing in a table turned the grid back into
      // `| Tea | 4 |` under the hand that touched it. Now nothing changes.
      controllerOf(tester).selection = TextSelection.collapsed(
        offset: body.indexOf('Tea') + 1,
      );
      await tester.pump();
      expect(styleOf(tester, 'Tea').color!.a, 0);
      expect(styleOf(tester, 'Tea').fontSize, lessThan(1));
    });

    testWidgets('tapping a cell opens a field over it, and typing splices it', (
      tester,
    ) async {
      const body = '| a | b |\n| --- | --- |\n| Tea | 4 |';
      String? latest;
      await tester.pumpWidget(
        harness(body, onBodyChanged: (value) => latest = value),
      );
      await tester.pumpAndSettle();

      // Worked out before the editor opens: once it is, there are two
      // TextFields in the tree and the helpers above cannot tell them apart.
      // The row's spacer is the one box of a hidden row with real height, and it
      // sits at the grid's left edge — so its centre is in the first column.
      final rowStart = body.indexOf('| Tea');
      final firstCell = centerOfRange(tester, rowStart, rowStart + 1);

      await tester.tapAt(firstCell);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('table-cell-editor')), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('table-cell-editor')),
        'Coffee',
      );
      await tester.pumpAndSettle();
      expect(latest, '| a | b |\n| --- | --- |\n| Coffee | 4 |');

      // A press anywhere else finishes editing.
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('table-cell-editor')), findsNothing);
    });

    testWidgets('pasted pipes and line breaks stay inside one cell', (
      tester,
    ) async {
      const body = '| a | b |\n| --- | --- |\n| Tea | 4 |';
      String? latest;
      await tester.pumpWidget(
        harness(body, onBodyChanged: (value) => latest = value),
      );
      await tester.pumpAndSettle();
      final rowStart = body.indexOf('| Tea');
      await tester.tapAt(centerOfRange(tester, rowStart, rowStart + 1));
      await tester.pumpAndSettle();

      final field = find.byKey(const ValueKey('table-cell-editor'));
      await tester.enterText(field, 'a | b\nc');
      await tester.pumpAndSettle();

      expect(tester.widget<TextField>(field).controller!.text, r'a \| b<br>c');
      expect(latest, '| a | b |\n| --- | --- |\n| a \\| b<br>c | 4 |');
    });

    testWidgets('Tab walks the cells, and past the last one adds a row', (
      tester,
    ) async {
      const body = '| a | b |\n| --- | --- |\n| Tea | 4 |';
      String? latest;
      await tester.pumpWidget(
        harness(body, onBodyChanged: (value) => latest = value),
      );
      await tester.pumpAndSettle();
      final rowStart = body.indexOf('| Tea');
      await tester.tapAt(centerOfRange(tester, rowStart, rowStart + 1));
      await tester.pumpAndSettle();

      // Scoped by key, so the note's own field is never mistaken for this one.
      final cell = find.byKey(const ValueKey('table-cell-editor'));
      String editing() => tester.widget<TextField>(cell).controller!.text;
      expect(editing(), 'Tea');

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(editing(), '4');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(editing(), 'Tea', reason: 'Shift+Tab goes back');

      // Tab off the end of the last row makes a new one and moves into it.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(latest, '| a | b |\n| --- | --- |\n| Tea | 4 |\n|  |  |');
      expect(editing(), isEmpty, reason: 'the new row\'s first cell');
    });

    testWidgets('Return moves down the column and appends at the bottom', (
      tester,
    ) async {
      const body = '| a | b |\n| --- | --- |\n| Tea | 4 |';
      String? latest;
      await tester.pumpWidget(
        harness(body, onBodyChanged: (value) => latest = value),
      );
      await tester.pumpAndSettle();
      final rowStart = body.indexOf('| Tea');
      await tester.tapAt(centerOfRange(tester, rowStart, rowStart + 1));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(latest, '$body\n|  |  |');
      final cell = find.byKey(const ValueKey('table-cell-editor'));
      expect(tester.widget<TextField>(cell).controller!.text, isEmpty);
    });

    testWidgets('every keystroke stays in the cell, not only the first', (
      tester,
    ) async {
      // The reported bug: each splice went back into the note with a toolbar
      // cause, and for that cause the note's field asks for the keyboard. It
      // took focus from the cell, so the next key landed among the table's
      // hidden pipes. `enterText` by finder cannot see that — it writes to
      // whichever field it is pointed at — so this types into whatever field
      // holds the keyboard, as a person does.
      const body = '| a | b |\n| --- | --- |\n| Tea | 4 |\n| Cake | 5 |';
      String? latest;
      await tester.pumpWidget(
        harness(body, onBodyChanged: (value) => latest = value),
      );
      await tester.pumpAndSettle();
      final rowStart = body.indexOf('| Tea');
      await tester.tapAt(centerOfRange(tester, rowStart, rowStart + 1));
      await tester.pumpAndSettle();
      // Down a row, so the note's parked caret has somewhere new to go.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      for (final typed in ['Teas', 'Teas a', 'Teas an', 'Teas and']) {
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: typed,
            selection: TextSelection.collapsed(offset: typed.length),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'table cell',
          reason: 'after "$typed"',
        );
      }
      expect(latest, '| a | b |\n| --- | --- |\n| Tea | 4 |\n| Teas and | 5 |');
    });

    testWidgets('arrow keys walk the grid and leave it at its edges', (
      tester,
    ) async {
      const body = 'before\n\n| a | b |\n| --- | --- |\n| Tea | 4 |\n\nafter';
      await tester.pumpWidget(harness(body));
      await tester.pumpAndSettle();
      final rowStart = body.indexOf('| Tea');
      await tester.tapAt(centerOfRange(tester, rowStart, rowStart + 1));
      await tester.pumpAndSettle();

      final cell = find.byKey(const ValueKey('table-cell-editor'));
      TextEditingController field() =>
          tester.widget<TextField>(cell).controller!;

      // The caret is at the end of `Tea`, so Right has nowhere left to go.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(field().text, '4');
      expect(field().selection.baseOffset, 0, reason: 'arrives at the start');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(field().text, 'Tea');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(field().text, 'a', reason: 'up to the header');

      // Up out of the header leaves the table, onto the line above it —
      // never into its hidden source.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(cell, findsNothing);
      expect(controllerOf(tester).selection.baseOffset, 'before\n'.length);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        isNot('table cell'),
      );

      // And Down from the line above walks back in.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(field().text, 'a');
    });

    testWidgets('Escape leaves the caret on the line under the table', (
      tester,
    ) async {
      const body = '| a | b |\n| --- | --- |\n| Tea | 4 |\n\nafter';
      await tester.pumpWidget(harness(body));
      await tester.pumpAndSettle();
      final rowStart = body.indexOf('| Tea');
      await tester.tapAt(centerOfRange(tester, rowStart, rowStart + 1));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('table-cell-editor')), findsNothing);
      expect(
        controllerOf(tester).selection.baseOffset,
        body.indexOf('\n\nafter') + 1,
      );
    });

    testWidgets('undo straight after typing in a cell takes the typing back', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.windows;
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() {
        AppPlatform.debugTargetPlatformOverride = null;
        debugDefaultTargetPlatformOverride = null;
      });
      const body = '| a | b |\n| --- | --- |\n| Tea | 4 |';
      String latest = body;
      await tester.pumpWidget(
        harness(body, onBodyChanged: (value) => latest = value),
      );
      await tester.pumpAndSettle();
      final rowStart = body.indexOf('| Tea');
      await tester.tapAt(centerOfRange(tester, rowStart, rowStart + 1));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 600));

      await tester.enterText(
        find.byKey(const ValueKey('table-cell-editor')),
        'Coffee',
      );
      await tester.pump();
      expect(latest, '| a | b |\n| --- | --- |\n| Coffee | 4 |');

      // Well inside the half second the history waits before it records a
      // change, which is when a controller's undo refuses to do anything.
      await tester.sendKeyDownEvent(
        LogicalKeyboardKey.controlLeft,
        platform: 'windows',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ, platform: 'windows');
      await tester.sendKeyUpEvent(
        LogicalKeyboardKey.controlLeft,
        platform: 'windows',
      );
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;

      expect(latest, body);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('table-cell-editor')))
            .controller!
            .text,
        'Tea',
      );
    });

    testWidgets('words typed under a table start a paragraph of their own', (
      tester,
    ) async {
      const body = '| a | b |\n| --- | --- |\n| Tea | 4 |\n';
      String? latest;
      await tester.pumpWidget(
        harness(
          body,
          autofocus: true,
          onBodyChanged: (value) => latest = value,
        ),
      );
      await tester.pumpAndSettle();
      controllerOf(tester).selection = TextSelection.collapsed(
        offset: body.length,
      );
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: '${body}x',
          selection: TextSelection.collapsed(offset: body.length + 1),
        ),
      );
      await tester.pumpAndSettle();
      // Straight under the last row, `x` would have been a third row.
      expect(latest, '$body\nx');
    });

    testWidgets('words typed after a table that ends the note stay in sight', (
      tester,
    ) async {
      // No line after the last row: stepping out leaves the caret at its end.
      const body = 'Trip\n\n| a | b |\n| --- | --- |\n| Tea | 4 |';
      String? latest;
      await tester.pumpWidget(
        harness(
          body,
          autofocus: true,
          onBodyChanged: (value) => latest = value,
        ),
      );
      await tester.pumpAndSettle();
      controllerOf(tester).selection = TextSelection.collapsed(
        offset: body.length,
      );
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: '${body}x',
          selection: TextSelection.collapsed(offset: body.length + 1),
        ),
      );
      await tester.pumpAndSettle();
      expect(latest, '$body\n\nx');
    });

    testWidgets('the cell toolbar edits rows, columns and alignment', (
      tester,
    ) async {
      const body = '| a | b |\n| --- | --- |\n| Tea | 4 |';
      String? latest;
      await tester.pumpWidget(
        harness(body, onBodyChanged: (value) => latest = value),
      );
      await tester.pumpAndSettle();

      final rowStart = body.indexOf('| Tea');
      await tester.tapAt(centerOfRange(tester, rowStart, rowStart + 1));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('table-cell-toolbar')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('table-align-center')));
      await tester.pumpAndSettle();
      expect(latest, '| a | b |\n| :---: | --- |\n| Tea | 4 |');

      await tester.tap(find.byKey(const ValueKey('table-add-row')));
      await tester.pumpAndSettle();
      expect(latest, '| a | b |\n| :---: | --- |\n| Tea | 4 |\n|  |  |');

      await tester.tap(find.byKey(const ValueKey('table-add-column')));
      await tester.pumpAndSettle();
      expect(
        latest,
        '| a |  | b |\n'
        '| :---: | --- | --- |\n'
        '| Tea |  | 4 |\n'
        '|  |  |  |',
      );

      await tester.tap(find.byKey(const ValueKey('table-remove-column')));
      await tester.pumpAndSettle();
      expect(latest, '| a | b |\n| :---: | --- |\n| Tea | 4 |\n|  |  |');

      await tester.tap(find.byKey(const ValueKey('table-remove-row')));
      await tester.pumpAndSettle();
      expect(latest, '| a | b |\n| :---: | --- |\n| Tea | 4 |');
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('table-cell-editor')))
            .controller!
            .text,
        '4',
        reason: 'removing the last row lands in the previous one',
      );
    });

    testWidgets('a structural table action is one undo step', (tester) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.windows;
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() {
        AppPlatform.debugTargetPlatformOverride = null;
        debugDefaultTargetPlatformOverride = null;
      });
      const body = '| a | b |\n| --- | --- |\n| Tea | 4 |';
      String latest = body;
      await tester.pumpWidget(
        harness(body, onBodyChanged: (value) => latest = value),
      );
      await tester.pumpAndSettle();
      final rowStart = body.indexOf('| Tea');
      await tester.tapAt(centerOfRange(tester, rowStart, rowStart + 1));
      await tester.pumpAndSettle();
      // The table tap gives the main field its first valid caret, which is when
      // Flutter can put the note's initial value into UndoHistory. It throttles
      // that entry for 500 ms, the same cadence used by the insertion test.
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(find.byKey(const ValueKey('table-add-row')));
      await tester.pumpAndSettle();
      expect(latest, '$body\n|  |  |');
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('table-cell-editor')))
            .focusNode!
            .hasFocus,
        isTrue,
        reason: 'table actions keep keyboard ownership in the active cell',
      );

      await tester.sendKeyDownEvent(
        LogicalKeyboardKey.controlLeft,
        platform: 'windows',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ, platform: 'windows');
      await tester.sendKeyUpEvent(
        LogicalKeyboardKey.controlLeft,
        platform: 'windows',
      );
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;

      expect(latest, body);
    });

    testWidgets('a secondary click opens the same cell controls', (
      tester,
    ) async {
      const body = '| a | b |\n| --- | --- |\n| Tea | 4 |';
      await tester.pumpWidget(harness(body));
      await tester.pumpAndSettle();

      final rowStart = body.indexOf('| Tea');
      await tester.tapAt(
        centerOfRange(tester, rowStart, rowStart + 1),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('table-cell-editor')), findsOneWidget);
      expect(find.byKey(const ValueKey('table-cell-toolbar')), findsOneWidget);
    });

    testWidgets('a read-only table stays a grid without an editor', (
      tester,
    ) async {
      const body = '| a | b |\n| --- | --- |\n| Tea | 4 |';
      await tester.pumpWidget(harness(body, readOnly: true));
      await tester.pumpAndSettle();

      final rowStart = body.indexOf('| Tea');
      await tester.tapAt(centerOfRange(tester, rowStart, rowStart + 1));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('table-cell-editor')), findsNothing);
      expect(find.text('| Tea | 4 |'), findsNothing);
    });

    testWidgets('an active cell follows a remote edit before its table', (
      tester,
    ) async {
      const body = 'before\n\n| a | b |\n| --- | --- |\n| Tea | 4 |';
      const remote = 'remote\n$body';
      final editorKey = GlobalKey<NoteEditorState>();
      String? latest;
      await tester.pumpWidget(harness(body, editorKey: editorKey));
      await tester.pumpAndSettle();

      final rowStart = body.indexOf('| Tea');
      await tester.tapAt(centerOfRange(tester, rowStart, rowStart + 1));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('table-cell-editor')))
            .controller!
            .text,
        'Tea',
      );

      await tester.pumpWidget(
        harness(
          remote,
          editorKey: editorKey,
          onBodyChanged: (value) => latest = value,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('table-cell-editor')), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('table-cell-editor')))
            .controller!
            .text,
        'Tea',
      );

      await tester.enterText(
        find.byKey(const ValueKey('table-cell-editor')),
        'Coffee',
      );
      await tester.pumpAndSettle();
      expect(latest, remote.replaceFirst('Tea', 'Coffee'));
    });

    testWidgets('the cell editor follows pointer scrolling', (tester) async {
      final body =
          '| a | b |\n| --- | --- |\n| Tea | 4 |\n\n'
          '${List.generate(50, (i) => 'line $i').join('\n')}';
      await tester.pumpWidget(harness(body));
      await tester.pumpAndSettle();

      final rowStart = body.indexOf('| Tea');
      await tester.tapAt(centerOfRange(tester, rowStart, rowStart + 1));
      await tester.pumpAndSettle();
      final cell = find.byKey(const ValueKey('table-cell-editor'));
      final before = tester.getRect(cell);
      final mainField = find.descendant(
        of: find.byType(NoteEditor),
        matching: noteField,
      );
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position:
              tester.getRect(mainField).bottomCenter - const Offset(0, 20),
          scrollDelta: const Offset(0, 140),
        ),
      );
      await tester.pumpAndSettle();

      expect(cell, findsOneWidget);
      expect(tester.getRect(cell).top, lessThan(before.top));
    });

    testWidgets(
      'a phone keeps the cell and table controls above its keyboard',
      (tester) async {
        AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 568);
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
        addTearDown(tester.view.reset);
        const body = '| a | b |\n| --- | --- |\n| Tea | 4 |';
        String? latest;
        await tester.pumpWidget(
          harness(body, onBodyChanged: (value) => latest = value),
        );
        await tester.pumpAndSettle();

        final rowStart = body.indexOf('| Tea');
        await tester.tapAt(centerOfRange(tester, rowStart, rowStart + 1));
        await tester.pumpAndSettle();

        final cell = find.byKey(const ValueKey('table-cell-editor'));
        expect(cell, findsOneWidget);
        expect(tester.getRect(cell).bottom, lessThanOrEqualTo(268));
        expect(
          find.byKey(const ValueKey('footer-table-add-row')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('footer-table-align-column')),
          findsOneWidget,
        );

        // A press on them is part of editing the cell, not a press elsewhere
        // that finishes it: the first one used to close the cell and do
        // nothing else.
        await tester.tap(find.byKey(const ValueKey('footer-table-add-row')));
        await tester.pumpAndSettle();
        expect(latest, '$body\n|  |  |');
        expect(cell, findsOneWidget);
        expect(FocusManager.instance.primaryFocus?.debugLabel, 'table cell');
      },
    );

    testWidgets('the caret never rests inside a table', (tester) async {
      const body = 'before\n\n| a | b |\n| --- | --- |\n| Tea | 4 |\n\nafter';
      await tester.pumpWidget(harness(body, autofocus: true));
      await tester.pumpAndSettle();
      final tableStart = body.indexOf('| a');
      final tableEnd = body.indexOf('\n\nafter');

      Future<int> caretAfterMovingTo(int park, int into) async {
        controllerOf(tester).selection = TextSelection.collapsed(offset: park);
        await tester.pump();
        controllerOf(tester).selection = TextSelection.collapsed(offset: into);
        await tester.pump();
        return controllerOf(tester).selection.baseOffset;
      }

      // Into a cell from above — a click on the grid — steps out below it.
      expect(await caretAfterMovingTo(0, body.indexOf('Tea')), tableEnd);

      // The `|---|` row is not a place either: nothing of it is drawn.
      expect(await caretAfterMovingTo(0, body.indexOf('---') + 1), tableEnd);

      // Coming from below, it steps out above rather than falling back in.
      expect(
        await caretAfterMovingTo(body.length, body.indexOf('4')),
        tableStart,
      );

      // The edges themselves stay usable, or there would be no way to write a
      // line above a table that starts a note.
      expect(await caretAfterMovingTo(0, tableEnd), tableEnd);
    });

    testWidgets('a table whose cells wrap pushes what follows it down', (
      tester,
    ) async {
      // Both cells are long, so the table's natural width is far wider than a
      // narrow column whether or not the results gutter collapses with it.
      const body =
          '| Notes | More notes |\n'
          '| --- | --- |\n'
          '| a sentence long enough that a narrow column must wrap it '
          '| and another sentence quite as long as the first one is |\n'
          '\n'
          'after';

      Future<double> afterAt(double width) async {
        // A fresh editor: the harness keys itself on the body, so the same note
        // would otherwise keep the state it had at the other width.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await tester.pumpWidget(harness(body, width: width));
        await tester.pumpAndSettle();
        return centerOf(tester, 'after').dy;
      }

      final wide = await afterAt(780);
      final narrow = await afterAt(420);

      expect(
        narrow,
        greaterThan(wide),
        reason:
            'the cells wrap in a narrow column, so the rows grow taller '
            'and the line under the table is pushed down',
      );
    });

    testWidgets('the caret steps over a line\'s hidden structure', (
      tester,
    ) async {
      const body = 'text\n## Title';
      await tester.pumpWidget(harness(body, autofocus: true));
      await tester.pumpAndSettle();

      // Landing in it — a click at the margin, say — puts it at the words.
      controllerOf(tester).selection = const TextSelection.collapsed(offset: 5);
      await tester.pump();
      expect(controllerOf(tester).selection.baseOffset, 8);

      // Left from the words goes on to the line above, not into the `## `.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(controllerOf(tester).selection.baseOffset, 4);

      // And Right from there comes back to the words.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(controllerOf(tester).selection.baseOffset, 8);
    });

    testWidgets('Backspace at the start of a heading takes the heading off', (
      tester,
    ) async {
      await tester.pumpWidget(harness('# Title', autofocus: true));
      await tester.pumpAndSettle();
      controllerOf(tester).selection = const TextSelection.collapsed(offset: 2);
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(controllerOf(tester).text, 'Title');
      expect(controllerOf(tester).selection.baseOffset, 0);
    });

    testWidgets('bold with nothing selected is for the next word typed', (
      tester,
    ) async {
      await tester.pumpWidget(harness('say ', autofocus: true));
      await tester.pumpAndSettle();
      controllerOf(tester).selection = const TextSelection.collapsed(offset: 4);
      await tester.pump();

      await sendShortcut(
        tester,
        shortcutPrefs.bindingFor(ShortcutAction.formatBold)!,
      );
      await tester.pump();
      expect(controllerOf(tester).text, 'say ', reason: 'no `****` left');

      await typeAtCaret(tester, 'h');
      await typeAtCaret(tester, 'i');
      expect(controllerOf(tester).text, 'say **hi**');
      expect(styleOf(tester, 'hi').fontWeight, FontWeight.w600);

      // A space, then the key again: the next word is plain.
      await typeAtCaret(tester, ' ');
      await sendShortcut(
        tester,
        shortcutPrefs.bindingFor(ShortcutAction.formatBold)!,
      );
      await tester.pump();
      await typeAtCaret(tester, 'x');
      expect(controllerOf(tester).text, 'say **hi** x');
    });
  });
  group('formulas, code and HTML', () {
    /// Where the first box [needle] is drawn in sits on screen.
    Rect rectOf(WidgetTester tester, String needle) {
      final start = controllerOf(tester).text.indexOf(needle);
      final editable = NoteDriver(tester);
      final box = editable
          .boxesFor(
            TextSelection(
              baseOffset: start,
              extentOffset: start + needle.length,
            ),
          )
          .first;
      return Rect.fromPoints(
        editable.toGlobal(Offset(box.left, box.top)),
        editable.toGlobal(Offset(box.right, box.bottom)),
      );
    }

    testWidgets('a formula is drawn in place of its TeX, shown with the caret '
        'in it', (tester) async {
      const body = r'Area $\pi r^2$ here';
      await tester.pumpWidget(harness(body, autofocus: true));
      await tester.pumpAndSettle();
      controllerOf(tester).selection = const TextSelection.collapsed(offset: 0);
      await tester.pump();
      expect(find.byType(Math), findsOneWidget);
      expect(isHidden(tester, r'\pi'), isTrue);

      // The caret inside: the TeX as written, as code, where the formula was.
      controllerOf(tester).selection = TextSelection.collapsed(
        offset: body.indexOf('r^2'),
      );
      await tester.pump();
      expect(find.byType(Math), findsNothing);
      expect(isHidden(tester, r'\pi'), isFalse);
      expect(
        styleOf(tester, r'\pi').fontFamily,
        WritingFont.monospace.fontFamily,
      );

      // Typed in, it stays as written.
      await typeAtCaret(tester, '2');
      expect(controllerOf(tester).text, r'Area $\pi 2r^2$ here');
      expect(isHidden(tester, r'\pi'), isFalse);

      // Away from it, drawn again.
      controllerOf(tester).selection = const TextSelection.collapsed(offset: 0);
      await tester.pump();
      expect(find.byType(Math), findsOneWidget);
    });

    testWidgets('arrow keys walk through a formula\'s TeX, and it is drawn '
        'again past it', (tester) async {
      await tester.pumpWidget(harness(r'a $x$ b', autofocus: true));
      await tester.pumpAndSettle();
      controllerOf(tester).selection = const TextSelection.collapsed(offset: 1);
      await tester.pump();
      expect(find.byType(Math), findsOneWidget);

      // Against it and inside it, the caret is never somewhere unseen.
      for (var offset = 2; offset <= 5; offset++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(controllerOf(tester).selection.baseOffset, offset);
        expect(find.byType(Math), findsNothing, reason: 'at $offset');
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(controllerOf(tester).selection.baseOffset, 6);
      expect(find.byType(Math), findsOneWidget);
    });

    testWidgets('the same formula twice is drawn twice', (tester) async {
      // flutter_math_fork keys each line it builds with a GlobalKey, so one
      // widget shown in two places is a key in two places.
      await tester.pumpWidget(harness(r'$x^2$ and again $x^2$'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(Math), findsNWidgets(2));
    });

    testWidgets('TeX it cannot draw stays as written, as code', (tester) async {
      await tester.pumpWidget(harness(r'bad $\frac{a$ here'));
      await tester.pumpAndSettle();
      expect(find.byType(Math), findsNothing);
      expect(isHidden(tester, r'\frac'), isFalse);
      expect(
        styleOf(tester, r'\frac').fontFamily,
        WritingFont.monospace.fontFamily,
      );
    });

    testWidgets('dollar amounts stay words', (tester) async {
      await tester.pumpWidget(harness(r'Lunch $5 and coffee $10'));
      await tester.pumpAndSettle();
      expect(find.byType(Math), findsNothing);
      expect(isHidden(tester, r'$5'), isFalse);
      expect(
        styleOf(tester, r'$5').fontFamily,
        isNot(WritingFont.monospace.fontFamily),
      );
    });

    testWidgets('set apart, a formula takes a line of its own and results '
        'keep to theirs', (tester) async {
      const body = '1 + 1\n\$\$\n\\frac{a}{b}\n\$\$\n2 + 2';
      await tester.pumpWidget(harness(body));
      await tester.pumpAndSettle();
      final formula = tester.getRect(find.byType(Math));
      final above = rectOf(tester, '1 + 1');
      final below = rectOf(tester, '2 + 2');
      expect(formula.top, greaterThanOrEqualTo(above.bottom));
      expect(formula.bottom, lessThanOrEqualTo(below.top));
      expect(formula.left, greaterThan(above.right), reason: 'it is centred');
      expect(
        tester.getCenter(chipWithText('4')).dy,
        closeTo(below.center.dy, 2),
        reason: 'the result is beside the line it belongs to',
      );
    });

    testWidgets('fenced code is coloured by its language, from the palette', (
      tester,
    ) async {
      const body =
          '```python\ndef total(xs):\n    return sum(xs)  # all\n```\n\n'
          '```nosuchlanguage\ndefine "it" # too\n```';
      await tester.pumpWidget(harness(body));
      await tester.pumpAndSettle();
      const palette = KapyTheme.darkPalette;
      expect(styleOf(tester, 'def').color, palette.codeKeyword);
      expect(styleOf(tester, 'return').color, palette.codeKeyword);
      expect(styleOf(tester, 'sum').color, palette.codeBuiltIn);
      expect(styleOf(tester, 'total').color, palette.textPrimary);
      expect(styleOf(tester, 'total').fontWeight, FontWeight.w500);
      expect(styleOf(tester, '# all').color, palette.textTertiary);
      expect(styleOf(tester, '# all').fontStyle, FontStyle.italic);
      // A language it does not know is left as it is written.
      final plain = styleOf(tester, 'define');
      expect(styleOf(tester, '"it"').color, plain.color);
      expect(styleOf(tester, '# too').color, plain.color);
      expect(styleOf(tester, '# too').fontStyle, plain.fontStyle);
    });

    testWidgets('underline, superscript and subscript, their tags hidden', (
      tester,
    ) async {
      const body =
          'Note\n'
          'a <u>under</u> E = mc<sup>2</sup> and H<sub>3</sub>O x<sup>n</sup>';
      await tester.pumpWidget(harness(body));
      await tester.pumpAndSettle();
      expect(isHidden(tester, '<u>'), isTrue);
      expect(isHidden(tester, '</sup>'), isTrue);
      expect(styleOf(tester, 'under').decoration, TextDecoration.underline);
      // The handwritten face has raised and lowered figures of its own.
      expect(
        styleOf(tester, '2<').fontFeatures,
        contains(const FontFeature.enable('sups')),
      );
      expect(
        styleOf(tester, '3<').fontFeatures,
        contains(const FontFeature.enable('sinf')),
      );
      // But not letters, which are drawn smaller instead.
      expect(
        styleOf(tester, 'n<').fontSize,
        lessThan(styleOf(tester, 'x<').fontSize!),
      );
    });

    testWidgets('a <br> in a cell gives its row another line', (tester) async {
      Future<double> afterWith(String cell) async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await tester.pumpWidget(harness('| a |\n| --- |\n| $cell |\n\nafter'));
        await tester.pumpAndSettle();
        return centerOf(tester, 'after').dy;
      }

      final one = await afterWith('one two');
      final two = await afterWith('one<br>two');
      final three = await afterWith('one<br>two<br>three');
      expect(two, greaterThan(one));
      expect(three - two, greaterThan(0));
      expect(three - two, closeTo(two - one, 1), reason: 'a line apiece');
    });

    // The blocks artboards: CYZ-0 in dark, and E7F-0's key pieces in light.
    group('blocks as on Paper', () {
      const dark =
          'SnowSEO Issues\n'
          '# Rank scoring\n'
          'Runs nightly; the [cron notes](https://cron.example) are in Shared. '
          'Keep `MAX_PAGES` under 500.\n'
          '```python\n'
          'def score(page, keywords):\n'
          '    # a title hit counts double\n'
          '    hits = sum(k in page.title for k in keywords) * 2\n'
          '    return hits + len(page.links) / 100\n'
          'label = "needs links" if score(p, kw) < 3 else "ok"\n'
          '```\n'
          '## Formulas\n'
          r'Click-through is $\frac{clicks}{shows}$, about 3.2% this week.'
          '\n'
          '\$\$\n'
          r'E[\mathrm{rank}] = \sum\nolimits_i p_i \cdot r_i'
          '\n'
          '\$\$\n'
          '## This week\n'
          '| Keyword | Rank | Change |\n'
          '| --- | ---: | ---: |\n'
          '| kapy notes | 3 | +2 |\n'
          '| calculator notes app | 11 | −1 |\n'
          '| markdown notes mac | 7 | +4 |\n'
          '\n'
          'Full report: https://app.openseo.so/s/_g7CLGiBVMgNALKe';
      const light =
          'Key pieces\n'
          '# Trip budget\n'
          'Flights are **booked**, hotels are *still open*. See '
          '[the shared sheet](https://sheet.example) and `TOTAL`.\n'
          '## Before we go\n'
          '- [x] Renew passports\n'
          '- [ ] Book Lisbon flights under ₹28,000\n'
          '- Lisbon, 4 nights\n'
          '  - Alfama walk on day 2\n'
          '    - Tram 28 early, before the queue\n'
          '1. Exchange €300\n'
          '2. Offline maps\n'
          '\n'
          '> Pack for rain, it is November.\n'
          '\n'
          '---\n'
          '### Split\n'
          '```python\n'
          'def score(page, keywords):\n'
          '    # a title hit counts double\n'
          '    hits = sum(k in page.title for k in keywords) * 2\n'
          '    return hits + len(page.links) / 100\n'
          'label = "needs links" if score(p, kw) < 3 else "ok"\n'
          '```';

      Future<void> pumpNote(
        WidgetTester tester,
        String note,
        Size size, {
        bool light = false,
      }) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          harness(note, light: light, writingFont: WritingFont.mixed),
        );
        await settleWithPageKapy(tester);
      }

      testWidgets('dark, as CYZ-0', (tester) async {
        await pumpNote(tester, dark, const Size(1013, 817));
        await expectLater(
          find.byType(NoteEditor),
          matchesGoldenFile('goldens/markdown_blocks_dark.png'),
        );
      });

      testWidgets('light, as E7F-0', (tester) async {
        await pumpNote(tester, light, const Size(720, 900), light: true);
        await expectLater(
          find.byType(NoteEditor),
          matchesGoldenFile('goldens/markdown_blocks_light.png'),
        );
      });

      testWidgets("a code block's header names its language and copies its "
          'code, and goes while the caret is in the block', (tester) async {
        final copied = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied.add((call.arguments as Map)['text'] as String);
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        const note = 'Note\n```python\nx = 1\nprint(x)\n```\nafter';
        await pumpNote(tester, note, const Size(900, 600));

        final copy = find.byKey(const ValueKey('code-copy'));
        expect(find.text('python'), findsOneWidget);
        expect(copy, findsOneWidget);
        expect(
          tester.getRect(copy).bottom,
          lessThan(centerOf(tester, 'x = 1').dy),
        );

        await tester.tap(copy);
        await tester.pump();
        expect(copied, ['x = 1\nprint(x)']);
        await tester.pump(const Duration(seconds: 3));

        await tester.tapAt(centerOf(tester, 'x = 1'));
        await tester.pumpAndSettle();
        expect(copy, findsNothing);
      });
    });

    group("a code block's lines are set in from its panel", () {
      const fence = '\x60\x60\x60';
      const note = 'Note\n${fence}python\nx = 1\nprint(x)\n$fence\nafter';
      // Lines of the note: 2 is `x = 1`, 3 is `print(x)`, 5 is `after`.
      const inset = EditorMetrics.codeInset;

      Future<NoteDriver> pump(WidgetTester tester, [String body = note]) async {
        tester.view.physicalSize = const Size(900, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(harness(body, writingFont: WritingFont.mixed));
        await settleWithPageKapy(tester);
        return NoteDriver(tester);
      }

      int at(WidgetTester tester, String needle) =>
          controllerOf(tester).text.indexOf(needle);

      testWidgets('the code starts inset, the text around it does not', (
        tester,
      ) async {
        final field = await pump(tester);
        final code = field.boxesFor(
          TextSelection(
            baseOffset: at(tester, 'x = 1'),
            extentOffset: at(tester, 'x = 1') + 1,
          ),
        );
        final plain = field.boxesFor(
          TextSelection(
            baseOffset: at(tester, 'after'),
            extentOffset: at(tester, 'after') + 1,
          ),
        );
        expect(code.single.left, closeTo(inset, 0.5));
        expect(plain.single.left, closeTo(0, 0.5));
      });

      testWidgets(
        'the caret stands where the code is, not where the column starts',
        (tester) async {
          final field = await pump(tester);
          final start = at(tester, 'print(x)');
          final first = field.caretRect(TextPosition(offset: start));
          final later = field.caretRect(TextPosition(offset: start + 5));
          expect(first.left, closeTo(inset, 1.5));
          final advance = (later.left - first.left) / 5;
          expect(advance, greaterThan(4));
          final after = field.caretRect(
            TextPosition(offset: at(tester, 'after')),
          );
          expect(after.left, closeTo(0, 1.5));
        },
      );

      testWidgets('a tap lands on the character under it, and a tap in the '
          "inset or past the end lands at the line's ends", (tester) async {
        final field = await pump(tester);
        final controller = controllerOf(tester);
        final start = at(tester, 'print(x)');
        final end = start + 'print(x)'.length;
        final left = field.toGlobal(Offset.zero).dx;

        // The caret in the block shows its fences, which moves the lines,
        // so each tap finds its row afresh.
        double rowOf(int offset) =>
            centerOfRange(tester, offset, offset + 1).dy;

        await tester.tapAt(centerOfRange(tester, start + 3, start + 4));
        await tester.pump();
        expect(controller.selection.isCollapsed, isTrue);
        expect(controller.selection.baseOffset, anyOf(start + 3, start + 4));

        await tester.tapAt(Offset(left + 3, rowOf(start)));
        await tester.pump();
        expect(controller.selection.baseOffset, start);

        await tester.tapAt(Offset(left + 500, rowOf(start)));
        await tester.pump();
        expect(controller.selection.baseOffset, end);
      });

      testWidgets(
        'a drag selects across the lines, from the inset to past the end',
        (tester) async {
          final field = await pump(tester);
          final controller = controllerOf(tester);
          final first = at(tester, 'x = 1');
          final second = at(tester, 'print(x)');
          final left = field.toGlobal(Offset.zero).dx;

          final gesture = await tester.startGesture(
            Offset(left + 3, centerOfRange(tester, first, first + 1).dy),
            kind: PointerDeviceKind.mouse,
          );
          await tester.pump();
          await gesture.moveTo(
            Offset(left + 500, centerOfRange(tester, second, second + 1).dy),
          );
          await tester.pump();
          await gesture.up();
          await tester.pump();
          expect(controller.selection.start, first);
          expect(controller.selection.end, second + 'print(x)'.length);
        },
      );

      testWidgets('a selection handle points at the selected code, and the '
          'selection\'s boxes start in the inset', (tester) async {
        final field = await pump(tester);
        final start = at(tester, 'x = 1');
        final paragraph = field.state.layout.paragraphOf(2);
        final range = TextSelection(baseOffset: 0, extentOffset: 5);
        final width = field.columnWidth;
        final first = handlePointIn(
          paragraph,
          range,
          start: true,
          width: width,
        );
        final last = handlePointIn(
          paragraph,
          range,
          start: false,
          width: width,
        );
        expect(first.dx, closeTo(inset, 0.5));
        final box = field
            .boxesFor(TextSelection(baseOffset: start, extentOffset: start + 5))
            .single;
        expect(last.dx, closeTo(box.right, 0.5));
        expect(box.left, closeTo(inset, 0.5));
      });

      testWidgets(
        "at 125% zoom the code and the header's language start at the "
        'same x',
        (tester) async {
          tester.view.physicalSize = const Size(900, 600);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            harness(
              note,
              editorTextScale: 1.25,
              writingFont: WritingFont.mixed,
            ),
          );
          await settleWithPageKapy(tester);
          final field = NoteDriver(tester);
          final start = at(tester, 'x = 1');
          final box = field
              .boxesFor(
                TextSelection(baseOffset: start, extentOffset: start + 1),
              )
              .single;
          final codeX = field.toGlobal(Offset(box.left, 0)).dx;
          final labelX = tester.getTopLeft(find.text('python')).dx;
          expect(labelX, closeTo(codeX, 0.75));
          expect(
            codeX - field.toGlobal(Offset.zero).dx,
            closeTo(inset * 1.25, 0.75),
          );
        },
      );

      testWidgets(
        'a long line wraps inside the panel, every row in the inset',
        (tester) async {
          final long = List.filled(40, 'word').join(' ');
          final field = await pump(
            tester,
            'Note\n${fence}python\n$long\n$fence\nafter',
          );
          final rows = field.state.layout.paragraphOf(2).computeLineMetrics();
          expect(rows.length, greaterThan(1));
          for (final row in rows) {
            expect(row.left, closeTo(inset, 0.5));
            expect(
              row.left + row.width,
              lessThanOrEqualTo(field.columnWidth - inset + 0.5),
            );
          }
        },
      );
    });

    group('as a golden', () {
      const note =
          '# Formulas, code and underline\n'
          '\n'
          r'The area of a circle is $\pi r^2$, and lunch was $5 or $10.'
          '\n'
          '\n'
          '\$\$\n'
          r'x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}'
          '\n'
          '\$\$\n'
          '\n'
          r'TeX that does not parse stays as written: $\frac{a$'
          '\n'
          '\n'
          '<u>Underlined</u>, E = mc<sup>2</sup>, H<sub>2</sub>O and '
          '2<sup>n</sup>\n'
          '\n'
          '```python\n'
          'def area(r):\n'
          '    # a circle\n'
          '    return 3.14159 * r ** 2  # "pi r squared"\n'
          '```\n'
          '\n'
          '| Constant | Value |\n'
          '| --- | --- |\n'
          '| Speed of light | 299 792 458<br>metres a second |\n'
          r'| $c^2$ | <u>squared</u> |'
          '\n'
          '\n'
          '5 + 3';

      Future<void> pumpNote(
        WidgetTester tester, {
        bool light = false,
        bool focused = false,
      }) async {
        tester.view.physicalSize = const Size(900, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          harness(note, light: light, autofocus: focused),
        );
        await settleWithPageKapy(tester);
      }

      testWidgets('dark', (tester) async {
        await pumpNote(tester);
        await expectLater(
          find.byType(NoteEditor),
          matchesGoldenFile('goldens/markdown_rendering_dark.png'),
        );
      });

      testWidgets('light', (tester) async {
        await pumpNote(tester, light: true);
        await expectLater(
          find.byType(NoteEditor),
          matchesGoldenFile('goldens/markdown_rendering_light.png'),
        );
      });

      testWidgets('dark, the caret in a formula set apart', (tester) async {
        await pumpNote(tester, focused: true);
        controllerOf(tester).selection = TextSelection.collapsed(
          offset: note.indexOf(r'\frac{-b'),
        );
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(NoteEditor),
          matchesGoldenFile('goldens/markdown_rendering_revealed_dark.png'),
        );
      });
    });
  });
}
