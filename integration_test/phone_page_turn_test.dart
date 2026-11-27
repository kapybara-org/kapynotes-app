// Every sideways page turn on a phone (KAP-429), for KAPY-35 to judge the
// motion: a note's page turned a day back and on, a short drag let go that
// springs back, and Home turned from Notes to Tasks and back. Each runs in
// light and dark, recorded off the device's own screen as
// build/screenshots/page-turn-<appearance>.mp4 when the run's host reads
// screens, and the frames the turns take are counted from the engine's own
// frame timings and printed, as PAGE-TURN-FRAMES.
//
//   flutter drive --driver test_driver/integration_test.dart \
//     --target integration_test/phone_page_turn_test.dart -d <device> \
//     --dart-define=KAPYNOTES_SYNC=false
//
// The Phones workflow runs it through tool/ci/phone_screenshots.sh. It runs
// in a debug build, as every phone test does for its screenshots, so its
// frame times are the debug build's, slower than a release build's.
import 'dart:convert';

import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/appearance.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note_days.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/ui/tasks/tasks_screen.dart';
import 'package:material_ui/material_ui.dart';

import 'rates_support.dart';
import 'screenshot.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'phone-page-turn-integration.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

/// Wed 19 Nov 2025, 9:41.
final _now = DateTime(2025, 11, 19, 9, 41);

Map<String, Object?> _note(String id, String body, DateTime edited) => {
  'id': id,
  'body': body,
  'createdAt': edited.millisecondsSinceEpoch,
  'updatedAt': edited.millisecondsSinceEpoch,
};

final _day = find.byKey(const ValueKey('page-day'));

/// The words on the note's page's day chip.
List<String> _dayShown(WidgetTester tester) => [
  for (final text in tester.widgetList<Text>(
    find.descendant(of: _day, matching: find.byType(Text)),
  ))
    ?text.data,
];

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final appearance in [AppearanceMode.light, AppearanceMode.dark]) {
    final name = appearance.name;
    testWidgets('every sideways turn follows the finger, $name', (
      tester,
    ) async {
      final store = _MemoryStore();
      store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
      store.data['notes.v1'] = [
        _note('mon-a', 'Gym plan\nLegs', DateTime(2025, 11, 17, 7, 30)),
        _note('mon-b', 'Budget\nRent', DateTime(2025, 11, 17, 18, 10)),
        _note('tue', 'Standup notes\nShip it', DateTime(2025, 11, 18, 10, 5)),
        _note('errands', 'Errands\n☐ Buy milk', DateTime(2025, 11, 19, 8, 0)),
        _note(
          'arjun',
          'Call with Arjun\nPricing page by Friday.\n☐ Send the deck',
          DateTime(2025, 11, 19, 8, 55),
        ),
      ];
      final prefs = LayoutPrefs(store)..load();
      prefs.appearance = appearance;
      final notes = NotesStore(store, now: () => _now);
      final days = NoteDayStore(store, now: () => _now);
      await days.load();
      final library = TaskLibrary(
        notes: notes,
        store: store,
        storage: MemoryDocStorage(),
        now: () => _now,
      );
      await notes.load();
      await library.reconcileNow();
      await tester.pumpWidget(
        KapyNotesApp(
          store: store,
          notes: notes,
          rates: offlineRates(store),
          prefs: prefs,
          shortcuts: ShortcutPrefs(store)..load(),
          days: days,
          tasks: library,
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));
      // The page opens ready to type; the turns here start with the keyboard
      // down, once it has gone.
      FocusManager.instance.primaryFocus?.unfocus();
      await Future<void>.delayed(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(_dayShown(tester), contains('19'));

      final frames = <FrameTiming>[];
      void count(List<FrameTiming> timings) => frames.addAll(timings);
      SchedulerBinding.instance.addTimingsCallback(count);
      expect(
        await deviceAction('record:page-turn-$name'),
        anyOf(isNull, startsWith('no host')),
      );
      addTearDown(() => deviceAction('record-stop'));

      final width = tester.getSize(find.byType(MaterialApp)).width;
      Offset header() => tester.getCenter(_day) + const Offset(60, 0);
      Future<void> drag(Offset from, double share, int ms) async {
        await tester.timedDragFrom(
          from,
          Offset(share * width, 0),
          Duration(milliseconds: ms),
        );
        await tester.pumpAndSettle();
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }

      // A note's page: a day back, a short drag let go, then a day on.
      await drag(header(), 0.5, 500);
      expect(_dayShown(tester), contains('18'));
      await drag(header(), 0.12, 500);
      expect(_dayShown(tester), contains('18'));
      await drag(header(), -0.5, 500);
      expect(_dayShown(tester), contains('19'));

      // Home, turned to Tasks and back to Notes from its header.
      await tester.tap(find.byKey(const ValueKey('page-home')));
      await tester.pumpAndSettle();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final title = find.byKey(const ValueKey('home-title-notes'));
      await drag(tester.getCenter(title), -0.5, 500);
      expect(find.byType(TasksScreen), findsOneWidget);
      await drag(tester.getCenter(title), 0.5, 500);
      expect(find.byType(TasksScreen), findsNothing);

      SchedulerBinding.instance.removeTimingsCallback(count);
      await tester.pump();
      expect(tester.takeException(), isNull);

      double ms(Duration duration) => duration.inMicroseconds / 1000;
      double at(List<double> sorted, double share) =>
          sorted[((sorted.length - 1) * share).round()];
      expect(frames, isNotEmpty);
      final build = [for (final frame in frames) ms(frame.buildDuration)]
        ..sort();
      final raster = [for (final frame in frames) ms(frame.rasterDuration)]
        ..sort();
      final budget =
          1000 / binding.platformDispatcher.views.first.display.refreshRate;
      final summary = jsonEncode({
        'appearance': name,
        'frames': frames.length,
        'budget_ms': budget,
        'build_p50_ms': at(build, 0.5),
        'build_p90_ms': at(build, 0.9),
        'build_worst_ms': build.last,
        'raster_p50_ms': at(raster, 0.5),
        'raster_p90_ms': at(raster, 0.9),
        'raster_worst_ms': raster.last,
        'over_budget': frames
            .where((frame) => ms(frame.totalSpan) > budget)
            .length,
      });
      // ignore: avoid_print
      print('PAGE-TURN-FRAMES $summary');
    });
  }
}
