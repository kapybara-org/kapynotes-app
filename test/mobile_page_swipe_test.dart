import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kLongPressTimeout;
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/mobile_page_swipe.dart';
import 'package:material_ui/material_ui.dart';

Widget _harness({
  required VoidCallback onOpenNotes,
  required VoidCallback onCreateNote,
}) => MaterialApp(
  theme: KapyTheme.dark(),
  home: MobilePageSwipe(
    onOpenNotes: onOpenNotes,
    onCreateNote: onCreateNote,
    child: const ColoredBox(color: Color(0xFFFAFAFA)),
  ),
);

/// A page with a bar at the bottom that owns its own sideways drags, the way
/// the note footer does.
Widget _withFooter({
  required VoidCallback onOpenNotes,
  required VoidCallback onCreateNote,
}) => MaterialApp(
  theme: KapyTheme.dark(),
  home: MobilePageSwipe(
    onOpenNotes: onOpenNotes,
    onCreateNote: onCreateNote,
    child: const Column(
      children: [
        Expanded(child: ColoredBox(color: Color(0xFFFAFAFA))),
        PageSwipeExclusion(
          child: SizedBox(
            height: 56,
            width: double.infinity,
            child: ColoredBox(color: Color(0xFF202125)),
          ),
        ),
      ],
    ),
  ),
);

void main() {
  testWidgets('a deliberate right swipe opens notes from the right half', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var opened = 0;
    await tester.pumpWidget(
      _harness(onOpenNotes: () => opened++, onCreateNote: () {}),
    );

    final swipe = await tester.startGesture(const Offset(330, 400));
    await swipe.moveBy(const Offset(40, 0));
    await tester.pump();
    expect(find.text('Swipe right for notes'), findsOneWidget);
    final surface = tester.widget<Container>(
      find.byKey(const ValueKey('mobile-page-swipe-cue-surface')),
    );
    final decoration = surface.decoration! as BoxDecoration;
    expect(decoration.boxShadow, anyOf(isNull, isEmpty));
    expect(
      tester.widget<Text>(find.text('Swipe right for notes')).style!.fontWeight,
      FontWeight.w400,
    );

    await swipe.moveBy(const Offset(40, 0));
    await tester.pump();
    expect(find.text('Release for notes'), findsOneWidget);
    expect(opened, 0, reason: 'crossing the threshold is not the action');

    await swipe.up();
    await tester.pump();
    expect(opened, 1);
  });

  testWidgets('a deliberate left swipe previews and confirms a new note', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var created = 0;
    await tester.pumpWidget(
      _harness(onOpenNotes: () {}, onCreateNote: () => created++),
    );

    final swipe = await tester.startGesture(const Offset(320, 400));
    await swipe.moveBy(const Offset(-60, 0));
    await tester.pump();
    expect(find.text('Swipe left for new note'), findsOneWidget);

    await swipe.moveBy(const Offset(-100, 0));
    await tester.pump();
    expect(find.text('Release for new note'), findsOneWidget);
    expect(created, 0);

    await swipe.up();
    await tester.pump();
    expect(created, 1);
    expect(find.text('New note created'), findsOneWidget);
  });

  testWidgets('retreating below the threshold cancels before release', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var created = 0;
    await tester.pumpWidget(
      _harness(onOpenNotes: () {}, onCreateNote: () => created++),
    );

    final swipe = await tester.startGesture(const Offset(320, 400));
    await swipe.moveBy(const Offset(-160, 0));
    await tester.pump();
    expect(find.text('Release for new note'), findsOneWidget);

    await swipe.moveBy(const Offset(80, 0));
    await tester.pump();
    expect(find.text('Swipe left for new note'), findsOneWidget);

    await swipe.up();
    await tester.pump();
    expect(created, 0);
    expect(find.text('New note created'), findsNothing);
  });

  testWidgets('short, vertical, long-press, and mouse drags do nothing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var actions = 0;
    await tester.pumpWidget(
      _harness(onOpenNotes: () => actions++, onCreateNote: () => actions++),
    );

    await tester.dragFrom(const Offset(210, 400), const Offset(-50, 0));
    expect(actions, 0, reason: 'a short drag is not intentional enough');
    await tester.dragFrom(const Offset(210, 400), const Offset(-160, 130));
    expect(actions, 0, reason: 'a diagonal drag belongs to vertical scroll');

    final longPress = await tester.startGesture(const Offset(210, 400));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
    await longPress.moveBy(const Offset(-160, 0));
    await longPress.up();
    expect(actions, 0, reason: 'a long press belongs to text selection');

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(210, 400));
    await mouse.down(const Offset(210, 400));
    await mouse.moveBy(const Offset(160, 0));
    await mouse.up();
    await tester.pump();

    expect(actions, 0, reason: 'pointer drags keep their desktop behavior');
    expect(find.byKey(const ValueKey('mobile-page-swipe-cue')), findsNothing);
  });

  group('the footer', () {
    testWidgets('keeps a right drag along it to itself', (tester) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var opened = 0;
      await tester.pumpWidget(
        _withFooter(onOpenNotes: () => opened++, onCreateNote: () {}),
      );

      // Well past the threshold an identical drag on the note would clear.
      final swipe = await tester.startGesture(const Offset(120, 772));
      await swipe.moveBy(const Offset(80, 0));
      await tester.pump();
      expect(find.byKey(const ValueKey('mobile-page-swipe-cue')), findsNothing);

      await swipe.moveBy(const Offset(120, 0));
      await tester.pump();
      await swipe.up();
      await tester.pump();

      expect(opened, 0);
      expect(find.byKey(const ValueKey('mobile-page-swipe-cue')), findsNothing);
    });

    testWidgets('keeps a left drag along it to itself', (tester) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var created = 0;
      await tester.pumpWidget(
        _withFooter(onOpenNotes: () {}, onCreateNote: () => created++),
      );

      await tester.dragFrom(const Offset(320, 772), const Offset(-200, 0));
      await tester.pumpAndSettle();

      expect(created, 0);
      expect(find.text('New note created'), findsNothing);
    });

    testWidgets('leaves the rest of the page swiping as before', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var opened = 0;
      await tester.pumpWidget(
        _withFooter(onOpenNotes: () => opened++, onCreateNote: () {}),
      );

      // One pixel above the bar is still the note.
      await tester.dragFrom(const Offset(120, 740), const Offset(200, 0));
      await tester.pumpAndSettle();
      expect(opened, 1);
    });

    testWidgets(
      'a drag that ends over it still counts, once begun on the note',
      (tester) async {
        tester.view.physicalSize = const Size(420, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        var opened = 0;
        await tester.pumpWidget(
          _withFooter(onOpenNotes: () => opened++, onCreateNote: () {}),
        );

        // Only where the finger lands decides. A diagonal drag that drifts down
        // onto the bar has already been read as a page swipe.
        final swipe = await tester.startGesture(const Offset(100, 700));
        await swipe.moveBy(const Offset(120, 40));
        await swipe.moveBy(const Offset(120, 40));
        await tester.pump();
        await swipe.up();
        await tester.pumpAndSettle();
        expect(opened, 1);
      },
    );
  });
}
