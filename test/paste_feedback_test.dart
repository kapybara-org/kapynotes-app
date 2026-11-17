import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/calc/highlight.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/images/image_clipboard.dart';
import 'package:kapy_notes/paste/clipboard_snapshot.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/editor/note_field.dart';
import 'package:kapy_notes/ui/editor/paste_feedback.dart';
import 'package:material_ui/material_ui.dart';

import 'kapy_icon_finder.dart';
import 'support/note_driver.dart';
import 'test_fonts.dart';

/// Paper's list, copied from a page: its markup, and the plain text the
/// platform gives beside it.
const _html =
    '<h2>Q3 goals</h2><ul><li>Ship the Windows build</li>'
    '<li>Cut onboarding to two screens</li><li>Hire a <b>designer</b></li></ul>';
const _plain =
    'Q3 goals\nShip the Windows build\nCut onboarding to two screens\n'
    'Hire a designer';

class _Clipboard extends ImageClipboard {
  const _Clipboard();

  @override
  Future<ClipboardSnapshot> readSnapshot() async =>
      const ClipboardSnapshot(html: _html, text: _plain);
}

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'paste-feedback-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

late CalcEngine _engine;
late ShortcutPrefs _shortcuts;

final _chip = find.byKey(const ValueKey('paste-chip'));
final _menu = find.byKey(const ValueKey('paste-menu'));

Future<GlobalKey<NoteEditorState>> _pumpEditor(
  WidgetTester tester, {
  String body = '',
  bool markdown = true,
  Brightness brightness = Brightness.dark,
}) async {
  final editor = GlobalKey<NoteEditorState>();
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: brightness == Brightness.dark
          ? KapyTheme.dark()
          : KapyTheme.light(),
      home: Scaffold(
        body: NoteEditor(
          key: editor,
          noteId: 'paste',
          initialBody: body,
          markdownEnabled: markdown,
          clipboard: const _Clipboard(),
          autofocus: true,
          startAtEnd: true,
          now: () => DateTime(2026, 11, 17, 11, 15),
          engine: _engine,
          highlighter: Highlighter(_engine.registry),
          resultsVisible: true,
          writingFont: WritingFont.mixed,
          shortcuts: _shortcuts,
          onDocumentChanged: (_, _, _, _) {},
          onSettingsPressed: () {},
        ),
      ),
    ),
  );
  await tester.pump();
  return editor;
}

/// The platform's own text call, which a plain note and Paste as plain text
/// read.
void _platformClipboard(WidgetTester tester) {
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async => switch (call.method) {
      'Clipboard.getData' => {'text': _plain},
      'Clipboard.hasStrings' => {'value': true},
      _ => null,
    },
  );
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
}

/// Pastes the way ⌘V does, and lets the chip find the paste's caret.
///
/// On the test's clock rather than in [WidgetTester.runAsync], so the field
/// takes the paste as an undo step of its own when the clock moves on.
Future<void> _paste(
  WidgetTester tester,
  GlobalKey<NoteEditorState> editor,
) async {
  await editor.currentState!.handlePaste(SelectionChangedCause.keyboard);
  await tester.pump();
  await tester.pump();
}

String _note(WidgetTester tester) => NoteDriver(tester).value.text;

/// The caret at [offset], on screen.
Rect _caretAt(WidgetTester tester, int offset) {
  final note = NoteDriver(tester);
  return note
      .caretRect(TextPosition(offset: offset))
      .shift(note.toGlobal(Offset.zero));
}

/// What the wash paints now, on screen: its shape and colour, or null when
/// it paints nothing.
({RRect shape, Color color})? _wash(WidgetTester tester) {
  final wash = tester.renderObject<RenderBox>(
    find.descendant(
      of: find.byType(PasteWash),
      matching: find.byType(CustomPaint),
    ),
  );
  final canvas = TestRecordingCanvas();
  wash.paint(TestRecordingPaintingContext(canvas), Offset.zero);
  final calls = [
    for (final call in canvas.invocations)
      if (call.invocation.memberName == #drawRRect) call.invocation,
  ];
  if (calls.isEmpty) return null;
  final [shape as RRect, paint as Paint] = calls.single.positionalArguments;
  return (
    shape: shape.shift(wash.localToGlobal(Offset.zero)),
    color: paint.color,
  );
}

Future<void> _press(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool meta = false,
  bool shift = false,
}) async {
  if (meta) await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  if (meta) await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pump();
}

/// Lets the editor's own timers run out before the test ends.
Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 3));
}

