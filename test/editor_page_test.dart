import 'package:flutter/gestures.dart';
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
import 'package:kapy_notes/ui/compact_icon_button.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/kapy_page_peek.dart';
import 'package:kapy_notes/ui/editor/note_field.dart';
import 'package:kapy_notes/ui/editor/note_footer.dart';
import 'package:kapy_notes/ui/editor/note_header.dart';
import 'package:material_ui/material_ui.dart';

import 'support/note_driver.dart';
import 'test_fonts.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'editor-page-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

final _now = DateTime(2026, 9, 1, 15, 38);

/// The note the page was drawn around in Paper, cut down.
const _body =
    'SnowSEO Issues\n'
    '☐ Automate Backlink Outreach\n'
    '☑ Update pricing and plans\n'
    '☐ add a report link: https://app.openseo.so/s/abc\n'
    'Tool costs per month\n'
    'ahrefs = 129 usd\n'
    'total';

late CalcEngine _engine;

Widget _page(
  String body, {
  double width = 1200,
  List<NoteFormatRange> formats = const [],
  bool readOnly = false,
  VoidCallback? onRecordVoice,
  bool slashHint = false,
  ValueChanged<List<NoteFormatRange>>? onFormats,
  ValueChanged<String>? onBody,
  WritingFont writingFont = WritingFont.mixed,
}) => MaterialApp(
  theme: KapyTheme.dark(),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: width,
        height: 800,
        child: NoteEditor(
          key: ValueKey(body),
          noteId: 'page',
          initialBody: body,
          initialFormats: formats,
          engine: _engine,
          highlighter: Highlighter(_engine.registry),
          resultsVisible: true,
          readOnly: readOnly,
          lastUpdatedAt: _now,
          now: () => _now,
          displayTime: (time) => time,
          onDocumentChanged: (body, formats, attachments, _) {
            onBody?.call(body);
            onFormats?.call(formats);
          },
          onSettingsPressed: () {},
          onRecordVoice: onRecordVoice,
          slashHint: slashHint,
          writingFont: writingFont,
          shortcuts: ShortcutPrefs(_MemoryStore())..load(),
        ),
      ),
    ),
  ),
);

NoteDriver _editable(WidgetTester tester) => NoteDriver(tester);

/// Where line [line] of the note starts and the next one does, in the
/// field's own coordinates, as the editor measured them for what it draws
/// behind the text.
(double, double) _rows(WidgetTester tester, int line) {
  final note = NoteDriver(tester);
  final lines = note.state.lines;
  double top(int line) =>
      note.caretRect(TextPosition(offset: lines.startOf(line))).top;
  return (top(line), top(line + 1));
}

