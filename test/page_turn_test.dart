import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ui/page_turn.dart';
import 'package:material_ui/material_ui.dart';

/// A 400 × 800 phone, so a share of the width is easy to read.
const _width = 400.0;

class _Counter extends StatefulWidget {
  const _Counter(this.label);

  final String label;

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int taps = 0;

  @override
  Widget build(BuildContext context) {
    final label = widget.label;
    return GestureDetector(
      onTap: () => setState(() => taps++),
      child: ColoredBox(
        color: const Color(0xFFFFFFFF),
        child: Center(child: Text('$label $taps')),
      ),
    );
  }
}

/// Pages 0 to [last], one on screen, turned by a [PageTurn].
class _Pages extends StatefulWidget {
  const _Pages({
    super.key,
    this.start = 1,
    this.page,
    this.canStart,
    this.onBack,
    this.top,
  });

  final int start;
  final Widget Function(int index)? page;
  final bool Function(Offset)? canStart;
  final VoidCallback? onBack;

  /// A part over the pages that stays put, the only place a turn starts
  /// from, built for the page it shows.
  final Widget Function(int index)? top;

  @override
  State<_Pages> createState() => _PagesState();
}

class _PagesState extends State<_Pages> {
  late int index = widget.start;
  final turns = <bool>[];

  Widget _page(int i) => KeyedSubtree(
    key: ValueKey('page-$i'),
    child: widget.page?.call(i) ?? _Counter('page $i'),
  );

  @override
  Widget build(BuildContext context) => PageTurn(
    before: index > 0 ? (_) => _page(index - 1) : null,
    after: index < 2 ? (_) => _page(index + 1) : null,
    canStart: widget.canStart,
    onBack: widget.onBack,
    top: switch (widget.top) {
      final top? => (_, turning) => top(switch (turning) {
        null => index,
        true => index + 1,
        false => index - 1,
      }),
      null => null,
    },
    onlyFromTop: widget.top != null,
    onTurn: (later) => setState(() {
      turns.add(later);
      index += later ? 1 : -1;
    }),
    child: _page(index),
  );
}

Future<void> _pump(
  WidgetTester tester,
  Widget pages, {
  TargetPlatform platform = TargetPlatform.iOS,
  EdgeInsets gestureInsets = EdgeInsets.zero,
  bool reduceMotion = false,
  DeviceGestureSettings? gestureSettings,
}) async {
  tester.view.physicalSize = const Size(_width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: platform),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          systemGestureInsets: gestureInsets,
          disableAnimations: reduceMotion,
          gestureSettings: gestureSettings,
        ),
        child: child!,
      ),
      home: pages,
    ),
  );
}

_PagesState _state(WidgetTester tester) =>
    tester.state<_PagesState>(find.byType(_Pages));

/// Where page [i] stands across the screen, as its left edge.
double _left(WidgetTester tester, int i) =>
    tester.getTopLeft(find.byKey(ValueKey('page-$i'))).dx;

Finder _page(int i) => find.byKey(ValueKey('page-$i'));

const _middle = Offset(_width / 2, 400);

/// A header 100 tall over the pages, naming the page it shows.
Widget _top(int index) => SizedBox(height: 100, child: Text('top $index'));

