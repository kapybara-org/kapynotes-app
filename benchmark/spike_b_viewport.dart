// HIS-14 spike B: how a note sliver that lays out only the visible lines
// opens, flings and jumps to the end of a long note.
//
// The note is benchmark/markdown_rendering.dart's 5,000-line note, or that
// note's pattern of 166-line sections repeated to KAPY_SPIKE_LINES lines. Each
// run opens it three times. Then, each on a fresh open, it flings from the top
// to the bottom through the platform's scroll physics, twice; flicks once at
// the physics' own fling cap, and once at the most that repeated swipes carry;
// flings back up from the end over lines nobody has measured; jumps exactly to
// the end; jumps to the end the naive way, for comparison; and lays out every
// line once, to time what idle-time measuring would cost. It prints
// SPIKE_B_VIEWPORT and the figures as JSON, also written to
// spike_b_viewport.json in the app's temporary directory, and quits.
//
// A throwaway prototype's harness, built like the other benchmarks:
//
//   FLUTTER_XCODE_PRODUCT_BUNDLE_IDENTIFIER=com.kapybara.kapynotes.kapy5b \
//     flutter build macos --profile --dart-define=KAPYNOTES_SYNC=false \
//     -t benchmark/spike_b_viewport.dart
//   open -n --env KAPY_SPIKE_LINES=20000 \
//     "build/macos/Build/Products/Profile/Kapy Notes.app"
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show FramePhase;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/calc/highlight.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/main.dart' as app;
import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

import 'markdown_rendering.dart' as rendering;
import 'spike_b_note_sliver.dart';

final int _lineCount =
    int.tryParse(Platform.environment['KAPY_SPIKE_LINES'] ?? '') ?? 5000;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(_runAll());
}

Future<void> _runAll() async {
  // The app's window waits hidden for the app's main to show it, and a
  // hidden window draws no frames.
  await windowManager.ensureInitialized();
  await windowManager.setSize(const Size(1280, 900));
  await windowManager.show();
  // Kept above other windows for the run: a profile build draws no frames
  // while its window is covered.
  await windowManager.setAlwaysOnTop(true);
  SchedulerBinding.instance.addPersistentFrameCallback(_onFrame);
  Timer.periodic(const Duration(seconds: 1), (_) => _watch());
  final report = <String, Object?>{};
  try {
    await _run(report);
  } on _FramesStopped catch (stopped) {
    report['frames_stopped'] = stopped.where;
    _say('FRAMES STOPPED in ${stopped.where}');
  }
  final line = jsonEncode(report);
  _write(report);
  _say('SPIKE_B_VIEWPORT $line');
  if (report.isEmpty) await app.main();
  exit(0);
}

final Stopwatch _clock = Stopwatch()..start();

void _say(String line) {
  // ignore: avoid_print
  print('$line (at ${(_clock.elapsedMilliseconds / 1000).toStringAsFixed(1)} s)');
}

void _write(Map<String, Object?> report) {
  File(
    '${Directory.systemTemp.path}/spike_b_viewport.json',
  ).writeAsStringSync(jsonEncode(report));
}

/// Frames drawn since launch, and how many seconds in a row a frame has been
/// asked for without one being drawn.
int _framesDrawn = 0;
int _framesSeen = 0;
int _stalledSeconds = 0;

void _watch() {
  if (_framesDrawn == _framesSeen &&
      SchedulerBinding.instance.hasScheduledFrame) {
    _stalledSeconds++;
    if (_stalledSeconds == 3) _say('no frame drawn for 3 s');
  } else {
    _stalledSeconds = 0;
  }
  _framesSeen = _framesDrawn;
}

class _FramesStopped implements Exception {
  _FramesStopped(this.where);
  final String where;
}

/// The end of the next frame, or [_FramesStopped] if none comes in 10 s.
Future<void> _frame(String where) async {
  try {
    await WidgetsBinding.instance.endOfFrame.timeout(
      const Duration(seconds: 10),
    );
  } on TimeoutException {
    throw _FramesStopped(where);
  }
}

