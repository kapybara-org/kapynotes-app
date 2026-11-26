import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/context_menu.dart';
import 'package:kapy_notes/ui/editor/editor_context_menu.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  const window = Size(800, 600);
  const menu = Size(200, 300);

  /// Where a menu of [size] opened at [at] sits in an 800 by 600 window, as
  /// tall as the layout lets it be. [list] is a note row's notes list.
  Rect place(Offset at, {Size size = menu, Rect? list}) {
    final layout = KapyMenuLayout(
      position: at,
      mediaPadding: EdgeInsets.zero,
      preferredBounds: list,
    );
    final laid = layout
        .getConstraintsForChild(BoxConstraints.tight(window))
        .constrain(size);
    return layout.getPositionForChild(window, laid) & laid;
  }

  test('a menu that fits opens down and right from the pointer', () {
    expect(
      place(const Offset(100, 100)),
      const Rect.fromLTWH(100, 100, 200, 300),
    );
  });

  test('near the bottom it opens up, and near the right edge left, keeping '
      'a corner at the pointer', () {
    expect(place(const Offset(100, 500)).bottomLeft, const Offset(100, 500));
    expect(place(const Offset(700, 100)).topRight, const Offset(700, 100));
    expect(place(const Offset(700, 500)).bottomRight, const Offset(700, 500));
  });

  test('too tall for either side, it opens on the side with more room, as '
      'tall as that room, and scrolls the rest', () {
    const tall = Size(200, 700);
    expect(
      place(const Offset(100, 250), size: tall),
      const Rect.fromLTRB(100, 250, 300, 592),
    );
    expect(
      place(const Offset(100, 350), size: tall),
      const Rect.fromLTRB(100, 8, 300, 350),
    );
  });

  test('too wide for either side, it narrows to the side with more room '
      'and keeps a corner at the pointer', () {
    expect(
      place(const Offset(400, 200), size: const Size(500, 100)),
      const Rect.fromLTWH(400, 200, 392, 100),
    );
  });

  test("a note row's menu hangs left from the click while the list holds "
      'it, and otherwise opens right from it', () {
    const list = Rect.fromLTRB(240, 0, 560, 600);
    expect(
      place(const Offset(500, 100), list: list).topRight,
      const Offset(500, 100),
    );
    expect(
      place(const Offset(300, 100), list: list).topLeft,
      const Offset(300, 100),
    );
  });

  testWidgets(
    'the editor menu near the bottom-right keeps a corner at its anchor, '
    'so the pointer rests on no item',
    (tester) async {
      const anchor = Offset(760, 560);
      await tester.pumpWidget(
        MaterialApp(
          theme: KapyTheme.dark(),
          home: const Scaffold(
            body: NoteEditorContextMenu(
              anchors: TextSelectionToolbarAnchors(primaryAnchor: anchor),
              buttonItems: [
                ContextMenuButtonItem(
                  type: ContextMenuButtonType.cut,
                  onPressed: _noop,
                ),
                ContextMenuButtonItem(
                  type: ContextMenuButtonType.copy,
                  onPressed: _noop,
                ),
                ContextMenuButtonItem(
                  type: ContextMenuButtonType.paste,
                  onPressed: _noop,
                ),
                ContextMenuButtonItem(
                  type: ContextMenuButtonType.selectAll,
                  onPressed: _noop,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final menu = tester.getRect(
        find.byKey(const ValueKey('editor-context-menu')),
      );
      expect(
        [
          menu.topLeft,
          menu.topRight,
          menu.bottomLeft,
          menu.bottomRight,
        ].any((corner) => (corner - anchor).distance < 0.01),
        isTrue,
        reason: '$menu has no corner at $anchor',
      );
      final underPointer = {
        for (final entry in tester.hitTestOnBinding(anchor).path) entry.target,
      };
      expect(
        find
            .byType(InkWell)
            .evaluate()
            .where((item) => underPointer.contains(item.renderObject)),
        isEmpty,
      );
    },
  );
}

void _noop() {}
