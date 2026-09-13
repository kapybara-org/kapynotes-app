import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/sync/sync_api.dart';

void main() {
  test(
    'streams attachment bytes and reports measured upload progress',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final received = Completer<Uint8List>();
      server.listen((request) async {
        final body = BytesBuilder(copy: false);
        await for (final chunk in request) {
          body.add(chunk);
        }
        received.complete(body.takeBytes());
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
      });
      final api = HttpSyncApi(
        baseUrl: Uri.parse('http://${server.address.address}:${server.port}/'),
        token: () async => 'unused',
        deviceId: 'progress-test',
        timeout: const Duration(seconds: 5),
      );
      addTearDown(() async {
        api.close();
        await server.close(force: true);
      });
      final bytes = Uint8List.fromList(
        List.generate(180000, (index) => index & 0xFF),
      );
      final progress = <double>[];

      await api.putBlob(
        Uri.parse('http://${server.address.address}:${server.port}/upload'),
        bytes,
        onProgress: progress.add,
      );

      expect(await received.future, bytes);
      expect(progress.first, 0);
      expect(progress.last, 1);
      expect(progress.any((value) => value > 0 && value < 1), isTrue);
      expect(progress, orderedEquals([...progress]..sort()));
    },
  );
}