/// What the sliver had done by the end of a frame: lines measured,
/// paragraphs built, the time spent on spans and on layout, corrections, and
/// where the view was.
typedef _Snapshot = ({
  int measured,
  int built,
  int span,
  int layout,
  int corrections,
  double pixels,
  int line,
});

_Recorder? _recording;

void _onFrame(Duration _) {
  _framesDrawn++;
  final recorder = _recording;
  if (recorder == null) return;
  recorder.snapshots.add(recorder.snapshot());
}

class _Recorder {
  _Recorder(this.layout, this.position);

  final NoteLayout layout;
  final ScrollPosition? position;
  final List<FrameTiming> timings = [];
  final List<_Snapshot> snapshots = [];
  late _Snapshot _before;

  _Snapshot snapshot() {
    final pixels = position?.pixels ?? 0;
    return (
      measured: layout.stats.measured,
      built: layout.cache.misses,
      span: layout.cache.spanMicros,
      layout: layout.cache.layoutMicros,
      corrections: layout.stats.corrections,
      pixels: pixels,
      line: layout.index.lineAt(pixels),
    );
  }

  _Snapshot _previous(int frame) =>
      frame == 0 ? _before : snapshots[frame - 1];

  void _take(List<FrameTiming> batch) => timings.addAll(batch);

  /// Starts taking timings, waits until the timings of every earlier frame
  /// have arrived (they come at least once a second), and then starts
  /// recording, so that the timings that follow belong to the frames the
  /// snapshots see, in order.
  Future<void> arm() async {
    SchedulerBinding.instance.addTimingsCallback(_take);
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    timings.clear();
    _before = snapshot();
    _recording = this;
  }

  /// Stops taking snapshots, then waits for the timings, which arrive in
  /// batches about once a second in profile mode.
  Future<void> stop() async {
    _recording = null;
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    SchedulerBinding.instance.removeTimingsCallback(_take);
  }

  /// The timings of the frames the snapshots saw: the first as many as
  /// there are snapshots. Later ones are frames after recording stopped,
  /// such as the scrollbar fading out.
  List<FrameTiming> get matched => timings.take(snapshots.length).toList();

  Map<String, Object?> perFrameWork() {
    if (snapshots.isEmpty) return {'frames': 0};
    final lines = <double>[];
    final ms = <double>[];
    for (var i = 0; i < snapshots.length; i++) {
      final before = _previous(i);
      final after = snapshots[i];
      lines.add((after.measured - before.measured).toDouble());
      ms.add(
        (after.span + after.layout - before.span - before.layout) / 1000,
      );
    }
    return {
      'frames': snapshots.length,
      'lines_laid_out_per_frame': _stats(lines),
      'span_and_layout_ms_per_frame': _stats(ms),
    };
  }

  /// The [count] frames that took longest to build, with what the sliver did
  /// in each and the first line on screen at its end.
  List<Map<String, Object?>> worstFrames(int count) {
    final frames = matched;
    final order = [for (var i = 0; i < frames.length; i++) i]
      ..sort(
        (a, b) => frames[b].buildDuration.compareTo(frames[a].buildDuration),
      );
    return [
      for (final i in order.take(count))
        {
          'frame': i,
          'build_ms': _ms(frames[i].buildDuration),
          'raster_ms': _ms(frames[i].rasterDuration),
          'lines_measured': snapshots[i].measured - _previous(i).measured,
          'paragraphs_built': snapshots[i].built - _previous(i).built,
          'span_ms': (snapshots[i].span - _previous(i).span) / 1000,
          'layout_ms': (snapshots[i].layout - _previous(i).layout) / 1000,
          'first_line': snapshots[i].line,
        },
    ];
  }
}

/// [values] at the [p]th percentile, by nearest rank.
double _percentile(List<double> values, double p) {
  final sorted = [...values]..sort();
  final rank = (p / 100 * sorted.length).ceil().clamp(1, sorted.length);
  return sorted[rank - 1];
}

Map<String, double> _stats(List<double> values) => values.isEmpty
    ? const {}
    : {
        'p50': _percentile(values, 50),
        'p95': _percentile(values, 95),
        'p99': _percentile(values, 99),
        'max': _percentile(values, 100),
      };

double _ms(Duration duration) => duration.inMicroseconds / 1000;

