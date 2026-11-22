import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/editor/slash_command_menu.dart';
import 'package:kapy_notes/ui/editor/slash_commands.dart';
import 'package:kapy_notes/ui/keycap.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';

late SlashCommandMenuController _menu;
late BuildContext _context;
final _chosen = <SlashCommandChoice>[];

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

/// Opens Commands at the top left the way the editor does, with every
/// command on offer and today's keys beside the inserts.
Future<void> _open(
  WidgetTester tester, {
  String query = '',
  SlashCommandType? last,
  bool search = false,
  bool markdown = true,
}) async {
  _menu.show(
    _context,
    anchor: const Rect.fromLTWH(40, 20, 2, 20),
    query: query,
    available: SlashCommandType.values.toSet(),
    markdownEnabled: markdown,
    hints: const {
      SlashCommandType.image: '⌘⇧I',
      SlashCommandType.video: '⌘⇧M',
      SlashCommandType.voiceNote: '⌘⇧R',
      SlashCommandType.file: '⌘⇧A',
    },
    lastCommand: last,
    search: search,
    onSelected: _chosen.add,
    onDismissed: (_) {},
  );
  await tester.pumpAndSettle();
}

bool _key(LogicalKeyboardKey key) => _menu.handleKeyEvent(
  KeyDownEvent(
    physicalKey: PhysicalKeyboardKey.enter,
    logicalKey: key,
    timeStamp: Duration.zero,
  ),
);

Finder _command(SlashCommandType type) =>
    find.byKey(ValueKey('slash-command-${type.name}'));

bool _selected(WidgetTester tester, SlashCommandType type) => isSemantics(
  isSelected: true,
).matches(tester.getSemantics(_command(type)), {});

