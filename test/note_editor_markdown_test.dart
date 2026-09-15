import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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
import 'package:kapy_notes/ui/editor/results_gutter.dart';
import 'package:material_ui/material_ui.dart';

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
  bool markdown = true,
  bool autofocus = false,
  List<NoteFormatRange> initialFormats = const [],
  ValueChanged<String>? onBodyChanged,
  ValueChanged<List<NoteFormatRange>>? onFormatsChanged,
  ValueChanged<bool>? onMarkdownEnabledChanged,
}) {
  return MaterialApp(
    theme: KapyTheme.dark(),
    home: Scaffold(
      body: NoteEditor(
        key: ValueKey(body),
        noteId: 'markdown',
        initialBody: body,
        initialFormats: initialFormats,
        engine: engine,
        highlighter: Highlighter(engine.registry),
        gutterWidth: 200,
        resultsVisible: true,
        markdownEnabled: markdown,
        onMarkdownEnabledChanged: onMarkdownEnabledChanged,
        autofocus: autofocus,
        onDocumentChanged: (body, formats, attachments) {
          onBodyChanged?.call(body);
          onFormatsChanged?.call(formats);
        },
        onGutterWidthChanged: (_) {},
        onResultsVisibilityChanged: (_) {},
        onGutterWidthReset: () {},
        onSettingsPressed: () {},
        writingFont: WritingFont.handwritten,
        shortcuts: shortcutPrefs,
      ),
    ),
  );
}

