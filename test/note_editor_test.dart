import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
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
import 'package:kapy_notes/data/time_zones.dart';
import 'package:kapy_notes/ui/editor/editor_formatting.dart';
import 'package:kapy_notes/ui/celebrate.dart';
import 'package:kapy_notes/ui/kapy_cursor_peek.dart';
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

/// The middle of a substring's first line, in global coordinates.
Offset _centerOf(WidgetTester tester, String body, String linkText) {
  final editable = tester
      .state<EditableTextState>(find.byType(EditableText))
      .renderEditable;
  final start = body.indexOf(linkText);
  final box = editable
      .getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: start + linkText.length),
      )
      .first;
  return editable.localToGlobal(
    Offset((box.left + box.right) / 2, (box.top + box.bottom) / 2),
  );
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
  bool readOnly = false,
  ValueChanged<String>? onBodyChanged,
  ValueChanged<List<NoteFormatRange>>? onFormatsChanged,
  ValueChanged<double>? onGutterWidthChanged,
  ValueChanged<bool>? onResultsVisibilityChanged,
  VoidCallback? onGutterWidthReset,
  VoidCallback? onSettingsPressed,
  VoidCallback? onRecordVoice,
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
        readOnly: readOnly,
        onDocumentChanged: (body, formats, attachments) {
          onBodyChanged?.call(body);
          onFormatsChanged?.call(formats);
        },
        onGutterWidthChanged: onGutterWidthChanged ?? (_) {},
        onResultsVisibilityChanged: onResultsVisibilityChanged ?? (_) {},
        onGutterWidthReset: onGutterWidthReset ?? () {},
        onSettingsPressed: onSettingsPressed ?? () {},
        onRecordVoice: onRecordVoice,
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

