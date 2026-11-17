import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kapy_notes/paste/image_download.dart';

final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]);

http.Response picture([String type = 'image/png']) =>
    http.Response.bytes(png, 200, headers: {'content-type': type});

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 10));

/// Serves [png] from an isolate of its own, so it keeps answering while the
/// test's isolate is blocked.
Future<({int port, Isolate isolate})> serveElsewhere() async {
  final ready = ReceivePort();
  final isolate = await Isolate.spawn(_serve, ready.sendPort);
  final port = await ready.first as int;
  return (port: port, isolate: isolate);
}

Future<void> _serve(SendPort ready) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  ready.send(server.port);
  await for (final request in server) {
    request.response
      ..headers.contentType = ContentType('image', 'png')
      ..add(png);
    await request.response.close();
  }
}

void main() {
  test(
    'a picture comes back with its bytes and type, asked for plainly',
    () async {
      late http.BaseRequest sent;
      final downloader = PastedImageDownloader(
        client: MockClient((request) async {
          sent = request;
          return picture('image/png; charset=binary');
        }),
      );
      final fetched = await downloader.fetch('https://example.com/p.png');
      expect(fetched?.bytes, png);
      expect(fetched?.mime, 'image/png');
      expect(sent.method, 'GET');
      final headers = sent.headers.keys.map((key) => key.toLowerCase());
      expect(headers, isNot(contains('cookie')));
      expect(headers, isNot(contains('referer')));
    },
  );

  test('anything but a picture is refused', () async {
    for (final response in [
      http.Response('<html>', 200, headers: {'content-type': 'text/html'}),
      http.Response.bytes(png, 404, headers: {'content-type': 'image/png'}),
      http.Response.bytes(
        const [],
        200,
        headers: {'content-type': 'image/png'},
      ),
    ]) {
      final downloader = PastedImageDownloader(
        client: MockClient((_) async => response),
      );
      expect(await downloader.fetch('https://example.com/p.png'), isNull);
    }
  });

  test('a picture over the size limit is refused, said or not', () async {
    final said = PastedImageDownloader(
      client: MockClient.streaming(
        (request, body) async => http.StreamedResponse(
          Stream.value(png),
          200,
          contentLength: PastedImageDownloader.maxBytes + 1,
          headers: {'content-type': 'image/png'},
        ),
      ),
    );
    expect(await said.fetch('https://example.com/big.png'), isNull);
    final chunk = Uint8List(1024 * 1024);
    final unsaid = PastedImageDownloader(
      client: MockClient.streaming(
        (request, body) async => http.StreamedResponse(
          Stream.fromIterable(List.filled(26, chunk)),
          200,
          headers: {'content-type': 'image/png'},
        ),
      ),
    );
    expect(await unsaid.fetch('https://example.com/big.png'), isNull);
  });

  test('only addresses a page can link to are fetched', () async {
    var asked = 0;
    final downloader = PastedImageDownloader(
      client: MockClient((_) async {
        asked++;
        return picture();
      }),
    );
    for (final address in [
      'ftp://example.com/p.png',
      'data:image/png;base64,AAAA',
      'javascript:alert(1)',
      '',
    ]) {
      expect(await downloader.fetch(address), isNull, reason: address);
    }
    expect(asked, 0);
  });

  test('no more than four pictures download at once', () async {
    final waiting = <Completer<void>>[];
    var active = 0;
    var most = 0;
    final downloader = PastedImageDownloader(
      client: MockClient((_) async {
        active++;
        if (active > most) most = active;
        final turn = Completer<void>();
        waiting.add(turn);
        await turn.future;
        active--;
        return picture();
      }),
    );
    final fetches = [
      for (var i = 0; i < 7; i++)
        downloader.fetch('https://example.com/$i.png'),
    ];
    await settle();
    expect(waiting, hasLength(PastedImageDownloader.maxConcurrent));
    while (waiting.isNotEmpty) {
      waiting.removeAt(0).complete();
      await settle();
    }
    final results = await Future.wait(fetches);
    expect(results.every((result) => result?.mime == 'image/png'), isTrue);
    expect(most, PastedImageDownloader.maxConcurrent);
  });

  test('a busy editor cannot run a download out of time', () async {
    final server = await serveElsewhere();
    addTearDown(() => server.isolate.kill(priority: Isolate.immediate));
    final downloader = PastedImageDownloader(
      timeout: const Duration(seconds: 2),
    );
    final fetching = downloader.fetch('http://127.0.0.1:${server.port}/p.png');
    // Lets the download start, and nothing else this isolate is waiting on.
    await Future<void>.delayed(Duration.zero);
    // Longer than the timeout, the way laying out a long note holds the
    // editor.
    sleep(const Duration(seconds: 3));
    final fetched = await fetching;
    expect(fetched?.bytes, png);
    expect(fetched?.mime, 'image/png');
  });

  test('a stand-in network set up here answers on this isolate', () async {
    var asked = 0;
    final fetched = await HttpOverrides.runZoned(
      () => PastedImageDownloader().fetch('https://example.com/p.png'),
      createHttpClient: (_) {
        asked++;
        throw const SocketException('no network in tests');
      },
    );
    expect(asked, 1);
    expect(fetched, isNull);
  });

  test('a picture an app left on disk is read from there', () async {
    final folder = await Directory.systemTemp.createTemp('kapy_paste_');
    addTearDown(() => folder.delete(recursive: true));
    final image = File('${folder.path}/clip.png')..writeAsBytesSync(png);
    final words = File('${folder.path}/notes.txt')..writeAsStringSync('hi');
    final downloader = PastedImageDownloader(
      client: MockClient((_) async => throw StateError('no network')),
    );
    final fetched = await downloader.fetch(image.uri.toString());
    expect(fetched?.bytes, png);
    expect(fetched?.mime, 'image/png');
    expect(await downloader.fetch(words.uri.toString()), isNull);
    expect(
      await downloader.fetch(Uri.file('${folder.path}/gone.png').toString()),
      isNull,
    );
  });

  group('a file a page names outside the temporary folder', () {
    late Directory outside;
    late File image;
    final downloader = PastedImageDownloader(
      client: MockClient((_) async => throw StateError('no network')),
    );

    setUp(() {
      outside = Directory(
        '${Directory.current.path}/.dart_tool',
      ).createTempSync('kapy_paste_outside_');
      image = File('${outside.path}/private.png')..writeAsBytesSync(png);
      expect(
        image.resolveSymbolicLinksSync().startsWith(
          Directory.systemTemp.resolveSymbolicLinksSync(),
        ),
        isFalse,
      );
    });
    tearDown(() => outside.deleteSync(recursive: true));

    test('is not read', () async {
      expect(await downloader.fetch(image.uri.toString()), isNull);
    });

    test('is read when the clipboard offered that file itself', () async {
      final fetched = await downloader.fetch(
        image.uri.toString(),
        clipboardFiles: [image.path],
      );
      expect(fetched?.bytes, png);
      expect(
        await downloader.fetch(
          image.uri.toString(),
          clipboardFiles: ['${outside.path}/other.png'],
        ),
        isNull,
      );
    });

    test(
      'is not read through a link or a climb out of the temporary folder',
      () async {
        final temp = await Directory.systemTemp.createTemp('kapy_paste_');
        addTearDown(() => temp.delete(recursive: true));
        final link = Link('${temp.path}/clip.png')..createSync(image.path);
        expect(await downloader.fetch(link.uri.toString()), isNull);

        final climb = Uri.file(
          '${temp.path}${Platform.pathSeparator}..'
          '${Platform.pathSeparator}..${Platform.pathSeparator}..'
          '${Platform.pathSeparator}..${Platform.pathSeparator}..'
          '${Platform.pathSeparator}..${Platform.pathSeparator}..'
          '${Platform.pathSeparator}..${image.path}',
        );
        expect(await downloader.fetch(climb.toString()), isNull);
      },
    );
  });
}
