import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:kapy_notes/audio/voice_recording_controller.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/editor/voice_recording_bar.dart';

import 'test_fonts.dart';

VoiceRecordingSession session({
  double level = 0,
  int sampleSequence = 0,
  Duration elapsed = const Duration(seconds: 12),
  bool paused = false,
  bool interrupted = false,
  bool finishing = false,
}) => VoiceRecordingSession(
  noteId: 'note-1',
  level: level,
  sampleSequence: sampleSequence,
  elapsed: elapsed,
  paused: paused,
  interrupted: interrupted,
  finishing: finishing,
);

Widget harness(
  VoiceRecordingSession value, {
  Brightness brightness = Brightness.dark,
}) => MaterialApp(
  theme: brightness == Brightness.dark ? KapyTheme.dark() : KapyTheme.light(),
  home: Scaffold(
    body: Align(
      alignment: Alignment.bottomCenter,
      child: VoiceRecordingBar(
        session: value,
        onPause: () {},
        onResume: () {},
        onCancel: () {},
        onStop: () {},
      ),
    ),
  ),
);

RecordingWaveformPainter waveform(WidgetTester tester) =>
    tester
            .widget<CustomPaint>(
              find.byKey(const ValueKey('recording-waveform')),
            )
            .painter!
        as RecordingWaveformPainter;

Future<void> buildHistory(WidgetTester tester) async {
  const levels = [0.12, 0.28, 0.72, 0.44, 0.9, 0.36, 0.64, 0.18];
  await tester.pumpWidget(harness(session()));
  for (var index = 0; index < levels.length; index++) {
    await tester.pumpWidget(
      harness(session(level: levels[index], sampleSequence: index + 1)),
    );
  }
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  setUpAll(loadTestFonts);

  setUp(() {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
  });

  tearDown(() {
    AppPlatform.debugTargetPlatformOverride = null;
  });

  testWidgets('turns microphone levels into a bounded live waveform', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await buildHistory(tester);

    final painter = waveform(tester);
    expect(painter.levels, hasLength(40));
    expect(painter.levels.where((level) => level > 0), hasLength(8));
    expect(painter.levels.last, 0.18);
    expect(painter.active, isTrue);
    expect(find.text('Recording'), findsOneWidget);
    expect(find.byTooltip('Pause recording'), findsOneWidget);
    expect(find.byTooltip('Discard recording'), findsOneWidget);
    expect(find.byTooltip('Stop and keep recording'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('recording-stop'))),
      const Size.square(32),
    );
  });

  testWidgets('keeps the waveform but clearly marks a pause', (tester) async {
    tester.view.physicalSize = const Size(600, 100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await buildHistory(tester);
    await tester.pumpWidget(
      harness(session(level: 0, sampleSequence: 8, paused: true)),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Recording paused'), findsOneWidget);
    expect(find.byTooltip('Resume recording'), findsOneWidget);
    expect(waveform(tester).active, isFalse);
    expect(waveform(tester).levels.where((level) => level > 0), hasLength(8));
  });

  testWidgets('uses the waveform well for compact interruption feedback', (
    tester,
  ) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    tester.view.physicalSize = const Size(320, 100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness(session(interrupted: true)));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Recording interrupted'), findsOneWidget);
    expect(find.byTooltip('Resume recording'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('recording-stop'))),
      const Size.square(48),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('replaces actions with calm progress while saving', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness(session(finishing: true)));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Saving voice note…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byKey(const ValueKey('recording-stop')), findsNothing);
    expect(find.byTooltip('Discard recording'), findsNothing);
  });

  testWidgets('keeps its controls clear of the home indicator', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness(session()));
    await tester.pumpAndSettle();

    final bar = tester.getRect(find.byType(VoiceRecordingBar));
    // It stands in for the footer, so it holds the same edge: background to
    // the bottom of the screen, buttons above the indicator.
    expect(bar.bottom, closeTo(844, 0.01));
    expect(bar.height, closeTo(AppControlMetrics.footerHeight + 34, 0.01));
    expect(
      tester.getRect(find.byKey(const ValueKey('recording-stop'))).bottom,
      lessThanOrEqualTo(844 - 34),
    );
  });

  testWidgets('desktop active recording bar golden', (tester) async {
    tester.view.physicalSize = const Size(600, 100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await buildHistory(tester);

    await expectLater(
      find.byType(VoiceRecordingBar),
      matchesGoldenFile('goldens/voice_recording_bar_desktop_dark.png'),
    );
  });
}
