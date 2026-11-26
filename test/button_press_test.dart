import 'dart:ui' show Tristate;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'golden_test.dart'
    show goldenNotes, goldenPrefs, pumpForGolden, tapSettings;
import 'test_fonts.dart';

/// VoiceOver, Voice Control and AXPress press a control through its
/// semantics tap action, never a pointer, so these press nothing else.
void main() {
  setUpAll(loadTestFonts);

  Future<void> pumpWindow(
    WidgetTester tester, {
    bool sidebarVisible = true,
  }) async {
    await pumpForGolden(
      tester,
      size: const Size(1440, 900),
      brightness: Brightness.dark,
      sidebarVisible: sidebarVisible,
    );
  }

  Future<void> press(
    WidgetTester tester,
    FinderBase<SemanticsNode> control,
  ) async {
    tester.semantics.tap(control);
    await tester.pumpAndSettle();
  }

  SemanticsFinder labelled(String label) =>
      find.semantics.byLabel(RegExp('^${RegExp.escape(label)}\$'));

  SemanticsFinder tipped(String tooltip) => find.semantics.byPredicate(
    (node) =>
        node.getSemanticsData().flagsCollection.isButton &&
        node.label.startsWith(tooltip),
  );

  String? spaceTitle(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const ValueKey('sidebar-space-title')))
      .data;

  /// The buttons the platform is sent: a node merged into its parent is part
  /// of that parent's button, and only the parent reaches VoiceOver.
  Iterable<SemanticsData> buttons() => find.semantics
      .byPredicate(
        (node) =>
            !node.isMergedIntoParent &&
            node.getSemanticsData().flagsCollection.isButton,
      )
      .evaluate()
      .map((node) => node.getSemanticsData());

  /// Every button on screen that is switched on and has nothing to press,
  /// other than the chosen option of a switch, which pressing would not
  /// change.
  List<String> unpressable() => [
    for (final data in buttons())
      if (data.flagsCollection.isEnabled != Tristate.isFalse &&
          data.flagsCollection.isSelected != Tristate.isTrue &&
          !data.hasAction(SemanticsAction.tap))
        '"${data.label}" ${data.tooltip}'.trim(),
  ];

  /// Every button on screen with no name. macOS reads a button's name from
  /// its label alone, so a button named only by its tooltip is read there as
  /// "button" and nothing else.
  List<String> unnamed() => [
    for (final node
        in find.semantics
            .byPredicate(
              (node) =>
                  !node.isMergedIntoParent &&
                  node.getSemanticsData().hasAction(SemanticsAction.tap),
            )
            .evaluate())
      if (node.getSemanticsData() case final data
          when data.label.trim().isEmpty && !data.flagsCollection.isTextField)
        'tooltip "${data.tooltip}" value "${data.value}"',
  ];

  /// A test with the semantics tree on, as it is while VoiceOver runs.
  void testPress(String description, WidgetTesterCallback body) =>
      testWidgets(description, (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          await body(tester);
        } finally {
          semantics.dispose();
        }
      });

  testPress('every button in the window can be pressed', (tester) async {
    await pumpWindow(tester);
    for (final id in [for (var i = 0; i < 5; i++) goldenNotes.create().id]) {
      goldenNotes.updateBody(id, 'Pinned');
      goldenNotes.togglePinned(id);
    }
    await tester.pumpAndSettle();
    expect(unpressable(), isEmpty, reason: 'with the list open');
    expect(unnamed(), isEmpty, reason: 'with the list open');

    await tester.tap(find.byKey(const ValueKey('page-more')));
    await tester.pumpAndSettle();
    expect(unpressable(), isEmpty, reason: 'with More open');
    expect(unnamed(), isEmpty, reason: 'with More open');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('notes-view')));
    await tester.pumpAndSettle();
    expect(unpressable(), isEmpty, reason: 'with the notes filter open');
    expect(unnamed(), isEmpty, reason: 'with the notes filter open');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('rail-drawings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sidebar-new-note')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('draw-style')));
    await tester.pumpAndSettle();
    expect(unpressable(), isEmpty, reason: 'on a drawing');
    expect(unnamed(), isEmpty, reason: 'on a drawing');

    await tester.tap(find.byKey(const ValueKey('rail-drawings')));
    await tester.pumpAndSettle();
    expect(unpressable(), isEmpty, reason: 'in drawings');
    expect(unnamed(), isEmpty, reason: 'in drawings');

    await tester.tap(find.byKey(const ValueKey('notes-view')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notes-filter-archive')));
    await tester.pumpAndSettle();
    expect(unpressable(), isEmpty, reason: 'in the archive');
    expect(unnamed(), isEmpty, reason: 'in the archive');

    await tapSettings(tester);
    expect(unpressable(), isEmpty, reason: 'with Settings open');
    expect(unnamed(), isEmpty, reason: 'with Settings open');
  });

  testPress('every button can be pressed with the list hidden', (tester) async {
    await pumpWindow(tester, sidebarVisible: false);
    expect(unpressable(), isEmpty);
    expect(unnamed(), isEmpty);
  });

  testPress('a rail item opens its space when pressed', (tester) async {
    await pumpWindow(tester);
    await press(tester, labelled('Drawings'));
    expect(spaceTitle(tester), 'Drawings');
    await press(tester, labelled('Notes'));
    expect(spaceTitle(tester), 'My notes');
  });

  testPress("the list's + makes a note when pressed", (tester) async {
    await pumpWindow(tester);
    final before = goldenNotes.notes.length;
    await press(tester, labelled('New note'));
    expect(goldenNotes.notes, hasLength(before + 1));
  });

  testPress('a keycap is read with its button, never on its own', (
    tester,
  ) async {
    await pumpWindow(tester);
    expect(labelled('New note'), findsOne);
    expect(find.semantics.byLabel(RegExp('⌘')), findsNothing);
  });

  testPress('an icon button is pressed by its name', (tester) async {
    await pumpWindow(tester);

    await press(tester, tipped('Hide notes'));
    expect(goldenPrefs.sidebarVisible, isFalse);
    await press(tester, tipped('Show notes'));
    expect(goldenPrefs.sidebarVisible, isTrue);
  });

  testPress('the list controls are pressed by their names', (tester) async {
    await pumpWindow(tester);

    await press(tester, labelled('View'));
    expect(find.byKey(const ValueKey('notes-filter-menu')), findsOneWidget);
    await press(tester, labelled('Grid'));
    expect(goldenPrefs.noteCards, isTrue);
    await press(tester, labelled('View'));
    await press(tester, labelled('List'));
    expect(goldenPrefs.noteCards, isFalse);
  });

  testPress('a kind of media in the notes filter is unticked and ticked '
      'again when pressed, and All media ticks every kind (KAP-365)', (
    tester,
  ) async {
    await pumpWindow(tester);
    await press(tester, labelled('View'));
    SemanticsNode row(String kind) =>
        tester.getSemantics(find.byKey(ValueKey('media-filter-$kind')));
    Future<void> tick(String kind) {
      final id = row(kind).id;
      return press(tester, find.semantics.byPredicate((node) => node.id == id));
    }

    expect(
      row('video'),
      isSemantics(
        label: 'Video',
        hasCheckedState: true,
        isChecked: true,
        hasTapAction: true,
      ),
    );
    await tick('video');
    expect(row('video'), isSemantics(isChecked: false, hasTapAction: true));
    expect(
      row('all'),
      isSemantics(
        label: 'All media',
        hasCheckedState: true,
        isChecked: false,
        hasTapAction: true,
      ),
    );
    await tick('video');
    expect(row('video'), isSemantics(isChecked: true));
    expect(row('all'), isSemantics(isChecked: true));

    await tick('voice');
    await tick('image');
    expect(row('voice'), isSemantics(isChecked: false));
    await tick('all');
    for (final kind in ['all', 'voice', 'video', 'image']) {
      expect(row(kind), isSemantics(isChecked: true), reason: kind);
    }
  });

  testPress('View all is pressed by its name', (tester) async {
    await pumpWindow(tester);
    for (final id in [for (var i = 0; i < 5; i++) goldenNotes.create().id]) {
      goldenNotes.updateBody(id, 'Pinned');
      goldenNotes.togglePinned(id);
    }
    await tester.pumpAndSettle();

    await press(tester, labelled('View all pinned notes'));
    expect(labelled('View all pinned notes'), findsNothing);
    expect(unpressable(), isEmpty);
    expect(unnamed(), isEmpty);

    await press(tester, tipped('Back to all notes'));
    expect(labelled('View all pinned notes'), findsOne);
  });
}
