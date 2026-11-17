// How long does a long note with formulas and code take to open, and how fast
// does typing in it stay?
//
// Five thousand lines: 30 code blocks in Python, TypeScript and SQL, 300
// formulas among words and 50 set apart, and prose and sums between them,
// with markdown on unless KAPY_BENCH_MARKDOWN=off is in the environment.
// KAPY_BENCH_FORMULAS=off writes words where the formulas were, so the cost
// of drawing them can be told apart from the rest.
// The note is opened three times, then typed into the way a keyboard types,
// one editing-value update a key about thirty times a second for a second at
// a time: in prose, in a code block and right after a formula. The semantics
// tree is on throughout, as it always is in the macOS app, which switches it
// on at launch so that dictation tools can write into the editor (see
// AccessibilityTree.swift). Prints how long each opening took to its first
// frame, and how long the typing frames took to build and to draw, and
// quits. KAPY_BENCH_TYPING=off stops after the openings.
//
// A plain app rather than an integration test, because only profile mode
// says anything about frame times. It keeps the app's `main` reachable without
// calling it, so that it is compiled together with the app's own code. Build
// it under a bundle id of its own, never the real app's, and with sync off,
// then launch it with what to measure:
//
//   FLUTTER_XCODE_PRODUCT_BUNDLE_IDENTIFIER=com.kapybara.kapynotes.renderperf \
//     flutter build macos --profile --dart-define=KAPYNOTES_SYNC=false \
//     -t benchmark/markdown_rendering.dart
//   open -n --env KAPY_BENCH_MARKDOWN=off \
//     "build/macos/Build/Products/Profile/Kapy Notes.app"
//
// The figures are the line starting MARKDOWN_RENDERING_PERF in the log, also
// written to markdown_rendering_perf.json in the app's temporary directory.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/calc/highlight.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/main.dart' as app;
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'markdown-rendering-benchmark.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

const _python = [
  'import math',
  'from dataclasses import dataclass',
  '',
  '@dataclass',
  'class Point:',
  '    x: float',
  '    y: float',
  '',
  '    def norm(self) -> float:',
  '        # Euclidean length of the vector',
  '        return math.sqrt(self.x ** 2 + self.y ** 2)',
  '',
  'def mean(values: list[float]) -> float:',
  '    """The arithmetic mean, or zero for nothing."""',
  '    if not values:',
  '        return 0.0',
  '    return sum(values) / len(values)',
  '',
  'for i in range(10):',
  '    print(f"step {i}: {mean([i, i * 2, 3.5])}")',
];

const _typescript = [
  "import { readFile } from 'node:fs/promises';",
  '',
  'interface Invoice {',
  '  id: string;',
  '  total: number;',
  '  paid?: boolean;',
  '}',
  '',
  'export async function load(path: string): Promise<Invoice[]> {',
  "  const raw = await readFile(path, 'utf8');",
  '  // One invoice per line, as JSON.',
  '  return raw.split("\\n").filter(Boolean).map((line) => JSON.parse(line));',
  '}',
  '',
  'const unpaid = (all: Invoice[]) => all.filter((i) => !i.paid);',
  'let sum = 0;',
  'for (const invoice of unpaid([])) {',
  '  sum += invoice.total * 1.2;',
  '}',
  r'console.log(`owed: ${sum.toFixed(2)}`);',
];

const _sql = [
  '-- Monthly revenue by customer',
  'SELECT c.name,',
  "       date_trunc('month', o.created_at) AS month,",
  '       SUM(o.total) AS revenue,',
  '       COUNT(*) AS orders',
  'FROM customers c',
  'JOIN orders o ON o.customer_id = c.id',
  "WHERE o.status = 'paid'",
  '  AND o.created_at >= NOW() - INTERVAL 1 YEAR',
  'GROUP BY c.name, month',
  'HAVING SUM(o.total) > 1000',
  'ORDER BY revenue DESC',
  'LIMIT 50;',
  '',
  'UPDATE orders SET status = NULL WHERE id IN (1, 2, 3);',
  'CREATE INDEX orders_customer ON orders (customer_id);',
  "INSERT INTO audit (event, at) VALUES ('refresh', NOW());",
  'DELETE FROM sessions WHERE expires_at < NOW();',
  "SELECT * FROM customers WHERE email LIKE '%@example.com';",
  'DROP TABLE IF EXISTS scratch;',
];

