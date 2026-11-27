import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kapy_notes/audio/noise_removals.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/clean_copies.dart';
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
  MemoryStore() : super(fileName: 'local-engine-row-test.json');
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
  NoiseRemovals? noise,
  Size size = const Size(1000, 1400),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: KapyTheme.dark(),
      builder: noise == null
          ? null
          : (context, child) =>
                NoiseRemovalScope(notifier: noise, child: child!),
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
  license: 'MIT',
  licenseUrl: 'https://example.com/licence',
  summary: 'A model that does nothing.',
  languages: const ['English', 'French'],
  englishWordErrorRate: 1.5,
  speedFactor: 3,
  files: [
    for (final entry in files.entries)
      LocalModelFile(
        name: entry.key,
        urls: ['https://models.test/${entry.key}'],
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
    return http.StreamedResponse(
      _chunks(body),
      200,
      contentLength: body.length,
    );
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
    temp = Directory.systemTemp.createTempSync('kapy-engine-row');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
  });

  testWidgets('a build with no models still shows the shelf', (tester) async {
    await _openVoicePane(tester);

    expect(find.byKey(const ValueKey('local-transcription-line')), findsOne);
    expect(find.byKey(const ValueKey('local-summary-line')), findsOne);
    expect(find.text('Not available on this device'), findsNWidgets(2));
    expect(find.text('Speech model'), findsNothing);
    expect(find.text('Download'), findsNothing);
  });

  testWidgets('a model on offer names itself and what it costs', (
    tester,
  ) async {
    final models = LocalModelStore(
      catalogue: localSpeechModels,
      directory: temp,
      client: MockClient((_) async => fail('a row must fetch nothing')),
    );
    addTearDown(models.dispose);

    await _openVoicePane(tester, models: models);

    // The name and the size, which are the two anybody weighs, and the
    // attribution the licence asks for.
    expect(find.text('Speech model · 670 MB download'), findsOneWidget);
    expect(find.text('CC-BY-4.0'), findsOneWidget);
    expect(
      find.textContaining('Turns speech into text on this device'),
      findsOneWidget,
    );

    // Nothing downloaded yet, so this device cannot be chosen and the one
    // available action is to download its engine.
    expect(find.text('Download'), findsOneWidget);
    expect(_segment(tester, 'transcribe-with-device').enabled, isFalse);
  });

  testWidgets('the row fits the phone sheet as well as the dialog', (
    tester,
  ) async {
    // Rendering is the assertion: an overflow here is an exception the
    // framework fails the test on.
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    final models = LocalModelStore(
      catalogue: localSpeechModels,
      directory: temp,
      client: MockClient((_) async => fail('a row must fetch nothing')),
    );
    addTearDown(models.dispose);

    await _openVoicePane(tester, models: models, size: const Size(390, 844));

    expect(find.text('Download'), findsOneWidget);
  });

  testWidgets('downloading one shows progress and enables its choice', (
    tester,
  ) async {
    final bodies = {
      'encoder.onnx': Uint8List.fromList([
        for (var i = 0; i < 500; i++) i % 251,
      ]),
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

    await tester.tap(find.byKey(const ValueKey('local-download-tiny')));
    await _until(tester, () => server.firstChunk.isCompleted);

    // Mid-download the row says how far it has got and offers the way out.
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.textContaining(' of '), findsWidgets);

    server.release.complete();
    await _until(
      tester,
      () => models.stateOf(model).status == LocalModelStatus.ready,
    );

    // Downloaded makes this device one half of the engine choice.
    expect(find.text('Download'), findsNothing);
    expect(_segment(tester, 'transcribe-with-device').enabled, isTrue);
    // And 670 MB deserves a way back that is not a menu.
    expect(find.byKey(const ValueKey('local-remove-tiny')), findsOneWidget);
  });

  testWidgets('a download that fails says why and offers another go', (
    tester,
  ) async {
    final bodies = {
      'encoder.onnx': Uint8List.fromList([1, 2, 3, 4]),
    };
    final model = _tinyModel(bodies);
    final models = LocalModelStore(
      catalogue: [model],
      directory: temp,
      client: MockClient((_) async => http.Response('nope', 503)),
    );
    addTearDown(models.dispose);

    await _openVoicePane(tester, models: models);
    await tester.tap(find.byKey(const ValueKey('local-download-tiny')));
    await _until(
      tester,
      () => models.stateOf(model).status == LocalModelStatus.failed,
    );

    expect(
      find.byKey(const ValueKey('voice-local-model-error')),
      findsOneWidget,
    );
    expect(find.textContaining('503'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('noise removal for new recordings is a setting, off to start', (
    tester,
  ) async {
    final voicePrefs = VoicePrefs(store)..load();
    final noise = NoiseRemovals(
      models: LocalModelStore(directory: Directory('/tmp/kapy-no-such-dir')),
      prefs: voicePrefs,
      copies: CleanCopies(directory: Directory('/tmp/kapy-no-such-dir')),
      originals: (_) async => null,
      switched: (_) {},
    );
    addTearDown(noise.dispose);
    await _openVoicePane(tester, voicePrefs: voicePrefs, noise: noise);

    expect(find.text('Always remove noise from recordings'), findsOneWidget);
    expect(
      find.text('From each new recording. Your original is kept'),
      findsOneWidget,
    );
    expect(voicePrefs.removeNoise, isFalse);

    await tester.tap(find.byKey(const ValueKey('voice-remove-noise-toggle')));
    await tester.pump();
    expect(voicePrefs.removeNoise, isTrue);
  });

  testWidgets('a build that cannot remove noise does not offer it', (
    tester,
  ) async {
    await _openVoicePane(tester);
    expect(find.text('Always remove noise from recordings'), findsNothing);
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
