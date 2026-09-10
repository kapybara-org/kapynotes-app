import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/speech/local_model_store.dart';
import 'package:kapy_notes/speech/local_models.dart';
import 'package:kapy_notes/speech/runtime_pack.dart';

/// A pack that arrives in three steps, or refuses, or is cancelled — as the
/// test decides — and remembers everything asked of it.
class _FakePack implements RuntimePack {
  _FakePack({this.failWith});

  bool installed = false;
  final String? failWith;
  final int total = 3000;

  int installs = 0;
  int cancels = 0;
  int removes = 0;
  final List<(int, int)> reported = [];

  /// Held open until the test lets the install finish, so that a cancel can
  /// land in the middle of one.
  Completer<void>? gate;

  @override
  Future<bool> isInstalled() async => installed;

  @override
  Future<void> install({
    void Function(int received, int total)? onProgress,
  }) async {
    installs++;
    if (failWith != null) throw RuntimePackException(failWith!);
    for (var step = 1; step <= 3; step++) {
      final received = (total * step) ~/ 3;
      reported.add((received, total));
      onProgress?.call(received, total);
      if (gate != null && step == 1) await gate!.future;
      if (_cancelled) throw const RuntimePackException('Cancelled.');
    }
    installed = true;
  }

  bool _cancelled = false;

  @override
  Future<void> cancel() async {
    cancels++;
    _cancelled = true;
    gate?.complete();
  }

  @override
  Future<void> remove() async {
    removes++;
    installed = false;
  }
}

LocalSpeechModel _model(String id, Map<String, List<int>> files) =>
    LocalSpeechModel(
      id: id,
      name: 'Model $id',
      vendor: 'Nobody',
      parameters: '1M',
      architecture: 'None',
      license: 'MIT',
      licenseUrl: 'https://example.com/licence',
      summary: 'A model that does nothing.',
      languages: const ['English'],
      englishWordErrorRate: 1.5,
      multilingualWordErrorRate: 2.5,
      accuracySource: 'nowhere at all',
      speedFactor: 3,
      speedSource: 'nothing in particular',
      files: [
        for (final entry in files.entries)
          LocalModelFile(
            name: entry.key,
            url: 'https://models.test/$id/${entry.key}',
            bytes: entry.value.length,
            sha256: sha256.convert(entry.value).toString(),
          ),
      ],
    );

Uint8List _bytes(int length, {int seed = 0}) =>
    Uint8List.fromList([for (var i = 0; i < length; i++) (i + seed) % 251]);

