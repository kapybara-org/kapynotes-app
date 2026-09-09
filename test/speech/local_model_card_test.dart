import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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
  MemoryStore() : super(fileName: 'local-model-card-test.json');
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
late LayoutPrefs prefs;
late ShortcutPrefs shortcuts;
late Directory temp;

/// Opens settings straight onto the voice pane, on a desktop-shaped window.
Future<void> _openVoicePane(
  WidgetTester tester, {
  LocalModelStore? models,
  VoicePrefs? voicePrefs,
  Size size = const Size(1000, 1400),
}) async {
  tester.view.physicalSize = size;
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
              layoutPrefs: prefs,
              shortcuts: shortcuts,
              rates: RatesRepository(store),
              notes: notes,
              voicePrefs: voicePrefs ?? (VoicePrefs(store)..load()),
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

/// A model whose files are a few hundred bytes, so a test can download one.
LocalSpeechModel _tinyModel(Map<String, List<int>> files) => LocalSpeechModel(
  id: 'tiny',
  name: 'Tiny Model',
  vendor: 'Nobody',
  parameters: '1M',
  architecture: 'None',
  license: 'MIT',
  licenseUrl: 'https://example.com/licence',
  summary: 'A model that does nothing.',
  languages: const ['English', 'French'],
  englishWordErrorRate: 1.5,
  multilingualWordErrorRate: 2.5,
  accuracySource: 'nowhere at all',
  speedFactor: 3,
  speedSource: 'nothing in particular',
  files: [
    for (final entry in files.entries)
      LocalModelFile(
        name: entry.key,
        url: 'https://models.test/${entry.key}',
        bytes: entry.value.length,
        sha256: sha256.convert(entry.value).toString(),
      ),
  ],
);

/// Serves a body one chunk at a time, and can be held open between chunks so
/// a test can look at the card mid-download.
class _GatedServer {
  _GatedServer(this.bodies);

  final Map<String, List<int>> bodies;
  final Completer<void> firstChunk = Completer<void>();
  final Completer<void> release = Completer<void>();

  http.Client get client => MockClient.streaming((request, _) async {
    final body = bodies[request.url.pathSegments.last]!;
    return http.StreamedResponse(_chunks(body), 200, contentLength: body.length);
  });

  Stream<List<int>> _chunks(List<int> body) async* {
    const size = 64;
    for (var at = 0; at < body.length; at += size) {
      final end = at + size > body.length ? body.length : at + size;
      yield body.sublist(at, end);
      if (!firstChunk.isCompleted) {
        firstChunk.complete();
        await release.future;
      }
    }
  }
}

/// Runs a download that a button press started, to completion.
///
/// It has to alternate two clocks. The work is real file and network I/O,
/// which only moves inside [WidgetTester.runAsync]; but it was started inside
/// the test's fake zone, whose microtasks only drain on a pump. Polling in
/// either one alone hangs forever.
Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var attempt = 0; attempt < 600; attempt++) {
    await tester.pump(const Duration(milliseconds: 5));
    if (done()) {
      await tester.pumpAndSettle();
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  fail('timed out waiting');
}

void main() {
  setUp(() async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    store = MemoryStore();
    notes = NotesStore(store);
    await notes.load();
    prefs = LayoutPrefs(store)..load();
    shortcuts = ShortcutPrefs(store)..load();
    temp = Directory.systemTemp.createTempSync('kapy-model-card');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
  });

  testWidgets('a build with no models keeps the promise it made', (
    tester,
  ) async {
    await _openVoicePane(tester);

    expect(find.text('ON THIS DEVICE'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('voice-local-engine-row')),
      findsOneWidget,
    );
    expect(find.text('Parakeet TDT 0.6B v3'), findsNothing);
  });

  testWidgets('the card answers what a 670 MB decision turns on', (
    tester,
  ) async {
    final models = LocalModelStore(
      catalogue: localSpeechModels,
      directory: temp,
      client: MockClient((_) async => fail('a card must fetch nothing')),
    );
    addTearDown(models.dispose);

    await _openVoicePane(tester, models: models);

    expect(find.text('Parakeet TDT 0.6B v3'), findsOneWidget);

    // The four numbers, each with what it means beside it.
    expect(find.text('670 MB'), findsOneWidget);
    expect(find.text('to download'), findsOneWidget);
    expect(find.text('25 languages'), findsOneWidget);
    expect(find.text('multilingual'), findsOneWidget);
    expect(find.text('6.3% errors'), findsOneWidget);
    expect(find.text('transcribing English'), findsOneWidget);
    expect(find.text('9× real time'), findsOneWidget);
    expect(find.text('on a laptop CPU'), findsOneWidget);

    // Which languages, not merely how many.
    expect(
      find.textContaining('Ukrainian', findRichText: true),
      findsWidgets,
    );

    // Where the figures came from, and the attribution the licence requires.
    expect(find.textContaining('as published by NVIDIA'), findsNothing);
    expect(find.textContaining('Open ASR Leaderboard'), findsOneWidget);
    expect(find.textContaining('a phone is slower'), findsOneWidget);
    expect(find.text('CC-BY-4.0'), findsOneWidget);
    expect(find.textContaining('600M parameters'), findsOneWidget);

    // Nothing has been downloaded, so there is one thing to do.
    expect(find.text('Download'), findsOneWidget);
  });

  testWidgets('the card fits the phone sheet as well as the dialog', (
    tester,
  ) async {
    // The stats are two to a row, and a phone gives each column about half of
    // 390 logical pixels. Rendering is the assertion: an overflow here is an
    // exception the framework fails the test on.
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    final models = LocalModelStore(
      catalogue: localSpeechModels,
      directory: temp,
      client: MockClient((_) async => fail('a card must fetch nothing')),
    );
    addTearDown(models.dispose);

    await _openVoicePane(tester, models: models, size: const Size(390, 844));

    expect(find.text('Parakeet TDT 0.6B v3'), findsOneWidget);
    expect(find.text('670 MB'), findsOneWidget);
    expect(find.text('9× real time'), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);
  });

  testWidgets('downloading one shows progress and ends in Remove', (
    tester,
  ) async {
    final bodies = {
      'encoder.onnx': Uint8List.fromList([for (var i = 0; i < 500; i++) i % 251]),
    };
    final model = _tinyModel(bodies);
    final server = _GatedServer(bodies);
    final models = LocalModelStore(
      catalogue: [model],
      directory: temp,
      client: server.client,
    );
    addTearDown(models.dispose);

    await _openVoicePane(tester, models: models);
    expect(find.text('Download'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('voice-local-model-action-tiny')));
    await _until(tester, () => server.firstChunk.isCompleted);

    // Mid-download the card says how far it has got and offers the way out.
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.textContaining(' of '), findsWidgets);

    server.release.complete();
    await _until(
      tester,
      () => models.stateOf(model).status == LocalModelStatus.ready,
    );

    expect(find.text('Remove'), findsOneWidget);
    expect(find.text('Download'), findsNothing);
  });

  testWidgets('a download that fails says why and offers another go', (
    tester,
  ) async {
    final bodies = {'encoder.onnx': Uint8List.fromList([1, 2, 3, 4])};
    final model = _tinyModel(bodies);
    final models = LocalModelStore(
      catalogue: [model],
      directory: temp,
      client: MockClient((_) async => http.Response('nope', 503)),
    );
    addTearDown(models.dispose);

    await _openVoicePane(tester, models: models);
    await tester.tap(find.byKey(const ValueKey('voice-local-model-action-tiny')));
    await _until(
      tester,
      () => models.stateOf(model).status == LocalModelStatus.failed,
    );

    expect(find.byKey(const ValueKey('voice-local-model-error')), findsOneWidget);
    expect(find.textContaining('503'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });
}
