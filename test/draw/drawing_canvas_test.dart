import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/note_drawing.dart';
import 'package:kapy_notes/ui/draw/drawing_canvas.dart';
import 'package:material_ui/material_ui.dart';

class _Host extends StatefulWidget {
  const _Host({required this.initial, this.onSwitchToWrite});

  final NoteDrawing initial;
  final VoidCallback? onSwitchToWrite;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late NoteDrawing drawing = widget.initial;
  String title = '';
  int reports = 0;

  void arrive(NoteDrawing next) => setState(() => drawing = next);

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: KapyTheme.light(),
    home: Scaffold(
      body: DrawingCanvas(
        drawing: drawing,
        title: title,
        onSwitchToWrite: widget.onSwitchToWrite,
        onChanged: (next) => setState(() {
          drawing = next;
          reports++;
        }),
        onTitleChanged: (next) => setState(() => title = next),
      ),
    ),
  );
}

Future<_HostState> _pump(
  WidgetTester tester, {
  NoteDrawing? initial,
  VoidCallback? onSwitchToWrite,
}) async {
  tester.view.physicalSize = const Size(1000, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    _Host(
      initial: initial ?? NoteDrawing.empty,
      onSwitchToWrite: onSwitchToWrite,
    ),
  );
  await tester.pumpAndSettle();
  return tester.state<_HostState>(find.byType(_Host));
}

Future<void> _drag(
  WidgetTester tester,
  List<Offset> path, {
  PointerDeviceKind kind = PointerDeviceKind.mouse,
}) async {
  final gesture = await tester.startGesture(path.first, kind: kind);
  for (final point in path.skip(1)) {
    await gesture.moveTo(point);
    await tester.pump();
  }
  await gesture.up();
  await tester.pump();
}

Future<void> _tool(WidgetTester tester, String name) async {
  await tester.tap(find.byKey(ValueKey('draw-tool-$name')));
  await tester.pump();
}

void main() {
  testWidgets('a pen stroke is one element, reported once', (tester) async {
    final host = await _pump(tester);
    await _drag(tester, const [
      Offset(200, 200),
      Offset(240, 220),
      Offset(280, 260),
      Offset(320, 250),
    ]);
    expect(host.drawing.elements, hasLength(1));
    expect(host.drawing.elements.single.kind, DrawKind.pen);
    expect(host.drawing.elements.single.pointCount, 4);
    expect(host.reports, 1);
  });

  testWidgets('shapes, undo and redo', (tester) async {
    final host = await _pump(tester);
    await _tool(tester, 'rect');
    await _drag(tester, const [Offset(100, 150), Offset(300, 300)]);
    await _tool(tester, 'arrow');
    await _drag(tester, const [Offset(400, 150), Offset(500, 250)]);
    expect(host.drawing.elements.map((e) => e.kind), [
      DrawKind.rect,
      DrawKind.arrow,
    ]);
    expect(
      host.drawing.elements.first.bounds,
      const Rect.fromLTRB(100, 150, 300, 300),
    );

    await tester.tap(find.byKey(const ValueKey('draw-undo')));
    await tester.pump();
    expect(host.drawing.elements.map((e) => e.kind), [DrawKind.rect]);
    await tester.tap(find.byKey(const ValueKey('draw-redo')));
    await tester.pump();
    expect(host.drawing.elements, hasLength(2));
  });

  testWidgets('a click without a drag leaves no empty shape', (tester) async {
    final host = await _pump(tester);
    await _tool(tester, 'ellipse');
    await _drag(tester, const [Offset(300, 300)]);
    expect(host.drawing.isEmpty, isTrue);
  });

  testWidgets('select, move and delete', (tester) async {
    final host = await _pump(tester);
    await _tool(tester, 'line');
    await _drag(tester, const [Offset(100, 200), Offset(300, 200)]);
    final id = host.drawing.elements.single.id;

    await _tool(tester, 'select');
    await _drag(tester, const [Offset(200, 201), Offset(250, 251)]);
    expect(host.drawing.byId(id)!.pointAt(0), const Offset(150, 250));

    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    expect(host.drawing.isEmpty, isTrue);
  });

  testWidgets('the eraser removes what it passes over', (tester) async {
    final host = await _pump(tester);
    await _drag(tester, const [Offset(100, 300), Offset(400, 300)]);
    await _drag(tester, const [Offset(100, 400), Offset(400, 400)]);
    await _tool(tester, 'eraser');
    await _drag(tester, const [Offset(250, 250), Offset(250, 350)]);
    expect(host.drawing.elements, hasLength(1));
    expect(host.drawing.elements.single.pointAt(0).dy, 400);
  });

  testWidgets('text is typed where the canvas was tapped', (tester) async {
    final host = await _pump(tester);
    await _tool(tester, 'text');
    await tester.tapAt(const Offset(300, 300));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('drawing-text-field')),
      'Kitchen',
    );
    // Tapping away finishes it.
    await tester.tapAt(const Offset(600, 500));
    await tester.pump();
    final text = host.drawing.elements.single;
    expect(text.kind, DrawKind.text);
    expect(text.text, 'Kitchen');
    expect(text.pointAt(0), const Offset(300, 300));
  });

  testWidgets('a change from elsewhere is adopted', (tester) async {
    final host = await _pump(tester);
    host.arrive(
      NoteDrawing([
        DrawElement(
          id: 'remote',
          kind: DrawKind.line,
          points: const [0, 0, 10, 10],
          z: 0,
        ),
      ]),
    );
    await tester.pump();
    await _drag(tester, const [Offset(500, 500), Offset(600, 600)]);
    expect(host.drawing.elements.map((e) => e.id), contains('remote'));
    expect(host.drawing.elements, hasLength(2));
  });

  testWidgets('Write is offered only while the canvas is blank', (
    tester,
  ) async {
    var switched = 0;
    await _pump(tester, onSwitchToWrite: () => switched++);
    expect(find.byKey(const ValueKey('note-mode-switch')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('note-mode-write')));
    expect(switched, 1);

    await _drag(tester, const [Offset(300, 300), Offset(350, 350)]);
    await tester.pump();
    expect(find.byKey(const ValueKey('note-mode-switch')), findsNothing);
  });

  testWidgets('two fingers pinch to zoom instead of drawing', (tester) async {
    final host = await _pump(tester);
    final a = await tester.startGesture(
      const Offset(400, 350),
      kind: PointerDeviceKind.touch,
      pointer: 1,
    );
    await tester.pump();
    final b = await tester.startGesture(
      const Offset(500, 350),
      kind: PointerDeviceKind.touch,
      pointer: 2,
    );
    await tester.pump();
    await a.moveTo(const Offset(350, 350));
    await b.moveTo(const Offset(550, 350));
    await tester.pump();
    await a.up();
    await b.up();
    await tester.pump();
    expect(host.drawing.isEmpty, isTrue);
    expect(find.text('200%'), findsOneWidget);
  });
}