http.Client _serving(Map<String, List<int>> bodies) => MockClient((request) async {
  final body = bodies[request.url.pathSegments.last];
  if (body == null) return http.Response('missing', 404);
  return http.Response.bytes(body, 200);
});

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 500 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(condition(), isTrue, reason: 'never happened');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('kapy-runtime'));
  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  group('the store fetches the engine before the model', () {
    test('and reports it as the first stage of the same download', () async {
      final bodies = {'encoder.onnx': _bytes(400)};
      final model = _model('a', bodies);
      final pack = _FakePack();
      final store = LocalModelStore(
        catalogue: [model],
        directory: temp,
        client: _serving(bodies),
        runtime: pack,
      );
      addTearDown(store.dispose);

      final seen = <LocalModelStatus>[];
      store.addListener(() => seen.add(store.stateOf(model).status));

      await store.download(model);

      expect(pack.installs, 1);
      expect(seen.first, LocalModelStatus.fetchingRuntime);
      expect(seen, contains(LocalModelStatus.downloading));
      expect(seen.last, LocalModelStatus.ready);
      // The engine's bytes are shown as its own stage, not folded into the
      // model's total: a phone user sees the bar for what it is.
      expect(pack.reported.last, (3000, 3000));
      expect(store.stateOf(model).receivedBytes, model.bytes);
    });

    test('but not twice: a second model finds it already there', () async {
      final first = {'a.onnx': _bytes(100)};
      final second = {'b.onnx': _bytes(120, seed: 3)};
      final pack = _FakePack();
      final store = LocalModelStore(
        catalogue: [_model('a', first), _model('b', second)],
        directory: temp,
        client: _serving({...first, ...second}),
        runtime: pack,
      );
      addTearDown(store.dispose);

      await store.download(store.catalogue[0]);
      await store.download(store.catalogue[1]);

      expect(pack.installs, 1);
      expect(store.stateOf(store.catalogue[1]).status, LocalModelStatus.ready);
    });

    test('and a refusal is the card\'s failure, in Play\'s words', () async {
      final bodies = {'encoder.onnx': _bytes(50)};
      final model = _model('a', bodies);
      final store = LocalModelStore(
        catalogue: [model],
        directory: temp,
        client: _serving(bodies),
        runtime: _FakePack(failWith: 'Not enough room on this phone.'),
      );
      addTearDown(store.dispose);

      await store.download(model);

      final state = store.stateOf(model);
      expect(state.status, LocalModelStatus.failed);
      expect(state.error, 'Not enough room on this phone.');
    });

    test('and cancelling during it stops the engine, not just the model', () async {
      final bodies = {'encoder.onnx': _bytes(50)};
      final model = _model('a', bodies);
      final pack = _FakePack()..gate = Completer<void>();
      final store = LocalModelStore(
        catalogue: [model],
        directory: temp,
        client: _serving(bodies),
        runtime: pack,
      );
      addTearDown(store.dispose);

      final job = store.download(model);
      // Let the first progress report land, so the card is mid-engine.
      await _until(
        () => store.stateOf(model).status == LocalModelStatus.fetchingRuntime,
      );

      store.cancel(model);
      await job;

      expect(pack.cancels, 1);
      expect(store.stateOf(model).status, LocalModelStatus.absent);
      expect(store.stateOf(model).error, isNull, reason: 'a cancel is not a failure');
    });
  });

  group('the engine follows the models', () {
    test('a model whose files are here but whose engine is not is not ready', () async {
      final bodies = {'encoder.onnx': _bytes(80)};
      final model = _model('a', bodies);
      final pack = _FakePack();
      final store = LocalModelStore(
        catalogue: [model],
        directory: temp,
        client: _serving(bodies),
        runtime: pack,
      );
      await store.download(model);
      store.dispose();

      // Play took the module back — or this is a fresh process on a phone
      // that never had it.
      pack.installed = false;
      final reopened = LocalModelStore(
        catalogue: [model],
        directory: temp,
        client: _serving(bodies),
        runtime: pack,
      );
      addTearDown(reopened.dispose);
      await reopened.refresh();

      final state = reopened.stateOf(model);
      expect(state.status, LocalModelStatus.absent);
      expect(state.receivedBytes, model.bytes, reason: 'the card offers Resume');

      // Resuming fetches the engine and touches no model bytes.
      var served = 0;
      final counting = MockClient((request) async {
        served++;
        return http.Response.bytes(bodies[request.url.pathSegments.last]!, 200);
      });
      final resumed = LocalModelStore(
        catalogue: [model],
        directory: temp,
        client: counting,
        runtime: pack,
      );
      addTearDown(resumed.dispose);
      await resumed.download(model);
      expect(resumed.stateOf(model).status, LocalModelStatus.ready);
      expect(pack.installs, 2);
      expect(served, 0);
    });

    test('removing the last model releases it; removing one of two does not', () async {
      final first = {'a.onnx': _bytes(100)};
      final second = {'b.onnx': _bytes(120, seed: 3)};
      final pack = _FakePack();
      final store = LocalModelStore(
        catalogue: [_model('a', first), _model('b', second)],
        directory: temp,
        client: _serving({...first, ...second}),
        runtime: pack,
      );
      addTearDown(store.dispose);
      await store.download(store.catalogue[0]);
      await store.download(store.catalogue[1]);

      await store.remove(store.catalogue[0]);
      expect(pack.removes, 0);

      await store.remove(store.catalogue[1]);
      expect(pack.removes, 1);
    });
  });

  group('the Play pack', () {
    tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

    test('is only ever possible on Android', () {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      expect(PlayRuntimePack.isPossibleHere, isFalse);
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.windows;
      expect(PlayRuntimePack.isPossibleHere, isFalse);
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
      expect(PlayRuntimePack.isPossibleHere, isTrue);
    });

    test('relays progress from the runner and finishes when it does', () async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
      const channel = MethodChannel(PlayRuntimePack.channelName);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        switch (call.method) {
          case 'isInstalled':
            return false;
          case 'install':
            // The runner reports twice before it answers.
            for (final (received, total) in [(10, 100), (100, 100)]) {
              await messenger.handlePlatformMessage(
                PlayRuntimePack.channelName,
                const StandardMethodCodec().encodeMethodCall(
                  MethodCall('progress', {'received': received, 'total': total}),
                ),
                (_) {},
              );
            }
            return null;
          case 'remove':
          case 'cancel':
            return null;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final pack = PlayRuntimePack(channel: channel);
      final progress = <(int, int)>[];
      await pack.install(onProgress: (r, t) => progress.add((r, t)));
      expect(progress, [(10, 100), (100, 100)]);

      await pack.remove();
      await pack.cancel();
      expect(calls, ['install', 'remove', 'cancel']);
    });

    test('turns the runner\'s refusal into the card\'s words', () async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
      const channel = MethodChannel(PlayRuntimePack.channelName);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(
          code: 'failed',
          message: 'Could not reach Google Play. Check your connection.',
        );
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final pack = PlayRuntimePack(channel: channel);
      await expectLater(
        pack.install(),
        throwsA(
          isA<RuntimePackException>().having(
            (e) => e.message,
            'message',
            'Could not reach Google Play. Check your connection.',
          ),
        ),
      );
    });

    test('a runner without the channel is a build without the module', () async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
      final pack = PlayRuntimePack(
        channel: const MethodChannel('kapynotes/no-such-channel'),
      );
      expect(await pack.isInstalled(), isFalse);
      await expectLater(pack.install(), throwsA(isA<RuntimePackException>()));
    });
  });
}