TextEditingController controllerOf(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!;

/// The middle of the first box [needle] is drawn in, on screen.
Offset centerOf(WidgetTester tester, String needle) {
  final start = controllerOf(tester).text.indexOf(needle);
  return centerOfRange(tester, start, start + needle.length);
}

Offset centerOfRange(WidgetTester tester, int start, int end) {
  final editable = tester
      .state<EditableTextState>(find.byType(EditableText))
      .renderEditable;
  final box = editable
      .getBoxesForSelection(TextSelection(baseOffset: start, extentOffset: end))
      .first;
  return editable.localToGlobal(
    Offset((box.left + box.right) / 2, (box.top + box.bottom) / 2),
  );
}

/// The style the field draws the first character of [needle] in.
TextStyle styleOf(WidgetTester tester, String needle) {
  final editable = tester
      .state<EditableTextState>(find.byType(EditableText))
      .renderEditable;
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

  visit(editable.text!, inherited);
  return found!;
}

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
  final toggle = find.byKey(const ValueKey('formatting-toggle'));
  await tester.tap(toggle);
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
      expect(title.fontWeight, FontWeight.w700);
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
      const body = '- [ ] task\n- bullet\n  - nested\n    - deeper\n1. number';
      await tester.pumpWidget(harness(body));
      await tester.pumpAndSettle();
      final editable = tester
          .state<EditableTextState>(find.byType(EditableText))
          .renderEditable;
      double x(String word) => editable
          .getLocalRectForCaret(TextPosition(offset: body.indexOf(word)))
          .left;
      final margin = editable
          .getLocalRectForCaret(const TextPosition(offset: 0))
          .left;

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

      expect(styleOf(tester, 'bold').fontWeight, FontWeight.w700);
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
      await tester.pumpWidget(harness('# Title\n**bold**', markdown: false));
      await tester.pumpAndSettle();

      expect(styleOf(tester, 'bold').fontWeight, FontWeight.w400);
      expect(styleOf(tester, 'Title').fontWeight, FontWeight.w400);
    });

    testWidgets('switching markdown on redraws the open note', (tester) async {
      await tester.pumpWidget(harness('**bold**', markdown: false));
      await tester.pumpAndSettle();
      expect(styleOf(tester, 'bold').fontWeight, FontWeight.w400);

      await tester.pumpWidget(harness('**bold**'));
      await tester.pumpAndSettle();
      expect(styleOf(tester, 'bold').fontWeight, FontWeight.w700);
    });
  });

  group('typing', () {
    testWidgets('"- " stays markdown instead of becoming a bullet glyph', (
      tester,
    ) async {
      await tester.pumpWidget(harness(''));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '-');
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '- ');
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

      await tester.enterText(find.byType(TextField), '1. first\n');
      await tester.pumpAndSettle();
      expect(controllerOf(tester).text, '1. first\n2. ');

      await tester.enterText(find.byType(TextField), '1. first\n2. \n');
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

      await tester.enterText(
        find.byType(TextField),
        '```\n- not a list\n\n```',
      );
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

      await tester.enterText(find.byType(TextField), '• one\n');
      await tester.pumpAndSettle();
      expect(controllerOf(tester).text, '• one\n• ');
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

    testWidgets('the footer writes headings and lists as markdown', (
      tester,
    ) async {
      await tester.pumpWidget(harness('Groceries', autofocus: true));
      await tester.pumpAndSettle();
      controllerOf(tester).selection = const TextSelection.collapsed(offset: 9);
      await tester.pumpAndSettle();
      await revealFormatting(tester);

      await tester.tap(find.byKey(const ValueKey('format-style')));
      await tester.pumpAndSettle();
      expect(controllerOf(tester).text, '# Groceries');
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('format-style')),
          matching: find.text('H1'),
        ),
        findsOneWidget,
      );

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

      await tester.enterText(find.byType(TextField), '/');
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('slash-command-menu')), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(const ValueKey('slash-command-menu')), findsNothing);
      expect(controllerOf(tester).text, '/');

      await tester.enterText(find.byType(TextField), '/table');
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('slash-command-menu')),
        findsNothing,
        reason: 'Escape leaves this slash literal until it is removed',
      );

      await tester.enterText(find.byType(TextField), '10 / 2');
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('slash-command-menu')), findsNothing);

      await tester.enterText(find.byType(TextField), 'https://example.com');
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('slash-command-menu')), findsNothing);
    });

    testWidgets('filters commands and inserts the keyboard-picked table size', (
      tester,
    ) async {
      await tester.pumpWidget(harness('', autofocus: true));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '/table');
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

        await tester.enterText(find.byType(TextField), '/$query');
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

    testWidgets('asks before enabling Markdown for a table', (tester) async {
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

      await tester.enterText(find.byType(TextField), '/table');
      await tester.pump();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(find.text('Turn on Markdown?'), findsOneWidget);
      expect(controllerOf(tester).text, '/table');
      await tester.tap(find.byKey(const ValueKey('enable-markdown-command')));
      await tester.pumpAndSettle();

      expect(enabled, isTrue);
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
      await tester.enterText(find.byType(TextField), '/todo');
      await tester.pump();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(find.text('Turn on Markdown?'), findsNothing);
      expect(enabled, isNull);
      expect(controllerOf(tester).text, '☐ ');
    });

    testWidgets('leaves headings to the text-style control', (tester) async {
      await tester.pumpWidget(harness('', autofocus: true));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '/heading');
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const ValueKey('slash-command-heading')), findsNothing);
      expect(find.byKey(const ValueKey('slash-command-empty')), findsOneWidget);
      expect(controllerOf(tester).text, '/heading');
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

      await tester.enterText(find.byType(TextField), '/table');
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

    testWidgets('the mobile footer opens the same insert menu', (tester) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      await tester.pumpWidget(harness('', autofocus: true));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('insert-menu')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('insert-menu')));
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const ValueKey('slash-command-menu')), findsOneWidget);
      expect(find.byKey(const ValueKey('slash-command-table')), findsOneWidget);
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

      await tester.enterText(find.byType(TextField), '/table');
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

    testWidgets('a table is a grid until the caret is in it', (tester) async {
      const body = '| a | b |\n|---|---|\n| Tea | 4 |\n\nafter';
      await tester.pumpWidget(harness(body, autofocus: true));
      await tester.pumpAndSettle();
      controllerOf(tester).selection = TextSelection.collapsed(
        offset: body.length,
      );
      await tester.pump();
      expect(styleOf(tester, 'Tea').color!.a, 0);

      controllerOf(tester).selection = TextSelection.collapsed(
        offset: body.indexOf('Tea') + 1,
      );
      await tester.pump();
      expect(styleOf(tester, 'Tea').color!.a, greaterThan(0));
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
      expect(styleOf(tester, 'hi').fontWeight, FontWeight.w700);

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
}
