import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kapy_notes/audio/audio_decode.dart';
import 'package:kapy_notes/audio/noise_removal.dart';
import 'package:kapy_notes/audio/noise_removals.dart';
import 'package:kapy_notes/data/clean_copies.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/voice_prefs.dart';
import 'package:kapy_notes/speech/local_model_store.dart';
import 'package:kapy_notes/speech/local_models.dart';

/// A graph with DPDFNet-2's inputs and outputs that passes frames straight
/// through, standing in for the 10 MB model.
final List<int> weights = File(
  'packages/denoise/test/identity.onnx',
).readAsBytesSync();

final String hash = 'cd' * 32;

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'noise-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;

  @override
  void putNow(String key, Object? value) => data[key] = value;
}

class _Decoder extends AudioDecoder {
  _Decoder(this.dir);

  final Directory dir;

  @override
  Future<DecodedAudio> decode(File source, {int sampleRate = 16000}) async {
    final random = Random(3);
    final samples = Int16List.fromList([
      for (var i = 0; i < 16000; i++)
        (4000 * (random.nextDouble() - 0.5)).round(),
    ]);
    final file = await File(
      '${dir.path}/decoded-${source.uri.pathSegments.last}.pcm',
    ).writeAsBytes(samples.buffer.asUint8List());
    return DecodedAudio(file: file, sampleRate: sampleRate, frames: 16000);
  }
}

