import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/ui/back_forward.dart';
import 'package:material_ui/material_ui.dart';

import 'support/back_forward.dart';

const _back = BackForwardStep.back;
const _forward = BackForwardStep.forward;

void main() {
  late List<String> steps;

  setUp(() => steps = []);

  bool Function(BackForwardStep) record(String place) => (step) {
    steps.add('$place ${step.name}');
    return true;
  };

  Widget app(Widget home) => MaterialApp(home: home);

  Widget box(String key) => ColoredBox(
    key: ValueKey(key),
    color: const Color(0xFF808080),
    child: const SizedBox.expand(),
  );

  for (final by in StepBy.values) {
    testWidgets('${by.name}: steps the area under the pointer, back and '
        'forward', (tester) async {
      asDesktop();
      await tester.pumpWidget(
        app(BackForwardArea(onStep: record('page'), child: box('page'))),
      );
      final page = find.byKey(const ValueKey('page'));

      await stepOver(tester, page, _back, by);
      await stepOver(tester, page, _forward, by);
      expect(steps, ['page back', 'page forward']);
    }, variant: TargetPlatformVariant.desktop());

    testWidgets('${by.name}: the innermost area takes it', (tester) async {
      asDesktop();
      await tester.pumpWidget(
        app(
          BackForwardArea(
            onStep: record('outer'),
            child: Row(
              children: [
                Expanded(child: box('outside')),
                Expanded(
                  child: BackForwardArea(
                    onStep: record('inner'),
                    child: box('inside'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      await stepOver(tester, find.byKey(const ValueKey('inside')), _back, by);
      await stepOver(tester, find.byKey(const ValueKey('outside')), _back, by);
      expect(steps, ['inner back', 'outer back']);
    }, variant: TargetPlatformVariant.desktop());

    testWidgets('${by.name}: nothing on a phone, which has its own swipes', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      await tester.pumpWidget(
        app(BackForwardArea(onStep: record('page'), child: box('page'))),
      );

      await stepOver(tester, find.byKey(const ValueKey('page')), _back, by);
      expect(steps, isEmpty);
    });
  }

  testWidgets('one swipe takes one step however far it goes, and a short or '
      'mostly vertical one none', (tester) async {
    asDesktop();
    await tester.pumpWidget(
      app(BackForwardArea(onStep: record('page'), child: box('page'))),
    );
    final at = tester.getCenter(find.byKey(const ValueKey('page')));

    for (final by in [StepBy.pan, StepBy.wheel]) {
      await stepAt(tester, at, _back, by, reach: 6);
      await stepAt(tester, at, _forward, by, reach: 0.8);
    }
    expect(steps, ['page back', 'page back']);

    final pointer = TestPointer(1, PointerDeviceKind.trackpad);
    await tester.sendEventToBinding(pointer.panZoomStart(at));
    await tester.sendEventToBinding(
      pointer.panZoomUpdate(at, pan: const Offset(120, 300)),
    );
    await tester.sendEventToBinding(pointer.panZoomEnd());
    await tester.pumpAndSettle();
    expect(steps, hasLength(2), reason: 'a scroll down that drifts sideways');
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('a canvas keeps the swipes that start over it, and the mouse '
      'buttons go to the place around it', (tester) async {
    asDesktop();
    await tester.pumpWidget(
      app(
        BackForwardArea(
          onStep: record('page'),
          child: BackForwardArea(onStep: null, child: box('canvas')),
        ),
      ),
    );
    final canvas = find.byKey(const ValueKey('canvas'));

    await stepOver(tester, canvas, _back, StepBy.pan);
    await stepOver(tester, canvas, _back, StepBy.wheel);
    expect(steps, isEmpty);
    await stepOver(tester, canvas, _back, StepBy.button);
    expect(steps, ['page back']);
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('something that scrolls sideways keeps the swipe until it '
      'reaches its end', (tester) async {
    asDesktop();
    final wide = ScrollController();
    addTearDown(wide.dispose);
    await tester.pumpWidget(
      app(
        BackForwardArea(
          onStep: record('page'),
          child: Center(
            child: SizedBox(
              height: 100,
              child: ListView(
                controller: wide,
                scrollDirection: Axis.horizontal,
                children: [
                  for (var cell = 0; cell < 12; cell++)
                    SizedBox(width: 200, child: box('cell $cell')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final at = tester.getCenter(find.byType(ListView));

    for (final by in [StepBy.pan, StepBy.wheel]) {
      wide.jumpTo(400);
      await tester.pump();
      await stepAt(tester, at, _forward, by);
      expect(wide.offset, greaterThan(400), reason: by.name);
      await stepAt(tester, at, _back, by, reach: 0.5);
      expect(steps, isEmpty, reason: by.name);

      wide.jumpTo(wide.position.maxScrollExtent);
      await tester.pump();
      await stepAt(tester, at, _forward, by);
      expect(steps, ['page forward'], reason: by.name);
      steps.clear();

      wide.jumpTo(0);
      await tester.pump();
      await stepAt(tester, at, _back, by);
      expect(steps, ['page back'], reason: by.name);
      steps.clear();
    }

    // The mouse's buttons never scroll anything, so they step wherever.
    wide.jumpTo(400);
    await tester.pump();
    await stepAt(tester, at, _back, StepBy.button);
    expect(steps, ['page back']);
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('a vertical scroll never spends the swipe, and a swipe that '
      'drifts down still steps once it is mostly sideways', (tester) async {
    asDesktop();
    final tall = ScrollController();
    addTearDown(tall.dispose);
    await tester.pumpWidget(
      app(
        BackForwardArea(
          onStep: record('page'),
          child: ListView(
            controller: tall,
            children: [
              for (var row = 0; row < 40; row++)
                SizedBox(height: 100, child: box('row $row')),
            ],
          ),
        ),
      ),
    );
    final at = tester.getCenter(find.byType(ListView));

    final pointer = TestPointer(2, PointerDeviceKind.trackpad);
    await tester.sendEventToBinding(pointer.panZoomStart(at));
    for (var part = 1; part <= 4; part++) {
      await tester.sendEventToBinding(
        pointer.panZoomUpdate(at, pan: Offset(5.0 * part, -30.0 * part)),
      );
    }
    await tester.pump();
    expect(tall.offset, greaterThan(0), reason: 'the list scrolled');
    expect(steps, isEmpty, reason: 'mostly down');
    await tester.sendEventToBinding(
      pointer.panZoomUpdate(at, pan: const Offset(220, -120)),
    );
    await tester.sendEventToBinding(pointer.panZoomEnd());
    await tester.pumpAndSettle();
    expect(steps, ['page back']);

    for (var part = 0; part < 3; part++) {
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: at,
          kind: PointerDeviceKind.mouse,
          scrollDelta: const Offset(0, 40),
        ),
      );
    }
    await tester.pump(const Duration(milliseconds: 200));
    expect(steps, ['page back'], reason: 'a wheel down is no step');
    await stepAt(tester, at, _forward, StepBy.wheel);
    expect(steps, ['page back', 'page forward']);
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('a canvas that pans sideways keeps its pan under a swipe or a '
      'sideways wheel, even at the end of its extent', (tester) async {
    asDesktop();
    final canvas = ScrollController();
    addTearDown(canvas.dispose);
    await tester.pumpWidget(
      app(
        BackForwardArea(
          onStep: record('page'),
          child: BackForwardArea(
            onStep: null,
            child: Center(
              child: SizedBox(
                height: 100,
                child: ListView(
                  controller: canvas,
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (var cell = 0; cell < 12; cell++)
                      SizedBox(width: 200, child: box('cell $cell')),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final at = tester.getCenter(find.byType(ListView));

    for (final by in [StepBy.pan, StepBy.wheel]) {
      canvas.jumpTo(400);
      await tester.pump();
      await stepAt(tester, at, _forward, by);
      expect(canvas.offset, greaterThan(400), reason: '${by.name} pans');

      canvas.jumpTo(canvas.position.maxScrollExtent);
      await tester.pump();
      await stepAt(tester, at, _forward, by);
      canvas.jumpTo(0);
      await tester.pump();
      await stepAt(tester, at, _back, by);
      expect(steps, isEmpty, reason: '${by.name} at either end');
    }
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('what moved slides in from the side the step came from, and '
      'holds still where the system asks for less motion', (tester) async {
    asDesktop();
    Future<void> pumpPage({required bool reduced}) => tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: app(
          BackForwardArea(
            onStep: record('page'),
            child: BackForwardSlide(child: box('page')),
          ),
        ),
      ),
    );
    await pumpPage(reduced: false);
    final page = find.byKey(const ValueKey('page'));
    final at = tester.getCenter(page);
    double shift() => tester.getTopLeft(page).dx;

    Future<double> midway(BackForwardStep step) async {
      await tester.tapAt(
        at,
        buttons: step == _back ? kBackMouseButton : kForwardMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final moved = shift();
      await tester.pumpAndSettle();
      expect(shift(), 0);
      return moved;
    }

    expect(await midway(_forward), greaterThan(0), reason: 'from the right');
    expect(await midway(_back), lessThan(0), reason: 'from the left');

    await pumpPage(reduced: true);
    expect(await midway(_forward), 0);
    expect(steps, hasLength(3));
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('a place that goes mid-swipe takes no step', (tester) async {
    asDesktop();
    var panel = true;
    late StateSetter setPanel;
    await tester.pumpWidget(
      app(
        BackForwardArea(
          onStep: record('page'),
          child: StatefulBuilder(
            builder: (context, setState) {
              setPanel = setState;
              return panel
                  ? BackForwardArea(
                      onStep: record('panel'),
                      child: box('panel'),
                    )
                  : box('panel');
            },
          ),
        ),
      ),
    );
    final at = tester.getCenter(find.byKey(const ValueKey('panel')));
    final pointer = TestPointer(1, PointerDeviceKind.trackpad);
    await tester.sendEventToBinding(pointer.panZoomStart(at));
    await tester.sendEventToBinding(
      pointer.panZoomUpdate(at, pan: const Offset(40, 0)),
    );
    setPanel(() => panel = false);
    await tester.pump();
    await tester.sendEventToBinding(
      pointer.panZoomUpdate(at, pan: const Offset(140, 0)),
    );
    await tester.sendEventToBinding(pointer.panZoomEnd());
    await tester.pumpAndSettle();
    expect(steps, isEmpty);
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('at rest the slide draws only its child, and the child keeps its '
      'state across a step', (tester) async {
    asDesktop();
    await tester.pumpWidget(
      app(
        BackForwardArea(
          onStep: record('page'),
          child: BackForwardSlide(child: const _Counter()),
        ),
      ),
    );
    final slide = find.byType(BackForwardSlide);
    Finder inside(Type type) =>
        find.descendant(of: slide, matching: find.byType(type));
    expect(inside(Opacity), findsNothing);
    expect(inside(Transform), findsNothing);

    await tester.tap(find.byType(_Counter));
    await tester.pump();
    expect(find.text('1'), findsOneWidget);

    final at = tester.getCenter(slide);
    await tester.tapAt(
      at,
      buttons: kForwardMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(inside(Transform), findsOneWidget);
    expect(find.text('1'), findsOneWidget, reason: 'state moves with it');
    await tester.pumpAndSettle();
    expect(inside(Transform), findsNothing);
    expect(find.text('1'), findsOneWidget);
  }, variant: TargetPlatformVariant.desktop());
}

class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int _taps = 0;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () => setState(() => _taps++),
    child: SizedBox.expand(child: Text('$_taps')),
  );
}
