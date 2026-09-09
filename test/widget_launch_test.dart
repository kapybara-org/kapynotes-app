import 'dart:async';
import 'dart:io';

import 'package:kapy_notes/audio/voice_recorder.dart';
import 'package:kapy_notes/audio/voice_recording_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/images/image_picker.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:material_ui/material_ui.dart';

import 'app_test.dart' show MemoryStore;
import 'quick_capture_test.dart' show stubLaunchIntent;
import 'test_fonts.dart';

late MemoryStore store;
late NotesStore notes;
late LayoutPrefs prefs;
late RatesRepository rates;
late ShortcutPrefs shortcuts;
late List<String> imageRequests;

/// Launches the app the way a widget tap does: the platform is holding an
/// answer, and storage has not been read yet, so the app asks on the way up.
///
/// Deliberately not preloaded. A store that is already loaded takes the path
/// an app resuming from memory takes, which never asks anything.
Future<void> pumpLaunch(
  WidgetTester tester, {
  String? action,
  VoiceRecordingController? recording,
  LostImageRetriever? lostImageRetriever,
}) async {
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
      recording: recording,
      imageAcquirer: (_) async {
        imageRequests.add('camera');
        return const [];
      },
      lostImageRetriever: lostImageRetriever,
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

    imageRequests = [];
  });

  tearDown(() {
    AppPlatform.debugTargetPlatformOverride = null;
    stubLaunchIntent(null, respond: false);
  });

  testWidgets('a Capture tap opens the camera over the note it landed in', (
    tester,
  ) async {
    await pumpLaunch(tester, action: 'capture');

    expect(imageRequests, ['camera']);
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

    expect(imageRequests, isEmpty);
    expect(notes.notes.single.id, 'last');
  });

  testWidgets('a widget targets the fixed startup note when one is chosen', (
    tester,
  ) async {
    store.data['notes.v1'] = [
      {
        'id': 'recent',
        'body': 'Recently edited',
        'createdAt': 3000,
        'updatedAt': 4000,
      },
      {
        'id': 'inbox',
        'body': 'Widget inbox',
        'createdAt': 1000,
        'updatedAt': 2000,
      },
    ];
    store.data['defaultNote.v1'] = 'inbox';

    await pumpLaunch(tester, action: 'continueWriting');

    final editor = tester.widget<TextField>(find.byType(TextField));
    expect(editor.controller!.text, startsWith('Widget inbox'));
  });

  testWidgets('an ordinary launch opens no picker', (tester) async {
    await pumpLaunch(tester);

    expect(imageRequests, isEmpty);
  });

  testWidgets('a Dictate tap starts recording into the note it opened', (
    tester,
  ) async {
    // The recorder is a fake: the real one would want a microphone, and its
    // one-second ticker would keep `pumpAndSettle` waiting forever.
    final recorder = _SilentRecorder();
    final recording = VoiceRecordingController(
      recorder: recorder,
      tempDirectory: Directory.systemTemp,
    );
    addTearDown(recording.dispose);

    await pumpLaunch(tester, action: 'dictate', recording: recording);

    // Still the note that was already there. Dictate is no more a new note
    // than Write is.
    expect(notes.notes.single.id, 'last');
    expect(imageRequests, isEmpty);
    expect(recording.isRecording, isTrue);
    expect(recording.session!.noteId, 'last');
    expect(recorder.startedAt, endsWith('.m4a'));

    // Put the microphone down before the test ends: a live recording keeps a
    // one-second ticker, and flutter_test refuses to leave one pending.
    // Through `runAsync` because cancelling touches the filesystem, and real
    // I/O never completes inside the fake-async zone `testWidgets` runs in.
    await tester.runAsync(recording.cancel);
  });

  testWidgets('a Dictate tap with no microphone opens the note anyway', (
    tester,
  ) async {
    // Permission refused, or a platform with no recorder at all. The note is
    // still open at the end of itself, which is the part of dictating a
    // phone's own keyboard can finish.
    final recording = VoiceRecordingController(
      recorder: _SilentRecorder(permitted: false),
      tempDirectory: Directory.systemTemp,
    );
    addTearDown(recording.dispose);

    await pumpLaunch(tester, action: 'dictate', recording: recording);

    expect(notes.notes.single.id, 'last');
    expect(recording.isRecording, isFalse);
  });

  testWidgets('a Capture tap at an app already running still opens it', (
    tester,
  ) async {
    await pumpLaunch(tester);
    expect(imageRequests, isEmpty);

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

    expect(imageRequests, ['camera']);
    expect(notes.notes, hasLength(1));
  });

  testWidgets('an interrupted library return does not reopen Capture', (
    tester,
  ) async {
    store.data['pendingImageNote.v1'] = 'last';

    await pumpLaunch(
      tester,
      action: 'capture',
      lostImageRetriever: () async => const LostImageRecovery(),
    );

    expect(imageRequests, isEmpty);
    expect(store.data['pendingImageNote.v1'], isNull);
    expect(notes.notes.single.id, 'last');
  });
}

/// A recorder with no microphone behind it, and no ticker worth waiting on.
class _SilentRecorder implements VoiceRecorderBackend {
  _SilentRecorder({this.permitted = true});

  final bool permitted;
  String? startedAt;

  final _amplitude = StreamController<double>.broadcast();
  final _paused = StreamController<bool>.broadcast();

  @override
  Future<bool> hasPermission() async => permitted;

  @override
  Future<void> start(String path) async => startedAt = path;

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<String?> stop() async => startedAt;

  @override
  Future<void> cancel() async {}

  @override
  Stream<double> get amplitude => _amplitude.stream;

  @override
  Stream<bool> get paused => _paused.stream;

  @override
  Future<void> dispose() async {
    await _amplitude.close();
    await _paused.close();
  }
}
