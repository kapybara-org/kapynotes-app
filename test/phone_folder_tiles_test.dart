import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/ui/phone_folder_tiles.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  final now = DateTime(2026, 11, 19, 12);
  Note note(String id, String body) =>
      Note(id: id, body: body, createdAt: now, updatedAt: now);

  final drawingsTile = find.byKey(const ValueKey('folders-drawings-tile'));
  final sharedTile = find.byKey(const ValueKey('folders-shared-tile'));
  final badge = find.byKey(const ValueKey('folders-shared-invitations'));

  Future<({int drawings, int shared})> pumpTiles(
    WidgetTester tester, {
    List<Note> drawings = const [],
    String? newest,
    List<Note>? shared,
    String? latest,
    int invitations = 0,
    double scale = 1,
    Size size = const Size(393, 852),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    var opened = (drawings: 0, shared: 0);
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(20),
            child: Align(
              alignment: Alignment.topCenter,
              child: PhoneFolderTiles(
                drawings: drawings,
                newest: newest,
                onOpenDrawings: () => opened = (
                  drawings: opened.drawings + 1,
                  shared: opened.shared,
                ),
                shared: shared,
                latest: latest,
                invitations: invitations,
                onOpenShared: () => opened = (
                  drawings: opened.drawings,
                  shared: opened.shared + 1,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(drawingsTile);
    if (sharedTile.evaluate().isNotEmpty) await tester.tap(sharedTile);
    return opened;
  }

  testWidgets('a tile is the quiet 4% fill with no border', (tester) async {
    await pumpTiles(tester, shared: const []);
    for (final tile in [drawingsTile, sharedTile]) {
      final decoration =
          tester
                  .widget<Container>(
                    find
                        .descendant(of: tile, matching: find.byType(Container))
                        .first,
                  )
                  .decoration!
              as BoxDecoration;
      expect(decoration.color, KapyTheme.darkPalette.cardBackground);
      expect(
        decoration.borderRadius,
        BorderRadius.circular(AppRadii.card),
      );
      expect(decoration.border, isNull);
    }
  });

  testWidgets('Shared sits beside Drawings in the same tile: the people '
      'icon, the count of shared notes, the latest with its day, and a tap '
      'opens it', (tester) async {
    final opened = await pumpTiles(
      tester,
      drawings: [note('d', 'Deck flow')],
      newest: 'Deck flow · Today',
      shared: [
        note('a', 'Book club picks'),
        note('b', 'Trip budget'),
        note('c', 'Packing list'),
      ],
      latest: 'Book club picks · Today',
    );
    expect(tester.getRect(sharedTile).top, tester.getRect(drawingsTile).top);
    expect(
      tester.getRect(sharedTile).left - tester.getRect(drawingsTile).right,
      8,
    );
    expect(tester.getSize(sharedTile), tester.getSize(drawingsTile));
    for (final text in ['Shared', '3', 'Book club picks · Today']) {
      expect(
        find.descendant(of: sharedTile, matching: find.text(text)),
        findsOneWidget,
        reason: text,
      );
    }
    expect(
      find.descendant(
        of: sharedTile,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is KapyIcon && widget.icon == KapyIcons.groupOutlined,
        ),
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Text>(
            find.descendant(
              of: sharedTile,
              matching: find.text('Book club picks · Today'),
            ),
          )
          .style
          ?.color,
      tester
          .widget<Text>(
            find.descendant(
              of: drawingsTile,
              matching: find.text('Deck flow · Today'),
            ),
          )
          .style
          ?.color,
      reason: "Shared's line is set as Drawings' is",
    );
    expect(badge, findsNothing);
    expect(opened, (drawings: 1, shared: 1));
  });

  testWidgets("the red badge on Shared's icon counts the invitations "
      'waiting, and a screen reader hears them', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpTiles(tester, shared: const [], invitations: 2);
    expect(badge, findsOneWidget);
    expect(
      (tester.widget<Container>(badge).decoration! as BoxDecoration).color,
      Theme.of(tester.element(badge)).colorScheme.errorContainer,
    );
    expect(find.descendant(of: badge, matching: find.text('2')), findsOne);
    expect(
      find.bySemanticsLabel('Shared, 0 notes, 2 invitations waiting'),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: sharedTile,
        matching: find.text('Nothing shared yet'),
      ),
      findsOneWidget,
    );

    await pumpTiles(tester, shared: const [], invitations: 1);
    expect(
      find.bySemanticsLabel('Shared, 0 notes, 1 invitation waiting'),
      findsOneWidget,
    );
    await pumpTiles(tester, shared: const [], invitations: 120);
    expect(find.descendant(of: badge, matching: find.text('99+')), findsOne);
    semantics.dispose();
  });

  testWidgets('with no account to share from, Shared leaves its half empty', (
    tester,
  ) async {
    final opened = await pumpTiles(tester);
    expect(sharedTile, findsNothing);
    expect(tester.getRect(drawingsTile).width, (393 - 40 - 8) / 2);
    expect(find.text('No drawings yet'), findsOneWidget);
    expect(opened, (drawings: 1, shared: 0));
  });

  for (final (scale, size) in [
    (2.0, const Size(412, 915)),
    (3.1, const Size(375, 667)),
  ]) {
    testWidgets('the tiles grow with $scale× text and cut nothing', (
      tester,
    ) async {
      await pumpTiles(
        tester,
        drawings: [note('d', 'Deck flow')],
        newest: 'Deck flow · Today',
        shared: [note('a', 'Book club picks')],
        latest: 'Book club picks · Today',
        invitations: 2,
        scale: scale,
        size: size,
      );
      expect(tester.takeException(), isNull);
      for (final tile in [drawingsTile, sharedTile]) {
        final rect = tester.getRect(tile);
        for (final text in tester.widgetList<Text>(
          find.descendant(of: tile, matching: find.byType(Text)),
        )) {
          expect(
            tester.getRect(find.byWidget(text)).bottom,
            lessThanOrEqualTo(rect.bottom - 14 + 0.5),
            reason: text.data,
          );
        }
      }
    });
  }
}
