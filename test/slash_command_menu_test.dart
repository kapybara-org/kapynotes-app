import 'package:flutter/gestures.dart' show PointerDeviceKind;
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
  bool camera = true,
}) async {
  _menu.show(
    _context,
    anchor: const Rect.fromLTWH(40, 20, 2, 20),
    query: query,
    available: {
      for (final type in SlashCommandType.values)
        if (camera || type != SlashCommandType.camera) type,
    },
    markdownEnabled: markdown,
    hints: const {
      SlashCommandType.camera: '⌘⇧P',
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

final _media = find.byKey(const ValueKey('slash-command-media'));
final _back = find.byKey(const ValueKey('slash-command-back'));

bool _highlighted(WidgetTester tester, Finder finder) =>
    isSemantics(isSelected: true).matches(tester.getSemantics(finder), {});

/// The words beside each key under the menu: move, insert, and close or back.
List<String> _footer(WidgetTester tester) => [
  for (final text in tester.widgetList<Text>(
    find.descendant(
      of: find.byKey(const ValueKey('slash-command-keys')),
      matching: find.byType(Text),
    ),
  ))
    ?text.data,
];

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
      (_media, 'Media'),
      (_command(SlashCommandType.voiceNote), 'Voice note'),
      (_command(SlashCommandType.file), 'File'),
    ]) {
      expect(tester.getRect(insert).center.dy, closeTo(inserts.center.dy, 1));
      expect(find.text(label), findsNothing, reason: 'icons only');
    }
    // Camera, Photo and Video wait behind Media.
    for (final type in [
      SlashCommandType.camera,
      SlashCommandType.image,
      SlashCommandType.video,
    ]) {
      expect(_command(type), findsNothing, reason: type.name);
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
      ('image', SlashCommandType.image),
      ('cam', SlashCommandType.camera),
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
    expect(_highlighted(tester, _media), isTrue);
    expect(find.text('←→'), findsOneWidget);
    // Media has no key of its own, so its tooltip is its name alone.
    expect(
      tester
          .widget<Tooltip>(
            find.descendant(of: _media, matching: find.byType(Tooltip)),
          )
          .message,
      'Media',
    );

    _key(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(_selected(tester, SlashCommandType.voiceNote), isTrue);
    expect(find.text('Voice note  ⌘⇧R'), findsOneWidget);
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
    expect(_chosen.single.type, SlashCommandType.file);
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

  testWidgets('Enter on Media swaps the row for a back arrow, Camera, Photo '
      'and Video, with Camera highlighted and esc back', (tester) async {
    window(tester);
    await tester.pumpWidget(_app());
    final semantics = tester.ensureSemantics();
    await _open(tester, last: SlashCommandType.divider);
    expect(_footer(tester), contains('close'));

    _key(LogicalKeyboardKey.arrowDown);
    expect(_key(LogicalKeyboardKey.enter), isTrue);
    await tester.pumpAndSettle();
    expect(_chosen, isEmpty);
    expect(_menu.mediaOpen, isTrue);
    expect(_media, findsNothing);
    expect(_command(SlashCommandType.voiceNote), findsNothing);
    expect(_command(SlashCommandType.file), findsNothing);
    final row = tester.getRect(
      find.byKey(const ValueKey('slash-command-inserts')),
    );
    final xs = [
      for (final finder in [
        _back,
        _command(SlashCommandType.camera),
        _command(SlashCommandType.image),
        _command(SlashCommandType.video),
      ])
        tester.getRect(finder).left,
    ];
    for (var index = 1; index < xs.length; index++) {
      expect(xs[index], greaterThan(xs[index - 1]));
    }
    expect(tester.getRect(_back).top, greaterThanOrEqualTo(row.top));
    // The back arrow is a fixed square, the Table picker's back icon.
    expect(tester.getSize(_back), const Size(34, 34));
    expect(
      tester.getSize(_command(SlashCommandType.camera)).width,
      greaterThan(34),
    );
    expect(
      find.descendant(
        of: _back,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is KapyIcon && widget.icon == KapyIcons.arrowBackRounded,
        ),
      ),
      findsOneWidget,
    );
    expect(_selected(tester, SlashCommandType.camera), isTrue);
    expect(find.text('Camera  ⌘⇧P'), findsOneWidget);
    for (final name in ['Back', 'Camera', 'Photo', 'Video']) {
      expect(find.bySemanticsLabel(name), findsOneWidget, reason: name);
    }
    expect(_footer(tester), containsAllInOrder(['move', 'insert', 'back']));
    expect(_footer(tester), isNot(contains('close')));

    _key(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('Photo  ⌘⇧I'), findsOneWidget);
    expect(_key(LogicalKeyboardKey.enter), isTrue);
    expect(_chosen.single.type, SlashCommandType.image);
    await tester.pumpAndSettle();
    semantics.dispose();
  });

  testWidgets('a click on Media opens it too, and the back arrow goes back', (
    tester,
  ) async {
    window(tester);
    await tester.pumpWidget(_app());
    final semantics = tester.ensureSemantics();
    await _open(tester);

    await tester.tap(_media);
    await tester.pumpAndSettle();
    expect(_menu.mediaOpen, isTrue);
    expect(_selected(tester, SlashCommandType.camera), isTrue);

    // Left from Camera reaches the back arrow, named with its key.
    _key(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(_highlighted(tester, _back), isTrue);
    expect(find.text('Back  esc'), findsOneWidget);
    _key(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(_menu.mediaOpen, isFalse);
    expect(_highlighted(tester, _media), isTrue);

    await tester.tap(_media);
    await tester.pumpAndSettle();
    await tester.tap(_back);
    await tester.pumpAndSettle();
    expect(_menu.mediaOpen, isFalse);
    expect(_menu.isVisible, isTrue);
    expect(_chosen, isEmpty);
    semantics.dispose();
  });

  testWidgets('Esc steps back to Media before it closes the menu', (
    tester,
  ) async {
    window(tester);
    await tester.pumpWidget(_app());
    final semantics = tester.ensureSemantics();
    await _open(tester);
    await tester.tap(_media);
    await tester.pumpAndSettle();

    expect(_key(LogicalKeyboardKey.escape), isTrue);
    await tester.pumpAndSettle();
    expect(_menu.isVisible, isTrue);
    expect(_menu.mediaOpen, isFalse);
    expect(_highlighted(tester, _media), isTrue);
    expect(_footer(tester), contains('close'));

    expect(_key(LogicalKeyboardKey.escape), isTrue);
    await tester.pumpAndSettle();
    expect(_menu.isVisible, isFalse);
    semantics.dispose();
  });

  testWidgets('the row goes back to Media when the highlight or the pointer '
      'reaches a list row, or a letter is typed', (tester) async {
    window(tester);
    await tester.pumpWidget(_app());
    final semantics = tester.ensureSemantics();
    Future<void> openMedia() async {
      await tester.tap(_media);
      await tester.pumpAndSettle();
      expect(_menu.mediaOpen, isTrue);
    }

    await _open(tester);
    await openMedia();
    _key(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(_menu.mediaOpen, isFalse);
    expect(_selected(tester, SlashCommandType.divider), isTrue);
    expect(_media, findsOneWidget);

    await openMedia();
    _key(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(_menu.mediaOpen, isFalse);
    expect(_selected(tester, SlashCommandType.checklist), isTrue);

    await openMedia();
    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(pointer.removePointer);
    await pointer.addPointer(location: tester.getCenter(_back));
    await pointer.moveTo(tester.getCenter(_command(SlashCommandType.video)));
    await tester.pumpAndSettle();
    expect(_menu.mediaOpen, isTrue, reason: 'still on the row');
    await pointer.moveTo(tester.getCenter(_command(SlashCommandType.table)));
    await tester.pumpAndSettle();
    expect(_menu.mediaOpen, isFalse);
    expect(_selected(tester, SlashCommandType.table), isTrue);

    await pointer.moveTo(tester.getCenter(_media));
    await openMedia();
    await _open(tester, query: 't');
    expect(_menu.mediaOpen, isFalse);
    await _open(tester);
    expect(_menu.mediaOpen, isFalse);
    expect(_media, findsOneWidget);
    semantics.dispose();
  });

  testWidgets('typing skips Media: /cam, /photo and /video highlight that '
      'icon, and /media lists all three', (tester) async {
    window(tester);
    await tester.pumpWidget(_app());
    final semantics = tester.ensureSemantics();
    for (final (query, type, tooltip) in [
      ('cam', SlashCommandType.camera, 'Camera  ⌘⇧P'),
      ('camera', SlashCommandType.camera, 'Camera  ⌘⇧P'),
      ('photo', SlashCommandType.image, 'Photo  ⌘⇧I'),
      ('image', SlashCommandType.image, 'Photo  ⌘⇧I'),
      ('video', SlashCommandType.video, 'Video  ⌘⇧M'),
    ]) {
      await _open(tester, query: query);
      expect(_media, findsNothing, reason: query);
      expect(_selected(tester, type), isTrue, reason: query);
      expect(find.text(tooltip), findsOneWidget, reason: query);
      _menu.hide();
      await tester.pumpAndSettle();
    }

    await _open(tester, query: 'media');
    expect(_media, findsNothing);
    expect(_back, findsNothing);
    for (final type in [
      SlashCommandType.camera,
      SlashCommandType.image,
      SlashCommandType.video,
    ]) {
      expect(_command(type), findsOneWidget, reason: type.name);
    }
    expect(_command(SlashCommandType.voiceNote), findsNothing);
    expect(_selected(tester, SlashCommandType.camera), isTrue);
    _key(LogicalKeyboardKey.enter);
    expect(_chosen.single.type, SlashCommandType.camera);
    await tester.pumpAndSettle();
    semantics.dispose();
  });

  testWidgets('the + menu has Media too, and its search field finds Camera', (
    tester,
  ) async {
    window(tester);
    await tester.pumpWidget(_app());
    final semantics = tester.ensureSemantics();
    await _open(tester, search: true);
    final search = find.byKey(const ValueKey('slash-command-search'));

    await tester.tap(_media);
    await tester.pumpAndSettle();
    expect(_menu.mediaOpen, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(_menu.mediaOpen, isFalse);
    expect(search, findsOneWidget);

    await tester.tap(_media);
    await tester.pumpAndSettle();
    await tester.enterText(search, 'cam');
    await tester.pump();
    expect(_menu.mediaOpen, isFalse);
    expect(_selected(tester, SlashCommandType.camera), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(_chosen.single.type, SlashCommandType.camera);
    semantics.dispose();
  });

  testWidgets('the command used last behind Media starts on Media', (
    tester,
  ) async {
    window(tester);
    await tester.pumpWidget(_app());
    final semantics = tester.ensureSemantics();
    await _open(tester, last: SlashCommandType.video);
    expect(_highlighted(tester, _media), isTrue);
    semantics.dispose();
  });

  testWidgets('Linux has no Camera and no Media: the row stays four icons, '
      'with Image called Photo', (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.linux;
    window(tester);
    await tester.pumpWidget(_app());
    final semantics = tester.ensureSemantics();
    await _open(tester, camera: false);

    expect(_media, findsNothing);
    expect(_command(SlashCommandType.camera), findsNothing);
    final xs = [
      for (final type in [
        SlashCommandType.image,
        SlashCommandType.video,
        SlashCommandType.voiceNote,
        SlashCommandType.file,
      ])
        tester.getRect(_command(type)).left,
    ];
    for (var index = 1; index < xs.length; index++) {
      expect(xs[index], greaterThan(xs[index - 1]));
    }
    expect(
      tester.getSemantics(_command(SlashCommandType.image)),
      matchesSemantics(
        label: 'Photo',
        hint: 'Choose a picture',
        isButton: true,
        hasTapAction: true,
        hasSelectedState: true,
      ),
    );
    _menu.hide();
    await tester.pumpAndSettle();

    await _open(tester, query: 'media', camera: false);
    expect(find.text('No matching commands'), findsOneWidget);
    _menu.hide();
    await tester.pumpAndSettle();
    await _open(tester, query: 'image', camera: false);
    expect(_selected(tester, SlashCommandType.image), isTrue);
    semantics.dispose();
  });

  testWidgets('a phone keeps Image as it was', (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    window(tester);
    await tester.pumpWidget(_app());
    final semantics = tester.ensureSemantics();
    await _open(tester, camera: false);
    expect(_media, findsNothing);
    expect(
      tester.getSemantics(_command(SlashCommandType.image)),
      matchesSemantics(
        label: 'Image',
        hint: 'Take or choose a picture',
        isButton: true,
        hasTapAction: true,
        hasSelectedState: true,
      ),
    );
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