/// The note: 5,000 lines in 30 sections, each with five lines of two
/// formulas among words, one or two formulas set apart, a sum and a code
/// block, and prose after them.
String longNote() {
  final lines = <String>[];
  const languages = ['python', 'typescript', 'sql'];
  const bodies = [_python, _typescript, _sql];
  for (var section = 0; section < 30; section++) {
    final start = lines.length;
    lines
      ..add('## Section $section')
      ..add('');
    for (var i = 0; i < 5; i++) {
      lines.add(
        _formulas
            ? 'Line $i of $section says \$x_{$i}^{2} + \\frac{a}{b}\$ grows '
                  'faster than \$\\sqrt{n}\$ here.'
            : 'Line $i of $section says x to the $i squared plus a over b '
                  'grows faster than root n here.',
      );
    }
    lines.add('');
    final displays = section < 20 ? 2 : 1;
    for (var d = 0; d < displays; d++) {
      lines
        ..add(_formulas ? '\$\$' : 'Set apart:')
        ..add(
          _formulas
              ? '\\sum_{k=1}^{$section} k^$d = \\int_0^1 f(t)\\,dt'
              : 'the sum of k to the $d for k up to $section is an integral',
        )
        ..add(_formulas ? '\$\$' : 'of f over 0 to 1.')
        ..add('');
    }
    lines
      ..add('price = ${section + 3} usd')
      ..add('price * 3')
      ..add('')
      ..add('```${languages[section % 3]}');
    final body = bodies[section % 3];
    lines
      ..addAll(body)
      ..addAll(body)
      ..add('```')
      ..add('');
    while (lines.length - start < 166) {
      lines.add(
        'Plain prose for section $section, line ${lines.length - start}, '
        'with a total of 4 + 5 in it.',
      );
    }
  }
  while (lines.length < 5000) {
    lines.add('closing line ${lines.length}');
  }
  return lines.take(5000).join('\n');
}

/// [values] at the [p]th percentile, by nearest rank.
double percentile(List<double> values, double p) {
  final sorted = [...values]..sort();
  final rank = (p / 100 * sorted.length).ceil().clamp(1, sorted.length);
  return sorted[rank - 1];
}

double _ms(Duration duration) => duration.inMicroseconds / 1000;

