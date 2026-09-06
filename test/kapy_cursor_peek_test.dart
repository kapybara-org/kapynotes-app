import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/kapy_cursor_peek.dart';

const _stageKey = ValueKey('kapy-cursor-peek-stage');

Widget _harness({
  Animation<double>? animation,
  bool disableAnimations = false,
}) {
  return MaterialApp(
    theme: KapyTheme.dark(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(disableAnimations: disableAnimations),
      child: child!,
    ),
    home: Scaffold(
      body: Center(child: KapyCursorPeek(animation: animation)),
    ),
  );
}

double _mascotDx(WidgetTester tester) => tester
    .widget<Transform>(find.byKey(KapyCursorPeek.mascotKey))
    .transform
    .entry(0, 3);

void main() {
  testWidgets('moves out from behind a fixed caret and hides again', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(animation: const AlwaysStoppedAnimation(0)),
    );
    final hiddenStart = _mascotDx(tester);
    final caretStart = tester.getRect(find.byKey(KapyCursorPeek.caretKey));

    await tester.pumpWidget(
      _harness(animation: const AlwaysStoppedAnimation(0.5)),
    );
    final visible = _mascotDx(tester);
    final caretVisible = tester.getRect(find.byKey(KapyCursorPeek.caretKey));

    await tester.pumpWidget(
      _harness(animation: const AlwaysStoppedAnimation(1)),
    );
    final hiddenEnd = _mascotDx(tester);
    final caretEnd = tester.getRect(find.byKey(KapyCursorPeek.caretKey));

    expect(hiddenStart, lessThan(visible - 15));
    expect(hiddenEnd, closeTo(hiddenStart, 0.01));
    expect(caretVisible, caretStart);
    expect(caretEnd, caretStart);
  });

  testWidgets('emerges on the right side of the caret', (tester) async {
    await tester.pumpWidget(
      _harness(animation: const AlwaysStoppedAnimation(0.5)),
    );

    final mascot = tester.getRect(find.byKey(KapyCursorPeek.mascotKey));
    final caret = tester.getRect(find.byKey(KapyCursorPeek.caretKey));

    expect(mascot.left, closeTo(caret.center.dx, 0.1));
    expect(mascot.center.dx, greaterThan(caret.center.dx));
  });

  testWidgets('plays once when no timeline is supplied', (tester) async {
    await tester.pumpWidget(_harness());
    final hiddenStart = _mascotDx(tester);

    await tester.pump(const Duration(milliseconds: 600));
    final visible = _mascotDx(tester);

    await tester.pump(const Duration(milliseconds: 1050));
    final hiddenEnd = _mascotDx(tester);

    expect(hiddenStart, lessThan(visible - 15));
    expect(hiddenEnd, closeTo(hiddenStart, 0.01));
  });

  testWidgets('blinks twice while holding the full peek', (tester) async {
    Future<void> show(double progress) => tester.pumpWidget(
      _harness(animation: AlwaysStoppedAnimation(progress)),
    );

    await show(0.40);
    expect(find.byKey(KapyCursorPeek.blinkKey), findsNothing);

    await show(0.45);
    expect(find.byKey(KapyCursorPeek.blinkKey), findsOneWidget);

    await show(0.52);
    expect(find.byKey(KapyCursorPeek.blinkKey), findsNothing);

    await show(0.59);
    expect(find.byKey(KapyCursorPeek.blinkKey), findsOneWidget);

    await show(0.66);
    expect(find.byKey(KapyCursorPeek.blinkKey), findsNothing);
  });

  testWidgets('stays absent when reduced motion is enabled', (tester) async {
    await tester.pumpWidget(_harness(disableAnimations: true));

    expect(find.byKey(KapyCursorPeek.mascotKey), findsNothing);
    expect(find.byKey(KapyCursorPeek.caretKey), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('cursor-peek key frames', (tester) async {
    tester.view.physicalSize = const Size(420, 88);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Scaffold(
          body: RepaintBoundary(
            key: _stageKey,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: const [
                KapyCursorPeek(
                  size: 56,
                  animation: AlwaysStoppedAnimation(0.14),
                ),
                KapyCursorPeek(
                  size: 56,
                  animation: AlwaysStoppedAnimation(0.40),
                ),
                KapyCursorPeek(
                  size: 56,
                  animation: AlwaysStoppedAnimation(0.45),
                ),
                KapyCursorPeek(
                  size: 56,
                  animation: AlwaysStoppedAnimation(0.52),
                ),
                KapyCursorPeek(
                  size: 56,
                  animation: AlwaysStoppedAnimation(0.59),
                ),
                KapyCursorPeek(
                  size: 56,
                  animation: AlwaysStoppedAnimation(0.90),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => precacheImage(
        const AssetImage(KapyCursorPeek.assetPath),
        tester.element(find.byKey(_stageKey)),
      ),
    );
    await tester.pump();

    await expectLater(
      find.byKey(_stageKey),
      matchesGoldenFile('goldens/kapy_cursor_peek_frames.png'),
    );
  });
}