Map<String, Object?> _frameStats(List<FrameTiming> timings) {
  const budget = 16.0;
  final build = [for (final t in timings) _ms(t.buildDuration)];
  final raster = [for (final t in timings) _ms(t.rasterDuration)];
  final total = [for (final t in timings) _ms(t.totalSpan)];
  final starts = [
    for (final t in timings) t.timestampInMicroseconds(FramePhase.vsyncStart),
  ];
  final intervals = [
    for (var i = 1; i < starts.length; i++) (starts[i] - starts[i - 1]) / 1000,
  ];
  return {
    'frames': timings.length,
    'build_ms': _stats(build),
    'raster_ms': _stats(raster),
    'total_span_ms': _stats(total),
    'build_over_16ms': build.where((ms) => ms > budget).length,
    'raster_over_16ms': raster.where((ms) => ms > budget).length,
    'frames_over_16ms': [
      for (var i = 0; i < timings.length; i++)
        if (build[i] > budget || raster[i] > budget) i,
    ].length,
    'vsync_interval_ms_p50': intervals.isEmpty
        ? null
        : _percentile(intervals, 50),
  };
}

void _show(Widget home) {
  runApp(MaterialApp(key: UniqueKey(), theme: KapyTheme.dark(), home: home));
}

final Highlighter _highlighter = Highlighter(CalcEngine().registry);

/// Shows [body] in a fresh view and hands back its layout and scroll
/// controller once the first frame is drawn. [opened] is called with the
/// time from showing it to the end of that frame.
Future<(NoteLayout, ScrollController)> _openView(
  String body, {
  void Function(double ms)? opened,
}) async {
  _show(const SizedBox.shrink());
  await _frame('opening');
  await Future<void>.delayed(const Duration(seconds: 1));
  late NoteLayout layout;
  late ScrollController scroll;
  final stopwatch = Stopwatch()..start();
  _show(
    Scaffold(
      body: SpikeNoteView(
        body: body,
        highlighter: _highlighter,
        onReady: (l, s) {
          layout = l;
          scroll = s;
        },
      ),
    ),
  );
  await _frame('opening');
  opened?.call(stopwatch.elapsedMicroseconds / 1000);
  return (layout, scroll);
}

Future<Map<String, Object?>> _open(String body) async {
  final timings = <FrameTiming>[];
  void record(List<FrameTiming> batch) => timings.addAll(batch);
  SchedulerBinding.instance.addTimingsCallback(record);
  var firstFrame = 0.0;
  final (layout, _) = await _openView(body, opened: (ms) => firstFrame = ms);
  final cache = layout.cache;
  final measuredAtFirstFrame = layout.stats.measured;
  final spanMs = cache.spanMicros / 1000;
  final layoutMs = cache.layoutMicros / 1000;
  await Future<void>.delayed(const Duration(seconds: 2));
  SchedulerBinding.instance.removeTimingsCallback(record);
  double slowest(Iterable<double> values) =>
      values.fold<double>(0, (a, b) => a > b ? a : b);
  return {
    'first_frame_ms': firstFrame,
    'setup_ms': layout.setupMicros / 1000,
    'lines_laid_out': measuredAtFirstFrame,
    'span_ms': spanMs,
    'paragraph_layout_ms': layoutMs,
    'slowest_build_ms': slowest([for (final t in timings) _ms(t.buildDuration)]),
    'slowest_raster_ms': slowest([
      for (final t in timings) _ms(t.rasterDuration),
    ]),
  };
}

/// Resolves when [position] stops scrolling, or after [timeout].
Future<bool> _settled(ScrollPosition position, Duration timeout) {
  final done = Completer<bool>();
  late VoidCallback listener;
  listener = () {
    if (!position.isScrollingNotifier.value && !done.isCompleted) {
      done.complete(true);
    }
  };
  position.isScrollingNotifier.addListener(listener);
  listener();
  final timer = Timer(timeout, () {
    if (!done.isCompleted) done.complete(false);
  });
  return done.future.whenComplete(() {
    timer.cancel();
    position.isScrollingNotifier.removeListener(listener);
  });
}

