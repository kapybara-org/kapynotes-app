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
    testWidgets('a build with nothing local says so rather than nothing', (
      tester,
    ) async {
      await _openVoicePane(tester, prefs: VoicePrefs(store)..load());

      // The row is always there — the section is where you look to find out
      // whether this machine can do it — but there is no switch to move.
      expect(find.byKey(const ValueKey('local-transcription-row')), findsOne);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('local-transcription-row')),
          matching: find.text('Not something this device can do yet'),
        ),
        findsOneWidget,
      );
      expect(_switchIn(tester, 'local-transcription-row'), isNull);
    });

    testWidgets('an engine that is here is a switch, not a picker', (
      tester,
    ) async {
      final prefs = VoicePrefs(store)..load();
      await _openVoicePane(
        tester,
        prefs: prefs,
        deviceTranscriber: _Fake(TranscriberReadiness.ready),
      );

      // The question the two pickers used to ask, in the one place the answer
      // can be seen without opening anything.
      expect(find.text('Where recordings are transcribed'), findsNothing);
      expect(
        find.text('Built into this device, and never uploaded'),
        findsOneWidget,
      );
      expect(_switchIn(tester, 'local-transcription-row'), isFalse);
    });

    testWidgets('switching it on is the whole of the choice', (tester) async {
      final prefs = VoicePrefs(store)..load();
      await _openVoicePane(
        tester,
        prefs: prefs,
        deviceTranscriber: _Fake(TranscriberReadiness.ready),
      );

      await tester.tap(find.byKey(const ValueKey('local-transcription-row')));
      await tester.pumpAndSettle();

      expect(prefs.transcriptEngine, TranscriptEngine.device);
      expect(_switchIn(tester, 'local-transcription-row'), isTrue);

      // And off again sends it back to the cloud, which is the other half of
      // what the picker used to do.
      await tester.tap(find.byKey(const ValueKey('local-transcription-row')));
      await tester.pumpAndSettle();
      expect(prefs.transcriptEngine, TranscriptEngine.cloud);
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
      expect(_switchIn(tester, 'local-transcription-row'), isNull);
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

    testWidgets('signing in stops being the only way once this device can', (
      tester,
    ) async {
      await _openVoicePane(
        tester,
        prefs: VoicePrefs(store)..load(),
        deviceTranscriber: _Fake(TranscriberReadiness.ready),
      );

      expect(
        find.text('Sign in, or switch this device on below'),
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

/// The switch inside a local engine row, or null when the row has none —
/// which is how "this machine cannot" is said.
bool? _switchIn(WidgetTester tester, String rowKey) {
  final indicator = find.descendant(
    of: find.byKey(ValueKey(rowKey)),
    matching: find.byKey(const ValueKey('compact-switch-indicator')),
  );
  if (indicator.evaluate().isEmpty) return null;
  return tester
      .widget<Semantics>(
        find
            .ancestor(
              of: indicator,
              matching: find.byWidgetPredicate(
                (w) => w is Semantics && w.properties.toggled != null,
              ),
            )
            .first,
      )
      .properties
      .toggled;
}
