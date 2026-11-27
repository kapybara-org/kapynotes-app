import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/note_tabs.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);
  tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

  testWidgets(
    'a screen reader opens the folded tabs from "N more" as a click does, '
    'and the tab picked there opens (KAP-365)',
    (tester) async {
      AppPlatform.debugTargetPlatformOverride = defaultTargetPlatform;
      final semantics = tester.ensureSemantics();
      tester.view.physicalSize = const Size(480, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final tabs = [
        for (var i = 1; i <= 8; i++)
          NoteTab(
            id: 'n$i',
            title: 'Note number $i',
            icon: KapyIcons.noteOutlined,
          ),
      ];
      final picked = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: KapyTheme.dark(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: NoteTabRow(
                tabs: tabs,
                activeId: 'n1',
                recentIds: [for (final tab in tabs) tab.id],
                onSelect: picked.add,
                onClose: (_) {},
                onCloseOthers: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final more = tester.getSemantics(
        find.byKey(const ValueKey('note-tabs-more')),
      );
      expect(more, isSemantics(isButton: true, hasTapAction: true));
      final count = RegExp(r'^(\d+) more tabs?$').firstMatch(more.label);
      expect(count, isNotNull, reason: more.label);
      tester.semantics.tap(
        find.semantics.byPredicate((node) => node.id == more.id),
      );
      await tester.pumpAndSettle();
      final folded = [
        for (final tab in tabs)
          if (find.byKey(ValueKey('more-tab-${tab.id}')).evaluate().isNotEmpty)
            tab.id,
      ];
      expect(folded, hasLength(int.parse(count!.group(1)!)));
      expect(folded, isNot(contains('n1')));

      await tester.tap(find.byKey(ValueKey('more-tab-${folded.last}')));
      await tester.pumpAndSettle();
      expect(picked, [folded.last]);
      semantics.dispose();
    },
    variant: TargetPlatformVariant(const {
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
      TargetPlatform.iOS,
      TargetPlatform.android,
    }),
  );
}