/// The velocity that carries [position]'s own physics [distance] pixels
/// from where it is, with nothing to stop it.
double _velocityFor(ScrollPosition position, double distance) {
  final metrics = position.copyWith(maxScrollExtent: 1e12);
  double reach(double velocity) {
    final simulation = position.physics.createBallisticSimulation(
      metrics,
      velocity,
    );
    return simulation == null ? 0 : simulation.x(1000) - position.pixels;
  }

  var low = 0.0;
  var high = 1000.0;
  while (reach(high) < distance) {
    high *= 2;
  }
  for (var i = 0; i < 60; i++) {
    final middle = (low + high) / 2;
    if (reach(middle) < distance) {
      low = middle;
    } else {
      high = middle;
    }
  }
  return high;
}

/// Flings from where the view is with [velocity], or with whatever velocity
/// carries the physics a little past the end of the note.
Future<Map<String, Object?>> _fling(
  String body, {
  double? velocity,
  bool fromEnd = false,
}) async {
  final (layout, scroll) = await _openView(body);
  final position = scroll.position as ScrollPositionWithSingleContext;
  if (fromEnd) {
    layout.jumpToEnd();
    await _frame('jumping to the end before flinging up');
  }
  final measuredBefore = layout.index.measuredCount;
  final correctionsBefore = layout.stats.corrections;
  final start = position.pixels;
  final speed =
      velocity ??
      _velocityFor(
        position,
        (position.maxScrollExtent - position.pixels) * 1.05 +
            position.viewportDimension,
      );
  final recorder = _Recorder(layout, position);
  await recorder.arm();
  final clock = Stopwatch()..start();
  position.goBallistic(speed);
  final stopped = await _settled(position, const Duration(seconds: 30));
  if (!stopped && _stalledSeconds > 0) throw _FramesStopped('a fling');
  final elapsed = clock.elapsedMicroseconds / 1000;
  final travelled = position.pixels - start;
  await recorder.stop();
  final matched = recorder.matched;
  return {
    'physics': position.physics.toString(),
    'velocity_px_s': speed,
    'stopped': stopped,
    'duration_ms': elapsed,
    'travelled_px': travelled,
    'final_pixels': position.pixels,
    'max_scroll_extent': position.maxScrollExtent,
    'at_end': (position.pixels - position.maxScrollExtent).abs() < 0.5,
    'estimated_total_px': layout.estimatedTotal,
    'total_px_after': layout.index.total,
    'lines_measured': layout.index.measuredCount - measuredBefore,
    'corrections': layout.stats.corrections - correctionsBefore,
    'correction_max_px': layout.stats.correctionMax,
    'anchor_drift_max_px': layout.stats.anchorDriftMax,
    'fling_frames': _frameStats(matched),
    'timings_after_start': recorder.timings.length,
    'snapshot_frames': recorder.snapshots.length,
    'work': recorder.perFrameWork(),
    'worst_frames': recorder.worstFrames(3),
  };
}

Future<Map<String, Object?>> _jump(String body, {required bool exact}) async {
  final (layout, scroll) = await _openView(body);
  final position = scroll.position;
  final recorder = _Recorder(layout, position);
  await recorder.arm();
  final clock = Stopwatch()..start();
  if (exact) {
    layout.jumpToEnd();
  } else {
    position.jumpTo(position.maxScrollExtent);
  }
  await _frame('a jump to the end');
  final firstFrame = clock.elapsedMicroseconds / 1000;
  double? gap() {
    final render = layout.renderSliver;
    final last = layout.length - 1;
    final top = render?.screenTopOf(last);
    if (top == null) return null;
    return position.viewportDimension - (top + layout.index.heightOf(last));
  }

  final gapAtFirstFrame = gap();
  var state = (position.pixels, position.maxScrollExtent, layout.index.total);
  var settled = firstFrame;
  var quiet = 0;
  var frames = 1;
  while (quiet < 10 && clock.elapsed < const Duration(seconds: 5)) {
    WidgetsBinding.instance.scheduleFrame();
    await _frame('settling a jump');
    frames++;
    final now = (position.pixels, position.maxScrollExtent, layout.index.total);
    if (now != state) {
      state = now;
      settled = clock.elapsedMicroseconds / 1000;
      quiet = 0;
    } else {
      quiet++;
    }
  }
  await recorder.stop();
  return {
    'exact': exact,
    'first_frame_ms': firstFrame,
    'settled_ms': settled,
    'frames_until_quiet': frames,
    'gap_under_last_line_at_first_frame_px': gapAtFirstFrame,
    'gap_under_last_line_px': gap(),
    'pixels_minus_max_scroll_extent': position.pixels - position.maxScrollExtent,
    'lines_measured': layout.index.measuredCount,
    'frames': _frameStats(recorder.matched),
    'work': recorder.perFrameWork(),
    'worst_frames': recorder.worstFrames(2),
  };
}

