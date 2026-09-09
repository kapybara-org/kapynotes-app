import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kapy_notes/speech/local_model_store.dart';
import 'package:kapy_notes/speech/local_models.dart';

/// A model made of whatever bytes a test wants, hashed for real.
///
/// Real hashes matter: the point of this store is that it trusts the checksum
/// and not the host, and a test with made-up hashes would exercise the
/// opposite code path from the shipping one.
LocalSpeechModel _model(Map<String, List<int>> files) => LocalSpeechModel(
  id: 'test-model',
  name: 'Test Model',
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

Uint8List _bytes(int length, {int seed = 0}) =>
    Uint8List.fromList([for (var i = 0; i < length; i++) (i + seed) % 251]);

/// Serves [bodies] over a mocked connection, honouring `Range` the way a CDN
/// does unless a test asks it not to.
class _Server {
  _Server(
    this.bodies, {
    this.honoursRange = true,
    this.status = 200,
    this.truncateTo,
    this.onChunk,
  });

  final Map<String, List<int>> bodies;
  final bool honoursRange;
  final int status;

  /// Stop the body short, as a dropped connection does.
  final int? truncateTo;

  /// Called after each chunk leaves, which is where a test presses Cancel.
  final void Function()? onChunk;

  final List<http.BaseRequest> requests = [];

  /// Every byte this server actually put on the wire, per file. A resumed
  /// download must not send the whole file again, and this is how that is
  /// checked rather than inferred.
  final Map<String, int> served = {};

  http.Client get client => MockClient.streaming((request, _) async {
    requests.add(request);
    final name = request.url.pathSegments.last;
    final body = bodies[name]!;
    if (status != 200) {
      return http.StreamedResponse(const Stream.empty(), status);
    }

    final range = request.headers['range'];
    var start = 0;
    if (range != null && honoursRange) {
      start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
    }
    var payload = body.sublist(start);
    if (truncateTo != null && payload.length > truncateTo!) {
      payload = payload.sublist(0, truncateTo!);
    }
    served[name] = (served[name] ?? 0) + payload.length;

    return http.StreamedResponse(
      _chunked(payload),
      range != null && honoursRange ? 206 : 200,
      contentLength: payload.length,
    );
  });

  Stream<List<int>> _chunked(List<int> payload) async* {
    const size = 64;
    for (var at = 0; at < payload.length; at += size) {
      final end = at + size > payload.length ? payload.length : at + size;
      yield payload.sublist(at, end);
      onChunk?.call();
    }
  }
}

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('kapy-models'));
  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  LocalModelStore storeFor(LocalSpeechModel model, http.Client client) =>
      LocalModelStore(
        catalogue: [model],
        directory: temp,
        client: client,
      );

  test('downloads every file, checks it, and reports it ready', () async {
    final bodies = {
      'encoder.onnx': _bytes(500),
      'tokens.txt': _bytes(90, seed: 7),
    };
    final model = _model(bodies);
    final server = _Server(bodies);
    final store = storeFor(model, server.client);
    addTearDown(store.dispose);

    await store.download(model);

    final state = store.stateOf(model);
    expect(state.status, LocalModelStatus.ready);
    expect(state.receivedBytes, model.bytes);
    expect(state.progress, 1);

    final dir = await store.directoryFor(model);
    expect(File('${dir.path}/encoder.onnx').readAsBytesSync(), bodies['encoder.onnx']);
    expect(File('${dir.path}/tokens.txt').readAsBytesSync(), bodies['tokens.txt']);
    // No part files left behind.
    expect(dir.listSync().map((e) => e.uri.pathSegments.last), isNot(contains('encoder.onnx.part')));
  });

  test('a second store finds what the first one downloaded', () async {
    final bodies = {'encoder.onnx': _bytes(300)};
    final model = _model(bodies);
    final first = _Server(bodies);
    final store = storeFor(model, first.client);
    await store.download(model);
    store.dispose();

    final second = _Server(bodies);
    final reopened = storeFor(model, second.client);
    addTearDown(reopened.dispose);

    await reopened.refresh();

    expect(reopened.stateOf(model).status, LocalModelStatus.ready);
    expect(second.requests, isEmpty, reason: 'nothing to fetch twice');
  });

  test('an interrupted download resumes instead of starting over', () async {
    final bodies = {'encoder.onnx': _bytes(500)};
    final model = _model(bodies);

    final dropped = _Server(bodies, truncateTo: 200);
    final store = storeFor(model, dropped.client);
    addTearDown(store.dispose);

    await store.download(model);
    expect(store.stateOf(model).status, LocalModelStatus.failed);
    expect(store.stateOf(model).receivedBytes, 200, reason: 'kept for the retry');

    final full = _Server(bodies);
    final resumed = LocalModelStore(
      catalogue: [model],
      directory: temp,
      client: full.client,
    );
    addTearDown(resumed.dispose);

    await resumed.download(model);

    expect(resumed.stateOf(model).status, LocalModelStatus.ready);
    expect(full.requests.single.headers['range'], 'bytes=200-');
    expect(full.served['encoder.onnx'], 300, reason: 'only the remainder');
    final dir = await resumed.directoryFor(model);
    expect(File('${dir.path}/encoder.onnx').readAsBytesSync(), bodies['encoder.onnx']);
  });

  test('a server that ignores the range header still lands correct bytes', () async {
    final bodies = {'encoder.onnx': _bytes(400)};
    final model = _model(bodies);

    await storeFor(model, _Server(bodies, truncateTo: 100).client).download(model);

    final server = _Server(bodies, honoursRange: false);
    final store = storeFor(model, server.client);
    addTearDown(store.dispose);

    await store.download(model);

    expect(store.stateOf(model).status, LocalModelStatus.ready);
    final dir = await store.directoryFor(model);
    // The whole body was written over the partial one rather than appended to
    // it, which is the only way the checksum can pass here.
    expect(File('${dir.path}/encoder.onnx').readAsBytesSync(), bodies['encoder.onnx']);
  });

  test('bytes that fail their checksum are thrown away, not kept', () async {
    final model = _model({'encoder.onnx': _bytes(300)});
    // Same length, different content: only the hash can tell.
    final server = _Server({'encoder.onnx': _bytes(300, seed: 99)});
    final store = storeFor(model, server.client);
    addTearDown(store.dispose);

    await store.download(model);

    final state = store.stateOf(model);
    expect(state.status, LocalModelStatus.failed);
    expect(state.error, contains('checksum'));
    final dir = await store.directoryFor(model);
    expect(File('${dir.path}/encoder.onnx').existsSync(), isFalse);
  });

  test('a refused download says so and keeps nothing', () async {
    final bodies = {'encoder.onnx': _bytes(120)};
    final model = _model(bodies);
    final store = storeFor(model, _Server(bodies, status: 503).client);
    addTearDown(store.dispose);

    await store.download(model);

    expect(store.stateOf(model).status, LocalModelStatus.failed);
    expect(store.stateOf(model).error, contains('503'));
  });

  test('cancelling keeps what arrived and the next attempt resumes', () async {
    final bodies = {'encoder.onnx': _bytes(500)};
    final model = _model(bodies);

    late LocalModelStore store;
    var chunks = 0;
    final server = _Server(
      bodies,
      onChunk: () {
        chunks++;
        if (chunks == 1) store.cancel(model);
      },
    );
    store = storeFor(model, server.client);
    addTearDown(store.dispose);

    await store.download(model);

    final stopped = store.stateOf(model);
    expect(stopped.status, LocalModelStatus.absent);
    expect(stopped.receivedBytes, 64, reason: 'one chunk, and no more');

    final rest = _Server(bodies);
    final again = LocalModelStore(
      catalogue: [model],
      directory: temp,
      client: rest.client,
    );
    addTearDown(again.dispose);
    await again.download(model);

    expect(again.stateOf(model).status, LocalModelStatus.ready);
    expect(rest.served['encoder.onnx'], 500 - 64);
  });

  test('removing a model deletes it', () async {
    final bodies = {'encoder.onnx': _bytes(200)};
    final model = _model(bodies);
    final store = storeFor(model, _Server(bodies).client);
    addTearDown(store.dispose);

    await store.download(model);
    final dir = await store.directoryFor(model);
    expect(dir.existsSync(), isTrue);

    await store.remove(model);

    expect(store.stateOf(model).status, LocalModelStatus.absent);
    expect(store.stateOf(model).receivedBytes, 0);
    expect(dir.existsSync(), isFalse);
  });

  test('downloading what is already here touches no network', () async {
    final bodies = {'encoder.onnx': _bytes(200)};
    final model = _model(bodies);
    final store = storeFor(model, _Server(bodies).client);
    await store.download(model);
    store.dispose();

    final server = _Server(bodies);
    final again = storeFor(model, server.client);
    addTearDown(again.dispose);

    await again.download(model);

    expect(again.stateOf(model).status, LocalModelStatus.ready);
    expect(server.requests, isEmpty);
  });

  test('progress is reported as it goes, not only at the end', () async {
    final bodies = {'encoder.onnx': _bytes(500)};
    final model = _model(bodies);
    final store = storeFor(model, _Server(bodies).client);
    addTearDown(store.dispose);

    final seen = <double>[];
    store.addListener(() => seen.add(store.stateOf(model).progress));

    await store.download(model);

    expect(seen.first, lessThan(1));
    expect(seen.last, 1);
    expect(seen, isNot(contains(greaterThan(1.0))));
  });
}
