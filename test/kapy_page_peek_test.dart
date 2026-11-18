import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ui/kapy_page_peek.dart';
import 'package:material_ui/material_ui.dart';

final _kapy = find.byKey(KapyPagePeek.imageKey);

Widget _host({
  bool Function()? held,
  Listenable? activity,
  math.Random? random,
  bool disableAnimations = false,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: disableAnimations),
    child: child!,
  ),
  home: Scaffold(
    body: Stack(
      children: [
        Positioned(
          right: -6,
          bottom: 0,
          child: KapyPagePeek(
            held: held,
            activity: activity,
            random: random ?? math.Random(1),
          ),
        ),
      ],
    ),
  ),
);

/// Pumps [time] in frames of at most half a second, so an animation a timer
/// starts is ticked the way a running window would tick it.
Future<void> _wait(WidgetTester tester, Duration time) async {
  const frame = Duration(milliseconds: 500);
  var left = time;
  while (left > frame) {
    await tester.pump(frame);
    left -= frame;
  }
  await tester.pump(left);
  await tester.pump();
}

/// A slide takes its time from the frame after it starts, so a test that wants
/// it finished gives it a frame and a little more.
Future<void> _slide(WidgetTester tester) async {
  await tester.pump();
  await _wait(tester, KapyPagePeek.slide + const Duration(milliseconds: 50));
}

