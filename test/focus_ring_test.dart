import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/appearance.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/ui/draw/drawing_canvas.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/focus_ring.dart';
import 'package:kapy_notes/ui/spaces_rail.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';

class _Store extends LocalStore {
  _Store() : super(fileName: 'focus-ring-test.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
}

const _wide = Size(1500, 800);
final _ring = find.byKey(const ValueKey('focus-ring'));

Future<void> _pump(
  WidgetTester tester, {
  TargetPlatform platform = TargetPlatform.linux,
  Size size = _wide,
  bool listShown = true,
  bool increaseContrast = false,
}) async {
  AppPlatform.debugTargetPlatformOverride = platform;
  addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('kapynotes/window_material'),
        (call) async => false,
      );
  final store = _Store();
  store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
  if (increaseContrast) store.data['increaseContrast.v1'] = true;
  final notes = NotesStore(store, now: () => DateTime(2026, 11, 26, 10));
  await tester.runAsync(() async {
    await notes.load();
    notes.create(body: 'Groceries\nMilk');
    notes.create(body: 'Lisbon trip\n☐ Book flights');
  });
  final prefs = LayoutPrefs(store)..load();
  if (prefs.sidebarVisible != listShown) prefs.toggleSidebar();
  await tester.pumpWidget(
    KapyNotesApp(
      store: store,
      notes: notes,
      rates: RatesRepository(store),
      prefs: prefs,
      shortcuts: ShortcutPrefs(store)..load(),
    ),
  );
  await tester.pumpAndSettle();
}

/// What keeps [node] out of sight, or null when it can be seen where it is.
String? _unseen(WidgetTester tester, FocusNode node) {
  final box = node.context?.findRenderObject();
  if (box is! RenderBox || !box.attached || !box.hasSize) return 'not laid out';
  var visible = node.rect;
  if (visible.width < 1 || visible.height < 1) return 'no size';
  final window = Offset.zero & tester.view.physicalSize;
  if (!visible.overlaps(window)) return 'off the window';
  RenderObject child = box;
  for (var parent = box.parent; parent != null; parent = parent.parent) {
    if (parent is RenderOffstage && parent.offstage) return 'offstage';
    if (parent is RenderOpacity && parent.opacity == 0) return 'faded out';
    if (parent is RenderAnimatedOpacity && parent.opacity.value == 0) {
      return 'faded out';
    }
    final clip = parent.describeApproximatePaintClip(child);
    if (clip != null) {
      visible = visible.intersect(
        MatrixUtils.transformRect(parent.getTransformTo(null), clip),
      );
      if (visible.width < 1 || visible.height < 1) return 'clipped away';
    }
    child = parent;
  }
  final hit = HitTestResult();
  RendererBinding.instance.hitTestInView(
    hit,
    visible.center,
    tester.view.viewId,
  );
  if (!hit.path.any((entry) => entry.target == box)) return 'under something';
  return null;
}

