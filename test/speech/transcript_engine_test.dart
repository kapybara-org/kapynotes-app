import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/voice_prefs.dart';
import 'package:kapy_notes/speech/summarizer.dart';
import 'package:kapy_notes/speech/transcriber.dart';
import 'package:kapy_notes/ui/settings_dialog.dart';
import 'package:material_ui/material_ui.dart';

/// A store that keeps what it is given, in memory.
class _MemoryStore extends LocalStore {
  _MemoryStore({super.fileName = 'transcript-engine-test.json'});

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;

  @override
  void putNow(String key, Object? value) => data[key] = value;
}

/// A transcriber that answers whatever the test needs it to.
class _Fake implements Transcriber {
  _Fake(this.state);

  final TranscriberReadiness state;

  @override
  Future<TranscriberReadiness> readiness() async => state;

  @override
  Future<TranscriptDraft> transcribe({
    required File audio,
    required String requestId,
    String? language,
  }) async => throw UnimplementedError();
}

late LocalStore store;
late NotesStore notes;

Future<void> _openVoicePane(
  WidgetTester tester, {
  required VoicePrefs prefs,
  Transcriber? deviceTranscriber,
}) async {
  tester.view.physicalSize = const Size(1000, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: KapyTheme.dark(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSettings(
              context,
              layoutPrefs: LayoutPrefs(store)..load(),
              shortcuts: ShortcutPrefs(store)..load(),
              rates: RatesRepository(store),
              notes: notes,
              voicePrefs: prefs,
              deviceTranscriber: deviceTranscriber,
              section: SettingsSection.voice,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() async {
    store = _MemoryStore();
    notes = NotesStore(_MemoryStore(fileName: 'notes.json'));
    await notes.load();
  });

  group('the setting itself', () {
    test('the cloud is the default, because it is the one that always is', () {
      expect(
        (VoicePrefs(_MemoryStore())..load()).transcriptEngine,
        TranscriptEngine.cloud,
      );
    });

    test('a choice outlives the launch that made it', () {
      final store = _MemoryStore();
      (VoicePrefs(store)..load()).transcriptEngine = TranscriptEngine.device;

      expect(
        (VoicePrefs(store)..load()).transcriptEngine,
        TranscriptEngine.device,
      );
    });

    test('a corrupt record reads as the cloud rather than throwing', () {
      final store = _MemoryStore();
      store.data['voice.transcriptEngine.v1'] = 42;

      expect(
        (VoicePrefs(store)..load()).transcriptEngine,
        TranscriptEngine.cloud,
      );
    });

    test('the two engines are chosen separately', () async {
      // Transcribing here and summarising in the cloud is an ordinary
      // setting, and so is the reverse.
      final prefs = VoicePrefs(_MemoryStore())..load();
      prefs.transcriptEngine = TranscriptEngine.device;

      expect(prefs.summaryEngine, SummaryEngine.cloud);
    });
  });

  group('the voice pane', () {
    testWidgets('a build with no device engine does not offer one', (
      tester,
    ) async {
      await _openVoicePane(tester, prefs: VoicePrefs(store)..load());

      expect(find.text('Where recordings are transcribed'), findsNothing);
    });

    testWidgets('the row says where the words are made', (tester) async {
      await _openVoicePane(
        tester,
        prefs: VoicePrefs(store)..load(),
        deviceTranscriber: _Fake(TranscriberReadiness.ready),
      );

      expect(find.text('Where recordings are transcribed'), findsOneWidget);
      expect(
        find.text('Sent to our server, and billed to your minutes'),
        findsOneWidget,
      );
    });

    testWidgets('choosing this device is kept, and explained', (tester) async {
      final prefs = VoicePrefs(store)..load();
      await _openVoicePane(
        tester,
        prefs: prefs,
        deviceTranscriber: _Fake(TranscriberReadiness.ready),
      );

      await tester.tap(find.byKey(const ValueKey('voice-transcript-engine-row')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('transcript-engine-device')));
      await tester.pumpAndSettle();

      expect(prefs.transcriptEngine, TranscriptEngine.device);
      expect(find.text('Made here, and never uploaded'), findsOneWidget);
    });

    testWidgets('a device that needs the model says so, not just "no"', (
      tester,
    ) async {
      final prefs = VoicePrefs(store)..load();
      prefs.transcriptEngine = TranscriptEngine.device;

      await _openVoicePane(
        tester,
        prefs: prefs,
        deviceTranscriber: _Fake(TranscriberReadiness.needsDownload),
      );

      expect(
        find.text('Download the speech model below first'),
        findsOneWidget,
      );
    });

    testWidgets('a device that cannot at all says that instead', (
      tester,
    ) async {
      final prefs = VoicePrefs(store)..load();
      prefs.transcriptEngine = TranscriptEngine.device;

      await _openVoicePane(
        tester,
        prefs: prefs,
        deviceTranscriber: _Fake(TranscriberReadiness.unsupported),
      );

      expect(
        find.text('Nothing on this device can transcribe yet'),
        findsOneWidget,
      );
    });

    testWidgets('signing in stops being the only way once this device can', (
      tester,
    ) async {
      await _openVoicePane(
        tester,
        prefs: VoicePrefs(store)..load(),
        deviceTranscriber: _Fake(TranscriberReadiness.ready),
      );

      expect(
        find.text('Sign in, or transcribe on this device below'),
        findsOneWidget,
      );
      expect(
        find.text('Sign in to turn recordings into text'),
        findsNothing,
        reason: 'it would be false on a machine that can do it alone',
      );
    });
  });
}