Future<Map<String, Object?>> _measureAll(String body) async {
  final (layout, _) = await _openView(body);
  final clock = Stopwatch()..start();
  for (var line = 0; line < layout.length; line++) {
    layout.measure(line);
  }
  final ms = clock.elapsedMicroseconds / 1000;
  final measured = layout.index.total;
  return {
    'ms': ms,
    'us_per_line': ms * 1000 / layout.length,
    'span_ms': layout.cache.spanMicros / 1000,
    'paragraph_layout_ms': layout.cache.layoutMicros / 1000,
    'cache_misses': layout.cache.misses,
    'estimated_total_px': layout.estimatedTotal,
    'measured_total_px': measured,
    'estimate_error_pct':
        (layout.estimatedTotal - measured) / measured * 100,
    'lines_estimated_wrong': layout.stats.estimateMisses,
  };
}

Future<void> _run(Map<String, Object?> report) async {
  final body = _lineCount == 5000
      ? rendering.longNote()
      : repeatedNote(_lineCount);
  report
    ..['lines'] = _lineCount
    ..['characters'] = body.length
    ..['semantics'] = SemanticsBinding.instance.semanticsEnabled
    ..['device_pixel_ratio'] = WidgetsBinding
        .instance
        .platformDispatcher
        .views
        .first
        .devicePixelRatio;
  final opens = <Map<String, Object?>>[];
  report['open'] = opens;
  for (var i = 1; i <= 3; i++) {
    opens.add(await _open(body));
    _say(
      'opened $i of 3: ${opens.last['first_frame_ms']} ms to the first frame',
    );
  }
  _write(report);
  String brief(Map<String, Object?> fling) => jsonEncode({
    for (final key in [
      'duration_ms',
      'stopped',
      'at_end',
      'snapshot_frames',
      'timings_after_start',
      'corrections',
    ])
      key: fling[key],
    'frames': fling['fling_frames'],
  });
  final fling = report['fling_top_to_bottom'] = await _fling(body);
  _say('flung top to bottom: ${brief(fling)}');
  _write(report);
  // The same again, on a fresh view: what is left once the process has
  // paid its one-time costs, such as compiling each code language's rules.
  final again = report['fling_top_to_bottom_again'] = await _fling(body);
  _say('flung top to bottom again: ${brief(again)}');
  _write(report);
  final flick = report['flick_at_cap'] = await _fling(body, velocity: 8000);
  _say('flicked at the cap: ${brief(flick)}');
  _write(report);
  // Swiping again while a fling runs adds BouncingScrollPhysics'
  // carriedMomentum, at most 40,000 px/s, to the gesture's own 8,000.
  final carried = report['flick_carried'] = await _fling(
    body,
    velocity: 48000,
  );
  _say('flicked with carried momentum: ${brief(carried)}');
  _write(report);
  final up = report['flick_up_from_end'] = await _fling(
    body,
    velocity: -8000,
    fromEnd: true,
  );
  _say('flicked up from the end: ${brief(up)}');
  _write(report);
  final exact = report['jump_to_end'] = await _jump(body, exact: true);
  _say('jumped to the end: ${jsonEncode(exact)}');
  _write(report);
  final naive = report['jump_to_end_naive'] = await _jump(body, exact: false);
  _say('jumped to the end the naive way: ${jsonEncode(naive)}');
  _write(report);
  final all = report['measure_every_line'] = await _measureAll(body);
  _say('measured every line: ${jsonEncode(all)}');
}
