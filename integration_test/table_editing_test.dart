// Do the table controls work on a real window and a real touch screen?
//
// test/table_controls_test.dart proves every operation through the widget
// tester's own pointer. This runs the four that lean on the platform (drag,
// resize, add and delete) on a real device, where a hover, a long press and a
// mouse drag arrive from the engine instead of the tester.
//
//   flutter test integration_test/table_editing_test.dart -d macos \
//     --dart-define=KAPYNOTES_SYNC=false
//   flutter test integration_test/table_editing_test.dart -d <ios sim id>
//   flutter test integration_test/table_editing_test.dart -d <android id>
//
// On a Mac, run it under a bundle id of its own, never the real app's:
//   FLUTTER_XCODE_PRODUCT_BUNDLE_IDENTIFIER=com.kapybara.kapynotes.<suffix>
//
// A phone has no column border to drag, so resize runs on desktops only.
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/calc/highlight.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/editor/note_field.dart';
import 'package:kapy_notes/ui/editor/table_controls.dart';
import 'package:material_ui/material_ui.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'table-editing-integration.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

const _table =
    '| Item | Who | Cost |\n'
    '| --- | :---: | ---: |\n'
    '| Tickets | Ana | 412 |\n'
    '| Hotel | Sanjay | 896 |\n'
    '| Taxi | Ana | 38 |';