void main() {
  testWidgets('Kapy starts out of sight', (tester) async {
    await tester.pumpWidget(_host());
    expect(_kapy, findsNothing);
  });

  testWidgets('peeks only once the window has been idle for the threshold', (
    tester,
  ) async {
    await tester.pumpWidget(_host());

    await _wait(
      tester,
      KapyPagePeek.idleBeforePeek - const Duration(seconds: 1),
    );
    expect(_kapy, findsNothing);

    await _wait(tester, const Duration(seconds: 1));
    expect(_kapy, findsOneWidget);
    await _slide(tester);
    final size = tester.getSize(_kapy);
    expect(size, const Size(KapyPagePeek.width, KapyPagePeek.height));
    expect(tester.getRect(_kapy).right, 806);
  });

  testWidgets('slides in from the edge and out again, not a cut', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    await _wait(tester, KapyPagePeek.idleBeforePeek);
    final start = tester.getRect(_kapy).left;
    await _wait(tester, KapyPagePeek.slide ~/ 2);
    final middle = tester.getRect(_kapy).left;
    await _slide(tester);
    final end = tester.getRect(_kapy).left;
    expect(start, greaterThan(middle));
    expect(middle, greaterThan(end));
    expect(start - end, closeTo(KapyPagePeek.width, 0.5));

    await _wait(tester, KapyPagePeek.stay);
    await _wait(tester, KapyPagePeek.slide ~/ 2);
    expect(tester.getRect(_kapy).left, greaterThan(end));
    expect(_kapy, findsOneWidget);
  });

  testWidgets('hides again after its time', (tester) async {
    await tester.pumpWidget(_host());
    await _wait(tester, KapyPagePeek.idleBeforePeek);
    await _slide(tester);
    await _wait(tester, KapyPagePeek.stay - const Duration(milliseconds: 100));
    expect(_kapy, findsOneWidget);

    await _wait(tester, const Duration(milliseconds: 100));
    await _slide(tester);
    expect(_kapy, findsNothing);
  });

  testWidgets('returns at a random 2 to 5 minute interval while idle', (
    tester,
  ) async {
    await tester.pumpWidget(_host(random: math.Random(1)));
    await _wait(tester, KapyPagePeek.idleBeforePeek);
    await _slide(tester);
    await _wait(tester, KapyPagePeek.stay + KapyPagePeek.slide);
    await _slide(tester);
    expect(_kapy, findsNothing);

    var idle = Duration.zero;
    while (_kapy.evaluate().isEmpty && idle < KapyPagePeek.maxInterval * 2) {
      await _wait(tester, const Duration(seconds: 1));
      idle += const Duration(seconds: 1);
    }
    expect(_kapy, findsOneWidget);
    expect(
      idle.inSeconds,
      inInclusiveRange(
        KapyPagePeek.minInterval.inSeconds - 5,
        KapyPagePeek.maxInterval.inSeconds + 5,
      ),
    );
    await _slide(tester);
    expect(tester.getRect(_kapy).right, 806);
  });

  testWidgets('any key or pointer input sends it away, and the wait starts '
      'again', (tester) async {
    await tester.pumpWidget(_host());
    await _wait(tester, KapyPagePeek.idleBeforePeek);
    await _slide(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
    await _wait(tester, KapyPagePeek.slide ~/ 2);
    expect(_kapy, findsOneWidget, reason: 'it leaves on the same slide');
    await _slide(tester);
    expect(_kapy, findsNothing);

    await _wait(
      tester,
      KapyPagePeek.idleBeforePeek - const Duration(seconds: 5),
    );
    expect(_kapy, findsNothing);
    await _wait(tester, const Duration(seconds: 6));
    expect(_kapy, findsOneWidget);
    await _slide(tester);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(10, 10));
    addTearDown(mouse.removePointer);
    await mouse.moveTo(const Offset(20, 20));
    await _slide(tester);
    expect(_kapy, findsNothing);
  });

  testWidgets('never shows while the person keeps typing', (tester) async {
    await tester.pumpWidget(_host());
    for (var i = 0; i < 20; i++) {
      await _wait(tester, const Duration(seconds: 30));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      expect(_kapy, findsNothing);
    }
  });

  testWidgets('holds back while a pointer is down, as in a drag', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    final touch = await tester.startGesture(const Offset(100, 100));
    await _wait(tester, KapyPagePeek.idleBeforePeek * 3);
    expect(_kapy, findsNothing);

    await touch.up();
    await _wait(tester, KapyPagePeek.idleBeforePeek);
    expect(_kapy, findsOneWidget);
  });

  testWidgets('holds back while the host says so, and while a dialog is open', (
    tester,
  ) async {
    var held = true;
    await tester.pumpWidget(_host(held: () => held));
    await _wait(tester, KapyPagePeek.idleBeforePeek * 2);
    expect(_kapy, findsNothing);

    held = false;
    await _wait(tester, KapyPagePeek.retryWhenHeld);
    expect(_kapy, findsOneWidget);
    await _slide(tester);
    await _wait(tester, KapyPagePeek.stay + KapyPagePeek.slide);
    await _slide(tester);
    expect(_kapy, findsNothing);

    final context = tester.element(find.byType(Scaffold));
    showDialog<void>(
      context: context,
      builder: (_) => const AlertDialog(title: Text('Open')),
    );
    await tester.pump();
    await _wait(tester, KapyPagePeek.maxInterval * 2);
    expect(_kapy, findsNothing);

    Navigator.of(context).pop();
    await tester.pump();
    await _wait(tester, KapyPagePeek.retryWhenHeld);
    expect(_kapy, findsOneWidget);
  });

  testWidgets('with Reduce Motion on it fades where it would slide', (
    tester,
  ) async {
    await tester.pumpWidget(_host(disableAnimations: true));
    await _wait(tester, KapyPagePeek.idleBeforePeek);
    await _wait(tester, KapyPagePeek.slide ~/ 3);
    final rect = tester.getRect(_kapy);
    expect(rect.right, 806);
    final opacity = tester.widget<Opacity>(
      find.ancestor(of: _kapy, matching: find.byType(Opacity)),
    );
    expect(opacity.opacity, inExclusiveRange(0, 1));

    await _slide(tester);
    expect(tester.getRect(_kapy), rect);
    expect(
      tester
          .widget<Opacity>(
            find.ancestor(of: _kapy, matching: find.byType(Opacity)),
          )
          .opacity,
      1,
    );
  });

  testWidgets('text arriving without a key or pointer event is input too', (
    tester,
  ) async {
    final dictation = ValueNotifier('');
    addTearDown(dictation.dispose);
    await tester.pumpWidget(_host(activity: dictation));

    await _wait(
      tester,
      KapyPagePeek.idleBeforePeek - const Duration(seconds: 5),
    );
    dictation.value = 'hello';
    await _wait(
      tester,
      KapyPagePeek.idleBeforePeek - const Duration(seconds: 5),
    );
    expect(_kapy, findsNothing, reason: 'the wait started again');
    await _wait(tester, const Duration(seconds: 6));
    expect(_kapy, findsOneWidget);
    await _slide(tester);

    dictation.value = 'hello again';
    await _slide(tester);
    expect(_kapy, findsNothing, reason: 'dictation sends it away');

    for (var i = 0; i < 10; i++) {
      await _wait(tester, const Duration(seconds: 30));
      dictation.value = i.toString();
      expect(_kapy, findsNothing);
    }
  });

  testWidgets('keeps no timer while the app is hidden, and waits again when '
      'it comes back', (tester) async {
    await tester.pumpWidget(_host());
    await _wait(
      tester,
      KapyPagePeek.idleBeforePeek - const Duration(seconds: 5),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await _wait(tester, KapyPagePeek.maxInterval * 2);
    expect(_kapy, findsNothing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _wait(tester, const Duration(seconds: 6));
    expect(_kapy, findsNothing, reason: 'no peek as the window comes back');
    await _wait(
      tester,
      KapyPagePeek.idleBeforePeek - const Duration(seconds: 5),
    );
    expect(_kapy, findsOneWidget);
    await _slide(tester);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _slide(tester);
    expect(_kapy, findsNothing, reason: 'it was sent away on hiding');
    await _wait(
      tester,
      KapyPagePeek.idleBeforePeek - const Duration(seconds: 5),
    );
    expect(_kapy, findsNothing);
    await _wait(tester, const Duration(seconds: 6));
    expect(_kapy, findsOneWidget);
  });

  testWidgets('a pointer whose release was lost does not hold it back for '
      'good', (tester) async {
    await tester.pumpWidget(_host());
    await tester.startGesture(const Offset(100, 100));
    await _wait(tester, KapyPagePeek.idleBeforePeek * 2);
    expect(_kapy, findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
    await _wait(tester, KapyPagePeek.idleBeforePeek);
    expect(_kapy, findsOneWidget);
    await _slide(tester);
    await _wait(tester, KapyPagePeek.stay + KapyPagePeek.slide);
    await _slide(tester);

    await tester.startGesture(const Offset(100, 100), pointer: 7);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(10, 10));
    addTearDown(mouse.removePointer);
    await mouse.moveTo(const Offset(20, 20));
    await _wait(tester, KapyPagePeek.idleBeforePeek);
    expect(_kapy, findsOneWidget, reason: 'a hover says nothing is down');
  });
}
