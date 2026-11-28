import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/data/folders.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/tags.dart';
import 'package:kapy_notes/recaps/recap_period.dart';
import 'package:kapy_notes/ui/home_page.dart';
import 'package:material_ui/material_ui.dart';

import 'fake_kapy_ai.dart';
import 'test_fonts.dart';

/// openKapyAiForPeriod: Kapy AI about a period, opened from Home the way the
/// recap drawer's Ask Kapy AI opens it.

class _Store extends LocalStore {
  _Store() : super(fileName: 'kapy-ai-period-app-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

const _windowMaterial = MethodChannel('kapynotes/window_material');
final _week = RecapPeriod.containing(
  DateTime(2026, 11, 17),
  RecapKind.week,
  firstWeekday: DateTime.monday,
);

void main() {
  setUpAll(loadTestFonts);

  late bool wasAvailable;
  late _Store store;
  late NotesStore notes;
  late FakeKapyAi ai;

  setUp(() {
    wasAvailable = kapyAiAvailable;
    kapyAiAvailable = true;
    store = _Store()..data[Onboarding.storeKey] = Onboarding.welcomeRevision;
    notes = NotesStore(store, now: () => DateTime(2026, 11, 17, 16, 40));
    ai = FakeKapyAi(pro: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_windowMaterial, (call) async => false);
  });
  tearDown(() {
    kapyAiAvailable = wasAvailable;
    ai.dispose();
  });

  Future<void> pump(
    WidgetTester tester, {
    required Size size,
    required TargetPlatform platform,
    bool tags = true,
  }) async {
    AppPlatform.debugTargetPlatformOverride = platform;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await notes.load();
    notes.create(body: 'Call with Arjun\nPricing page by Friday');
    notes.create(body: 'Launch checklist\n☐ Write release notes');
    final prefs = LayoutPrefs(store)..load();
    await tester.pumpWidget(
      KapyNotesApp(
        store: store,
        notes: notes,
        rates: RatesRepository(store),
        prefs: prefs,
        shortcuts: ShortcutPrefs(store)..load(),
        kapyAi: ai,
        tags: tags ? TagStore(store) : null,
        folders: FolderStore(store),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// A place under Home, as the row a drawer opens from is.
  BuildContext underHome(WidgetTester tester) => tester.element(
    find
        .descendant(of: find.byType(HomePage), matching: find.byType(Material))
        .first,
  );

  testWidgets('on a desktop it is the panel beside the page, about the week', (
    tester,
  ) async {
    await pump(
      tester,
      size: const Size(1500, 800),
      platform: TargetPlatform.macOS,
    );
    expect(openKapyAiForPeriod(underHome(tester), _week), isTrue);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('kapy-ai-panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('kapy-ai-sheet')), findsNothing);
    expect(find.byKey(const ValueKey('kapy-ai-period-chip')), findsOneWidget);
    expect(find.text('Ask about this week'), findsOneWidget);
    expect(
      find.text(
        'Answers come only from 16–22 Nov: 2 notes. Hidden notes are never '
        'used.',
      ),
      findsOneWidget,
      reason: 'Home reads the week as its recap would',
    );
    expect(ai.calls, contains('newChat'));
  });

  testWidgets('on a phone it is a sheet over Home, at full height', (
    tester,
  ) async {
    await pump(
      tester,
      size: const Size(393, 852),
      platform: TargetPlatform.iOS,
    );
    expect(openKapyAiForPeriod(underHome(tester), _week), isTrue);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('kapy-ai-sheet')), findsOneWidget);
    expect(find.byKey(const ValueKey('kapy-ai-period-chip')), findsOneWidget);
    expect(find.byKey(const ValueKey('kapy-ai-about')), findsNothing);
  });

  testWidgets('goes back to the chat about the same week', (tester) async {
    await pump(
      tester,
      size: const Size(1500, 800),
      platform: TargetPlatform.macOS,
    );
    final at = DateTime(2026, 11, 17, 12);
    final chat = KapyChat(
      id: 'week',
      title: 'Any news?',
      createdAt: at,
      updatedAt: at,
      model: KapyModel.cloud,
      scope: _week,
      messages: [
        KapyMessage(id: 'q', role: KapyRole.user, text: 'Any news?', at: at),
      ],
    );
    ai.set(chats: [chat], current: chat);
    expect(openKapyAiForPeriod(underHome(tester), _week), isTrue);
    await tester.pumpAndSettle();
    expect(ai.calls, isNot(contains('newChat')));
    expect(find.text('Any news?'), findsOneWidget);
  });

  testWidgets('opens nothing where the period cannot be read', (tester) async {
    await pump(
      tester,
      size: const Size(1500, 800),
      platform: TargetPlatform.macOS,
      tags: false,
    );
    expect(openKapyAiForPeriod(underHome(tester), _week), isFalse);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('kapy-ai-panel')), findsNothing);
  });

  testWidgets('opens nothing with Kapy AI off, or from outside Home', (
    tester,
  ) async {
    await pump(
      tester,
      size: const Size(1500, 800),
      platform: TargetPlatform.macOS,
    );
    expect(
      openKapyAiForPeriod(tester.element(find.byType(HomePage)), _week),
      isFalse,
    );
    ai.enabled = false;
    expect(openKapyAiForPeriod(underHome(tester), _week), isFalse);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('kapy-ai-panel')), findsNothing);
  });

  testWidgets('Home lets go of the reader when it goes', (tester) async {
    await pump(
      tester,
      size: const Size(1500, 800),
      platform: TargetPlatform.macOS,
    );
    expect(ai.periods, isNotNull);
    await tester.pumpWidget(const SizedBox());
    expect(ai.periods, isNull);
  });
}