void main() {
  setUpAll(() async {
    await loadTestFonts();
    _engine = CalcEngine();
  });

  setUp(() {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
    _shortcuts = ShortcutPrefs(_MemoryStore())..load();
  });

  tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

  testWidgets('a converted paste leaves the chip at the end of what it '
      'wrote', (tester) async {
    final editor = await _pumpEditor(tester);
    await _paste(tester, editor);

    final note = _note(tester);
    expect(note, isNot(_plain));
    expect(note, contains('**designer**'));
    expect(_chip, findsOneWidget);
    expect(_menu, findsNothing);

    // As in Paper: 16 under the caret, with its icon below it.
    final caret = _caretAt(tester, note.length);
    final icon = find.descendant(
      of: _chip,
      matching: findKapyIcon(KapyIcons.clipboardOutlined),
    );
    expect(tester.getTopLeft(_chip).dy, caret.bottom + 16);
    expect(
      tester.getCenter(icon).dx,
      moreOrLessEquals(caret.center.dx, epsilon: 4),
    );
    await _finish(tester);
  });

  testWidgets('a paste into a plain note is the platform text as ever, with '
      'no chip', (tester) async {
    _platformClipboard(tester);
    final editor = await _pumpEditor(tester, markdown: false);
    await _paste(tester, editor);

    expect(_note(tester), _plain);
    expect(_chip, findsNothing);
    expect(find.byType(PasteWash), findsNothing);
    await _finish(tester);
  });

  testWidgets('⌘⇧V pastes plain with no chip', (tester) async {
    _platformClipboard(tester);
    await _pumpEditor(tester);
    final binding = _shortcuts.bindingFor(ShortcutAction.pasteAsPlainText)!;
    expect((binding.meta, binding.shift), (true, true));
    await _press(tester, binding.logicalKey, meta: true, shift: true);
    await tester.pumpAndSettle();

    expect(_note(tester), _plain);
    expect(_chip, findsNothing);
    expect(find.byType(PasteWash), findsNothing);
    await _finish(tester);
  });

  testWidgets('Keep formatting keeps the paste and puts the chip away', (
    tester,
  ) async {
    final editor = await _pumpEditor(tester);
    await _paste(tester, editor);
    final formatted = _note(tester);

    await tester.tap(_chip);
    await tester.pump();
    expect(_menu, findsOneWidget);
    // Keep formatting is what the paste did, and the menu teaches the key
    // that pastes plain.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('paste-keep-formatting')),
        matching: findKapyIcon(KapyIcons.checkRounded),
      ),
      findsOneWidget,
    );
    final keys = _shortcuts.bindingFor(ShortcutAction.pasteAsPlainText)!;
    expect(
      find.descendant(of: _menu, matching: find.text(keys.keycapLabel)),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('paste-keep-formatting')));
    await tester.pump();
    expect(_chip, findsNothing);
    expect(_menu, findsNothing);
    expect(_note(tester), formatted);
    // The chip was part of the note, so the note kept its caret.
    expect(tester.widget<NoteField>(noteField).focusNode.hasFocus, isTrue);
    await _finish(tester);
  });

  testWidgets('Plain text instead writes the clipboard plain text, and one '
      'undo brings the formatted paste back', (tester) async {
    final editor = await _pumpEditor(tester);
    // Let the field take the empty note as its first undo step.
    await tester.pump(const Duration(milliseconds: 600));
    await _paste(tester, editor);
    final formatted = _note(tester);
    await tester.pump(const Duration(milliseconds: 600));

    await tester.tap(_chip);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('paste-plain-text')));
    await tester.pump();
    expect(_note(tester), _plain);
    expect(
      NoteDriver(tester).value.selection,
      const TextSelection.collapsed(offset: _plain.length),
    );
    expect(_chip, findsNothing);
    expect(find.byType(PasteWash), findsNothing);

    await tester.pump(const Duration(milliseconds: 600));
    await _press(tester, LogicalKeyboardKey.keyZ, meta: true);
    expect(_note(tester), formatted);
    await _finish(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('the next keystroke puts the chip away', (tester) async {
    final editor = await _pumpEditor(tester);
    await _paste(tester, editor);
    final formatted = _note(tester);
    expect(_chip, findsOneWidget);

    await _press(tester, LogicalKeyboardKey.arrowLeft);
    expect(_chip, findsNothing);
    expect(_note(tester), formatted);
    await _finish(tester);
  });

  testWidgets('a click anywhere else puts the chip away', (tester) async {
    final editor = await _pumpEditor(tester);
    await _paste(tester, editor);
    final formatted = _note(tester);
    expect(_chip, findsOneWidget);

    await tester.tapAt(_caretAt(tester, 2).center);
    await tester.pump();
    expect(_chip, findsNothing);
    expect(_note(tester), formatted);
    await _finish(tester);
  });

  testWidgets('the wash covers what the paste wrote and fades out over '
      '1.5 s', (tester) async {
    final editor = await _pumpEditor(tester);
    await _paste(tester, editor);
    final note = _note(tester);

    final full = _wash(tester)!;
    final selection = tester.element(find.byType(PasteWash)).palette.selection;
    expect(
      full.color,
      isSameColorAs(selection.withValues(alpha: selection.a / 2)),
    );
    // From the first row the paste wrote to its last, a little beyond them.
    final first = _caretAt(tester, 0);
    final last = _caretAt(tester, note.length);
    final column = NoteDriver(tester).toGlobal(Offset.zero);
    expect(full.shape.left, moreOrLessEquals(column.dx - 8));
    expect(full.shape.top, lessThan(first.top));
    expect(full.shape.bottom, greaterThan(last.bottom));

    await tester.pump(PasteWash.duration ~/ 2);
    final half = _wash(tester)!.color.a;
    expect(half, greaterThan(0));
    expect(half, lessThan(full.color.a));

    await tester.pump(PasteWash.duration ~/ 2);
    expect(_wash(tester), isNull);
    await _finish(tester);
  });

  for (final brightness in Brightness.values) {
    testWidgets('the chip and its menu look like Paper in ${brightness.name}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(500, 500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final editor = await _pumpEditor(
        tester,
        body: 'Planning\n',
        brightness: brightness,
      );
      await _paste(tester, editor);
      await tester.tap(_chip);
      await tester.pump();
      await expectLater(
        find.byType(NoteEditor),
        matchesGoldenFile('goldens/paste_feedback_${brightness.name}.png'),
      );
      await _finish(tester);
    });
  }
}
