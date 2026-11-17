// Spike C for HIS-14: what does one text-field semantics node cost per
// keystroke in the 5,000-line note of markdown_rendering.dart, with the
// semantics tree on as the macOS app ships it? AccessibilityTree.swift turns
// the tree on at launch, and this target runs in the same Runner, so it is on
// here too; the report says whether it was.
//
// KAPY_C_MODE picks what is measured:
//   field     today's NoteEditor, whose TextField exposes the whole note
//   excluded  the same editor inside ExcludeSemantics
//   node      a stand-in editor with one text-field node: the whole note as
//             its value and the caret as its selection, as the per-line
//             editor would expose it, with the value rebuilt only when the
//             text changes
//   nonode    the same stand-in without the node
//   window    the node with the caret's line and at least KAPY_C_WINDOW
//             characters of whole lines either side as its value
// KAPY_BENCH_MARKDOWN=off turns markdown off in field and excluded.
// KAPY_C_LINES (5000) is the note's length in lines, a multiple of 5,000.
// KAPY_C_KEYS keys are typed, then the caret moves KAPY_C_MOVES times
// without changing the text. SAMPLE_NOW is printed before the keys, so a
// profiler can attach, and the keys start KAPY_C_LEAD seconds later.
// KAPY_C_REATTACH times after the moves, the node is detached and attached
// again (the stand-in rebuilds it as a new node, the field loses focus and
// takes it back), and the first key after is measured.
//
// Each key and move is measured on its own: the handler (what the platform's
// text input or an arrow key would run), the framework's phases from
// FlutterTimeline, which profile mode records (BUILD, LAYOUT, PAINT,
// COMPOSITING, SEMANTICS and the three parts of SEMANTICS), and a round trip
// to the platform thread after the frame. The frame posts its semantics
// update to the platform thread before the round trip's message, so the round
// trip waits for the accessibility bridge to take the update.
//
// Build it like markdown_rendering.dart, under a bundle id of its own and
// with sync off. The figures are written to spike_c_semantics.json in the
// app's temporary directory.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
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
import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

import 'markdown_rendering.dart' show longNote, percentile;

final _env = Platform.environment;
final _mode = _env['KAPY_C_MODE'] ?? 'field';
final _markdown = _env['KAPY_BENCH_MARKDOWN'] != 'off';
final _lines = int.tryParse(_env['KAPY_C_LINES'] ?? '') ?? 5000;
final _keys = int.tryParse(_env['KAPY_C_KEYS'] ?? '') ?? 30;
final _moves = int.tryParse(_env['KAPY_C_MOVES'] ?? '') ?? 30;
final _windowChars = int.tryParse(_env['KAPY_C_WINDOW'] ?? '') ?? 2048;
final _lead = int.tryParse(_env['KAPY_C_LEAD'] ?? '') ?? 0;
final _standIn = const {'node', 'nonode', 'window'}.contains(_mode);
final _background = _env['KAPY_C_BG'] == '1';
final _reattach = int.tryParse(_env['KAPY_C_REATTACH'] ?? '') ?? 0;

/// Answered on the platform thread by SystemRegion.swift, cheaply.
const _region = MethodChannel('kapynotes/region');

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'spike-c-benchmark.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(_runAll());
}

/// Filled in as the run goes, so a run that stalls still reports how far it
/// got and why.
final _report = <String, Object>{};
var _frameCount = 0;

Future<void> _runAll() async {
  await windowManager.ensureInitialized();
  await windowManager.setSize(const Size(1280, 900));
  await windowManager.show();
  // Kept above other windows for the run: a covered window draws no frames,
  // and the Mac is in use while these run.
  await windowManager.setAlwaysOnTop(true);
  final lifecycle = AppLifecycleListener(
    onStateChange: (state) => _say('lifecycle ${state.name}'),
  );
  SchedulerBinding.instance.addPersistentFrameCallback((_) => _frameCount++);
  final heartbeat = Timer.periodic(
    const Duration(seconds: 5),
    (_) => _say('alive, ${_frameCount} frames so far'),
  );
  try {
    await _run();
  } catch (error, stack) {
    _report['error'] = '$error';
    _report['stack'] = '$stack'.split('\n').take(12).join('\n');
    _say('SPIKE_C_ERROR $error');
  }
  heartbeat.cancel();
  lifecycle.dispose();
  File(
    '${Directory.systemTemp.path}/spike_c_semantics.json',
  ).writeAsStringSync(jsonEncode(_report));
  _say('SPIKE_C_DONE');
  if (_report.isEmpty) await app.main();
  exit(0);
}