InlineSpan _spanAt(WidgetTester tester, int offset) {
  final field = tester.widget<NoteField>(noteField);
  final span = field.controller.buildTextSpan(
    context: tester.element(noteField),
    style: field.style,
    withComposing: false,
  );
  return span.getSpanForPosition(TextPosition(offset: offset))!;
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => _engine = CalcEngine());

  /// Room for the 1200px editor and the 800px page under it.
  void window(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('the title is set in Shantell at 30/38 with the meta row under '
      'it', (tester) async {
    window(tester);
    await tester.pumpWidget(_page(_body));
    await tester.pumpAndSettle();

    final title = (_spanAt(tester, 2) as TextSpan).style!;
    expect(title.fontFamily, 'Shantell Sans');
    expect(title.fontSize, 30);
    expect(title.fontWeight, EditorMetrics.titleWeight);
    final (firstLine, secondLine) = _rows(tester, 1);
    expect(secondLine - firstLine, moreOrLessEquals(EditorMetrics.lineHeight));
    expect(find.text('Edited today, 15:38'), findsOneWidget);
    expect(find.text('1 of 3 done'), findsOneWidget);
    final semantics = tester.ensureSemantics();
    await tester.pump();
    expect(find.bySemanticsLabel('1 of 3 done'), findsOneWidget);
    semantics.dispose();
    // The meta row stands in the room under the title, and the body starts
    // below it. Line positions are where a caret's top goes, a few pixels
    // into the row.
    final meta = tester.getRect(find.byType(NoteMetaRow));
    final field = _editable(tester).toGlobal(Offset.zero);
    expect(
      meta.top - field.dy,
      closeTo(EditorMetrics.titleRow + EditorMetrics.metaGap, 0.5),
    );
    final roomBelow = firstLine - (meta.bottom - field.dy);
    expect(roomBelow, greaterThanOrEqualTo(EditorMetrics.metaBottom));
    expect(roomBelow, lessThan(EditorMetrics.metaBottom + 10));
  });

  testWidgets('an empty line under the title has a row of its own, below '
      'the meta row', (tester) async {
    window(tester);
    // A title and Enter, and a title with a blank line before the writing.
    for (final body in ['Weekend\n', 'Weekend\n\nBody']) {
      await tester.pumpWidget(_page(body));
      await tester.pumpAndSettle();
      final editable = _editable(tester);
      final origin = editable.toGlobal(Offset.zero);
      final end = editable.caretRect(const TextPosition(offset: 7));
      final under = editable.caretRect(const TextPosition(offset: 8));
      final meta = tester.getRect(find.byType(NoteMetaRow));

      expect(end.left, greaterThan(100), reason: body);
      expect(under.left, lessThan(2), reason: body);
      expect(origin.dy + under.top, greaterThanOrEqualTo(meta.bottom));
      // What the field draws reads as the note, letter and break included.
      expect(editable.span.toPlainText(), body);

      // A click past the end of the title puts the caret at its end.
      await tester.tapAt(origin + Offset(end.left + 120, end.center.dy));
      await tester.pumpAndSettle();
      expect(
        tester.widget<NoteField>(noteField).controller.selection.baseOffset,
        7,
      );
    }
  });

  testWidgets('the writing is a 680px column of Figtree at weight 400', (
    tester,
  ) async {
    window(tester);
    await tester.pumpWidget(_page(_body));
    await tester.pumpAndSettle();

    final body = (_spanAt(tester, _body.indexOf('ahrefs')) as TextSpan).style!;
    expect(body.fontFamily, 'Figtree');
    expect(body.fontSize, 16);
    expect(body.fontWeight, FontWeight.w400);
    final field = _editable(tester);
    expect(field.columnWidth, closeTo(EditorMetrics.columnWidth, 0.5));
    expect(field.toGlobal(Offset.zero).dx, closeTo((1200 - 680) / 2, 2));

    await tester.pumpWidget(_page(_body, width: 500));
    await tester.pumpAndSettle();
    expect(
      _editable(tester).toGlobal(Offset.zero).dx,
      EditorMetrics.padding.left,
    );
  });

  testWidgets('a heading is Shantell at 22 with room above it', (tester) async {
    window(tester);
    final start = _body.indexOf('Tool costs');
    await tester.pumpWidget(
      _page(
        _body,
        formats: [
          NoteFormatRange(
            start: start,
            end: start + 'Tool costs per month'.length,
            format: NoteFormat.heading,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    final heading = (_spanAt(tester, start + 1) as TextSpan).style!;
    expect(heading.fontFamily, 'Shantell Sans');
    expect(heading.fontSize, EditorMetrics.headingFontSize(1));
    // Lines 3 and 5 are both plain rows, so their caret tops sit alike and
    // the distance between them is the two rows between.
    final (above, headingCaret) = _rows(tester, 3);
    final (bottom, _) = _rows(tester, 5);
    expect(
      bottom - above,
      closeTo(EditorMetrics.lineHeight + EditorMetrics.headingRow(1), 1),
    );
    // The room is above the words: a plain row's caret starts at its top,
    // and the heading's well below the top of its row.
    expect(
      headingCaret - (above + EditorMetrics.lineHeight),
      greaterThan(EditorMetrics.headingRow(1) / 4),
    );
  });

  testWidgets('a checkbox is drawn as a box in its own room and still ticks', (
    tester,
  ) async {
    window(tester);
    String? body;
    await tester.pumpWidget(_page(_body, onBody: (value) => body = value));
    await tester.pumpAndSettle();

    final box = (_spanAt(tester, _body.indexOf('☐')) as TextSpan).style!;
    expect(box.color!.a, 0, reason: 'the glyph gives way to the drawn box');
    final words = _editable(tester)
        .boxesFor(
          TextSelection(
            baseOffset: _body.indexOf('Automate'),
            extentOffset: _body.indexOf('Automate') + 1,
          ),
        )
        .first;
    expect(words.left, closeTo(32, 1));

    final field = _editable(tester);
    final glyph = field
        .boxesFor(
          TextSelection(
            baseOffset: _body.indexOf('☐'),
            extentOffset: _body.indexOf('☐') + 1,
          ),
        )
        .first;
    await tester.tapAt(field.toGlobal(glyph.toRect().center));
    await tester.pumpAndSettle();
    expect(body, startsWith('SnowSEO Issues\n☑ Automate'));
  });

  testWidgets('a web address is set as a Geist Mono chip', (tester) async {
    window(tester);
    await tester.pumpWidget(_page(_body));
    await tester.pumpAndSettle();

    final link = (_spanAt(tester, _body.indexOf('openseo')) as TextSpan).style!;
    expect(link.fontFamily, AppFonts.mono);
    expect(link.fontSize, 12.5);
  });

  testWidgets('scrolled, the "+" and the hint stay on the caret\'s line', (
    tester,
  ) async {
    window(tester);
    final long = '$_body\n${List.filled(40, 'more').join('\n')}\n';
    await tester.pumpWidget(_page(long, slashHint: true));
    await tester.pumpAndSettle();

    await tester.showNoteKeyboard();
    final field = tester.widget<NoteField>(noteField);
    field.controller.selection = TextSelection.collapsed(offset: long.length);
    await tester.pumpAndSettle();
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    expect(scroll.position.pixels, greaterThan(0));

    final editable = _editable(tester);
    final caret = editable.toGlobal(
      editable.caretRect(TextPosition(offset: long.length)).center,
    );
    final hint = find.byKey(const ValueKey('slash-hint'));
    expect(tester.getRect(hint).center.dy, closeTo(caret.dy, 2));
    expect(
      tester.getRect(find.byKey(const ValueKey('line-commands'))).center.dy,
      closeTo(caret.dy, 2),
    );
  });

  testWidgets('no bar: an empty line has the "+" and the hint, which open '
      'Commands', (tester) async {
    window(tester);
    String? body;
    final empty = _body.length + 1;
    await tester.pumpWidget(
      _page('$_body\n\n', slashHint: true, onBody: (value) => body = value),
    );
    await tester.pumpAndSettle();
    expect(find.byType(NoteFooter), findsNothing);

    await tester.showNoteKeyboard();
    final field = tester.widget<NoteField>(noteField);
    field.controller.selection = TextSelection.collapsed(offset: empty);
    await tester.pumpAndSettle();
    final plus = find.byKey(const ValueKey('line-commands'));
    final hint = find.byKey(const ValueKey('slash-hint'));
    expect(plus, findsOneWidget);
    expect(hint, findsOneWidget);
    // In the margin, level with the hint, which starts where the words do.
    expect(tester.getRect(plus).right, lessThan(tester.getRect(hint).left));
    expect(
      tester.getRect(plus).center.dy,
      closeTo(tester.getRect(hint).center.dy, 2),
    );
    expect(tester.widget<CompactIconButton>(plus).selected, isFalse);

    // A line with words has neither.
    field.controller.selection = const TextSelection.collapsed(offset: 3);
    await tester.pumpAndSettle();
    expect(plus, findsNothing);
    expect(hint, findsNothing);

    // The pointer over an empty line brings the "+" alone, lit.
    final editable = _editable(tester);
    final line = editable.toGlobal(
      editable.caretRect(TextPosition(offset: empty)).center,
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: line + const Offset(80, 0));
    addTearDown(mouse.removePointer);
    await mouse.moveBy(const Offset(1, 0));
    await tester.pumpAndSettle();
    expect(plus, findsOneWidget);
    expect(hint, findsNothing);
    expect(tester.widget<CompactIconButton>(plus).selected, isTrue);

    // Pressed as a screen reader would, it opens Commands with a search of
    // its own, since the caret stays on the line.
    final semantics = tester.ensureSemantics();
    tester.semantics.tap(find.semantics.byLabel('Commands'));
    await tester.pumpAndSettle();
    semantics.dispose();
    expect(find.byKey(const ValueKey('slash-command-menu')), findsOneWidget);
    expect(field.focusNode.hasFocus, isFalse, reason: 'the search has it');
    await tester.enterText(
      find.byKey(const ValueKey('slash-command-search')),
      'todo',
    );
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('slash-command-checklist')),
        matching: find.text('todo'),
      ),
      findsOneWidget,
      reason: 'the alias it was found by',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('slash-command-menu')), findsNothing);
    expect(body, endsWith('\n☐ \n'));
    expect(field.focusNode.hasFocus, isTrue, reason: 'back in the note');

    // Esc closes the menu and gives the keyboard back to the note too.
    field.controller.selection = TextSelection.collapsed(
      offset: field.controller.text.length,
    );
    await tester.pumpAndSettle();
    await tester.tap(plus);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('slash-command-search')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('slash-command-menu')), findsNothing);
    expect(field.focusNode.hasFocus, isTrue);
  });

  testWidgets('a read-only note has no "+" and says why in its meta row', (
    tester,
  ) async {
    window(tester);
    await tester.pumpWidget(_page(_body, readOnly: true));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('line-commands')), findsNothing);
    expect(find.byKey(const ValueKey('view-only-status')), findsOneWidget);
  });

  testWidgets(
    'Kapy peeks from the page corner once idle, clipped by its edge',
    (tester) async {
      window(tester);
      await tester.pumpWidget(_page(_body));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('page-kapy')), findsNothing);

      await tester.pump(KapyPagePeek.idleBeforePeek);
      await tester.pump();
      await tester.pump(KapyPagePeek.slide + const Duration(milliseconds: 50));
      final kapy = tester.getRect(find.byKey(const ValueKey('page-kapy')));
      expect(kapy.size, const Size(60, 113));
      expect(kapy.right, 1206);
      expect(kapy.bottom, 800);
    },
  );

  testWidgets('a phone has the page with its meta row and no footer', (
    tester,
  ) async {
    window(tester);
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    await tester.pumpWidget(_page(_body, width: 390));
    await tester.pumpAndSettle();

    expect(find.byType(NoteFooter), findsNothing);
    // Taller than a window's row: the tags under the facts are 44 pt
    // targets on a phone, so the row grows with them (KAP-115).
    expect(
      tester.getSize(find.byType(NoteMetaRow)).height,
      greaterThanOrEqualTo(EditorMetrics.metaRow),
    );
    // The facts and the tags on their two lines sit between the title and
    // the writing, over neither.
    final field = _editable(tester);
    final meta = tester.getRect(find.byType(NoteMetaRow));
    final title = field.caretRect(const TextPosition(offset: 1));
    final first = field.caretRect(TextPosition(offset: _body.indexOf('☐')));
    expect(meta.top, greaterThanOrEqualTo(field.toGlobal(title.bottomLeft).dy));
    expect(meta.bottom, lessThanOrEqualTo(field.toGlobal(first.topLeft).dy));
  });
}
