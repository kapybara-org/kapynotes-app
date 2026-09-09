import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kapy_notes/core/device_memory.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/voice_prefs.dart';
import 'package:kapy_notes/speech/local_model_store.dart';
import 'package:kapy_notes/speech/local_models.dart';
import 'package:kapy_notes/ui/settings_dialog.dart';
import 'package:material_ui/material_ui.dart';

class MemoryStore extends LocalStore {
  MemoryStore() : super(fileName: 'summary-model-test.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
  @override
  void putNow(String key, Object? value) => data[key] = value;
}

late MemoryStore store;
late NotesStore notes;
late Directory temp;

Future<void> _openVoicePane(
  WidgetTester tester, {
  required LocalModelStore models,
  required VoicePrefs prefs,
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
              localModels: models,
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

/// The card sits below the fold of a pane that scrolls, so it has to be
/// brought into view before it can be pressed.
Future<void> _pressDownload(WidgetTester tester) async {
  final button = find.text('Download');
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    store = MemoryStore();
    notes = NotesStore(store);
    await notes.load();
    temp = Directory.systemTemp.createTempSync('summary-model');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
  });

  LocalModelStore summaryOnly() => LocalModelStore(
    catalogue: localSummaryModels,
    directory: temp,
    client: MockClient((_) async => fail('a card must fetch nothing')),
  );

  group('the summary model on its own shelf', () {
    testWidgets('says what it is and what it costs', (tester) async {
      final models = summaryOnly();
      addTearDown(models.dispose);

      await _openVoicePane(
        tester,
        models: models,
        prefs: VoicePrefs(store)..load(),
      );

      expect(find.text('SUMMARIES ON THIS DEVICE'), findsOneWidget);
      expect(find.text('Gemma 4 E2B'), findsOneWidget);
      expect(find.text('2.6 GB'), findsOneWidget);
      expect(find.text('2B effective parameters'), findsOneWidget);
      expect(find.text('4,096 tokens'), findsOneWidget);
      expect(find.text('of transcript at a time'), findsOneWidget);
      // The licence has to be named and reachable, not merely implied.
      expect(find.text('Apache-2.0'), findsOneWidget);
    });

    testWidgets('a recogniser-less build still promises transcription', (
      tester,
    ) async {
      final models = summaryOnly();
      addTearDown(models.dispose);

      await _openVoicePane(
        tester,
        models: models,
        prefs: VoicePrefs(store)..load(),
      );

      // The summary shelf being present must not silently drop the other one.
      expect(
        find.byKey(const ValueKey('voice-local-engine-row')),
        findsOneWidget,
      );
    });
  });

  group('agreeing to a licence', () {
    // Nothing we ship carries terms any more — Gemma 4 is Apache-2.0 — but a
    // model that does is one entry away, and the flow that stands between it
    // and a download is worth keeping honest.
    const restricted = LocalSummaryModel(
      id: 'restricted-model',
      name: 'Restricted Model',
      vendor: 'Somebody',
      parameters: '1B',
      quantisation: 'int4',
      contextTokens: 4096,
      license: 'Some Terms of Use',
      licenseUrl: 'https://example.com/terms',
      summary: 'A model with strings attached.',
      detail: 'Small print.',
      terms: ModelTerms(
        version: 1,
        summary: 'You agree to the terms by downloading this.',
        links: [
          (label: 'Prohibited Use Policy', url: 'https://example.com/policy'),
        ],
      ),
      minimumMemoryBytes: 0,
      files: [
        LocalModelFile(
          name: 'model.bin',
          url: 'https://models.test/model.bin',
          bytes: 1024,
          sha256: 'not-checked-here',
        ),
      ],
    );

    LocalModelStore restrictedStore() => LocalModelStore(
      catalogue: const [restricted],
      directory: temp,
      client: MockClient((_) async => fail('a refusal must fetch nothing')),
    );

    testWidgets('the download asks first, and cancelling stops it', (
      tester,
    ) async {
      final models = restrictedStore();
      addTearDown(models.dispose);
      final prefs = VoicePrefs(store)..load();

      await _openVoicePane(tester, models: models, prefs: prefs);
      await _pressDownload(tester);

      expect(find.byKey(const ValueKey('model-terms-dialog')), findsOneWidget);
      expect(find.textContaining('Prohibited Use Policy'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('model-terms-cancel')));
      await tester.pumpAndSettle();

      expect(prefs.hasAcceptedTerms(restricted.id, 1), isFalse);
      expect(models.stateOf(restricted).status, LocalModelStatus.absent);
    });

    testWidgets('agreeing is remembered, so it is asked once', (tester) async {
      final models = restrictedStore();
      addTearDown(models.dispose);
      final prefs = VoicePrefs(store)..load();

      await _openVoicePane(tester, models: models, prefs: prefs);
      await _pressDownload(tester);
      await tester.tap(find.byKey(const ValueKey('model-terms-accept')));
      await tester.pumpAndSettle();

      expect(prefs.hasAcceptedTerms(restricted.id, 1), isTrue);
    });

    testWidgets('a model with nothing to agree to just downloads', (
      tester,
    ) async {
      // The shipped one. Pressing Download must not put a dialog in the way.
      final models = LocalModelStore(
        catalogue: localSummaryModels,
        directory: temp,
        client: MockClient((_) async => http.Response('', 503)),
      );
      addTearDown(models.dispose);

      await _openVoicePane(
        tester,
        models: models,
        prefs: VoicePrefs(store)..load(),
      );
      await _pressDownload(tester);

      expect(find.byKey(const ValueKey('model-terms-dialog')), findsNothing);
    });

    test('raising the version asks again', () {
      final prefs = VoicePrefs(store)..load();
      prefs.acceptTerms('a-model', 1);

      expect(prefs.hasAcceptedTerms('a-model', 1), isTrue);
      // New wording, new question.
      expect(prefs.hasAcceptedTerms('a-model', 2), isFalse);
    });
  });

  group('memory', () {
    test('a machine that will not say is allowed to try', () async {
      // No /proc, no channel: Windows, in effect.
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.windows;
      expect(await DeviceMemory().total(), isNull);
    });

    test('linux reads its own /proc, in kibibytes', () async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.linux;
      final file = File('${temp.path}/meminfo')
        ..writeAsStringSync(
          'MemTotal:        8129412 kB\nMemFree:  1000 kB\n',
        );

      final total = await DeviceMemory(procMeminfo: file).total();

      expect(total, 8129412 * 1024);
    });

    test('a corrupt /proc is unknown, not zero', () async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.linux;
      final file = File('${temp.path}/meminfo')..writeAsStringSync('nonsense');

      expect(await DeviceMemory(procMeminfo: file).total(), isNull);
    });

    testWidgets('a device too small is told, and not offered the button', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
      TestWidgetsFlutterBinding.ensureInitialized();
      const channel = MethodChannel('kapynotes/summaries');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'physicalMemory') return 2 * 1000 * 1000 * 1000;
            return 'unsupported';
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      final models = summaryOnly();
      addTearDown(models.dispose);

      await _openVoicePane(
        tester,
        models: models,
        prefs: VoicePrefs(store)..load(),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('voice-local-model-blocked')),
        findsOneWidget,
      );
      expect(find.textContaining('this device has 2.0 GB'), findsOneWidget);
      // Nothing to press: the point is that the download never starts.
      expect(find.text('Download'), findsNothing);
    });
  });
}
