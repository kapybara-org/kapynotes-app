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
import 'package:kapy_notes/ui/editor/insert_bar.dart';
import 'package:kapy_notes/ui/editor/markdown_backdrop.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/editor/note_footer.dart';
import 'package:kapy_notes/ui/editor/note_header.dart';
import 'package:material_ui/material_ui.dart';

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
  VoidCallback? onNewDrawing,
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
          onDocumentChanged: (body, formats, attachments) {
            onBody?.call(body);
            onFormats?.call(formats);
          },
          onSettingsPressed: () {},
          onRecordVoice: onRecordVoice,
          onNewDrawing: onNewDrawing,
          writingFont: writingFont,
          shortcuts: ShortcutPrefs(_MemoryStore())..load(),
        ),
      ),
    ),
  ),
);

RenderEditable _editable(WidgetTester tester) =>
    tester.state<EditableTextState>(find.byType(EditableText)).renderEditable;

/// Where line [line] of the note starts and the next one does, in the
/// field's own coordinates, as the editor measured them for what it draws
/// behind the text.
(double, double) _rows(WidgetTester tester, int line) {
  final tops = tester
      .widget<MarkdownBackdrop>(find.byType(MarkdownBackdrop))
      .offsets
      .tops;
  return (tops[line], tops[line + 1]);
}

