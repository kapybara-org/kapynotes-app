import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/app_logo.dart';
import 'package:kapy_notes/ui/kapy_header_mascot.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';

const _statesGoldenKey = ValueKey('kapy-header-states');
const _sleepFramesGoldenKey = ValueKey('kapy-header-sleep-frames');

Widget _harness(
  KapyHeaderController controller, {
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
      body: Center(
        child: AppWordmark(
          markSize: 19,
          fontSize: 14.5,
          spacing: 6.5,
          mark: KapyHeaderMascot(controller: controller),
        ),
      ),
    ),
  );
}

KapyHeaderMascotState _state(WidgetTester tester) =>
    tester.state<KapyHeaderMascotState>(find.byType(KapyHeaderMascot));

Future<void> _finish(WidgetTester tester, Duration duration) async {
  // The zero-duration pump that starts an AnimationController establishes its
  // epoch; cross its nominal duration by a millisecond to deliver the terminal
  // tick and let the async sequence advance.
  await tester.pump(duration + const Duration(milliseconds: 1));
  await tester.pump();
}

Future<void> _precacheHeaderAssets(WidgetTester tester, Finder boundary) async {
  await tester.runAsync(() async {
    final context = tester.element(boundary);
    await Future.wait([
      precacheImage(const AssetImage(AppLogo.assetPath), context),
      for (final path in KapyHeaderMascot.runtimeAssetPaths)
        precacheImage(AssetImage(path), context),
    ]);
  });
  await tester.pump();
}

bool _usesAsset(WidgetTester tester, String assetPath) => tester
    .widgetList<Image>(find.byType(Image))
    .any(
      (image) =>
          image.image is AssetImage &&
          (image.image as AssetImage).assetName == assetPath,
    );

