import 'dart:math' as math;
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kDoubleTapTimeout, kSecondaryButton;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/calc/contribution.dart';
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/calc/highlight.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/crdt/text_diff.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note_format.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/time_zones.dart';
import 'package:kapy_notes/ui/editor/editor_formatting.dart';
import 'package:kapy_notes/ui/editor/note_sliver.dart'
    show RenderNoteLine, lineTrailingGap;
import 'package:kapy_notes/ui/celebrate.dart';
import 'package:kapy_notes/ui/compact_icon_button.dart';
import 'package:kapy_notes/ui/editor/note_field.dart';
import 'package:kapy_notes/ui/kapy_cursor_peek.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/editor/results_gutter.dart';
import 'package:kapy_notes/ui/editor/editor_context_menu.dart';

import 'support/note_driver.dart';
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
  final editable = NoteDriver(tester);
  final start = body.indexOf(linkText);
  final box = editable
      .boxesFor(
        TextSelection(baseOffset: start, extentOffset: start + linkText.length),
      )
      .first;
  return editable.toGlobal(
    Offset((box.left + box.right) / 2, (box.top + box.bottom) / 2),
  );
}

Widget harness(
  String body, {
  List<NoteFormatRange> initialFormats = const [],
  bool keepResultRoom = false,
  bool resultsVisible = true,
  double? width,
  DateTime? lastUpdatedAt,
  DateTime? createdAt,
  bool dailySeparatorsEnabled = false,
  DateTime Function()? now,
  DateTime Function(DateTime)? displayTime,
  bool startAtEnd = false,
  bool autofocus = false,
  bool ensureKeyboardVisible = false,
  bool readOnly = false,
  TargetPlatform? platform,
  bool phone = false,
  ValueChanged<String>? onBodyChanged,
  ValueChanged<List<NoteFormatRange>>? onFormatsChanged,
  ValueChanged<TextEdit?>? onEdit,
  VoidCallback? onSettingsPressed,
  VoidCallback? onRecordVoice,
  WritingFont writingFont = WritingFont.handwritten,
  double editorTextScale = 1,
  ShortcutPrefs? shortcuts,
  bool markdown = false,
  Brightness brightness = Brightness.dark,
}) {
  final editor = NoteEditor(
    // Keyed by body so re-pumping with different text remounts the editor,
    // the way switching notes does in the app.
    key: ValueKey(body),
    noteId: 'test',
    initialBody: body,
    initialFormats: initialFormats,
    engine: engine,
    highlighter: Highlighter(engine.registry),
    keepResultRoom: keepResultRoom,
    phone: phone,
    resultsVisible: resultsVisible,
    lastUpdatedAt: lastUpdatedAt,
    createdAt: createdAt,
    dailySeparatorsEnabled: dailySeparatorsEnabled,
    now: now,
    displayTime: displayTime,
    startAtEnd: startAtEnd,
    autofocus: autofocus,
    ensureKeyboardVisible: ensureKeyboardVisible,
    readOnly: readOnly,
    onDocumentChanged: (body, formats, attachments, edit) {
      onBodyChanged?.call(body);
      onFormatsChanged?.call(formats);
      onEdit?.call(edit);
    },
    onSettingsPressed: onSettingsPressed ?? () {},
    onRecordVoice: onRecordVoice,
    writingFont: writingFont,
    editorTextScale: editorTextScale,
    shortcuts: shortcuts ?? shortcutPrefs,
    markdownEnabled: markdown,
  );
  return MaterialApp(
    theme:
        (brightness == Brightness.dark ? KapyTheme.dark() : KapyTheme.light())
            .copyWith(platform: platform),
    home: Scaffold(
      // A narrower editor where a test needs one, with the rest of the
      // window left empty beside it.
      body: width == null
          ? editor
          : Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                height: double.infinity,
                child: editor,
              ),
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
  final editable = NoteDriver(tester);
  // The field sets selectionHeightStyle to strut, so these are full line
  // boxes rather than tight glyph bounds.
  final boxes = editable.boxesFor(
    TextSelection(baseOffset: start, extentOffset: start + line.length),
  );
  expect(boxes, isNotEmpty, reason: 'line $index has no text box');
  final box = tester.renderObject<RenderBox>(noteField);
  final first = boxes.first;
  final origin = box.localToGlobal(Offset(first.left, first.top));
  return origin & Size(first.right - first.left, first.bottom - first.top);
}

/// The last row the text field draws line [index] on: the same row as
/// [lineRect] unless the line wraps.
Rect lastRowRect(WidgetTester tester, String body, int index) {
  final start = startOfLine(body, index);
  final line = body.split('\n')[index];
  final editable = NoteDriver(tester);
  final boxes = editable.boxesFor(
    TextSelection(baseOffset: start, extentOffset: start + line.length),
  );
  expect(boxes, isNotEmpty, reason: 'line $index has no text box');
  final last = boxes.last;
  final row = [
    for (final box in boxes)
      if ((box.top - last.top).abs() < 0.5) box.toRect(),
  ].reduce((a, b) => a.expandToInclude(b));
  final box = tester.renderObject<RenderBox>(noteField);
  return row.shift(box.localToGlobal(Offset.zero));
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

/// Puts the phone's keyboard up on the note, which is what raises the
/// formatting bar above it.
Future<void> revealFormatting(WidgetTester tester) async {
  tester.view.viewInsets = const FakeViewPadding(bottom: 300);
  addTearDown(tester.view.resetViewInsets);
  tester.widget<NoteField>(find.byType(NoteField)).focusNode.requestFocus();
  await tester.pumpAndSettle();
}

/// The footer's tools are a phone's: on a desktop the page has none, and
/// formatting comes from the bubble over a selection.
void _onPhone() {
  AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
  addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() {
    engine = CalcEngine(ratesPerUsd: _rates);
    shortcutPrefs = ShortcutPrefs(_MemoryStore())..load();
  });

  testWidgets('the writing surface never inherits form-field outlines', (
    tester,
  ) async {
    await tester.pumpWidget(harness('A note without a box', autofocus: true));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byType(NoteEditor),
        matching: find.byType(InputDecorator),
      ),
      findsNothing,
    );
  });

  testWidgets('works out what the note says to the semantics tree once', (
    tester,
  ) async {
    const body = 'Bread 4\nMilk 2\n\n# Shopping';
    await tester.pumpWidget(harness(body, autofocus: true));
    await tester.pumpAndSettle();

    // The field asks again whenever its semantics are marked dirty, which it
    // does for every widget it takes in, and each answer walks the note.
    final text = NoteDriver(tester).span;
    final semantics = text.getSemanticsInformation();
    expect(semantics.map((info) => info.text).join(), body);
    expect(text.getSemanticsInformation(), same(semantics));
  });

  testWidgets('ticking a box celebrates, unticking it does not', (
    tester,
  ) async {
    await tester.pumpWidget(harness('☐ milk\n☐ bread', autofocus: true));
    await tester.pumpAndSettle();
    final topLeft = tester.getTopLeft(noteField);

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
    const body = '☑ milk\n☐ bread';
    await tester.pumpWidget(harness(body, autofocus: true));
    await tester.pumpAndSettle();
    final topLeft = tester.getTopLeft(noteField);

    await tester.tapAt(
      Offset(topLeft.dx + 6, lineRect(tester, body, 1).center.dy),
    );
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
    final topLeft = tester.getTopLeft(noteField);

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

    expect(tester.widget<NoteField>(noteField).readOnly, isTrue);
    expect(
      find.byKey(const ValueKey('note-formatting-controls')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('view-only-status')), findsOneWidget);

    final topLeft = tester.getTopLeft(noteField);
    await tester.tapAt(topLeft + const Offset(6, 14));
    await tester.pump();
    tester
        .state<NoteEditorState>(find.byType(NoteEditor))
        .insertPlainLines('must not appear');
    await tester.pump();

    expect(
      tester.state<NoteFieldState>(noteField).widget.controller.value.text,
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

    await tester.enterNote('A quiet note with an edit');
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
    final topLeft = tester.getTopLeft(noteField);

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

    // The middle of the blank line's own row, which on the page sits under
    // the room for the title's meta row.
    final editable = NoteDriver(tester);
    final row = editable.caretRect(
      TextPosition(offset: body.indexOf('\n') + 1),
    );
    final blank = Offset(
      lineRect(tester, body, 0).center.dx,
      editable.toGlobal(row.center).dy,
    );

    await tester.tapAt(blank);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(blank);
    await tester.pumpAndSettle();

    final selection = tester
        .state<NoteFieldState>(noteField)
        .widget
        .controller
        .value
        .selection;
    expect(selection.isCollapsed, isTrue);
    expect(selection.baseOffset, body.indexOf('\n') + 1);
  });

  group('clicking the blank page below a note', () {
    /// A point on the empty page [rows] ruled rows under the note's last
    /// line, [x] in from the field's left edge.
    Offset underNote(WidgetTester tester, int rows, {double x = 40}) {
      final editable = NoteDriver(tester);
      final origin = editable.toGlobal(Offset.zero);
      final end = editable.state.layout.heights!.total;
      return Offset(
        origin.dx + x,
        origin.dy + end + (rows - 0.5) * editable.rowHeight,
      );
    }

    TextSelection selectionOf(WidgetTester tester) =>
        tester.state<NoteFieldState>(noteField).widget.controller.selection;

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

    testWidgets('the caret goes to the end of the note, and nothing is '
        'written', (tester) async {
      const body = 'one\ntwo\nthree';
      var saved = body;
      await pumpEditor(tester, body, onBodyChanged: (text) => saved = text);

      // Under the start of the lines as well as across the page: below the
      // writing is after it, whichever column the click was in.
      for (final x in [4.0, 40.0, 400.0]) {
        await tester.tapAt(underNote(tester, 6, x: x));
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();
        expect(
          selectionOf(tester),
          const TextSelection.collapsed(offset: body.length),
          reason: 'x = $x',
        );
      }
      expect(saved, body);
      expect(
        tester.state<NoteFieldState>(noteField).widget.focusNode.hasFocus,
        isTrue,
      );
    });

    testWidgets('an empty note stays empty', (tester) async {
      var saved = '';
      await pumpEditor(tester, '', onBodyChanged: (text) => saved = text);

      await tester.tapAt(underNote(tester, 3));
      await tester.pumpAndSettle();

      expect(selectionOf(tester), const TextSelection.collapsed(offset: 0));
      expect(saved, '');
    });

    testWidgets('a note that ends in an empty line gains no more', (
      tester,
    ) async {
      const body = 'one\n';
      var saved = body;
      await pumpEditor(tester, body, onBodyChanged: (text) => saved = text);

      await tester.tapAt(underNote(tester, 4));
      await tester.pumpAndSettle();

      expect(saved, body);
      expect(
        selectionOf(tester),
        const TextSelection.collapsed(offset: body.length),
      );
    });

    testWidgets('a click on a line the note reaches leaves it alone', (
      tester,
    ) async {
      const body = 'one\ntwo\nthree';
      var saved = body;
      await pumpEditor(tester, body, onBodyChanged: (text) => saved = text);

      // Past the end of the second line, which is still that line.
      final editable = NoteDriver(tester);
      final two = editable.caretRect(TextPosition(offset: body.indexOf('two')));
      await tester.tapAt(editable.toGlobal(Offset(400, two.center.dy)));
      await tester.pumpAndSettle();

      expect(saved, body);
      expect(selectionOf(tester).isCollapsed, isTrue);
      expect(selectionOf(tester).baseOffset, body.indexOf('two') + 3);
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

      await tester.tapAt(underNote(tester, 7));
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

    final state = tester.state<NoteFieldState>(noteField);
    // Straddles the blank line on the way to real text.
    state.userUpdateTextEditingValue(
      state.widget.controller.value.copyWith(
        selection: const TextSelection(baseOffset: 4, extentOffset: 12),
      ),
      SelectionChangedCause.drag,
    );
    await tester.pumpAndSettle();

    final selection = state.widget.controller.value.selection;
    expect(selection.isCollapsed, isFalse);
    expect(selection.extentOffset, 12);
  });

  testWidgets('a line deleted whole is reported where it went, not where '
      'the text alone would put it', (tester) async {
    const body = 'Errands\n☐ Buy oats\n☐ Buy milk\n☐ Buy eggs';
    final edits = <TextEdit?>[];
    await tester.pumpWidget(harness(body, autofocus: true, onEdit: edits.add));
    await tester.pumpAndSettle();

    final state = tester.state<NoteFieldState>(noteField);
    state.userUpdateTextEditingValue(
      state.widget.controller.value.copyWith(
        selection: const TextSelection(baseOffset: 19, extentOffset: 30),
      ),
      SelectionChangedCause.drag,
    );
    await tester.pumpAndSettle();
    state.userUpdateTextEditingValue(
      const TextEditingValue(
        text: 'Errands\n☐ Buy oats\n☐ Buy eggs',
        selection: TextSelection.collapsed(offset: 19),
      ),
      SelectionChangedCause.keyboard,
    );
    await tester.pumpAndSettle();

    expect(edits.last, (start: 19, oldEnd: 30, newEnd: 19));
  });

  group('blank lines', () {
    // "one" ends at 3, the blank lines' breaks are 4 to 7, "two" starts at 8.
    const body = 'one\n\n\n\n\ntwo';

    /// A point on the line [offset] starts, a little in from its edge.
    Offset onLineOf(WidgetTester tester, int offset) {
      final editable = NoteDriver(tester);
      final caret = editable.caretRect(TextPosition(offset: offset));
      return editable.toGlobal(caret.center + const Offset(20, 0));
    }

    TextSelection selectionOf(WidgetTester tester) => tester
        .state<NoteFieldState>(noteField)
        .widget
        .controller
        .value
        .selection;

    /// What the blank-line highlight paints, in global coordinates.
    List<({Rect rect, Color color})> blankLineBlocks(WidgetTester tester) {
      final lines = NoteDriver(tester).state.lines;
      final blocks = <({Rect rect, Color color})>[];
      // Each line once: several elements can stand over one render object.
      for (final drawn
          in tester.allRenderObjects.whereType<RenderNoteLine>().toSet()) {
        if (lines[drawn.line].isNotEmpty) continue;
        final canvas = TestRecordingCanvas();
        drawn.paint(TestRecordingPaintingContext(canvas), Offset.zero);
        final origin = drawn.localToGlobal(Offset.zero);
        for (final call in canvas.invocations) {
          if (call.invocation.memberName != #drawRect) continue;
          blocks.add((
            rect: (call.invocation.positionalArguments[0] as Rect).shift(
              origin,
            ),
            color: (call.invocation.positionalArguments[1] as Paint).color,
          ));
        }
      }
      return blocks..sort((a, b) => a.rect.top.compareTo(b.rect.top));
    }

    // Every selection made only of line breaks used to collapse to a caret.
    // Meant for a double click on a blank line, the rule also swallowed a
    // drag over blank lines, Shift with the arrows, and Select All — so a run
    // of them could be neither selected nor deleted in one go.
    testWidgets('can be selected by dragging over them', (tester) async {
      await tester.pumpWidget(harness(body, autofocus: true));
      await tester.pumpAndSettle();

      final drag = await tester.startGesture(
        onLineOf(tester, 4),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await drag.moveTo(onLineOf(tester, 7));
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();

      expect(
        selectionOf(tester),
        const TextSelection(baseOffset: 4, extentOffset: 7),
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('selected with Shift and the arrows go in one keystroke', (
      tester,
    ) async {
      var saved = body;
      await tester.pumpWidget(
        harness(body, autofocus: true, onBodyChanged: (text) => saved = text),
      );
      await tester.pumpAndSettle();
      final state = tester.state<NoteFieldState>(noteField);
      state.userUpdateTextEditingValue(
        state.widget.controller.value.copyWith(
          selection: const TextSelection.collapsed(offset: 4),
        ),
        SelectionChangedCause.tap,
      );
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      }
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(
        selectionOf(tester),
        const TextSelection(baseOffset: 4, extentOffset: 7),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pumpAndSettle();
      expect(saved, 'one\n\ntwo');
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('that make up the whole note go with Select All', (
      tester,
    ) async {
      var saved = '\n\n\n\n';
      await tester.pumpWidget(
        harness(
          '\n\n\n\n',
          autofocus: true,
          onBodyChanged: (text) => saved = text,
        ),
      );
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pumpAndSettle();

      expect(saved, isEmpty);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    // A press that selects by word finds nothing on a blank line but its
    // break. Left standing, that hid the caret, opened the formatting toolbar
    // over nothing, and let a Paste from the menu replace the break.
    testWidgets('double or right clicking one leaves a caret', (tester) async {
      await tester.pumpWidget(harness(body, autofocus: true));
      await tester.pumpAndSettle();

      final blank = onLineOf(tester, 5);
      final mouse = await tester.startGesture(
        blank,
        kind: PointerDeviceKind.mouse,
      );
      await mouse.up();
      await tester.pump(const Duration(milliseconds: 50));
      await mouse.down(blank);
      await tester.pump();
      await mouse.up();
      await tester.pumpAndSettle();
      expect(selectionOf(tester), const TextSelection.collapsed(offset: 5));

      // Well clear of the double-click window.
      await tester.pump(const Duration(seconds: 1));
      await tester.tapAt(
        onLineOf(tester, 6),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(selectionOf(tester), const TextSelection.collapsed(offset: 6));
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('a long press on one leaves a caret', (tester) async {
      await tester.pumpWidget(harness(body, autofocus: true));
      await tester.pumpAndSettle();

      await tester.longPressAt(onLineOf(tester, 5));
      await tester.pumpAndSettle();

      expect(selectionOf(tester), const TextSelection.collapsed(offset: 5));
    });

    // The field highlights each line only as far as its text, and a blank
    // line has none — its break is a zero-width box — so a selection over
    // blank lines showed nothing on them at all.
    testWidgets('are highlighted where a selection covers them', (
      tester,
    ) async {
      await tester.pumpWidget(harness(body, autofocus: true));
      await tester.pumpAndSettle();
      final state = tester.state<NoteFieldState>(noteField);
      state.userUpdateTextEditingValue(
        state.widget.controller.value.copyWith(
          selection: const TextSelection(baseOffset: 4, extentOffset: 7),
        ),
        SelectionChangedCause.drag,
      );
      await tester.pumpAndSettle();

      final editable = NoteDriver(tester);
      final blocks = blankLineBlocks(tester);
      // The break at 7 ends the selection rather than sitting in it.
      expect(blocks, hasLength(3));
      for (final (index, block) in blocks.indexed) {
        final top = editable.state.lineTop(
          editable.state.lines.lineAt(4 + index),
        )!;
        final lineOrigin = editable.toGlobal(Offset(0, top));
        expect(block.rect.left, moreOrLessEquals(lineOrigin.dx));
        expect(block.rect.top, moreOrLessEquals(lineOrigin.dy));
        expect(block.rect.height, moreOrLessEquals(editable.rowHeight));
        expect(block.rect.width, greaterThan(2));
        expect(block.color, isSameColorAs(editable.selectionColor!));
      }

      // Lines holding text are the field's own business.
      state.userUpdateTextEditingValue(
        state.widget.controller.value.copyWith(
          selection: const TextSelection(baseOffset: 0, extentOffset: 3),
        ),
        SelectionChangedCause.drag,
      );
      await tester.pumpAndSettle();
      expect(blankLineBlocks(tester), isEmpty);

      // And like the field's highlight, it goes with the focus.
      state.userUpdateTextEditingValue(
        state.widget.controller.value.copyWith(
          selection: const TextSelection(baseOffset: 4, extentOffset: 7),
        ),
        SelectionChangedCause.drag,
      );
      await tester.pumpAndSettle();
      expect(blankLineBlocks(tester), hasLength(3));
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(blankLineBlocks(tester), isEmpty);
    });
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
    final state = tester.state<NoteFieldState>(noteField);
    state.userUpdateTextEditingValue(
      state.widget.controller.value.copyWith(selection: selection),
      SelectionChangedCause.drag,
    );
    await tester.pumpAndSettle();

    final editable = NoteDriver(tester);
    final highlight = editable.boxesFor(selection);
    expect(highlight, hasLength(2), reason: 'one highlight per selected line');
    // The first line is the one that used to be padded: its line break falls
    // inside the selection, and the line above it is far longer.
    for (final index in [1, 2]) {
      final text = editable
          .boxesFor(
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

  testWidgets('puts a wrapped line\'s result on its last row', (tester) async {
    // Long enough to wrap in the narrow text pane, which pushes every
    // following line down by one row.
    const long =
        '1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1';
    const body = 'first\n$long\nafter = 9';
    // The handwriting face is proportionally spaced and fits more of this
    // expression than the old mono default, so keep the pane narrow enough
    // to preserve the wrap.
    await tester.pumpWidget(harness(body, width: 465));
    await tester.pumpAndSettle();

    final wrappedLine = lineRect(tester, body, 1);
    final lastRow = lastRowRect(tester, body, 1);
    final afterLine = lineRect(tester, body, 2);
    // Confirm the line really did wrap before asserting anything about it.
    expect(afterLine.top - wrappedLine.top, greaterThan(wrappedLine.height));
    expect(lastRow.top, greaterThan(wrappedLine.top));

    final wrapped = tester.getRect(chipWithText('18'));
    expect(wrapped.center.dy, closeTo(lastRow.center.dy, 1.5));
    expect(
      wrapped.left,
      greaterThan(lastRow.right),
      reason: 'after the writing on that row, not over it',
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
        '7 * 55\n'
        'total';
    await tester.pumpWidget(harness(body, width: 465));
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
    const body = 'Trip\n  // travel assumptions\n2 + 2';
    await tester.pumpWidget(harness(body));
    await tester.pumpAndSettle();

    final rendered = NoteDriver(tester).span;
    final comment = rendered.children!.whereType<TextSpan>().firstWhere(
      (span) => span.text?.contains('//') ?? false,
    );
    final indentation = rendered.children!.whereType<TextSpan>().firstWhere(
      (span) => span.text?.endsWith('  ') ?? false,
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
            'startIndex': 1,
            'endIndex': 6,
            'suggestions': ['sample', 'simple'],
          },
        ];
      });

      // Under a blank first line, so this is not the note's title.
      await tester.pumpWidget(harness('\nsmple + 2', autofocus: true));
      await tester.pump(const Duration(milliseconds: 181));
      await tester.pump();

      final rendered = NoteDriver(tester).span;
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
        Theme.of(tester.element(noteField)).colorScheme.error,
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
    final field = tester.widget<NoteField>(noteField);
    field.controller.selection = const TextSelection.collapsed(offset: 2);
    await tester.pump();

    // No pointer went near the word, so nothing asked the system for its
    // corrections ahead of time: the menu opens and then fills itself in.
    final editable = tester.state<NoteFieldState>(noteField);
    expect(editable.showToolbar(), isTrue);
    await tester.pump();
    expect(find.text('sample'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('sample'), findsOneWidget);
    expect(find.text('simple'), findsOneWidget);

    await tester.tap(find.text('sample'));
    await tester.pump();
    expect(field.controller.text, 'sample note');
    expect(
      field.controller.selection,
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

    final field = tester.widget<NoteField>(noteField);
    expect(
      field.controller.selection,
      const TextSelection(baseOffset: 0, extentOffset: 5),
    );
    expect(find.byKey(const ValueKey('editor-context-menu')), findsOneWidget);
    expect(find.text('sample'), findsOneWidget);
    expect(find.text('simple'), findsOneWidget);
    // Formatting stays where it was: the word is still selected text. The
    // selection is the menu's, so the bubble keeps out of its way.
    expect(find.text('Bold'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('selection-bubble')), findsNothing);

    await tester.tap(find.text('simple'));
    await tester.pumpAndSettle();
    expect(field.controller.text, 'simple note');
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
    final field = tester.widget<NoteField>(noteField);
    field.controller.selection = const TextSelection.collapsed(offset: 10);
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
    expect(field.controller.text, 'sample note');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('orders the bar from attach and the line tools to the marks '
      'and links', (tester) async {
    _onPhone();
    await tester.pumpWidget(harness('2 + 2'));
    await tester.pumpAndSettle();
    await revealFormatting(tester);

    final bar = tester.getRect(find.byKey(const ValueKey('phone-format-bar')));
    expect(bar.height, 44);
    double leftOf(String key) => tester.getRect(find.byKey(ValueKey(key))).left;
    final order = [
      'format-attach',
      'format-style',
      'format-bold',
      'format-italic',
      'format-checklist',
      'format-bullets',
      'format-numbered',
      'format-quote',
      'format-code',
      'format-link',
    ];
    for (var i = 1; i < order.length; i++) {
      expect(
        leftOf(order[i]),
        greaterThan(leftOf(order[i - 1])),
        reason: order[i],
      );
    }
    expect(find.byKey(const ValueKey('format-indent')), findsNothing);
  });

  testWidgets('leaves settings to the notes list', (tester) async {
    _onPhone();
    await tester.pumpWidget(harness('2 + 2'));
    await tester.pumpAndSettle();
    await revealFormatting(tester);

    // The bar belongs to the note: what it holds either writes in it or
    // reports on it. Settings is a row in the notes list on every layout.
    expect(find.byKey(const ValueKey('note-settings')), findsNothing);
    expect(find.byTooltip('Settings'), findsNothing);
  });

  testWidgets('applies real bold and italic styles without changing text', (
    tester,
  ) async {
    _onPhone();
    final changes = <List<NoteFormatRange>>[];
    await tester.pumpWidget(
      harness('Format me', onFormatsChanged: changes.add),
    );
    await tester.pumpAndSettle();
    final field = tester.widget<NoteField>(noteField);
    field.controller.selection = const TextSelection(
      baseOffset: 0,
      extentOffset: 6,
    );
    await tester.pump();
    await revealFormatting(tester);

    await tester.tap(find.byKey(const ValueKey('format-bold')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('format-italic')));
    await tester.pumpAndSettle();

    expect(field.controller.text, 'Format me');
    expect(changes.last, const [
      NoteFormatRange(start: 0, end: 6, format: NoteFormat.bold),
      NoteFormatRange(start: 0, end: 6, format: NoteFormat.italic),
    ]);
    final rendered = NoteDriver(tester).span;
    final formatted = rendered.children!.whereType<TextSpan>().firstWhere(
      (span) => span.text == 'Format',
    );
    expect(formatted.style!.fontWeight, FontWeight.w600);
    expect(formatted.style!.fontStyle, FontStyle.italic);
  });

  testWidgets('styles pasted URLs as links without changing their text', (
    tester,
  ) async {
    const body = 'Reading\nRead https://example.com/docs?q=notes.';

    await tester.pumpWidget(harness(body));
    await tester.pumpAndSettle();

    final runs = NoteDriver(tester).span.children!.whereType<TextSpan>();
    // The page's link chip, which keeps its scheme out of sight.
    final address = runs.firstWhere(
      (span) => span.text == 'example.com/docs?q=notes',
    );
    expect(address.style!.fontFamily, AppFonts.mono);
    expect(address.style!.decoration, TextDecoration.none);
    // The full stop after it is the sentence's, not the address's.
    final period = runs.firstWhere((span) => span.text == '.');
    expect(period.style?.fontFamily, isNot(AppFonts.mono));
    expect(
      period.style?.decoration?.contains(TextDecoration.underline) ?? false,
      isFalse,
    );
    expect(period.style?.fontStyle, isNot(FontStyle.italic));
    expect(tester.widget<NoteField>(noteField).controller.text, body);
  });

  testWidgets('a link inside a comment is still a link', (tester) async {
    // A slash comment, a hash after a sum and a quoted annotation, then
    // prose, where the same kind of address still shows as a link.
    const body =
        'Links\n'
        '//buy from unipile (https://www.unipile.com/pricing-api/)\n'
        '2 + 2 # rates at https://example.com/rates\n'
        '3 * 4 "see example.com/tax"\n'
        'Read https://example.com/docs';

    await tester.pumpWidget(harness(body));
    await tester.pumpAndSettle();

    final rendered = NoteDriver(tester).span;
    // Every run of [text], however the highlighter happened to cut it.
    List<TextSpan> runsOf(String text) {
      final start = body.indexOf(text);
      final end = start + text.length;
      final runs = <TextSpan>[];
      var offset = 0;
      for (final span in rendered.children!) {
        if (span is! TextSpan) {
          offset++;
          continue;
        }
        final length = span.text?.length ?? 0;
        if (length > 0 && offset >= start && offset + length <= end) {
          runs.add(span);
        }
        offset += length;
      }
      expect(runs, isNotEmpty, reason: '"$text" was not drawn on its own');
      return runs;
    }

    // Each a chip on the page, as in prose.
    for (final link in [
      'https://www.unipile.com/pricing-api/',
      'https://example.com/rates',
      'example.com/tax',
      'https://example.com/docs',
    ]) {
      for (final run in runsOf(link)) {
        expect(run.style!.fontFamily, AppFonts.mono, reason: link);
      }
    }

    // Quiet, but still a link: a click on it offers to open it.
    await tester.tapAt(
      _centerOf(tester, body, 'https://www.unipile.com/pricing-api/'),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('link-popover')), findsOneWidget);
  });

  testWidgets('cycles paragraph presets directly from the footer', (
    tester,
  ) async {
    _onPhone();
    final changes = <List<NoteFormatRange>>[];
    await tester.pumpWidget(
      harness(
        'Note\nProject title\nA supporting thought',
        onFormatsChanged: changes.add,
      ),
    );
    await tester.pumpAndSettle();
    final field = tester.widget<NoteField>(noteField);
    field.controller.selection = const TextSelection(
      baseOffset: 7,
      extentOffset: 12,
    );
    await tester.pump();
    await revealFormatting(tester);

    await tester.tap(find.byKey(const ValueKey('format-style')));
    await tester.pumpAndSettle();

    expect(changes.last, const [
      NoteFormatRange(start: 5, end: 18, format: NoteFormat.heading),
    ]);
    final rendered = NoteDriver(tester).span;
    final heading = rendered.children!.whereType<TextSpan>().firstWhere(
      (span) => span.text == 'Project title',
    );
    expect(heading.style!.fontWeight, FontWeight.w600);
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
      NoteFormatRange(start: 5, end: 18, format: NoteFormat.subtitle),
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
    final field = tester.widget<NoteField>(noteField);
    field.controller.selection = const TextSelection.collapsed(offset: 13);
    await tester.pump();

    await tester.enterNote('Project title\nBody');
    await tester.pumpAndSettle();

    expect(changes.last, const [
      NoteFormatRange(start: 0, end: 13, format: NoteFormat.heading),
      NoteFormatRange(start: 14, end: 18, format: NoteFormat.subtitle),
    ]);
    final rendered = NoteDriver(tester).span;
    final body = rendered.children!.whereType<TextSpan>().firstWhere(
      (span) => span.text?.contains('Body') ?? false,
    );
    // The page's writing weight, in italic.
    expect(body.style!.fontWeight, FontWeight.w400);
    expect(body.style!.fontStyle, FontStyle.italic);

    field.controller.value = const TextEditingValue(
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
    _onPhone();
    final changes = <List<NoteFormatRange>>[];
    await tester.pumpWidget(
      harness('', startAtEnd: true, onFormatsChanged: changes.add),
    );
    await tester.pumpAndSettle();
    await revealFormatting(tester);

    await tester.tap(find.byKey(const ValueKey('format-style')));
    await tester.pumpAndSettle();
    await tester.enterNote('Project title');
    await tester.pumpAndSettle();

    expect(changes.last, const [
      NoteFormatRange(start: 0, end: 13, format: NoteFormat.heading),
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
    final field = tester.widget<NoteField>(noteField);
    field.controller.selection = TextSelection(
      baseOffset: body.indexOf('example'),
      extentOffset: body.indexOf('.com'),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    tester.state<NoteFieldState>(noteField).showToolbar();
    await tester.pumpAndSettle();
    expect(find.text('Open link'), findsOneWidget);
    expect(find.text('Copy link'), findsOneWidget);

    await tester.tap(find.text('Copy link'));
    await tester.pumpAndSettle();

    expect(copied, [linkText]);
    await tester.pump(const Duration(seconds: 2));
  });

  group('scrolling from the results gutter', () {
    /// A note long enough that the field has somewhere to scroll to.
    String longBody() =>
        [for (var i = 1; i <= 80; i++) 'line$i = $i * 2'].join('\n');

    ScrollController fieldScroll(WidgetTester tester) =>
        tester.widget<NoteField>(noteField).scrollController;

    testWidgets('a drag beside the results scrolls the note', (tester) async {
      // The right of a phone's page, where results sit, once was a column
      // of its own that a drag landed on nothing in.
      tester.view.physicalSize = const Size(390, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(harness(longBody(), keepResultRoom: true));
      await tester.pumpAndSettle();

      final scroll = fieldScroll(tester);
      expect(scroll.offset, 0);

      final gutter = tester.getRect(noteField).centerRight - const Offset(8, 0);
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
      await tester.pumpWidget(harness(longBody(), keepResultRoom: true));
      await tester.pumpAndSettle();

      final scroll = fieldScroll(tester);
      await tester.flingFrom(
        tester.getRect(noteField).centerRight - const Offset(8, 0),
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

    testWidgets('a drag or a wheel over a pill scrolls the note', (
      tester,
    ) async {
      // A pill sits over the field, so the field never sees what lands on it.
      await tester.pumpWidget(harness(longBody()));
      await tester.pumpAndSettle();

      final scroll = fieldScroll(tester);
      final pill = tester.getCenter(find.byType(ResultChip).first);
      await tester.dragFrom(pill, const Offset(0, -160));
      await tester.pumpAndSettle();
      final dragged = scroll.offset;
      expect(dragged, greaterThan(0));

      // The first pill on screen now: one scrolled half under the top edge
      // is clipped there and takes no pointer.
      final wheel = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        wheel.hover(
          tester.getCenter(find.byType(ResultChip).hitTestable().first),
        ),
      );
      await tester.sendEventToBinding(wheel.scroll(const Offset(0, 120)));
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(dragged));
    });

    testWidgets('tapping a chip still copies rather than scrolling', (
      tester,
    ) async {
      // The passthrough claims vertical drags, not taps: children hit-test
      // first, so a chip is still a chip.
      await tester.pumpWidget(harness('Revenue\nrev = 4 * 3'));
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
    final editable = NoteDriver(tester);
    final start = body.indexOf(linkText);
    final box = editable
        .boxesFor(
          TextSelection(
            baseOffset: start,
            extentOffset: start + linkText.length,
          ),
        )
        .first;
    final tapPosition = editable.toGlobal(
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
      expect(tester.widget<NoteField>(noteField).controller.text, body);

      await tester.tapAt(_centerOf(tester, body, 'over'));
      await tester.pumpAndSettle();

      expect(
        find.text('Divides the value on the left by the value on the right.'),
        findsOneWidget,
      );
      expect(tester.widget<NoteField>(noteField).controller.text, body);

      final controller = tester.widget<NoteField>(noteField).controller;
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
      // Under a blank first line, so this is not the note's title.
      const body = '\nOpen www.example.com/path and then keep writing here';
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
      final field = tester.widget<NoteField>(noteField);
      final caret = field.controller.selection.baseOffset;
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

    expect(tester.testTextInput.isVisible, isFalse);
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
    final field = tester.widget<NoteField>(noteField);
    field.controller.selection = const TextSelection.collapsed(offset: 3);
    await tester.pumpAndSettle();
    tester.state<NoteFieldState>(noteField).showToolbar();
    await tester.pumpAndSettle();

    final contextMenu = find.byKey(const ValueKey('editor-context-menu'));
    expect(contextMenu, findsOneWidget);
    expect(tester.getSize(contextMenu).width, lessThanOrEqualTo(208));
    expect(
      find.ancestor(of: contextMenu, matching: find.byType(FadeTransition)),
      findsOneWidget,
    );
    await tester.tap(find.text('Copy plain text'));
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
    final field = tester.widget<NoteField>(noteField);
    field.controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: body.indexOf('\n'),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    tester.state<NoteFieldState>(noteField).showToolbar();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('editor-context-menu')), findsOneWidget);
    await tester.tap(find.text('Copy plain text'));
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

    await tester.enterNote('$body!');
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
    final editable = NoteDriver(tester);
    final start = body.indexOf(linkText);
    final box = editable
        .boxesFor(
          TextSelection(
            baseOffset: start,
            extentOffset: start + linkText.length,
          ),
        )
        .first;
    final clickPosition = editable.toGlobal(
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

  testWidgets('Text ▾ in a plain note maps headings to its own styles', (
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
    final field = tester.widget<NoteField>(noteField);
    Future<void> turnInto(String block) async {
      field.controller.selection = const TextSelection(
        baseOffset: 2,
        extentOffset: 12,
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('selection-block')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('selection-block-$block')));
      await tester.pumpAndSettle();
    }

    await turnInto('Heading 1');
    expect(changes.last, const [
      NoteFormatRange(start: 0, end: 20, format: NoteFormat.heading),
    ]);
    await turnInto('Heading 2');
    expect(changes.last, const [
      NoteFormatRange(start: 0, end: 20, format: NoteFormat.subtitle),
    ]);
    await turnInto('Text');
    expect(changes.last, isEmpty);
    expect(field.controller.text, 'A supporting thought');
  });

  testWidgets('Text style preserves independent bold and italic controls', (
    tester,
  ) async {
    _onPhone();
    final changes = <List<NoteFormatRange>>[];
    await tester.pumpWidget(
      harness(
        'Note\nKeep emphasis',
        initialFormats: const [
          NoteFormatRange(start: 5, end: 9, format: NoteFormat.bold),
          NoteFormatRange(start: 10, end: 18, format: NoteFormat.italic),
          NoteFormatRange(start: 5, end: 18, format: NoteFormat.subtitle),
        ],
        onFormatsChanged: changes.add,
      ),
    );
    await tester.pumpAndSettle();
    final field = tester.widget<NoteField>(noteField);
    field.controller.selection = const TextSelection(
      baseOffset: 5,
      extentOffset: 18,
    );
    await tester.pump();
    await revealFormatting(tester);

    await tester.tap(find.byKey(const ValueKey('format-style')));
    await tester.pumpAndSettle();

    expect(changes.last, const [
      NoteFormatRange(start: 5, end: 9, format: NoteFormat.bold),
      NoteFormatRange(start: 10, end: 18, format: NoteFormat.italic),
    ]);
    final rendered = NoteDriver(tester).span;
    final bold = rendered.children!.whereType<TextSpan>().firstWhere(
      (span) => span.text == 'Keep',
    );
    final italic = rendered.children!.whereType<TextSpan>().firstWhere(
      (span) => span.text == 'emphasis',
    );
    expect(bold.style!.fontWeight, FontWeight.w600);
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
    final field = tester.widget<NoteField>(noteField);
    field.controller.selection = const TextSelection(
      baseOffset: 4,
      extentOffset: 11,
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    // A phone gets the platform's own toolbar, which keeps itself on the
    // screen and moves whatever does not fit behind More. Copy leads it, and
    // is there before the clipboard has been asked anything: no clipboard
    // answers in this test at all.
    final toolbar = tester.getRect(find.byType(TextSelectionToolbar));
    expect(toolbar.left, greaterThanOrEqualTo(0));
    expect(toolbar.right, lessThanOrEqualTo(320));
    expect(find.text('Copy').hitTestable(), findsOneWidget);

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(find.text('Open link').hitTestable(), findsOneWidget);
    expect(find.text('Copy link').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a collapsed format toggle styles subsequent typing', (
    tester,
  ) async {
    _onPhone();
    final changes = <List<NoteFormatRange>>[];
    await tester.pumpWidget(harness('A', onFormatsChanged: changes.add));
    await tester.pumpAndSettle();
    final field = tester.widget<NoteField>(noteField);
    field.controller.selection = const TextSelection.collapsed(offset: 1);
    await tester.pump();
    await revealFormatting(tester);

    await tester.tap(find.byKey(const ValueKey('format-bold')));
    await tester.pump();
    field.controller.value = const TextEditingValue(
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
    final field = tester.widget<NoteField>(noteField);
    field.controller.selection = const TextSelection(
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
    final field = tester.widget<NoteField>(noteField);
    field.controller.selection = const TextSelection(
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
    expect(field.controller.text, '${bulletPrefix}Task');

    await sendShortcut(
      tester,
      shortcutPrefs.bindingFor(ShortcutAction.formatChecklist)!,
    );
    await tester.pumpAndSettle();
    expect(field.controller.text, '${uncheckedPrefix}Task');
  });

  testWidgets('a changed shortcut works at once', (tester) async {
    _onPhone();
    await tester.pumpWidget(harness('Task', autofocus: true));
    await tester.pumpAndSettle();
    final original = shortcutPrefs.bindingFor(ShortcutAction.formatBullets)!;
    expect(original, isNotNull);

    const replacement = ShortcutBinding(
      logicalKey: LogicalKeyboardKey.keyU,
      physicalKey: PhysicalKeyboardKey.keyU,
      control: true,
      alt: true,
    );
    shortcutPrefs.update(ShortcutAction.formatBullets, replacement);
    await tester.pumpAndSettle();

    final field = tester.widget<NoteField>(noteField);
    field.controller.selection = const TextSelection(
      baseOffset: 0,
      extentOffset: 4,
    );
    await sendShortcut(tester, replacement);
    await tester.pumpAndSettle();
    expect(field.controller.text, '${bulletPrefix}Task');
  });

  testWidgets('the format bar offers Details on a task, drawn as lines', (
    tester,
  ) async {
    _onPhone();
    await tester.pumpWidget(harness('☐ Task'));
    await tester.pumpAndSettle();
    final field = tester.widget<NoteField>(noteField);
    field.controller.selection = const TextSelection.collapsed(offset: 4);
    await tester.pump();
    await revealFormatting(tester);

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('format-details')),
        matching: find.byWidgetPredicate(
          (widget) => widget is KapyIcon && widget.icon == KapyIcons.alignLeft,
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('creates, completes, and removes a checklist item', (
    tester,
  ) async {
    _onPhone();
    await tester.pumpWidget(harness('List\nTask'));
    await tester.pumpAndSettle();
    final field = tester.widget<NoteField>(noteField);
    field.controller.selection = const TextSelection.collapsed(offset: 9);
    await tester.pump();
    await revealFormatting(tester);

    await tester.tap(find.byKey(const ValueKey('format-checklist')));
    await tester.pumpAndSettle();
    expect(field.controller.text, 'List\n☐ Task');

    final editable = NoteDriver(tester);
    final checkbox = editable
        .boxesFor(const TextSelection(baseOffset: 5, extentOffset: 6))
        .single;
    final checkboxCenter = editable.toGlobal(
      Offset(
        (checkbox.left + checkbox.right) / 2,
        (checkbox.top + checkbox.bottom) / 2,
      ),
    );
    await tester.tapAt(checkboxCenter);
    await tester.pumpAndSettle();
    expect(field.controller.text, 'List\n☑ Task');
    final rendered = editable.span;
    final completed = rendered.children!.whereType<TextSpan>().firstWhere(
      (span) => span.text == 'Task',
    );
    expect(completed.style!.decoration, TextDecoration.lineThrough);

    await tester.tapAt(checkboxCenter);
    await tester.pumpAndSettle();
    expect(field.controller.text, 'List\n☐ Task');

    await tester.tap(find.byKey(const ValueKey('format-checklist')));
    await tester.pumpAndSettle();
    expect(field.controller.text, 'List\nTask');
  });

  testWidgets('Enter keeps a nested item at its own depth', (tester) async {
    await tester.pumpWidget(harness('• one\n  • two'));
    await tester.pumpAndSettle();
    final field = tester.widget<NoteField>(noteField);
    field.controller.selection = const TextSelection.collapsed(offset: 13);
    await tester.pump();

    await tester.enterNote('• one\n  • two\n');
    await tester.pumpAndSettle();
    expect(field.controller.text, '• one\n  • two\n  • ');
  });

  testWidgets('Enter on an empty nested item steps out one level at a time', (
    tester,
  ) async {
    await tester.pumpWidget(harness('• one\n    ▪ '));
    await tester.pumpAndSettle();
    final field = tester.widget<NoteField>(noteField);
    field.controller.selection = const TextSelection.collapsed(offset: 12);
    await tester.pump();

    // Stepping out a level takes that level's bullet with it.
    await tester.enterNote('• one\n    ▪ \n');
    await tester.pumpAndSettle();
    expect(field.controller.text, '• one\n  ◦ ');

    await tester.enterNote('• one\n  ◦ \n');
    await tester.pumpAndSettle();
    expect(field.controller.text, '• one\n• ');

    // Back at the margin, the next Enter leaves the list, as it always did.
    await tester.enterNote('• one\n• \n');
    await tester.pumpAndSettle();
    expect(field.controller.text, '• one\n');
  });

  testWidgets('typing "- " at the start of a line makes a bullet', (
    tester,
  ) async {
    await tester.pumpWidget(harness(''));
    await tester.pumpAndSettle();
    final field = tester.widget<NoteField>(noteField);

    await tester.enterNote('-');
    await tester.pumpAndSettle();
    await tester.enterNote('- ');
    await tester.pumpAndSettle();

    // The typed space is spent on the marker rather than added after it.
    expect(field.controller.text, '• ');
    expect(field.controller.selection.baseOffset, 2);
  });

  testWidgets('typing "[] " and "[ ] " both make a checkbox', (tester) async {
    for (final shorthand in ['[]', '[ ]']) {
      await tester.pumpWidget(harness(''));
      await tester.pumpAndSettle();
      final field = tester.widget<NoteField>(noteField);

      await tester.enterNote(shorthand);
      await tester.pumpAndSettle();
      await tester.enterNote('$shorthand ');
      await tester.pumpAndSettle();

      expect(field.controller.text, '☐ ', reason: 'from "$shorthand "');
    }
  });

  testWidgets('shorthand inside a nested list takes that level\'s bullet', (
    tester,
  ) async {
    await tester.pumpWidget(harness('• one\n  '));
    await tester.pumpAndSettle();
    final field = tester.widget<NoteField>(noteField);

    await tester.enterNote('• one\n  -');
    await tester.pumpAndSettle();
    await tester.enterNote('• one\n  - ');
    await tester.pumpAndSettle();

    expect(field.controller.text, '• one\n  ◦ ');
  });

  testWidgets('a minus that is not shorthand is left as arithmetic', (
    tester,
  ) async {
    await tester.pumpWidget(harness(''));
    await tester.pumpAndSettle();
    final field = tester.widget<NoteField>(noteField);

    // No space after the minus, so this stays the negative number the engine
    // evaluates rather than becoming a bullet.
    await tester.enterNote('-5');
    await tester.pumpAndSettle();
    expect(field.controller.text, '-5');

    // And mid-line the shorthand does not apply at all.
    await tester.enterNote('12 -');
    await tester.pumpAndSettle();
    await tester.enterNote('12 - ');
    await tester.pumpAndSettle();
    expect(field.controller.text, '12 - ');
  });

  testWidgets('Tab nests the current item and Shift+Tab lifts it out', (
    tester,
  ) async {
    await tester.pumpWidget(harness('• one', autofocus: true));
    await tester.pumpAndSettle();
    final field = tester.widget<NoteField>(noteField);
    field.controller.selection = const TextSelection.collapsed(offset: 5);
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(field.controller.text, '  ◦ one');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(field.controller.text, '• one');
  });

  testWidgets('Tab is left to move focus when the caret is not on a list', (
    tester,
  ) async {
    await tester.pumpWidget(harness('just prose', autofocus: true));
    await tester.pumpAndSettle();
    final field = tester.widget<NoteField>(noteField);
    field.controller.selection = const TextSelection.collapsed(offset: 4);
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(field.controller.text, 'just prose');
  });

  testWidgets('the nesting controls appear only for a list line', (
    tester,
  ) async {
    _onPhone();
    await tester.pumpWidget(harness('plain\n• item', autofocus: true));
    await tester.pumpAndSettle();
    await revealFormatting(tester);
    final field = tester.widget<NoteField>(noteField);

    field.controller.selection = const TextSelection.collapsed(offset: 2);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('format-indent')), findsNothing);

    field.controller.selection = const TextSelection.collapsed(offset: 9);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('format-indent')), findsOneWidget);
    expect(find.byKey(const ValueKey('format-style')), findsNothing);
    // Already at the margin, so there is nowhere to step out to.
    await tester.tap(find.byKey(const ValueKey('format-outdent')));
    await tester.pumpAndSettle();
    expect(field.controller.text, 'plain\n• item');
  });

  testWidgets('continues and exits a checklist with Enter', (tester) async {
    await tester.pumpWidget(harness('☐ Task'));
    await tester.pumpAndSettle();
    final field = tester.widget<NoteField>(noteField);
    field.controller.selection = const TextSelection.collapsed(offset: 6);
    await tester.pump();

    await tester.enterNote('☐ Task\n');
    await tester.pumpAndSettle();
    expect(field.controller.text, '☐ Task\n☐ ');

    await tester.enterNote('☐ Task\n☐ \n');
    await tester.pumpAndSettle();
    expect(field.controller.text, '☐ Task\n');
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
    /// The writing, and the room each row keeps after it for the caret.
    double fieldWidth(WidgetTester tester) =>
        NoteDriver(tester).columnWidth + EditorMetrics.caretMargin;

    const baseEditor = 600.0;
    await tester.pumpWidget(
      harness('seed', width: baseEditor, writingFont: WritingFont.monospace),
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

    // Narrow the editor just enough that the line lands inside the reserved
    // sliver: too long for the text area, short enough for the field.
    final chars = (baseWidth / advance).floor();
    final lineWidth = chars * advance;
    final targetWidth = lineWidth + EditorMetrics.caretMargin / 2;
    final editorWidth = baseEditor - (baseWidth - targetWidth);

    final body = '${'a' * chars}\n6 * 7';
    await tester.pumpWidget(
      harness(body, width: editorWidth, writingFont: WritingFont.monospace),
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

    final rendered = NoteDriver(tester).span.style!;
    final expected = EditorMetrics.textStyle(
      KapyTheme.darkPalette.textPrimary,
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
      tester.widget<NoteField>(noteField).style.fontFamily,
      'Shantell Sans',
    );

    await tester.pumpWidget(harness(body, writingFont: WritingFont.monospace));
    await tester.pumpAndSettle();

    expect(
      tester.widget<NoteField>(noteField).style.fontFamily,
      WritingFont.monospace.fontFamily,
    );
    expect(
      tester.getRect(chipWithText('42')).center.dy,
      closeTo(lineRect(tester, body, 1).center.dy, 1.5),
    );
  });

  testWidgets('mixed typeface scales headings and keeps result alignment', (
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

    // Handwritten for the title and headings, clean for the writing.
    final field = tester.widget<NoteField>(noteField);
    expect(field.style.fontFamily, WritingFont.mixed.fontFamily);

    final rendered = NoteDriver(tester).span;
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
    expect(heading.style?.fontSize, EditorMetrics.titleFontSize);
    expect(bodyText.style?.fontFamily, WritingFont.mixed.fontFamily);
    expect(
      tester.getRect(chipWithText('896.00 EUR')).center.dy,
      closeTo(lineRect(tester, body, 2).center.dy, 1.5),
    );

    await tester.pumpWidget(
      harness(
        body,
        initialFormats: formats,
        writingFont: WritingFont.mixed,
        editorTextScale: 1.4,
      ),
    );
    await tester.pumpAndSettle();

    final scaledField = tester.widget<NoteField>(noteField);
    expect(
      scaledField.style.fontSize,
      closeTo(WritingFont.mixed.editorSize * 1.4, 0.001),
    );
    final scaledRendered = NoteDriver(tester).span;
    final scaledHeading = scaledRendered.children!
        .whereType<TextSpan>()
        .firstWhere((span) => span.text == 'Nightly cost');
    expect(
      scaledHeading.style?.fontSize,
      closeTo(EditorMetrics.titleFontSize * 1.4, 0.001),
    );
    expect(
      tester.getRect(chipWithText('896.00 EUR')).center.dy,
      closeTo(lineRect(tester, body, 2).center.dy, 1.5),
    );
  });

  testWidgets('puts each result at the right-hand end of its own line', (
    tester,
  ) async {
    const body =
        'Tool costs per month\n'
        'ahrefs = 129 usd\n'
        'looker = 29 usd\n'
        'outreach = 3 * 49 usd\n'
        'total';
    await tester.pumpWidget(harness(body));
    await tester.pumpAndSettle();

    expect(find.byType(ResultLeader), findsWidgets);
    final editable = NoteDriver(tester);
    final columnRight =
        editable.toGlobal(Offset.zero).dx + editable.columnWidth;

    for (final entry in {
      1: '129.00 USD',
      2: '29.00 USD',
      3: '147.00 USD',
      4: '305.00 USD',
    }.entries) {
      final row = lastRowRect(tester, body, entry.key);
      final pill = tester.getRect(chipWithText(entry.value));
      expect(
        pill.center.dy,
        closeTo(row.center.dy, 1.5),
        reason: '"${entry.value}" should sit on line ${entry.key}',
      );
      expect(pill.right, closeTo(columnRight, 1));

      final leader = tester.getRect(
        find.byKey(ValueKey('result-leader-${entry.key}')),
      );
      expect(leader.left, closeTo(row.right + lineTrailingGap, 1));
      expect(leader.right, closeTo(pill.left - lineTrailingGap, 1));
      expect(leader.center.dy, closeTo(row.center.dy, 1.5));
    }
  });

  testWidgets('fills in the pill of the line that reads the total', (
    tester,
  ) async {
    await tester.pumpWidget(harness('Totals\na = 12\nb = 30\ntotal'));
    await tester.pumpAndSettle();

    Color fillOf(String text) =>
        (tester
                    .widget<AnimatedContainer>(
                      find.descendant(
                        of: chipWithText(text),
                        matching: find.byType(AnimatedContainer),
                      ),
                    )
                    .decoration!
                as BoxDecoration)
            .color!;
    TextStyle styleOf(String text) =>
        tester.widget<Text>(find.text(text)).style!;
    const palette = KapyTheme.darkPalette;

    expect(fillOf('42'), palette.totalPillBackground);
    expect(styleOf('42').color, palette.totalPillText);
    expect(styleOf('42').fontWeight, FontWeight.w600);
    for (final text in ['12', '30']) {
      expect(fillOf(text), palette.resultPillBackground);
      expect(styleOf(text).color, palette.resultPillText);
      expect(styleOf(text).fontWeight, FontWeight.w500);
    }
  });

  testWidgets('a pill steps past the column rather than cover the writing', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness('seed', writingFont: WritingFont.monospace),
    );
    await tester.pumpAndSettle();
    var editable = NoteDriver(tester);
    final width = editable.columnWidth;
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

    // A calculating line that stops 24px short of the column's edge: too
    // close for its pill to sit there with a gap before it, with room enough
    // in the margin to step out into.
    const tail = ' = 6 * 7';
    final chars = ((width - 24) / advance).floor() - tail.length;
    // Under a blank first line, so this is not the note's title.
    final body = '\n${'x' * chars}$tail';
    await tester.pumpWidget(harness(body, writingFont: WritingFont.monospace));
    await tester.pumpAndSettle();
    editable = NoteDriver(tester);
    final columnRight = editable.toGlobal(Offset.zero).dx + width;

    final row = lastRowRect(tester, body, 1);
    expect(row.top, lineRect(tester, body, 1).top, reason: 'one row only');
    final pill = tester.getRect(chipWithText('42'));
    expect(pill.left, closeTo(row.right + lineTrailingGap, 1));
    expect(pill.right, greaterThan(columnRight));
    expect(
      pill.right,
      lessThanOrEqualTo(tester.getRect(find.byType(NoteEditor)).right),
    );
  });

  testWidgets('a result is never part of the note', (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.windows;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() {
      AppPlatform.debugTargetPlatformOverride = null;
      debugDefaultTargetPlatformOverride = null;
    });
    final clipboard = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      switch (call.method) {
        case 'Clipboard.hasStrings':
          return {'value': clipboard.isNotEmpty};
        case 'Clipboard.getData':
          return clipboard.isEmpty ? null : {'text': clipboard.last};
        case 'Clipboard.setData':
          clipboard.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    Future<void> control(LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(
        LogicalKeyboardKey.controlLeft,
        platform: 'windows',
      );
      await tester.sendKeyEvent(key, platform: 'windows');
      await tester.sendKeyUpEvent(
        LogicalKeyboardKey.controlLeft,
        platform: 'windows',
      );
      await tester.pump();
    }

    const body = 'Rent\nrent = 1200 usd\nrent * 12\n';
    String? latest;
    await tester.pumpWidget(
      harness(body, autofocus: true, onBodyChanged: (value) => latest = value),
    );
    await tester.pump();
    // Let EditableText commit the initial value as the undo baseline.
    await tester.pump(const Duration(milliseconds: 600));
    expect(chipWithText('1,200.00 USD'), findsOneWidget);
    expect(chipWithText('14,400.00 USD'), findsOneWidget);

    final controller = tester.widget<NoteField>(noteField).controller;
    expect(controller.text, body);
    // What the field lays out and paints is the note and nothing more.
    expect(NoteDriver(tester).span.toPlainText(), body);

    // Copying all of it copies the note alone, and pasting it back adds the
    // note alone.
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: body.length,
    );
    await tester.pump();
    await control(LogicalKeyboardKey.keyC);
    expect(clipboard, [body]);
    controller.selection = const TextSelection.collapsed(offset: body.length);
    await tester.pump();
    await control(LogicalKeyboardKey.keyV);
    await tester.pumpAndSettle();
    expect(controller.text, '$body$body');
    expect(latest, '$body$body');

    // An edit at the end of a calculating line goes into the line, its pill
    // follows it live, and undo takes it back out.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.enterNote('Rent\nrent = 1300 usd\nrent * 12');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(controller.text, 'Rent\nrent = 1300 usd\nrent * 12');
    expect(chipWithText('1,300.00 USD'), findsOneWidget);
    expect(chipWithText('15,600.00 USD'), findsOneWidget);

    await control(LogicalKeyboardKey.keyZ);
    await tester.pumpAndSettle();
    expect(controller.text, '$body$body');
    expect(chipWithText('14,400.00 USD'), findsNWidgets(2));
    await tester.pump(const Duration(seconds: 2));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('says so when a result cannot be copied', (tester) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        throw PlatformException(code: 'unavailable');
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.pumpWidget(harness('Revenue\nrev = 4 * 3'));
    await tester.pumpAndSettle();

    await tester.tap(chipWithText('12'));
    await tester.pump();

    expect(find.text("Couldn't copy to clipboard"), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('hidden results leave the writing exactly as wide', (
    tester,
  ) async {
    await tester.pumpWidget(harness('Budget\n6 * 7'));
    await tester.pumpAndSettle();
    expect(chipWithText('42'), findsOneWidget);
    final shown = tester.getSize(noteField).width;

    await tester.pumpWidget(harness('Budget\n6 * 7', resultsVisible: false));
    await tester.pumpAndSettle();

    expect(find.byType(ResultChip), findsNothing);
    expect(find.byType(ResultLeader), findsNothing);
    expect(tester.getSize(noteField).width, shown);
  });

  testWidgets('a phone puts a result at the right of its own line', (
    tester,
  ) async {
    await tester.pumpWidget(harness('Budget\n6 * 7', keepResultRoom: true));
    await tester.pumpAndSettle();

    expect(find.byType(ResultLeader), findsNothing);
    expect(
      tester.getCenter(chipWithText('42')).dy,
      closeTo(lineRect(tester, 'Budget\n6 * 7', 1).center.dy, 1.5),
    );
    final target = tester.getSize(chipWithText('42'));
    expect(target.width, greaterThanOrEqualTo(44));
    expect(target.height, greaterThanOrEqualTo(44));
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('a phone on ${platform.name} draws results in the desktop\'s '
        'pills, with a total in the strong one', (tester) async {
      AppPlatform.debugTargetPlatformOverride = platform;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      const body = 'Totals\na = 12\nb = 30\ntotal';
      await tester.pumpWidget(
        harness(body, keepResultRoom: true, platform: platform),
      );
      await tester.pumpAndSettle();

      Finder pill(String text) => find.descendant(
        of: chipWithText(text),
        matching: find.byType(AnimatedContainer),
      );
      BoxDecoration decorationOf(String text) =>
          tester.widget<AnimatedContainer>(pill(text)).decoration!
              as BoxDecoration;
      TextStyle styleOf(String text) =>
          tester.widget<Text>(find.text(text)).style!;
      const palette = KapyTheme.darkPalette;

      expect(find.byType(ResultLeader), findsNothing);
      expect(decorationOf('42').color, palette.totalPillBackground);
      expect(styleOf('42').color, palette.totalPillText);
      expect(styleOf('42').fontWeight, FontWeight.w600);
      for (final text in ['12', '30']) {
        expect(decorationOf(text).color, palette.resultPillBackground);
        expect(styleOf(text).color, palette.resultPillText);
        expect(styleOf(text).fontWeight, FontWeight.w500);
      }
      for (final (line, text) in [(1, '12'), (2, '30'), (3, '42')]) {
        final style = styleOf(text);
        expect(style.fontSize, AppTypeScale.result);
        expect(style.fontSize, greaterThan(13), reason: "the phone's size");
        expect(style.fontFeatures, const [FontFeature.tabularFigures()]);
        final rect = tester.getRect(pill(text));
        final radius =
            (decorationOf(text).borderRadius! as BorderRadius).topLeft.x;
        expect(radius, closeTo(rect.height / 2, 0.5), reason: 'round ends');
        final row = lineRect(tester, body, line);
        expect(rect.top, greaterThanOrEqualTo(row.top - 0.5));
        expect(rect.bottom, lessThanOrEqualTo(row.bottom + 0.5));
      }
    });
  }

  for (final width in [320.0, 390.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('a phone ${width.round()} pt wide at $scale× text keeps '
          'every pill on screen and clear of its writing', (tester) async {
        AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
        addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
        // Tall enough that every line is laid out at the larger size.
        tester.view.physicalSize = Size(width, 2400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        const body =
            'Trip\n'
            'Flights for the two of us to Lisbon in October = 2 * 1147.50 eur\n'
            'hotel = 9 * 128 eur\n'
            'week 44 2026\n'
            'total';
        await tester.pumpWidget(
          harness(body, keepResultRoom: true, platform: TargetPlatform.iOS),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        final editable = NoteDriver(tester);
        final writing = [
          for (final box in editable.boxesFor(
            TextSelection(
              baseOffset: body.indexOf('\n') + 1,
              extentOffset: body.length,
            ),
          ))
            if (box.right > box.left)
              Rect.fromPoints(
                editable.toGlobal(Offset(box.left, box.top)),
                editable.toGlobal(Offset(box.right, box.bottom)),
              ),
        ];
        final pills = find.descendant(
          of: find.byType(ResultChip),
          matching: find.byType(AnimatedContainer),
        );
        expect(pills, findsNWidgets(4));
        for (final element in pills.evaluate()) {
          final rect = tester.getRect(find.byWidget(element.widget));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(width));
          for (final words in writing) {
            final beside =
                words.bottom > rect.top + 1 && words.top < rect.bottom - 1;
            if (beside) {
              expect(
                words.right,
                lessThanOrEqualTo(rect.left),
                reason: 'a pill covers the writing at $words',
              );
            }
          }
        }
        for (final paragraph in tester.renderObjectList<RenderParagraph>(
          find.descendant(
            of: find.byType(ResultChip),
            matching: find.byType(RichText),
          ),
        )) {
          expect(paragraph.didExceedMaxLines, isFalse);
        }
        // The writing wraps between words, never inside a word or a number.
        for (final word in ['October', '1147.50', 'hotel']) {
          final start = body.indexOf(word);
          final rows = editable
              .boxesFor(
                TextSelection(
                  baseOffset: start,
                  extentOffset: start + word.length,
                ),
              )
              .map((box) => box.top.round())
              .toSet();
          expect(rows, hasLength(1), reason: '"$word" breaks across rows');
        }
      });
    }
  }

  testWidgets('writing that would take two rows beside its phone pill runs '
      'the full width with the pill under it', (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(320, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const body = 'Trip\nHotel: 9 nights * 128 eur';
    await tester.pumpWidget(
      harness(body, keepResultRoom: true, platform: TargetPlatform.iOS),
    );
    await tester.pumpAndSettle();

    final editable = NoteDriver(tester);
    final rows = editable
        .boxesFor(
          TextSelection(
            baseOffset: body.indexOf('\n') + 1,
            extentOffset: body.length,
          ),
        )
        .map((box) => box.top.round())
        .toSet();
    expect(rows, hasLength(1), reason: 'the writing runs the full width');
    final pill = tester.getRect(
      find.descendant(
        of: chipWithText('1,152.00 EUR'),
        matching: find.byType(AnimatedContainer),
      ),
    );
    expect(
      pill.top,
      greaterThanOrEqualTo(lineRect(tester, body, 1).bottom - 0.5),
    );
  });

  testWidgets('a tap on the writing just above a phone pill under it puts '
      'the caret there and copies nothing', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final copied = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    const body =
        'Trip\n'
        'Flights for the two of us to Lisbon in October and the trains = '
        '2 * 1147.50 eur';
    await tester.pumpWidget(harness(body, keepResultRoom: true));
    await tester.pumpAndSettle();

    final chip = chipWithText('2,295.00 EUR');
    final target = tester.getRect(chip);
    final pill = tester.getRect(
      find.descendant(of: chip, matching: find.byType(AnimatedContainer)),
    );
    final editable = NoteDriver(tester);
    final words = [
      for (final box in editable.boxesFor(
        TextSelection(
          baseOffset: body.indexOf('\n') + 1,
          extentOffset: body.length,
        ),
      ))
        if (box.right > box.left)
          Rect.fromPoints(
            editable.toGlobal(Offset(box.left, box.top)),
            editable.toGlobal(Offset(box.right, box.bottom)),
          ),
    ];
    final last = words.reduce((a, b) => a.bottom >= b.bottom ? a : b);
    expect(pill.top, greaterThanOrEqualTo(last.bottom - 0.5));
    // The 44 pt target reaches up into the writing's last row.
    expect(target.top, lessThan(last.bottom - 2));
    expect(last.right, greaterThan(target.left + 4));

    // The pill itself still copies.
    await tester.tapAt(pill.center);
    await tester.pump(const Duration(seconds: 3));
    expect(copied, hasLength(1));

    final at = Offset(
      (target.left + math.min(last.right, target.right)) / 2,
      last.bottom - 2,
    );
    await tester.tapAt(at);
    await tester.pump(const Duration(seconds: 3));
    expect(copied, hasLength(1), reason: 'the tap on the writing copied');
    expect(
      editable.value.selection.extentOffset,
      greaterThan(body.indexOf('\n')),
      reason: 'the caret is on the calculation',
    );
    await tester.pumpAndSettle();
  });

  testWidgets('a phone result takes a tap only inside its own line', (
    tester,
  ) async {
    final copied = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    const body = 'Sums\n1 + 1\n2 + 2\n3 + 3';
    await tester.pumpWidget(harness(body, keepResultRoom: true));
    await tester.pumpAndSettle();

    final target = tester.getRect(chipWithText('4'));
    final line = lineRect(tester, body, 2);
    // The 44 pt target is taller than its line, so it reaches into the
    // lines on either side of it.
    expect(target.height, greaterThanOrEqualTo(44));
    expect(target.top, lessThan(line.top));
    expect(target.bottom, greaterThan(line.bottom));

    for (final y in [target.top + 1, line.top - 1, line.bottom + 1]) {
      await tester.tapAt(Offset(target.center.dx, y));
      await tester.pump(const Duration(seconds: 3));
    }
    expect(copied, isNot(contains('4')));

    await tester.tapAt(Offset(target.center.dx, line.center.dy));
    await tester.pump(const Duration(seconds: 3));
    expect(copied.last, '4');
    await tester.pumpAndSettle();
  });

  testWidgets('a phone shows a long week result whole (KAP-143)', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      harness('Phrases\nweek 44 2026', keepResultRoom: true),
    );
    await tester.pumpAndSettle();

    final result = find.descendant(
      of: find.byType(ResultChip),
      matching: find.byType(RichText),
    );
    expect(
      tester.widget<RichText>(result).text.toPlainText(),
      startsWith('Oct 26'),
    );
    expect(
      tester.renderObject<RenderParagraph>(result).didExceedMaxLines,
      isFalse,
    );
  });

  for (final scale in [1.0, 1.3, 2.0, 3.1]) {
    testWidgets('a phone title at $scale× text gets no answer, keeps its last '
        'letter the size of the rest, and its meta row clear of it', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      const body = 'Today\nFollow up on the launch checklist\n2 + 2';
      await tester.pumpWidget(harness(body));
      await tester.pumpAndSettle();

      final editable = NoteDriver(tester);
      final y = editable
          .boxesFor(const TextSelection(baseOffset: 4, extentOffset: 5))
          .single;
      final letter = Rect.fromPoints(
        editable.toGlobal(Offset(y.left, y.top)),
        editable.toGlobal(Offset(y.right, y.bottom)),
      );
      final a = editable
          .boxesFor(const TextSelection(baseOffset: 3, extentOffset: 4))
          .single;
      final aTop = editable.toGlobal(Offset(a.left, a.top)).dy;
      final aBottom = editable.toGlobal(Offset(a.left, a.bottom)).dy;
      final aHeight = aBottom - aTop;
      final t = editable
          .boxesFor(const TextSelection(baseOffset: 0, extentOffset: 1))
          .single;
      // "Today" names the note: it is not worked out into a date, so no
      // answer takes room from the title and it stays on one line.
      expect(find.byType(ResultChip), findsOneWidget);
      expect(chipWithText('4'), findsOneWidget);
      expect(editable.toGlobal(Offset(t.left, t.top)).dy, closeTo(aTop, 1));
      // Drawn as the rest of the title is, not as a placeholder of its own.
      expect(letter.height, closeTo(aHeight, 0.5));
      expect(letter.center.dy, closeTo((aTop + aBottom) / 2, aHeight * 0.3));

      // The meta row sits under the title, and its words are not cut down
      // to a fixed row.
      final edited = find.byKey(const ValueKey('note-edited'));
      final editedRect = tester.getRect(edited);
      expect(editedRect.top, greaterThanOrEqualTo(letter.bottom - 1));
      expect(editedRect.height, greaterThan(16 * scale * 0.9));
      final facts = tester.getRect(find.byKey(const ValueKey('note-facts')));
      expect(facts.bottom, greaterThanOrEqualTo(editedRect.bottom));
      // The facts wrap within the screen rather than running off it, and
      // stay above the note's first line.
      final total = tester.getRect(find.byKey(const ValueKey('note-total')));
      final follow = editable
          .boxesFor(const TextSelection(baseOffset: 6, extentOffset: 7))
          .single;
      final followTop = editable.toGlobal(Offset(follow.left, follow.top)).dy;
      expect(total.right, lessThanOrEqualTo(393));
      expect(facts.bottom, lessThanOrEqualTo(followTop));
      // A wrapped fact takes its separator with it, so no line holds a dot
      // alone.
      expect(facts.height, lessThanOrEqualTo(editedRect.height * 2 + 1));
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [320.0, 390.0]) {
    for (final scale in [1.0, 1.5, 2.0]) {
      for (final brightness in Brightness.values) {
        testWidgets('a phone title at ${width.round()} pt and $scale× text '
            'breaks only between words in ${brightness.name} (KAP-450)', (
          tester,
        ) async {
          AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
          addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
          tester.view.physicalSize = Size(width, 2400);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          const title = 'Lisbon trip budget';
          await tester.pumpWidget(
            harness(
              '$title\nBody',
              phone: true,
              platform: TargetPlatform.iOS,
              brightness: brightness,
              writingFont: WritingFont.handwritten,
            ),
          );
          await tester.pumpAndSettle();

          final editable = NoteDriver(tester);
          for (final match in RegExp(r'\S+').allMatches(title)) {
            final rows = editable
                .boxesFor(
                  TextSelection(
                    baseOffset: match.start,
                    extentOffset: match.end,
                  ),
                )
                .map((box) => box.top.round())
                .toSet();
            expect(
              rows,
              hasLength(1),
              reason: '"${match.group(0)}" breaks across rows',
            );
          }
        });
      }
    }
  }

  for (final width in [320.0, 390.0]) {
    for (final scale in [1.0, 1.5, 2.0]) {
      testWidgets(
        'a phone header Total at ${width.round()} pt and $scale× text '
        'fits the line or wraps, and the other facts stay (KAP-449)',
        (tester) async {
          AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
          addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
          tester.view.physicalSize = Size(width, 2400);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          await tester.pumpWidget(
            harness(
              'Flat move\n- [ ] sign\n- [x] keys\ndeposit = 2000000 eur\n'
              'rent: 1200000\nfood: 300\nboxes = 4 kg',
              phone: true,
              platform: TargetPlatform.iOS,
              markdown: true,
            ),
          );
          await tester.pumpAndSettle();

          expect(tester.takeException(), isNull);
          for (final key in ['note-edited', 'note-progress', 'note-total']) {
            final rect = tester.getRect(find.byKey(ValueKey(key)));
            expect(rect.width, greaterThan(0), reason: '$key is shown');
            expect(rect.left, greaterThanOrEqualTo(0), reason: key);
            expect(rect.right, lessThanOrEqualTo(width), reason: key);
          }
          final total = tester.widget<Text>(
            find.byKey(const ValueKey('note-total')),
          );
          expect(total.textSpan!.toPlainText(), startsWith('Total: 3,'));
          final mark =
              tester
                      .widget<DecoratedBox>(
                        find
                            .ancestor(
                              of: find.byKey(const ValueKey('note-total')),
                              matching: find.byType(DecoratedBox),
                            )
                            .first,
                      )
                      .decoration
                  as DashedOutline;
          final line = tester.getRect(
            find.byKey(const ValueKey('note-edited')),
          );
          if (width == 320 && scale == 2) {
            expect(
              tester.getSize(find.byKey(const ValueKey('note-total'))).height,
              greaterThan(line.height * 1.5),
              reason: 'the Total wraps here',
            );
          }
          expect(
            mark.radius,
            closeTo(line.height / 2 + 3, 1),
            reason: 'round ends one line tall, wrapped or not',
          );
        },
      );
    }
  }

  testWidgets('a title typed into an empty note keeps the room under it, '
      'and the line below stays put as it wraps (KAP-450)', (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(320, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(harness('', phone: true, autofocus: true));
    await tester.pumpAndSettle();

    Future<double> gap(String text) async {
      await tester.enterNote('$text\nBody');
      await tester.pumpAndSettle();
      const body = 'Body';
      final editable = NoteDriver(tester);
      final start = editable.value.text.indexOf(body);
      final box = editable
          .boxesFor(TextSelection(baseOffset: start, extentOffset: start + 4))
          .first;
      final titleEnd = editable
          .boxesFor(TextSelection(baseOffset: 0, extentOffset: text.length))
          .map((box) => box.bottom)
          .reduce(math.max);
      return box.top - titleEnd;
    }

    final oneLetter = await gap('L');
    final oneRow = await gap('Lisbon');
    final wrapped = await gap('Lisbon trip budget');
    // Room for the meta row, at twice the text size.
    expect(
      oneLetter,
      greaterThanOrEqualTo(
        2 *
            (EditorMetrics.metaGap +
                EditorMetrics.metaBottom +
                EditorMetrics.phoneMetaRow),
      ),
    );
    expect(oneRow, closeTo(oneLetter, 0.5));
    expect(wrapped, closeTo(oneLetter, 0.5));
  });

  testWidgets('a phone keeps room for a result at each text size', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const body =
        'Trip\nFlights for the two of us to Lisbon in October = 2 * 1147.50 eur';
    await tester.pumpWidget(harness(body, keepResultRoom: true));
    await tester.pumpAndSettle();

    // The same result, measured once already, at a larger size.
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();

    final pill = tester.getRect(
      find.descendant(
        of: chipWithText('2,295.00 EUR'),
        matching: find.byType(AnimatedContainer),
      ),
    );
    final editable = NoteDriver(tester);
    final calculation = editable.boxesFor(
      TextSelection(
        baseOffset: body.indexOf('\n') + 1,
        extentOffset: body.length,
      ),
    );
    for (final box in calculation) {
      final words = Rect.fromPoints(
        editable.toGlobal(Offset(box.left, box.top)),
        editable.toGlobal(Offset(box.right, box.bottom)),
      );
      expect(
        words.right <= pill.left || words.bottom <= pill.top,
        isTrue,
        reason: 'the pill covers the writing at $words',
      );
    }
  });

  testWidgets('on a 390 pt phone, prose reaches the right margin, and a '
      'calculation too long to sit beside its result runs the full width '
      'with the result whole under it', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const body =
        'We walked along the river until the light went and the cafes '
        'began to close one after another\n'
        'Flights for the two of us to Lisbon in October = 2 * 1147.50 eur';
    await tester.pumpWidget(harness(body, keepResultRoom: true));
    await tester.pumpAndSettle();

    final editable = NoteDriver(tester);
    final columnRight =
        editable.toGlobal(Offset.zero).dx + editable.columnWidth;
    final prose = NoteDriver(
      tester,
    ).boxesFor(TextSelection(baseOffset: 0, extentOffset: body.indexOf('\n')));
    final proseRight = prose
        .map((box) => box.right)
        .fold(0.0, (a, b) => a > b ? a : b);
    expect(
      editable.toGlobal(Offset(proseRight, 0)).dx,
      greaterThan(columnRight - 40),
      reason: 'a line without a result keeps the full writing width',
    );

    final chip = chipWithText('2,295.00 EUR');
    expect(chip, findsOneWidget);
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(of: chip, matching: find.byType(RichText)),
    );
    expect(paragraph.didExceedMaxLines, isFalse);
    final pill = tester.getRect(
      find.descendant(of: chip, matching: find.byType(AnimatedContainer)),
    );
    expect(pill.right, closeTo(columnRight, 1));

    final calculation = NoteDriver(tester).boxesFor(
      TextSelection(
        baseOffset: body.indexOf('\n') + 1,
        extentOffset: body.length,
      ),
    );
    final writingRight = calculation
        .map((box) => editable.toGlobal(Offset(box.right, 0)).dx)
        .reduce(math.max);
    final writingBottom = calculation
        .map((box) => editable.toGlobal(Offset(0, box.bottom)).dy)
        .reduce(math.max);
    expect(
      writingRight,
      greaterThan(pill.left),
      reason: 'the calculation keeps the full width',
    );
    expect(
      pill.top,
      greaterThanOrEqualTo(writingBottom),
      reason: 'its result sits under it',
    );
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

    await tester.drag(noteField, const Offset(0, -120));
    await tester.pumpAndSettle();

    final after = tester.getRect(chipWithText('100')).center.dy;
    final lineAfter = lineRect(tester, body, 9).center.dy;
    expect(after, lessThan(before), reason: 'the note should have scrolled');
    expect(after, closeTo(lineAfter, 1.5));
  });

  testWidgets('keeps clean-font results aligned after focusing at the end', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(500, 471);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const body = '''
Lisbon trip budget

Flights for two
flights = 412 eur
flights to usd

Hotel: 7 nights
nightly = 128 eur
nightly * 7

Food and getting around // rough guess
daily = 55 eur
daily * 7

total
total to usd''';

    await tester.pumpWidget(
      harness(
        body,
        writingFont: WritingFont.clean,
        startAtEnd: true,
        autofocus: true,
      ),
    );
    await tester.pumpAndSettle();

    final field = tester.widget<NoteField>(noteField);
    expect(field.controller.text, '$body\n\n');
    final scroll = field.scrollController;
    expect(scroll.offset, greaterThan(0));
    for (final entry in {
      4: '479.07 USD',
      8: '896.00 EUR',
      12: '385.00 EUR',
    }.entries) {
      expect(
        tester.getRect(chipWithText(entry.value)).center.dy,
        closeTo(lineRect(tester, body, entry.key).center.dy, 1.5),
        reason: 'chip "${entry.value}" should sit on line ${entry.key}',
      );
    }
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

    final field = tester.widget<NoteField>(noteField);
    expect(field.focusNode.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
    final scrollBefore = field.scrollController.offset;
    expect(scrollBefore, greaterThan(0));

    // The app opens at the end ready to type. Pulling the page down moves
    // towards the earlier writing while making the whole viewport available.
    await tester.drag(noteField, const Offset(0, 140));
    await tester.pumpAndSettle();

    expect(field.focusNode.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
    expect(field.scrollController.offset, lessThan(scrollBefore));
  });

  testWidgets('keeps the header Total amount with its currency code, and '
      'copies a result with a plain space (KAP-449)', (tester) async {
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
    await tester.pumpWidget(harness('Flat\n5000 eur\nrent: 1200'));
    await tester.pumpAndSettle();

    final chip = chipWithText('5,000.00 EUR');
    expect(chip, findsOneWidget);
    final result = tester.widget<ResultChip>(chip).result;
    expect(result.text, '5,000.00 EUR');
    expect(result.copyText, isNot(contains('\u00A0')));
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('note-total')))
          .textSpan!
          .toPlainText(),
      'Total: 6,200.00\u00A0EUR',
    );

    await tester.tap(chip);
    await tester.pump();
    expect(copied, [result.copyText]);
    expect(copied.single, isNot(contains('\u00A0')));
    expect(find.textContaining('Copied'), findsOneWidget);
    expect(find.text('Copied ${result.copyText}'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 2));
  });

  testWidgets('recalculates as the user types', (tester) async {
    await tester.pumpWidget(harness('Sums\n2 + 2'));
    await tester.pumpAndSettle();
    expect(chipWithText('4'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('note-total')))
          .textSpan!
          .toPlainText(),
      'Total: 4',
    );

    await tester.enterNote('Sums\n2 + 2\n40 + 2');
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

  for (final (device, size, platform) in const [
    ('desktop', Size(1000, 700), TargetPlatform.macOS),
    ('phone', Size(390, 844), TargetPlatform.iOS),
  ]) {
    Future<void> pumpAt(WidgetTester tester, String body) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      AppPlatform.debugTargetPlatformOverride = platform;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      await tester.pumpWidget(
        harness(body, platform: platform, phone: device == 'phone'),
      );
      await tester.pumpAndSettle();
    }

    String headerTotal(WidgetTester tester) => tester
        .widget<Text>(find.byKey(const ValueKey('note-total')))
        .textSpan!
        .toPlainText();

    Decoration headerMark(WidgetTester tester) => tester
        .widget<DecoratedBox>(
          find
              .ancestor(
                of: find.byKey(const ValueKey('note-total')),
                matching: find.byType(DecoratedBox),
              )
              .first,
        )
        .decoration;

    CountNote? countOn(WidgetTester tester, String text) =>
        tester.widget<ResultChip>(chipWithText(text)).result.count;

    testWidgets('counts plain numbers in a money total, on a $device', (
      tester,
    ) async {
      await pumpAt(tester, 'Flat\n5000 eur\nrent: 1200\nfood: 300');
      expect(headerTotal(tester), 'Total: 6,500.00\u00A0EUR');
      expect(headerMark(tester), isNot(isA<DashedOutline>()));
      expect(countOn(tester, '1,200'), isNull, reason: 'rent is counted');
      expect(countOn(tester, '300'), isNull, reason: 'food is counted');

      await tester.enterNote('Flat\n5000 eur\nrent 1200\nfood 300\ntotal');
      await tester.pumpAndSettle();
      expect(chipWithText('1,200'), findsOneWidget, reason: 'rent 1200');
      expect(chipWithText('300'), findsOneWidget, reason: 'food 300');
      expect(chipWithText('6,500.00 EUR'), findsOneWidget);
      expect(countOn(tester, '6,500.00 EUR')!.mark, isFalse);
      expect(find.byKey(const ValueKey('note-total')), findsNothing);
    });

    testWidgets('marks a total that leaves a line out, on a $device', (
      tester,
    ) async {
      await pumpAt(tester, 'Flat\n5000 eur\nrent: 1200\nboxes = 4 kg');
      expect(headerTotal(tester), 'Total: 6,200.00\u00A0EUR');
      expect(headerMark(tester), isA<DashedOutline>());
      expect(countOn(tester, '4 kg')!.mark, isTrue);

      await tester.enterNote('Flat\n5000 eur\nrent: 1200\nboxes = 4 kg\ntotal');
      await tester.pumpAndSettle();
      expect(countOn(tester, '6,200.00 EUR')!.mark, isTrue);
      final box = tester.widget<AnimatedContainer>(
        find.descendant(
          of: chipWithText('6,200.00 EUR'),
          matching: find.byType(AnimatedContainer),
        ),
      );
      final fill = (box.decoration! as BoxDecoration).borderRadius!;
      final dash = box.foregroundDecoration! as DashedOutline;
      expect(dash.outset, 3);
      expect(
        dash.radius,
        (fill as BorderRadius).topLeft.x + 3,
        reason: 'the dash rings the fill',
      );
    });

    testWidgets('leaves sentences above a total without a result, on a '
        '$device', (tester) async {
      await pumpAt(
        tester,
        'Plan\nMeeting at 3\nChapter 12\nNov 27\nrent 100\ntotal',
      );
      expect(find.byType(ResultChip), findsNWidgets(2));
      expect(chipWithText('100'), findsNWidgets(2));
    });
  }

  testWidgets('writes the total hover only once the total is hovered', (
    tester,
  ) async {
    await tester.pumpWidget(harness('Budget\nrent = 1200\nfood = 300'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('2 amounts\nrent 1,200, food 300'), findsNothing);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('note-total'))),
    );
    await tester.pump();
    await tester.pumpAndSettle(const Duration(seconds: 2));

    expect(find.byTooltip('2 amounts\nrent 1,200, food 300'), findsOneWidget);
  });

  testWidgets('keeps the total hover current while the note is typed in', (
    tester,
  ) async {
    await tester.pumpWidget(harness('Budget\nrent = 1200\nfood = 300'));
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('note-total'))),
    );
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(find.byTooltip('2 amounts\nrent 1,200, food 300'), findsOneWidget);

    await tester.enterNote('Budget\nrent = 1200\nfood = 300\nfun = 50');
    await tester.pumpAndSettle(const Duration(seconds: 2));

    expect(find.byTooltip('Total'), findsNothing);
    expect(
      find.byTooltip('3 amounts\nrent 1,200, food 300, fun 50'),
      findsOneWidget,
    );
  });

  testWidgets('long-pressing the total on a phone shows its capped hover', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final body = [
      'Budget',
      for (var i = 1; i <= 25; i++) 'a$i = $i',
    ].join('\n');
    await tester.pumpWidget(harness(body));
    await tester.pumpAndSettle();
    final total = find.byKey(const ValueKey('note-total'));
    final tooltip = find.ancestor(of: total, matching: find.byType(Tooltip));
    expect(tester.widget<Tooltip>(tooltip).message, 'Total');

    await tester.longPress(total);
    await tester.pump(const Duration(milliseconds: 100));

    final shown = tester.widget<Tooltip>(tooltip).message!;
    expect(shown, startsWith('25 amounts\n'));
    expect(shown, contains('a20 20, and 5 more'));
    expect(
      find.text(shown, findRichText: true),
      findsOneWidget,
      reason: 'the overlay is up',
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('hides the running total until the note has a calculation', (
    tester,
  ) async {
    await tester.pumpWidget(harness('Groceries for the weekend'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('note-total')), findsNothing);

    await tester.enterNote('Groceries for the weekend\n12 + 30');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('note-total')))
          .textSpan!
          .toPlainText(),
      'Total: 42',
    );
  });

  testWidgets('a variable the title sets works below it, while the title '
      'shows no answer and adds nothing to the total', (tester) async {
    await tester.pumpWidget(harness('rent = 1200\nrent * 12'));
    await tester.pumpAndSettle();

    expect(find.byType(ResultChip), findsOneWidget);
    expect(chipWithText('14,400'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('note-total')))
          .textSpan!
          .toPlainText(),
      'Total: 14,400',
    );
  });

  testWidgets('carries a variable down to later lines', (tester) async {
    await tester.pumpWidget(harness('Order\nsubtotal = 42\nsubtotal * 3'));
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
    expect(heading.style!.fontWeight, FontWeight.w600);
    expect(subtitle.style!.fontStyle, FontStyle.italic);
    expect(find.byKey(const ValueKey('note-total')), findsNothing);

    await tester.enterNote('Sums\n1');
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

    final field = tester.widget<NoteField>(noteField);
    expect(field.controller.text, 'Yesterday\n\n');
    expect(field.controller.selection.baseOffset, 'Yesterday\n\n'.length);
    expect(changes, isEmpty);
    expect(field.controller.text, isNot(contains('// ─')));
  });

  testWidgets("off a phone the meta line keeps the note's last edit, not the "
      'time it was written (D01)', (tester) async {
    await tester.pumpWidget(
      harness(
        'Plan\nCall Ana',
        createdAt: DateTime(2026, 9, 1, 8, 55),
        lastUpdatedAt: DateTime(2026, 9, 1, 9, 30),
        now: () => DateTime(2026, 9, 1, 10),
      ),
    );
    await tester.pumpAndSettle();
    final line = tester
        .widget<Text>(find.byKey(const ValueKey('note-edited')))
        .data!;
    expect(line, contains('9:30'));
    expect(line, isNot(contains('8:55')));
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

    final field = tester.widget<NoteField>(noteField);
    expect(field.controller.text, 'Earlier today\n\n');

    await tester.enterNote('Earlier today\n\nMore');
    await tester.pumpAndSettle();
    expect(field.controller.text, 'Earlier today\n\nMore');
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

    final field = tester.widget<NoteField>(noteField);
    expect(field.controller.text, 'Yesterday\n\n');

    await tester.enterNote('Yesterday\n\nT');
    await tester.pumpAndSettle();

    expect(field.controller.text, 'Yesterday\n\n// ─ 1 Sep · 21:42 ─\nT');
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

    await tester.enterNote('Late entry\n\nN');
    await tester.pumpAndSettle();

    final field = tester.widget<NoteField>(noteField);
    expect(field.controller.text, 'Late entry\n\n// ─ 1 Sep · 23:30 ─\nN');
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

    await tester.enterNote('Last entry\n\nBack again');
    await tester.pumpAndSettle();

    final text = tester.widget<NoteField>(noteField).controller.text;
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

    final field = tester.widget<NoteField>(noteField);
    expect(field.controller.text, 'Ideas\n\n');
    expect(changes, isEmpty);

    await tester.enterNote('Ideas\n\nNext idea');
    await tester.pumpAndSettle();

    expect(field.controller.text, 'Ideas\n\n// ─ 1 Sep · 21:42 ─\nNext idea');
    expect(changes.single, field.controller.text);
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
      return tester.state<NoteFieldState>(noteField).widget.focusNode;
    }

    Future<void> setKeyboard(WidgetTester tester, double height) async {
      tester.view.viewInsets = height > 0
          ? FakeViewPadding(bottom: height)
          : FakeViewPadding.zero;
      await tester.pump();
    }

    testWidgets(
      'the bar pins keyboard dismissal outside its scrolling buttons',
      (tester) async {
        AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
        tester.view.physicalSize = const Size(320, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          harness(
            'one\ntwo',
            startAtEnd: true,
            autofocus: true,
            ensureKeyboardVisible: true,
            onRecordVoice: () {},
          ),
        );
        await tester.pump();
        await tester.pump();

        const dismissKey = ValueKey('dismiss-keyboard');
        expect(find.byKey(dismissKey), findsNothing);
        expect(find.byKey(const ValueKey('phone-format-bar')), findsNothing);

        await setKeyboard(tester, 300);
        final dismiss = find.byKey(dismissKey);
        final bar = find.byKey(const ValueKey('phone-format-bar'));
        expect(dismiss, findsOneWidget);
        final pinned = tester.getRect(dismiss);
        expect(pinned.right, closeTo(tester.getRect(bar).right, 0.1));

        final formattingScroll = find.byKey(
          const ValueKey('phone-format-scroll'),
        );
        expect(
          tester
              .widget<SingleChildScrollView>(formattingScroll)
              .scrollDirection,
          Axis.horizontal,
        );
        final scrollable = find.descendant(
          of: formattingScroll,
          matching: find.byType(Scrollable),
        );
        expect(
          tester.state<ScrollableState>(scrollable).position.maxScrollExtent,
          greaterThan(0),
        );
        expect(tester.getRect(dismiss), pinned);

        await tester.drag(formattingScroll, const Offset(-100, 0));
        await tester.pumpAndSettle();
        expect(tester.getRect(dismiss), pinned);

        final focus = tester.widget<NoteField>(noteField).focusNode;
        expect(focus.hasFocus, isTrue);
        tester.testTextInput.log.clear();
        await tester.tap(dismiss);
        await tester.pump();

        expect(focus.hasFocus, isFalse);
        expect(tester.testTextInput.isVisible, isFalse);
        expect(
          tester.testTextInput.log.map((call) => call.method),
          contains('TextInput.hide'),
        );

        await setKeyboard(tester, 0);
        expect(find.byKey(dismissKey), findsNothing);
      },
    );

    testWidgets('the editor lets go, so the keyboard stays down', (
      tester,
    ) async {
      final node = await pumpFocused(tester);
      await setKeyboard(tester, 300);
      // Up and still: a keyboard that is still moving is still coming up.
      await tester.pump(const Duration(seconds: 1));
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

    // A note opened just as the last one's keyboard finished going down (CI,
    // Android, run 44913238799): the new keyboard came up, read zero for a
    // moment while Android restarted its animation, and came back. Read as a
    // dismissal, that moment took the focus, so the bar went and the keyboard
    // was left up with nothing to type into.
    testWidgets('a keyboard that blinks out while coming up keeps the note', (
      tester,
    ) async {
      final node = await pumpFocused(tester);
      await setKeyboard(tester, 300);

      tester.testTextInput.log.clear();
      await setKeyboard(tester, 0);
      await tester.pump(const Duration(milliseconds: 200));
      await setKeyboard(tester, 300);
      await tester.pump(const Duration(seconds: 4));

      expect(node.hasFocus, isTrue);
      expect(find.byKey(const ValueKey('phone-format-bar')), findsOneWidget);
      expect(
        tester.testTextInput.log.map((call) => call.method),
        isNot(contains('TextInput.hide')),
      );
    });

    // A slow phone (CI, Android, runs 45992261717 and 46042569829): Android
    // started the keyboard's slide, called it off and started it again from
    // the bottom, and the second slide reached the app only after more than
    // half a second. Read as a dismissal, the zero in between took the focus,
    // and that put the keyboard away just after it opened (KAP-324).
    testWidgets('a keyboard that slides in slowly keeps the note', (
      tester,
    ) async {
      final node = await pumpFocused(tester);
      tester.testTextInput.log.clear();
      for (final height in [40.0, 120.0]) {
        await setKeyboard(tester, height);
        await tester.pump(const Duration(milliseconds: 100));
      }
      await setKeyboard(tester, 0);
      await tester.pump(const Duration(milliseconds: 800));
      for (final height in [60.0, 300.0, 600.0, 883.0]) {
        await setKeyboard(tester, height);
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump(const Duration(seconds: 4));

      expect(node.hasFocus, isTrue);
      expect(find.byKey(const ValueKey('phone-format-bar')), findsOneWidget);
      expect(
        tester.testTextInput.log.map((call) => call.method),
        isNot(contains('TextInput.hide')),
      );
    });

    // The editor lets go only once the keyboard has stayed down, so by then
    // the reader may have moved on to another field. That one keeps it.
    testWidgets('a field that takes the focus after Back keeps it', (
      tester,
    ) async {
      final node = await pumpFocused(tester);
      await setKeyboard(tester, 300);
      await tester.pump(const Duration(seconds: 1));
      await setKeyboard(tester, 0);
      await tester.pump(const Duration(milliseconds: 200));

      final other = FocusNode(debugLabel: 'other');
      final entry = OverlayEntry(
        builder: (_) => Focus(focusNode: other, child: const SizedBox()),
      );
      tester.state<OverlayState>(find.byType(Overlay).first).insert(entry);
      await tester.pump();
      other.requestFocus();
      await tester.pump();
      expect(other.hasPrimaryFocus, isTrue);
      expect(node.hasFocus, isFalse);

      await tester.pump(const Duration(seconds: 4));
      final kept = other.hasPrimaryFocus;
      entry.remove();
      await tester.pump();
      entry.dispose();
      other.dispose();
      expect(kept, isTrue);
    });

    // CI, Android, run 45220012622: the startup retry asked again 20 ms after
    // the field's own request, before the IME had moved the window. Android
    // cancelled the animation it had started and left the inset at zero under
    // a keyboard that was up, so the bar went (KAP-324).
    testWidgets(
      'the startup request gives the IME time to start before asking again',
      (tester) async {
        await pumpFocused(tester);
        tester.testTextInput.log.clear();
        await tester.pump(const Duration(milliseconds: 350));
        expect(
          tester.testTextInput.log.map((call) => call.method),
          isNot(contains('TextInput.show')),
        );
      },
    );

    testWidgets(
      'a request the IME is answering is not repeated, and one it ignored is',
      (tester) async {
        await pumpFocused(tester);
        tester.testTextInput.log.clear();
        // The IME starts its animation: the window moves, still at zero.
        await tester.pump(const Duration(milliseconds: 100));
        tester.binding.handleMetricsChanged();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          tester.testTextInput.log.map((call) => call.method),
          isNot(contains('TextInput.show')),
        );
        // Nothing more comes of it: the window stays still, so it asks again.
        await tester.pump(const Duration(milliseconds: 250));
        expect(
          tester.testTextInput.log.map((call) => call.method),
          contains('TextInput.show'),
        );
      },
    );

    testWidgets(
      'a window that moved before the note asked still gets asked again',
      (tester) async {
        AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          harness('one\ntwo', ensureKeyboardVisible: true),
        );
        // A page sliding in, or the last field's keyboard going down.
        tester.binding.handleMetricsChanged();
        tester.state<NoteEditorState>(find.byType(NoteEditor)).focus();
        await tester.pump();
        tester.testTextInput.log.clear();
        await tester.pump(const Duration(milliseconds: 450));
        expect(
          tester.testTextInput.log.map((call) => call.method),
          contains('TextInput.show'),
        );
      },
    );

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
      await tester.pump(const Duration(seconds: 1));

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

    await tester.pumpWidget(harness('Thirds\n2 / 3'));
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
    await tester.pumpWidget(harness('Big\n12345678'));
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

  group('the edit menu on a phone', () {
    // Selected text on a phone has to show Copy where a phone shows it, and a
    // tap into a note has to offer Paste. Copy used to wait behind More on a
    // formatting row, and Paste came only from a press-and-hold.
    late List<String> copied;

    setUp(() {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
      copied = [];
    });

    tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

    /// What the phone's clipboard holds; null for nothing at all.
    void clipboardHolds(WidgetTester tester, String? text) {
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        switch (call.method) {
          case 'Clipboard.hasStrings':
            return {'value': text != null};
          case 'Clipboard.getData':
            return text == null ? null : {'text': text};
          case 'Clipboard.setData':
            copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
    }

    /// Past the end of a line's words, where there is nothing.
    Offset besideLine(WidgetTester tester, String body, String lastWord) =>
        _centerOf(tester, body, lastWord) + const Offset(120, 0);

    Future<void> tapAndWait(WidgetTester tester, Offset position) async {
      await tester.tapAt(position);
      // A double tap would select a word instead, so the offer waits one out.
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
    }

    Future<void> selectFirstWord(WidgetTester tester) async {
      final field = tester.widget<NoteField>(noteField);
      field.controller.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 6,
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
    }

    testWidgets(
      'a tap offers Paste and Paste Text when there is text to paste',
      (tester) async {
        tester.view.physicalSize = const Size(360, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        clipboardHolds(tester, 'from elsewhere');
        String? body;
        await tester.pumpWidget(
          harness(
            'First line',
            autofocus: true,
            resultsVisible: false,
            onBodyChanged: (value) => body = value,
          ),
        );
        await tester.pumpAndSettle();

        await tapAndWait(tester, besideLine(tester, 'First line', 'line'));

        final paste = find.text('Paste').hitTestable();
        final pastePlainText = find.text('Paste Text').hitTestable();
        expect(paste, findsOneWidget);
        expect(pastePlainText, findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(TextSelectionToolbarTextButton).first,
            matching: find.text('Paste'),
          ),
          findsOneWidget,
          reason: 'Paste leads, where a phone always has room for it',
        );

        await tester.tap(pastePlainText);
        await tester.pumpAndSettle();
        expect(body, 'First linefrom elsewhere');
      },
    );

    testWidgets('a tap with nothing to paste opens no menu', (tester) async {
      clipboardHolds(tester, null);
      await tester.pumpWidget(
        harness('First line', autofocus: true, resultsVisible: false),
      );
      await tester.pumpAndSettle();

      await tapAndWait(tester, besideLine(tester, 'First line', 'line'));

      expect(find.byType(TextSelectionToolbar), findsNothing);
    });

    testWidgets('a second tap on the caret puts the menu away', (tester) async {
      clipboardHolds(tester, 'from elsewhere');
      await tester.pumpWidget(
        harness('First line', autofocus: true, resultsVisible: false),
      );
      await tester.pumpAndSettle();
      final spot = besideLine(tester, 'First line', 'line');

      await tapAndWait(tester, spot);
      expect(find.text('Paste').hitTestable(), findsOneWidget);

      await tapAndWait(tester, spot);
      expect(find.byType(TextSelectionToolbar), findsNothing);
    });

    testWidgets('a tap that ticks a box offers nothing', (tester) async {
      clipboardHolds(tester, 'from elsewhere');
      const body = '☐ milk';
      String? changed;
      await tester.pumpWidget(
        harness(
          body,
          autofocus: true,
          resultsVisible: false,
          onBodyChanged: (value) => changed = value,
        ),
      );
      await tester.pumpAndSettle();

      await tapAndWait(tester, _centerOf(tester, body, '☐'));

      expect(changed, isNot(body), reason: 'the box was ticked');
      expect(find.byType(TextSelectionToolbar), findsNothing);
    });

    testWidgets('selected text shows Cut, Copy and Paste in the row', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      clipboardHolds(tester, 'from elsewhere');
      await tester.pumpWidget(
        harness('Select this text', autofocus: true, resultsVisible: false),
      );
      await tester.pumpAndSettle();

      await selectFirstWord(tester);

      expect(find.byKey(const ValueKey('selection-bubble')), findsNothing);
      expect(find.text('Cut').hitTestable(), findsOneWidget);
      expect(find.text('Copy').hitTestable(), findsOneWidget);
      expect(find.text('Paste').hitTestable(), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(TextSelectionToolbarTextButton).first,
          matching: find.text('Copy'),
        ),
        findsOneWidget,
        reason: 'Copy is the first action offered for selected text',
      );

      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      expect(copied, ['Select']);
    });

    testWidgets('a narrow iPhone menu keeps Copy first and visible', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      clipboardHolds(tester, 'from elsewhere');
      await tester.pumpWidget(
        harness(
          'Select this text',
          autofocus: true,
          resultsVisible: false,
          platform: TargetPlatform.iOS,
        ),
      );
      await tester.pumpAndSettle();

      await selectFirstWord(tester);

      final menu = tester.widget<NoteEditorContextMenu>(
        find.byType(NoteEditorContextMenu),
      );
      expect(menu.buttonItems.first.type, ContextMenuButtonType.copy);
      expect(find.text('Copy').hitTestable(), findsOneWidget);
    });

    testWidgets('a compact iPhone menu shows both paste choices after a tap', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      tester.view.physicalSize = const Size(375, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      clipboardHolds(tester, 'from elsewhere');
      await tester.pumpWidget(
        harness(
          'First line',
          autofocus: true,
          resultsVisible: false,
          platform: TargetPlatform.iOS,
        ),
      );
      await tester.pumpAndSettle();

      await tapAndWait(tester, besideLine(tester, 'First line', 'line'));

      final menu = tester.widget<NoteEditorContextMenu>(
        find.byType(NoteEditorContextMenu),
      );
      expect(menu.buttonItems.first.type, ContextMenuButtonType.paste);
      expect(menu.buttonItems[1].label, 'Paste Text');
      expect(find.text('Paste').hitTestable(), findsOneWidget);
      expect(find.text('Paste Text').hitTestable(), findsOneWidget);
    });

    testWidgets('formatting a selection is still there, behind More', (
      tester,
    ) async {
      clipboardHolds(tester, null);
      tester.view.physicalSize = const Size(360, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final formats = <List<NoteFormatRange>>[];
      await tester.pumpWidget(
        harness(
          'Select this text',
          autofocus: true,
          resultsVisible: false,
          onFormatsChanged: formats.add,
        ),
      );
      await tester.pumpAndSettle();

      await selectFirstWord(tester);
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bold'));
      await tester.pumpAndSettle();

      expect(formats.last, const [
        NoteFormatRange(start: 0, end: 6, format: NoteFormat.bold),
      ]);
    });
  });

  testWidgets('on its side with the keyboard up, a phone keeps the row it is '
      'typing in sight (KAP-174)', (tester) async {
    tester.view.physicalSize = const Size(852, 393);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    addTearDown(tester.view.reset);
    const body =
        'Trip\nFlights = 2 * 1147.50 eur\nHotels = 4 * 210\nDinners = 3 * 48';
    await tester.pumpWidget(harness(body, keepResultRoom: true));
    await tester.pumpAndSettle();

    // The note stops above the keyboard, so the lines have room at all.
    final field = tester.getRect(noteField);
    expect(field.bottom, lessThanOrEqualTo(393 - 260 + 0.5));
    expect(tester.takeException(), isNull);

    // A tap at the foot of the note leaves that row on screen.
    await tester.tapAt(Offset(field.center.dx, field.bottom - 6));
    await tester.pumpAndSettle();
    final driver = NoteDriver(tester);
    final caret = driver
        .caretRect(driver.value.selection.extent)
        .shift(driver.toGlobal(Offset.zero));
    expect(caret.bottom, lessThanOrEqualTo(field.bottom + 0.5));
    expect(caret.top, greaterThanOrEqualTo(field.top - 0.5));
  });

  group('find in the note', () {
    setUp(() => AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS);
    tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

    final bar = find.byKey(const ValueKey('note-find-bar'));
    final field = find.byKey(const ValueKey('note-find-field'));

    TextEditingController words(WidgetTester tester) =>
        tester.widget<TextField>(field).controller!;

    String? count(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const ValueKey('note-find-count'))).data;

    Future<void> openFind(WidgetTester tester, [String? text]) async {
      tester.state<NoteEditorState>(find.byType(NoteEditor)).openFind();
      await tester.pumpAndSettle();
      if (text == null) return;
      await tester.enterText(field, text);
      await tester.pumpAndSettle();
    }

    Future<void> press(
      WidgetTester tester,
      LogicalKeyboardKey key, {
      bool shift = false,
      bool meta = false,
    }) async {
      if (meta) await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(key);
      if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      if (meta) await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
    }

    testWidgets("finds the words in a table's cells, each cell on its own", (
      tester,
    ) async {
      const body =
          'Gear\n\n| Item | Qty |\n| --- | --- |\n| Stove | 1 |\n'
          '| Tent pegs | 8 |\n\nSpare pegs';
      await tester.pumpWidget(harness(body, autofocus: true, markdown: true));
      await tester.pumpAndSettle();

      await openFind(tester, 'pegs');
      expect(count(tester), '1 of 2');
      final at = body.indexOf('pegs');
      expect(
        NoteDriver(tester).state.layout.marks.found!.ranges.first,
        TextRange(start: at, end: at + 4),
      );

      // The grid's lines are not words, and a match never runs from one
      // cell into the next.
      for (final words in ['pegs8', 'pegs 8', 'pegs | 8']) {
        await tester.enterText(field, words);
        await tester.pumpAndSettle();
        expect(count(tester), 'No matches', reason: words);
      }
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('counts the matches, marks them, and steps through them', (
      tester,
    ) async {
      const body = 'Camping\nPack the tent\nTent pegs\nA tent for two';
      await tester.pumpWidget(harness(body, autofocus: true));
      await tester.pumpAndSettle();

      await openFind(tester, 'tent');
      expect(bar, findsOneWidget);
      expect(count(tester), '1 of 3');
      final found = NoteDriver(tester).state.layout.marks.found!;
      expect(found.ranges, [
        for (final at in [
          body.indexOf('tent'),
          body.indexOf('Tent'),
          body.lastIndexOf('tent'),
        ])
          TextRange(start: at, end: at + 4),
      ]);
      expect(found.current, 0);
      // The match it is on filled as the selection is, which is what esc
      // leaves of it.
      expect(found.currentColor, KapyTheme.darkPalette.selection);
      expect(found.color, isNot(found.currentColor));

      await press(tester, LogicalKeyboardKey.enter);
      expect(count(tester), '2 of 3');
      expect(NoteDriver(tester).state.layout.marks.found!.current, 1);
      await press(tester, LogicalKeyboardKey.enter, shift: true);
      expect(count(tester), '1 of 3');
      await press(tester, LogicalKeyboardKey.enter, shift: true);
      expect(count(tester), '3 of 3');
      await press(tester, LogicalKeyboardKey.f3);
      expect(count(tester), '1 of 3');
      await press(tester, LogicalKeyboardKey.f3, shift: true);
      expect(count(tester), '3 of 3');
      await press(tester, LogicalKeyboardKey.keyG, meta: true);
      expect(count(tester), '1 of 3');
      await press(tester, LogicalKeyboardKey.keyG, meta: true, shift: true);
      expect(count(tester), '3 of 3');
      await tester.tap(find.byKey(const ValueKey('note-find-next')));
      await tester.pumpAndSettle();
      expect(count(tester), '1 of 3');

      // Enter that ends a word an input method is still putting together
      // belongs to the input method.
      final query = words(tester);
      query.value = query.value.copyWith(
        composing: const TextRange(start: 0, end: 4),
      );
      await press(tester, LogicalKeyboardKey.enter);
      expect(count(tester), '1 of 3');

      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
      expect(NoteDriver(tester).value.text, body);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('esc closes it on its match, back in the note', (tester) async {
      const body = 'Camping\nPack the tent\nTent pegs';
      await tester.pumpWidget(harness(body, autofocus: true));
      await tester.pumpAndSettle();
      await openFind(tester, 'tent');
      await press(tester, LogicalKeyboardKey.enter);
      expect(count(tester), '2 of 2');

      await press(tester, LogicalKeyboardKey.escape);
      expect(bar, findsNothing);
      final note = NoteDriver(tester);
      expect(note.state.layout.marks.found, isNull);
      final at = body.indexOf('Tent');
      expect(
        note.value.selection,
        TextSelection(baseOffset: at, extentOffset: at + 4),
      );
      expect(note.state.widget.focusNode.hasFocus, isTrue);
      expect(note.value.text, body);

      // It opens again on the words the note has selected, ready to type
      // over.
      await openFind(tester);
      expect(words(tester).text, 'Tent');
      expect(
        words(tester).selection,
        const TextSelection(baseOffset: 0, extentOffset: 4),
      );
      expect(count(tester), '2 of 2');

      await tester.tap(find.byKey(const ValueKey('note-find-close')));
      await tester.pumpAndSettle();
      expect(bar, findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('the bar pushes the note down, never over what it finds', (
      tester,
    ) async {
      const body = 'Camping\nPack the tent';
      await tester.pumpWidget(harness(body, autofocus: true));
      await tester.pumpAndSettle();
      final note = NoteDriver(tester);
      Rect title() => note
          .caretRect(const TextPosition(offset: 0))
          .shift(note.toGlobal(Offset.zero));
      final closed = title();

      await openFind(tester, 'tent');
      final strip = tester.getRect(bar);
      expect(strip.top, tester.getRect(find.byType(NoteEditor)).top);
      expect(title().top, moreOrLessEquals(closed.top + strip.height));
      expect(title().top, greaterThan(strip.bottom));
      // The words start where the writing does.
      expect(
        tester.getRect(field).left,
        moreOrLessEquals(closed.left, epsilon: 3),
      );

      await press(tester, LogicalKeyboardKey.escape);
      expect(title().top, moreOrLessEquals(closed.top));
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('a selection over more than one line is not what it finds', (
      tester,
    ) async {
      const body = 'Camping\nPack the tent\nTent pegs';
      await tester.pumpWidget(harness(body, autofocus: true));
      await tester.pumpAndSettle();
      final note = NoteDriver(tester);
      note.controller.selection = TextSelection(
        baseOffset: body.indexOf('the'),
        extentOffset: body.indexOf('pegs'),
      );
      await tester.pump();

      await openFind(tester);
      expect(words(tester).text, isEmpty);
      expect(find.byKey(const ValueKey('note-find-count')), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('finds the words the note shows, not its markdown', (
      tester,
    ) async {
      // Bold's stars and the link's brackets and address draw as nothing,
      // so the link's words read as one with the letters after it.
      const body = 'Plans\n**Bold** move, and [bo](https://example.com)ld too';
      await tester.pumpWidget(harness(body, autofocus: true, markdown: true));
      await tester.pumpAndSettle();

      await openFind(tester, 'bold');
      expect(count(tester), '1 of 2');
      expect(
        NoteDriver(tester).state.layout.marks.found!.ranges.last,
        TextRange(
          start: body.indexOf('[bo') + 1,
          end: body.indexOf('ld too') + 2,
        ),
      );

      await tester.enterText(field, 'example');
      await tester.pumpAndSettle();
      expect(count(tester), 'No matches');

      await tester.enterText(field, '**');
      await tester.pumpAndSettle();
      expect(count(tester), 'No matches');
      expect(NoteDriver(tester).state.layout.marks.found, isNull);
      for (final key in ['note-find-next', 'note-find-previous']) {
        final button = tester.widget<CompactIconButton>(
          find.byKey(ValueKey(key)),
        );
        expect(button.onPressed, isNull);
        expect(
          tester
              .widget<KapyIcon>(
                find.descendant(
                  of: find.byKey(ValueKey(key)),
                  matching: find.byType(KapyIcon),
                ),
              )
              .color,
          tester.element(find.byKey(ValueKey(key))).palette.textTertiary,
          reason: key,
        );
      }
      expect(
        tester
            .widget<KapyIcon>(
              find.descendant(
                of: find.byKey(const ValueKey('note-find-close')),
                matching: find.byType(KapyIcon),
              ),
            )
            .color,
        isNull,
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('the count keeps up as the note changes', (tester) async {
      const body = 'Camping\nPack the tent';
      await tester.pumpWidget(harness(body, autofocus: true));
      await tester.pumpAndSettle();
      await openFind(tester, 'tent');
      expect(count(tester), '1 of 1');

      NoteDriver(tester).controller.text = '$body\nA second tent';
      await tester.pumpAndSettle();
      expect(count(tester), '1 of 2');
      expect(NoteDriver(tester).state.layout.marks.found!.ranges, hasLength(2));
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('a match in a table is filled in its cell, and esc leaves it '
        'selected there', (tester) async {
      const body =
          'Gear\n\n| Item | Qty |\n| --- | --- |\n| Tent pegs | 8 |\n\n'
          'Spare pegs';
      await tester.pumpWidget(harness(body, autofocus: true));
      await tester.pumpAndSettle();
      final note = NoteDriver(tester);
      final at = body.indexOf('pegs');

      await openFind(tester, 'pegs');
      expect(count(tester), '1 of 2');
      await press(tester, LogicalKeyboardKey.enter);
      expect(count(tester), '2 of 2');
      // The cell's match is filled where a selection of its words would be,
      // over the words in the cell.
      final lines = note.state.lines;
      final line = lines.lineAt(at);
      final from = at - lines.startOf(line);
      expect(note.state.layout.marks.found!.ranges.first.start, at);
      expect(
        note.state.layout.selectionOf!(
          line,
          TextRange(start: from, end: from + 4),
        ),
        [isA<Rect>().having((rect) => rect.width, 'width', greaterThan(1))],
      );

      await press(tester, LogicalKeyboardKey.enter);
      expect(count(tester), '1 of 2');
      await press(tester, LogicalKeyboardKey.escape);
      expect(bar, findsNothing);
      expect(
        note.value.selection,
        TextSelection(baseOffset: at, extentOffset: at + 4),
      );
      expect(note.value.text, body);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('a match in a table below the page is scrolled into sight', (
      tester,
    ) async {
      final body = [
        'Long',
        for (var line = 0; line < 80; line++) 'line $line',
        '',
        '| Item | Qty |',
        '| --- | --- |',
        '| Tent pegs | 8 |',
      ].join('\n');
      await tester.pumpWidget(harness(body));
      await tester.pumpAndSettle();
      final note = NoteDriver(tester);
      Rect pegs() => note
          .caretRect(TextPosition(offset: body.indexOf('pegs')))
          .shift(note.toGlobal(Offset.zero));
      final page = tester.getRect(find.byType(NoteEditor));
      expect(pegs().top, greaterThan(page.bottom));

      await openFind(tester, 'pegs');
      expect(count(tester), '1 of 1');
      expect(pegs().top, greaterThanOrEqualTo(page.top));
      expect(pegs().bottom, lessThanOrEqualTo(page.bottom));
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('a match below the page is scrolled into sight', (
      tester,
    ) async {
      final body = [
        'Long',
        for (var line = 0; line < 80; line++) 'line $line',
        'the needle',
      ].join('\n');
      await tester.pumpWidget(harness(body));
      await tester.pumpAndSettle();
      final note = NoteDriver(tester);
      Rect needle() => note
          .caretRect(TextPosition(offset: body.indexOf('needle')))
          .shift(note.toGlobal(Offset.zero));
      final page = tester.getRect(find.byType(NoteEditor));
      expect(needle().top, greaterThan(page.bottom));

      await openFind(tester, 'needle');
      expect(count(tester), '1 of 1');
      expect(needle().top, greaterThanOrEqualTo(page.top));
      expect(needle().bottom, lessThanOrEqualTo(page.bottom));
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    // A desktop's click outside a text field takes the keyboard from it,
    // which Android's tap does not, so this one runs as each desktop.
    testWidgets('a click on Next or Previous leaves the keyboard in the bar', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = defaultTargetPlatform;
      const body = 'Camping\nPack the tent\nTent pegs\nA tent for two';
      await tester.pumpWidget(harness(body, autofocus: true));
      await tester.pumpAndSettle();
      await openFind(tester, 'tent');
      expect(count(tester), '1 of 3');

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      for (final (key, after) in [
        ('note-find-next', '2 of 3'),
        ('note-find-previous', '1 of 3'),
      ]) {
        final at = tester.getCenter(find.byKey(ValueKey(key)));
        await mouse.moveTo(at);
        await mouse.down(at);
        await mouse.up();
        await tester.pumpAndSettle();
        expect(count(tester), after, reason: key);
        expect(
          tester.widget<TextField>(field).focusNode!.hasFocus,
          isTrue,
          reason: key,
        );
      }
      await mouse.moveTo(Offset.zero);
      await tester.pumpAndSettle();

      // Enter still steps, and esc still closes it on its match.
      await press(tester, LogicalKeyboardKey.enter);
      expect(count(tester), '2 of 3');
      await press(tester, LogicalKeyboardKey.escape);
      expect(bar, findsNothing);
      final at = body.indexOf('Tent');
      expect(
        NoteDriver(tester).value.selection,
        TextSelection(baseOffset: at, extentOffset: at + 4),
      );
    }, variant: TargetPlatformVariant.desktop());

    testWidgets('phones have no find bar', (tester) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      await tester.pumpWidget(harness('Camping\nPack the tent'));
      await tester.pumpAndSettle();

      tester.state<NoteEditorState>(find.byType(NoteEditor)).openFind();
      await tester.pumpAndSettle();
      expect(bar, findsNothing);
    });
  });
}
