// How fast does typing stay in a long markdown note?
//
// Five thousand lines of everything a markdown note holds — headings, lists,
// tasks, quotes, code, tables and sums — with markdown on, typed into the way
// a keyboard types: one editing-value update per key, about thirty a second,
// two hundred keys at the end of the note and two hundred in the middle.
// Then prints how long those frames took to build and to draw, and quits.
//
// Other sizes, plain notes and fewer keys come from defines, several sizes
// and modes in one run:
//
//   --dart-define=EDITOR_BENCHMARK_LINES=500,1000,5000
//   --dart-define=EDITOR_BENCHMARK_MODES=markdown,plain
//   --dart-define=EDITOR_BENCHMARK_KEYS=30
//
// A plain app rather than an integration test, because only profile mode
// says anything about frame times, and Flutter 3.47.4's AOT compiler fails on
// an entrypoint that leaves out the app's own windowing code ("Class with
// illegal cid" in _window_macos.dart). This one keeps the app's `main`
// reachable, never calling it, so it compiles the way the app does. Run it
// under a bundle id of its own, never the real app's:
//
//   FLUTTER_XCODE_PRODUCT_BUNDLE_IDENTIFIER=com.kapybara.kapynotes.typingperf \
//     flutter run --profile -d macos -t benchmark/editor_typing.dart \
//     --dart-define=KAPYNOTES_SYNC=false
//
// The figures are the line starting EDITOR_TYPING_PERF in the log: frame
// build and raster times at p50, p90, p95 and p99. Nothing runs it in CI.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/calc/highlight.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/main.dart' as app;
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/editor/note_field.dart';
import 'package:material_ui/material_ui.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'editor-typing-benchmark.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

/// A long note in the shapes people write: every kind of block, over and
/// over, [lines] lines of it.
String longNote({int lines = 5000}) {
  const pattern = [
    '## Section {n}',
    'Plain words about item {n}, with **bold**, *italic* and a '
        '[link](https://example.com/{n}).',
    '- groceries {n}: 3 * 4.50',
    '- [ ] call about invoice {n}',
    '- [x] paid {n} = 120 + 35',
    '  - nested detail {n}',
    '1. first step {n}',
    '2. second step',
    '> a quote worth keeping {n}',
    'rent {n} = 1200 / 2',
    '```dart',
    'final total = items.fold(0, (a, b) => a + b);',
    '```',
    '',
    '| Item | Cost |',
    '| --- | --- |',
    '| Taxi | 14 |',
    '',
    'Words with `inline code` and ~~struck~~ text and https://example.org/{n}',
    '',
  ];
  return [
    for (var i = 0; i < lines; i++)
      pattern[i % pattern.length].replaceAll('{n}', '$i'),
  ].join('\n');
}

/// [values] at the [p]th percentile, by nearest rank.
double percentile(List<double> values, double p) {
  final sorted = [...values]..sort();
  final rank = (p / 100 * sorted.length).ceil().clamp(1, sorted.length);
  return sorted[rank - 1];
}

Map<String, Object> summary(List<FrameTiming> timings) {
  double ms(Duration duration) => duration.inMicroseconds / 1000;
  const budget = 1000 / 60;
  final build = [for (final t in timings) ms(t.buildDuration)];
  final raster = [for (final t in timings) ms(t.rasterDuration)];
  Map<String, Object> stats(List<double> values) => {
    'p50': percentile(values, 50),
    'p90': percentile(values, 90),
    'p95': percentile(values, 95),
    'p99': percentile(values, 99),
    'max': percentile(values, 100),
    'over_16_7ms': values.where((value) => value > budget).length,
  };
  return {
    'frames': timings.length,
    'build_ms': stats(build),
    'raster_ms': stats(raster),
    'frames_over_16_7ms': [
      for (var i = 0; i < timings.length; i++)
        if (build[i] > budget || raster[i] > budget) i,
    ].length,
  };
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(_runAll());
}

