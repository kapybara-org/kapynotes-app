import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ui/editor/dotted_wrap.dart';

void main() {
  final dot = Semantics(
    label: '·',
    container: true,
    child: ColoredBox(
      color: Color(0xFF000000),
      child: SizedBox(width: 4, height: 8),
    ),
  );

  Future<void> pump(WidgetTester tester, double width, List<double> items) =>
      tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: width),
              child: DottedWrap(
                key: const ValueKey('facts'),
                dot: dot,
                gap: 10,
                items: [
                  for (final (index, w) in items.indexed)
                    SizedBox(key: ValueKey('item$index'), width: w, height: 16),
                ],
              ),
            ),
          ),
        ),
      );

  Offset at(WidgetTester tester, String key) =>
      tester.getTopLeft(find.byKey(ValueKey(key)));

  RenderObject facts(WidgetTester tester) =>
      tester.renderObject(find.byKey(const ValueKey('facts')));

  testWidgets('puts a dot between facts that share a line', (tester) async {
    await pump(tester, 300, [100, 100]);
    expect(at(tester, 'item0'), Offset.zero);
    expect(tester.getTopLeft(find.byType(ColoredBox)), const Offset(110, 4));
    expect(at(tester, 'item1'), const Offset(124, 0));
    expect(
      tester.getSize(find.byKey(const ValueKey('facts'))),
      const Size(224, 16),
    );
    expect(facts(tester), paintsExactlyCountTimes(#drawRect, 1));
  });

  testWidgets('a fact that moves to the next line leaves its dot behind', (
    tester,
  ) async {
    await pump(tester, 250, [100, 100, 100]);
    expect(at(tester, 'item1'), const Offset(124, 0));
    expect(at(tester, 'item2'), const Offset(0, 16));
    expect(
      facts(tester),
      paintsExactlyCountTimes(#drawRect, 1),
      reason: 'the dot before the third fact is not drawn',
    );
    expect(tester.getSize(find.byKey(const ValueKey('facts'))).height, 32);
  });

  testWidgets('a dot left behind is not exposed to semantics', (tester) async {
    final semantics = tester.ensureSemantics();
    await pump(tester, 250, [100, 100, 100]);
    expect(find.bySemanticsLabel('·'), findsOneWidget);
    await pump(tester, 400, [100, 100, 100]);
    expect(find.bySemanticsLabel('·'), findsNWidgets(2));
    semantics.dispose();
  });

  testWidgets('answers an intrinsic size like the line it lays out', (
    tester,
  ) async {
    await pump(tester, 250, [100, 100, 100]);
    final box = tester.renderObject<RenderBox>(
      find.byKey(const ValueKey('facts')),
    );
    expect(box.getMinIntrinsicWidth(double.infinity), 100);
    expect(box.getMaxIntrinsicWidth(double.infinity), 100 * 3 + 2 * (20 + 4));
    expect(box.getMinIntrinsicHeight(250), 32);
    expect(box.getMinIntrinsicHeight(400), 16);
  });

  testWidgets('a fact wider than the line takes a line and wraps in it', (
    tester,
  ) async {
    await pump(tester, 120, [100, 200]);
    expect(at(tester, 'item1'), const Offset(0, 16));
    expect(tester.getSize(find.byKey(const ValueKey('item1'))).width, 120);
    expect(facts(tester), paintsExactlyCountTimes(#drawRect, 0));
  });
}