/// Reveals the formatting cluster the same way the current platform does.
Future<void> revealFormatting(WidgetTester tester) async {
  final toggle = find.byKey(const ValueKey('formatting-toggle'));
  if (AppPlatform.hasPointer) {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(toggle));
  } else {
    await tester.tap(toggle);
  }
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() {
    engine = CalcEngine(ratesPerUsd: _rates);
    shortcutPrefs = ShortcutPrefs(_MemoryStore())..load();
  });

  testWidgets('ticking a box celebrates, unticking it does not', (
    tester,
  ) async {
    await tester.pumpWidget(harness('☐ milk\n☐ bread', autofocus: true));
    await tester.pumpAndSettle();
    final topLeft = tester.getTopLeft(find.byType(EditableText));

    // First box: a burst, and no finale — there is still one left.
    await tester.tapAt(topLeft + const Offset(6, 14));
    await tester.pump();
    expect(find.byKey(Celebrate.burstKey), findsOneWidget);
    expect(find.byKey(Celebrate.finaleKey), findsNothing);
    await tester.pumpAndSettle();
    expect(find.byKey(Celebrate.burstKey), findsNothing);

    // Unticking is a correction, and a correction that throws confetti is
    // mocking you.
    await tester.tapAt(topLeft + const Offset(6, 14));
    await tester.pump();
    expect(find.byKey(Celebrate.burstKey), findsNothing);
    await tester.pumpAndSettle();
  });

  testWidgets('finishing a checklist keeps its confetti but not Kapy', (
    tester,
  ) async {
    await tester.pumpWidget(harness('☑ milk\n☐ bread', autofocus: true));
    await tester.pumpAndSettle();
    final topLeft = tester.getTopLeft(find.byType(EditableText));

    await tester.tapAt(topLeft + const Offset(6, 43));
    await tester.pump();
    expect(find.byKey(Celebrate.burstKey), findsOneWidget);
    expect(
      find.byKey(Celebrate.finaleKey),
      findsOneWidget,
      reason: 'that emptied the list',
    );
    expect(find.byKey(KapyCursorPeek.mascotKey), findsNothing);
    await tester.pumpAndSettle();
  });

  testWidgets('a single box on its own is not a finished list', (tester) async {
    await tester.pumpWidget(harness('☐ milk', autofocus: true));
    await tester.pumpAndSettle();
    final topLeft = tester.getTopLeft(find.byType(EditableText));

    await tester.tapAt(topLeft + const Offset(6, 14));
    await tester.pump();
    expect(find.byKey(Celebrate.burstKey), findsOneWidget);
    expect(find.byKey(Celebrate.finaleKey), findsNothing);
    await tester.pumpAndSettle();
  });

  testWidgets('view-only notes remain selectable without mutation controls', (
    tester,
  ) async {
    var changed = false;
    const body = '☐ read this\n12 km to miles';
    await tester.pumpWidget(
      harness(
        body,
        readOnly: true,
        autofocus: true,
        onBodyChanged: (_) => changed = true,
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
    expect(
      find.byKey(const ValueKey('note-formatting-controls')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('view-only-status')), findsOneWidget);

    final topLeft = tester.getTopLeft(find.byType(EditableText));
    await tester.tapAt(topLeft + const Offset(6, 14));
    await tester.pump();
    tester
        .state<NoteEditorState>(find.byType(NoteEditor))
        .insertPlainLines('must not appear');
    await tester.pump();

    expect(
      tester
          .state<EditableTextState>(find.byType(EditableText))
          .textEditingValue
          .text,
      body,
    );
    expect(changed, isFalse);
  });

  testWidgets('Kapy peeks once after five seconds without typing', (
    tester,
  ) async {
    await tester.pumpWidget(harness('A quiet note', autofocus: true));
    await tester.pumpAndSettle();

    await tester.pump(const Duration(seconds: 4));
    expect(find.byKey(KapyCursorPeek.overlayKey), findsNothing);

    await tester.enterText(find.byType(TextField), 'A quiet note with an edit');
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(find.byKey(KapyCursorPeek.overlayKey), findsNothing);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.byKey(KapyCursorPeek.overlayKey), findsOneWidget);
    expect(find.byKey(KapyCursorPeek.mascotKey), findsOneWidget);
    expect(find.byKey(Celebrate.burstKey), findsNothing);

    await tester.pump(
      KapyCursorPeek.defaultDuration + const Duration(milliseconds: 1),
    );
    await tester.pump();
    expect(find.byKey(KapyCursorPeek.overlayKey), findsNothing);

    // The wait is one-shot. Remaining idle does not make Kapy repeat forever.
    await tester.pump(NoteEditor.kapyPeekIdleDelay * 2);
    await tester.pump();
    expect(find.byKey(KapyCursorPeek.overlayKey), findsNothing);
  });

  testWidgets('moving the caret restarts the five-second peek wait', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness('first line\nsecond line', autofocus: true),
    );
    await tester.pumpAndSettle();
    final topLeft = tester.getTopLeft(find.byType(EditableText));

    await tester.pump(const Duration(seconds: 4));
    await tester.tapAt(topLeft + const Offset(40, 43));
    await tester.pump();

    await tester.pump(const Duration(seconds: 4));
    expect(find.byKey(KapyCursorPeek.overlayKey), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.byKey(KapyCursorPeek.overlayKey), findsOneWidget);
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

  group('clicking the blank page below a note', () {
    /// The middle of ruled row [row], counting the first line of the note as
    /// row 0 — the point a reader aims at when they click an empty line.
    Offset rowCenter(WidgetTester tester, int row) {
      final editable = tester
          .state<EditableTextState>(find.byType(EditableText))
          .renderEditable;
      final origin = editable.localToGlobal(Offset.zero);
      return Offset(
        origin.dx + 40,
        origin.dy + (row + 0.5) * editable.preferredLineHeight,
      );
    }

    /// Which ruled row the caret is drawn on.
    int caretRow(WidgetTester tester) {
      final state = tester.state<EditableTextState>(find.byType(EditableText));
      final editable = state.renderEditable;
      final rect = editable.getLocalRectForCaret(
        TextPosition(offset: state.textEditingValue.selection.baseOffset),
      );
      return (rect.center.dy / editable.preferredLineHeight).floor();
    }

    Future<void> pumpEditor(
      WidgetTester tester,
      String body, {
      bool readOnly = false,
      ValueChanged<String>? onBodyChanged,
    }) async {
      tester.view.physicalSize = const Size(900, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        harness(body, readOnly: readOnly, onBodyChanged: onBodyChanged),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the caret lands on the line that was clicked', (tester) async {
      const body = 'one\ntwo\nthree';
      var saved = body;
      await pumpEditor(tester, body, onBodyChanged: (text) => saved = text);

      await tester.tapAt(rowCenter(tester, 8));
      await tester.pumpAndSettle();

      // Not the end of "three", which is where the field would have put it.
      expect(caretRow(tester), 8);
      expect(saved, 'one\ntwo\nthree\n\n\n\n\n\n');
      expect(
        tester
            .state<EditableTextState>(find.byType(EditableText))
            .widget
            .focusNode
            .hasFocus,
        isTrue,
      );
    });

    testWidgets('an empty note can be started part way down the page', (
      tester,
    ) async {
      var saved = '';
      await pumpEditor(tester, '', onBodyChanged: (text) => saved = text);

      await tester.tapAt(rowCenter(tester, 3));
      await tester.pumpAndSettle();

      expect(caretRow(tester), 3);
      expect(saved, '\n\n\n');
    });

    testWidgets('clicking the same line again writes nothing more', (
      tester,
    ) async {
      const body = 'one';
      var saved = body;
      await pumpEditor(tester, body, onBodyChanged: (text) => saved = text);

      await tester.tapAt(rowCenter(tester, 5));
      await tester.pumpAndSettle();
      expect(saved, 'one\n\n\n\n\n');

      await tester.tapAt(rowCenter(tester, 5));
      await tester.pumpAndSettle();
      expect(saved, 'one\n\n\n\n\n');
      expect(caretRow(tester), 5);
    });

    testWidgets('a click on a line the note reaches leaves it alone', (
      tester,
    ) async {
      const body = 'one\ntwo\nthree';
      var saved = body;
      await pumpEditor(tester, body, onBodyChanged: (text) => saved = text);

      // Past the end of the second line, which is still that line.
      await tester.tapAt(rowCenter(tester, 1));
      await tester.pumpAndSettle();

      expect(saved, body);
      expect(caretRow(tester), 1);
    });

    testWidgets('a view-only note gains no lines', (tester) async {
      const body = 'one\ntwo';
      var saved = body;
      await pumpEditor(
        tester,
        body,
        readOnly: true,
        onBodyChanged: (text) => saved = text,
      );

      await tester.tapAt(rowCenter(tester, 7));
      await tester.pumpAndSettle();

      expect(saved, body);
    });
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

  // Flutter pads every selected line that carries a line break out to the
  // width of the longest line in the note unless told otherwise, so selecting
  // two short lines under a long one washed a block of empty space in the
  // selection colour.
  testWidgets('a selected line is highlighted no wider than its own text', (
    tester,
  ) async {
    const body =
        'a much longer line further down the note\n'
        '12 mangoes\n'
        'potatoes 13';
    await tester.pumpWidget(harness(body, autofocus: true));
    await tester.pumpAndSettle();

    final start = startOfLine(body, 1);
    final selection = TextSelection(
      baseOffset: start,
      extentOffset: body.length,
    );
    final state = tester.state<EditableTextState>(find.byType(EditableText));
    state.userUpdateTextEditingValue(
      state.textEditingValue.copyWith(selection: selection),
      SelectionChangedCause.drag,
    );
    await tester.pumpAndSettle();

    final editable = state.renderEditable;
    final highlight = editable.getBoxesForSelection(selection);
    expect(highlight, hasLength(2), reason: 'one highlight per selected line');
    // The first line is the one that used to be padded: its line break falls
    // inside the selection, and the line above it is far longer.
    for (final index in [1, 2]) {
      final text = editable
          .getBoxesForSelection(
            TextSelection(
              baseOffset: startOfLine(body, index),
              extentOffset:
                  startOfLine(body, index) + body.split('\n')[index].length,
            ),
          )
          .single;
      expect(
        highlight[index - 1].right,
        moreOrLessEquals(text.right, epsilon: 0.5),
        reason: 'line $index is highlighted past its own text',
      );
    }
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

  testWidgets(
    'native spelling stays subtle without replacing calculator styling',
    (tester) async {
      const channel = MethodChannel('kapynotes/spell_check');
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() {
        AppPlatform.debugTargetPlatformOverride = null;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
      });
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        expect(call.method, 'check');
        return [
          {
            'startIndex': 0,
            'endIndex': 5,
            'suggestions': ['sample', 'simple'],
          },
        ];
      });

      await tester.pumpWidget(harness('smple + 2', autofocus: true));
      await tester.pump(const Duration(milliseconds: 181));
      await tester.pump();

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.spellCheckConfiguration?.spellCheckEnabled, isFalse);
      final rendered =
          tester
                  .state<EditableTextState>(find.byType(EditableText))
                  .renderEditable
                  .text!
              as TextSpan;
      final textSpans = rendered.children!.whereType<TextSpan>();
      final misspelling = textSpans.firstWhere((span) => span.text == 'smple');
      final number = textSpans.firstWhere((span) => span.text == '2');
      expect(
        misspelling.style!.decoration!.contains(TextDecoration.underline),
        isTrue,
      );
      expect(
        misspelling.style!.decorationStyle,
        defaultTargetPlatform == TargetPlatform.iOS ||
                defaultTargetPlatform == TargetPlatform.macOS
            ? TextDecorationStyle.dotted
            : TextDecorationStyle.wavy,
      );
      expect(
        misspelling.style!.decorationColor,
        Theme.of(tester.element(find.byType(TextField))).colorScheme.error,
      );
      expect(number.style!.color, KapyTheme.darkPalette.number);
    },
  );

  testWidgets('offers native corrections in the adaptive edit menu', (
    tester,
  ) async {
    const channel = MethodChannel('kapynotes/spell_check');
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() {
      AppPlatform.debugTargetPlatformOverride = null;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    });
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'check'
          ? [
              {'startIndex': 0, 'endIndex': 5},
            ]
          : ['sample', 'simple'],
    );

    await tester.pumpWidget(harness('smple note', autofocus: true));
    await tester.pump(const Duration(milliseconds: 181));
    await tester.pump();
    final field = tester.widget<TextField>(find.byType(TextField));
    field.controller!.selection = const TextSelection.collapsed(offset: 2);
    await tester.pump();

    // No pointer went near the word, so nothing asked the system for its
    // corrections ahead of time: the menu opens and then fills itself in.
    final editable = tester.state<EditableTextState>(find.byType(EditableText));
    expect(editable.showToolbar(), isTrue);
    await tester.pump();
    expect(find.text('sample'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('sample'), findsOneWidget);
    expect(find.text('simple'), findsOneWidget);

    await tester.tap(find.text('sample'));
    await tester.pump();
    expect(field.controller!.text, 'sample note');
    expect(
      field.controller!.selection,
      const TextSelection.collapsed(offset: 6),
    );
  });

  testWidgets('right-clicking a misspelling offers corrections', (
    tester,
  ) async {
    const channel = MethodChannel('kapynotes/spell_check');
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() {
      AppPlatform.debugTargetPlatformOverride = null;
      debugDefaultTargetPlatformOverride = null;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    });
    // What the macOS runner answers: finding the word is one call, guessing
    // what it should have been is another, and only the second is expensive.
    final asked = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      asked.add(call.method);
      return call.method == 'check'
          ? [
              {'startIndex': 0, 'endIndex': 5},
            ]
          : ['sample', 'simple'];
    });

    await tester.pumpWidget(harness('smple note', autofocus: true));
    await tester.pump(const Duration(milliseconds: 181));
    await tester.pump();
    expect(asked, [
      'check',
    ], reason: 'typing must not pay for corrections nobody has asked to see');

    // macOS selects the word a right-click lands on, so the corrections have
    // to come with the selection toolbar and not only with the caret menu.
    await tester.tapAt(
      _centerOf(tester, 'smple note', 'smple'),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(
      field.controller!.selection,
      const TextSelection(baseOffset: 0, extentOffset: 5),
    );
    expect(
      find.byKey(const ValueKey('selection-formatting-toolbar')),
      findsOneWidget,
    );
    expect(find.text('sample'), findsOneWidget);
    expect(find.text('simple'), findsOneWidget);
    // Formatting stays where it was: the word is still selected text.
    expect(find.byKey(const ValueKey('selection-bold')), findsOneWidget);

    await tester.tap(find.text('simple'));
    await tester.pumpAndSettle();
    expect(field.controller!.text, 'simple note');
    expect(asked, contains('suggest'));
    // Before the harness checks it, rather than in the tear-down that runs
    // after: a leaked platform override fails the test on its way out.
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a right-click answers for the word under the pointer', (
    tester,
  ) async {
    const channel = MethodChannel('kapynotes/spell_check');
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.windows;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() {
      AppPlatform.debugTargetPlatformOverride = null;
      debugDefaultTargetPlatformOverride = null;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    });
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => [
        {
          'startIndex': 0,
          'endIndex': 5,
          'suggestions': ['sample'],
        },
      ],
    );

    await tester.pumpWidget(harness('smple note', autofocus: true));
    await tester.pump(const Duration(milliseconds: 181));
    await tester.pump();
    // Windows leaves the caret where it was when the menu opens; here that is
    // the end of the note, a word away from the underline.
    final field = tester.widget<TextField>(find.byType(TextField));
    field.controller!.selection = const TextSelection.collapsed(offset: 10);
    await tester.pump();

    await tester.tapAt(
      _centerOf(tester, 'smple note', 'smple'),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    expect(find.text('sample'), findsOneWidget);

    await tester.tap(find.text('sample'));
    await tester.pumpAndSettle();
    expect(field.controller!.text, 'sample note');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('starts the controls at the left and pins the total right', (
    tester,
  ) async {
    await tester.pumpWidget(harness('2 + 2'));
    await tester.pumpAndSettle();

    final footer = tester.getRect(find.byType(NoteFooter));
    final formatting = tester.getRect(
      find.byKey(const ValueKey('note-formatting-controls')),
    );
    final total = tester.getRect(find.byKey(const ValueKey('note-total')));

    // Left-anchored, in reading order, rather than floating in the middle.
    expect(formatting.left, closeTo(footer.left + 12, 1));
    expect(
      formatting.center.dx,
      lessThan(footer.center.dx),
      reason: 'the controls belong at the edge the eye starts from',
    );
    expect(total.right, closeTo(footer.right - 12, 1));
  });

  testWidgets('the controls do not move when the nesting buttons appear', (
    tester,
  ) async {
    await tester.pumpWidget(harness('2 + 2'));
    await tester.pumpAndSettle();
    await revealFormatting(tester);

    double boldLeft() =>
        tester.getRect(find.byKey(const ValueKey('format-bold'))).left;

    final before = boldLeft();
    expect(find.byKey(const ValueKey('format-indent')), findsNothing);

    // Putting the caret on a list line grows the row from five buttons to
    // seven. Centred, that used to slide everything already there sideways by
    // a full button — so the control someone had just pressed left from under
    // the finger that pressed it.
    await tester.tap(find.byKey(const ValueKey('format-bullets')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('format-indent')), findsOneWidget);
    expect(
      boldLeft(),
      closeTo(before, 0.01),
      reason: 'a row that grows rightward leaves what is already in it alone',
    );
  });

  testWidgets('spaces consistently sized footer controls on desktop', (
    tester,
  ) async {
    await tester.pumpWidget(harness('2 + 2'));
    await tester.pumpAndSettle();
    await revealFormatting(tester);

    final controls = <Finder>[
      for (final key in const [
        ValueKey('format-style'),
        ValueKey('format-checklist'),
        ValueKey('format-bullets'),
        ValueKey('format-bold'),
        ValueKey('format-italic'),
      ])
        find.descendant(of: find.byKey(key), matching: find.byType(IconButton)),
    ];
    expect(
      controls.map(tester.getSize),
      everyElement(const Size.square(32)),
      reason: 'Every footer action should have the same readable hover target',
    );
    for (var index = 1; index < controls.length; index++) {
      final previous = tester.getRect(controls[index - 1]);
      final current = tester.getRect(controls[index]);
      expect(current.left - previous.right, closeTo(4, 0.01));
    }
    expect(tester.getSize(find.byType(NoteFooter)).height, 48);
  });

  testWidgets('puts the line tools before the ones that mark a word', (
    tester,
  ) async {
    await tester.pumpWidget(harness('2 + 2'));
    await tester.pumpAndSettle();
    await revealFormatting(tester);

    double leftOf(String key) => tester.getRect(find.byKey(ValueKey(key))).left;

    // Style, checklist, bulleted list, bold, italic: what changes the whole
    // line first, what changes a word after it.
    expect(leftOf('format-checklist'), greaterThan(leftOf('format-style')));
    expect(leftOf('format-bullets'), greaterThan(leftOf('format-checklist')));
    expect(leftOf('format-bold'), greaterThan(leftOf('format-bullets')));
    expect(leftOf('format-italic'), greaterThan(leftOf('format-bold')));
  });

  testWidgets('leaves settings to the notes list', (tester) async {
    await tester.pumpWidget(harness('2 + 2'));
    await tester.pumpAndSettle();
    await revealFormatting(tester);

    // The bar belongs to the note: what it holds either writes in it or
    // reports on it. Settings is a row in the notes list on every layout.
    expect(find.byKey(const ValueKey('note-settings')), findsNothing);
    expect(find.byTooltip('Settings'), findsNothing);
  });

  testWidgets('keeps the footer controls separated on a narrow phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(harness('2 + 2'));
    await tester.pumpAndSettle();

    final footer = tester.getRect(find.byType(NoteFooter));
    final formatting = tester.getRect(
      find.byKey(const ValueKey('note-formatting-controls')),
    );
    final total = tester.getRect(find.byKey(const ValueKey('note-total')));
    expect(footer.left, lessThanOrEqualTo(formatting.left));
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
    await revealFormatting(tester);

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

  testWidgets('styles pasted URLs as links without changing their text', (
    tester,
  ) async {
    const body = 'Read https://example.com/docs?q=notes.';
    const linkText = 'https://example.com/docs?q=notes';
    final linkStart = body.indexOf(linkText);
    final linkEnd = linkStart + linkText.length;

    await tester.pumpWidget(harness(body));
    await tester.pumpAndSettle();

    final rendered =
        tester
                .state<EditableTextState>(find.byType(EditableText))
                .renderEditable
                .text!
            as TextSpan;
    var offset = 0;
    var sawLinkRun = false;
    var sawTrailingPeriod = false;
    for (final span in rendered.children!.whereType<TextSpan>()) {
      final text = span.text ?? '';
      final end = offset + text.length;
      if (offset >= linkStart && end <= linkEnd && text.isNotEmpty) {
        sawLinkRun = true;
        expect(
          span.style!.color,
          Theme.of(tester.element(find.byType(TextField))).colorScheme.primary,
        );
        expect(
          span.style?.decoration?.contains(TextDecoration.underline) ?? false,
          isFalse,
        );
        expect(span.style?.fontWeight ?? FontWeight.w400, FontWeight.w400);
      }
      if (offset == linkEnd && text == '.') {
        sawTrailingPeriod = true;
        expect(
          span.style?.decoration?.contains(TextDecoration.underline) ?? false,
          isFalse,
        );
        expect(span.style?.fontStyle, isNot(FontStyle.italic));
      }
      offset = end;
    }

    expect(sawLinkRun, isTrue);
    expect(sawTrailingPeriod, isTrue);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      body,
    );
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
    await revealFormatting(tester);

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
    await revealFormatting(tester);

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

  testWidgets('offers one-tap open and full-link copy for selected URLs', (
    tester,
  ) async {
    const body = 'Read www.example.com/docs today';
    const linkText = 'www.example.com/docs';
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

    await tester.pumpWidget(harness(body, autofocus: true));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    field.controller!.selection = TextSelection(
      baseOffset: body.indexOf('example'),
      extentOffset: body.indexOf('.com'),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('selection-open-link')), findsOneWidget);
    expect(find.byKey(const ValueKey('selection-copy-link')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('selection-copy-link')));
    await tester.pumpAndSettle();

    expect(copied, [linkText]);
    await tester.pump(const Duration(seconds: 2));
  });

  group('scrolling from the results gutter', () {
    /// A note long enough that the field has somewhere to scroll to.
    String longBody() =>
        [for (var i = 1; i <= 80; i++) 'line $i = $i * 2'].join('\n');

    ScrollController fieldScroll(WidgetTester tester) =>
        tester.widget<TextField>(find.byType(TextField)).scrollController!;

    testWidgets('a drag over the gutter scrolls the note', (tester) async {
      // The gutter is a sibling of the field, not part of it, so a drag here
      // used to land on nothing at all — a third of a phone's width where
      // scrolling silently did nothing.
      tester.view.physicalSize = const Size(390, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(harness(longBody(), gutterWidth: 140));
      await tester.pumpAndSettle();

      final scroll = fieldScroll(tester);
      expect(scroll.offset, 0);

      final gutter = tester.getCenter(find.byType(ResultsGutter));
      await tester.dragFrom(gutter, const Offset(0, -160));
      await tester.pumpAndSettle();

      expect(
        scroll.offset,
        greaterThan(0),
        reason: 'dragging up on the right moves the note up, as on the left',
      );

      // And back down again, to the top rather than past it.
      await tester.dragFrom(gutter, const Offset(0, 400));
      await tester.pumpAndSettle();
      expect(scroll.offset, 0);
    });

    testWidgets('a fling keeps going after the finger leaves', (tester) async {
      // Handing the drag to the scroll position rather than nudging offset is
      // what buys this; it is also what makes overscroll behave.
      tester.view.physicalSize = const Size(390, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(harness(longBody(), gutterWidth: 140));
      await tester.pumpAndSettle();

      final scroll = fieldScroll(tester);
      await tester.fling(
        find.byType(ResultsGutter),
        const Offset(0, -200),
        800,
      );
      await tester.pump();
      final duringFling = scroll.offset;
      await tester.pumpAndSettle();

      expect(
        scroll.offset,
        greaterThan(duringFling),
        reason: 'momentum carries it past where the finger let go',
      );
    });

    testWidgets('tapping a chip still copies rather than scrolling', (
      tester,
    ) async {
      // The passthrough claims vertical drags, not taps: children hit-test
      // first, so a chip is still a chip.
      await tester.pumpWidget(harness('rev = 4 * 3'));
      await tester.pumpAndSettle();

      final copied = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );

      await tester.tap(find.byType(ResultChip).first);
      await tester.pumpAndSettle();

      expect(copied, ['12']);

      // The chip shows a tick for 900ms and the toast has a life of its own;
      // both are timers the test has to outlive.
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
    });
  });

  testWidgets('a tapped link offers to open rather than opening itself', (
    tester,
  ) async {
    const body = 'Open www.example.com/path';
    const linkText = 'www.example.com/path';
    final launched = <String>[];
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      final url = (call.arguments as Map?)?['url'];
      if (url is String) launched.add(url);
      return true;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );

    await tester.pumpWidget(harness(body));
    await tester.pumpAndSettle();
    final editable = tester
        .state<EditableTextState>(find.byType(EditableText))
        .renderEditable;
    final start = body.indexOf(linkText);
    final box = editable
        .getBoxesForSelection(
          TextSelection(
            baseOffset: start,
            extentOffset: start + linkText.length,
          ),
        )
        .first;
    final tapPosition = editable.localToGlobal(
      Offset((box.left + box.right) / 2, (box.top + box.bottom) / 2),
    );

    await tester.tapAt(tapPosition);
    await tester.pumpAndSettle();

    // The tap put the caret in the URL and said what could be done with it;
    // it did not leave the app.
    expect(find.byKey(const ValueKey('link-popover')), findsOneWidget);
    expect(find.text(linkText), findsOneWidget);
    expect(launched, isEmpty);
    // Flat, like every panel that floats here: the shared FloatingSurface
    // separates with a hairline rather than a shadow.
    final panel = tester.widget<Container>(
      find
          .descendant(
            of: find.byKey(const ValueKey('link-popover')),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(
      (panel.decoration! as BoxDecoration).boxShadow,
      anyOf(isNull, isEmpty),
    );
    // And its text starts from a complete style rather than merging with the
    // fallback an overlay entry would otherwise inherit — red, and underlined
    // twice in yellow.
    expect(
      DefaultTextStyle.of(
        tester.element(find.text('Open link')),
      ).style.decoration,
      TextDecoration.none,
    );
    expect(
      tester.widget<Text>(find.text('Open link')).style!.fontWeight,
      FontWeight.w400,
    );

    await tester.tap(find.byKey(const ValueKey('link-popover-open')));
    await tester.pumpAndSettle();

    expect(launched, ['https://www.example.com/path']);
    expect(find.byKey(const ValueKey('link-popover')), findsNothing);
  });

  testWidgets(
    'calculator keywords explain themselves without changing the text',
    (tester) async {
      const body = '12 km to miles\n20 over 4';
      await tester.pumpWidget(harness(body, autofocus: true));
      await tester.pumpAndSettle();

      await tester.tapAt(_centerOf(tester, body, 'to'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('calc-keyword-tooltip')),
        findsOneWidget,
      );
      expect(
        find.text('Converts the value to another unit or currency.'),
        findsOneWidget,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        body,
      );

      await tester.tapAt(_centerOf(tester, body, 'over'));
      await tester.pumpAndSettle();

      expect(
        find.text('Divides the value on the left by the value on the right.'),
        findsOneWidget,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        body,
      );

      final controller = tester
          .widget<TextField>(find.byType(TextField))
          .controller!;
      final keywordSelection = controller.selection;
      await tester.tapAt(_centerOf(tester, body, '12'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('calc-keyword-tooltip')), findsNothing);
      expect(controller.selection, isNot(keywordSelection));
      expect(controller.text, body);
    },
  );

  testWidgets('the panel copies the link exactly as it is written', (
    tester,
  ) async {
    const body = 'Read www.example.com/docs today';
    const linkText = 'www.example.com/docs';
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

    await tester.pumpWidget(harness(body));
    await tester.pumpAndSettle();
    await tester.tapAt(_centerOf(tester, body, linkText));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('link-popover-copy')));
    await tester.pumpAndSettle();

    // The source text, not the normalized https:// form the browser gets.
    expect(copied, [linkText]);
    expect(find.byKey(const ValueKey('link-popover')), findsNothing);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets(
    'a click elsewhere dismisses the panel and still moves the caret',
    (tester) async {
      const body = 'Open www.example.com/path and then keep writing here';
      await tester.pumpWidget(harness(body, autofocus: true));
      await tester.pumpAndSettle();
      await tester.tapAt(_centerOf(tester, body, 'www.example.com/path'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('link-popover')), findsOneWidget);

      // The panel does not swallow the press that dismisses it, so putting the
      // caret somewhere else still takes the one click it always took.
      await tester.tapAt(_centerOf(tester, body, 'writing'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('link-popover')), findsNothing);
      final field = tester.widget<TextField>(find.byType(TextField));
      final caret = field.controller!.selection.baseOffset;
      expect(caret, greaterThanOrEqualTo(body.indexOf('writing')));
      expect(
        caret,
        lessThanOrEqualTo(body.indexOf('writing') + 'writing'.length),
      );
    },
  );

  testWidgets('keeps the link panel inside a narrow phone', (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const body = 'www.example.com/a/rather/long/path/that/will/not/fit';
    await tester.pumpWidget(harness(body, autofocus: true));
    await tester.pumpAndSettle();

    await tester.tapAt(_centerOf(tester, body, body));
    await tester.pumpAndSettle();

    final panel = tester.getRect(find.byKey(const ValueKey('link-popover')));
    expect(panel.left, greaterThanOrEqualTo(0));
    expect(panel.right, lessThanOrEqualTo(320));
    expect(panel.top, greaterThanOrEqualTo(0));
    expect(panel.bottom, lessThanOrEqualTo(640));
    expect(
      find.byKey(const ValueKey('link-popover-open')),
      findsOneWidget,
      reason: 'the address gives way before the actions do',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('right-click copies the whole note as plain text', (
    tester,
  ) async {
    const body =
        '${bulletPrefix}milk\n$listIndentUnit${uncheckedPrefix}oat\n'
        '${checkedPrefix}bread\n\n120 * 3';
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

    await tester.pumpWidget(harness(body, autofocus: true));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    field.controller!.selection = const TextSelection.collapsed(offset: 3);
    await tester.pumpAndSettle();
    tester.state<EditableTextState>(find.byType(EditableText)).showToolbar();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Copy Plain Text'));
    await tester.pumpAndSettle();

    // Nothing selected, so the whole note comes across: glyphs turned to
    // ASCII, the nested indent and the blank line untouched.
    expect(copied, [
      '- milk\n$listIndentUnit- [ ] oat\n- [x] bread\n\n120 * 3',
    ]);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('plain-text copy takes only the selection when there is one', (
    tester,
  ) async {
    const body = '${uncheckedPrefix}first\n${uncheckedPrefix}second';
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

    await tester.pumpWidget(harness(body, autofocus: true));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    field.controller!.selection = TextSelection(
      baseOffset: 0,
      extentOffset: body.indexOf('\n'),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('selection-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy Plain Text'));
    await tester.pumpAndSettle();

    expect(copied, ['- [ ] first']);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('typing dismisses the link panel', (tester) async {
    const body = 'Open www.example.com/path';
    await tester.pumpWidget(harness(body, autofocus: true));
    await tester.pumpAndSettle();
    await tester.tapAt(_centerOf(tester, body, 'www.example.com/path'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('link-popover')), findsOneWidget);

    await tester.enterText(find.byType(TextField), '$body!');
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('link-popover')), findsNothing);
  });

  testWidgets('plain desktop clicks edit and Command-click opens links', (
    tester,
  ) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    const body = 'Open https://example.com/path';
    const linkText = 'https://example.com/path';
    final launched = <String>[];
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      final url = (call.arguments as Map?)?['url'];
      if (url is String) launched.add(url);
      return true;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );

    await tester.pumpWidget(harness(body));
    await tester.pumpAndSettle();
    final editable = tester
        .state<EditableTextState>(find.byType(EditableText))
        .renderEditable;
    final start = body.indexOf(linkText);
    final box = editable
        .getBoxesForSelection(
          TextSelection(
            baseOffset: start,
            extentOffset: start + linkText.length,
          ),
        )
        .first;
    final clickPosition = editable.localToGlobal(
      Offset((box.left + box.right) / 2, (box.top + box.bottom) / 2),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: clickPosition);

    await mouse.down(clickPosition);
    await mouse.up();
    await tester.pumpAndSettle();
    expect(launched, isEmpty);
    expect(
      find.byKey(const ValueKey('link-popover')),
      findsOneWidget,
      reason: 'a plain click edits, and offers the link rather than taking it',
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await mouse.down(clickPosition);
    await mouse.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    expect(launched, ['https://example.com/path']);
    expect(
      find.byKey(const ValueKey('link-popover')),
      findsNothing,
      reason: 'the shortcut skips the panel instead of stacking one up',
    );
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
    await revealFormatting(tester);

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

  testWidgets('keeps link actions inside a narrow phone', (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(harness('www.example.com', autofocus: true));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    field.controller!.selection = const TextSelection(
      baseOffset: 4,
      extentOffset: 11,
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    final toolbar = tester.getRect(
      find.byKey(const ValueKey('selection-formatting-toolbar')),
    );
    expect(toolbar.left, greaterThanOrEqualTo(0));
    expect(toolbar.right, lessThanOrEqualTo(320));
    expect(find.byKey(const ValueKey('selection-open-link')), findsOneWidget);
    expect(find.byKey(const ValueKey('selection-copy-link')), findsOneWidget);
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
    await revealFormatting(tester);

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
      shortcutPrefs.bindingFor(ShortcutAction.formatBold)!,
    );
    await sendShortcut(
      tester,
      shortcutPrefs.bindingFor(ShortcutAction.formatItalic)!,
    );
    await tester.pumpAndSettle();

    expect(changes.last, const [
      NoteFormatRange(start: 0, end: 8, format: NoteFormat.bold),
      NoteFormatRange(start: 0, end: 8, format: NoteFormat.italic),
    ]);
  });

  testWidgets('settings and voice actions answer their footer shortcuts', (
    tester,
  ) async {
    var settingsOpens = 0;
    var voiceToggles = 0;
    await tester.pumpWidget(
      harness(
        'Shortcut',
        autofocus: true,
        onSettingsPressed: () => settingsOpens++,
        onRecordVoice: () => voiceToggles++,
      ),
    );
    await tester.pumpAndSettle();

    await sendShortcut(
      tester,
      shortcutPrefs.bindingFor(ShortcutAction.openSettings)!,
    );
    await sendShortcut(
      tester,
      shortcutPrefs.bindingFor(ShortcutAction.recordVoiceNote)!,
    );
    await tester.pump();

    expect(settingsOpens, 1);
    expect(voiceToggles, 1);
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
      shortcutPrefs.bindingFor(ShortcutAction.cycleTextStyle)!,
    );
    await tester.pumpAndSettle();
    expect(changes.last, const [
      NoteFormatRange(start: 0, end: 4, format: NoteFormat.heading),
    ]);
    await sendShortcut(
      tester,
      shortcutPrefs.bindingFor(ShortcutAction.cycleTextStyle)!,
    );
    await tester.pumpAndSettle();
    expect(changes.last, const [
      NoteFormatRange(start: 0, end: 4, format: NoteFormat.subtitle),
    ]);
    await sendShortcut(
      tester,
      shortcutPrefs.bindingFor(ShortcutAction.cycleTextStyle)!,
    );
    await tester.pumpAndSettle();
    expect(changes.last, isEmpty);

    await sendShortcut(
      tester,
      shortcutPrefs.bindingFor(ShortcutAction.formatBullets)!,
    );
    await tester.pumpAndSettle();
    expect(field.controller!.text, '${bulletPrefix}Task');

    await sendShortcut(
      tester,
      shortcutPrefs.bindingFor(ShortcutAction.formatChecklist)!,
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
        'Text style: Text · ${shortcutPrefs.bindingFor(ShortcutAction.cycleTextStyle)!.displayLabel}',
      ),
      findsOneWidget,
    );
    expect(
      find.byTooltip(
        'Bold · ${shortcutPrefs.bindingFor(ShortcutAction.formatBold)!.displayLabel}',
      ),
      findsOneWidget,
    );
    expect(
      find.byTooltip(
        'Italic · ${shortcutPrefs.bindingFor(ShortcutAction.formatItalic)!.displayLabel}',
      ),
      findsOneWidget,
    );
    final original = shortcutPrefs.bindingFor(ShortcutAction.formatBullets)!;
    expect(
      find.byTooltip('Bulleted list · ${original.displayLabel}'),
      findsOneWidget,
    );
    expect(
      find.byTooltip(
        'Checklist · ${shortcutPrefs.bindingFor(ShortcutAction.formatChecklist)!.displayLabel}',
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
    await revealFormatting(tester);

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
    await tester.pumpWidget(harness('• one\n    ▪ '));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    field.controller!.selection = const TextSelection.collapsed(offset: 12);
    await tester.pump();

    // Stepping out a level takes that level's bullet with it.
    await tester.enterText(find.byType(TextField), '• one\n    ▪ \n');
    await tester.pumpAndSettle();
    expect(field.controller!.text, '• one\n  ◦ ');

    await tester.enterText(find.byType(TextField), '• one\n  ◦ \n');
    await tester.pumpAndSettle();
    expect(field.controller!.text, '• one\n• ');

    // Back at the margin, the next Enter leaves the list, as it always did.
    await tester.enterText(find.byType(TextField), '• one\n• \n');
    await tester.pumpAndSettle();
    expect(field.controller!.text, '• one\n');
  });

  testWidgets('typing "- " at the start of a line makes a bullet', (
    tester,
  ) async {
    await tester.pumpWidget(harness(''));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));

    await tester.enterText(find.byType(TextField), '-');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '- ');
    await tester.pumpAndSettle();

    // The typed space is spent on the marker rather than added after it.
    expect(field.controller!.text, '• ');
    expect(field.controller!.selection.baseOffset, 2);
  });

  testWidgets('typing "[] " and "[ ] " both make a checkbox', (tester) async {
    for (final shorthand in ['[]', '[ ]']) {
      await tester.pumpWidget(harness(''));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(find.byType(TextField));

      await tester.enterText(find.byType(TextField), shorthand);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '$shorthand ');
      await tester.pumpAndSettle();

      expect(field.controller!.text, '☐ ', reason: 'from "$shorthand "');
    }
  });

  testWidgets('shorthand inside a nested list takes that level\'s bullet', (
    tester,
  ) async {
    await tester.pumpWidget(harness('• one\n  '));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));

    await tester.enterText(find.byType(TextField), '• one\n  -');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '• one\n  - ');
    await tester.pumpAndSettle();

    expect(field.controller!.text, '• one\n  ◦ ');
  });

  testWidgets('a minus that is not shorthand is left as arithmetic', (
    tester,
  ) async {
    await tester.pumpWidget(harness(''));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));

    // No space after the minus, so this stays the negative number the engine
    // evaluates rather than becoming a bullet.
    await tester.enterText(find.byType(TextField), '-5');
    await tester.pumpAndSettle();
    expect(field.controller!.text, '-5');

    // And mid-line the shorthand does not apply at all.
    await tester.enterText(find.byType(TextField), '12 -');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '12 - ');
    await tester.pumpAndSettle();
    expect(field.controller!.text, '12 - ');
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
    expect(field.controller!.text, '  ◦ one');

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

  testWidgets('mixed typeface gives headings a handwritten face', (
    tester,
  ) async {
    const body = 'Nightly cost\nnightly = 128 eur\nnightly * 7';
    const formats = [
      NoteFormatRange(start: 0, end: 12, format: NoteFormat.heading),
    ];
    await tester.pumpWidget(
      harness(body, initialFormats: formats, writingFont: WritingFont.mixed),
    );
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.style?.fontFamily, WritingFont.monospace.fontFamily);

    final rendered =
        tester
                .state<EditableTextState>(find.byType(EditableText))
                .renderEditable
                .text!
            as TextSpan;
    final heading = rendered.children!.whereType<TextSpan>().firstWhere(
      (span) => span.text == 'Nightly cost',
    );
    final bodyText = rendered.children!.whereType<TextSpan>().firstWhere(
      (span) => span.text == 'nightly',
    );

    expect(heading.style?.fontFamily, WritingFont.handwritten.fontFamily);
    expect(
      heading.style?.fontVariations,
      WritingFont.handwritten.fontVariations,
    );
    expect(heading.style?.fontSize, WritingFont.handwritten.editorSize * 1.28);
    expect(bodyText.style?.fontFamily, WritingFont.monospace.fontFamily);
    expect(
      tester.getRect(chipWithText('896.00 EUR')).center.dy,
      closeTo(lineRect(tester, body, 2).center.dy, 1.5),
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

  testWidgets('scrolling down a mobile note dismisses the keyboard to read', (
    tester,
  ) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    final body = List.generate(
      80,
      (index) => 'A line to read ${index + 1}',
    ).join('\n');
    await tester.pumpWidget(
      harness(body, autofocus: true, ensureKeyboardVisible: true),
    );
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.focusNode!.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
    final scrollBefore = field.scrollController!.offset;
    expect(scrollBefore, greaterThan(0));

    // The app opens at the end ready to type. Pulling the page down moves
    // towards the earlier writing while making the whole viewport available.
    await tester.drag(find.byType(TextField), const Offset(0, 140));
    await tester.pumpAndSettle();

    expect(field.focusNode!.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
    expect(field.scrollController!.offset, lessThan(scrollBefore));
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

  group('a keyboard dismissed out from under the editor', () {
    /// The editor as a phone mounts it: focused on open, and asking for a
    /// keyboard.
    Future<FocusNode> pumpFocused(WidgetTester tester) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        harness(
          'one\ntwo',
          startAtEnd: true,
          autofocus: true,
          ensureKeyboardVisible: true,
        ),
      );
      // Frames, not pumpAndSettle: settling runs the startup retry to its end,
      // and whether that run stops on its own is half of what is under test.
      await tester.pump();
      await tester.pump();
      return tester
          .state<EditableTextState>(find.byType(EditableText))
          .widget
          .focusNode;
    }

    Future<void> setKeyboard(WidgetTester tester, double height) async {
      tester.view.viewInsets = height > 0
          ? FakeViewPadding(bottom: height)
          : FakeViewPadding.zero;
      await tester.pump();
    }

    testWidgets('the editor lets go, so the keyboard stays down', (
      tester,
    ) async {
      final node = await pumpFocused(tester);
      await setKeyboard(tester, 300);
      expect(node.hasFocus, isTrue);

      // Android's Back is swallowed by the IME: the keyboard goes, and all the
      // app is told is that the window grew.
      tester.testTextInput.log.clear();
      await setKeyboard(tester, 0);
      await tester.pump(const Duration(seconds: 4));

      expect(node.hasFocus, isFalse);
      expect(
        tester.testTextInput.log.map((call) => call.method),
        isNot(contains('TextInput.show')),
      );
    });

    // The guard used to read MediaQuery, which a Scaffold hands its body with
    // the bottom inset already taken out — so it never saw the keyboard, and
    // every note opened went on asking for one for five seconds. Pressing Back
    // inside that window was answered by the next request.
    testWidgets('the startup request stops once the keyboard is up', (
      tester,
    ) async {
      await pumpFocused(tester);
      await setKeyboard(tester, 300);

      tester.testTextInput.log.clear();
      await tester.pump(const Duration(seconds: 6));

      expect(
        tester.testTextInput.log.map((call) => call.method),
        isNot(contains('TextInput.show')),
      );
    });

    testWidgets('a window that is only resized keeps the caret', (
      tester,
    ) async {
      // Every desktop metrics change looks like this: no keyboard before, no
      // keyboard after. Dropping the focus on one would empty the editor of
      // its caret every time the window was dragged wider.
      final node = await pumpFocused(tester);
      tester.view.physicalSize = const Size(500, 900);
      await tester.pump();

      expect(node.hasFocus, isTrue);
    });

    testWidgets('a keyboard that goes down with the app leaves focus alone', (
      tester,
    ) async {
      final node = await pumpFocused(tester);
      await setKeyboard(tester, 300);

      // Backgrounding takes the keyboard with it. The note is still open and
      // still the one being written in, so the caret belongs where it is.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await setKeyboard(tester, 0);

      expect(node.hasFocus, isTrue);
    });
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

  group('pointer affordances', () {
    /// Parks a mouse at [position] and reports the cursor the app asks for.
    Future<MouseCursor> cursorAt(WidgetTester tester, Offset position) async {
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        pointer: 1,
      );
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(position);
      await tester.pump();
      return RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1)!;
    }

    testWidgets('a checkbox asks for a hand', (tester) async {
      const body = '\u2610 milk\n\u2610 eggs';
      await tester.pumpWidget(harness(body));
      await tester.pumpAndSettle();

      expect(
        await cursorAt(tester, _centerOf(tester, body, '\u2610')),
        SystemMouseCursors.click,
      );
    });

    testWidgets('ordinary text still asks for an I-beam', (tester) async {
      const body = '\u2610 milk\n\u2610 eggs';
      await tester.pumpWidget(harness(body));
      await tester.pumpAndSettle();

      // The word beside the box, not the box: the editor is still a text
      // field everywhere a click would only place the caret.
      expect(
        await cursorAt(tester, _centerOf(tester, body, 'milk')),
        SystemMouseCursors.text,
      );
    });

    testWidgets('a link asks for a hand too', (tester) async {
      const body = 'Open www.example.com/path';
      await tester.pumpWidget(harness(body));
      await tester.pumpAndSettle();

      expect(
        await cursorAt(tester, _centerOf(tester, body, 'www.example.com/path')),
        SystemMouseCursors.click,
      );
    });

    testWidgets('and the I-beam returns on the way out', (tester) async {
      const body = '\u2610 milk and more text here';
      await tester.pumpWidget(harness(body));
      await tester.pumpAndSettle();

      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        pointer: 1,
      );
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pump();

      await gesture.moveTo(_centerOf(tester, body, '\u2610'));
      await tester.pump();
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.click,
      );

      await gesture.moveTo(_centerOf(tester, body, 'more text'));
      await tester.pump();
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.text,
        reason: 'the hand must not stick once the pointer leaves the box',
      );
    });
  });
}
