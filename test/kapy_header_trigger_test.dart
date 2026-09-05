import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/home_page.dart';
import 'package:kapy_notes/ui/kapy_header_mascot.dart';
import 'package:material_ui/material_ui.dart';

import 'app_test.dart' show MemoryStore;
import 'test_fonts.dart';

class _AppFixture {
  _AppFixture(MemoryStore store)
    : store = store,
      notes = NotesStore(store),
      prefs = LayoutPrefs(store),
      rates = RatesRepository(store),
      shortcuts = ShortcutPrefs(store);

  final MemoryStore store;
  final NotesStore notes;
  final LayoutPrefs prefs;
  final RatesRepository rates;
  final ShortcutPrefs shortcuts;
}

Future<_AppFixture> _pumpApp(WidgetTester tester, {String body = ''}) async {
  final fixture = _AppFixture(MemoryStore());
  await fixture.notes.load();
  fixture.prefs.load();
  fixture.shortcuts.load();
  fixture.notes.create(body: body);

  tester.view.physicalSize = const Size(1100, 760);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    KapyNotesApp(
      store: fixture.store,
      notes: fixture.notes,
      rates: fixture.rates,
      prefs: fixture.prefs,
      shortcuts: fixture.shortcuts,
    ),
  );
  await tester.pumpAndSettle();
  return fixture;
}

KapyHeaderController _controller(WidgetTester tester) =>
    tester.widget<KapyHeaderMascot>(find.byType(KapyHeaderMascot)).controller;

KapyHeaderMascotState _mascotState(WidgetTester tester) =>
    tester.state<KapyHeaderMascotState>(find.byType(KapyHeaderMascot));

Finder _editor() => find.descendant(
  of: find.byType(NoteEditor),
  matching: find.byType(TextField),
);

Future<void> _finish(WidgetTester tester, Duration duration) async {
  await tester.pump(duration + const Duration(milliseconds: 1));
  await tester.pump();
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('the word total requests one thinking sequence per occurrence', (
    tester,
  ) async {
    await _pumpApp(tester, body: 'Groceries');
    final controller = _controller(tester);
    var commands = 0;
    controller.addListener(() => commands++);

    await tester.enterText(_editor(), 'Groceries\nTotal spend');
    await tester.pump();

    expect(controller.lastAnimation, KapyHeaderAnimation.think);
    expect(_mascotState(tester).activeAnimation, KapyHeaderAnimation.emerge);
    expect(commands, 1);

    await tester.enterText(_editor(), 'Groceries\nTotal spend\nCoffee 4');
    await tester.pump();
    expect(commands, 1);

    await tester.enterText(_editor(), 'Groceries\nCoffee 4');
    await tester.pump();
    await _finish(tester, KapyHeaderMascot.emergeDuration);
    await _finish(tester, KapyHeaderMascot.thinkDuration);
    await _finish(tester, KapyHeaderMascot.hideDuration);
    expect(_mascotState(tester).restingPose, KapyHeaderRestingPose.logo);

    await tester.enterText(_editor(), 'Groceries\ntotal spend again');
    await tester.pump();
    expect(commands, 2);
    expect(_mascotState(tester).activeAnimation, KapyHeaderAnimation.emerge);
  });

  testWidgets('one minute of inactivity sleeps Kapy and input wakes it', (
    tester,
  ) async {
    await _pumpApp(tester, body: 'A quiet note');
    final controller = _controller(tester);

    await tester.pump(HomePage.kapyIdleDelay - const Duration(seconds: 10));
    await tester.enterText(_editor(), 'A quiet note with an edit');
    await tester.pump();
    await tester.pump(const Duration(seconds: 20));
    expect(controller.lastAnimation, isNull);

    await tester.pump(HomePage.kapyIdleDelay - const Duration(seconds: 20));
    await tester.pump();
    expect(controller.lastAnimation, KapyHeaderAnimation.sleep);
    expect(_mascotState(tester).activeAnimation, KapyHeaderAnimation.emerge);

    await _finish(tester, KapyHeaderMascot.emergeDuration);
    await _finish(tester, KapyHeaderMascot.sleepDuration);
    expect(_mascotState(tester).restingPose, KapyHeaderRestingPose.sleeping);

    await tester.tap(_editor());
    await tester.pump();
    expect(controller.lastAnimation, KapyHeaderAnimation.wake);
    expect(_mascotState(tester).activeAnimation, KapyHeaderAnimation.wake);

    await _finish(tester, KapyHeaderMascot.wakeDuration);
    expect(_mascotState(tester).activeAnimation, KapyHeaderAnimation.hide);
    await _finish(tester, KapyHeaderMascot.hideDuration);
    expect(_mascotState(tester).restingPose, KapyHeaderRestingPose.logo);
  });
}