/// The ring's stroke as painted now, or null when there is none.
(RRect, Paint)? _painted(WidgetTester tester) {
  final canvas = TestRecordingCanvas();
  tester
      .renderObject(_ring)
      .paint(TestRecordingPaintingContext(canvas), Offset.zero);
  final strokes = [
    for (final call in canvas.invocations)
      if (call.invocation.memberName == #drawRRect)
        (
          call.invocation.positionalArguments[0] as RRect,
          call.invocation.positionalArguments[1] as Paint,
        ),
  ];
  expect(strokes.length, lessThan(2), reason: 'one ring at a time');
  return strokes.firstOrNull;
}

/// Checks the ring is drawn around [node], or the part of it a
/// [FocusRingTarget] picks out, or the whole of its field when it is a text
/// field's, and only just around it, in the theme's accent.
void _expectRinged(WidgetTester tester, FocusNode node, {double width = 2}) {
  final ring = _painted(tester);
  expect(ring, isNotNull, reason: 'no ring around ${_name(node)}');
  final (rrect, paint) = ring!;
  final accent = Theme.of(
    tester.element(_ring),
  ).extension<CalcPalette>()!.accent;
  expect(paint.color, isSameColorAs(accent));
  expect(paint.style, PaintingStyle.stroke);
  expect(paint.strokeWidth, width);
  final field = node.context?.findAncestorStateOfType<State<TextField>>();
  final part = find.descendant(
    of: find.byElementPredicate((element) => element == node.context),
    matching: find.byType(FocusRingTarget),
  );
  final marked = field != null
      ? tester.getRect(find.byWidget(field.widget))
      : part.evaluate().isEmpty
      ? node.rect
      : tester.getRect(part.first);
  final window = Offset.zero & tester.view.physicalSize;
  final shown = marked.intersect(window);
  final outside = rrect.outerRect.inflate(width / 2);
  expect(
    outside.contains(shown.topLeft) &&
        outside.contains(shown.bottomRight - const Offset(0.5, 0.5)),
    isTrue,
    reason: 'the ring ${rrect.outerRect} leaves out ${_name(node)} at $shown',
  );
  expect(
    marked.inflate(6).contains(rrect.outerRect.topLeft) &&
        marked.inflate(6).contains(rrect.outerRect.bottomRight),
    isTrue,
    reason: 'the ring ${rrect.outerRect} stands off ${_name(node)} at $marked',
  );
}

Future<void> _bare(WidgetTester tester, Widget body) async {
  AppPlatform.debugTargetPlatformOverride = TargetPlatform.linux;
  addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 800);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: KapyTheme.dark(),
      builder: (context, child) => FocusRing(child: child!),
      home: Scaffold(body: body),
    ),
  );
}

Future<void> _awayAndBack(WidgetTester tester) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  await tester.pump();
  expect(_painted(tester), isNull, reason: 'a ring while the app is away');
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pump();
}

String _name(FocusNode node) {
  final context = node.context;
  if (context == null) return '$node';
  final words = <String>[];
  void read(Element element) {
    final widget = element.widget;
    if (widget is Semantics && (widget.properties.label ?? '').isNotEmpty) {
      words.add(widget.properties.label!);
    } else if (widget is Text && (widget.data ?? '').isNotEmpty) {
      words.add(widget.data!);
    }
    if (words.isEmpty) element.visitChildElements(read);
  }

  (context as Element).visitChildElements(read);
  return words.isEmpty ? '${context.widget.runtimeType}' : words.first;
}

Future<void> _press(WidgetTester tester, {bool back = false}) async {
  if (back) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  if (back) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.pumpAndSettle();
}

/// Presses Tab, or Shift+Tab, until focus comes back round to the first stop,
/// checking on the way that each stop is in sight with the ring around it, or
/// with none when it is a surface for writing or drawing, and returns the
/// stops in the order they were reached.
Future<List<FocusNode>> _round(
  WidgetTester tester, {
  bool back = false,
  double width = 2,
}) async {
  final stops = <FocusNode>[];
  for (var i = 0; i < 80; i++) {
    await _press(tester, back: back);
    final node = FocusManager.instance.primaryFocus!;
    if (stops.contains(node)) {
      expect(
        node,
        stops.first,
        reason:
            'Tab went from ${_name(stops.last)} back to ${_name(node)}, '
            'never to ${_name(stops.first)}',
      );
      return stops;
    }
    expect(_unseen(tester, node), isNull, reason: _name(node));
    if (node is NoRingFocusNode) {
      expect(_painted(tester), isNull, reason: 'a ring around ${_name(node)}');
    } else {
      _expectRinged(tester, node, width: width);
    }
    stops.add(node);
  }
  fail('Tab never came back round');
}

/// How many separate runs of stops [inside] picks out, going round.
int _runs(List<FocusNode> stops, bool Function(FocusNode) inside) {
  var runs = 0;
  for (var i = 0; i < stops.length; i++) {
    if (inside(stops[i]) && !inside(stops[(i - 1) % stops.length])) runs++;
  }
  return runs;
}

