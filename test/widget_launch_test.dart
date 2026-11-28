import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:kapy_notes/data/blob_store.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:kapy_notes/audio/voice_recorder.dart';
import 'package:kapy_notes/audio/voice_recording_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/images/image_picker.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:material_ui/material_ui.dart';
import 'package:kapy_notes/ui/editor/note_field.dart';

import 'app_test.dart' show MemoryStore;
import 'quick_capture_test.dart' show stubLaunchIntent;
import 'support/note_driver.dart';
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
  bool settle = true,
  Duration answerAfter = Duration.zero,
}) async {
  stubLaunchIntent(action, after: answerAfter);
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
      cameraAcquirer: (_) async {
        imageRequests.add('camera');
        return const [];
      },
      lostImageRetriever: lostImageRetriever,
    ),
  );
  if (settle) await tester.pumpAndSettle();
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

    final editor = tester.widget<NoteField>(noteField);
    expect(editor.controller.text, startsWith('Widget inbox'));
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

  group('an answer that misses the launch deadline (KAP-148)', () {
    const late = Duration(milliseconds: 900);

    testWidgets('still starts Dictate in the note it opened', (tester) async {
      final recording = VoiceRecordingController(
        recorder: _SilentRecorder(),
        tempDirectory: Directory.systemTemp,
      );
      addTearDown(recording.dispose);

      await pumpLaunch(
        tester,
        action: 'dictate',
        recording: recording,
        answerAfter: late,
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      expect(notes.notes.single.id, 'last');
      expect(recording.isRecording, isTrue);
      expect(recording.session!.noteId, 'last');
      await tester.runAsync(recording.cancel);
    });

    testWidgets('still opens the camera for Capture', (tester) async {
      await pumpLaunch(tester, action: 'capture', answerAfter: late);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      expect(imageRequests, ['camera']);
    });

    testWidgets('a late Write leaves the open note as it is', (tester) async {
      await pumpLaunch(tester, action: 'continueWriting', answerAfter: late);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      expect(notes.notes.single.id, 'last');
      expect(imageRequests, isEmpty);
    });
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

  // A library whose only note is the welcome note, untouched, counts as empty
  // for a widget tap: the welcome note is there to be read, so Write, Dictate
  // and Capture each start a note of their own instead of landing in it.
  for (final firstLaunch in [true, false]) {
    final who = firstLaunch ? 'a first launch' : 'a relaunch';

    void welcomeOnlyLibrary() {
      store = MemoryStore();
      if (!firstLaunch) {
        store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
        store.data['notes.v1'] = [
          {
            'id': 'welcome',
            'body': welcomeNoteBody,
            'createdAt': 1000,
            'updatedAt': 1000,
          },
        ];
      }
      notes = NotesStore(store);
      prefs = LayoutPrefs(store);
      rates = RatesRepository(store);
      shortcuts = ShortcutPrefs(store);
    }

    Note welcomeNote() =>
        notes.notes.singleWhere((note) => note.body == welcomeNoteBody);

    Note newNote() =>
        notes.notes.singleWhere((note) => note.body != welcomeNoteBody);

    void expectWelcomeLeftAlone(WidgetTester tester) {
      expect(notes.notes, hasLength(2));
      expect(welcomeNote().body, welcomeNoteBody);
      expect(
        tester.widget<NoteField>(noteField).controller.text,
        isNot(contains('Welcome to Kapy Notes')),
        reason: 'the note on the page is the new one',
      );
      expect(newNote().isEmpty, isTrue);
    }

    Future<void> resumeWith(WidgetTester tester, String action) async {
      stubLaunchIntent(action);
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
    }

    VoiceRecordingController dictation() {
      final recording = VoiceRecordingController(
        recorder: _SilentRecorder(),
        tempDirectory: Directory.systemTemp,
      );
      addTearDown(recording.dispose);
      return recording;
    }

    for (final warm in [false, true]) {
      final how = warm ? 'tapped while the app is open' : 'cold';

      testWidgets('Dictate on $who with only the welcome note, $how, records '
          'into a new note', (tester) async {
        welcomeOnlyLibrary();
        final recording = dictation();

        if (warm) {
          await pumpLaunch(tester, recording: recording);
          await resumeWith(tester, 'dictate');
        } else {
          await pumpLaunch(tester, action: 'dictate', recording: recording);
        }

        expectWelcomeLeftAlone(tester);
        expect(recording.isRecording, isTrue);
        expect(recording.session!.noteId, newNote().id);
        await tester.runAsync(recording.cancel);
      });

      testWidgets('Capture on $who with only the welcome note, $how, opens '
          'the camera over a new note', (tester) async {
        welcomeOnlyLibrary();

        if (warm) {
          await pumpLaunch(tester);
          await resumeWith(tester, 'capture');
        } else {
          await pumpLaunch(tester, action: 'capture');
        }

        expect(imageRequests, ['camera']);
        expectWelcomeLeftAlone(tester);
      });

      testWidgets('Write on $who with only the welcome note, $how, opens a '
          'new note', (tester) async {
        welcomeOnlyLibrary();

        if (warm) {
          await pumpLaunch(tester);
          await resumeWith(tester, 'continueWriting');
        } else {
          await pumpLaunch(tester, action: 'continueWriting');
        }

        expect(imageRequests, isEmpty);
        expectWelcomeLeftAlone(tester);
      });
    }

    testWidgets('an ordinary resume of $who with only the welcome note makes '
        'no new note', (tester) async {
      welcomeOnlyLibrary();

      await pumpLaunch(tester);
      await resumeWith(tester, 'open');

      expect(notes.notes, hasLength(1));
      expect(notes.notes.single.body, welcomeNoteBody);
      expect(imageRequests, isEmpty);
    });
  }

  testWidgets('a welcome note that has been edited is a real note, and Dictate '
      'carries on in it', (tester) async {
    store.data['notes.v1'] = [
      {
        'id': 'welcome',
        'body': '${welcomeNoteBody}Mine.',
        'createdAt': 1000,
        'updatedAt': 2000,
      },
    ];
    notes = NotesStore(store);
    final recording = VoiceRecordingController(
      recorder: _SilentRecorder(),
      tempDirectory: Directory.systemTemp,
    );
    addTearDown(recording.dispose);

    await pumpLaunch(tester, action: 'dictate', recording: recording);

    expect(notes.notes.single.id, 'welcome');
    expect(recording.session!.noteId, 'welcome');
    await tester.runAsync(recording.cancel);
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

  testWidgets('a Photos choice made while Android killed the app lands in '
      'its note', (tester) async {
    final folder = await tester.runAsync(
      () => Directory.systemTemp.createTemp('kapy_lost_photo_'),
    );
    addTearDown(() => folder!.delete(recursive: true));
    final picker = _KilledPicker();
    final platform = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = picker;
    addTearDown(() => ImagePickerPlatform.instance = platform);
    notes = NotesStore(store, blobs: BlobStore(directory: folder!));

    await pumpLaunch(tester, action: 'continueWriting');
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('format-attach')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('attach-photos')));
    await tester.pump();
    expect(picker.opened, 1);

    // Android reclaims the process while its library is in front. All that
    // survives is what was saved before the camera opened.
    final saved = Map.of(store.data);
    expect(saved['pendingImageNote.v1'], 'last');
    await tester.pumpWidget(const SizedBox());
    store = MemoryStore()..data.addAll(saved);
    notes = NotesStore(store, blobs: BlobStore(directory: folder));
    prefs = LayoutPrefs(store);
    rates = RatesRepository(store);
    shortcuts = ShortcutPrefs(store);
    final photo = img.Image(width: 32, height: 24, numChannels: 3);
    picker.lost = XFile.fromData(
      Uint8List.fromList(img.encodePng(photo, level: 1)),
      name: 'photo.png',
      mimeType: 'image/png',
    );

    await pumpLaunch(tester, action: 'capture', settle: false);
    for (var i = 0; i < 100 && notes.byId('last')!.attachments.isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(seconds: 5));

    expect(picker.opened, 1, reason: 'the returning photo does not reopen it');
    expect(imageRequests, isEmpty, reason: 'nor does it open the camera');
    expect(notes.notes.single.id, 'last');
    expect(notes.byId('last')!.attachments, hasLength(1));
    expect(store.data['pendingImageNote.v1'], isNull);
  });
}

/// A photo library Android never returns from: the process dies while it is
/// open, and the photo waits in image_picker's lost-data store for the next
/// launch.
class _KilledPicker extends ImagePickerPlatform
    with MockPlatformInterfaceMixin {
  int opened = 0;
  XFile? lost;

  @override
  Future<List<XFile>> getMedia({required MediaOptions options}) {
    opened++;
    return Completer<List<XFile>>().future;
  }

  @override
  Future<LostDataResponse> getLostData() async {
    final file = lost;
    lost = null;
    return file == null
        ? LostDataResponse.empty()
        : LostDataResponse(file: file, files: [file], type: RetrieveType.image);
  }
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
  Future<bool> hasMicrophone() async => true;

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
