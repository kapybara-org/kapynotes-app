import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/calc/highlight.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/editor/results_gutter.dart';

import 'test_fonts.dart';

const _rates = <String, double>{'EUR': 0.86, 'GBP': 0.74};

late CalcEngine engine;

Widget harness(
  String body, {
  double gutterWidth = 200,
  DateTime? lastUpdatedAt,
  bool dailySeparatorsEnabled = false,
  DateTime Function()? now,
  bool startAtEnd = false,
  bool autofocus = false,
  bool ensureKeyboardVisible = false,
  ValueChanged<String>? onBodyChanged,
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
        engine: engine,
        highlighter: Highlighter(engine.registry),
        gutterWidth: gutterWidth,
        lastUpdatedAt: lastUpdatedAt,
        dailySeparatorsEnabled: dailySeparatorsEnabled,
        now: now,
        startAtEnd: startAtEnd,
        autofocus: autofocus,
        ensureKeyboardVisible: ensureKeyboardVisible,
        onBodyChanged: onBodyChanged ?? (_) {},
        onGutterWidthChanged: (_) {},
        onGutterWidthReset: () {},
        onSettingsPressed: () {},
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

void main() {
  setUpAll(loadTestFonts);
  setUp(() => engine = CalcEngine(ratesPerUsd: _rates));

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
    await tester.pumpWidget(harness(body, gutterWidth: 140));
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
    await tester.pumpWidget(harness(body, gutterWidth: 200));
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

  testWidgets('dims a line that starts with a slash comment', (tester) async {
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

    expect(comment.text, '  // travel assumptions');
    expect(comment.style!.color, KapyTheme.darkPalette.comment);
    expect(comment.style!.fontStyle, FontStyle.italic);
    expect(find.byType(ResultChip), findsOneWidget);
    expect(chipWithText('4'), findsOneWidget);
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
    await tester.pumpWidget(harness('seed', gutterWidth: baseGutter));
    await tester.pumpAndSettle();
    final baseWidth = fieldWidth(tester);

    final probe = TextPainter(
      text: TextSpan(
        text: 'x',
        style: EditorMetrics.textStyle(const Color(0xFF000000)),
      ),
      textDirection: TextDirection.ltr,
      strutStyle: EditorMetrics.strut,
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
    await tester.pumpWidget(harness(body, gutterWidth: gutter));
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
    final expected = EditorMetrics.textStyle(const Color(0xFF000000));

    expect(rendered.letterSpacing, expected.letterSpacing);
    expect(rendered.wordSpacing, expected.wordSpacing);
    expect(rendered.fontSize, expected.fontSize);
    expect(rendered.height, expected.height);
    expect(rendered.fontFamily, expected.fontFamily);
    expect(rendered.fontWeight, expected.fontWeight);
    expect(rendered.leadingDistribution, expected.leadingDistribution);
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
    expect(
      find.textContaining('Start with // to add a comment'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('note-total')))
          .textSpan!
          .toPlainText(),
      'Total: 0',
    );

    await tester.enterText(find.byType(TextField), '1');
    await tester.pumpAndSettle();
    expect(find.textContaining('Start typing'), findsNothing);
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
}
