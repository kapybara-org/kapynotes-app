import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/ui/phone_home_cards.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  final now = DateTime(2026, 11, 19, 12);
  Note note(String id, String body) =>
      Note(id: id, body: body, createdAt: now, updatedAt: now);

  Future<({int pinned, int shared})> pumpCards(
    WidgetTester tester, {
    List<Note> pinned = const [],
    List<Note>? shared,
    int invitations = 0,
    double scale = 1,
    Size size = const Size(393, 852),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    var opened = (pinned: 0, shared: 0);
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(20),
            child: Align(
              alignment: Alignment.topCenter,
              child: PhoneHomeCards(
                pinned: pinned,
                onOpenPinned: () =>
                    opened = (pinned: opened.pinned + 1, shared: opened.shared),
                shared: shared,
                invitations: invitations,
                onOpenShared: () =>
                    opened = (pinned: opened.pinned, shared: opened.shared + 1),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final pinnedCard = find.byKey(const ValueKey('home-pinned-card'));
    await tester.tap(pinnedCard);
    final sharedCard = find.byKey(const ValueKey('home-shared-card'));
    if (sharedCard.evaluate().isNotEmpty) await tester.tap(sharedCard);
    return opened;
  }

  testWidgets('a card is the quiet 4% fill with no border', (tester) async {
    await pumpCards(tester, pinned: [note('a', 'Reading list')]);
    final pinned = find.byKey(const ValueKey('home-pinned-card'));
    final decoration =
        tester
                .widget<Container>(
                  find
                      .descendant(of: pinned, matching: find.byType(Container))
                      .first,
                )
                .decoration!
            as BoxDecoration;
    expect(decoration.color, KapyTheme.darkPalette.fillRest);
    expect(decoration.border, isNull);
  });

  testWidgets('Pinned and Shared are two equal cards that count their notes, '
      'name them, and open their lists', (tester) async {
    final opened = await pumpCards(
      tester,
      pinned: [note('a', 'Reading list'), note('b', 'Lisbon budget')],
      shared: [note('c', 'Call with Arjun')],
    );
    final pinned = find.byKey(const ValueKey('home-pinned-card'));
    final shared = find.byKey(const ValueKey('home-shared-card'));
    expect(tester.getSize(pinned), tester.getSize(shared));
    expect(
      find.descendant(
        of: pinned,
        matching: find.text('Reading list, Lisbon budget'),
      ),
      findsOneWidget,
    );
    expect(find.descendant(of: pinned, matching: find.text('2')), findsOne);
    expect(find.descendant(of: shared, matching: find.text('1')), findsOne);
    expect(find.byKey(const ValueKey('home-shared-invitations')), findsNothing);
    expect(opened, (pinned: 1, shared: 1));
  });

  testWidgets('a screen reader hears how many invitations wait under Shared', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpCards(tester, shared: const [], invitations: 2);
    expect(find.byKey(const ValueKey('home-shared-invitations')), findsOne);
    expect(
      find.bySemanticsLabel('Shared, 0 notes, 2 invitations waiting'),
      findsOneWidget,
    );
    await pumpCards(tester, shared: const [], invitations: 1);
    expect(
      find.bySemanticsLabel('Shared, 0 notes, 1 invitation waiting'),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('home-shared-card')),
        matching: find.text('Nothing shared yet'),
      ),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('without an account there is only Pinned', (tester) async {
    await pumpCards(tester);
    expect(find.byKey(const ValueKey('home-shared-card')), findsNothing);
    expect(find.text('Nothing pinned yet'), findsOneWidget);
  });

  for (final (scale, size) in [
    (2.0, const Size(412, 915)),
    (3.1, const Size(375, 667)),
  ]) {
    testWidgets('the cards grow with $scale× text and cut nothing', (
      tester,
    ) async {
      await pumpCards(
        tester,
        pinned: [note('a', 'Reading list'), note('b', 'Lisbon budget')],
        shared: [note('c', 'Call with Arjun')],
        invitations: 2,
        scale: scale,
        size: size,
      );
      expect(tester.takeException(), isNull);
      for (final key in ['home-pinned-card', 'home-shared-card']) {
        final card = tester.getRect(find.byKey(ValueKey(key)));
        final lines = tester.getRect(
          find.descendant(
            of: find.byKey(ValueKey(key)),
            matching: find.byWidgetPredicate(
              (widget) => widget is Text && widget.maxLines == 2,
            ),
          ),
        );
        expect(lines.bottom, lessThanOrEqualTo(card.bottom - 14 + 0.5));
      }
    });
  }
}
