import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ui/editor/dotted_wrap.dart';

void main() {
  const dot = ColoredBox(
    color: Color(0xFF000000),
    child: SizedBox(width: 4, height: 8),
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

  testWidgets('a fact wider than the line takes a line and wraps in it', (
    tester,
  ) async {
    await pump(tester, 120, [100, 200]);
    expect(at(tester, 'item1'), const Offset(0, 16));
    expect(tester.getSize(find.byKey(const ValueKey('item1'))).width, 120);
    expect(facts(tester), paintsExactlyCountTimes(#drawRect, 0));
  });
}
