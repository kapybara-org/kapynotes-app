import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/calc/highlight.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note_format.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/editor/note_field.dart';
import 'package:kapy_notes/ui/editor/selection_bubble.dart';
import 'package:material_ui/material_ui.dart';

import 'support/note_driver.dart';
import 'test_fonts.dart';

late ShortcutPrefs _shortcuts;

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'selection-bubble-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

/// What the note gives up of the window, as a sidebar opening beside it or
/// the window shrinking under it does.
final _taken = ValueNotifier(EdgeInsets.zero);

Widget _editor(
  String body, {
  bool markdown = true,
  ValueChanged<List<NoteFormatRange>>? onFormatsChanged,
}) {
  final engine = CalcEngine();
  return MaterialApp(
    theme: KapyTheme.dark(),
    home: Scaffold(
      body: ValueListenableBuilder(
        valueListenable: _taken,
        builder: (context, taken, child) => Padding(
          padding: taken.copyWith(top: taken.top + 120),
          child: child,
        ),
        child: NoteEditor(
          key: ValueKey(body),
          noteId: 'bubble',
          initialBody: body,
          engine: engine,
          highlighter: Highlighter(engine.registry),
          resultsVisible: false,
          markdownEnabled: markdown,
          autofocus: true,
          onDocumentChanged: (body, formats, attachments, _) =>
              onFormatsChanged?.call(formats),
          onSettingsPressed: () {},
          writingFont: WritingFont.handwritten,
          shortcuts: _shortcuts,
        ),
      ),
    ),
  );
}

TextEditingController _controller(WidgetTester tester) =>
    tester.widget<NoteField>(noteField).controller;

/// Selects [needle] and waits the bubble's settle out.
Future<void> _select(WidgetTester tester, String needle) async {
  final controller = _controller(tester);
  final start = controller.text.indexOf(needle);
  controller.selection = TextSelection(
    baseOffset: start,
    extentOffset: start + needle.length,
  );
  await tester.pump(const Duration(milliseconds: 160));
  await tester.pumpAndSettle();
}

Future<void> _chord(WidgetTester tester, ShortcutAction action) async {
  final binding = _shortcuts.bindingFor(action)!;
  final held = [
    if (binding.meta) LogicalKeyboardKey.metaLeft,
    if (binding.control) LogicalKeyboardKey.controlLeft,
    if (binding.alt) LogicalKeyboardKey.altLeft,
    if (binding.shift) LogicalKeyboardKey.shiftLeft,
  ];
  for (final key in held) {
    await tester.sendKeyDownEvent(key);
  }
  await tester.sendKeyEvent(binding.logicalKey);
  for (final key in held.reversed) {
    await tester.sendKeyUpEvent(key);
  }
  await tester.pumpAndSettle();
}

final _bubble = find.byKey(const ValueKey('selection-bubble'));

late SelectionBubbleController _standalone;
late BuildContext _context;
final _pressed = <String>[];
final _links = <String>[];
var _linkClosed = 0;

Widget _app({Brightness brightness = Brightness.dark}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: brightness == Brightness.dark ? KapyTheme.dark() : KapyTheme.light(),
  home: Builder(
    builder: (context) {
      _context = context;
      return ColoredBox(color: context.palette.paperColor);
    },
  ),
);

