// The timeline's rail on Home on a real phone or simulator: the whole app
// over notes kept in memory, with a Kapy AI that answers from the test and
// never from a model or the network.
//
//   flutter drive --driver test_driver/integration_test.dart \
//     --target integration_test/phone_recap_rail_test.dart -d <device> \
//     --dart-define=KAPYNOTES_SYNC=false
//
// Home lists this week by day and folds the weeks before into cards on the
// rail. An earlier week's recap icon opens its recap drawer as a sheet, and
// its Ask Kapy AI closes the drawer and opens Kapy AI about that week. Home
// and the drawer are shots, dark and light.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/ai/kapy_chat_book.dart';
import 'package:kapy_notes/ai/period_scope.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/appearance.dart';
import 'package:kapy_notes/data/folders.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/tags.dart';
import 'package:kapy_notes/data/task_board.dart';
import 'package:kapy_notes/ui/recaps/recap_rail.dart';
import 'package:material_ui/material_ui.dart';

import '../test/fake_kapy_ai.dart';
import 'rates_support.dart';
import 'screenshot.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'recap-rail-integration.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

/// The widgets whose string key starts with [prefix].
Finder _keyed(String prefix) => find.byWidgetPredicate(
  (widget) => switch (widget.key) {
    ValueKey<String>(:final value) => value.startsWith(prefix),
    _ => false,
  },
);

String _keyOf(Finder finder) =>
    (finder.evaluate().first.widget.key! as ValueKey<String>).value;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final appearance in [AppearanceMode.dark, AppearanceMode.light]) {
    testWidgets('an earlier week opens its recap drawer from its row, '
        '${appearance.name}', (tester) async {
      kapyAiAvailable = true;
      final today = DateTime.now();
      var clock = today;
      final store = _MemoryStore();
      store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
      final notes = NotesStore(store, now: () => clock);
      final tags = TagStore(store);
      final folders = FolderStore(store);
      final chats = KapyChatBook(_MemoryStore());
      final prefs = LayoutPrefs(store)..load();
      prefs.appearance = appearance;
      await notes.load();
      await tags.load();
      await folders.load();
      await chats.load();
      for (var back = 13; back > 0; back--) {
        for (final (hour, body) in [
          (9, 'Morning pages\nThree things for the day'),
          (13, 'Lunch with Nadia\nTalked about the launch'),
          (18, 'Groceries\nMilk, eggs and rice'),
        ]) {
          final day = today.subtract(Duration(days: back));
          clock = DateTime(day.year, day.month, day.day, hour);
          notes.create(body: body);
        }
      }
      clock = today;
      notes.create(body: 'Call with Arjun\nPricing page by Friday');

      final ai = FakeKapyAi(pro: true)..set(model: KapyModel.cloud);
      ai.periods = (period) => KapyPeriodRead.gather(
        period,
        store: notes,
        tasks: TaskBoard.read(
          entries: const [],
          notes: notes.notes,
          docOf: (_) => null,
        ),
        tags: tags,
        folders: folders.tree,
        displayTime: (instant) => instant.toLocal(),
      );

      await tester.pumpWidget(
        KapyNotesApp(
          store: store,
          notes: notes,
          rates: offlineRates(store),
          prefs: prefs,
          shortcuts: ShortcutPrefs(store)..load(),
          tags: tags,
          folders: folders,
          chats: chats,
          kapyAi: ai,
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));
      final back = find.byKey(const ValueKey('page-home'));
      if (back.evaluate().isNotEmpty) {
        await tester.tap(back);
        await tester.pumpAndSettle();
      }

      expect(find.byType(RecapRailLine), findsWidgets);
      expect(
        find.byKey(
          ValueKey(
            'recap-heading-day-${today.year}-${today.month}-${today.day}',
          ),
        ),
        findsOneWidget,
      );
      await screenshot('recap-rail-${appearance.name}');

      final list = find
          .ancestor(
            of: find.byType(RecapRailLine).first,
            matching: find.byType(Scrollable),
          )
          .first;

      /// Scrolls Home down until a row keyed [prefix] is built, and brings
      /// the first into view.
      Future<Finder> reach(String prefix) async {
        final rows = _keyed(prefix);
        for (var i = 0; i < 40 && rows.evaluate().isEmpty; i++) {
          await tester.drag(list, const Offset(0, -240));
          await tester.pumpAndSettle();
        }
        expect(rows, findsWidgets, reason: 'no row keyed $prefix');
        await tester.ensureVisible(rows.first);
        await tester.pumpAndSettle();
        return rows.first;
      }

      // Last week sits under this month's heading as a card, or, where it
      // ended in the month before, in that month's card.
      await reach('recap-card-');
      if (_keyed('recap-card-week-').evaluate().isEmpty) {
        await tester.tap(await reach('recap-card-month-'));
        await tester.pumpAndSettle();
      }
      final week = await reach('recap-card-week-');
      final icon = find.byKey(
        ValueKey(_keyOf(week).replaceFirst('recap-card-', 'recap-icon-')),
      );
      expect(icon, findsOneWidget);
      expect(tester.getSize(icon), const Size(44, 44));

      // The sheet's route cancels the press it opens under, and the live
      // binding hands that cancel to its finder printer unless device pointer
      // events reach the app.
      binding.shouldPropagateDevicePointerEvents = true;
      addTearDown(() => binding.shouldPropagateDevicePointerEvents = false);
      await tester.tap(icon);
      await tester.pumpAndSettle();
      binding.shouldPropagateDevicePointerEvents = false;
      final drawer = find.byKey(const ValueKey('recap-drawer'));
      expect(drawer, findsOneWidget);
      expect(
        find.ancestor(of: drawer, matching: find.byType(BottomSheet)),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('recap-create')), findsOneWidget);
      await screenshot('recap-drawer-week-${appearance.name}');

      await tester.tap(find.byKey(const ValueKey('recap-ask')));
      await tester.pumpAndSettle();
      expect(drawer, findsNothing);
      expect(ai.calls, contains('newChat'));
      expect(find.byKey(const ValueKey('kapy-ai-sheet')), findsOneWidget);
    });
  }
}
