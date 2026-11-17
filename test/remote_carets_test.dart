import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/calc/highlight.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/sync/presence.dart';
import 'package:kapy_notes/ui/collaborator_colors.dart';
import 'package:kapy_notes/ui/editor/highlighting_controller.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/editor/note_field.dart';
import 'package:kapy_notes/ui/editor/remote_carets.dart';
import 'package:material_ui/material_ui.dart';

import 'support/note_driver.dart';
import 'test_fonts.dart';

/// Other people's carets over the note, drawn from what the sync layer
/// resolved — here a hand-fed source, so the tests are about the drawing.

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'remote-carets-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

class FakeCaretSource implements RemoteCaretSource {
  final ValueNotifier<int> _changes = ValueNotifier<int>(0);
  RemoteCarets carets = RemoteCarets.empty;

  @override
  Listenable get caretChanges => _changes;

  @override
  RemoteCarets caretsFor(String noteId) => carets;

  void show(RemoteCarets value) {
    carets = value;
    _changes.value++;
  }
}

late CalcEngine engine;
late ShortcutPrefs shortcutPrefs;

Widget harness(String body, FakeCaretSource source) => MaterialApp(
  theme: KapyTheme.dark(),
  home: Scaffold(
    body: NoteEditor(
      key: const ValueKey('remote-caret-editor'),
      noteId: 'note-1',
      initialBody: body,
      engine: engine,
      highlighter: Highlighter(engine.registry),
      resultsVisible: true,
      remoteCarets: source,
      onDocumentChanged: (_, _, _, _) {},
      onSettingsPressed: () {},
      writingFont: WritingFont.handwritten,
      shortcuts: shortcutPrefs,
    ),
  ),
);

RemoteCaret caret({
  int base = 5,
  int? extent,
  bool typing = false,
  Duration ago = Duration.zero,
}) => RemoteCaret(
  id: 'user-2|phone',
  userId: 'user-2',
  name: 'Priya',
  base: base,
  extent: extent ?? base,
  typing: typing,
  movedAt: DateTime.now().subtract(ago),
);

/// The layer's own render object, which is what does the painting.
RenderBox layer(WidgetTester tester) => tester.renderObject<RenderBox>(
  find.descendant(
    of: find.byType(RemoteCaretLayer),
    matching: find.byWidgetPredicate(
      (widget) => widget.runtimeType.toString() == '_RemoteCaretPaint',
    ),
  ),
);

NoteDriver field(WidgetTester tester) => NoteDriver(tester);

/// Where [offset]'s caret bar is drawn, in the layer's coordinates.
Rect bar(WidgetTester tester, int offset) {
  final editable = field(tester);
  final rect = editable.caretRect(TextPosition(offset: offset));
  final origin = layer(tester).globalToLocal(editable.toGlobal(Offset.zero));
  final shifted = rect.shift(origin);
  return Rect.fromLTWH(shifted.left - 1, shifted.top, 2, shifted.height);
}

final Color ink = collaboratorColor('user-2', on: Brightness.dark);

