import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/task_board.dart';
import 'package:kapy_notes/ui/editor_panes.dart';
import 'package:kapy_notes/ui/notes_list.dart';
import 'package:kapy_notes/ui/sidebar.dart';
import 'package:kapy_notes/ui/tasks/task_marks.dart';
import 'package:kapy_notes/ui/tasks/tasks_sidebar.dart';
import 'package:material_ui/material_ui.dart';

import 'kapy_icon_finder.dart';

void main() {
  setUp(() => AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS);
  tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Scaffold(body: child),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('All tasks wears the Tasks glyph, under a 14 px search glyph', (
    tester,
  ) async {
    await pump(
      tester,
      TasksSidebar(
        board: TaskBoard.read(
          entries: const [],
          notes: const [],
          docOf: (_) => null,
        ),
        today: const [],
        filter: const TaskFilter.all(),
        onFilter: (_) {},
        labelOf: (note) => note.title,
        windowBar: const SizedBox.shrink(),
        onSearch: () {},
      ),
    );

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('tasks-filter-all')),
        matching: findKapyIcon(KapyIcons.tasksOutlined),
      ),
      findsOneWidget,
    );
    expect(findKapyIcon(KapyIcons.checklistRounded), findsNothing);
    expect(
      tester.getSize(
        find.descendant(
          of: find.byType(SidebarSearchField),
          matching: findKapyIcon(KapyIcons.searchRounded),
        ),
      ),
      const Size.square(14),
    );
  });

  testWidgets('Show notes wears the sidebar toggle glyph', (tester) async {
    await pump(
      tester,
      EmptyPane(active: true, onCreate: () {}, onShowNotes: () {}),
    );

    expect(
      find.descendant(
        of: find.widgetWithText(TextButton, 'Show notes'),
        matching: findKapyIcon(KapyIcons.menuOpenRounded),
      ),
      findsOneWidget,
    );
  });

  testWidgets("View all's chevron is a 12 px path chevron, and 14 on a "
      'phone', (tester) async {
    await pump(tester, Center(child: ViewAllLink(count: 3, onPressed: () {})));
    expect(
      tester.getSize(findKapyIcon(KapyIcons.chevronRightRounded)),
      const Size.square(12),
    );

    await pump(
      tester,
      Center(child: ViewAllLink(phone: true, count: 3, onPressed: () {})),
    );
    expect(
      tester.getSize(findKapyIcon(KapyIcons.chevronRightRounded)),
      const Size.square(14),
    );
  });

  testWidgets('View all carries the count in a circle, 16 on a desktop and '
      '18 on a phone, which two digits widen into a pill', (tester) async {
    final badge = find.descendant(
      of: find.byType(ViewAllLink),
      matching: find.byType(CountBadge),
    );
    await pump(tester, Center(child: ViewAllLink(count: 3, onPressed: () {})));
    expect(
      find.descendant(of: badge, matching: find.text('3')),
      findsOneWidget,
    );
    expect(tester.getSize(badge).height, 16);
    final one = tester.getSize(badge).width;

    await pump(tester, Center(child: ViewAllLink(count: 12, onPressed: () {})));
    expect(tester.getSize(badge).height, 16);
    expect(tester.getSize(badge).width, greaterThan(one));

    await pump(
      tester,
      Center(child: ViewAllLink(phone: true, count: 7, onPressed: () {})),
    );
    expect(tester.getSize(badge).height, 18);
  });
}
