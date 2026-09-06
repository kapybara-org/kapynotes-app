import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/empty_state.dart';
import 'package:kapy_notes/ui/kapy_header_mascot.dart';
import 'package:material_ui/material_ui.dart';

import 'app_test.dart' show MemoryStore;
import 'test_fonts.dart';

/// Rates the app only has once a refresh has landed. The welcome note has to
/// read the same either way, which is the point of the pair of tests below.
const _rates = <String, double>{'EUR': 0.861401, 'GBP': 0.738359};

/// The welcome note's evaluated lines, keyed by the line rather than by its
/// index: what matters is which lines compute and what they say, and a test
/// that says so survives the copy being re-wrapped.
Map<String, String> _resultsByLine({Map<String, double> rates = const {}}) {
  final lines = welcomeNoteBody.split('\n');
  final evaluation = CalcEngine(
    ratesPerUsd: rates,
  ).evaluateDocumentWithSummary(welcomeNoteBody);
  return {
    for (final entry in evaluation.results.entries)
      lines[entry.key]: entry.value.text,
  };
}

/// Launches the app over [store], the way a real install does: one store
/// behind everything, and nothing created before the first frame.
Future<void> pumpLaunch(
  WidgetTester tester,
  MemoryStore store, {
  Size size = const Size(1100, 760),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final notes = NotesStore(store);
  final prefs = LayoutPrefs(store);
  final rates = RatesRepository(store);
  final shortcuts = ShortcutPrefs(store);
  await notes.load();
  prefs.load();
  shortcuts.load();

  await tester.pumpWidget(
    KapyNotesApp(
      store: store,
      notes: notes,
      rates: rates,
      prefs: prefs,
      shortcuts: shortcuts,
    ),
  );
  await tester.pumpAndSettle();
}

TextField _field(WidgetTester tester) => tester.widget<TextField>(
  find.descendant(
    of: find.byType(NoteEditor),
    matching: find.byType(TextField),
  ),
);

void main() {
  setUpAll(loadTestFonts);

  group('what the welcome note computes', () {
    test('says the same thing with and without exchange rates', () {
      const expected = {
        'Coffee: 12.40': '12.4',
        'Oats: 3.99': '3.99',
        'Pastries: 6.50': '6.5',
        'total': '22.89',
      };
      // Exactly these lines, and no others: the prose has to stay silent
      // rather than hang an error off the end of a sentence.
      expect(_resultsByLine(), expected);
      expect(_resultsByLine(rates: _rates), expected);
    });

    test('agrees with the running total in the footer', () {
      final evaluation = CalcEngine().evaluateDocumentWithSummary(
        welcomeNoteBody,
      );
      expect(evaluation.totalText, '22.89');
    });

    test('names no currency, which a new install cannot yet convert', () {
      // Until the first rate refresh lands, `12.40 eur` evaluates to a bare
      // `12.4` with the currency dropped — right through the first launch of
      // an install with no network.
      expect(
        welcomeNoteBody.contains(RegExp(r'[$€£¥₹]')),
        isFalse,
        reason: 'a currency symbol reads as wrong until rates arrive',
      );
      expect(
        welcomeNoteBody.contains(
          RegExp(r'\b(usd|eur|gbp|jpy|inr)\b', caseSensitive: false),
        ),
        isFalse,
        reason: 'a currency code reads as wrong until rates arrive',
      );
    });

    test('reads as prose everywhere it means to', () {
      // looksLikeMath decides both what is evaluated and what is coloured, so
      // a sentence carrying a colon or the word `sum` would get syntax
      // highlighting sprayed through the middle of it. Only the demo, the
      // total and the closing invitation are meant to light up.
      final claimed = welcomeNoteBody
          .split('\n')
          .where((line) => line.trim().isNotEmpty)
          .where((line) => CalcEngine.looksLikeMath(line, const {}))
          .toList();
      expect(claimed, [
        'Coffee: 12.40',
        'Oats: 3.99',
        'Pastries: 6.50',
        'total',
        'Now try 20% of 60, or 9 km in miles.',
      ]);
    });

    test('invites two lines that genuinely work', () {
      final engine = CalcEngine();
      expect(welcomeNoteBody, contains('20% of 60'));
      expect(welcomeNoteBody, contains('9 km in miles'));
      expect(engine.evaluateDocument('20% of 60')[0]!.text, '12');
      expect(engine.evaluateDocument('9 km in miles')[0]!.text, '5.592341 mi');
    });
  });

  group('when it is seeded', () {
    test('lands in an empty store once, and never again', () {
      final store = MemoryStore();
      final notes = NotesStore(store);
      final onboarding = Onboarding(store);

      expect(onboarding.hasSeenWelcome, isFalse);
      final seeded = onboarding.seedWelcomeNote(notes);
      expect(seeded?.body, welcomeNoteBody);
      expect(onboarding.hasSeenWelcome, isTrue);

      // Thrown away, and the next launch respects that rather than putting it
      // back.
      notes.delete(seeded!.id);
      expect(Onboarding(store).seedWelcomeNote(notes), isNull);
      expect(notes.isEmpty, isTrue);
    });

    test('stays out of a device that already holds notes', () {
      final store = MemoryStore();
      final notes = NotesStore(store)..create(body: 'Pulled down by sync');

      expect(Onboarding(store).seedWelcomeNote(notes), isNull);
      expect(notes.notes, hasLength(1));
    });

    test('opens the copy that already exists instead of stacking them', () {
      final store = MemoryStore();
      final notes = NotesStore(store);
      final onboarding = Onboarding(store);

      final first = onboarding.openWelcomeNote(notes);
      final second = onboarding.openWelcomeNote(notes);
      expect(second.id, first.id);
      expect(notes.notes, hasLength(1));

      // Once it has been made their own, asking again writes a fresh one
      // rather than dragging their note back to the tour.
      notes.updateBody(first.id, 'Coffee: 12.40\nand my own line');
      final third = onboarding.openWelcomeNote(notes);
      expect(third.id, isNot(first.id));
      expect(notes.notes, hasLength(2));
    });
  });

  group('the first launch', () {
    testWidgets('opens on the welcome note instead of an empty page', (
      tester,
    ) async {
      await pumpLaunch(tester, MemoryStore());

      expect(find.byType(EmptyState), findsNothing);
      expect(_field(tester).controller!.text, welcomeNoteBody);
    });

    testWidgets('shows it from the top, with no cursor and no keyboard', (
      tester,
    ) async {
      await pumpLaunch(tester, MemoryStore(), size: const Size(390, 760));

      final field = _field(tester);
      // Unfocused, unscrolled and unchanged: no jump to the end, and no dated
      // separator stamped onto a note nobody has written in yet.
      expect(field.focusNode!.hasFocus, isFalse);
      expect(field.controller!.text, welcomeNoteBody);
      expect(tester.testTextInput.isVisible, isFalse);
    });

    testWidgets('gives Kapy the one beat the word total already earns', (
      tester,
    ) async {
      await pumpLaunch(tester, MemoryStore());

      final mascot = tester.widget<KapyHeaderMascot>(
        find.byType(KapyHeaderMascot),
      );
      expect(mascot.controller.lastAnimation, KapyHeaderAnimation.think);
    });

    testWidgets('hands the note over the moment it is typed in', (
      tester,
    ) async {
      await pumpLaunch(tester, MemoryStore(), size: const Size(390, 760));

      await tester.enterText(
        find.descendant(
          of: find.byType(NoteEditor),
          matching: find.byType(TextField),
        ),
        'Coffee: 20',
      );
      await tester.pumpAndSettle();

      // Editing it ends the welcome behaviour: from here it is one of their
      // notes, and the app treats it like one.
      expect(_field(tester).controller!.text, 'Coffee: 20');
      expect(_field(tester).focusNode!.hasFocus, isTrue);
    });
  });

  group('finding it again', () {
    testWidgets('settings opens it, even once the first one was rewritten', (
      tester,
    ) async {
      await pumpLaunch(tester, MemoryStore());

      // Made their own, which is exactly when somebody goes looking for the
      // tour they typed over.
      await tester.enterText(
        find.descendant(
          of: find.byType(NoteEditor),
          matching: find.byType(TextField),
        ),
        'My own note',
      );
      await tester.pumpAndSettle();

      // A new install keeps its notes list closed, so the sidebar's settings
      // button is mounted behind it as well as the editor's. This is the one
      // somebody with a note open would reach for.
      await tester.tap(
        find.descendant(
          of: find.byType(NoteEditor),
          matching: find.byTooltip('Settings'),
        ),
      );
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('open-welcome-note'));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();

      // Back on the note, from the top and without a cursor in it, exactly as
      // a first launch shows it.
      expect(_field(tester).controller!.text, welcomeNoteBody);
      expect(_field(tester).focusNode!.hasFocus, isFalse);
    });

    testWidgets('comes back through the notes drawer just as quietly', (
      tester,
    ) async {
      await pumpLaunch(tester, MemoryStore(), size: const Size(390, 760));
      await tester.enterText(
        find.descendant(
          of: find.byType(NoteEditor),
          matching: find.byType(TextField),
        ),
        'My own note',
      );
      await tester.pumpAndSettle();

      // The phone route: notes drawer, settings, welcome note. Closing the
      // drawer is what normally puts the cursor back at the end of a note.
      await tester.tap(find.byTooltip('Show notes'));
      await tester.pumpAndSettle();
      // The drawer's own settings row: the editor keeps a gear too, behind it.
      await tester.tap(
        find.descendant(
          of: find.byType(Drawer),
          matching: find.byKey(const ValueKey('sidebar-settings')),
        ),
      );
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('open-welcome-note'));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();

      expect(_field(tester).controller!.text, welcomeNoteBody);
      expect(_field(tester).focusNode!.hasFocus, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
    });
  });

  group('the second launch', () {
    testWidgets('starts on a blank page, welcome note deleted and all', (
      tester,
    ) async {
      final store = MemoryStore();
      await pumpLaunch(tester, store);
      expect(store.data[Onboarding.storeKey], Onboarding.welcomeRevision);

      // A second install-lifetime launch, with the note thrown away in
      // between.
      final notes = NotesStore(store);
      await notes.load();
      for (final note in [...notes.notes]) {
        notes.delete(note.id);
      }
      await pumpLaunch(tester, store);

      expect(find.byType(EmptyState), findsOneWidget);
      expect(find.byType(NoteEditor), findsNothing);
    });
  });
}
