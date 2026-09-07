import 'dart:ui' show AppLifecycleState;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';

import 'app_test.dart' show MemoryStore;
import 'quick_capture_test.dart' show stubLaunchIntent;
import 'test_fonts.dart';

/// The channel `file_selector` reaches the platform picker on. Nothing
/// registers it in a test, so this is both how the picker is prevented from
/// existing and how the app is caught asking for it.
const MethodChannel _picker = MethodChannel('plugins.flutter.io/file_selector');

late MemoryStore store;
late NotesStore notes;
late LayoutPrefs prefs;
late RatesRepository rates;
late ShortcutPrefs shortcuts;
late List<MethodCall> pickerCalls;

/// Launches the app the way a widget tap does: the platform is holding an
/// answer, and storage has not been read yet, so the app asks on the way up.
///
/// Deliberately not preloaded. A store that is already loaded takes the path
/// an app resuming from memory takes, which never asks anything.
Future<void> pumpLaunch(WidgetTester tester, {String? action}) async {
  stubLaunchIntent(action);
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

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

void main() {
  setUpAll(loadTestFonts);

  setUp(() {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
    store = MemoryStore();
    // Somebody who has used the app before: they have met the welcome note,
    // and they left a note behind to be carried on.
    store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
    store.data['notes.v1'] = [
      {'id': 'last', 'body': 'Milk', 'createdAt': 1000, 'updatedAt': 2000},
    ];
    notes = NotesStore(store);
    prefs = LayoutPrefs(store);
    rates = RatesRepository(store);
    shortcuts = ShortcutPrefs(store);

    pickerCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_picker, (call) async {
          pickerCalls.add(call);
          // The picker opened and the user chose nothing, which is the only
          // outcome a test can honestly stand in for.
          return null;
        });
  });

  tearDown(() {
    AppPlatform.debugTargetPlatformOverride = null;
    stubLaunchIntent(null, respond: false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_picker, null);
  });

  testWidgets('a Capture tap opens the picker over the note it landed in', (
    tester,
  ) async {
    await pumpLaunch(tester, action: 'capture');

    expect(pickerCalls.map((call) => call.method), ['openFile']);
    // Over the note that was already there. A note per tap would shred a
    // notebook into fragments, and Capture is no more a new note than Write.
    expect(notes.notes, hasLength(1));
    expect(notes.notes.single.id, 'last');
    expect(find.byType(NoteEditor), findsOneWidget);
  });

  testWidgets('a Write tap opens the note and asks for nothing else', (
    tester,
  ) async {
    await pumpLaunch(tester, action: 'continueWriting');

    expect(pickerCalls, isEmpty);
    expect(notes.notes.single.id, 'last');
  });

  testWidgets('an ordinary launch opens no picker', (tester) async {
    await pumpLaunch(tester);

    expect(pickerCalls, isEmpty);
  });

  // Until voice notes land — docs/voice-notes.md, Phase 1 — Dictate is Write:
  // the note, open, at the end of itself. This is the test that will change
  // when there is a recorder for it to start.
  testWidgets('a Dictate tap opens the note, and starts no picker', (
    tester,
  ) async {
    await pumpLaunch(tester, action: 'dictate');

    expect(pickerCalls, isEmpty);
    expect(notes.notes.single.id, 'last');
  });

  testWidgets('a Capture tap at an app already running still opens it', (
    tester,
  ) async {
    await pumpLaunch(tester);
    expect(pickerCalls, isEmpty);

    // The tap arrives at a backgrounded app: Android hands the activity a new
    // intent, iOS hands the scene a URL, and both are held until the app is
    // asked — which it does on the way back to the foreground.
    stubLaunchIntent('capture');
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();

    expect(pickerCalls.map((call) => call.method), ['openFile']);
    expect(notes.notes, hasLength(1));
  });
}