InlineSpan _spanAt(WidgetTester tester, int offset) {
  final field = tester.widget<EditableText>(find.byType(EditableText));
  final span = field.controller.buildTextSpan(
    context: tester.element(find.byType(EditableText)),
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

  testWidgets('the title is set in Shantell at 40/48 with the meta row under '
      'it', (tester) async {
    window(tester);
    await tester.pumpWidget(_page(_body));
    await tester.pumpAndSettle();

    final title = (_spanAt(tester, 2) as TextSpan).style!;
    expect(title.fontFamily, 'Shantell Sans');
    expect(title.fontSize, 40);
    expect(title.fontWeight, FontWeight.w700);
    final (firstLine, secondLine) = _rows(tester, 1);
    expect(secondLine - firstLine, EditorMetrics.lineHeight);
    expect(find.text('Edited today, 15:38'), findsOneWidget);
    expect(find.text('1 of 3 done'), findsOneWidget);
    expect(find.byKey(const ValueKey('note-title-underline')), findsOneWidget);
    // The meta row stands in the room under the title, and the body starts
    // below it. Line positions are where a caret's top goes, a few pixels
    // into the row.
    final meta = tester.getRect(find.byType(NoteMetaRow));
    final field = _editable(tester).localToGlobal(Offset.zero);
    expect(
      meta.top - field.dy,
      closeTo(EditorMetrics.titleRow + EditorMetrics.metaGap, 0.5),
    );
    final roomBelow = firstLine - (meta.bottom - field.dy);
    expect(roomBelow, greaterThanOrEqualTo(EditorMetrics.metaBottom));
    expect(roomBelow, lessThan(EditorMetrics.metaBottom + 10));
  });

  testWidgets('a caret past the end of the title stays at its end', (
    tester,
  ) async {
    window(tester);
    await tester.pumpWidget(_page(_body));
    await tester.pumpAndSettle();
    final field = tester.widget<EditableText>(find.byType(EditableText));
    const end = 'SnowSEO Issues'.length;

    field.controller.selection = const TextSelection.collapsed(
      offset: end + 1,
      affinity: TextAffinity.upstream,
    );
    await tester.pump();
    expect(field.controller.selection.baseOffset, end);

    // The line below still starts where it always did.
    field.controller.selection = const TextSelection.collapsed(offset: end + 1);
    await tester.pump();
    expect(field.controller.selection.baseOffset, end + 1);
  });

  testWidgets('the writing is a 680px column of Figtree at weight 500', (
    tester,
  ) async {
    window(tester);
    await tester.pumpWidget(_page(_body));
    await tester.pumpAndSettle();

    final body = (_spanAt(tester, _body.indexOf('ahrefs')) as TextSpan).style!;
    expect(body.fontFamily, 'Figtree');
    expect(body.fontSize, 16);
    expect(body.fontWeight, FontWeight.w500);
    final field = _editable(tester);
    expect(
      field.size.width,
      closeTo(EditorMetrics.columnWidth + EditorMetrics.caretMargin, 0.5),
    );
    expect(field.localToGlobal(Offset.zero).dx, closeTo((1200 - 680) / 2, 2));

    await tester.pumpWidget(_page(_body, width: 500));
    await tester.pumpAndSettle();
    // Too narrow for the bar's words, so it keeps its icons.
    expect(find.text('Image'), findsNothing);
    expect(tester.getRect(find.byType(InsertBar)).width, lessThan(500 - 32));
    expect(
      _editable(tester).localToGlobal(Offset.zero).dx,
      EditorMetrics.padding.left,
    );
  });

  testWidgets('a heading is Shantell at 18 with room above it', (tester) async {
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
    expect(heading.fontSize, EditorMetrics.headingFontSize);
    // Lines 3 and 5 are both plain rows, so their caret tops sit alike and
    // the distance between them is the two rows between.
    final (above, headingCaret) = _rows(tester, 3);
    final (bottom, _) = _rows(tester, 5);
    expect(
      bottom - above,
      closeTo(EditorMetrics.lineHeight + EditorMetrics.headingLine, 1),
    );
    // The room is above the words: a plain row's caret starts at its top,
    // and the heading's well below the top of its row.
    expect(
      headingCaret - (above + EditorMetrics.lineHeight),
      greaterThan(EditorMetrics.headingLine / 3),
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
        .getBoxesForSelection(
          TextSelection(
            baseOffset: _body.indexOf('Automate'),
            extentOffset: _body.indexOf('Automate') + 1,
          ),
        )
        .first;
    expect(words.left, closeTo(32, 1));

    final field = _editable(tester);
    final glyph = field
        .getBoxesForSelection(
          TextSelection(
            baseOffset: _body.indexOf('☐'),
            extentOffset: _body.indexOf('☐') + 1,
          ),
        )
        .first;
    await tester.tapAt(field.localToGlobal(glyph.toRect().center));
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

  testWidgets('the insert bar replaces the footer and does what it says', (
    tester,
  ) async {
    window(tester);
    var recorded = 0;
    var drawings = 0;
    List<NoteFormatRange>? formats;
    await tester.pumpWidget(
      _page(
        _body,
        onRecordVoice: () => recorded++,
        onNewDrawing: () => drawings++,
        onFormats: (value) => formats = value,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(NoteFooter), findsNothing);
    expect(find.byType(InsertBar), findsOneWidget);
    for (final label in [
      'Image',
      'Video',
      'Voice',
      'Drawing',
      'Format',
      'Commands',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    // Centred at the page's foot.
    final bar = tester.getRect(find.byType(InsertBar));
    expect(bar.center.dx, closeTo(600, 1));
    expect(800 - bar.bottom, closeTo(InsertBar.bottom, 0.5));
    expect(bar.height, closeTo(46, 1));

    await tester.tap(find.text('Voice'));
    await tester.tap(find.text('Drawing'));
    expect((recorded, drawings), (1, 1));

    await tester.showKeyboard(find.byType(EditableText));
    final field = tester.widget<EditableText>(find.byType(EditableText));
    final words = _body.indexOf('ahrefs');
    field.controller.selection = TextSelection(
      baseOffset: words,
      extentOffset: words + 6,
    );
    await tester.pump();
    await tester.tap(find.text('Format'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bold'));
    await tester.pumpAndSettle();
    expect(
      formats,
      contains(
        isA<NoteFormatRange>()
            .having((range) => range.format, 'format', NoteFormat.bold)
            .having((range) => range.start, 'start', words),
      ),
    );

    expect(
      field.focusNode.hasFocus,
      isTrue,
      reason: 'formatting keeps the caret',
    );
    await tester.tap(find.text('Commands'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('slash-command-menu')), findsOneWidget);
    expect(field.focusNode.hasFocus, isTrue, reason: 'the caret stays put');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  });

  testWidgets('a read-only note has no insert bar and says why in its meta '
      'row', (tester) async {
    window(tester);
    await tester.pumpWidget(_page(_body, readOnly: true));
    await tester.pumpAndSettle();

    expect(find.byType(InsertBar), findsNothing);
    expect(find.byKey(const ValueKey('view-only-status')), findsOneWidget);
  });

  testWidgets('Kapy peeks from the page corner, clipped by its edge', (
    tester,
  ) async {
    window(tester);
    await tester.pumpWidget(_page(_body));
    await tester.pumpAndSettle();

    final kapy = tester.getRect(find.byKey(const ValueKey('page-kapy')));
    expect(kapy.size, const Size(60, 113));
    expect(kapy.right, 1206);
    expect(kapy.bottom, 800);
  });

  testWidgets('a phone keeps its footer and its own rows', (tester) async {
    window(tester);
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    await tester.pumpWidget(_page(_body, width: 390));
    await tester.pumpAndSettle();

    expect(find.byType(NoteFooter), findsOneWidget);
    expect(find.byType(InsertBar), findsNothing);
    expect(find.byType(NoteMetaRow), findsNothing);
    final field = _editable(tester);
    expect(
      field.getLocalRectForCaret(TextPosition(offset: _body.indexOf('☐'))).top -
          field.getLocalRectForCaret(const TextPosition(offset: 1)).top,
      closeTo(29, 0.5),
    );
  });
}
