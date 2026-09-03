import 'dart:ui' show PointerDeviceKind;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/calc/highlight.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note_format.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/time_zones.dart';
import 'package:kapy_notes/ui/editor/editor_formatting.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/editor/note_footer.dart';
import 'package:kapy_notes/ui/editor/results_gutter.dart';

import 'test_fonts.dart';

const _rates = <String, double>{'EUR': 0.86, 'GBP': 0.74};

late CalcEngine engine;
late ShortcutPrefs shortcutPrefs;

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'note-editor-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

Widget harness(
  String body, {
  List<NoteFormatRange> initialFormats = const [],
  double gutterWidth = 200,
  bool resultsVisible = true,
  DateTime? lastUpdatedAt,
  bool dailySeparatorsEnabled = false,
  DateTime Function()? now,
  DateTime Function(DateTime)? displayTime,
  bool startAtEnd = false,
  bool autofocus = false,
  bool ensureKeyboardVisible = false,
  ValueChanged<String>? onBodyChanged,
  ValueChanged<List<NoteFormatRange>>? onFormatsChanged,
  ValueChanged<double>? onGutterWidthChanged,
  ValueChanged<bool>? onResultsVisibilityChanged,
  VoidCallback? onGutterWidthReset,
  WritingFont writingFont = WritingFont.handwritten,
  ShortcutPrefs? shortcuts,
}) {
  return MaterialApp(
    theme: KapyTheme.dark(),
    home: Scaffold(
      body: NoteEditor(
        // Keyed by body so re-pumping with different text remounts the
        // editor, the way switching notes does in the app.
        key: ValueKey(body),
        noteId: 'test',
        initialBody: body,
        initialFormats: initialFormats,
        engine: engine,
        highlighter: Highlighter(engine.registry),
        gutterWidth: gutterWidth,
        resultsVisible: resultsVisible,
        lastUpdatedAt: lastUpdatedAt,
        dailySeparatorsEnabled: dailySeparatorsEnabled,
        now: now,
        displayTime: displayTime,
        startAtEnd: startAtEnd,
        autofocus: autofocus,
        ensureKeyboardVisible: ensureKeyboardVisible,
        onDocumentChanged: (body, formats) {
          onBodyChanged?.call(body);
          onFormatsChanged?.call(formats);
        },
        onGutterWidthChanged: onGutterWidthChanged ?? (_) {},
        onResultsVisibilityChanged: onResultsVisibilityChanged ?? (_) {},
        onGutterWidthReset: onGutterWidthReset ?? () {},
        onSettingsPressed: () {},
        writingFont: writingFont,
        shortcuts: shortcuts ?? shortcutPrefs,
      ),
    ),
  );
}

/// The box the text field actually draws line [index] into — the ground
/// truth the gutter has to match.
///
/// Uses the strut height style so the box is the full line box, not just the
/// tight glyph bounds, and reads it from the live [RenderEditable] rather
/// than re-deriving it, so the assertion is independent of the code under
/// test.
Rect lineRect(WidgetTester tester, String body, int index) {
  final start = startOfLine(body, index);
  final line = body.split('\n')[index];
  final editable = tester
      .state<EditableTextState>(find.byType(EditableText))
      .renderEditable;
  // The field sets selectionHeightStyle to strut, so these are full line
  // boxes rather than tight glyph bounds.
  final boxes = editable.getBoxesForSelection(
    TextSelection(baseOffset: start, extentOffset: start + line.length),
  );
  expect(boxes, isNotEmpty, reason: 'line $index has no text box');
  final box = tester.renderObject<RenderBox>(find.byType(EditableText));
  final first = boxes.first;
  final origin = box.localToGlobal(Offset(first.left, first.top));
  return origin & Size(first.right - first.left, first.bottom - first.top);
}

/// Character offset at which line [index] starts.
int startOfLine(String body, int index) {
  var offset = 0;
  final lines = body.split('\n');
  for (var i = 0; i < index; i++) {
    offset += lines[i].length + 1;
  }
  return offset;
}

Finder chipWithText(String text) => find.widgetWithText(ResultChip, text);

