import 'dart:io';

import 'package:flutter/semantics.dart';
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
  VoidCallback? onTranscriptionReady,
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
              onTranscriptionReady: onTranscriptionReady,
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
    testWidgets('a build with nothing local says so rather than nothing', (
      tester,
    ) async {
      await _openVoicePane(tester, prefs: VoicePrefs(store)..load());

      // The line is always there, because it is where you look to find out
      // whether this machine can do it. Its half of the choice is dimmed.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('local-transcription-line')),
          matching: find.text('Not available on this device'),
        ),
        findsOneWidget,
      );
      expect(_segment(tester, 'transcribe-with-device').enabled, isFalse);
    });

    testWidgets('an engine that is here is one half of the choice', (
      tester,
    ) async {
      await _openVoicePane(
        tester,
        prefs: VoicePrefs(store)..load(),
        deviceTranscriber: _Fake(TranscriberReadiness.ready),
      );

      expect(_segment(tester, 'transcribe-with-device').enabled, isTrue);
      // Signed out, what runs is this device, said as the choice.
      expect(_segment(tester, 'transcribe-with-device').selected, isTrue);
      expect(_segment(tester, 'transcribe-with-cloud').selected, isFalse);
      // A built-in engine needs no download, so there is no line about one.
      expect(
        find.byKey(const ValueKey('local-transcription-line')),
        findsNothing,
      );
    });

    testWidgets('signed out can choose only this device', (tester) async {
      final prefs = VoicePrefs(store)..load();
      var readyCalls = 0;
      await _openVoicePane(
        tester,
        prefs: prefs,
        deviceTranscriber: _Fake(TranscriberReadiness.ready),
        onTranscriptionReady: () => readyCalls++,
      );
      expect(prefs.transcriptEngine, TranscriptEngine.cloud);

      // Shown as chosen already, because the cloud cannot run signed out,
      // so a tap on it changes nothing.
      await tester.tap(find.byKey(const ValueKey('transcribe-with-device')));
      await tester.pumpAndSettle();
      expect(prefs.transcriptEngine, TranscriptEngine.cloud);
      expect(readyCalls, 0);

      expect(_segment(tester, 'transcribe-with-cloud').enabled, isFalse);
      await tester.tap(find.byKey(const ValueKey('transcribe-with-cloud')));
      await tester.pumpAndSettle();
      expect(prefs.transcriptEngine, TranscriptEngine.cloud);
      expect(readyCalls, 0);
    });

    testWidgets('a device still fetching its language says which', (
      tester,
    ) async {
      await _openVoicePane(
        tester,
        prefs: VoicePrefs(store)..load(),
        deviceTranscriber: _Fake(TranscriberReadiness.preparing),
      );

      expect(find.text('Preparing language support'), findsOneWidget);
      expect(_segment(tester, 'transcribe-with-device').enabled, isFalse);
    });

    testWidgets('a permission that was never given names itself', (
      tester,
    ) async {
      await _openVoicePane(
        tester,
        prefs: VoicePrefs(store)..load(),
        deviceTranscriber: _Fake(TranscriberReadiness.needsSystemFeature),
      );

      expect(
        find.text('Allow Speech Recognition in system settings'),
        findsOneWidget,
      );
    });

    testWidgets('signed out cloud says what needs an account', (tester) async {
      await _openVoicePane(
        tester,
        prefs: VoicePrefs(store)..load(),
        deviceTranscriber: _Fake(TranscriberReadiness.ready),
      );

      expect(
        find.text('Cloud needs you signed in. This device works offline'),
        findsOneWidget,
      );
    });

    testWidgets('offers no choice of cloud model', (tester) async {
      await _openVoicePane(tester, prefs: VoicePrefs(store)..load());

      expect(find.textContaining('Soniox'), findsNothing);
      expect(find.textContaining('NVIDIA'), findsNothing);
    });
  });
}

/// What a segment of an engine choice says about itself.
SemanticsProperties _segment(WidgetTester tester, String key) => tester
    .widget<Semantics>(
      find
          .ancestor(
            of: find.byKey(ValueKey(key)),
            matching: find.byType(Semantics),
          )
          .first,
    )
    .properties;