const _body = 'Lisbon packing\n\n$_table\n\nafter';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final phone = AppPlatform.isMobile;
  final kind = phone ? PointerDeviceKind.touch : PointerDeviceKind.mouse;
  TestGesture? mouse;

  String text(WidgetTester tester) =>
      tester.widget<NoteField>(find.byType(NoteField)).controller.text;

  TableFrame frameOf(WidgetTester tester) => tester
      .state<NoteEditorState>(find.byType(NoteEditor))
      .debugTableFrames
      .single;

  Offset cell(TableFrame frame, int row, int column) => Offset(
    (frame.columnEdges[column] + frame.columnEdges[column + 1]) / 2,
    (frame.rowEdges[row] + frame.rowEdges[row + 1]) / 2,
  );

  /// A second of real time, which a live binding's pump does not wait for,
  /// so a phone's keyboard has finished moving the note before anything is
  /// measured.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  /// Brings row [row]'s grip up: a hover over it on a desktop, its first
  /// cell opened on a phone.
  Future<void> reach(WidgetTester tester, int row) async {
    final at = cell(frameOf(tester), row, 0);
    if (phone) {
      await tester.tapAt(at);
    } else {
      if (mouse == null) {
        mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse!.addPointer(location: Offset.zero);
      }
      await mouse!.moveTo(at);
    }
    await settle(tester);
  }

  Future<void> open(WidgetTester tester, {String body = _body}) async {
    await tester.pumpWidget(const SizedBox.shrink());
    final engine = CalcEngine();
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Scaffold(
          body: NoteEditor(
            key: UniqueKey(),
            noteId: 'table-editing',
            initialBody: body,
            engine: engine,
            highlighter: Highlighter(engine.registry),
            resultsVisible: true,
            markdownEnabled: true,
            onDocumentChanged: (_, _, _, _) {},
            onSettingsPressed: () {},
            shortcuts: ShortcutPrefs(_MemoryStore())..load(),
            writingFont: WritingFont.handwritten,
          ),
        ),
      ),
    );
    await settle(tester);
    if (body == _body) await reach(tester, 1);
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.tapAt(tester.getCenter(find.byKey(ValueKey(key))), kind: kind);
    await settle(tester);
  }

  Future<void> drag(WidgetTester tester, Offset from, Offset to) async {
    final gesture = await tester.startGesture(from, kind: kind);
    // A live binding's pump does not wait, so a phone's press is held for real.
    await Future<void>.delayed(Duration(milliseconds: phone ? 800 : 50));
    await tester.pump();
    for (var i = 1; i <= 12; i++) {
      await gesture.moveTo(Offset.lerp(from, to, i / 12)!);
      await Future<void>.delayed(const Duration(milliseconds: 16));
      await tester.pump();
    }
    await gesture.up();
    await settle(tester);
  }

  testWidgets('a row grip drags its row where it is dropped', (tester) async {
    await open(tester);
    final frame = frameOf(tester);
    final grip = tester.getCenter(
      find.byKey(const ValueKey('table-row-grip-1')),
    );
    await drag(tester, grip, Offset(grip.dx, cell(frame, 3, 0).dy));
    expect(
      text(tester),
      _body.replaceFirst(
        '| Tickets | Ana | 412 |\n| Hotel | Sanjay | 896 |\n| Taxi | Ana | 38 |',
        '| Hotel | Sanjay | 896 |\n| Taxi | Ana | 38 |\n| Tickets | Ana | 412 |',
      ),
    );
  });

  testWidgets('a row is added below the first and then deleted', (
    tester,
  ) async {
    await open(tester);
    await tapKey(tester, 'table-row-grip-1');
    await tapKey(tester, 'table-menu-${TableCommand.rowBelow.name}');
    expect(
      text(tester),
      _body.replaceFirst(
        '| Tickets | Ana | 412 |\n',
        '| Tickets | Ana | 412 |\n|  |  |  |\n',
      ),
    );

    await reach(tester, 2);
    await tapKey(tester, 'table-row-grip-2');
    await tapKey(tester, 'table-menu-${TableCommand.deleteRow.name}');
    expect(text(tester), _body);
  });

  testWidgets('"+" past the last row adds one', (tester) async {
    await open(tester);
    final frame = frameOf(tester);
    await mouse!.moveTo(Offset(cell(frame, 3, 0).dx, frame.rowEdges.last + 4));
    await settle(tester);
    await tapKey(tester, 'table-add-row');
    expect(
      text(tester),
      _body.replaceFirst(
        '| Taxi | Ana | 38 |',
        '| Taxi | Ana | 38 |\n|  |  |  |',
      ),
    );
  }, skip: phone);

  testWidgets('a table typed by hand forms as each line is finished', (
    tester,
  ) async {
    const header = 'Title\n| Item | Qty |\n';
    await open(tester, body: header);
    // Focused, so the field has a connection to the platform's keyboard.
    final note = tester.widget<NoteField>(find.byType(NoteField));
    note.focusNode.requestFocus();
    await settle(tester);
    final controller = note.controller;
    controller.selection = const TextSelection.collapsed(offset: header.length);
    await settle(tester);
    // One character at a time, as the platform's keyboard sends them.
    final field = tester.state<NoteFieldState>(find.byType(NoteField));
    for (final character in '| --- | --- |\n| Tea | 2 |\n'.split('')) {
      final value = controller.value;
      final at = value.selection.baseOffset;
      field.updateEditingValueWithDeltas([
        TextEditingDeltaInsertion(
          oldText: value.text,
          textInserted: character,
          insertionOffset: at,
          selection: TextSelection.collapsed(offset: at + 1),
          composing: TextRange.empty,
        ),
      ]);
      await tester.pump();
    }
    await settle(tester);
    expect(text(tester), '$header| --- | --- |\n| Tea | 2 |\n');
    expect(frameOf(tester).rowEdges, hasLength(3));
  });

  testWidgets('a column border drags a width into the dashes', (tester) async {
    await open(tester);
    final frame = frameOf(tester);
    final edge = Offset(frame.columnEdges[1], cell(frame, 2, 0).dy);
    await mouse!.moveTo(edge);
    await settle(tester);
    await drag(tester, edge, edge.translate(80, 0));
    final sized = text(tester);
    final dashes = RegExp(r'\| (-+) \| :---:').firstMatch(sized)!.group(1)!;
    expect(dashes.length, greaterThan(3));
    expect(sized.replaceFirst('| $dashes |', '| --- |'), _body);
  }, skip: phone);
}