Future<void> _runAll() async {
  const lines = String.fromEnvironment(
    'EDITOR_BENCHMARK_LINES',
    defaultValue: '5000',
  );
  const modes = String.fromEnvironment(
    'EDITOR_BENCHMARK_MODES',
    defaultValue: 'markdown',
  );
  final reports = [
    for (final mode in modes.split(','))
      for (final size in lines.split(','))
        await _run(lines: int.parse(size), markdown: mode == 'markdown'),
  ];
  // ignore: avoid_print
  print('EDITOR_TYPING_PERF ${jsonEncode(reports)}');
  if (reports.isEmpty) await app.main();
  exit(0);
}

void _show(String body, {required bool markdown}) {
  final engine = CalcEngine();
  runApp(
    MaterialApp(
      key: UniqueKey(),
      theme: KapyTheme.dark(),
      home: Scaffold(
        body: NoteEditor(
          noteId: 'benchmark',
          initialBody: body,
          engine: engine,
          highlighter: Highlighter(engine.registry),
          keepResultRoom: true,
          resultsVisible: true,
          markdownEnabled: markdown,
          autofocus: true,
          onDocumentChanged: (_, _, _, _) {},
          onSettingsPressed: () {},
          writingFont: WritingFont.handwritten,
          shortcuts: ShortcutPrefs(_MemoryStore())..load(),
        ),
      ),
    ),
  );
}

NoteFieldState _field() {
  NoteFieldState? found;
  void visit(Element element) {
    if (found != null) return;
    if (element is StatefulElement && element.state is NoteFieldState) {
      found = element.state as NoteFieldState;
      return;
    }
    element.visitChildElements(visit);
  }

  WidgetsBinding.instance.rootElement!.visitChildElements(visit);
  return found!;
}

Future<Map<String, Object>> _run({
  required int lines,
  required bool markdown,
}) async {
  final body = longNote(lines: lines);
  _show(body, markdown: markdown);
  await Future<void>.delayed(const Duration(seconds: 3));
  final field = _field();
  const sentence = 'The quick brown fox jumps over the lazy dog, 12 * 3. ';
  final keys = (sentence * 4).substring(
    0,
    const int.fromEnvironment('EDITOR_BENCHMARK_KEYS', defaultValue: 200),
  );

  Future<Map<String, Object>> typeAt(int caret) async {
    field.userUpdateTextEditingValue(
      field.widget.controller.value.copyWith(
        selection: TextSelection.collapsed(offset: caret),
      ),
      SelectionChangedCause.tap,
    );
    await Future<void>.delayed(const Duration(seconds: 1));
    final timings = <FrameTiming>[];
    void record(List<FrameTiming> batch) => timings.addAll(batch);
    SchedulerBinding.instance.addTimingsCallback(record);
    for (final key in keys.split('')) {
      // What the platform's text input sends for a key: an insertion into
      // the window of the note it holds.
      final value = field.currentTextEditingValue;
      final at = value.selection.start;
      field.updateEditingValueWithDeltas([
        TextEditingDeltaInsertion(
          oldText: value.text,
          textInserted: key,
          insertionOffset: at,
          selection: TextSelection.collapsed(offset: at + 1),
          composing: TextRange.empty,
        ),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 33));
    }
    // Timings arrive in batches, about once a second in profile mode.
    await Future<void>.delayed(const Duration(seconds: 2));
    SchedulerBinding.instance.removeTimingsCallback(record);
    return summary(timings);
  }

  final atEnd = await typeAt(field.widget.controller.value.text.length);
  final middle = field.widget.controller.value.text
      .split('\n')
      .take(lines ~/ 2)
      .join('\n')
      .length;
  final inMiddle = await typeAt(middle);
  return {
    'lines': lines,
    'markdown': markdown,
    'characters': body.length,
    'keys_typed': keys.length,
    'typed_correctly':
        field.widget.controller.value.text.length ==
        body.length + keys.length * 2,
    'at_end': atEnd,
    'in_middle': inMiddle,
  };
}