/// Shows the bubble by a selection whose first line is [above] and last
/// [below], the way the editor does, with every block and button on offer.
Future<void> _show(
  WidgetTester tester, {
  Rect above = const Rect.fromLTWH(60, 300, 160, 22),
  Rect? below,
  Rect within = Rect.largest,
  String block = 'Text',
  bool markdown = true,
}) async {
  SelectionAction action(String name, String label, KapyIconData icon) =>
      SelectionAction(
        name: name,
        label: label,
        icon: icon,
        active: name == 'bold',
        shortcut: name == 'bold' ? '⌘B' : null,
        onPressed: () => _pressed.add(name),
      );
  SelectionBlock choice(
    String label,
    KapyIconData icon, [
    String? trigger,
    bool requiresMarkdown = false,
  ]) => SelectionBlock(
    label: label,
    icon: icon,
    trigger: trigger,
    requiresMarkdown: requiresMarkdown,
    onSelected: () => _pressed.add(label),
  );
  _standalone.show(
    _context,
    above: above,
    below: below ?? above,
    within: within,
    block: block,
    markdownEnabled: markdown,
    blocks: [
      choice('Text', KapyIcons.textFormatRounded),
      choice('Heading 1', KapyIcons.heading1Rounded, '#'),
      choice('Heading 2', KapyIcons.heading2Rounded, '##'),
      choice('Heading 3', KapyIcons.heading3Rounded, '###', true),
      choice('Bulleted list', KapyIcons.bulletedListRounded, '-'),
      choice('Numbered list', KapyIcons.numberedListRounded, '1.', true),
      choice('Checklist', KapyIcons.checklistRounded, '[ ]'),
      choice('Quote', KapyIcons.quoteRounded, '>', true),
      choice('Code block', KapyIcons.codeRounded, '```', true),
    ],
    actions: [
      action('bold', 'Bold', KapyIcons.formatBoldRounded),
      action('italic', 'Italic', KapyIcons.formatItalicRounded),
      action('strikethrough', 'Strikethrough', KapyIcons.strikethroughRounded),
      action('code', 'Inline code', KapyIcons.inlineCodeRounded),
      action('link', 'Link', KapyIcons.linkRounded),
    ],
    onLink: _links.add,
    onLinkClosed: () => _linkClosed++,
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() {
    _shortcuts = ShortcutPrefs(_MemoryStore())..load();
    _standalone = SelectionBubbleController();
    _pressed.clear();
    _links.clear();
    _linkClosed = 0;
    _taken.value = EdgeInsets.zero;
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
  });
  tearDown(() {
    _standalone.dispose();
    AppPlatform.debugTargetPlatformOverride = null;
  });

  void window(WidgetTester tester) {
    tester.view.physicalSize = const Size(520, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  group('the bubble', () {
    testWidgets('sits over the selection, clear of the lines under it, and '
        'under it near the top edge', (tester) async {
      window(tester);
      await tester.pumpWidget(_app());
      await _show(tester);
      expect(tester.getRect(_bubble).bottom, 300 - 8);
      expect(tester.getRect(_bubble).height, 40);

      // Over the selection's first line, centred on it.
      await _show(
        tester,
        above: const Rect.fromLTWH(60, 200, 300, 22),
        below: const Rect.fromLTWH(60, 230, 100, 22),
      );
      expect(tester.getRect(_bubble).bottom, 200 - 8);
      expect(tester.getRect(_bubble).center.dx, closeTo(210, 0.5));

      // Near the bottom edge, over it still.
      await _show(tester, above: const Rect.fromLTWH(60, 420, 160, 22));
      expect(tester.getRect(_bubble).bottom, 420 - 8);

      // With no room over it, under its last line.
      await _show(
        tester,
        above: const Rect.fromLTWH(60, 20, 160, 22),
        below: const Rect.fromLTWH(60, 50, 100, 22),
      );
      expect(tester.getRect(_bubble).top, 50 + 22 + 8);
    });

    testWidgets('Text ▾ opens downward under a bubble that sits under the '
        'selection', (tester) async {
      window(tester);
      await tester.pumpWidget(_app());
      await _show(tester, above: const Rect.fromLTWH(60, 40, 160, 22));
      _standalone.toggleBlocks();
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const ValueKey('selection-block-menu'))).top,
        greaterThan(tester.getRect(_bubble).bottom),
      );
    });

    testWidgets('Text ▾ under the selection opens upward when it does not '
        'fit below and there is more room above', (tester) async {
      window(tester);
      await tester.pumpWidget(_app());
      await _show(
        tester,
        above: const Rect.fromLTWH(60, 20, 160, 22),
        below: const Rect.fromLTWH(60, 320, 160, 22),
      );
      expect(tester.getRect(_bubble).top, 320 + 22 + 8);
      _standalone.toggleBlocks();
      await tester.pumpAndSettle();
      final menu = find.byKey(const ValueKey('selection-block-menu'));
      expect(
        tester.getSize(menu).height,
        greaterThan(480 - 8 - tester.getRect(_bubble).bottom - 6),
      );
      expect(tester.getRect(menu).bottom, tester.getRect(_bubble).top - 6);
    });

    testWidgets('Text ▾ over a bubble near the top opens under the '
        'selection, clear of it', (tester) async {
      window(tester);
      await tester.pumpWidget(_app());
      await _show(tester, above: const Rect.fromLTWH(60, 60, 160, 22));
      expect(tester.getRect(_bubble).bottom, 60 - 8);
      _standalone.toggleBlocks();
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const ValueKey('selection-block-menu'))).top,
        60 + 22 + 8,
      );
    });

    testWidgets('keeps to the note\'s pane, menu and all', (tester) async {
      window(tester);
      await tester.pumpWidget(_app());
      const pane = Rect.fromLTRB(120, 0, 520, 480);
      await _show(
        tester,
        above: const Rect.fromLTWH(130, 420, 40, 22),
        within: pane,
      );
      expect(tester.getRect(_bubble).left, pane.left + 8);

      // Over a selection at the top of the pane it would cover what sits
      // above the note, so it goes under.
      await _show(
        tester,
        above: const Rect.fromLTWH(130, 130, 40, 22),
        within: const Rect.fromLTRB(120, 100, 520, 480),
      );
      expect(tester.getRect(_bubble).top, 130 + 22 + 8);

      _standalone.toggleBlocks();
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const ValueKey('selection-block-menu'))).left,
        greaterThanOrEqualTo(pane.left + 8),
      );
    });

    testWidgets('Text ▾ opens upward with each block and its key, and esc '
        'closes it before the bubble', (tester) async {
      window(tester);
      await tester.pumpWidget(_app());
      await _show(
        tester,
        above: const Rect.fromLTWH(60, 420, 160, 22),
        block: 'Heading 1',
        markdown: false,
      );
      expect(find.text('Heading 1'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('selection-block')));
      await tester.pumpAndSettle();
      final menu = find.byKey(const ValueKey('selection-block-menu'));
      expect(
        tester.getRect(menu).bottom,
        lessThan(tester.getRect(_bubble).top),
      );
      expect(tester.getSize(menu).width, 236);
      expect(find.text('TURN INTO'), findsOneWidget);
      expect(
        find.descendant(of: menu, matching: find.text('Markdown')),
        findsNWidgets(4),
      );

      expect(
        _standalone.handleKeyEvent(
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.escape,
            logicalKey: LogicalKeyboardKey.escape,
            timeStamp: Duration.zero,
          ),
        ),
        isTrue,
      );
      await tester.pumpAndSettle();
      expect(menu, findsNothing);
      expect(_bubble, findsOneWidget);

      // Too little room either side: toward the larger, and on screen.
      await _show(tester, block: 'Heading 1', markdown: false);
      await tester.tap(find.byKey(const ValueKey('selection-block')));
      await tester.pumpAndSettle();
      expect(tester.getRect(menu).top, greaterThanOrEqualTo(8));
      expect(tester.getRect(menu).bottom, lessThanOrEqualTo(472));
      await tester.tap(find.byKey(const ValueKey('selection-block-Quote')));
      await tester.pumpAndSettle();
      expect(_pressed, ['Quote']);
      expect(menu, findsNothing);
    });

    testWidgets('link becomes an address field: enter links, esc goes back', (
      tester,
    ) async {
      window(tester);
      await tester.pumpWidget(_app());
      await _show(tester);
      _standalone.editLink();
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('selection-link-field'));
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
      expect(_standalone.editingLink, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(field, findsNothing);
      expect(_linkClosed, 1);
      expect(find.byKey(const ValueKey('selection-bold')), findsOneWidget);

      _standalone.editLink();
      await tester.pumpAndSettle();
      await tester.enterText(field, ' kapynotes.app ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(_links, ['kapynotes.app']);
      expect(_bubble, findsNothing);
    });

    testWidgets('every button is one a screen reader can press', (
      tester,
    ) async {
      window(tester);
      await tester.pumpWidget(_app());
      final semantics = tester.ensureSemantics();
      await _show(tester);

      expect(
        tester.getSemantics(find.byKey(const ValueKey('selection-bold'))),
        matchesSemantics(
          label: 'Bold',
          isButton: true,
          hasTapAction: true,
          hasToggledState: true,
          isToggled: true,
        ),
      );
      for (final label in ['Italic', 'Strikethrough', 'Inline code', 'Link']) {
        tester.semantics.tap(find.semantics.byLabel(label));
        await tester.pumpAndSettle();
      }
      expect(_pressed, ['italic', 'strikethrough', 'code', 'link']);

      tester.semantics.tap(find.semantics.byLabel('Turn into'));
      await tester.pumpAndSettle();
      expect(_standalone.blocksOpen, isTrue);
      tester.semantics.tap(find.semantics.byLabel('Checklist'));
      await tester.pumpAndSettle();
      expect(_pressed.last, 'Checklist');
      semantics.dispose();
    });

    for (final brightness in Brightness.values) {
      testWidgets('looks like ET7-0 in ${brightness.name}', (tester) async {
        window(tester);
        await tester.pumpWidget(_app(brightness: brightness));
        await _show(tester);
        await expectLater(
          _bubble,
          matchesGoldenFile('goldens/selection_bubble_${brightness.name}.png'),
        );
      });
    }

    testWidgets('looks like ET7-0 with Text ▾ open', (tester) async {
      window(tester);
      await tester.pumpWidget(_app());
      await _show(tester, above: const Rect.fromLTWH(60, 420, 160, 22));
      _standalone.toggleBlocks();
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/selection_bubble_turn_into.png'),
      );
    });

    testWidgets('looks like ET7-0 as a link field', (tester) async {
      window(tester);
      await tester.pumpWidget(_app());
      await _show(tester);
      _standalone.editLink();
      await tester.pumpAndSettle();
      await expectLater(
        _bubble,
        matchesGoldenFile('goldens/selection_bubble_link.png'),
      );
    });
  });

  group('in a note', () {
    testWidgets('appears once a selection settles, and goes with it', (
      tester,
    ) async {
      await tester.pumpWidget(_editor('Some words to format'));
      await tester.pumpAndSettle();
      final controller = _controller(tester);
      controller.selection = const TextSelection(
        baseOffset: 5,
        extentOffset: 10,
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(_bubble, findsNothing);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pumpAndSettle();
      expect(_bubble, findsOneWidget);
      final editable = NoteDriver(tester);
      final line = editable.toGlobal(
        Offset(0, editable.boxesFor(controller.selection).last.bottom),
      );
      expect(
        tester.getRect(_bubble).top,
        moreOrLessEquals(line.dy + 8, epsilon: 0.01),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(_bubble, findsNothing);
      expect(controller.selection.isCollapsed, isFalse);

      await _select(tester, 'format');
      expect(_bubble, findsOneWidget);
      controller.selection = const TextSelection.collapsed(offset: 3);
      await tester.pumpAndSettle();
      expect(_bubble, findsNothing);
    });

    testWidgets('sits over the selection, clear of the line written under '
        'it', (tester) async {
      const body = 'Title\nfirst line\nsecond line\nthe words to format\nnext';
      await tester.pumpWidget(_editor(body));
      await tester.pumpAndSettle();
      await _select(tester, 'words');
      final editable = NoteDriver(tester);
      final selected = editable.boxesFor(_controller(tester).selection).first;
      expect(
        tester.getRect(_bubble).bottom,
        moreOrLessEquals(
          editable.toGlobal(Offset(0, selected.top)).dy - 8,
          epsilon: 0.01,
        ),
      );
    });

    testWidgets('follows its selection when the note moves over, as it does '
        'when the sidebar opens', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _editor('Title\nThese are a few of the words we want to format'),
      );
      await tester.pumpAndSettle();
      await _select(tester, 'format');
      final editable = NoteDriver(tester);
      double selectedAt() => editable
          .toGlobal(
            editable
                .boxesFor(_controller(tester).selection)
                .first
                .toRect()
                .center,
          )
          .dx;
      final before = selectedAt();
      expect(tester.getRect(_bubble).center.dx, closeTo(before, 0.5));

      _taken.value = const EdgeInsets.only(left: 280);
      await tester.pumpAndSettle();
      expect(selectedAt(), isNot(closeTo(before, 1)));
      expect(tester.getRect(_bubble).center.dx, closeTo(selectedAt(), 0.5));
      expect(_controller(tester).selection.isCollapsed, isFalse);
    });

    testWidgets('goes when the window shrinks the selection out of sight', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final body = [
        'Title',
        for (var line = 1; line <= 12; line++) 'Line $line',
        'the last words',
      ].join('\n');
      await tester.pumpWidget(_editor(body));
      await tester.pumpAndSettle();
      await _select(tester, 'last');
      expect(_bubble, findsOneWidget);

      _taken.value = const EdgeInsets.only(bottom: 560);
      await tester.pumpAndSettle();
      expect(_bubble, findsNothing);
      expect(_controller(tester).selection.isCollapsed, isFalse);
    });

    testWidgets('lifts off while the note scrolls and settles back over its '
        'selection, from out of sight too', (tester) async {
      tester.view.physicalSize = const Size(1200, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // Long enough to scroll, and opened at its end, by the words.
      final body = [
        'Title',
        for (var line = 1; line <= 60; line++) 'Line $line',
        'the words to format',
        'The end',
      ].join('\n');
      await tester.pumpWidget(_editor(body));
      await tester.pumpAndSettle();
      await _select(tester, 'words');
      expect(_bubble, findsOneWidget);
      final editable = NoteDriver(tester);
      final controller = _controller(tester);
      Future<void> wheel(double dy) async {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: const Offset(600, 400),
            scrollDelta: Offset(0, dy),
          ),
        );
        await tester.pump();
      }

      Future<void> settle() async {
        await tester.pump(const Duration(milliseconds: 160));
        await tester.pumpAndSettle();
      }

      await wheel(-20);
      expect(_bubble, findsNothing);
      await settle();
      expect(_bubble, findsOneWidget);
      final words = editable.boxesFor(controller.selection).first.toRect();
      expect(
        tester
            .getRect(_bubble)
            .overlaps(
              Rect.fromPoints(
                editable.toGlobal(words.topLeft),
                editable.toGlobal(words.bottomRight),
              ),
            ),
        isFalse,
      );

      await wheel(-600);
      await settle();
      expect(_bubble, findsNothing);
      await wheel(600);
      await settle();
      expect(_bubble, findsOneWidget);
      expect(controller.selection.isCollapsed, isFalse);
    });

    testWidgets('a bubble put away with esc stays away through a scroll', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // Long enough to scroll, and opened at its end, by the words.
      final body = [
        'Title',
        for (var line = 1; line <= 60; line++) 'Line $line',
        'the words to format',
        'The end',
      ].join('\n');
      await tester.pumpWidget(_editor(body));
      await tester.pumpAndSettle();
      await _select(tester, 'words');
      expect(_bubble, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(_bubble, findsNothing);
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(600, 400),
          scrollDelta: Offset(0, -20),
        ),
      );
      await tester.pump(const Duration(milliseconds: 160));
      await tester.pumpAndSettle();
      expect(_bubble, findsNothing);
      expect(_controller(tester).selection.isCollapsed, isFalse);
    });

    testWidgets('a click outside the note closes the link field, and a trip '
        'to another app for the address does not', (tester) async {
      const body = 'Some words to format';
      await tester.pumpWidget(_editor(body));
      await tester.pumpAndSettle();
      await _select(tester, 'words');
      await _chord(tester, ShortcutAction.formatLink);
      final field = find.byKey(const ValueKey('selection-link-field'));
      expect(field, findsOneWidget);

      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pumpAndSettle();
      }
      expect(field, findsOneWidget);

      final away = await tester.startGesture(
        const Offset(20, 20),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 80));
      await away.up();
      await tester.pumpAndSettle();
      expect(_bubble, findsNothing);
      expect(_controller(tester).text, body);
    });

    testWidgets(
      'every button works under a mouse click, and the note keeps its '
      'focus and its selection',
      (tester) async {
        const body = 'Some words to format';
        await tester.pumpWidget(_editor(body));
        await tester.pumpAndSettle();
        final controller = _controller(tester);
        final focus = tester.widget<NoteField>(noteField).focusNode;
        // A click as a mouse makes one: the button goes down, frames pass,
        // and it comes up again.
        Future<void> click(String key) async {
          final gesture = await tester.startGesture(
            tester.getCenter(find.byKey(ValueKey(key))),
            kind: PointerDeviceKind.mouse,
          );
          await tester.pump(const Duration(milliseconds: 80));
          await gesture.up();
          await tester.pumpAndSettle();
        }

        for (final action in ['bold', 'italic', 'strikethrough', 'code']) {
          await _select(tester, 'words');
          expect(focus.hasFocus, isTrue);
          await click('selection-$action');
          expect(controller.text, isNot(body), reason: action);
          expect(controller.text, contains('words'), reason: action);
          expect(focus.hasFocus, isTrue, reason: action);
          expect(controller.selection.isCollapsed, isFalse, reason: action);
          expect(_bubble, findsOneWidget, reason: action);
          await click('selection-$action');
          expect(controller.text, body, reason: action);
        }

        await _select(tester, 'words');
        await click('selection-link');
        final field = find.byKey(const ValueKey('selection-link-field'));
        expect(field, findsOneWidget);
        await tester.enterText(field, 'https://kapynotes.app');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        expect(
          controller.text,
          'Some [words](https://kapynotes.app) to format',
        );

        controller.text = body;
        await _select(tester, 'words');
        await click('selection-block');
        expect(
          find.byKey(const ValueKey('selection-block-menu')),
          findsOneWidget,
        );
        await click('selection-block-Heading 2');
        expect(controller.text, '## $body');
        expect(focus.hasFocus, isTrue);

        await _select(tester, 'words');
        await _chord(tester, ShortcutAction.formatBold);
        expect(controller.text, isNot('## $body'));
        await _chord(tester, ShortcutAction.formatBold);
        await _chord(tester, ShortcutAction.formatItalic);
        expect(controller.text, isNot('## $body'));

        // Anywhere else is still outside the note.
        await _select(tester, 'words');
        expect(_bubble, findsOneWidget);
        final away = await tester.startGesture(
          const Offset(20, 20),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump(const Duration(milliseconds: 80));
        await away.up();
        await tester.pumpAndSettle();
        expect(focus.hasFocus, isFalse);
        expect(_bubble, findsNothing);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets('bold, strikethrough and inline code toggle, and stay', (
      tester,
    ) async {
      await tester.pumpWidget(_editor('Some words to format'));
      await tester.pumpAndSettle();
      final controller = _controller(tester);

      await _select(tester, 'words');
      await tester.tap(find.byKey(const ValueKey('selection-strikethrough')));
      await tester.pumpAndSettle();
      expect(controller.text, 'Some ~~words~~ to format');
      expect(_bubble, findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('selection-strikethrough')));
      await tester.pumpAndSettle();
      expect(controller.text, 'Some words to format');

      await _chord(tester, ShortcutAction.formatCode);
      expect(controller.text, 'Some `words` to format');
      await _chord(tester, ShortcutAction.formatStrikethrough);
      expect(controller.text, 'Some `~~words~~` to format');
    });

    testWidgets('link: the field takes the address and the words link to it', (
      tester,
    ) async {
      await tester.pumpWidget(_editor('Read the site today'));
      await tester.pumpAndSettle();
      final controller = _controller(tester);

      controller.selection = const TextSelection.collapsed(offset: 4);
      await tester.pump();
      await _chord(tester, ShortcutAction.formatLink);
      expect(find.byKey(const ValueKey('selection-link-field')), findsNothing);

      await _select(tester, 'site');
      await _chord(tester, ShortcutAction.formatLink);
      final field = find.byKey(const ValueKey('selection-link-field'));
      expect(field, findsOneWidget);
      await tester.enterText(field, 'https://kapynotes.app');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(controller.text, 'Read the [site](https://kapynotes.app) today');
    });

    testWidgets('Text ▾ turns the line into a heading or a list', (
      tester,
    ) async {
      await tester.pumpWidget(_editor('A thought'));
      await tester.pumpAndSettle();
      final controller = _controller(tester);

      await _select(tester, 'thought');
      await tester.tap(find.byKey(const ValueKey('selection-block')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('selection-block-Heading 2')));
      await tester.pumpAndSettle();
      expect(controller.text, '## A thought');

      await _select(tester, 'thought');
      expect(find.text('Heading 2'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('selection-block')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('selection-block-Text')));
      await tester.pumpAndSettle();
      expect(controller.text, 'A thought');
    });

    testWidgets('a plain note makes bold itself and asks before Markdown', (
      tester,
    ) async {
      final formats = <List<NoteFormatRange>>[];
      await tester.pumpWidget(
        _editor('Some words', markdown: false, onFormatsChanged: formats.add),
      );
      await tester.pumpAndSettle();
      final controller = _controller(tester);

      await _select(tester, 'words');
      await tester.tap(find.byKey(const ValueKey('selection-bold')));
      await tester.pumpAndSettle();
      expect(formats.last, const [
        NoteFormatRange(start: 5, end: 10, format: NoteFormat.bold),
      ]);

      await tester.tap(find.byKey(const ValueKey('selection-strikethrough')));
      await tester.pumpAndSettle();
      expect(find.text('Turn on Markdown?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(controller.text, 'Some words');
    });
  });
}
