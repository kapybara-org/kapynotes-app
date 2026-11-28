import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/ai/kapy_chat_book.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/appearance.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/data/folders.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/tags.dart';
import 'package:kapy_notes/recaps/recap_digest.dart';
import 'package:kapy_notes/recaps/recap_maker.dart';
import 'package:kapy_notes/recaps/recap_period.dart';
import 'package:kapy_notes/recaps/recap_record.dart';
import 'package:kapy_notes/ui/home_page.dart';
import 'package:material_ui/material_ui.dart';

import 'recap_maker_fixtures.dart' show RecapAi;

/// Kept in memory, written straight through.
class TimelineStore extends LocalStore {
  TimelineStore() : super(fileName: 'recap-timeline-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

/// Home in the whole app on Thu 19 Nov 2026 at 9:41, with notes reaching
/// back over this week, earlier weeks of November, earlier months of 2026
/// and two earlier years, for the timeline's rail. Weeks start on Sunday,
/// as the test locale's do: this week is 15–21 Nov.
class TimelineApp {
  TimelineApp() {
    store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
  }

  static final DateTime now = DateTime(2026, 11, 19, 9, 41);

  /// 8–14 Nov, the week before this one.
  static final RecapPeriod lastWeek = week(DateTime(2026, 11, 8));

  /// 1–7 Nov.
  static final RecapPeriod firstWeek = week(DateTime(2026, 11, 1));

  static RecapPeriod week(DateTime day) => RecapPeriod.containing(
    day,
    RecapKind.week,
    firstWeekday: DateTime.sunday,
  );

  final store = TimelineStore();
  late NotesStore notes;
  late KapyChatBook book;
  late RecapAi ai;
  final List<Map<String, Object?>> _notes = [];

  /// A note last edited at [at], local time.
  void note(String id, DateTime at, String body) => _notes.add(
    Note(
      id: id,
      body: body,
      createdAt: at.subtract(const Duration(minutes: 5)).toUtc(),
      updatedAt: at.toUtc(),
    ).toJson(),
  );

  /// Three notes today, three yesterday and two on Mon 16; 14 notes in
  /// 8–14 Nov, 7 in 1–7 Nov; 10 in October and 7 in September; 6 in 2025
  /// and 1 in 2024.
  void sample() {
    note(
      'morning',
      DateTime(2026, 11, 19, 9, 12),
      'Morning pages\nThree things: the deck, the room, a walk',
    );
    note(
      'arjun',
      DateTime(2026, 11, 19, 8, 55),
      'Call with Arjun\nPricing page by Friday',
    );
    note(
      'quote',
      DateTime(2026, 11, 19, 8, 20),
      'Quote for the deck\n40 seats × 12 = 480 a month',
    );
    note(
      'standup',
      DateTime(2026, 11, 18, 17, 5),
      'Standup notes\nFinish the pricing page',
    );
    note(
      'gym',
      DateTime(2026, 11, 18, 7, 30),
      'Gym plan\nLegs and a long walk',
    );
    note(
      'launch',
      DateTime(2026, 11, 18, 6, 10),
      'Launch checklist\nWrite release notes',
    );
    note('pricing', DateTime(2026, 11, 16, 12), 'Pricing ideas\n1,799.00 INR');
    note(
      'keys',
      DateTime(2026, 11, 16, 9),
      'Spare keys\nNadia has the spare set',
    );
    note(
      'errand-15',
      DateTime(2026, 11, 15, 15),
      'Errand 15\nPick up the parcel',
    );
    note(
      'week-15',
      DateTime(2026, 11, 15, 10),
      'Week note 15\nSomething from the week',
    );
    for (var day = 8; day <= 14; day++) {
      note(
        'week-$day',
        DateTime(2026, 11, day, 10),
        'Week note $day\nSomething from the week',
      );
      note(
        'errand-$day',
        DateTime(2026, 11, day, 15),
        'Errand $day\nPick up the parcel',
      );
    }
    for (var day = 1; day <= 7; day++) {
      note(
        'plan-$day',
        DateTime(2026, 11, day, 11),
        'Plan $day\nSketch the week',
      );
    }
    for (var day = 1; day <= 28; day += 3) {
      note(
        'oct-$day',
        DateTime(2026, 10, day, 10),
        'October $day\nThe autumn plan',
      );
    }
    for (var day = 2; day <= 26; day += 4) {
      note(
        'sep-$day',
        DateTime(2026, 9, day, 10),
        'September $day\nBack to school',
      );
    }
    for (var month = 1; month <= 12; month += 2) {
      note(
        'y25-$month',
        DateTime(2025, month, 12, 10),
        'Old note $month\nFrom last year',
      );
    }
    note('y24', DateTime(2024, 6, 3, 10), 'Older still\nTwo years back');
  }

  /// A recap of [period] made at [at], as Kapy AI Cloud keeps one.
  KapyChat recap(RecapPeriod period, DateTime at) => recapChat(
    null,
    record: RecapRecord(
      period: period,
      timeZone: 'UTC',
      firstWeekday: period.first.weekday,
      madeAt: at,
      numbers: const RecapNumbers(
        counts: RecapCounts(notes: 7),
        tasksOpen: 0,
        chart: [1, 1, 1, 1, 1, 1, 1],
        longestRun: 7,
        topics: [],
        previous: RecapCounts(),
      ),
      fingerprint: '0123456789abcdef',
    ),
    answer: 'TITLE: A planning week',
    model: KapyModel.cloud,
    now: at,
  );

  /// The app over the notes given, in [appearance], with recaps of [made]
  /// already made. [opened] is the note open at launch. On a desktop the
  /// list beside the rail is shown, as rows unless [rows] is false.
  Future<KapyNotesApp> app({
    required bool phone,
    AppearanceMode appearance = AppearanceMode.system,
    List<RecapPeriod> made = const [],
    bool rows = true,
    String? opened,
    RatesRepository? rates,
  }) async {
    store.data['notes.v1'] = _notes;
    notes = NotesStore(store, now: () => now);
    await notes.load();
    book = KapyChatBook(TimelineStore());
    await book.load();
    for (final period in made) {
      book.put(recap(period, DateTime.utc(2026, 11, 10, 9)));
    }
    ai = RecapAi();
    final prefs = LayoutPrefs(store)..load();
    prefs.appearance = appearance;
    if (!phone && !prefs.sidebarVisible) prefs.toggleSidebar();
    prefs.noteCards = !rows;
    if (opened != null) prefs.lastOpenedNoteId = opened;
    return KapyNotesApp(
      store: store,
      notes: notes,
      rates: rates ?? RatesRepository(store),
      prefs: prefs,
      shortcuts: ShortcutPrefs(store)..load(),
      kapyAi: ai,
      chats: book,
      tags: TagStore(store),
      folders: FolderStore(store),
    );
  }

  /// The recaps the app made for its lifetime, as Home holds them.
  static RecapMaker makerOf(WidgetTester tester) =>
      tester.widget<HomePage>(find.byType(HomePage)).recaps!;

  /// Pumps the app on a phone (393 × 852) or a desktop (1440 × 900) in
  /// [brightness], with Kapy AI in the build unless [kapyAi] says, and on
  /// a phone goes back from the note open to Home.
  Future<void> pump(
    WidgetTester tester, {
    required bool phone,
    Brightness brightness = Brightness.light,
    bool kapyAi = true,
    bool rows = true,
    List<RecapPeriod> made = const [],
    String? opened,
  }) async {
    final wasAvailable = kapyAiAvailable;
    kapyAiAvailable = kapyAi;
    addTearDown(() => kapyAiAvailable = wasAvailable);
    AppPlatform.debugTargetPlatformOverride = phone
        ? TargetPlatform.iOS
        : TargetPlatform.macOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = phone
        ? const Size(393, 852)
        : const Size(1440, 900);
    if (phone) {
      tester.view.padding = const FakeViewPadding(top: 59, bottom: 34);
      tester.view.viewPadding = const FakeViewPadding(top: 59, bottom: 34);
    }
    addTearDown(tester.view.reset);
    tester.platformDispatcher.platformBrightnessTestValue = brightness;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('kapynotes/window_material'),
          (call) async => false,
        );
    final app = await this.app(
      phone: phone,
      made: made,
      rows: rows,
      opened: opened,
    );
    addTearDown(ai.dispose);
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    await home(tester);
  }

  /// Back from a phone's note to Home, where the app opened on one.
  static Future<void> home(WidgetTester tester) async {
    final back = find.byKey(const ValueKey('page-home'));
    if (back.evaluate().isEmpty) return;
    await tester.tap(back);
    await tester.pumpAndSettle();
  }
}
