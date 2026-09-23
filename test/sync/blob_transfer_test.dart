import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kapy_notes/sync/sync_api.dart';

/// Object storage on a slow link: reads a request body a chunk at a time with
/// a pause between each, and sends a response body the same way. Stalls
/// outright when told to, and gives up only when the request is aborted.
class SlowStorage extends http.BaseClient {
  SlowStorage({
    required this.pause,
    this.stallAfterChunks,
    this.responseChunks = 0,
  });

  final Duration pause;
  final int? stallAfterChunks;
  final int responseChunks;
  var received = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final abort = (request as http.Abortable).abortTrigger!;
    final aborted = abort.then<Never>(
      (_) => throw http.RequestAbortedException(request.url),
    );

    var chunks = 0;
    await Future.any([
      () async {
        await for (final chunk in request.finalize()) {
          received += chunk.length;
          chunks++;
          if (stallAfterChunks != null && chunks >= stallAfterChunks!) {
            await Completer<void>().future;
          }
          await Future<void>.delayed(pause);
        }
      }(),
      aborted,
    ]);

    final body = StreamController<List<int>>();
    unawaited(() async {
      for (var i = 0; i < responseChunks; i++) {
        if (stallAfterChunks != null && i >= stallAfterChunks!) break;
        await Future<void>.delayed(pause);
        body.add(List.filled(1024, i));
      }
      if (stallAfterChunks == null) await body.close();
    }());
    unawaited(
      abort.then((_) {
        if (!body.isClosed) {
          body.addError(http.RequestAbortedException(request.url));
          body.close();
        }
      }),
    );
    return http.StreamedResponse(body.stream, 200);
  }
}

HttpSyncApi apiWith(http.Client client) => HttpSyncApi(
  baseUrl: Uri.parse('https://api.test/'),
  token: () async => 'token',
  deviceId: 'device',
  client: client,
  timeout: const Duration(milliseconds: 120),
);

final url = Uri.parse('https://blobs.test/object');

void main() {
  test(
    'an upload slower than the timeout still finishes while it moves',
    () async {
      // Ten chunks at 40ms each is 400ms: over three times the timeout. The
      // old single deadline failed this every time.
      final storage = SlowStorage(pause: const Duration(milliseconds: 40));
      final bytes = Uint8List(10 * 64 * 1024);
      final progress = <double>[];

      await apiWith(storage).putBlob(url, bytes, onProgress: progress.add);

      expect(storage.received, bytes.length);
      expect(progress.last, 1);
    },
  );

  test('an upload that stops moving is aborted as transient', () async {
    final storage = SlowStorage(
      pause: const Duration(milliseconds: 10),
      stallAfterChunks: 2,
    );

    await expectLater(
      apiWith(storage).putBlob(url, Uint8List(10 * 64 * 1024)),
      throwsA(isA<SyncTransientException>()),
    );
  });

  test(
    'a download slower than the timeout still finishes while it moves',
    () async {
      final storage = SlowStorage(
        pause: const Duration(milliseconds: 40),
        responseChunks: 8,
      );

      final bytes = await apiWith(storage).getBlob(url);

      expect(bytes, hasLength(8 * 1024));
    },
  );

  test('a download that stops moving is aborted as transient', () async {
    final storage = SlowStorage(
      pause: const Duration(milliseconds: 10),
      responseChunks: 8,
      stallAfterChunks: 3,
    );

    await expectLater(
      apiWith(storage).getBlob(url),
      throwsA(isA<SyncTransientException>()),
    );
  });
}
