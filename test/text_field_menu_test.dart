import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/editor/editor_context_menu.dart';
import 'package:material_ui/material_ui.dart';

/// The fields that are left out: the editor's own text and a table cell, which
/// build their own menus, and Quick Capture's, which has no menu at all and
/// sits in a window with no Overlay to hold one.
const _ownMenus = {
  'lib/ui/editor/note_field.dart',
  'lib/ui/editor/table_cell_editor.dart',
  'lib/ui/instant_capture.dart',
};

final _field = RegExp(
  r'(?<![A-Za-z_.])(TextField|SelectableText|EditableText)\(',
);

/// Every field constructor in [sources] (path to Dart source) whose arguments
/// leave out a contextMenuBuilder, as "path:line: Name".
List<String> fieldsWithStockMenu(Map<String, String> sources) {
  final found = <String>[];
  for (final MapEntry(key: path, value: source) in sources.entries) {
    if (_ownMenus.contains(path)) continue;
    for (final match in _field.allMatches(source)) {
      var depth = 1;
      var end = match.end;
      String? quote;
      while (end < source.length && depth > 0) {
        final char = source[end];
        if (quote != null) {
          if (char == r'\') end++;
          if (char == quote) quote = null;
        } else if (char == "'" || char == '"') {
          quote = char;
        } else if (char == '(') {
          depth++;
        } else if (char == ')') {
          depth--;
        }
        end++;
      }
      if (source.substring(match.end, end).contains('contextMenuBuilder:')) {
        continue;
      }
      final line = '\n'.allMatches(source.substring(0, match.start)).length + 1;
      final name = match.group(1);
      found.add('$path:$line: $name');
    }
  }
  return found;
}

void main() {
  test('every text field and selectable text takes the Kapy menu', () {
    final sources = {
      for (final file in Directory('lib').listSync(recursive: true))
        if (file is File && file.path.endsWith('.dart'))
          file.path: file.readAsStringSync(),
    };
    expect(
      fieldsWithStockMenu(sources),
      isEmpty,
      reason:
          'Give each one contextMenuBuilder: kapyTextFieldMenu, or the '
          "stock menu slides over the pointer near the window's edge.",
    );
  });

  test('the scan finds a field that keeps the stock menu', () {
    expect(
      fieldsWithStockMenu({
        'a.dart': "Widget a() => TextField(hintText: 'x)');",
        'b.dart':
            'Widget b() => TextField(\n'
            '  contextMenuBuilder: kapyTextFieldMenu,\n'
            ');',
        'c.dart': 'Widget c() => SelectableText(\n  text,\n);',
      }),
      ['a.dart:1: TextField', 'c.dart:1: SelectableText'],
    );
  });

  Future<Rect> openMenuAtCorner(WidgetTester tester, Widget field) async {
    tester.view.physicalSize = const Size(400, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomRight,
            child: SizedBox(width: 120, child: field),
          ),
        ),
      ),
    );
    final at = tester.getCenter(find.byType(field.runtimeType));
    final pointer = await tester.startGesture(
      at,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await pointer.up();
    await tester.pumpAndSettle();
    final menu = tester.getRect(
      find.byKey(const ValueKey('editor-context-menu')),
    );
    expect(
      menu.topLeft >= Offset.zero && menu.bottomRight <= const Offset(400, 300),
      isTrue,
      reason: '$menu runs out of the window',
    );
    expect(
      [
        menu.topLeft,
        menu.topRight,
        menu.bottomLeft,
        menu.bottomRight,
      ].any((corner) => (corner - at).distance < 0.01),
      isTrue,
      reason: '$menu has no corner at $at',
    );
    final underPointer = {
      for (final entry in tester.hitTestOnBinding(at).path) entry.target,
    };
    expect(
      find
          .byType(InkWell)
          .evaluate()
          .where((item) => underPointer.contains(item.renderObject)),
      isEmpty,
      reason: 'the pointer rests on a menu item',
    );
    return menu;
  }

  testWidgets(
    'a text field near the window corner opens the Kapy menu whole, with a '
    'corner at the pointer',
    (tester) async {
      await openMenuAtCorner(
        tester,
        TextField(
          controller: TextEditingController(text: 'hello world'),
          contextMenuBuilder: kapyTextFieldMenu,
        ),
      );
      expect(
        find.byKey(const ValueKey('editor-context-action-Select all')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'selectable text opens the Kapy menu with Select all and no Cut',
    (tester) async {
      await openMenuAtCorner(
        tester,
        const SelectableText(
          'hello world',
          contextMenuBuilder: kapyTextFieldMenu,
        ),
      );
      expect(
        find.byKey(const ValueKey('editor-context-action-Select all')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('editor-context-action-Cut')),
        findsNothing,
      );
    },
  );
}
