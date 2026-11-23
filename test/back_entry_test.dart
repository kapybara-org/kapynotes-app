import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/editor/link_popover.dart';
import 'package:kapy_notes/ui/editor/selection_bubble.dart';
import 'package:kapy_notes/ui/editor/slash_command_menu.dart';
import 'package:kapy_notes/ui/editor/slash_commands.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';

/// Back closes what's open over a page before it leaves the page (KAP-305).
void main() {
  setUpAll(loadTestFonts);

  final pageKey = GlobalKey();
  final page = find.byKey(const ValueKey('page'));

  Future<void> pumpPage(WidgetTester tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.light(),
        navigatorKey: navigator,
        home: const Scaffold(body: Text('list')),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          body: SizedBox.expand(
            key: const ValueKey('page'),
            child: Builder(key: pageKey, builder: (_) => const SizedBox()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(page, findsOneWidget);
  }

  Future<void> back(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  testWidgets("a link's popover closes first", (tester) async {
    await pumpPage(tester);
    LinkPopover.show(
      pageKey.currentContext!,
      anchor: const Rect.fromLTWH(40, 300, 120, 20),
      label: 'example.com',
      onOpen: () {},
      onCopy: () {},
    );
    await tester.pumpAndSettle();
    final popover = find.byKey(const ValueKey('link-popover'));
    expect(popover, findsOneWidget);

    await back(tester);
    expect(popover, findsNothing);
    expect(page, findsOneWidget);
    await back(tester);
    expect(page, findsNothing);
  });

  testWidgets('the selection bubble closes Text ▾ first, then itself', (
    tester,
  ) async {
    await pumpPage(tester);
    final bubble = SelectionBubbleController();
    addTearDown(bubble.dispose);
    bubble.show(
      pageKey.currentContext!,
      above: const Rect.fromLTWH(40, 300, 120, 20),
      below: const Rect.fromLTWH(40, 320, 120, 20),
      within: const Rect.fromLTWH(0, 0, 400, 800),
      block: 'Text',
      blocks: [
        SelectionBlock(
          label: 'Heading',
          icon: KapyIcons.penRounded,
          onSelected: () {},
        ),
      ],
      actions: const [],
      markdownEnabled: false,
      onLink: (_) {},
      onLinkClosed: () {},
    );
    bubble.toggleBlocks();
    await tester.pumpAndSettle();
    final shown = find.byKey(const ValueKey('selection-bubble'));
    expect(shown, findsOneWidget);
    expect(bubble.blocksOpen, isTrue);

    await back(tester);
    expect(bubble.blocksOpen, isFalse);
    expect(shown, findsOneWidget);
    await back(tester);
    expect(shown, findsNothing);
    expect(page, findsOneWidget);
    await back(tester);
    expect(page, findsNothing);
  });

  testWidgets('the slash menu closes first', (tester) async {
    await pumpPage(tester);
    final menu = SlashCommandMenuController();
    addTearDown(menu.dispose);
    var dismissed = false;
    menu.show(
      pageKey.currentContext!,
      anchor: const Rect.fromLTWH(40, 300, 2, 20),
      query: '',
      available: SlashCommandType.values.toSet(),
      markdownEnabled: false,
      onSelected: (_) {},
      onDismissed: (_) => dismissed = true,
    );
    await tester.pumpAndSettle();
    final shown = find.byKey(const ValueKey('slash-command-menu'));
    expect(shown, findsOneWidget);

    await back(tester);
    expect(shown, findsNothing);
    expect(dismissed, isTrue);
    expect(page, findsOneWidget);
    await back(tester);
    expect(page, findsNothing);
  });
}