void _say(String line) {
  // ignore: avoid_print
  print(line);
}

String _note() {
  final one = longNote();
  return List.filled(_lines ~/ 5000, one).join('\n');
}

void _show(Widget home) {
  runApp(MaterialApp(key: UniqueKey(), theme: KapyTheme.dark(), home: home));
}

Widget _editor(String body) {
  final engine = CalcEngine();
  final editor = NoteEditor(
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
  );
  return Scaffold(
    body: _mode == 'excluded' ? ExcludeSemantics(child: editor) : editor,
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

_StandInState _standInState() {
  _StandInState? found;
  void visit(Element element) {
    if (found != null) return;
    if (element is StatefulElement && element.state is _StandInState) {
      found = element.state as _StandInState;
      return;
    }
    element.visitChildElements(visit);
  }

  WidgetsBinding.instance.rootElement!.visitChildElements(visit);
  return found!;
}

double _ms(Duration duration) => duration.inMicroseconds / 1000;

Map<String, Object> _frames(List<FrameTiming> timings) {
  final build = [for (final t in timings) _ms(t.buildDuration)];
  final raster = [for (final t in timings) _ms(t.rasterDuration)];
  final total = [for (final t in timings) _ms(t.totalSpan)];
  Map<String, Object> stats(List<double> values) => values.isEmpty
      ? {}
      : {
          'p50': percentile(values, 50),
          'p95': percentile(values, 95),
          'max': percentile(values, 100),
        };
  return {
    'frames': timings.length,
    'build_ms': stats(build),
    'raster_ms': stats(raster),
    'total_span_ms': stats(total),
  };
}

/// What the semantics tree holds: whether it is on, how many nodes it has,
/// and each text field's value, selection and children.
Map<String, Object> _census() {
  final owner = RendererBinding.instance.renderViews.first.owner
      ?.semanticsOwner;
  final root = owner?.rootSemanticsNode;
  var nodes = 0;
  final fields = <Map<String, Object>>[];
  bool visit(SemanticsNode node) {
    nodes++;
    final data = node.getSemanticsData();
    if (data.flagsCollection.isTextField) {
      var childLabels = 0;
      var children = 0;
      node.visitChildren((child) {
        children++;
        childLabels += child.getSemanticsData().label.length;
        return true;
      });
      fields.add({
        'value_chars': data.value.length,
        'selection': [
          data.textSelection?.baseOffset,
          data.textSelection?.extentOffset,
        ],
        'multiline': data.flagsCollection.isMultiline,
        'focused': '${data.flagsCollection.isFocused}',
        'children': children,
        'child_label_chars': childLabels,
      });
    }
    node.visitChildren(visit);
    return true;
  }

  if (root != null) visit(root);
  return {
    'platform_semantics_enabled':
        ui.PlatformDispatcher.instance.semanticsEnabled,
    'binding_semantics_enabled': SemanticsBinding.instance.semanticsEnabled,
    'semantics_owner': owner != null,
    'nodes': nodes,
    'text_fields': fields,
  };
}

Future<int> _ping() async {
  final watch = Stopwatch()..start();
  await _region
      .invokeMethod<Object?>('region')
      .timeout(const Duration(seconds: 20));
  return watch.elapsedMicroseconds;
}

/// Runs [count] steps, one a frame, each measured on its own until the next.
Future<Map<String, Object>> _measure(
  String phase,
  int count,
  Map<String, num> Function(int i) step,
) async {
  final focusedBefore = await windowManager.isFocused();
  final timings = <FrameTiming>[];
  void record(List<FrameTiming> batch) => timings.addAll(batch);
  SchedulerBinding.instance.addTimingsCallback(record);
  final records = <Map<String, num>>[];
  FlutterTimeline.debugCollectionEnabled = true;
  for (var i = 0; i < count; i++) {
    FlutterTimeline.debugReset();
    final t0 = developer.Timeline.now;
    final watch = Stopwatch()..start();
    final extra = step(i);
    final handler = watch.elapsedMicroseconds;
    if (i < 2) _say('$phase $i: stepped in $handler us');
    try {
      await WidgetsBinding.instance.endOfFrame.timeout(
        const Duration(seconds: 20),
      );
    } on TimeoutException {
      final answered = await _ping()
          .then((us) => '$us us')
          .catchError((Object e) => '$e');
      throw StateError(
        '$phase $i: no frame in 20 s; ${_frameCount} frames so far; '
        'the platform thread answered: $answered',
      );
    }
    final toFrame = watch.elapsedMicroseconds;
    if (i < 2) _say('$phase $i: framed after $toFrame us');
    final ping = await _ping();
    final rest = 33000 - watch.elapsedMicroseconds;
    await Future<void>.delayed(
      Duration(microseconds: rest > 15000 ? rest : 15000),
    );
    final blocks = FlutterTimeline.debugCollect();
    records.add({
      ...extra,
      't0': t0,
      't_end': developer.Timeline.now,
      'handler_us': handler,
      'key_to_frame_us': toFrame,
      'ping_us': ping,
      for (final block in blocks.aggregatedBlocks) ...{
        '${block.name}_us': block.duration,
        '${block.name}_n': block.count,
      },
    });
  }
  FlutterTimeline.debugCollectionEnabled = false;
  await Future<void>.delayed(const Duration(seconds: 2));
  SchedulerBinding.instance.removeTimingsCallback(record);
  final focusedAfter = await windowManager.isFocused();
  _say('$phase: $count done');
  return {
    'count': count,
    'window_focused': [focusedBefore, focusedAfter],
    'frames': _frames(timings),
    'steps': records,
  };
}

/// Pings the platform thread from a background isolate, about once a
/// millisecond, until told to stop. The answers come back to that isolate,
/// not to the UI thread, so a busy UI thread does not hold them up: a slow
/// round trip means the platform thread was busy.
Future<void> _pinger((ui.RootIsolateToken, SendPort) args) async {
  final (token, out) = args;
  BackgroundIsolateBinaryMessenger.ensureInitialized(token);
  final inbox = ReceivePort();
  out.send(inbox.sendPort);
  var stop = false;
  inbox.listen((_) => stop = true);
  final samples = <int>[];
  while (!stop) {
    final start = developer.Timeline.now;
    await _region.invokeMethod<Object?>('region');
    samples
      ..add(start)
      ..add(developer.Timeline.now - start);
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  out.send(samples);
  inbox.close();
}

class _Pinger {
  _Pinger._(this._control, this._replies);

  final SendPort _control;
  final StreamIterator<Object?> _replies;

  static Future<_Pinger> start() async {
    final port = ReceivePort();
    final replies = StreamIterator<Object?>(port);
    await Isolate.spawn(_pinger, (
      ui.RootIsolateToken.instance!,
      port.sendPort,
    ));
    await replies.moveNext();
    return _Pinger._(replies.current! as SendPort, replies);
  }

  /// Start times and round trips, in microseconds on the timeline clock.
  Future<List<int>> stop() async {
    _control.send(null);
    await _replies.moveNext();
    final samples = (_replies.current! as List).cast<int>();
    await _replies.cancel();
    return samples;
  }
}

Future<List<int>> _idlePings() async {
  final pings = <int>[];
  for (var i = 0; i < 20; i++) {
    pings.add(await _ping());
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return pings;
}

Future<void> _run() async {
  final body = _note();
  final open = Stopwatch()..start();
  _show(_standIn ? Scaffold(body: _StandIn(body: body)) : _editor(body));
  await WidgetsBinding.instance.endOfFrame;
  final openMs = open.elapsedMicroseconds / 1000;
  await Future<void>.delayed(const Duration(seconds: 2));
  final start = body.indexOf(
    'Plain prose for section 15, line 100',
    body.indexOf('## Section 15'),
  );

  late final Map<String, num> Function(int) key;
  late final Map<String, num> Function(int) move;
  if (_standIn) {
    final state = _standInState()..moveTo(start);
    key = (_) => state.type('a');
    move = (_) => state.moveBy(1);
  } else {
    final field = _field();
    field.userUpdateTextEditingValue(
      field.textEditingValue.copyWith(
        selection: TextSelection.collapsed(offset: start),
      ),
      SelectionChangedCause.tap,
    );
    key = (_) {
      final value = field.textEditingValue;
      final at = value.selection.start;
      final next = TextEditingValue(
        text: value.text.replaceRange(at, at, 'a'),
        selection: TextSelection.collapsed(offset: at + 1),
      );
      final watch = Stopwatch()..start();
      // What the platform's text input sends for a key.
      field.updateEditingValue(next);
      return {'update_us': watch.elapsedMicroseconds};
    };
    move = (_) {
      final value = field.textEditingValue;
      final watch = Stopwatch()..start();
      // What an arrow key does.
      field.userUpdateTextEditingValue(
        value.copyWith(
          selection: TextSelection.collapsed(offset: value.selection.start + 1),
        ),
        SelectionChangedCause.keyboard,
      );
      return {'update_us': watch.elapsedMicroseconds};
    };
  }
  await WidgetsBinding.instance.endOfFrame;
  await Future<void>.delayed(const Duration(seconds: 1));
  _report.addAll({
    'mode': _mode,
    'markdown': _markdown,
    'lines': _lines,
    'characters': body.length,
    'window_chars': _windowChars,
    'open_first_frame_ms': openMs,
    'census_before': _census(),
  });
  _report['idle_ping_us'] = await _idlePings();
  _say('window focused: ${await windowManager.isFocused()}');
  final pinger = _background ? await _Pinger.start() : null;
  if (pinger != null) {
    _report['bg_idle_from'] = developer.Timeline.now;
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  _say('SAMPLE_NOW');
  if (_lead > 0) await Future<void>.delayed(Duration(seconds: _lead));
  _report['keys'] = await _measure('keys', _keys, key);
  _report['moves'] = await _measure('moves', _moves, move);
  if (_reattach > 0) _report['reattach'] = await _reattachCycles(key);
  _say('SAMPLE_END');
  _report['census_after'] = _census();
  if (_mode == 'node' || _mode == 'window') {
    _report['burst'] = await _burst(_standInState());
  }
  if (pinger != null) _report['bg'] = await pinger.stop();
}

/// Detaches and attaches the text-field node [_reattach] times, measuring
/// each change and the first key after it.
Future<List<Map<String, Object>>> _reattachCycles(
  Map<String, num> Function(int) key,
) async {
  final cycles = <Map<String, Object>>[];
  for (var i = 0; i < _reattach; i++) {
    final cycle = <String, Object>{};
    if (_standIn) {
      cycle['recreate'] = await _measure('recreate $i', 1, (_) {
        _standInState().recreate();
        return const {};
      });
    } else {
      final focus = _field().widget.focusNode;
      cycle['unfocus'] = await _measure('unfocus $i', 1, (_) {
        focus.unfocus();
        return const {};
      });
      cycle['refocus'] = await _measure('refocus $i', 1, (_) {
        focus.requestFocus();
        return const {};
      });
    }
    cycle['key'] = await _measure('key after $i', 1, key);
    cycles.add(cycle);
  }
  return cycles;
}

/// Posts [count] semantics updates back to back, each with a new value, then
/// sends a round trip to the platform thread, which queues behind all of
/// them. If the accessibility bridge takes an update more slowly than the
/// framework sends one, the backlog shows as the time from the last update
/// sent to the round trip's answer, less an idle round trip.
Future<List<Map<String, int>>> _burst(_StandInState state, {int count = 20}) async {
  RenderObject? found;
  void visit(RenderObject object) {
    if (found != null) return;
    if (object is _RenderEditorNode) {
      found = object;
      return;
    }
    object.visitChildren(visit);
  }

  RendererBinding.instance.renderViews.first.visitChildren(visit);
  final node = found! as _RenderEditorNode;
  final owner = node.owner!;
  final rounds = <Map<String, int>>[];
  for (var round = 0; round < 5; round++) {
    final values = [
      for (var i = 0; i < count; i++) state.valueWith('${round}x${i}'),
    ];
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final t0 = developer.Timeline.now;
    final watch = Stopwatch()..start();
    for (final value in values) {
      node.value = value;
      owner.flushSemantics();
    }
    final sent = watch.elapsedMicroseconds;
    await _ping();
    rounds.add({
      't0': t0,
      'count': count,
      'sent_us': sent,
      'answered_us': watch.elapsedMicroseconds,
    });
  }
  _say('burst done');
  return rounds;
}

/// A stand-in for the per-line editor: the note as lines, the lines around
/// the caret drawn as plain text, and, unless the mode is nonode, the one
/// text-field node the per-line editor would expose.
class _StandIn extends StatefulWidget {
  const _StandIn({required this.body});

  final String body;

  @override
  State<_StandIn> createState() => _StandInState();
}

class _StandInState extends State<_StandIn> {
  late final List<String> _lines = widget.body.split('\n');
  late final List<int> _starts = _lineStarts();
  late String _value = _mode == 'node' ? widget.body : '';
  int _caret = 0;
  int _windowStart = 0;
  int _windowEnd = 0;
  int _generation = 0;

  /// Rebuilds the node as a new one, as opening another note would.
  void recreate() => setState(() => _generation++);

  List<int> _lineStarts() {
    final starts = <int>[];
    var offset = 0;
    for (final line in _lines) {
      starts.add(offset);
      offset += line.length + 1;
    }
    return starts;
  }

  int _lineAt(int offset) {
    var low = 0;
    var high = _starts.length - 1;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (_starts[mid] <= offset) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low;
  }

  /// Whole lines around the caret's, at least [_windowChars] characters
  /// either side, and where they start in the note.
  void _rewindow() {
    final line = _lineAt(_caret);
    var first = line;
    var before = 0;
    while (first > 0 && before < _windowChars) {
      first--;
      before += _lines[first].length + 1;
    }
    var last = line;
    var after = 0;
    while (last < _lines.length - 1 && after < _windowChars) {
      last++;
      after += _lines[last].length + 1;
    }
    _windowStart = _starts[first];
    _windowEnd = _starts[last] + _lines[last].length;
    _value = _lines.sublist(first, last + 1).join('\n');
  }

  void moveTo(int offset) {
    setState(() {
      _caret = offset;
      if (_mode == 'window') _rewindow();
    });
  }

  Map<String, num> type(String text) {
    final watch = Stopwatch()..start();
    final line = _lineAt(_caret);
    final column = _caret - _starts[line];
    final old = _lines[line];
    _lines[line] = old.substring(0, column) + text + old.substring(column);
    for (var i = line + 1; i < _starts.length; i++) {
      _starts[i] += text.length;
    }
    _caret += text.length;
    final edit = watch.elapsedMicroseconds;
    watch
      ..reset()
      ..start();
    if (_mode == 'node') _value = _lines.join('\n');
    if (_mode == 'window') _rewindow();
    final value = watch.elapsedMicroseconds;
    setState(() {});
    return {'edit_us': edit, 'value_us': value};
  }

  /// The value the node would carry with [text] typed at the caret.
  String valueWith(String text) {
    final line = _lineAt(_caret);
    final column = _caret - _starts[line];
    if (_mode == 'node') {
      final at = _starts[line] + column;
      return _value.replaceRange(at, at, text);
    }
    final at = _caret - _windowStart;
    return _value.replaceRange(at, at, text);
  }

  Map<String, num> moveBy(int delta) {
    _caret += delta;
    if (_mode == 'window' && (_caret < _windowStart || _caret > _windowEnd)) {
      _rewindow();
    }
    setState(() {});
    return const {};
  }

  @override
  Widget build(BuildContext context) {
    final line = _lineAt(_caret);
    final first = line > 20 ? line - 20 : 0;
    final last = line + 25 < _lines.length ? line + 25 : _lines.length;
    final view = ExcludeSemantics(
      child: SizedBox.expand(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _lines.sublist(first, last).join('\n'),
            style: const TextStyle(fontSize: 15, height: 1.4),
          ),
        ),
      ),
    );
    if (_mode == 'nonode') return view;
    final selection = TextSelection.collapsed(
      offset: _mode == 'window' ? _caret - _windowStart : _caret,
    );
    return _EditorNode(
      key: ValueKey(_generation),
      value: _value,
      selection: selection,
      child: view,
    );
  }
}

class _EditorNode extends SingleChildRenderObjectWidget {
  const _EditorNode({
    super.key,
    required this.value,
    required this.selection,
    super.child,
  });

  final String value;
  final TextSelection selection;

  @override
  _RenderEditorNode createRenderObject(BuildContext context) =>
      _RenderEditorNode(value, selection);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderEditorNode renderObject,
  ) {
    renderObject
      ..value = value
      ..selection = selection;
  }
}

/// One multiline text-field node, configured the way RenderEditable
/// configures the field's: value, selection, focus, and the set-selection,
/// set-text and cursor-movement actions.
class _RenderEditorNode extends RenderProxyBox {
  _RenderEditorNode(this._value, this._selection);

  String _value;
  AttributedString? _attributed;
  set value(String value) {
    if (identical(value, _value)) return;
    _value = value;
    _attributed = null;
    markNeedsSemanticsUpdate();
  }

  TextSelection _selection;
  set selection(TextSelection selection) {
    if (selection == _selection) return;
    _selection = selection;
    markNeedsSemanticsUpdate();
  }

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config
      ..isSemanticBoundary = true
      ..attributedValue = _attributed ??= AttributedString(_value)
      ..isMultiline = true
      ..textDirection = TextDirection.ltr
      ..isFocused = true
      ..isTextField = true
      ..isReadOnly = false
      ..inputType = ui.SemanticsInputType.text
      ..textSelection = _selection
      ..onSetSelection = (_) {}
      ..onSetText = (_) {}
      ..onMoveCursorForwardByCharacter = (_) {}
      ..onMoveCursorBackwardByCharacter = (_) {}
      ..onMoveCursorForwardByWord = (_) {}
      ..onMoveCursorBackwardByWord = (_) {};
  }
}