Map<String, Object> summary(List<FrameTiming> timings) {
  const budget = 1000 / 60;
  final build = [for (final t in timings) _ms(t.buildDuration)];
  final raster = [for (final t in timings) _ms(t.rasterDuration)];
  Map<String, Object> stats(List<double> values) => {
    'p50': percentile(values, 50),
    'p90': percentile(values, 90),
    'max': percentile(values, 100),
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
  // The app's window waits hidden for the app's main to show it, and a
  // hidden window draws no frames.
  await windowManager.ensureInitialized();
  await windowManager.setSize(const Size(1280, 900));
  await windowManager.show();
  final report = await _run();
  final line = jsonEncode(report);
  File(
    '${Directory.systemTemp.path}/markdown_rendering_perf.json',
  ).writeAsStringSync(line);
  _say('MARKDOWN_RENDERING_PERF $line');
  if (report.isEmpty) await app.main();
  exit(0);
}

/// Prints [line] to the log, which is where a run that is taking its time
/// shows how far it has got.
void _say(String line) {
  // ignore: avoid_print
  print(line);
}

void _show(Widget home) {
  runApp(MaterialApp(key: UniqueKey(), theme: KapyTheme.dark(), home: home));
}

Widget _editor(String body) {
  final engine = CalcEngine();
  return Scaffold(
    body: NoteEditor(
      noteId: 'benchmark',
      initialBody: body,
      engine: engine,
      highlighter: Highlighter(engine.registry),
      resultsVisible: true,
      markdownEnabled: _markdown,
      autofocus: true,
      onDocumentChanged: (_, _, _) {},
      onSettingsPressed: () {},
      writingFont: WritingFont.handwritten,
      shortcuts: ShortcutPrefs(_MemoryStore())..load(),
    ),
  );
}

EditableTextState _field() {
  EditableTextState? found;
  void visit(Element element) {
    if (found != null) return;
    if (element is StatefulElement && element.state is EditableTextState) {
      found = element.state as EditableTextState;
      return;
    }
    element.visitChildElements(visit);
  }

  WidgetsBinding.instance.rootElement!.visitChildElements(visit);
  return found!;
}

double _slowest(Iterable<double> values) =>
    values.fold<double>(0, (a, b) => a > b ? a : b);

/// How long [body] takes to open in an empty window: from showing the
/// editor to the end of its first frame, which builds the note, lays it out
/// and paints it; and the slowest build and raster of the frames it takes.
Future<Map<String, Object>> _open(String body) async {
  _show(const SizedBox.shrink());
  await WidgetsBinding.instance.endOfFrame;
  await Future<void>.delayed(const Duration(seconds: 1));
  final timings = <FrameTiming>[];
  void record(List<FrameTiming> batch) => timings.addAll(batch);
  SchedulerBinding.instance.addTimingsCallback(record);
  final stopwatch = Stopwatch()..start();
  _show(_editor(body));
  await WidgetsBinding.instance.endOfFrame;
  final firstFrame = stopwatch.elapsedMicroseconds / 1000;
  await Future<void>.delayed(const Duration(seconds: 2));
  SchedulerBinding.instance.removeTimingsCallback(record);
  return {
    'first_frame_ms': firstFrame,
    'slowest_build_ms': _slowest([
      for (final t in timings) _ms(t.buildDuration),
    ]),
    'slowest_raster_ms': _slowest([
      for (final t in timings) _ms(t.rasterDuration),
    ]),
  };
}

final _markdown = Platform.environment['KAPY_BENCH_MARKDOWN'] != 'off';
final _formulas = Platform.environment['KAPY_BENCH_FORMULAS'] != 'off';

Future<Map<String, Object>> _run() async {
  final body = longNote();
  final opens = <Map<String, Object>>[];
  for (var i = 1; i <= 3; i++) {
    opens.add(await _open(body));
    _say(
      'opened $i of 3: ${opens.last['first_frame_ms']} ms to the first frame',
    );
  }
  if (Platform.environment['KAPY_BENCH_TYPING'] == 'off') {
    return {
      'semantics': SemanticsBinding.instance.semanticsEnabled,
      'markdown': _markdown,
      'characters': body.length,
      'open': opens,
    };
  }
  await Future<void>.delayed(const Duration(seconds: 1));
  final field = _field();
  const keys = 30;

  Future<Map<String, Object>> typeAt(int caret) async {
    field.userUpdateTextEditingValue(
      field.textEditingValue.copyWith(
        selection: TextSelection.collapsed(offset: caret),
      ),
      SelectionChangedCause.tap,
    );
    await Future<void>.delayed(const Duration(seconds: 1));
    final timings = <FrameTiming>[];
    void record(List<FrameTiming> batch) => timings.addAll(batch);
    SchedulerBinding.instance.addTimingsCallback(record);
    for (var i = 0; i < keys; i++) {
      final value = field.textEditingValue;
      final at = value.selection.start;
      // What the platform's text input sends for a key.
      field.updateEditingValue(
        TextEditingValue(
          text: value.text.replaceRange(at, at, 'a'),
          selection: TextSelection.collapsed(offset: at + 1),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 33));
    }
    // Timings arrive in batches, about once a second in profile mode.
    await Future<void>.delayed(const Duration(seconds: 2));
    SchedulerBinding.instance.removeTimingsCallback(record);
    _say('typed $keys keys at $caret');
    return summary(timings);
  }

  int after(String needle, String from) {
    final text = field.textEditingValue.text;
    return text.indexOf(needle, text.indexOf(from));
  }

  final prose = await typeAt(
    after('Plain prose for section 15, line 100', '## Section 15'),
  );
  final code = await typeAt(after('return sum(values)', '## Section 15'));
  final formula = await typeAt(after(' grows', 'Line 2 of 15'));
  return {
    'semantics': SemanticsBinding.instance.semanticsEnabled,
    'markdown': _markdown,
    'characters': body.length,
    'open': opens,
    'typing_in_prose': prose,
    'typing_in_code': code,
    'typing_after_a_formula': formula,
  };
}