void main() {
  setUpAll(loadTestFonts);
  setUp(() {
    _menu = SlashCommandMenuController();
    _chosen.clear();
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
  });
  tearDown(() {
    _menu.dispose();
    AppPlatform.debugTargetPlatformOverride = null;
  });

  void window(WidgetTester tester) {
    tester.view.physicalSize = const Size(420, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('Write comes first, then Blocks, then the inserts as a row of '
      'icons above the keys', (tester) async {
    window(tester);
    await tester.pumpWidget(_app());
    await _open(tester);

    const rows = [
      SlashCommandType.checklist,
      SlashCommandType.bulletedList,
      SlashCommandType.numberedList,
      SlashCommandType.heading1,
      SlashCommandType.heading2,
      SlashCommandType.heading3,
      SlashCommandType.quote,
      SlashCommandType.codeBlock,
      SlashCommandType.formula,
      SlashCommandType.table,
      SlashCommandType.divider,
    ];
    final tops = [for (final row in rows) tester.getTopLeft(_command(row)).dy];
    for (var index = 1; index < tops.length; index++) {
      expect(tops[index], greaterThan(tops[index - 1]));
    }
    expect(find.text('Write'), findsOneWidget);
    expect(find.text('Blocks'), findsOneWidget);
    expect(find.text('WRITE'), findsNothing);
    expect(find.text('BLOCKS'), findsNothing);
    expect(find.text('Insert'), findsNothing);

    final inserts = tester.getRect(
      find.byKey(const ValueKey('slash-command-inserts')),
    );
    final keys = tester.getRect(
      find.byKey(const ValueKey('slash-command-keys')),
    );
    expect(
      inserts.top,
      greaterThanOrEqualTo(tester.getRect(_command(rows.last)).bottom),
    );
    expect(keys.top, closeTo(inserts.bottom, 1));
    for (final (insert, label) in [
      (SlashCommandType.image, 'Image'),
      (SlashCommandType.video, 'Video'),
      (SlashCommandType.voiceNote, 'Voice note'),
      (SlashCommandType.file, 'File'),
    ]) {
      expect(
        tester.getRect(_command(insert)).center.dy,
        closeTo(inserts.center.dy, 1),
      );
      expect(find.text(label), findsNothing, reason: 'icons only');
    }
    expect(find.text('Drawing'), findsNothing);
    // Every row shows what typing it takes, as plain text, as D06 has it.
    expect(find.text('[ ]'), findsOneWidget);
    expect(find.text('-'), findsOneWidget);
    for (final cap in tester.widgetList<Keycap>(find.byType(Keycap))) {
      expect(cap.plain, isTrue, reason: cap.label);
    }
    expect(
      [
        for (final cap in tester.widgetList<Keycap>(
          find.descendant(
            of: find.byKey(const ValueKey('slash-command-keys')),
            matching: find.byType(Keycap),
          ),
        ))
          cap.label,
      ],
      ['↑↓', '↵', 'esc'],
    );
    expect(find.text('###'), findsOneWidget);
    expect(find.text(r'$$'), findsOneWidget);
    expect(find.text('|'), findsOneWidget);
  });

  testWidgets('in a plain note a heading shows no "#", and what needs '
      'Markdown says so', (tester) async {
    window(tester);
    await tester.pumpWidget(_app());
    await _open(tester, markdown: false);

    expect(find.text('#'), findsNothing);
    expect(find.text('##'), findsNothing);
    expect(
      find.descendant(
        of: _command(SlashCommandType.heading3),
        matching: find.text('Markdown'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the command used last starts highlighted, so "/" and Enter '
      'repeat it', (tester) async {
    window(tester);
    await tester.pumpWidget(_app());
    final semantics = tester.ensureSemantics();
    await _open(tester, last: SlashCommandType.heading2);

    expect(_selected(tester, SlashCommandType.heading2), isTrue);
    expect(
      find.descendant(
        of: _command(SlashCommandType.heading2),
        matching: find.text('last used'),
      ),
      findsOneWidget,
    );
    expect(_key(LogicalKeyboardKey.enter), isTrue);
    expect(_chosen.single.type, SlashCommandType.heading2);
    semantics.dispose();
  });

  testWidgets('typing filters everything, aliases included, and Enter takes '
      'the top match', (tester) async {
    window(tester);
    await tester.pumpWidget(_app());
    final semantics = tester.ensureSemantics();
    for (final (query, type) in [
      ('todo', SlashCommandType.checklist),
      ('photo', SlashCommandType.image),
      ('img', SlashCommandType.image),
      ('mic', SlashCommandType.voiceNote),
      ('record', SlashCommandType.voiceNote),
      ('math', SlashCommandType.formula),
      ('title', SlashCommandType.heading1),
      ('h1', SlashCommandType.heading1),
      ('v', SlashCommandType.video),
      ('head', SlashCommandType.heading1),
    ]) {
      await _open(tester, query: query, last: SlashCommandType.divider);
      expect(_selected(tester, type), isTrue, reason: query);
      _menu.hide();
      await tester.pumpAndSettle();
    }

    await _open(tester, query: 'v');
    expect(_command(SlashCommandType.voiceNote), findsOneWidget);
    expect(_command(SlashCommandType.divider), findsNothing);
    expect(_command(SlashCommandType.checklist), findsNothing);
    _menu.hide();
    await tester.pumpAndSettle();

    await _open(tester, query: 'todo');
    expect(
      find.descendant(
        of: _command(SlashCommandType.checklist),
        matching: find.text('todo'),
      ),
      findsOneWidget,
    );
    _key(LogicalKeyboardKey.enter);
    expect(_chosen.single.type, SlashCommandType.checklist);
    semantics.dispose();
  });

  testWidgets('↓ past Divider reaches the icon row, ←→ move along it with a '
      'tooltip, and Enter inserts', (tester) async {
    window(tester);
    await tester.pumpWidget(_app());
    final semantics = tester.ensureSemantics();
    await _open(tester, last: SlashCommandType.divider);

    expect(find.text('↑↓'), findsOneWidget);
    _key(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(_selected(tester, SlashCommandType.image), isTrue);
    expect(find.text('←→'), findsOneWidget);
    expect(find.text('Image  ⌘⇧I'), findsOneWidget);

    _key(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(_selected(tester, SlashCommandType.video), isTrue);
    expect(find.text('Video  ⌘⇧M'), findsOneWidget);
    _key(LogicalKeyboardKey.arrowLeft);
    _key(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(_selected(tester, SlashCommandType.file), isTrue);

    _key(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(_selected(tester, SlashCommandType.divider), isTrue);
    expect(find.text('↑↓'), findsOneWidget);
    // Left and right belong to the note's caret on the rows.
    expect(_key(LogicalKeyboardKey.arrowLeft), isFalse);

    _key(LogicalKeyboardKey.arrowDown);
    _key(LogicalKeyboardKey.arrowRight);
    _key(LogicalKeyboardKey.arrowRight);
    expect(_key(LogicalKeyboardKey.enter), isTrue);
    expect(_chosen.single.type, SlashCommandType.voiceNote);
    await tester.pumpAndSettle();
    semantics.dispose();
  });

  testWidgets('every row and icon is a button a screen reader can press', (
    tester,
  ) async {
    window(tester);
    await tester.pumpWidget(_app());
    final semantics = tester.ensureSemantics();
    await _open(tester, markdown: false);

    expect(
      tester.getSemantics(_command(SlashCommandType.quote)),
      matchesSemantics(
        label: 'Quote',
        hint: 'Requires Markdown',
        isButton: true,
        hasTapAction: true,
        hasSelectedState: true,
      ),
    );
    expect(find.bySemanticsLabel('Write'), findsOneWidget);
    tester.semantics.tap(find.semantics.byLabel('File'));
    await tester.pumpAndSettle();
    expect(_chosen.single.type, SlashCommandType.file);

    await _open(tester);
    tester.semantics.tap(find.semantics.byLabel('Heading 3'));
    await tester.pumpAndSettle();
    expect(_chosen.last.type, SlashCommandType.heading3);
    semantics.dispose();
  });

  testWidgets('opened from the "+", it has a search field of its own that '
      'holds the keys', (tester) async {
    window(tester);
    await tester.pumpWidget(_app());
    final semantics = tester.ensureSemantics();
    await _open(tester, search: true);

    final search = find.byKey(const ValueKey('slash-command-search'));
    expect(search, findsOneWidget);
    expect(tester.widget<TextField>(search).focusNode!.hasFocus, isTrue);
    await tester.enterText(search, 'quo');
    await tester.pump();
    expect(_command(SlashCommandType.checklist), findsNothing);
    expect(_selected(tester, SlashCommandType.quote), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(_chosen.single.type, SlashCommandType.quote);
    expect(search, findsNothing);
    semantics.dispose();
  });

  for (final brightness in Brightness.values) {
    testWidgets('looks like G9Z-0 in ${brightness.name}', (tester) async {
      window(tester);
      await tester.pumpWidget(_app(brightness: brightness));
      await _open(tester, last: SlashCommandType.heading2);
      await expectLater(
        find.byKey(const ValueKey('slash-command-menu')),
        matchesGoldenFile('goldens/commands_menu_${brightness.name}.png'),
      );
    });
  }
}