Future<void> sendShortcut(WidgetTester tester, ShortcutBinding binding) async {
  if (binding.meta) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  }
  if (binding.control) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  }
  if (binding.alt) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  }
  if (binding.shift) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  }
  await tester.sendKeyEvent(binding.logicalKey);
  if (binding.shift) {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  }
  if (binding.alt) {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  }
  if (binding.control) {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  }
  if (binding.meta) {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  }
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() {
    engine = CalcEngine(ratesPerUsd: _rates);
    shortcutPrefs = ShortcutPrefs(_MemoryStore())..load();
  });

  // Double-clicking a blank line used to select its terminator, painting a
  // wide highlight over an empty line and opening the formatting toolbar on a
  // selection holding no text.
  testWidgets('double tapping a blank line leaves a caret, not a selection', (
    tester,
  ) async {
    const body = 'todo\n\n☐ login and sync\n☐ sharable link';
    await tester.pumpWidget(harness(body, autofocus: true));
    await tester.pumpAndSettle();

    final heading = lineRect(tester, body, 0);
    final firstItem = lineRect(tester, body, 2);
    final blank = Offset(
      heading.center.dx,
      (heading.bottom + firstItem.top) / 2,
    );

    await tester.tapAt(blank);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(blank);
    await tester.pumpAndSettle();

    final selection = tester
        .state<EditableTextState>(find.byType(EditableText))
        .textEditingValue
        .selection;
    expect(selection.isCollapsed, isTrue);
    expect(selection.baseOffset, body.indexOf('\n') + 1);
  });

  testWidgets('a selection that spans blank lines and text is kept', (
    tester,
  ) async {
    const body = 'todo\n\n☐ login and sync\n☐ sharable link';
    await tester.pumpWidget(harness(body, autofocus: true));
    await tester.pumpAndSettle();

    final state = tester.state<EditableTextState>(find.byType(EditableText));
    // Straddles the blank line on the way to real text.
    state.userUpdateTextEditingValue(
      state.textEditingValue.copyWith(
        selection: const TextSelection(baseOffset: 4, extentOffset: 12),
      ),
      SelectionChangedCause.drag,
    );
    await tester.pumpAndSettle();

    final selection = state.textEditingValue.selection;
    expect(selection.isCollapsed, isFalse);
    expect(selection.extentOffset, 12);
  });

  testWidgets('shows a result chip only for lines that calculate', (
    tester,
  ) async {
    await tester.pumpWidget(harness('Shopping list\n2 + 2\nbuy milk\n10 * 3'));
    await tester.pumpAndSettle();

    expect(find.byType(ResultChip), findsNWidgets(2));
    expect(chipWithText('4'), findsOneWidget);
    expect(chipWithText('30'), findsOneWidget);
  });

  testWidgets('aligns each chip with its own line', (tester) async {
    const body = 'Budget\n100 + 20\nsome prose here\n50 / 2\n\n7 * 6';
    await tester.pumpWidget(harness(body));
    await tester.pumpAndSettle();

    for (final entry in {1: '120', 3: '25', 5: '42'}.entries) {
      final line = lineRect(tester, body, entry.key);
      final chip = tester.getRect(chipWithText(entry.value));
      expect(
        chip.center.dy,
        closeTo(line.center.dy, 1.5),
        reason: 'chip "${entry.value}" should sit on line ${entry.key}',
      );
    }
  });

  testWidgets('keeps alignment when a line wraps onto two rows', (
    tester,
  ) async {
    // Long enough to wrap in the narrow text pane, which pushes every
    // following line down by one row.
    const long =
        '1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1';
    const body = 'first\n$long\nafter = 9';
    // The handwriting face is proportionally spaced and fits more of this
    // expression than the
    // old mono default, so keep the pane narrow enough to preserve the wrap.
    await tester.pumpWidget(harness(body, gutterWidth: 320));
    await tester.pumpAndSettle();

    final wrappedLine = lineRect(tester, body, 1);
    final afterLine = lineRect(tester, body, 2);
    // Confirm the line really did wrap before asserting anything about it.
    expect(afterLine.top - wrappedLine.top, greaterThan(wrappedLine.height));

    expect(
      tester.getRect(chipWithText('18')).center.dy,
      closeTo(wrappedLine.center.dy, 1.5),
    );
    expect(
      tester.getRect(chipWithText('9')).center.dy,
      closeTo(afterLine.center.dy, 1.5),
    );
  });

  testWidgets('keeps alignment when a wrapping line carries a comment', (
    tester,
  ) async {
    // Comments render in italic. Measuring the plain string instead of the
    // span the field paints put the wrap in the wrong place and shifted
    // every result below it up by one row.
    // Long enough to wrap, with the wrap falling inside the italic comment.
    const body =
        'Food and getting around town for the week // only a rough guess\n'
        'daily = 55\n'
        'daily * 7\n'
        'total';
    await tester.pumpWidget(harness(body, gutterWidth: 320));
    await tester.pumpAndSettle();

    final commented = lineRect(tester, body, 0);
    expect(
      lineRect(tester, body, 1).top - commented.top,
      greaterThan(commented.height),
      reason: 'the commented line should have wrapped',
    );

    for (final entry in {1: '55', 2: '385', 3: '440'}.entries) {
      expect(
        tester.getRect(chipWithText(entry.value)).center.dy,
        closeTo(lineRect(tester, body, entry.key).center.dy, 1.5),
        reason: 'chip "${entry.value}" should sit on line ${entry.key}',
      );
    }
  });

  testWidgets('dims only the slash comment portion of a line', (tester) async {
    const body = '  // travel assumptions\n2 + 2';
    await tester.pumpWidget(harness(body));
    await tester.pumpAndSettle();

    final rendered =
        tester
                .state<EditableTextState>(find.byType(EditableText))
                .renderEditable
                .text!
            as TextSpan;
    final comment = rendered.children!.whereType<TextSpan>().firstWhere(
      (span) => span.text?.contains('//') ?? false,
    );
    final indentation = rendered.children!.whereType<TextSpan>().firstWhere(
      (span) => span.text == '  ',
    );

    expect(comment.text, '// travel assumptions');
    expect(comment.style!.color, KapyTheme.darkPalette.comment);
    expect(comment.style!.fontStyle, FontStyle.italic);
    expect(indentation.style!.color, isNot(KapyTheme.darkPalette.comment));
    expect(find.byType(ResultChip), findsOneWidget);
    expect(chipWithText('4'), findsOneWidget);
  });

  testWidgets('keeps settings left, formatting centered, and total right', (
    tester,
  ) async {
    await tester.pumpWidget(harness('2 + 2'));
    await tester.pumpAndSettle();

    final footer = tester.getRect(find.byType(NoteFooter));
    final settings = tester.getRect(
      find.byKey(const ValueKey('note-settings')),
    );
    final formatting = tester.getRect(
      find.byKey(const ValueKey('note-formatting-controls')),
    );
    final total = tester.getRect(find.byKey(const ValueKey('note-total')));

    expect(settings.center.dx, lessThan(formatting.center.dx));
    expect(formatting.center.dx, closeTo(footer.center.dx, 1));
    expect(total.center.dx, greaterThan(formatting.center.dx));
    expect(total.right, closeTo(footer.right - 10, 1));
  });

  testWidgets('uses one compact surface for every footer icon control', (
    tester,
  ) async {
    await tester.pumpWidget(harness('2 + 2'));
    await tester.pumpAndSettle();

    final sizes = <Size>[
      for (final key in const [
        ValueKey('note-settings'),
        ValueKey('format-style'),
        ValueKey('format-bold'),
        ValueKey('format-italic'),
        ValueKey('format-bullets'),
        ValueKey('format-checklist'),
      ])
        tester.getSize(find.byKey(key)),
    ];
    expect(
      sizes,
      everyElement(const Size.square(24)),
      reason: 'Every footer control should use the same compact hover surface',
    );
  });

  testWidgets('keeps the footer controls separated on a narrow phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(harness('2 + 2'));
    await tester.pumpAndSettle();

    final settings = tester.getRect(
      find.byKey(const ValueKey('note-settings')),
    );
    final formatting = tester.getRect(
      find.byKey(const ValueKey('note-formatting-controls')),
    );
    final total = tester.getRect(find.byKey(const ValueKey('note-total')));
    expect(settings.right, lessThanOrEqualTo(formatting.left));
    expect(formatting.right, lessThanOrEqualTo(total.left));
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('note-total')))
          .textSpan!
          .toPlainText(),
      'Σ 4',
    );
  });

  testWidgets('applies real bold and italic styles without changing text', (
    tester,
  ) async {
    final changes = <List<NoteFormatRange>>[];
    await tester.pumpWidget(
      harness('Format me', onFormatsChanged: changes.add),
    );
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    field.controller!.selection = const TextSelection(
      baseOffset: 0,
      extentOffset: 6,
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('format-bold')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('format-italic')));
    await tester.pumpAndSettle();

    expect(field.controller!.text, 'Format me');
    expect(changes.last, const [
      NoteFormatRange(start: 0, end: 6, format: NoteFormat.bold),
      NoteFormatRange(start: 0, end: 6, format: NoteFormat.italic),
    ]);
    final rendered =
        tester
                .state<EditableTextState>(find.byType(EditableText))
                .renderEditable
                .text!
            as TextSpan;
    final formatted = rendered.children!.whereType<TextSpan>().firstWhere(
      (span) => span.text == 'Format',
    );
    expect(formatted.style!.fontWeight, FontWeight.w700);
    expect(formatted.style!.fontStyle, FontStyle.italic);
  });

  testWidgets('cycles paragraph presets directly from the footer', (
    tester,
  ) async {
    final changes = <List<NoteFormatRange>>[];
    await tester.pumpWidget(
      harness(
        'Project title\nA supporting thought',
        onFormatsChanged: changes.add,
      ),
    );
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    field.controller!.selection = const TextSelection(
      baseOffset: 2,
      extentOffset: 7,
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('format-style')));
    await tester.pumpAndSettle();

    expect(changes.last, const [
      NoteFormatRange(start: 0, end: 13, format: NoteFormat.heading),
    ]);
    final rendered =
        tester
                .state<EditableTextState>(find.byType(EditableText))
                .renderEditable
                .text!
            as TextSpan;
    final heading = rendered.children!.whereType<TextSpan>().firstWhere(
      (span) => span.text == 'Project title',
    );
    expect(heading.style!.fontWeight, FontWeight.w700);
    expect(
      heading.style!.fontSize,
      greaterThan(
        EditorMetrics.textStyle(
          Colors.white,
          WritingFont.handwritten,
        ).fontSize!,
      ),
    );

    await tester.tap(find.byKey(const ValueKey('format-style')));
    await tester.pumpAndSettle();
    expect(changes.last, const [
      NoteFormatRange(start: 0, end: 13, format: NoteFormat.subtitle),
    ]);

    await tester.tap(find.byKey(const ValueKey('format-style')));
    await tester.pumpAndSettle();
    expect(changes.last, isEmpty);
    expect(find.byType(PopupMenuButton<NoteParagraphStyle>), findsNothing);
  });

  testWidgets('a heading starts a persistent Subtitle after Enter', (
    tester,
  ) async {
    final changes = <List<NoteFormatRange>>[];
    await tester.pumpWidget(
      harness(
        'Project title',
        initialFormats: const [
          NoteFormatRange(start: 0, end: 13, format: NoteFormat.heading),
        ],
        onFormatsChanged: changes.add,
      ),
    );
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    field.controller!.selection = const TextSelection.collapsed(offset: 13);
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'Project title\nBody');
    await tester.pumpAndSettle();

    expect(changes.last, const [
      NoteFormatRange(start: 0, end: 13, format: NoteFormat.heading),
      NoteFormatRange(start: 14, end: 18, format: NoteFormat.subtitle),
    ]);
    final rendered =
        tester
                .state<EditableTextState>(find.byType(EditableText))
                .renderEditable
                .text!
            as TextSpan;
    final body = rendered.children!.whereType<TextSpan>().firstWhere(
      (span) => span.text?.contains('Body') ?? false,
    );
    expect(body.style!.fontWeight, FontWeight.w400);
    expect(body.style!.fontStyle, FontStyle.italic);

    field.controller!.value = const TextEditingValue(
      text: 'Project title\nBody\nMore',
      selection: TextSelection.collapsed(offset: 23),
    );
    await tester.pumpAndSettle();

    expect(changes.last, const [
      NoteFormatRange(start: 0, end: 13, format: NoteFormat.heading),
      NoteFormatRange(start: 14, end: 18, format: NoteFormat.subtitle),
      NoteFormatRange(start: 19, end: 23, format: NoteFormat.subtitle),
    ]);
  });

  testWidgets('starts an empty note in the chosen paragraph style', (
    tester,
  ) async {
    final changes = <List<NoteFormatRange>>[];
    await tester.pumpWidget(
      harness('', startAtEnd: true, onFormatsChanged: changes.add),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('format-style')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Project title');
    await tester.pumpAndSettle();

    expect(changes.last, const [
      NoteFormatRange(start: 0, end: 13, format: NoteFormat.heading),
    ]);
  });

  testWidgets('shows formatting actions beside selected text', (tester) async {
    final changes = <List<NoteFormatRange>>[];
    await tester.pumpWidget(
      harness(
        'Select this text',
        autofocus: true,
        onFormatsChanged: changes.add,
      ),
    );
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    field.controller!.selection = const TextSelection(
      baseOffset: 0,
      extentOffset: 6,
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('selection-formatting-toolbar')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('selection-style')), findsOneWidget);
    expect(find.byKey(const ValueKey('selection-bold')), findsOneWidget);
    expect(find.byKey(const ValueKey('selection-italic')), findsOneWidget);
    expect(find.byKey(const ValueKey('selection-bullets')), findsOneWidget);
    expect(find.byKey(const ValueKey('selection-checklist')), findsOneWidget);
    expect(find.byKey(const ValueKey('selection-more')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('selection-style'))).height,
      24,
    );
    for (final key in const [
      ValueKey('selection-bold'),
      ValueKey('selection-italic'),
      ValueKey('selection-bullets'),
      ValueKey('selection-checklist'),
    ]) {
      expect(
        tester.getSize(
          find.descendant(
            of: find.byKey(key),
            matching: find.byType(IconButton),
          ),
        ),
        const Size.square(24),
      );
    }
    final selectionFade = tester.widget<FadeTransition>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('selection-formatting-toolbar')),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    expect(selectionFade.opacity.value, closeTo(1, 0.01));

    await tester.tap(find.byKey(const ValueKey('selection-bold')));
    await tester.pumpAndSettle();
    expect(changes.last, const [
      NoteFormatRange(start: 0, end: 6, format: NoteFormat.bold),
    ]);
  });

  testWidgets('cycles selected line styles without a floating popover', (
    tester,
  ) async {
    final changes = <List<NoteFormatRange>>[];
    await tester.pumpWidget(
      harness(
        'A supporting thought',
        autofocus: true,
        onFormatsChanged: changes.add,
      ),
    );
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    field.controller!.selection = const TextSelection(
      baseOffset: 2,
      extentOffset: 12,
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('selection-style')));
    await tester.pumpAndSettle();
    expect(changes.last, const [
      NoteFormatRange(start: 0, end: 20, format: NoteFormat.heading),
    ]);
    expect(
      find.byKey(const ValueKey('selection-formatting-toolbar')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('selection-style')));
    await tester.pumpAndSettle();

    expect(changes.last, const [
      NoteFormatRange(start: 0, end: 20, format: NoteFormat.subtitle),
    ]);
    expect(find.byType(PopupMenuButton<NoteParagraphStyle>), findsNothing);
  });

  testWidgets('Text style preserves independent bold and italic controls', (
    tester,
  ) async {
    final changes = <List<NoteFormatRange>>[];
    await tester.pumpWidget(
      harness(
        'Keep emphasis',
        initialFormats: const [
          NoteFormatRange(start: 0, end: 4, format: NoteFormat.bold),
          NoteFormatRange(start: 5, end: 13, format: NoteFormat.italic),
          NoteFormatRange(start: 0, end: 13, format: NoteFormat.subtitle),
        ],
        onFormatsChanged: changes.add,
      ),
    );
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    field.controller!.selection = const TextSelection(
      baseOffset: 0,
      extentOffset: 13,
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('format-style')));
    await tester.pumpAndSettle();

    expect(changes.last, const [
      NoteFormatRange(start: 0, end: 4, format: NoteFormat.bold),
      NoteFormatRange(start: 5, end: 13, format: NoteFormat.italic),
    ]);
    final rendered =
        tester
                .state<EditableTextState>(find.byType(EditableText))
                .renderEditable
                .text!
            as TextSpan;
    final bold = rendered.children!.whereType<TextSpan>().firstWhere(
      (span) => span.text == 'Keep',
    );
    final italic = rendered.children!.whereType<TextSpan>().firstWhere(
      (span) => span.text == 'emphasis',
    );
    expect(bold.style!.fontWeight, FontWeight.w700);
    expect(italic.style!.fontStyle, FontStyle.italic);
  });

  testWidgets('keeps the selection toolbar inside a narrow phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(harness('Select this text', autofocus: true));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    field.controller!.selection = const TextSelection(
      baseOffset: 0,
      extentOffset: 6,
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    final toolbar = tester.getRect(
      find.byKey(const ValueKey('selection-formatting-toolbar')),
    );
    expect(toolbar.left, greaterThanOrEqualTo(0));
    expect(toolbar.right, lessThanOrEqualTo(320));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a collapsed format toggle styles subsequent typing', (
    tester,
  ) async {
    final changes = <List<NoteFormatRange>>[];
    await tester.pumpWidget(harness('A', onFormatsChanged: changes.add));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    field.controller!.selection = const TextSelection.collapsed(offset: 1);
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('format-bold')));
    await tester.pump();
    field.controller!.value = const TextEditingValue(
      text: 'AB',
      selection: TextSelection.collapsed(offset: 2),
    );
    await tester.pumpAndSettle();

    expect(changes.last, const [
      NoteFormatRange(start: 1, end: 2, format: NoteFormat.bold),
    ]);
  });

  testWidgets('supports the OS-specific bold and italic shortcuts', (
    tester,
  ) async {
    final changes = <List<NoteFormatRange>>[];
    await tester.pumpWidget(
      harness('Shortcut', autofocus: true, onFormatsChanged: changes.add),
    );
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    field.controller!.selection = const TextSelection(
      baseOffset: 0,
      extentOffset: 8,
    );
    await tester.pump();

    await sendShortcut(
      tester,
      shortcutPrefs.bindingFor(ShortcutAction.formatBold),
    );
    await sendShortcut(
      tester,
      shortcutPrefs.bindingFor(ShortcutAction.formatItalic),
    );
    await tester.pumpAndSettle();

    expect(changes.last, const [
      NoteFormatRange(start: 0, end: 8, format: NoteFormat.bold),
      NoteFormatRange(start: 0, end: 8, format: NoteFormat.italic),
    ]);
  });

  testWidgets('cycles styles and toggles list formats from the keyboard', (
    tester,
  ) async {
    final changes = <List<NoteFormatRange>>[];
    await tester.pumpWidget(
      harness('Task', autofocus: true, onFormatsChanged: changes.add),
    );
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    field.controller!.selection = const TextSelection(
      baseOffset: 0,
      extentOffset: 4,
    );
    await tester.pump();

    await sendShortcut(
      tester,
      shortcutPrefs.bindingFor(ShortcutAction.cycleTextStyle),
    );
    await tester.pumpAndSettle();
    expect(changes.last, const [
      NoteFormatRange(start: 0, end: 4, format: NoteFormat.heading),
    ]);
    await sendShortcut(
      tester,
      shortcutPrefs.bindingFor(ShortcutAction.cycleTextStyle),
    );
    await tester.pumpAndSettle();
    expect(changes.last, const [
      NoteFormatRange(start: 0, end: 4, format: NoteFormat.subtitle),
    ]);
    await sendShortcut(
      tester,
      shortcutPrefs.bindingFor(ShortcutAction.cycleTextStyle),
    );
    await tester.pumpAndSettle();
    expect(changes.last, isEmpty);

    await sendShortcut(
      tester,
      shortcutPrefs.bindingFor(ShortcutAction.formatBullets),
    );
    await tester.pumpAndSettle();
    expect(field.controller!.text, '${bulletPrefix}Task');

    await sendShortcut(
      tester,
      shortcutPrefs.bindingFor(ShortcutAction.formatChecklist),
    );
    await tester.pumpAndSettle();
    expect(field.controller!.text, '${uncheckedPrefix}Task');
  });

  testWidgets('footer hints and actions follow a changed shortcut live', (
    tester,
  ) async {
    await tester.pumpWidget(harness('Task', autofocus: true));
    await tester.pumpAndSettle();
    expect(
      find.byTooltip(
        'Text style: Text · ${shortcutPrefs.bindingFor(ShortcutAction.cycleTextStyle).displayLabel}',
      ),
      findsOneWidget,
    );
    expect(
      find.byTooltip(
        'Bold · ${shortcutPrefs.bindingFor(ShortcutAction.formatBold).displayLabel}',
      ),
      findsOneWidget,
    );
    expect(
      find.byTooltip(
        'Italic · ${shortcutPrefs.bindingFor(ShortcutAction.formatItalic).displayLabel}',
      ),
      findsOneWidget,
    );
    final original = shortcutPrefs.bindingFor(ShortcutAction.formatBullets);
    expect(
      find.byTooltip('Bulleted list · ${original.displayLabel}'),
      findsOneWidget,
    );
    expect(
      find.byTooltip(
        'Checklist · ${shortcutPrefs.bindingFor(ShortcutAction.formatChecklist).displayLabel}',
      ),
      findsOneWidget,
    );

    const replacement = ShortcutBinding(
      logicalKey: LogicalKeyboardKey.keyU,
      physicalKey: PhysicalKeyboardKey.keyU,
      control: true,
      alt: true,
    );
    shortcutPrefs.update(ShortcutAction.formatBullets, replacement);
    await tester.pumpAndSettle();

    expect(
      find.byTooltip('Bulleted list · ${replacement.displayLabel}'),
      findsOneWidget,
    );
    final field = tester.widget<TextField>(find.byType(TextField));
    field.controller!.selection = const TextSelection(
      baseOffset: 0,
      extentOffset: 4,
    );
    await sendShortcut(tester, replacement);
    await tester.pumpAndSettle();
    expect(field.controller!.text, '${bulletPrefix}Task');
  });

  testWidgets('creates, completes, and removes a checklist item', (
    tester,
  ) async {
    await tester.pumpWidget(harness('Task'));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    field.controller!.selection = const TextSelection.collapsed(offset: 4);
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('format-checklist')));
    await tester.pumpAndSettle();
    expect(field.controller!.text, '☐ Task');

    final editable = tester
        .state<EditableTextState>(find.byType(EditableText))
        .renderEditable;
    final checkbox = editable
        .getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 1),
        )
        .single;
    final checkboxCenter = editable.localToGlobal(
      Offset(
        (checkbox.left + checkbox.right) / 2,
        (checkbox.top + checkbox.bottom) / 2,
      ),
    );
    await tester.tapAt(checkboxCenter);
    await tester.pumpAndSettle();
    expect(field.controller!.text, '☑ Task');
    final rendered = editable.text! as TextSpan;
    final completed = rendered.children!.whereType<TextSpan>().firstWhere(
      (span) => span.text == 'Task',
    );
    expect(completed.style!.decoration, TextDecoration.lineThrough);

    await tester.tapAt(checkboxCenter);
    await tester.pumpAndSettle();
    expect(field.controller!.text, '☐ Task');

    await tester.tap(find.byKey(const ValueKey('format-checklist')));
    await tester.pumpAndSettle();
    expect(field.controller!.text, 'Task');
  });

  testWidgets('Enter keeps a nested item at its own depth', (tester) async {
    await tester.pumpWidget(harness('• one\n  • two'));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    field.controller!.selection = const TextSelection.collapsed(offset: 13);
    await tester.pump();

    await tester.enterText(find.byType(TextField), '• one\n  • two\n');
    await tester.pumpAndSettle();
    expect(field.controller!.text, '• one\n  • two\n  • ');
  });

  testWidgets('Enter on an empty nested item steps out one level at a time', (
    tester,
  ) async {
    await tester.pumpWidget(harness('• one\n    • '));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    field.controller!.selection = const TextSelection.collapsed(offset: 12);
    await tester.pump();

    await tester.enterText(find.byType(TextField), '• one\n    • \n');
    await tester.pumpAndSettle();
    expect(field.controller!.text, '• one\n  • ');

    await tester.enterText(find.byType(TextField), '• one\n  • \n');
    await tester.pumpAndSettle();
    expect(field.controller!.text, '• one\n• ');

    // Back at the margin, the next Enter leaves the list, as it always did.
    await tester.enterText(find.byType(TextField), '• one\n• \n');
    await tester.pumpAndSettle();
    expect(field.controller!.text, '• one\n');
  });

  testWidgets('Tab nests the current item and Shift+Tab lifts it out', (
    tester,
  ) async {
    await tester.pumpWidget(harness('• one', autofocus: true));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    field.controller!.selection = const TextSelection.collapsed(offset: 5);
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(field.controller!.text, '  • one');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(field.controller!.text, '• one');
  });

  testWidgets('Tab is left to move focus when the caret is not on a list', (
    tester,
  ) async {
    await tester.pumpWidget(harness('just prose', autofocus: true));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    field.controller!.selection = const TextSelection.collapsed(offset: 4);
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(field.controller!.text, 'just prose');
  });

  testWidgets('the nesting controls appear only for a list line', (
    tester,
  ) async {
    await tester.pumpWidget(harness('plain\n• item', autofocus: true));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));

    field.controller!.selection = const TextSelection.collapsed(offset: 2);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('format-indent')), findsNothing);

    field.controller!.selection = const TextSelection.collapsed(offset: 9);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('format-indent')), findsOneWidget);
    // Already at the margin, so there is nowhere to step out to.
    final outdent = tester.widget<IconButton>(
      find.descendant(
        of: find.byKey(const ValueKey('format-outdent')),
        matching: find.byType(IconButton),
      ),
    );
    expect(outdent.onPressed, isNull);
  });

  testWidgets('continues and exits a checklist with Enter', (tester) async {
    await tester.pumpWidget(harness('☐ Task'));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    field.controller!.selection = const TextSelection.collapsed(offset: 6);
    await tester.pump();

    await tester.enterText(find.byType(TextField), '☐ Task\n');
    await tester.pumpAndSettle();
    expect(field.controller!.text, '☐ Task\n☐ ');

    await tester.enterText(find.byType(TextField), '☐ Task\n☐ \n');
    await tester.pumpAndSettle();
    expect(field.controller!.text, '☐ Task\n');
  });

  testWidgets('aligns a line that only wraps because of the caret margin', (
    tester,
  ) async {
    // RenderEditable lays text out inside `width - (1px gap + cursorWidth)`.
    // A line longer than that but shorter than the full width wraps in the
    // field and nowhere else, which silently shifted every result below it.
    //
    // That window is narrower than one monospace glyph, so rather than
    // stretch the line to fit it, the test sizes the field around the line.
    double fieldWidth(WidgetTester tester) => tester
        .state<EditableTextState>(find.byType(EditableText))
        .renderEditable
        .size
        .width;

    const baseGutter = 200.0;
    await tester.pumpWidget(
      harness(
        'seed',
        gutterWidth: baseGutter,
        writingFont: WritingFont.monospace,
      ),
    );
    await tester.pumpAndSettle();
    final baseWidth = fieldWidth(tester);

    final probe = TextPainter(
      text: TextSpan(
        text: 'x',
        style: EditorMetrics.textStyle(
          const Color(0xFF000000),
          WritingFont.monospace,
        ),
      ),
      textDirection: TextDirection.ltr,
      strutStyle: EditorMetrics.strut(WritingFont.monospace),
    )..layout();
    final advance = probe.width;
    probe.dispose();

    // Widen the gutter just enough that the line lands inside the reserved
    // sliver: too long for the text area, short enough for the field.
    final chars = (baseWidth / advance).floor();
    final lineWidth = chars * advance;
    final targetWidth = lineWidth + EditorMetrics.caretMargin / 2;
    final gutter = baseGutter + (baseWidth - targetWidth);

    final body = '${'a' * chars}\n6 * 7';
    await tester.pumpWidget(
      harness(body, gutterWidth: gutter, writingFont: WritingFont.monospace),
    );
    await tester.pumpAndSettle();

    final width = fieldWidth(tester);
    expect(
      lineWidth,
      greaterThan(EditorMetrics.textLayoutWidth(width)),
      reason: 'the line must be too long for the text area',
    );
    expect(
      lineWidth,
      lessThan(width),
      reason: 'but short enough for the field, or the test proves nothing',
    );

    expect(
      lineRect(tester, body, 1).top - lineRect(tester, body, 0).top,
      greaterThan(EditorMetrics.lineHeight),
      reason: 'the field should have wrapped the line',
    );
    expect(
      tester.getRect(chipWithText('42')).center.dy,
      closeTo(lineRect(tester, body, 1).center.dy, 1.5),
    );
  });

  testWidgets('the field renders with the metrics the gutter measures', (
    tester,
  ) async {
    // The gutter lays the note out itself to find each line. If the field's
    // effective style differs in any property that changes glyph advances —
    // Material's text theme supplies a non-zero letterSpacing unless it is
    // overridden — the two disagree about where lines wrap.
    await tester.pumpWidget(harness('2 + 2'));
    await tester.pumpAndSettle();

    final rendered = tester
        .state<EditableTextState>(find.byType(EditableText))
        .renderEditable
        .text!
        .style!;
    final expected = EditorMetrics.textStyle(
      const Color(0xFF000000),
      WritingFont.handwritten,
    );

    expect(rendered.letterSpacing, expected.letterSpacing);
    expect(rendered.wordSpacing, expected.wordSpacing);
    expect(rendered.fontSize, expected.fontSize);
    expect(rendered.height, expected.height);
    expect(rendered.fontFamily, expected.fontFamily);
    expect(rendered.fontWeight, expected.fontWeight);
    expect(rendered.fontVariations, expected.fontVariations);
    expect(rendered.leadingDistribution, expected.leadingDistribution);
  });

  testWidgets('changes typeface live and keeps result alignment', (
    tester,
  ) async {
    const body = 'Notebook total\n21 * 2';
    await tester.pumpWidget(
      harness(body, writingFont: WritingFont.handwritten),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).style?.fontFamily,
      'Shantell Sans',
    );

    await tester.pumpWidget(harness(body, writingFont: WritingFont.monospace));
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(find.byType(TextField)).style?.fontFamily,
      WritingFont.monospace.fontFamily,
    );
    expect(
      tester.getRect(chipWithText('42')).center.dy,
      closeTo(lineRect(tester, body, 1).center.dy, 1.5),
    );
  });

  testWidgets('results divider advertises and reports horizontal dragging', (
    tester,
  ) async {
    final widths = <double>[];
    final visibility = <bool>[];
    await tester.pumpWidget(
      harness(
        '2 + 2',
        onGutterWidthChanged: widths.add,
        onResultsVisibilityChanged: visibility.add,
      ),
    );
    await tester.pumpAndSettle();

    final divider = find.byType(GutterDivider);
    final region = find.byKey(const ValueKey('results-divider-hover'));
    final gripOpacity = find.byKey(
      const ValueKey('results-divider-grip-opacity'),
    );
    expect(
      tester.widget<MouseRegion>(region).cursor,
      SystemMouseCursors.resizeLeftRight,
    );
    expect(tester.widget<AnimatedOpacity>(gripOpacity).opacity, 0);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(divider));
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(gripOpacity).opacity, 1);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.text('Drag to resize. Click to hide.'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('results-divider-line'))).width,
      2,
    );

    await mouse.down(tester.getCenter(divider));
    // The first move clears the gesture slop; the second is the resize delta.
    await mouse.moveBy(const Offset(-20, 0));
    await tester.pump();
    await mouse.moveBy(const Offset(-20, 0));
    await mouse.up();
    await tester.pumpAndSettle();

    expect(widths, isNotEmpty);
    expect(widths.last, greaterThan(200));

    widths.clear();
    await mouse.moveTo(tester.getCenter(divider));
    await mouse.down(tester.getCenter(divider));
    await mouse.moveBy(const Offset(20, 0));
    await tester.pump();
    await mouse.moveBy(const Offset(20, 0));
    await mouse.up();
    await tester.pumpAndSettle();

    expect(widths, isNotEmpty);
    expect(widths.last, lessThan(200));

    widths.clear();
    await mouse.moveTo(tester.getCenter(divider));
    await mouse.down(tester.getCenter(divider));
    await mouse.moveBy(const Offset(20, 0));
    await tester.pump();
    await mouse.moveBy(const Offset(220, 0));
    await mouse.up();
    await tester.pumpAndSettle();

    expect(widths, isNotEmpty);
    expect(widths.last, lessThan(100));
    expect(
      visibility,
      isEmpty,
      reason: 'dragging only resizes; it never hides the results column',
    );
  });

  testWidgets('clicking the results divider collapses to a restore edge', (
    tester,
  ) async {
    final visibility = <bool>[];
    await tester.pumpWidget(
      harness('2 + 2', onResultsVisibilityChanged: visibility.add),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('results-divider')));
    // The divider also reserves double-click for width reset, so its single
    // click resolves after the platform double-click window.
    await tester.pump(const Duration(milliseconds: 400));

    expect(visibility, [false]);

    visibility.clear();
    await tester.pumpWidget(
      harness(
        '2 + 2',
        resultsVisible: false,
        onResultsVisibilityChanged: visibility.add,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(GutterDivider), findsNothing);
    expect(find.byType(ResultsGutter), findsNothing);
    expect(find.byType(ResultsRestoreHandle), findsOneWidget);
    expect(
      find.byTooltip('Show results. Drag left to resize.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<MouseRegion>(
            find.byKey(const ValueKey('results-restore-hover')),
          )
          .cursor,
      SystemMouseCursors.resizeLeftRight,
    );

    final restore = find.byKey(const ValueKey('results-restore-handle'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(restore));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.byKey(const ValueKey('results-restore-grip-opacity')),
          )
          .opacity,
      1,
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.text('Show results. Drag left to resize.'), findsOneWidget);

    await tester.tap(restore);
    await tester.pump();
    expect(visibility, [true]);
  });

  testWidgets('dragging left from the restore edge chooses its width', (
    tester,
  ) async {
    final widths = <double>[];
    final visibility = <bool>[];
    await tester.pumpWidget(
      harness(
        '2 + 2',
        resultsVisible: false,
        onGutterWidthChanged: widths.add,
        onResultsVisibilityChanged: visibility.add,
      ),
    );
    await tester.pumpAndSettle();

    final restore = find.byKey(const ValueKey('results-restore-handle'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: tester.getCenter(restore));
    await mouse.down(tester.getCenter(restore));
    await mouse.moveBy(const Offset(-20, 0));
    await tester.pump();
    await mouse.moveBy(const Offset(-180, 0));
    await mouse.up();
    await tester.pumpAndSettle();

    expect(widths, isNotEmpty);
    expect(widths.last, closeTo(180, 1));
    expect(visibility, [true]);
  });

  testWidgets('keeps results pinned to their lines while scrolling', (
    tester,
  ) async {
    // Long enough that the note must scroll inside the field.
    final body = List.generate(60, (i) => '${i + 1} * 10').join('\n');
    await tester.pumpWidget(harness(body));
    await tester.pumpAndSettle();

    final before = tester.getRect(chipWithText('100')).center.dy;
    final lineBefore = lineRect(tester, body, 9).center.dy;
    expect(before, closeTo(lineBefore, 1.5));

    await tester.drag(find.byType(TextField), const Offset(0, -120));
    await tester.pumpAndSettle();

    final after = tester.getRect(chipWithText('100')).center.dy;
    final lineAfter = lineRect(tester, body, 9).center.dy;
    expect(after, lessThan(before), reason: 'the note should have scrolled');
    expect(after, closeTo(lineAfter, 1.5));
  });

  testWidgets('recalculates as the user types', (tester) async {
    await tester.pumpWidget(harness('2 + 2'));
    await tester.pumpAndSettle();
    expect(chipWithText('4'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('note-total')))
          .textSpan!
          .toPlainText(),
      'Total: 4',
    );

    await tester.enterText(find.byType(TextField), '2 + 2\n40 + 2');
    await tester.pumpAndSettle();

    expect(chipWithText('4'), findsOneWidget);
    expect(chipWithText('42'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('note-total')))
          .textSpan!
          .toPlainText(),
      'Total: 46',
    );
    expect(find.byTooltip('Settings'), findsOneWidget);
  });

  testWidgets('hides the running total until the note has a calculation', (
    tester,
  ) async {
    await tester.pumpWidget(harness('Groceries for the weekend'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('note-total')), findsNothing);

    await tester.enterText(
      find.byType(TextField),
      'Groceries for the weekend\n12 + 30',
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('note-total')))
          .textSpan!
          .toPlainText(),
      'Total: 42',
    );
  });

  testWidgets('carries a variable down to later lines', (tester) async {
    await tester.pumpWidget(harness('subtotal = 42\nsubtotal * 3'));
    await tester.pumpAndSettle();

    expect(chipWithText('42'), findsOneWidget);
    expect(chipWithText('126'), findsOneWidget);
  });

  testWidgets('shows the placeholder only while the note is empty', (
    tester,
  ) async {
    await tester.pumpWidget(harness(''));
    await tester.pumpAndSettle();
    expect(find.textContaining('Start typing'), findsOneWidget);
    expect(find.textContaining('10rs to usd'), findsOneWidget);
    expect(find.textContaining('Try a few things'), findsOneWidget);
    expect(find.textContaining('Add a checklist'), findsOneWidget);
    expect(find.textContaining('Idea details // inline note'), findsOneWidget);
    final sample = tester.widget<Text>(find.textContaining('Start typing'));
    final sampleSpan = sample.textSpan! as TextSpan;
    final sampleSpans = sampleSpan.children!.whereType<TextSpan>();
    final heading = sampleSpans.firstWhere(
      (span) => span.text == 'Start typing…\n',
    );
    final subtitle = sampleSpans.firstWhere(
      (span) => span.text?.startsWith('Notes and quick') ?? false,
    );
    expect(heading.style!.fontWeight, FontWeight.w700);
    expect(subtitle.style!.fontStyle, FontStyle.italic);
    expect(find.byKey(const ValueKey('note-total')), findsNothing);

    await tester.enterText(find.byType(TextField), '1');
    await tester.pumpAndSettle();
    expect(find.textContaining('Start typing'), findsNothing);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('note-total')))
          .textSpan!
          .toPlainText(),
      'Total: 1',
    );
  });

  testWidgets('prepares a blank line without saving it on open', (
    tester,
  ) async {
    final changes = <String>[];
    final previousEdit = DateTime(2026, 9, 1, 21, 42);
    await tester.pumpWidget(
      harness(
        'Yesterday',
        lastUpdatedAt: previousEdit,
        dailySeparatorsEnabled: true,
        now: () => DateTime(2026, 9, 2, 8, 15),
        startAtEnd: true,
        onBodyChanged: changes.add,
      ),
    );
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'Yesterday\n\n');
    expect(field.controller!.selection.baseOffset, 'Yesterday\n\n'.length);
    expect(changes, isEmpty);
    expect(field.controller!.text, isNot(contains('// ─')));
  });

  testWidgets('same-day reopen starts after one empty line', (tester) async {
    final now = DateTime(2026, 9, 1, 22, 15);
    await tester.pumpWidget(
      harness(
        'Earlier today',
        lastUpdatedAt: DateTime(2026, 9, 1, 21, 42),
        dailySeparatorsEnabled: true,
        now: () => now,
        startAtEnd: true,
      ),
    );
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'Earlier today\n\n');

    await tester.enterText(find.byType(TextField), 'Earlier today\n\nMore');
    await tester.pumpAndSettle();
    expect(field.controller!.text, 'Earlier today\n\nMore');
  });

  testWidgets('starts a dated section only on the first new-day append', (
    tester,
  ) async {
    final previousEdit = DateTime(2026, 9, 1, 21, 42);
    await tester.pumpWidget(
      harness(
        'Yesterday',
        lastUpdatedAt: previousEdit,
        dailySeparatorsEnabled: true,
        now: () => DateTime(2026, 9, 2, 0, 1),
        startAtEnd: true,
      ),
    );
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'Yesterday\n\n');

    await tester.enterText(find.byType(TextField), 'Yesterday\n\nT');
    await tester.pumpAndSettle();

    expect(field.controller!.text, 'Yesterday\n\n// ─ 1 Sep · 21:42 ─\nT');
  });

  testWidgets('uses the selected time zone for a new-day append', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        'Late entry',
        lastUpdatedAt: DateTime.utc(2026, 9, 2, 3, 30),
        dailySeparatorsEnabled: true,
        now: () => DateTime.utc(2026, 9, 2, 4, 30),
        displayTime: (instant) =>
            AppTimeZones.convert(instant, 'America/New_York'),
        startAtEnd: true,
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Late entry\n\nN');
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'Late entry\n\n// ─ 1 Sep · 23:30 ─\nN');
  });

  testWidgets('skipped days produce only one separator when typing resumes', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        'Last entry',
        lastUpdatedAt: DateTime(2026, 9, 1, 21, 42),
        dailySeparatorsEnabled: true,
        now: () => DateTime(2026, 9, 5, 8, 15),
        startAtEnd: true,
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Last entry\n\nBack again');
    await tester.pumpAndSettle();

    final text = tester
        .widget<TextField>(find.byType(TextField))
        .controller!
        .text;
    expect(text, 'Last entry\n\n// ─ 1 Sep · 21:42 ─\nBack again');
    expect(RegExp(r'^// ─', multiLine: true).allMatches(text), hasLength(1));
  });

  testWidgets('reuses a hidden trailing separator when content is added', (
    tester,
  ) async {
    const original = 'Ideas\n\n// ─ 1 Sep · 21:42 ─\n';
    final changes = <String>[];
    await tester.pumpWidget(
      harness(
        original,
        // The previous app version timestamped the note when it eagerly
        // added the empty separator. The separator itself is the accurate
        // boundary and must win when the user finally types.
        lastUpdatedAt: DateTime(2026, 9, 2, 8, 15),
        dailySeparatorsEnabled: true,
        now: () => DateTime(2026, 9, 2, 9),
        startAtEnd: true,
        onBodyChanged: changes.add,
      ),
    );
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'Ideas\n\n');
    expect(changes, isEmpty);

    await tester.enterText(find.byType(TextField), 'Ideas\n\nNext idea');
    await tester.pumpAndSettle();

    expect(field.controller!.text, 'Ideas\n\n// ─ 1 Sep · 21:42 ─\nNext idea');
    expect(changes.single, field.controller!.text);
  });

  testWidgets('retries the startup keyboard request after the first frame', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        'Ready',
        startAtEnd: true,
        autofocus: true,
        ensureKeyboardVisible: true,
      ),
    );
    await tester.pump();

    // Android can reject the TextField's first request while FlutterView is
    // still becoming the served input view. Ignore the immediate request and
    // verify the editor sends a later one while it remains focused.
    tester.testTextInput.log.clear();
    await tester.pump(const Duration(seconds: 2));

    expect(
      tester.testTextInput.log.map((call) => call.method),
      contains('TextInput.show'),
    );

    // A failed request has no Dart-side acknowledgement, so the startup
    // guard keeps trying for a short bounded window.
    tester.testTextInput.log.clear();
    await tester.pump(const Duration(seconds: 2));
    expect(
      tester.testTextInput.log.map((call) => call.method),
      contains('TextInput.show'),
    );
  });

  testWidgets('copies full precision when a chip is tapped', (tester) async {
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

    await tester.pumpWidget(harness('2 / 3'));
    await tester.pumpAndSettle();

    // The chip is truncated for display but must copy the full value.
    expect(chipWithText('0.666667'), findsOneWidget);
    await tester.tap(chipWithText('0.666667'));
    await tester.pumpAndSettle();

    expect(copied, ['0.666666666667']);

    // Let the "copied" tick and the toast finish so no timer outlives the test.
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('shows a result in words when its chip is hovered', (
    tester,
  ) async {
    await tester.pumpWidget(harness('12345678'));
    await tester.pumpAndSettle();

    final chip = chipWithText('12,345,678');
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(chip));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Twelve million three hundred forty-five thousand six hundred '
        'seventy-eight\n12.345678 million\nClick to copy',
      ),
      findsOneWidget,
    );
  });
}