void main() {
  setUpAll(loadTestFonts);
  setUp(() {
    engine = CalcEngine(ratesPerUsd: const {'EUR': 0.86});
    shortcutPrefs = ShortcutPrefs(_MemoryStore())..load();
  });

  testWidgets('a typist shows as a caret in their colour, flying their name', (
    tester,
  ) async {
    final source = FakeCaretSource();
    await tester.pumpWidget(harness('hello world', source));
    await tester.pumpAndSettle();
    expect(layer(tester), isNot(paints..rect(color: ink)));

    source.show(
      RemoteCarets(text: 'hello world', carets: [caret(typing: true)]),
    );
    await tester.pump();
    expect(
      layer(tester),
      paints
        ..rect(rect: bar(tester, 5), color: ink)
        ..rrect(color: ink)
        ..paragraph(),
    );
  });

  testWidgets('a quiet caret folds its flag, and pointing at it raises it', (
    tester,
  ) async {
    final source = FakeCaretSource();
    await tester.pumpWidget(harness('hello world', source));
    source.show(
      RemoteCarets(
        text: 'hello world',
        carets: [caret(ago: const Duration(seconds: 30))],
      ),
    );
    await tester.pumpAndSettle();
    // The bar and the small tab on top of it; no name.
    expect(
      layer(tester),
      paints
        ..rect(color: ink)
        ..rect(color: ink),
    );
    expect(layer(tester), isNot(paints..rrect(color: ink)));

    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer(location: Offset.zero);
    addTearDown(pointer.removePointer);
    final editable = field(tester);
    await pointer.moveTo(
      editable.toGlobal(
        editable.caretRect(const TextPosition(offset: 5)).center,
      ),
    );
    await tester.pump();
    expect(
      layer(tester),
      paints
        ..rrect(color: ink)
        ..paragraph(),
    );
  });

  testWidgets('a moving caret raises its flag, which folds again on its own', (
    tester,
  ) async {
    final source = FakeCaretSource();
    await tester.pumpWidget(harness('hello world', source));
    source.show(RemoteCarets(text: 'hello world', carets: [caret()]));
    await tester.pump();
    expect(layer(tester), paints..rrect(color: ink));

    await tester.pump(
      RemoteCaretLayer.flagDuration + const Duration(milliseconds: 50),
    );
    expect(layer(tester), isNot(paints..rrect(color: ink)));
  });

  testWidgets('offsets resolved against older text are carried onto the '
      "editor's", (tester) async {
    final source = FakeCaretSource();
    // The editor already holds "XX " that the document has not absorbed.
    await tester.pumpWidget(harness('XX hello world', source));
    source.show(
      RemoteCarets(text: 'hello world', carets: [caret(typing: true)]),
    );
    await tester.pump();
    expect(layer(tester), paints..rect(rect: bar(tester, 8), color: ink));
  });

  testWidgets('a selection is shaded under the caret', (tester) async {
    final source = FakeCaretSource();
    await tester.pumpWidget(harness('hello world', source));
    source.show(
      RemoteCarets(
        text: 'hello world',
        carets: [caret(base: 0, extent: 5, typing: true)],
      ),
    );
    await tester.pump();
    expect(
      layer(tester),
      paints
        ..rect(color: ink.withValues(alpha: 0.22))
        ..rect(rect: bar(tester, 5), color: ink),
    );
  });

  testWidgets('a table caret uses its painted cell instead of hidden source', (
    tester,
  ) async {
    final source = FakeCaretSource();
    final controller = HighlightingController(
      highlighter: Highlighter(CalcEngine().registry),
      palette: KapyTheme.lightPalette,
      writingFont: WritingFont.clean,
      text: 'hidden source',
    );
    final focusNode = FocusNode();
    final scroll = ScrollController();
    final hover = ValueNotifier<Offset?>(null);
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    addTearDown(scroll.dispose);
    addTearDown(hover.dispose);
    final field = GlobalKey<NoteFieldState>();
    const visibleCaret = Rect.fromLTWH(240, 8, 0, 18);

    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Scaffold(
          body: Stack(
            children: [
              NoteField(
                key: field,
                controller: controller,
                focusNode: focusNode,
                scrollController: scroll,
                style: const TextStyle(fontSize: 16),
                strut: const StrutStyle(fontSize: 16),
              ),
              Positioned.fill(
                child: RemoteCaretLayer(
                  noteId: 'note-1',
                  source: source,
                  controller: controller,
                  scroll: scroll,
                  field: () => field.currentState,
                  hover: hover,
                  tableCaretRect: (_) => visibleCaret,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    source.show(
      RemoteCarets(
        text: controller.text,
        carets: [caret(base: 3, typing: true)],
      ),
    );
    await tester.pump();

    final painted = Rect.fromPoints(
      layer(tester).globalToLocal(visibleCaret.topLeft),
      layer(tester).globalToLocal(visibleCaret.bottomRight),
    );
    expect(
      layer(tester),
      paints..rect(
        rect: Rect.fromLTWH(painted.left - 1, painted.top, 2, painted.height),
        color: ink,
      ),
    );
  });
}
