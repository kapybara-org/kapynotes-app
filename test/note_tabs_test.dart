import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/note_tabs.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);
  tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

  List<NoteTab> tabsOf(List<String> titles) => [
    for (final (index, title) in titles.indexed)
      NoteTab(id: 't$index', title: title, icon: KapyIcons.noteOutlined),
  ];

  Future<void> pumpRow(
    WidgetTester tester,
    List<NoteTab> tabs, {
    double width = 1000,
    String? activeId = 't0',
    VoidCallback? onNew,
    Brightness brightness = Brightness.dark,
  }) async {
    tester.view.physicalSize = Size(width, 200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: brightness == Brightness.dark
            ? KapyTheme.dark()
            : KapyTheme.light(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: NoteTabRow(
                tabs: tabs,
                activeId: activeId,
                recentIds: [for (final tab in tabs) tab.id],
                onSelect: (_) {},
                onClose: (_) {},
                onCloseOthers: (_) {},
                onNew: onNew ?? () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder tab(String id) => find.byKey(ValueKey('note-tab-$id'));
  final plus = find.byKey(const ValueKey('note-tabs-new'));

  testWidgets('each tab\'s icon, title and × sit on the row\'s middle line, '
      'the active underline lies on its bottom edge, and the first icon '
      'starts 18 in, where the header\'s month starts (KAP-433)', (
    tester,
  ) async {
    await pumpRow(tester, tabsOf(['SnowAnalytics', 'Launch checklist', 'Q4']));
    final row = tester.getRect(find.byType(NoteTabRow));
    expect(row.height, NoteTabRow.height);

    for (final id in ['t0', 't1', 't2']) {
      final icon = find.descendant(
        of: tab(id),
        matching: find.byType(KapyIcon),
      );
      final title = find.descendant(of: tab(id), matching: find.byType(Text));
      for (final part in [
        icon.first,
        title,
        find.byKey(ValueKey('close-tab-$id')),
      ]) {
        expect(tester.getCenter(part).dy, row.center.dy, reason: '$id $part');
      }
    }
    expect(
      tester
          .getTopLeft(
            find
                .descendant(of: tab('t0'), matching: find.byType(KapyIcon))
                .first,
          )
          .dx,
      row.left + 18,
    );

    final underline = find.descendant(
      of: tab('t0'),
      matching: find.byType(Positioned),
    );
    expect(underline, findsOneWidget);
    expect(tester.getRect(underline).bottom, row.bottom);
    expect(tester.getRect(underline).height, 2);
    for (final id in ['t1', 't2']) {
      expect(
        find.descendant(of: tab(id), matching: find.byType(Positioned)),
        findsNothing,
      );
    }
  });

  testWidgets('tabs are 16 apart, each × is a target of 24 or more, and a '
      'long title stops at the widest a title gets, with all of it on '
      'hover (KAP-433)', (tester) async {
    const long =
        'A very long note title that goes on well past where any tab stops';
    await pumpRow(tester, tabsOf(['Short', long, 'Another note']));

    for (final (left, right) in [('t0', 't1'), ('t1', 't2')]) {
      expect(
        tester.getTopLeft(tab(right)).dx - tester.getTopRight(tab(left)).dx,
        16,
      );
    }
    for (final id in ['t0', 't1', 't2']) {
      final close = tester.getSize(find.byKey(ValueKey('close-tab-$id')));
      expect(close.width, greaterThanOrEqualTo(24));
      expect(close.height, greaterThanOrEqualTo(24));
    }
    final cut = find.descendant(of: tab('t1'), matching: find.text(long));
    expect(tester.getSize(cut).width, NoteTabRow.maxLabelWidth);
    expect(tester.widget<Text>(cut).overflow, TextOverflow.ellipsis);
    expect(find.byTooltip(long), findsOneWidget);
  });

  for (final count in [1, 3, 14]) {
    testWidgets('with $count ${count == 1 ? 'tab' : 'tabs'}, + comes 8 '
        'after the last tab or "N more", on the middle line, a 24 target, '
        'and always in the row (KAP-433)', (tester) async {
      await pumpRow(
        tester,
        tabsOf([for (var i = 0; i < count; i++) 'Note number $i']),
        width: 720,
      );
      final row = tester.getRect(find.byType(NoteTabRow));
      final more = find.byKey(const ValueKey('note-tabs-more'));
      expect(more, count == 14 ? findsOneWidget : findsNothing);
      final shown = [
        for (var i = 0; i < count; i++)
          if (tab('t$i').evaluate().isNotEmpty) tab('t$i'),
      ];
      final last = count == 14 ? more : shown.last;

      expect(plus, findsOneWidget);
      final at = tester.getRect(plus);
      expect(at.size, const Size(24, 24));
      expect(at.left - tester.getTopRight(last).dx, 8);
      expect(at.center.dy, row.center.dy);
      expect(at.right, lessThanOrEqualTo(row.right - 16));
    });
  }

  testWidgets('+ is a button a screen reader names and taps, not a tab, with '
      'a plain tooltip, and a click or Enter makes a new tab (KAP-433)', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var made = 0;
    await pumpRow(tester, tabsOf(['First', 'Second']), onNew: () => made++);

    final node = tester.getSemantics(plus);
    expect(
      node,
      isSemantics(
        label: 'New note in a new tab',
        isButton: true,
        hasTapAction: true,
        isSelected: false,
      ),
    );
    expect(find.byTooltip('New note in a new tab'), findsOneWidget);

    await tester.tap(plus);
    expect(made, 1);
    tester.semantics.tap(
      find.semantics.byPredicate((candidate) => candidate.id == node.id),
    );
    expect(made, 2);
    Focus.of(tester.element(plus)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(made, 3);
    semantics.dispose();
  });

  testWidgets('without onNew there is no +', (tester) async {
    tester.view.physicalSize = const Size(600, 200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final tabs = tabsOf(['First', 'Second']);
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Scaffold(
          body: NoteTabRow(
            tabs: tabs,
            activeId: 't0',
            recentIds: const ['t0', 't1'],
            onSelect: (_) {},
            onClose: (_) {},
            onCloseOthers: (_) {},
          ),
        ),
      ),
    );
    expect(plus, findsNothing);
  });

  for (final brightness in [Brightness.dark, Brightness.light]) {
    testWidgets('tab row, ${brightness.name}', (tester) async {
      await pumpRow(
        tester,
        [
          ...tabsOf([
            'SnowAnalytics',
            'Launch checklist',
            'A very long note title that goes on well past where a tab stops',
          ]),
          const NoteTab(
            id: 'pinned',
            title: 'Groceries',
            icon: KapyIcons.noteOutlined,
            pinned: true,
          ),
        ],
        width: 900,
        brightness: brightness,
      );
      await expectLater(
        find.byType(NoteTabRow),
        matchesGoldenFile('goldens/note_tab_row_${brightness.name}.png'),
      );
    });
  }

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