void main() {
  setUpAll(loadTestFonts);

  for (final platform in [
    TargetPlatform.linux,
    TargetPlatform.macOS,
    TargetPlatform.windows,
  ]) {
    for (final listShown in [true, false]) {
      testWidgets(
        '${platform.name}, notes list ${listShown ? 'shown' : 'hidden'}: Tab '
        'takes the rail, then the toolbar left to right, then the note, each '
        'in sight with the ring around it but the note, which has its caret, '
        'and Shift+Tab goes back the same way',
        (tester) async {
          await _pump(tester, platform: platform, listShown: listShown);
          final stops = await _round(tester);

          final rail = tester.getRect(find.byType(SpacesRail));
          bool onRail(FocusNode node) => rail.contains(node.rect.center);
          final railStops = stops.takeWhile(onRail).toList();
          expect(railStops.length, greaterThanOrEqualTo(3));
          expect(_runs(stops, onRail), 1, reason: 'the rail in one go');
          for (var i = 1; i < railStops.length; i++) {
            expect(
              railStops[i].rect.top,
              greaterThan(railStops[i - 1].rect.top),
            );
          }

          final note = tester.getRect(find.byType(NoteEditor));
          expect(note.contains(stops.last.rect.center), isTrue);
          expect(stops.last, isA<NoRingFocusNode>());
          final toolbar = stops.sublist(railStops.length, stops.length - 1);
          expect(toolbar, isNotEmpty);
          for (var i = 0; i < toolbar.length; i++) {
            expect(toolbar[i].rect.bottom, lessThanOrEqualTo(note.top));
            if (i > 0) {
              expect(
                toolbar[i].rect.left,
                greaterThan(toolbar[i - 1].rect.left),
                reason: '${_name(toolbar[i])} after ${_name(toolbar[i - 1])}',
              );
            }
          }

          final back = await _round(tester, back: true);
          expect(back, stops.reversed.toList());
        },
      );
    }
  }

  testWidgets('a click puts the ring away, typing leaves it away, and the next '
      'Tab brings it back', (tester) async {
    await _pump(tester);
    await _press(tester);
    expect(_painted(tester), isNotNull);

    final click = await tester.startGesture(
      tester.getCenter(find.byType(NoteEditor)),
      kind: PointerDeviceKind.mouse,
    );
    await click.up();
    await tester.pumpAndSettle();
    expect(_painted(tester), isNull);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pumpAndSettle();
    expect(_painted(tester), isNull);

    await _press(tester);
    _expectRinged(tester, FocusManager.instance.primaryFocus!);
  });

  testWidgets('a press on nothing puts the ring away', (tester) async {
    await _bare(
      tester,
      Center(
        child: TextButton(onPressed: () {}, child: const Text('Only')),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final node = FocusManager.instance.primaryFocus;
    expect(_painted(tester), isNotNull);

    await tester.tapAt(const Offset(40, 40));
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, node);
    expect(_painted(tester), isNull);
  });

  testWidgets('a control its list scrolls out of sight takes its ring along, '
      'and one partly out is cut at the edge', (tester) async {
    final list = ScrollController();
    addTearDown(list.dispose);
    await _bare(
      tester,
      Column(
        children: [
          const SizedBox(height: 300),
          Expanded(
            child: ListView(
              controller: list,
              children: [
                for (var i = 0; i < 30; i++)
                  SizedBox(
                    height: 48,
                    child: TextButton(onPressed: () {}, child: Text('Row $i')),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(_painted(tester), isNotNull);

    list.jumpTo(24);
    await tester.pump();
    expect(
      tester.renderObject(_ring),
      paints
        ..clipRect(rect: const Rect.fromLTRB(-4, 296, 804, 804))
        ..rrect(),
    );

    list.jumpTo(120);
    await tester.pump();
    expect(find.text('Row 0', skipOffstage: false), findsOneWidget);
    expect(_painted(tester), isNull);
  });

  testWidgets('leaving the app and coming back brings a ring back only where '
      'there was one', (tester) async {
    FocusManager.instance.listenToApplicationLifecycleChangesIfSupported();
    await _bare(
      tester,
      Column(
        children: [
          const SizedBox(width: 300, child: TextField()),
          TextButton(onPressed: () {}, child: const Text('Next')),
        ],
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.metaLeft);
    await _awayAndBack(tester);
    expect(_painted(tester), isNull);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(_painted(tester), isNotNull);
    await _awayAndBack(tester);
    expect(_painted(tester), isNotNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('on the rail the ring goes round the tile of a space, clear of '
      'its name', (tester) async {
    await _pump(tester);
    final name = find.descendant(
      of: find.byType(SpacesRail),
      matching: find.text('Notes'),
    );
    final tile = tester.getRect(
      find
          .descendant(
            of: find.ancestor(of: name, matching: find.byType(InkWell)).first,
            matching: find.byType(AnimatedContainer),
          )
          .first,
    );
    for (var i = 0; i < 20; i++) {
      await _press(tester);
      if (FocusManager.instance.primaryFocus!.rect.contains(tile.center)) break;
    }
    final (ring, paint) = _painted(tester)!;
    expect(
      ring.outerRect,
      rectMoreOrLessEquals(tile.inflate(FocusRing.gap + paint.strokeWidth / 2)),
    );
    expect(
      ring.tlRadius,
      const Radius.circular(AppRadii.surface + FocusRing.gap),
    );
    expect(
      ring.outerRect.bottom + paint.strokeWidth / 2,
      lessThanOrEqualTo(tester.getRect(name).top),
    );
  });

  testWidgets('in a drawing, Tab takes the canvas with no ring around it, and '
      'each other stop in sight with the ring', (tester) async {
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('rail-drawings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sidebar-new-note')));
    await tester.pumpAndSettle();
    final stops = await _round(tester);
    final canvas = tester.getRect(find.byType(DrawingCanvas));
    expect(
      stops.whereType<NoRingFocusNode>().where(
        (node) => canvas.contains(node.rect.center),
      ),
      isNotEmpty,
      reason: 'Tab never reached the canvas',
    );
  });

  testWidgets('with the notes list open over the note in a narrow window, Tab '
      'keeps to what is in sight', (tester) async {
    await _pump(tester, size: const Size(600, 640));
    await tester.tap(find.bySemanticsLabel(RegExp('^Show notes')).first);
    await tester.pumpAndSettle();
    final stops = await _round(tester);
    final note = tester.getRect(find.byType(NoteEditor));
    expect(stops.where((node) => note.contains(node.rect.center)), isEmpty);
  });

  testWidgets('Settings takes its categories in one go, then the pane, and '
      'comes back round to them', (tester) async {
    await _pump(tester);
    await tester.tap(find.bySemanticsLabel('Settings').first);
    await tester.pumpAndSettle();
    final stops = await _round(tester);
    final categories = tester.getRect(
      find
          .ancestor(
            of: find.text('Voice & AI'),
            matching: find.byType(FocusTraversalGroup),
          )
          .first,
    );
    expect(_runs(stops, (node) => categories.contains(node.rect.center)), 1);
  });

  testWidgets('under Increase contrast the ring is wider, on buttons and cards '
      'alike', (tester) async {
    await _pump(tester, increaseContrast: true);
    await _round(tester, width: 3);
    await tester.tap(find.bySemanticsLabel('Settings').first);
    await tester.pumpAndSettle();
    final stops = await _round(tester, width: 3);
    expect(
      stops.map(_name),
      containsAll(['Appearance', 'Riverbank', 'Increase contrast']),
    );
  });

  test('the ring stands out from every surface it can sit on, in all six '
      'themes, light and dark, with and without Increase contrast', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    double contrast(Color a, Color b) {
      final (la, lb) = (a.computeLuminance(), b.computeLuminance());
      return ((la > lb ? la : lb) + 0.05) / ((la > lb ? lb : la) + 0.05);
    }

    for (final increaseContrast in [false, true]) {
      for (final theme in AppTheme.values) {
        for (final data in [
          KapyTheme.light(theme: theme, increaseContrast: increaseContrast),
          KapyTheme.dark(theme: theme, increaseContrast: increaseContrast),
        ]) {
          final palette = data.extension<CalcPalette>()!.opaque;
          final surfaces = {
            'rail': palette.railBackground,
            'list': palette.sidebarBackground,
            'page': palette.editorBackground,
            'dialog': palette.surfaceBackground,
            'control': palette.controlBackground,
            'card': palette.cardBackground,
            'well': palette.wellBackground,
            'selected': palette.selectedBackground,
            'tonal': palette.tonalBackground,
          };
          surfaces.forEach((surface, color) {
            expect(
              contrast(
                palette.accent,
                Color.alphaBlend(color, palette.editorBackground),
              ),
              greaterThanOrEqualTo(3),
              reason:
                  '${theme.name} ${data.brightness.name}'
                  '${increaseContrast ? ', Increase contrast' : ''}, on $surface',
            );
          });
        }
      }
    }
  });
}
