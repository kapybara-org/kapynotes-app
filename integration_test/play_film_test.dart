// Scratch, never merged: films, for the Play Console's foreground-service
// declaration, a person starting a voice recording in a note with their own
// touches, then locking the phone and using the recording's notification:
// unfolding it, Pause, Resume and Stop, and finding the recording in the
// note once the phone is unlocked. Run by tool/ci/play_film.sh.
//
// The notification's time ticks every second, and the host reads a screen
// only once it has stood still for one, so where its arrow and buttons sit is
// read first in an unfilmed rehearsal, with the recording paused.
import 'dart:io';

import 'package:flutter/material.dart';
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
import 'package:kapy_notes/ui/editor/note_field.dart'
    show NoteField, NoteFieldState;

import 'rates_support.dart';
import 'screenshot.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'play-film-integration.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a person records a voice note and uses its notification', (
    tester,
  ) async {
    if (!hostReadsScreens || !Platform.isAndroid) {
      markTestSkipped('Films on an Android emulator under its host.');
      return;
    }
    expect(await deviceAction('grant'), isNull, reason: 'the microphone');

    final temp = await Directory.systemTemp.createTemp('kapy-film');
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

    Future<void> wait(num seconds) =>
        Future<void>.delayed(Duration(milliseconds: (seconds * 1000).round()));
    Future<void> backInFront() async {
      for (var i = 0; i < 30; i++) {
        if (WidgetsBinding.instance.lifecycleState ==
            AppLifecycleState.resumed) {
          return;
        }
        await wait(1);
      }
      fail('the app did not come back');
    }

    // Rehearsal, unfilmed: the notification folded on the lock screen, its
    // arrow, then unfolded, its buttons.
    expect(await recording.start(noteId: 'standup'), isTrue);
    await recording.pause();
    await wait(2);
    expect(await deviceAction('lock'), isNull);
    await wait(2);
    expect(await deviceAction('wake'), isNull);
    await wait(2);
    expect(await deviceAction('find-arrow:Recording paused'), isNull);
    expect(await deviceAction('press:Recording paused'), isNull);
    await wait(3);
    expect(await deviceAction('find:Resume'), isNull);
    expect(await deviceAction('find:Stop'), isNull);
    expect(await deviceAction('collapse'), isNull);
    expect(await deviceAction('unlock'), isNull);
    await recording.cancel();
    await backInFront();
    await tester.pumpAndSettle(const Duration(seconds: 1));
    final home = find.byKey(const ValueKey('page-home'));
    if (home.evaluate().isNotEmpty) {
      await tester.tap(home);
      await tester.pumpAndSettle(const Duration(seconds: 1));
    }
    expect(home, findsNothing, reason: 'not on Home');
    expect(notes.byId('standup')!.attachments, isEmpty);

    // The take: every touch is the emulator's own, drawn as a dot.
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    binding.shouldPropagateDevicePointerEvents = true;
    addTearDown(() {
      binding.shouldPropagateDevicePointerEvents = false;
      binding.framePolicy =
          LiveTestWidgetsFlutterBindingFramePolicy.fadePointers;
    });
    final ratio = tester.view.devicePixelRatio;
    Future<void> touch(Offset at, {bool hold = false}) async {
      final x = (at.dx * ratio).round();
      final y = (at.dy * ratio).round();
      final kind = hold ? 'hold' : 'touch';
      expect(await deviceAction('$kind:$x,$y'), isNull);
    }

    expect(await deviceAction('film'), isNull);
    await wait(2.5);
    await touch(tester.getCenter(find.text('Standup').first));
    await wait(2.5);
    expect(home, findsOneWidget, reason: 'the note did not open');

    final fieldFinder = find.byType(NoteField);
    final field = tester.widget<NoteField>(fieldFinder);
    final said = field.controller.text.indexOf('What we said');
    expect(said, isNot(-1), reason: 'the note opened without its text');
    final caret = tester
        .state<NoteFieldState>(fieldFinder)
        .caretRectAt(TextPosition(offset: said + 'What we said'.length))!;
    final line =
        tester.getRect(fieldFinder).top +
        caret.center.dy -
        field.scrollController.offset;
    final width = tester.view.physicalSize.width / ratio;
    await touch(Offset(width * 0.8, line), hold: true);
    await wait(1.5);
    var record = find.text('Record voice note');
    if (record.evaluate().isEmpty) {
      final more = find.byTooltip('More');
      expect(more, findsOneWidget, reason: 'no Record voice note, no More');
      await touch(tester.getCenter(more));
      await wait(1.2);
      record = find.text('Record voice note');
    }
    expect(record, findsOneWidget);
    await deviceShot('play-film-menu');
    await touch(tester.getCenter(record));
    await wait(1.5);
    expect(recording.isRecording, isTrue, reason: 'nothing recorded');
    await wait(4);

    expect(await deviceAction('lock'), isNull);
    await wait(3);
    expect(await deviceAction('wake'), isNull);
    await wait(2.5);
    expect(await deviceAction('press:Recording paused'), isNull);
    await wait(2.5);
    expect(await deviceAction('press:Resume'), isNull);
    await wait(3);
    expect(recording.session?.paused, isTrue, reason: 'Pause did nothing');
    expect(await deviceAction('press:Resume'), isNull);
    await wait(3);
    expect(recording.session?.paused, isFalse, reason: 'Resume did nothing');
    expect(await deviceAction('press:Stop'), isNull);
    await wait(3);
    expect(recording.isRecording, isFalse, reason: 'Stop did nothing');
    expect(await deviceAction('unlock'), isNull);
    await backInFront();
    await wait(4);
    expect(await deviceAction('cut'), isNull);

    final voice = notes.byId('standup')!.attachments.whereType<NoteVoiceRef>();
    expect(voice, hasLength(1), reason: 'the recording never reached its note');
    await deviceShot('play-film-end');
  });
}
