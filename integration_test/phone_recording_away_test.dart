// A voice recording carries on with the phone locked, under its
// notification on Android and its Live Activity on the iPhone, and comes back
// whole, two minutes and more of it.
//
// Run by tool/ci/phone_screenshots.sh under flutter drive, whose host does
// to the phone what nobody in the app can: locks it, wakes it, pulls down
// the shade and presses the notification's buttons, and reads its screen
// for each of them. Under plain flutter test, with no host, it skips.
//
// A simulator has no lock button, so its host presses Simulator's own Lock
// for it. Where that is not allowed, the recording goes behind another app
// instead, which leaves the app just as out of sight.
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/audio/voice_recording_controller.dart';
import 'package:kapy_notes/core/appearance.dart';
import 'package:kapy_notes/data/blob_store.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:record/record.dart';

import 'rates_support.dart';
import 'screenshot.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'phone-recording-away-integration.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

/// At least this much of the recording is made with the app out of sight.
const _away = Duration(seconds: 130);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a recording carries on with the phone locked', (tester) async {
    if (!hostReadsScreens) {
      markTestSkipped('Needs the host in tool/ci/phone_screenshots.sh.');
      return;
    }
    // An iPhone ends an app whose permissions change while it runs, so
    // tool/ci/phone_screenshots.sh grants the simulator's microphone before
    // the app starts; an emulator's is granted now, by the host. Checked
    // without asking either way, so that a phone never granted it fails here
    // rather than waiting on a dialog nobody answers.
    if (Platform.isAndroid) {
      expect(await deviceAction('grant'), isNull, reason: 'the microphone');
    }
    // What the phone refuses to show is only said in the log: a notification
    // the system would not post, a Live Activity ActivityKit would not start.
    final refusals = <String>[];
    final print = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message?.contains('recording controls could not') ?? false) {
        refusals.add(message!);
      }
      print(message, wrapWidth: wrapWidth);
    };
    addTearDown(() => debugPrint = print);

    final probe = AudioRecorder();
    final granted = await probe.hasPermission(request: false);
    await probe.dispose();
    expect(granted, isTrue, reason: 'the microphone was never granted');

    final temp = await Directory.systemTemp.createTemp('kapy-away');
    addTearDown(() => temp.delete(recursive: true));
    final store = _MemoryStore();
    store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
    final edited = DateTime.now().millisecondsSinceEpoch;
    store.data['notes.v1'] = [
      {
        'id': 'standup',
        'body': 'Standup\nWhat we said',
        'createdAt': edited,
        'updatedAt': edited,
      },
    ];
    final prefs = LayoutPrefs(store)..load();
    prefs.appearance = AppearanceMode.dark;
    final notes = NotesStore(store, blobs: BlobStore(directory: temp));
    await notes.load();
    final recording = VoiceRecordingController(tempDirectory: temp);
    addTearDown(recording.dispose);

    await tester.pumpWidget(
      KapyNotesApp(
        store: store,
        notes: notes,
        rates: offlineRates(store),
        prefs: prefs,
        shortcuts: ShortcutPrefs(store)..load(),
        recording: recording,
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Filmed on Android for the Play Console, which asks for a video of what
    // the recording's foreground service is for.
    if (Platform.isAndroid) expect(await deviceAction('film'), isNull);
    expect(await recording.start(noteId: 'standup'), isTrue);
    await tester.pump(const Duration(seconds: 2));
    await screenshot('recording-away-app', device: true);

    // Away. Nothing here pumps a frame until the app is back: a phone draws
    // none for an app out of sight, so a pump would wait for ever.
    final left = DateTime.now();
    Future<void> wait(int seconds) =>
        Future<void>.delayed(Duration(seconds: seconds));
    final locked = await deviceAction('lock') == null;
    if (!locked) expect(await deviceAction('other-app'), isNull);
    await wait(5);
    expect(recording.isRecording, isTrue, reason: 'stopped on the way out');

    if (locked) {
      await deviceAction('wake');
      await wait(3);
      await deviceShot('recording-away-lock-screen');
    }
    if (Platform.isAndroid) {
      expect(await deviceAction('shade'), isNull);
      await wait(3);
      await deviceShot('recording-away-shade');
      // The notification's own buttons, pressed as a person would. Its time
      // ticks every second, and the host reads a screen only once it has
      // stood still for one, so it is read paused: paused here in the app,
      // then resumed, paused and resumed again from the notification, where
      // Pause and Resume take turns in the same place.
      await recording.pause();
      await wait(3);
      await deviceShot('recording-away-shade-paused');
      expect(await deviceAction('tap:Resume'), isNull);
      await wait(3);
      expect(recording.session?.paused, isFalse, reason: 'Resume did nothing');
      expect(await deviceAction('tap-again'), isNull);
      await wait(3);
      expect(recording.session?.paused, isTrue, reason: 'Pause did nothing');
      expect(await deviceAction('tap:Resume'), isNull);
      await wait(3);
      expect(recording.session?.paused, isFalse, reason: 'Resume did nothing');
      await deviceAction('collapse');
    } else {
      // A host cannot press a Live Activity's buttons, so the app pauses for
      // the screenshot of what a pause looks like, on a light Lock Screen.
      await deviceAction('light');
      await recording.pause();
      await wait(3);
      if (locked) await deviceShot('recording-away-lock-screen-paused');
      await recording.resume();
      await deviceAction('dark');
      if (locked) await deviceAction('unlock');
      await wait(2);
      expect(await deviceAction('other-app'), isNull);
      await wait(3);
      await deviceShot('recording-away-dynamic-island');
      // For the run's log only: whether ActivityKit started the activity
      // and the widget extension drew it.
      await deviceAction('system-log');
    }

    final remaining = _away - DateTime.now().difference(left);
    if (remaining > Duration.zero) await Future<void>.delayed(remaining);
    expect(recording.isRecording, isTrue, reason: 'stopped while away');
    if (Platform.isAndroid) expect(await deviceAction('cut'), isNull);

    if (Platform.isAndroid) await deviceAction('unlock');
    expect(await deviceAction('back'), isNull);
    for (var i = 0; i < 60; i++) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        break;
      }
      await wait(1);
    }
    expect(
      WidgetsBinding.instance.lifecycleState,
      AppLifecycleState.resumed,
      reason: 'the app did not come back',
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(recording.isRecording, isTrue);
    expect(
      recording.session!.elapsed,
      greaterThanOrEqualTo(const Duration(minutes: 2)),
    );

    expect(refusals, isEmpty, reason: 'the phone would not show the recording');

    await recording.finishRecordingAndFlush();
    await tester.pumpAndSettle(const Duration(seconds: 1));
    final voice = notes.byId('standup')!.attachments.whereType<NoteVoiceRef>();
    expect(voice, hasLength(1), reason: 'the recording never reached its note');
    // Read off the file's own header: what was recorded, not what was timed.
    expect(
      voice.single.durationMs,
      greaterThanOrEqualTo(const Duration(minutes: 2).inMilliseconds),
    );
    await screenshot('recording-away-delivered', device: true);
  });
}
