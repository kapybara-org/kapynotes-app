import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/ui/focus_reveal.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';

class _Store extends LocalStore {
  _Store() : super(fileName: 'focus-reveal-test.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
}

FocusNode get _focus => FocusManager.instance.primaryFocus!;

String _name(FocusNode node) {
  final words = <String>[];
  void read(Element element) {
    final widget = element.widget;
    if (widget is Text && (widget.data ?? '').isNotEmpty) {
      words.add(widget.data!);
    }
    if (words.isEmpty) element.visitChildElements(read);
  }

  (node.context as Element?)?.visitChildElements(read);
  return words.firstOrNull ?? '$node';
}

/// Where [node] sits out of sight of its list, or null when it shows there.
String? _outOfSight(FocusNode node) {
  final scrollable = Scrollable.maybeOf(node.context!);
  if (scrollable == null) return null;
  final view = scrollable.context.findRenderObject()! as RenderBox;
  final shown = view.localToGlobal(Offset.zero) & view.size;
  return node.rect.overlaps(shown)
      ? null
      : '${_name(node)} at ${node.rect}, out of $shown';
}

Future<void> _shiftTab(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.pumpAndSettle();
}

/// [list] under a 100-high header, in a window 600 high.
Future<void> _window(
  WidgetTester tester,
  Widget list, {
  TargetPlatform platform = TargetPlatform.linux,
}) async {
  AppPlatform.debugTargetPlatformOverride = platform;
  addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(400, 600);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: KapyTheme.dark(),
      builder: (context, child) => FocusReveal(child: child!),
      home: Scaffold(
        body: Column(
          children: [
            const SizedBox(height: 100),
            Expanded(child: list),
          ],
        ),
      ),
    ),
  );
}

/// Twenty rows of 48 in a list 500 high.
Future<ScrollController> _rows(
  WidgetTester tester, {
  TargetPlatform platform = TargetPlatform.linux,
  List<FocusNode>? nodes,
}) async {
  final list = ScrollController();
  addTearDown(list.dispose);
  await _window(
    tester,
    platform: platform,
    SingleChildScrollView(
      controller: list,
      child: Column(
        children: [
          for (var i = 0; i < 20; i++)
            SizedBox(
              height: 48,
              child: TextButton(
                focusNode: nodes?[i],
                onPressed: () {},
                child: Text('Row $i'),
              ),
            ),
        ],
      ),
    ),
  );
  return list;
}

List<FocusNode> _nodes() {
  final nodes = [for (var i = 0; i < 20; i++) FocusNode()];
  addTearDown(() {
    for (final node in nodes) {
      node.dispose();
    }
  });
  return nodes;
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('Tab round past the last row brings the first back into sight, '
      'and Shift+Tab round past the first brings the last', (tester) async {
    final list = await _rows(tester);
    for (var i = 0; i < 20; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
    }
    expect(_name(_focus), 'Row 19');
    expect(list.offset, list.position.maxScrollExtent);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(_name(_focus), 'Row 0');
    expect(list.offset, 0);

    await _shiftTab(tester);
    expect(_name(_focus), 'Row 19');
    expect(list.offset, list.position.maxScrollExtent);
  });

  testWidgets('a list scrolled away from the focus stays put, and focus moved '
      'after a press is left where it is', (tester) async {
    final nodes = _nodes();
    final list = await _rows(tester, nodes: nodes);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(nodes.first.hasPrimaryFocus, isTrue);

    list.jumpTo(list.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(list.offset, list.position.maxScrollExtent);

    await tester.tapAt(const Offset(200, 50));
    await tester.pump();
    nodes[1].requestFocus();
    await tester.pumpAndSettle();
    expect(nodes[1].hasPrimaryFocus, isTrue);
    expect(list.offset, list.position.maxScrollExtent);
  });

  testWidgets('a key putting focus on a control partly in sight leaves the '
      'list where it is', (tester) async {
    final list = ScrollController();
    final page = FocusNode();
    addTearDown(list.dispose);
    addTearDown(page.dispose);
    await _window(
      tester,
      SingleChildScrollView(
        controller: list,
        child: Column(
          children: [
            const SizedBox(height: 300),
            Focus(
              focusNode: page,
              child: const SizedBox(width: 400, height: 900),
            ),
            const SizedBox(height: 300),
          ],
        ),
      ),
    );
    list.jumpTo(600);
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    page.requestFocus();
    await tester.pumpAndSettle();
    expect(page.hasPrimaryFocus, isTrue);
    expect(list.offset, 600);
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('on ${platform.name}, Shift+Tab brings a row into sight and '
        'no other key does', (tester) async {
      final nodes = _nodes();
      final list = await _rows(tester, platform: platform, nodes: nodes);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      nodes.last.requestFocus();
      await tester.pumpAndSettle();
      expect(list.offset, 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(nodes.first.hasPrimaryFocus, isTrue);

      await _shiftTab(tester);
      expect(nodes.last.hasPrimaryFocus, isTrue);
      expect(list.offset, list.position.maxScrollExtent);
    });
  }

  testWidgets('fifty Tabs round Settings, Notes keep every stop in sight', (
    tester,
  ) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 760);
    addTearDown(tester.view.reset);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('kapynotes/window_material'),
          (call) async => false,
        );
    final store = _Store();
    store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
    final notes = NotesStore(store, now: () => DateTime(2026, 11, 26, 10));
    await tester.runAsync(() async {
      await notes.load();
      notes.create(body: 'Groceries\nMilk');
    });
    await tester.pumpWidget(
      KapyNotesApp(
        store: store,
        notes: notes,
        rates: RatesRepository(store),
        prefs: LayoutPrefs(store)..load(),
        shortcuts: ShortcutPrefs(store)..load(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Settings').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Notes').last);
    await tester.pumpAndSettle();

    final stops = <String>[];
    final unseen = <String>[];
    for (var i = 0; i < 50; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      stops.add(_name(_focus));
      if (_outOfSight(_focus) case final where?) unseen.add(where);
    }
    expect(
      stops.where((name) => name == 'Note opened at launch').length,
      greaterThanOrEqualTo(2),
      reason: 'the lap never came round to the top of the pane',
    );
    expect(unseen, isEmpty);
  });
}