void main() {
  late Directory dir;
  late VoicePrefs prefs;
  late CleanCopies copies;
  late List<String> switched;
  late int fetches;
  late bool offline;
  late Completer<void>? encodeGate;
  late Completer<void>? downloadGate;
  late bool noSpace;
  File? original;

  final model = LocalSpeechModel(
    id: 'noise-test',
    name: 'Noise',
    vendor: 'Nobody',
    license: 'Apache-2.0',
    licenseUrl: 'https://example.test/licence',
    summary: '',
    languages: const [],
    englishWordErrorRate: 0,
    speedFactor: 1,
    files: [
      LocalModelFile(
        name: 'model.onnx',
        urls: const ['https://models.test/model.onnx'],
        bytes: weights.length,
        sha256: sha256.convert(weights).toString(),
      ),
    ],
  );

  NoiseRemovals build() {
    final noise = NoiseRemovals(
      models: LocalModelStore(
        catalogue: [model],
        directory: Directory('${dir.path}/models'),
        client: MockClient((request) async {
          fetches++;
          if (offline) throw http.ClientException('offline');
          await downloadGate?.future;
          return http.Response.bytes(weights, 200);
        }),
      ),
      model: model,
      prefs: prefs,
      copies: copies,
      originals: (_) async => original,
      switched: switched.add,
      remover: NoiseRemover(
        copies: copies,
        decoder: _Decoder(dir),
        encode: (pcm, destination) async {
          await encodeGate?.future;
          if (noSpace) {
            throw const FileSystemException('No space left on device');
          }
          await pcm.copy(destination.path);
        },
      ),
    );
    addTearDown(noise.dispose);
    return noise;
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('kapy-noise');
    prefs = VoicePrefs(_MemoryStore())..load();
    copies = CleanCopies(directory: Directory('${dir.path}/voice-clean'));
    switched = [];
    fetches = 0;
    offline = false;
    encodeGate = null;
    downloadGate = null;
    noSpace = false;
    original = await File('${dir.path}/original.m4a').writeAsString('m4a');
  });
  tearDown(() => dir.delete(recursive: true));

  test(
    'the first press fetches the model, makes the copy and plays it',
    () async {
      final noise = build();
      expect(noise.stateOf(hash).stage, NoiseStage.off);

      final stages = <NoiseStage>{};
      noise.addListener(() => stages.add(noise.stateOf(hash).stage));
      expect(await noise.turnOn(hash), isNull);

      expect(
        stages,
        containsAll([NoiseStage.downloading, NoiseStage.removing]),
      );
      expect(noise.stateOf(hash).stage, NoiseStage.on);
      expect(fetches, 1);
      expect(switched, [hash]);
      expect(
        (await noise.playable(hash))?.path,
        (await copies.fileFor(hash)).path,
      );
      expect(await original!.readAsString(), 'm4a', reason: 'only ever read');
    },
  );

  test('off plays the original and on again is instant', () async {
    final noise = build();
    await noise.turnOn(hash);

    noise.turnOff(hash);
    expect(noise.stateOf(hash).stage, NoiseStage.off);
    expect(await noise.playable(hash), isNull);
    expect(prefs.isNoiseOff(hash), isTrue);

    final copy = await copies.fileFor(hash);
    final written = await copy.lastModified();
    expect(await noise.turnOn(hash), isNull);
    expect(noise.stateOf(hash).stage, NoiseStage.on);
    expect(await copy.lastModified(), written, reason: 'not made again');
    expect(fetches, 1);
    expect(switched, [hash, hash, hash]);
  });

  test('a second recording reuses the model', () async {
    final noise = build();
    await noise.turnOn(hash);
    await noise.turnOn('ef' * 32);
    expect(fetches, 1);
  });

  test('stop leaves the recording as it was', () async {
    final noise = build();
    encodeGate = Completer();
    final done = noise.turnOn(hash);
    await pumpUntil(() => noise.stateOf(hash).stage == NoiseStage.removing);

    noise.stop(hash);
    encodeGate!.complete();
    expect(await done, isNull);

    expect(noise.stateOf(hash).stage, NoiseStage.off);
    expect(await copies.existing(hash), isNull);
    expect(switched, isEmpty);
  });

  test('says so when the model cannot be fetched, and can try again', () async {
    offline = true;
    final noise = build();
    expect(await noise.turnOn(hash), NoiseProblem.couldNotDownload);
    expect(noise.stateOf(hash).stage, NoiseStage.off);

    offline = false;
    expect(await noise.turnOn(hash), isNull);
    expect(noise.stateOf(hash).stage, NoiseStage.on);
  });

  test('stop while the model downloads says nothing went wrong', () async {
    downloadGate = Completer();
    final noise = build();
    final done = noise.turnOn(hash);
    await pumpUntil(() => noise.stateOf(hash).stage == NoiseStage.downloading);
    noise.stop(hash);
    downloadGate!.complete();
    expect(await done, isNull);
    expect(noise.stateOf(hash).stage, NoiseStage.off);
    expect(switched, isEmpty);
  });

  test('stopping one recording leaves the download another shares', () async {
    downloadGate = Completer();
    final noise = build();
    final other = 'ef' * 32;
    final first = noise.turnOn(hash);
    final second = noise.turnOn(other);
    await pumpUntil(
      () =>
          noise.stateOf(hash).stage == NoiseStage.downloading &&
          noise.stateOf(other).stage == NoiseStage.downloading,
    );
    noise.stop(hash);
    downloadGate!.complete();
    expect(await first, isNull);
    expect(await second, isNull);
    expect(noise.stateOf(other).stage, NoiseStage.on);
    expect(noise.stateOf(hash).stage, NoiseStage.off);
  });

  test('a model damaged on disk is fetched again next time', () async {
    final noise = build();
    expect(await noise.turnOn(hash), isNull);
    final file = File(
      '${(await noise.models.directoryFor(model)).path}/model.onnx',
    );
    await file.writeAsString('not a model');
    expect(await noise.turnOn('ef' * 32), NoiseProblem.failed);
    expect(await noise.turnOn('ef' * 32), isNull);
    expect(fetches, 2);
  });

  test('says so when there is no room for the copy', () async {
    noSpace = true;
    final noise = build();
    expect(await noise.turnOn(hash), NoiseProblem.noSpace);
    expect(noise.stateOf(hash).stage, NoiseStage.off);
  });

  test('says so when the recording is not on this device', () async {
    original = null;
    final noise = build();
    expect(await noise.turnOn(hash), NoiseProblem.notDownloaded);
    expect(noise.stateOf(hash).stage, NoiseStage.off);
  });

  test('a new recording is cleaned only when the setting is on', () async {
    final noise = build();
    noise.recorded(hash);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(fetches, 0);

    prefs.removeNoise = true;
    noise.recorded(hash);
    await pumpUntil(() => noise.stateOf(hash).stage == NoiseStage.on);
  });

  test('the setting fetches the model ahead of the first recording', () async {
    final noise = build();
    await noise.prepare();
    expect(noise.models.stateOf(model).status, LocalModelStatus.ready);
    await noise.prepare();
    expect(fetches, 1);
  });

  test('the setting and the off switch outlive a restart', () {
    final store = _MemoryStore();
    VoicePrefs(store)
      ..load()
      ..removeNoise = true
      ..setNoiseOff(hash, true);
    final again = VoicePrefs(store)..load();
    expect(again.removeNoise, isTrue);
    expect(again.isNoiseOff(hash), isTrue);
    expect(VoicePrefs(_MemoryStore()).removeNoise, isFalse);
  });

  test('the shipped model is the pinned DPDFNet-2', () {
    final file = noiseRemovalModel.files.single;
    expect(file.bytes, 10178747);
    expect(
      file.sha256,
      '4f0ee28935b4a32abecc717d745416976565834d839601acf43031094b4dc94c',
    );
    expect(
      file.urls.single,
      contains('/resolve/dd6818d00f50c836fed43a6243ebe49116de5964/'),
    );
  });

  test('stop shows off at once while a shared download runs on', () async {
    final held = Completer<void>();
    final noise = NoiseRemovals(
      models: LocalModelStore(
        catalogue: [model],
        directory: Directory('${dir.path}/models'),
        client: MockClient((request) async {
          await held.future;
          return http.Response.bytes(weights, 200);
        }),
      ),
      model: model,
      prefs: prefs,
      copies: copies,
      originals: (_) async => original,
      switched: switched.add,
    );
    addTearDown(noise.dispose);
    final other = 'ef' * 32;
    final first = noise.turnOn(hash);
    final second = noise.turnOn(other);
    await pumpUntil(
      () =>
          noise.stateOf(hash).stage == NoiseStage.downloading &&
          noise.stateOf(other).stage == NoiseStage.downloading,
    );

    noise.stop(hash);
    expect(noise.stateOf(hash).stage, NoiseStage.off);
    expect(noise.stateOf(other).stage, NoiseStage.downloading);

    held.complete();
    expect(await first, isNull);
    await second;
  });
}

Future<void> pumpUntil(bool Function() done) async {
  for (var i = 0; i < 500 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue);
}