void main() {
  group('following the finger', () {
    testWidgets('the page moves with the drag, and its neighbour slides in '
        'beside it, built only once it shows', (tester) async {
      await _pump(tester, const _Pages());
      expect(_page(2), findsNothing);
      final drag = await tester.startGesture(_middle);
      await drag.moveBy(const Offset(-30, 0));
      await drag.moveBy(const Offset(-50, 0));
      await tester.pump();
      expect(_left(tester, 1), -80);
      expect(_left(tester, 2), _width - 80);
      await drag.moveBy(const Offset(30, 0));
      await tester.pump();
      expect(_left(tester, 1), -50);
      await drag.up();
      await tester.pumpAndSettle();
    });

    testWidgets('a drag to the right brings the page before in from the left', (
      tester,
    ) async {
      await _pump(tester, const _Pages());
      final drag = await tester.startGesture(_middle);
      await drag.moveBy(const Offset(40, 0));
      await drag.moveBy(const Offset(40, 0));
      await tester.pump();
      expect(_left(tester, 1), 80);
      expect(_left(tester, 0), 80 - _width);
      await drag.up();
      await tester.pumpAndSettle();
    });
  });

  group('a part that stays put', () {
    testWidgets('stays put while the pages under it turn, and shows the page '
        'turned to once the turn is let go', (tester) async {
      await _pump(tester, const _Pages(top: _top));
      final drag = await tester.startGesture(const Offset(_width / 2, 50));
      await drag.moveBy(const Offset(-60, 0));
      await drag.moveBy(const Offset(-100, 0));
      await tester.pump();
      expect(_left(tester, 1), -160);
      expect(tester.getTopLeft(find.text('top 1')), Offset.zero);
      await drag.up();
      await tester.pump();
      expect(find.text('top 2'), findsOneWidget);
      expect(_left(tester, 2), greaterThan(0), reason: 'still settling');
      await tester.pumpAndSettle();
      expect(find.text('top 2'), findsOneWidget);
      expect(_state(tester).turns, [true]);
    });

    testWidgets('is the only place a turn starts from', (tester) async {
      await _pump(tester, const _Pages(top: _top));
      await tester.timedDragFrom(
        _middle,
        const Offset(-200, 0),
        const Duration(milliseconds: 300),
      );
      await tester.pumpAndSettle();
      expect(_state(tester).turns, isEmpty);
    });

    testWidgets('a turn caught before it settles shows its own page again', (
      tester,
    ) async {
      await _pump(tester, const _Pages(top: _top));
      await tester.timedDragFrom(
        const Offset(_width / 2, 50),
        const Offset(-160, 0),
        const Duration(milliseconds: 300),
      );
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.text('top 2'), findsOneWidget);
      final drag = await tester.startGesture(const Offset(_width / 2, 50));
      await drag.moveBy(const Offset(100, 0));
      await drag.moveBy(const Offset(100, 0));
      await tester.pump();
      expect(find.text('top 1'), findsOneWidget);
      await drag.up();
      await tester.pumpAndSettle();
      expect(_state(tester).turns, isEmpty);
    });
  });

  group('the marks', () {
    testWidgets('a slow drag short of a quarter of the width springs back', (
      tester,
    ) async {
      await _pump(tester, const _Pages());
      await tester.timedDragFrom(
        _middle,
        const Offset(-0.24 * _width, 0),
        const Duration(seconds: 1),
      );
      await tester.pumpAndSettle();
      expect(_state(tester).turns, isEmpty);
      expect(_left(tester, 1), 0);
      expect(_page(2), findsNothing);
    });

    testWidgets('a slow drag past a quarter of the width turns the page', (
      tester,
    ) async {
      await _pump(tester, const _Pages());
      await tester.timedDragFrom(
        _middle,
        const Offset(-0.27 * _width, 0),
        const Duration(seconds: 1),
      );
      await tester.pumpAndSettle();
      expect(_state(tester).turns, [true]);
      expect(_left(tester, 2), 0);
    });

    testWidgets('a short flick turns the page', (tester) async {
      await _pump(tester, const _Pages());
      await tester.flingFrom(_middle, const Offset(-60, 0), 1200);
      await tester.pumpAndSettle();
      expect(_state(tester).turns, [true]);
    });

    testWidgets('a short slow drag stays put', (tester) async {
      await _pump(tester, const _Pages());
      await tester.timedDragFrom(
        _middle,
        const Offset(-60, 0),
        const Duration(milliseconds: 600),
      );
      await tester.pumpAndSettle();
      expect(_state(tester).turns, isEmpty);
    });

    testWidgets('a long drag flicked back the way it came calls the turn off', (
      tester,
    ) async {
      await _pump(tester, const _Pages());
      final drag = await tester.startGesture(_middle);
      var at = Duration.zero;
      for (var i = 0; i < 20; i++) {
        at += const Duration(milliseconds: 16);
        await drag.moveBy(const Offset(-10, 0), timeStamp: at);
        await tester.pump(const Duration(milliseconds: 16));
      }
      for (var i = 0; i < 3; i++) {
        at += const Duration(milliseconds: 8);
        await drag.moveBy(const Offset(30, 0), timeStamp: at);
        await tester.pump(const Duration(milliseconds: 8));
      }
      await drag.up(timeStamp: at);
      await tester.pumpAndSettle();
      expect(_state(tester).turns, isEmpty);
      expect(_left(tester, 1), 0);
    });

    testWidgets('a drag taken back to where it began stays put', (
      tester,
    ) async {
      await _pump(tester, const _Pages());
      final drag = await tester.startGesture(_middle);
      for (final dx in [-40.0, -80.0, -40.0, 40.0, 40.0, 40.0, 40.0]) {
        await drag.moveBy(Offset(dx / 4, 0));
        await tester.pump(const Duration(milliseconds: 100));
      }
      await drag.up();
      await tester.pumpAndSettle();
      expect(_state(tester).turns, isEmpty);
      expect(_left(tester, 1), 0);
    });
  });

  group('settling', () {
    testWidgets('takes the rest of the way in one easing motion, no longer '
        'than the motion, and the page turned to keeps its state', (
      tester,
    ) async {
      await _pump(tester, const _Pages());
      final drag = await tester.startGesture(_middle);
      await drag.moveBy(const Offset(-30, 0));
      await drag.moveBy(const Offset(-110, 0));
      await tester.pump();
      final coming = tester.state<_CounterState>(
        find.descendant(of: _page(2), matching: find.byType(_Counter)),
      );
      await drag.up();
      await tester.pump();
      final lefts = <double>[];
      for (var t = 0; t < 30; t++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (_page(1).evaluate().isEmpty) break;
        lefts.add(_left(tester, 1));
      }
      expect(lefts, isNotEmpty);
      for (var i = 1; i < lefts.length; i++) {
        expect(lefts[i], lessThanOrEqualTo(lefts[i - 1]));
      }
      expect(
        lefts.length * 16,
        lessThanOrEqualTo(PageTurn.motion.inMilliseconds + 32),
      );
      await tester.pumpAndSettle();
      expect(_state(tester).turns, [true]);
      expect(_left(tester, 2), 0);
      expect(tester.state<_CounterState>(find.byType(_Counter)), same(coming));
    });

    testWidgets('a drag during the settle catches the page where it is', (
      tester,
    ) async {
      await _pump(tester, const _Pages());
      final first = await tester.startGesture(_middle);
      await first.moveBy(const Offset(-30, 0));
      await first.moveBy(const Offset(-170, 0));
      await tester.pump();
      await first.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final at = _left(tester, 1);
      expect(at, lessThan(-200));
      final drag = await tester.startGesture(_middle);
      await drag.moveBy(const Offset(30, 0));
      await drag.moveBy(const Offset(20, 0));
      await tester.pump();
      expect(_left(tester, 1), closeTo(at + 50, 1));
      await drag.up();
      await tester.pumpAndSettle();
    });
  });

  group('the ends', () {
    testWidgets('with no page beyond, the page gives a little and comes back', (
      tester,
    ) async {
      await _pump(tester, const _Pages(start: 2));
      final drag = await tester.startGesture(_middle);
      for (var i = 0; i < 10; i++) {
        await drag.moveBy(const Offset(-30, 0));
      }
      await tester.pump();
      final at = _left(tester, 2);
      expect(at, lessThan(0));
      expect(at, greaterThan(-PageTurn.give * _width));
      await drag.up();
      await tester.pumpAndSettle();
      expect(_state(tester).turns, isEmpty);
      expect(_left(tester, 2), 0);
    });

    testWidgets('a fast flick at the end turns nothing', (tester) async {
      await _pump(tester, const _Pages(start: 0));
      await tester.flingFrom(_middle, const Offset(200, 0), 2000);
      await tester.pumpAndSettle();
      expect(_state(tester).turns, isEmpty);
      expect(_left(tester, 0), 0);
    });

    testWidgets('with Back, a drag right past the marks goes back', (
      tester,
    ) async {
      var backs = 0;
      await _pump(tester, _Pages(start: 0, onBack: () => backs++));
      await tester.timedDragFrom(
        _middle,
        const Offset(150, 0),
        const Duration(milliseconds: 500),
      );
      await tester.pumpAndSettle();
      expect(backs, 1);
      await tester.timedDragFrom(
        _middle,
        const Offset(60, 0),
        const Duration(milliseconds: 600),
      );
      await tester.pumpAndSettle();
      expect(backs, 1);
    });
  });

  group('no accidental turns', () {
    Future<void> expectStill(WidgetTester tester, String why) async {
      await tester.pumpAndSettle();
      expect(_state(tester).turns, isEmpty, reason: why);
      expect(_left(tester, 1), 0, reason: why);
    }

    testWidgets('a tap', (tester) async {
      await _pump(tester, const _Pages());
      await tester.tap(_page(1));
      await expectStill(tester, 'tap');
      expect(find.text('page 1 1'), findsOneWidget);
    });

    testWidgets('a long press', (tester) async {
      await _pump(tester, const _Pages());
      final press = await tester.startGesture(_middle);
      await tester.pump(const Duration(seconds: 1));
      await press.up();
      await expectStill(tester, 'long press');
    });

    testWidgets('a wobble short of the start, then a lift', (tester) async {
      await _pump(tester, const _Pages());
      final drag = await tester.startGesture(_middle);
      for (final dx in [8.0, -12.0, 14.0, -10.0, 6.0]) {
        await drag.moveBy(Offset(dx, 1));
        await tester.pump(const Duration(milliseconds: 16));
        expect(_left(tester, 1), 0);
      }
      await drag.up();
      await expectStill(tester, 'wobble');
    });

    testWidgets('a fling that goes across less than twice the touch slop', (
      tester,
    ) async {
      await _pump(tester, const _Pages());
      await tester.flingFrom(
        _middle,
        const Offset(-2 * kTouchSlop + 2, 0),
        3000,
      );
      await expectStill(tester, 'short fling');
    });

    testWidgets('a diagonal drag steeper than the mark, however far', (
      tester,
    ) async {
      await _pump(tester, const _Pages());
      await tester.timedDragFrom(
        _middle,
        const Offset(-200, -120),
        const Duration(milliseconds: 300),
      );
      await expectStill(tester, 'diagonal');
    });

    testWidgets('a drag that goes up or down first, with nothing to scroll, '
        'however far it then goes sideways', (tester) async {
      await _pump(tester, const _Pages());
      final drag = await tester.startGesture(_middle);
      await drag.moveBy(const Offset(0, kTouchSlop + 4));
      await tester.pump();
      for (var i = 0; i < 10; i++) {
        await drag.moveBy(const Offset(-30, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(_left(tester, 1), 0);
      await drag.up();
      await expectStill(tester, 'down first');
    });

    testWidgets('a scroll that has started keeps the drag, however far it '
        'then goes sideways', (tester) async {
      await _pump(
        tester,
        _Pages(
          page: (i) => ListView(
            children: [
              for (var row = 0; row < 40; row++)
                SizedBox(height: 60, child: Text('row $i.$row')),
            ],
          ),
        ),
      );
      final drag = await tester.startGesture(_middle);
      await drag.moveBy(const Offset(0, -30));
      await tester.pump();
      for (var i = 0; i < 10; i++) {
        await drag.moveBy(const Offset(-30, -2));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(_left(tester, 1), 0);
      await drag.up();
      await expectStill(tester, 'scroll');
      expect(tester.getTopLeft(find.text('row 1.0')).dy, lessThan(-10));
    });

    testWidgets('a sideways scroller under the finger keeps its drag', (
      tester,
    ) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await _pump(
        tester,
        _Pages(
          page: (i) => Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              height: 100,
              child: ListView(
                controller: i == 1 ? controller : null,
                scrollDirection: Axis.horizontal,
                children: [
                  for (var cell = 0; cell < 20; cell++)
                    SizedBox(width: 80, child: Text('cell $cell')),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.timedDragFrom(
        const Offset(_width / 2, 50),
        const Offset(-200, 0),
        const Duration(milliseconds: 300),
      );
      await expectStill(tester, 'scroller');
      expect(controller.offset, greaterThan(100));
    });

    testWidgets('a drag where the page says no', (tester) async {
      await _pump(tester, _Pages(canStart: (at) => at.dy < 100));
      await tester.timedDragFrom(
        _middle,
        const Offset(-200, 0),
        const Duration(milliseconds: 300),
      );
      await expectStill(tester, 'below the header');
      await tester.timedDragFrom(
        const Offset(_width / 2, 50),
        const Offset(-200, 0),
        const Duration(milliseconds: 300),
      );
      await tester.pumpAndSettle();
      expect(_state(tester).turns, [true]);
    });

    testWidgets("on Android, a drag from inside the system's back gesture "
        'edges', (tester) async {
      await _pump(
        tester,
        const _Pages(),
        platform: TargetPlatform.android,
        gestureInsets: const EdgeInsets.symmetric(horizontal: 30),
      );
      await tester.timedDragFrom(
        const Offset(20, 400),
        const Offset(200, 0),
        const Duration(milliseconds: 300),
      );
      await expectStill(tester, 'left edge');
      await tester.timedDragFrom(
        const Offset(_width - 20, 400),
        const Offset(-200, 0),
        const Duration(milliseconds: 300),
      );
      await expectStill(tester, 'right edge');
      await tester.timedDragFrom(
        const Offset(40, 400),
        const Offset(200, 0),
        const Duration(milliseconds: 300),
      );
      await tester.pumpAndSettle();
      expect(_state(tester).turns, [false]);
    });

    testWidgets("on Android, Back's left edge still goes back from inside "
        "the system's gesture edges, as the system's own back does there, "
        'but turns nothing', (tester) async {
      var backs = 0;
      await _pump(
        tester,
        _Pages(start: 0, onBack: () => backs++),
        platform: TargetPlatform.android,
        gestureInsets: const EdgeInsets.symmetric(horizontal: 30),
      );
      await tester.timedDragFrom(
        const Offset(4, 400),
        const Offset(200, 0),
        const Duration(milliseconds: 300),
      );
      await tester.pumpAndSettle();
      expect(backs, 1);
      await tester.timedDragFrom(
        const Offset(_width - 4, 400),
        const Offset(-200, 0),
        const Duration(milliseconds: 300),
      );
      await tester.pumpAndSettle();
      expect(_state(tester).turns, isEmpty);
    });

    testWidgets("on Android, Back's left edge goes back ahead of a row's own "
        "swipe, at the phone's own touch slop", (tester) async {
      var backs = 0;
      var swipes = 0;
      await _pump(
        tester,
        _Pages(
          start: 0,
          onBack: () => backs++,
          page: (i) => GestureDetector(
            onHorizontalDragStart: (_) => swipes++,
            child: _Counter('page $i'),
          ),
        ),
        platform: TargetPlatform.android,
        gestureInsets: const EdgeInsets.symmetric(horizontal: 30),
        gestureSettings: const DeviceGestureSettings(touchSlop: 8),
      );
      await tester.timedDragFrom(
        const Offset(2, 400),
        const Offset(200, 0),
        const Duration(milliseconds: 300),
      );
      await tester.pumpAndSettle();
      expect(backs, 1);
      expect(swipes, 0);
      await tester.timedDragFrom(
        const Offset(_width / 2, 400),
        const Offset(200, 0),
        const Duration(milliseconds: 300),
      );
      await tester.pumpAndSettle();
      expect(swipes, 1, reason: 'away from the edge, the row keeps its swipe');
      expect(backs, 1);
    });

    testWidgets('on an iPhone, a drag from the left edge of a page that can '
        "go back is iOS's own", (tester) async {
      await _pump(tester, const SizedBox());
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      final pages = GlobalKey<_PagesState>();
      navigator.push(
        MaterialPageRoute<void>(builder: (_) => _Pages(key: pages)),
      );
      await tester.pumpAndSettle();
      await tester.timedDragFrom(
        const Offset(5, 400),
        const Offset(300, 0),
        const Duration(milliseconds: 300),
      );
      await tester.pumpAndSettle();
      expect(find.byType(_Pages), findsNothing);
    });
  });

  group('reduce motion', () {
    testWidgets('nothing moves with the finger, and a turn past the marks '
        'crossfades to its page', (tester) async {
      await _pump(tester, const _Pages(), reduceMotion: true);
      final drag = await tester.startGesture(_middle);
      for (var i = 0; i < 10; i++) {
        await drag.moveBy(const Offset(-20, 0));
        await tester.pump(const Duration(milliseconds: 16));
        expect(_left(tester, 1), 0);
      }
      await drag.up();
      await tester.pump();
      await tester.pump(PageTurn.fade ~/ 2);
      expect(_left(tester, 2), 0);
      final opacity = tester.widget<Opacity>(
        find.ancestor(of: _page(2), matching: find.byType(Opacity)).first,
      );
      expect(opacity.opacity, inExclusiveRange(0.2, 0.8));
      await tester.pumpAndSettle();
      expect(_state(tester).turns, [true]);
      expect(_page(1), findsNothing);
    });
  });
}