void main() {
  setUpAll(loadTestFonts);

  testWidgets('emerges, thinks, and returns through the logo', (tester) async {
    final controller = KapyHeaderController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_harness(controller));
    await tester.pumpAndSettle();

    expect(_state(tester).restingPose, KapyHeaderRestingPose.logo);
    final lockupAtRest = tester.getRect(find.byType(AppWordmark));

    controller.emerge();
    await tester.pump();
    expect(_state(tester).activeAnimation, KapyHeaderAnimation.emerge);
    expect(
      _state(tester).currentAtlasAssetPath,
      KapyHeaderMascot.emergeAtlasAssetPath,
    );
    expect(_state(tester).currentFrameIndex, 0);
    await tester.pump(const Duration(milliseconds: 240));
    expect(tester.getRect(find.byType(AppWordmark)), lockupAtRest);
    await _finish(tester, KapyHeaderMascot.emergeDuration);
    expect(_state(tester).restingPose, KapyHeaderRestingPose.standing);

    controller.hide();
    await tester.pump();
    expect(_state(tester).activeAnimation, KapyHeaderAnimation.hide);
    expect(
      _state(tester).currentAtlasAssetPath,
      KapyHeaderMascot.emergeAtlasAssetPath,
    );
    expect(
      _state(tester).currentFrameIndex,
      KapyHeaderMascot.emergeFrameCount - 1,
    );
    await _finish(tester, KapyHeaderMascot.hideDuration);
    expect(_state(tester).restingPose, KapyHeaderRestingPose.logo);

    controller.think();
    await tester.pump();
    await _finish(tester, KapyHeaderMascot.emergeDuration);
    expect(_state(tester).activeAnimation, KapyHeaderAnimation.think);
    await _finish(tester, KapyHeaderMascot.thinkDuration);
    expect(_state(tester).activeAnimation, KapyHeaderAnimation.hide);
    await _finish(tester, KapyHeaderMascot.hideDuration);
    expect(_state(tester).restingPose, KapyHeaderRestingPose.logo);
  });

  testWidgets('sleeps, wakes to standing, then hides separately', (
    tester,
  ) async {
    final controller = KapyHeaderController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_harness(controller));
    await tester.pumpAndSettle();

    controller.sleep();
    await tester.pump();
    await _finish(tester, KapyHeaderMascot.emergeDuration);
    expect(_state(tester).activeAnimation, KapyHeaderAnimation.sleep);
    expect(
      _state(tester).currentAtlasAssetPath,
      KapyHeaderMascot.sleepAtlasAssetPath,
    );
    await _finish(tester, KapyHeaderMascot.sleepDuration);
    expect(_state(tester).restingPose, KapyHeaderRestingPose.sleeping);
    expect(controller.needsWake, isTrue);
    expect(find.byKey(KapyHeaderMascot.sleepingKey), findsOneWidget);
    expect(
      _state(tester).currentAtlasAssetPath,
      KapyHeaderMascot.sleepLoopAtlasAssetPath,
    );

    controller.wake();
    await tester.pump();
    expect(_state(tester).activeAnimation, KapyHeaderAnimation.wake);
    expect(
      _state(tester).currentAtlasAssetPath,
      KapyHeaderMascot.sleepAtlasAssetPath,
    );
    expect(
      _state(tester).currentFrameIndex,
      KapyHeaderMascot.sleepFrameCount - 1,
    );
    await _finish(tester, KapyHeaderMascot.wakeDuration);
    expect(_state(tester).restingPose, KapyHeaderRestingPose.standing);
    expect(controller.needsWake, isFalse);
    expect(find.byKey(KapyHeaderMascot.sleepingKey), findsNothing);

    controller.hide();
    await tester.pump();
    await _finish(tester, KapyHeaderMascot.hideDuration);
    expect(_state(tester).restingPose, KapyHeaderRestingPose.logo);
  });

  testWidgets('user activity can interrupt sleep and return to the logo', (
    tester,
  ) async {
    final controller = KapyHeaderController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_harness(controller));
    await tester.pumpAndSettle();

    controller.sleep();
    await tester.pump();
    await _finish(tester, KapyHeaderMascot.emergeDuration);
    await tester.pump(const Duration(milliseconds: 380));
    expect(_state(tester).activeAnimation, KapyHeaderAnimation.sleep);
    final interruptedFrame = _state(tester).currentFrameIndex;

    controller.wake(hideAfter: true);
    await tester.pump();
    expect(_state(tester).activeAnimation, KapyHeaderAnimation.wake);
    expect(_state(tester).currentFrameIndex, interruptedFrame);
    await _finish(tester, KapyHeaderMascot.wakeDuration);
    expect(_state(tester).activeAnimation, KapyHeaderAnimation.hide);
    await _finish(tester, KapyHeaderMascot.hideDuration);
    expect(_state(tester).restingPose, KapyHeaderRestingPose.logo);
  });

  testWidgets('thinking plays the production 180-frame atlas at 30fps', (
    tester,
  ) async {
    final controller = KapyHeaderController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_harness(controller));
    await tester.pumpAndSettle();
    await _precacheHeaderAssets(tester, find.byType(AppWordmark));

    controller.emerge();
    await tester.pump();
    await _finish(tester, KapyHeaderMascot.emergeDuration);
    expect(_usesAsset(tester, KapyHeaderMascot.standingAssetPath), isTrue);

    controller.think();
    await tester.pump();
    await tester.pump(KapyHeaderMascot.thinkDuration * 0.22);
    expect(
      _state(tester).currentAtlasAssetPath,
      KapyHeaderMascot.thinkAtlasAssetPath,
    );
    expect(_state(tester).currentFrameIndex, 39);

    await tester.pump(KapyHeaderMascot.thinkDuration * 0.18);
    expect(_state(tester).currentFrameIndex, 72);

    await tester.pump(KapyHeaderMascot.thinkDuration * 0.19);
    expect(_state(tester).currentFrameIndex, 106);

    await tester.pump(KapyHeaderMascot.thinkDuration * 0.29);
    expect(_state(tester).currentFrameIndex, 158);
  });

  testWidgets('frames advance at 30fps at a restrained logo scale', (
    tester,
  ) async {
    int framesFor(Duration duration) =>
        duration.inMicroseconds *
        KapyHeaderMascot.framesPerSecond ~/
        Duration.microsecondsPerSecond;

    expect(
      KapyHeaderMascot.emergeFrameCount,
      framesFor(KapyHeaderMascot.emergeDuration),
    );
    expect(
      KapyHeaderMascot.thinkFrameCount,
      framesFor(KapyHeaderMascot.thinkDuration),
    );
    expect(
      KapyHeaderMascot.sleepFrameCount,
      framesFor(KapyHeaderMascot.sleepDuration),
    );
    expect(
      KapyHeaderMascot.sleepLoopFrameCount,
      framesFor(KapyHeaderMascot.sleepLoopDuration),
    );
    expect(
      KapyHeaderMascot.emergeDuration,
      greaterThanOrEqualTo(const Duration(milliseconds: 1000)),
    );
    expect(
      KapyHeaderMascot.thinkDuration,
      greaterThanOrEqualTo(const Duration(milliseconds: 6000)),
    );

    final controller = KapyHeaderController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_harness(controller));
    await tester.pumpAndSettle();
    await _precacheHeaderAssets(tester, find.byType(AppWordmark));

    controller.emerge();
    await tester.pump();
    await _finish(tester, KapyHeaderMascot.emergeDuration);
    expect(
      tester.getSize(find.byKey(KapyHeaderMascot.characterKey)).height,
      lessThanOrEqualTo(25),
    );

    controller.think();
    await tester.pump();
    expect(_state(tester).currentFrameIndex, 0);

    await tester.pump(const Duration(milliseconds: 16));
    expect(_state(tester).currentFrameIndex, 0);

    await tester.pump(const Duration(milliseconds: 18));
    expect(_state(tester).currentFrameIndex, 1);

    await tester.pump(const Duration(milliseconds: 33));
    expect(_state(tester).currentFrameIndex, 2);
  });

  testWidgets('thinking is rendered as frames, not source-pose crossfades', (
    tester,
  ) async {
    final controller = KapyHeaderController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_harness(controller));
    await tester.pumpAndSettle();
    await _precacheHeaderAssets(tester, find.byType(AppWordmark));

    controller.emerge();
    await tester.pump();
    await _finish(tester, KapyHeaderMascot.emergeDuration);
    controller.think();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 34));

    expect(find.byType(Image), findsNothing);
  });

  testWidgets('reduced motion leaves the ordinary logo still', (tester) async {
    final controller = KapyHeaderController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_harness(controller, disableAnimations: true));
    await tester.pumpAndSettle();

    controller.think();
    controller.sleep();
    await tester.pump(const Duration(seconds: 2));

    expect(_state(tester).restingPose, KapyHeaderRestingPose.logo);
    expect(find.byType(AppLogo), findsOneWidget);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('header mascot production-size states', (tester) async {
    tester.view.physicalSize = const Size(436, 88);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final standing = KapyHeaderController();
    final countOne = KapyHeaderController();
    final countTwo = KapyHeaderController();
    final countThree = KapyHeaderController();
    final scratching = KapyHeaderController();
    final sleeping = KapyHeaderController();
    addTearDown(standing.dispose);
    addTearDown(countOne.dispose);
    addTearDown(countTwo.dispose);
    addTearDown(countThree.dispose);
    addTearDown(scratching.dispose);
    addTearDown(sleeping.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: _statesGoldenKey,
              child: ColoredBox(
                color: const Color(0xFF202020),
                child: SizedBox(
                  width: 420,
                  height: 72,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      KapyHeaderMascot(
                        key: const ValueKey('standing'),
                        controller: standing,
                      ),
                      KapyHeaderMascot(
                        key: const ValueKey('count-one'),
                        controller: countOne,
                      ),
                      KapyHeaderMascot(
                        key: const ValueKey('count-two'),
                        controller: countTwo,
                      ),
                      KapyHeaderMascot(
                        key: const ValueKey('count-three'),
                        controller: countThree,
                      ),
                      KapyHeaderMascot(
                        key: const ValueKey('scratching'),
                        controller: scratching,
                      ),
                      KapyHeaderMascot(
                        key: const ValueKey('sleeping'),
                        controller: sleeping,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await _precacheHeaderAssets(tester, find.byKey(_statesGoldenKey));

    standing.emerge();
    countOne.emerge();
    countTwo.emerge();
    countThree.emerge();
    scratching.emerge();
    sleeping.emerge();
    await tester.pump();
    await _finish(tester, KapyHeaderMascot.emergeDuration);

    // Stagger the sequences so one production-size render includes every
    // source pose at the exact frame where it is used by the real timeline.
    sleeping.sleep();
    scratching.think();
    await tester.pump();
    await tester.pump(KapyHeaderMascot.thinkDuration * 0.29);
    countThree.think();
    await tester.pump();
    await tester.pump(KapyHeaderMascot.thinkDuration * 0.19);
    countTwo.think();
    await tester.pump();
    await tester.pump(KapyHeaderMascot.thinkDuration * 0.18);
    countOne.think();
    await tester.pump();
    await tester.pump(KapyHeaderMascot.thinkDuration * 0.22);

    await expectLater(
      find.byKey(_statesGoldenKey),
      matchesGoldenFile('goldens/kapy_header_states.png'),
    );
  });

  testWidgets('sleep transition key frames', (tester) async {
    tester.view.physicalSize = const Size(436, 88);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final controllers = List.generate(6, (_) => KapyHeaderController());
    for (final controller in controllers) {
      addTearDown(controller.dispose);
    }

    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: _sleepFramesGoldenKey,
              child: ColoredBox(
                color: const Color(0xFF202020),
                child: SizedBox(
                  width: 420,
                  height: 72,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      for (var index = 0; index < controllers.length; index++)
                        KapyHeaderMascot(
                          key: ValueKey('sleep-frame-$index'),
                          controller: controllers[index],
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await _precacheHeaderAssets(tester, find.byKey(_sleepFramesGoldenKey));

    for (final controller in controllers) {
      controller.emerge();
    }
    await tester.pump();
    await _finish(tester, KapyHeaderMascot.emergeDuration);

    // Start right-to-left at even intervals so one render captures the whole
    // standing-to-sleeping transition at its actual production size.
    for (var index = controllers.length - 1; index >= 0; index--) {
      controllers[index].sleep();
      await tester.pump();
      if (index > 0) {
        await tester.pump(
          KapyHeaderMascot.sleepDuration ~/ (controllers.length - 1),
        );
      }
    }
    await tester.pump(const Duration(milliseconds: 1));

    await expectLater(
      find.byKey(_sleepFramesGoldenKey),
      matchesGoldenFile('goldens/kapy_header_sleep_frames.png'),
    );
  });
}
