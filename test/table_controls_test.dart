import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/editor/table_controls.dart';
import 'package:material_ui/material_ui.dart';

import 'support/desk.dart';
import 'test_fonts.dart';

const _table =
    '| Item | Who | Cost |\n'
    '| --- | :---: | ---: |\n'
    '| Tickets | Ana | 412 |\n'
    '| Hotel | Sanjay | 896 |\n'
    '| Taxi | Ana | 38 |';
const _body = 'Lisbon packing\n\n$_table\n\nafter';

String _with(String table) => 'Lisbon packing\n\n$table\n\nafter';

final _mac = TargetPlatformVariant.only(TargetPlatform.macOS);
final _phone = TargetPlatformVariant.only(TargetPlatform.iOS);

void main() {
  setUpAll(() async {
    await loadTestFonts();
    // The keycap glyphs a Mac's menus print, which no loaded test face has.
    final symbols = FontLoader('Noto Sans')
      ..addFont(
        File(
          '/System/Library/Fonts/Apple Symbols.ttf',
        ).readAsBytes().then(ByteData.sublistView),
      );
    await symbols.load();
  });

  Future<(Desk, TableFrame)> open(
    WidgetTester tester, {
    String body = _body,
    Size window = const Size(640, 480),
    bool dark = true,
  }) async {
    final desk = Desk(tester);
    await desk.open(
      body,
      window: window,
      theme: dark ? KapyTheme.dark() : KapyTheme.light(),
    );
    await desk.settle();
    return (desk, desk.editor.debugTableFrames.single);
  }

  TableFrame frameOf(Desk desk) => desk.editor.debugTableFrames.single;

  Offset cell(TableFrame frame, int row, int column) => Offset(
    (frame.columnEdges[column] + frame.columnEdges[column + 1]) / 2,
    (frame.rowEdges[row] + frame.rowEdges[row + 1]) / 2,
  );

  /// A phone with the cell in the second body row open.
  Future<Desk> editCell(WidgetTester tester, {bool dark = true}) async {
    final (desk, frame) = await open(
      tester,
      window: const Size(390, 640),
      dark: dark,
    );
    await tester.tapAt(cell(frame, 2, 0));
    await desk.settle();
    return desk;
  }

  /// The one mouse a test moves around, added the first time it hovers.
  TestGesture? mouse;

  Future<TestGesture> hover(WidgetTester tester, Offset at) async {
    var pointer = mouse;
    if (pointer == null) {
      pointer = mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await pointer.addPointer(location: Offset.zero);
      addTearDown(() async {
        await mouse?.removePointer();
        mouse = null;
      });
    }
    await pointer.moveTo(at);
    await tester.pumpAndSettle();
    return pointer;
  }

  /// Hovers row [row] and clicks its grip, which picks it and opens its menu.
  Future<void> pickRow(Desk desk, int row) async {
    final frame = frameOf(desk);
    await hover(desk.tester, cell(frame, row, 0));
    await desk.clickKey('table-row-grip-$row');
  }

  Future<void> pickColumn(Desk desk, int column) async {
    final frame = frameOf(desk);
    await hover(desk.tester, cell(frame, 1, column));
    await desk.clickKey('table-column-grip-$column');
  }

  Future<void> choose(Desk desk, TableCommand command) =>
      desk.clickKey('table-menu-${command.name}');

  Future<void> dismissMenu(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  }

  /// Presses a chord's keys down, then up, as a person does.
  Future<void> chord(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool primary = false,
    bool alt = false,
    bool shift = false,
  }) async {
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    final modifiers = [
      if (primary)
        mac ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft,
      if (alt) LogicalKeyboardKey.altLeft,
      if (shift) LogicalKeyboardKey.shiftLeft,
    ];
    for (final modifier in modifiers) {
      await tester.sendKeyDownEvent(modifier);
    }
    await tester.sendKeyEvent(key);
    for (final modifier in modifiers.reversed) {
      await tester.sendKeyUpEvent(modifier);
    }
    await tester.pumpAndSettle();
  }

  /// One undo puts the note back exactly as it was.
  Future<void> expectOneUndo(Desk desk, String before) async {
    await desk.undo();
    await desk.settle();
    expect(desk.text, before);
  }

  group('the "+" controls', () {
    testWidgets('past the last row adds one, and one undo takes it away', (
      tester,
    ) async {
      final (desk, frame) = await open(tester);
      await hover(tester, cell(frame, 2, 1));
      await desk.clickKey('table-add-row');
      expect(desk.text, _with('$_table\n|  |  |  |'));
      await expectOneUndo(desk, _body);
    }, variant: _mac);

    testWidgets('a quick double click adds two rows, and one undo removes '
        'both', (tester) async {
      final (desk, frame) = await open(tester);
      await hover(tester, cell(frame, 2, 1));
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('table-add-row'))),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('table-add-row'))),
        kind: PointerDeviceKind.mouse,
      );
      await desk.settle();
      expect(desk.text, _with('$_table\n|  |  |  |\n|  |  |  |'));
      await expectOneUndo(desk, _body);
    }, variant: _mac);

    testWidgets('past the last column adds one', (tester) async {
      final (desk, frame) = await open(tester);
      await hover(tester, cell(frame, 2, 1));
      await desk.clickKey('table-add-column');
      expect(
        desk.text,
        _with(
          '| Item | Who | Cost |  |\n'
          '| --- | :---: | ---: | --- |\n'
          '| Tickets | Ana | 412 |  |\n'
          '| Hotel | Sanjay | 896 |  |\n'
          '| Taxi | Ana | 38 |  |',
        ),
      );
      await expectOneUndo(desk, _body);
    }, variant: _mac);

    testWidgets('between two rows inserts one there', (tester) async {
      final (desk, frame) = await open(tester);
      await hover(tester, Offset(frame.grid.left + 2, frame.rowEdges[2] + 1));
      await desk.clickKey('table-row-gap-2');
      expect(desk.text, _body.replaceFirst('| Hotel', '|  |  |  |\n| Hotel'));
      await expectOneUndo(desk, _body);
    }, variant: _mac);

    testWidgets('between two columns inserts one there', (tester) async {
      final (desk, frame) = await open(tester);
      await hover(tester, Offset(frame.columnEdges[1] + 1, frame.grid.top + 2));
      await desk.clickKey('table-column-gap-1');
      expect(
        desk.text,
        _with(
          '| Item |  | Who | Cost |\n'
          '| --- | --- | :---: | ---: |\n'
          '| Tickets |  | Ana | 412 |\n'
          '| Hotel |  | Sanjay | 896 |\n'
          '| Taxi |  | Ana | 38 |',
        ),
      );
      await expectOneUndo(desk, _body);
    }, variant: _mac);
  });

  group('a grip', () {
    testWidgets('picks its row, and Delete takes it away', (tester) async {
      final (desk, _) = await open(tester);
      await pickRow(desk, 2);
      await dismissMenu(tester);
      await desk.key(LogicalKeyboardKey.backspace);
      await desk.settle();
      expect(desk.text, _body.replaceFirst('| Hotel | Sanjay | 896 |\n', ''));
      await expectOneUndo(desk, _body);
    }, variant: _mac);

    testWidgets('picks its column, and Delete takes it away', (tester) async {
      final (desk, _) = await open(tester);
      await pickColumn(desk, 1);
      await dismissMenu(tester);
      await desk.key(LogicalKeyboardKey.delete);
      await desk.settle();
      expect(
        desk.text,
        _with(
          '| Item | Cost |\n'
          '| --- | ---: |\n'
          '| Tickets | 412 |\n'
          '| Hotel | 896 |\n'
          '| Taxi | 38 |',
        ),
      );
      await expectOneUndo(desk, _body);
    }, variant: _mac);

    testWidgets('menu moves a row down', (tester) async {
      final (desk, _) = await open(tester);
      await pickRow(desk, 1);
      await choose(desk, TableCommand.rowDown);
      expect(
        desk.text,
        _with(
          '| Item | Who | Cost |\n'
          '| --- | :---: | ---: |\n'
          '| Hotel | Sanjay | 896 |\n'
          '| Tickets | Ana | 412 |\n'
          '| Taxi | Ana | 38 |',
        ),
      );
      await expectOneUndo(desk, _body);
    }, variant: _mac);

    testWidgets('menu moves a column, its alignment going with it', (
      tester,
    ) async {
      final (desk, _) = await open(tester);
      await pickColumn(desk, 2);
      await choose(desk, TableCommand.columnBack);
      expect(
        desk.text,
        _with(
          '| Item | Cost | Who |\n'
          '| --- | ---: | :---: |\n'
          '| Tickets | 412 | Ana |\n'
          '| Hotel | 896 | Sanjay |\n'
          '| Taxi | 38 | Ana |',
        ),
      );
      await expectOneUndo(desk, _body);
    }, variant: _mac);

    testWidgets('menu inserts above and below, and deletes', (tester) async {
      final (desk, _) = await open(tester);
      await pickRow(desk, 2);
      await choose(desk, TableCommand.rowAbove);
      expect(desk.text, _body.replaceFirst('| Hotel', '|  |  |  |\n| Hotel'));
      await expectOneUndo(desk, _body);
      await pickRow(desk, 2);
      await choose(desk, TableCommand.rowBelow);
      expect(desk.text, _body.replaceFirst('| Taxi', '|  |  |  |\n| Taxi'));
      await expectOneUndo(desk, _body);
      await pickRow(desk, 3);
      await choose(desk, TableCommand.deleteRow);
      expect(desk.text, _body.replaceFirst('\n| Taxi | Ana | 38 |', ''));
      await expectOneUndo(desk, _body);
    }, variant: _mac);

    testWidgets('menu aligns its column with the colons GFM uses', (
      tester,
    ) async {
      final (desk, _) = await open(tester);
      await pickColumn(desk, 0);
      await choose(desk, TableCommand.alignEnd);
      expect(desk.text, _body.replaceFirst('| --- |', '| ---: |'));
      await expectOneUndo(desk, _body);
      await pickColumn(desk, 1);
      await choose(desk, TableCommand.alignStart);
      expect(desk.text, _body.replaceFirst('| :---: |', '| --- |'));
    }, variant: _mac);

    testWidgets('the header row stays where it is', (tester) async {
      final (desk, _) = await open(tester);
      await pickRow(desk, 0);
      for (final command in [
        TableCommand.rowAbove,
        TableCommand.rowUp,
        TableCommand.rowDown,
        TableCommand.deleteRow,
      ]) {
        final item = tester.widget<PopupMenuItem<TableCommand>>(
          find.byKey(ValueKey('table-menu-${command.name}')),
        );
        expect(item.enabled, isFalse, reason: command.name);
      }
      await dismissMenu(tester);
      await desk.key(LogicalKeyboardKey.backspace);
      await desk.settle();
      expect(desk.text, _body);
    }, variant: _mac);

    testWidgets('a one-column table keeps its column', (tester) async {
      const one = '| Item |\n| --- |\n| Tea |';
      final (desk, _) = await open(tester, body: _with(one));
      await pickColumn(desk, 0);
      final item = tester.widget<PopupMenuItem<TableCommand>>(
        find.byKey(const ValueKey('table-menu-deleteColumn')),
      );
      expect(item.enabled, isFalse);
      await dismissMenu(tester);
      await desk.key(LogicalKeyboardKey.backspace);
      await desk.settle();
      expect(desk.text, _with(one));
    }, variant: _mac);

    testWidgets('grips and "+" have labels for a screen reader', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final (_, frame) = await open(tester);
      await hover(tester, cell(frame, 2, 1));
      expect(find.bySemanticsLabel('Row 2'), findsOneWidget);
      expect(find.bySemanticsLabel('Column 2'), findsOneWidget);
      expect(find.bySemanticsLabel('Add row'), findsOneWidget);
      expect(find.bySemanticsLabel('Add column'), findsOneWidget);
      semantics.dispose();
    }, variant: _mac);
  });

  group('dragging', () {
    Future<void> drag(
      WidgetTester tester,
      Offset from,
      Offset to, {
      bool escape = false,
    }) async {
      final gesture = await tester.startGesture(
        from,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 50));
      for (var i = 1; i <= 8; i++) {
        await gesture.moveTo(Offset.lerp(from, to, i / 8)!);
        await tester.pump(const Duration(milliseconds: 16));
      }
      if (escape) {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
      }
      await gesture.up();
      await tester.pumpAndSettle();
    }

    testWidgets('a row grip moves its row where it is dropped', (tester) async {
      final (desk, frame) = await open(tester);
      await hover(tester, cell(frame, 1, 0));
      final grip = tester.getCenter(
        find.byKey(const ValueKey('table-row-grip-1')),
      );
      await drag(tester, grip, Offset(grip.dx, cell(frame, 3, 0).dy));
      expect(
        desk.text,
        _with(
          '| Item | Who | Cost |\n'
          '| --- | :---: | ---: |\n'
          '| Hotel | Sanjay | 896 |\n'
          '| Taxi | Ana | 38 |\n'
          '| Tickets | Ana | 412 |',
        ),
      );
      await expectOneUndo(desk, _body);
    }, variant: _mac);

    testWidgets('Escape lets go of a drag and leaves the table', (
      tester,
    ) async {
      final (desk, frame) = await open(tester);
      await hover(tester, cell(frame, 1, 0));
      final grip = tester.getCenter(
        find.byKey(const ValueKey('table-row-grip-1')),
      );
      await drag(
        tester,
        grip,
        Offset(grip.dx, cell(frame, 3, 0).dy),
        escape: true,
      );
      expect(desk.text, _body);
    }, variant: _mac);

    testWidgets('a column grip moves its column, alignment and all', (
      tester,
    ) async {
      final (desk, frame) = await open(tester);
      await hover(tester, cell(frame, 1, 0));
      final grip = tester.getCenter(
        find.byKey(const ValueKey('table-column-grip-0')),
      );
      await drag(tester, grip, Offset(cell(frame, 1, 2).dx, grip.dy));
      expect(
        desk.text,
        _with(
          '| Who | Cost | Item |\n'
          '| :---: | ---: | --- |\n'
          '| Ana | 412 | Tickets |\n'
          '| Sanjay | 896 | Hotel |\n'
          '| Ana | 38 | Taxi |',
        ),
      );
      await expectOneUndo(desk, _body);
    }, variant: _mac);

    testWidgets('a column border sets a width in dashes, and a double click '
        'resets it', (tester) async {
      final (desk, frame) = await open(tester);
      await hover(tester, cell(frame, 1, 0));
      final edge = Offset(frame.columnEdges[1], cell(frame, 2, 0).dy);
      await drag(tester, edge, edge.translate(80, 0));
      final sized = desk.text;
      final dashes = RegExp(r'\| (-+) \| :---:').firstMatch(sized)!.group(1)!;
      expect(dashes.length, greaterThan(3));
      expect(sized.replaceFirst('| $dashes |', '| --- |'), _body);
      await expectOneUndo(desk, _body);

      await drag(tester, edge, edge.translate(80, 0));
      await hover(tester, Offset(frameOf(desk).columnEdges[1], edge.dy));
      final strip = find.byKey(const ValueKey('table-resize-0'));
      await tester.tapAt(
        tester.getCenter(strip),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(
        tester.getCenter(strip),
        kind: PointerDeviceKind.mouse,
      );
      await desk.settle();
      expect(desk.text, _body);
    }, variant: _mac);
  });

  group('right-click on a cell', () {
    Future<void> rightClick(WidgetTester tester, Offset at) async {
      await tester.tapAt(
        at,
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
    }

    testWidgets('leads with Cut, Copy and Paste for the cell', (tester) async {
      final (desk, frame) = await open(tester, window: const Size(760, 520));
      final at = cell(frame, 2, 1);
      await hover(tester, at);
      await rightClick(tester, at);
      expect(find.byKey(const ValueKey('table-menu-cut')), findsOneWidget);
      expect(find.byKey(const ValueKey('table-menu-rowAbove')), findsOneWidget);
      expect(find.byKey(const ValueKey('table-menu-rowUp')), findsNothing);
      await choose(desk, TableCommand.copy);
      expect(desk.clipboard['text'], 'Sanjay');

      await rightClick(tester, at);
      await choose(desk, TableCommand.cut);
      expect(desk.clipboard['text'], 'Sanjay');
      expect(desk.text, _body.replaceFirst('| Sanjay |', '|  |'));
      await expectOneUndo(desk, _body);

      desk.clipboard = {'text': 'Mia | Leo'};
      await rightClick(tester, at);
      await choose(desk, TableCommand.paste);
      expect(desk.text, _body.replaceFirst('| Sanjay |', r'| Mia \| Leo |'));
    }, variant: _mac);

    testWidgets('fits the smallest window', (tester) async {
      final (_, frame) = await open(tester, window: const Size(760, 520));
      final at = cell(frame, 1, 1);
      await hover(tester, at);
      await rightClick(tester, at);
      final top = tester.getTopLeft(
        find.byKey(const ValueKey('table-menu-cut')),
      );
      final bottom = tester.getBottomLeft(
        find.byKey(const ValueKey('table-menu-deleteColumn')),
      );
      expect(top.dy, greaterThanOrEqualTo(0));
      expect(bottom.dy, lessThanOrEqualTo(520));
    }, variant: _mac);
  });

  group('shortcuts', () {
    final cellField = find.byKey(const ValueKey('table-cell-editor'));
    String editing(WidgetTester tester) =>
        tester.widget<TextField>(cellField).controller!.text;

    testWidgets('in a cell insert, move and delete rows and columns', (
      tester,
    ) async {
      final (desk, frame) = await open(tester);
      await desk.click(cell(frame, 2, 0));
      expect(editing(tester), 'Hotel');

      await chord(
        tester,
        LogicalKeyboardKey.arrowDown,
        primary: true,
        alt: true,
      );
      expect(desk.text, _body.replaceFirst('| Taxi', '|  |  |  |\n| Taxi'));
      expect(editing(tester), isEmpty);
      await expectOneUndo(desk, _body);

      await desk.click(cell(frameOf(desk), 2, 0));
      await chord(tester, LogicalKeyboardKey.arrowUp, alt: true, shift: true);
      expect(
        desk.text,
        _body.replaceFirst(
          '| Tickets | Ana | 412 |\n| Hotel | Sanjay | 896 |',
          '| Hotel | Sanjay | 896 |\n| Tickets | Ana | 412 |',
        ),
      );
      expect(editing(tester), 'Hotel');
      await expectOneUndo(desk, _body);

      await desk.click(cell(frameOf(desk), 2, 0));
      await chord(
        tester,
        LogicalKeyboardKey.backspace,
        primary: true,
        shift: true,
      );
      expect(desk.text, _body.replaceFirst('| Hotel | Sanjay | 896 |\n', ''));
      await expectOneUndo(desk, _body);

      await desk.click(cell(frameOf(desk), 2, 1));
      await chord(
        tester,
        LogicalKeyboardKey.arrowRight,
        primary: true,
        alt: true,
      );
      expect(desk.text, contains('| Item | Who |  | Cost |'));
      await expectOneUndo(desk, _body);

      await desk.click(cell(frameOf(desk), 2, 1));
      await chord(
        tester,
        LogicalKeyboardKey.backspace,
        primary: true,
        alt: true,
      );
      expect(desk.text, contains('| Item | Cost |\n| --- | ---: |'));
      await expectOneUndo(desk, _body);
    }, variant: desktopPlatforms);

    testWidgets('a picked column moves with Option and Shift', (tester) async {
      final (desk, _) = await open(tester);
      await pickColumn(desk, 0);
      await dismissMenu(tester);
      await chord(
        tester,
        LogicalKeyboardKey.arrowRight,
        alt: true,
        shift: true,
      );
      await chord(
        tester,
        LogicalKeyboardKey.arrowRight,
        alt: true,
        shift: true,
      );
      expect(
        desk.text,
        contains('| Who | Cost | Item |\n| :---: | ---: | --- |'),
      );
    }, variant: desktopPlatforms);
  });

  testWidgets('formatting, links, escaped pipes and wide characters move '
      'whole', (tester) async {
    const rich =
        '| a | b |\n'
        '| --- | --- |\n'
        '| **東京** | [link](https://x.example) |\n'
        r'| 🍵 \| tea |  |';
    final (desk, _) = await open(tester, body: _with(rich));
    await pickRow(desk, 2);
    await choose(desk, TableCommand.rowUp);
    expect(
      desk.text,
      _with(
        '| a | b |\n'
        '| --- | --- |\n'
        r'| 🍵 \| tea |  |'
        '\n| **東京** | [link](https://x.example) |',
      ),
    );
  }, variant: _mac);

  group('phone', () {
    testWidgets('a tap on a grip opens its actions as a sheet', (tester) async {
      final desk = await editCell(tester);
      await tester.tap(find.byKey(const ValueKey('table-row-grip-2')));
      await desk.settle();
      await tester.tap(find.byKey(const ValueKey('table-menu-deleteRow')));
      await desk.settle();
      expect(desk.text, _body.replaceFirst('| Hotel | Sanjay | 896 |\n', ''));
    }, variant: _phone);

    testWidgets('press and hold a grip, then drag it', (tester) async {
      final desk = await editCell(tester);
      final frame = frameOf(desk);
      final grip = tester.getCenter(
        find.byKey(const ValueKey('table-row-grip-2')),
      );
      final gesture = await tester.startGesture(grip);
      await tester.pump(const Duration(milliseconds: 600));
      for (var i = 1; i <= 6; i++) {
        await gesture.moveTo(
          Offset.lerp(grip, Offset(grip.dx, cell(frame, 3, 0).dy), i / 6)!,
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await desk.settle();
      expect(
        desk.text,
        _body.replaceFirst(
          '| Hotel | Sanjay | 896 |\n| Taxi | Ana | 38 |',
          '| Taxi | Ana | 38 |\n| Hotel | Sanjay | 896 |',
        ),
      );
    }, variant: _phone);

    testWidgets('grips are at least 44 points', (tester) async {
      await editCell(tester);
      for (final key in ['table-row-grip-2', 'table-column-grip-0']) {
        final size = tester.getSize(find.byKey(ValueKey(key)));
        expect(size.width, greaterThanOrEqualTo(44));
        expect(size.height, greaterThanOrEqualTo(44));
      }
    }, variant: _phone);
  });

  group('goldens', () {
    for (final dark in [false, true]) {
      final mode = dark ? 'dark' : 'light';

      Future<void> golden(String name) => expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/table_${name.replaceFirst('*', mode)}.png'),
      );

      testWidgets('desktop $mode', (tester) async {
        final (desk, frame) = await open(tester, dark: dark);
        final mouse = await hover(tester, cell(frame, 2, 1));
        await golden('desktop_*_hover');
        await mouse.moveTo(Offset(frame.grid.left + 2, frame.rowEdges[2] + 1));
        await tester.pumpAndSettle();
        await golden('desktop_*_insert_row');
        await mouse.moveTo(
          Offset(frame.columnEdges[2] + 1, frame.grid.top + 2),
        );
        await tester.pumpAndSettle();
        await golden('desktop_*_insert_column');
        await mouse.moveTo(
          Offset(frame.columnEdges[1] + 1, cell(frame, 2, 0).dy),
        );
        await tester.pumpAndSettle();
        await golden('desktop_*_resize');

        await pickRow(desk, 2);
        await golden('desktop_*_row_menu');
        await dismissMenu(tester);
        await golden('desktop_*_row_selected');
        await pickColumn(desk, 1);
        await golden('desktop_*_column_menu');
        await dismissMenu(tester);
        await desk.key(LogicalKeyboardKey.escape);
        await desk.settle();

        await hover(tester, cell(frame, 1, 0));
        final grip = tester.getCenter(
          find.byKey(const ValueKey('table-row-grip-1')),
        );
        final drag = await tester.startGesture(
          grip,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump(const Duration(milliseconds: 50));
        await drag.moveTo(grip.translate(0, 20));
        await tester.pump();
        await drag.moveTo(Offset(grip.dx, cell(frame, 3, 0).dy));
        await tester.pump();
        await golden('desktop_*_drag');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await drag.up();
        await tester.pumpAndSettle();
      }, variant: _mac);

      testWidgets('desktop $mode cell menu', (tester) async {
        final (_, frame) = await open(
          tester,
          dark: dark,
          window: const Size(760, 520),
        );
        final at = cell(frame, 1, 1);
        await hover(tester, at);
        await tester.tapAt(
          at,
          buttons: kSecondaryButton,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        await golden('desktop_*_cell_menu');
      }, variant: _mac);

      testWidgets('phone $mode', (tester) async {
        final desk = await editCell(tester, dark: dark);
        await golden('phone_*_editing');
        await tester.tap(find.byKey(const ValueKey('table-row-grip-2')));
        await desk.settle();
        await golden('phone_*_menu');
      }, variant: _phone);
    }
  });
}
