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

import '../kapy_icon_finder.dart';

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

      // The row is always there, because the section is where you look to find
      // out whether this machine can do it. Its choice is disabled here.
      expect(find.byKey(const ValueKey('local-transcription-row')), findsOne);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('local-transcription-row')),
          matching: find.text('Not something this device can do yet'),
        ),
        findsOneWidget,
      );
      expect(_choiceIn(tester, 'local-transcription-row'), isFalse);
    });

    testWidgets('an engine that is here is one of two visible choices', (
      tester,
    ) async {
      final prefs = VoicePrefs(store)..load();
      await _openVoicePane(
        tester,
        prefs: prefs,
        deviceTranscriber: _Fake(TranscriberReadiness.ready),
      );

      expect(find.text('Cloud transcription'), findsOneWidget);
      expect(find.text('Local transcription'), findsOneWidget);
      expect(
        find.text('Built into this device, and never uploaded'),
        findsOneWidget,
      );
      expect(_choiceIn(tester, 'cloud-transcription-row'), isFalse);
      expect(_choiceIn(tester, 'local-transcription-row'), isFalse);
    });

    testWidgets('signed out can choose only local transcription', (
      tester,
    ) async {
      final prefs = VoicePrefs(store)..load();
      var readyCalls = 0;
      await _openVoicePane(
        tester,
        prefs: prefs,
        deviceTranscriber: _Fake(TranscriberReadiness.ready),
        onTranscriptionReady: () => readyCalls++,
      );

      await tester.tap(find.byKey(const ValueKey('local-transcription-row')));
      await tester.pumpAndSettle();

      expect(prefs.transcriptEngine, TranscriptEngine.device);
      expect(readyCalls, 1);
      expect(_choiceIn(tester, 'local-transcription-row'), isTrue);
      expect(_choiceIn(tester, 'cloud-transcription-row'), isFalse);

      // A radio choice does not turn itself off, and the cloud row cannot be
      // selected without an account.
      await tester.tap(find.byKey(const ValueKey('local-transcription-row')));
      await tester.pumpAndSettle();
      expect(prefs.transcriptEngine, TranscriptEngine.device);
      expect(readyCalls, 1);

      await tester.tap(find.byKey(const ValueKey('cloud-transcription-row')));
      await tester.pumpAndSettle();
      expect(prefs.transcriptEngine, TranscriptEngine.device);
      expect(readyCalls, 1);
    });

    testWidgets('a device still fetching its language says which', (
      tester,
    ) async {
      await _openVoicePane(
        tester,
        prefs: VoicePrefs(store)..load(),
        deviceTranscriber: _Fake(TranscriberReadiness.preparing),
      );

      expect(find.text('Still fetching the language it needs'), findsOneWidget);
      expect(_choiceIn(tester, 'local-transcription-row'), isFalse);
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
        find.text(
          'Allow speech recognition for Kapy Notes in Privacy settings',
        ),
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
        find.text('Sign in first for cloud transcription and summaries'),
        findsOneWidget,
      );
      expect(find.text('Local transcription'), findsOneWidget);
    });
  });
}

/// Whether an engine row's mutually exclusive choice is selected.
bool _choiceIn(WidgetTester tester, String rowKey) {
  final checked = find.descendant(
    of: find.byKey(ValueKey(rowKey)),
    matching: findKapyIcon(KapyIcons.radioCheckedRounded),
  );
  return checked.evaluate().isNotEmpty;
}
