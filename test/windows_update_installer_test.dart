import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kapy_notes/data/update_installer.dart';
import 'package:kapy_notes/data/update_manifest.dart';
import 'package:kapy_notes/data/windows_update_installer.dart';

import 'update_test_fixtures.dart';

final _payload = utf8.encode(testPayload);

AvailableUpdate _update({
  String version = '1.29.0',
  int? length,
  String signature = testPayloadSignature,
}) => AvailableUpdate(
  version: version,
  build: 34,
  notesUrl: '',
  windows: UpdatePackage(
    url: Uri.parse('https://dl.example.test/KapyNotes-$version-setup.exe'),
    length: length ?? _payload.length,
    signature: signature,
  ),
);

/// Serves [body] the way R2 does: whole, or from an offset when asked for a
/// range. Records every request so a test can see what was asked for.
class _Server {
  _Server(this.body, {this.honoursRange = true});

  /// Small, so that even the test payload arrives in several pieces.
  static const chunk = 7;

  final List<int> body;
  final bool honoursRange;
  final List<http.BaseRequest> requests = [];

  http.Client get client => MockClient.streaming((request, _) async {
    requests.add(request);
    final range = request.headers['range'];
    var start = 0;
    if (range != null && honoursRange) {
      start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
    }
    final rest = body.sublist(start);
    final chunks = [
      for (var i = 0; i < rest.length; i += chunk)
        rest.sublist(i, i + chunk > rest.length ? rest.length : i + chunk),
    ];
    return http.StreamedResponse(
      Stream.fromIterable(chunks),
      start > 0 ? 206 : 200,
      headers: {
        if (start > 0)
          'content-range': 'bytes $start-${body.length - 1}/${body.length}',
      },
    );
  });
}

void main() {
  late Directory dir;
  late List<List<String>> launches;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('kn-updates');
    launches = [];
  });
  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  WindowsUpdateInstaller installer(http.Client client) =>
      WindowsUpdateInstaller(
        client: client,
        directory: () async => dir,
        launch: (executable, arguments) async =>
            launches.add([executable, ...arguments]),
        publicKeyPem: testUpdateKey,
      );

  File installerFile([String version = '1.29.0']) =>
      File('${dir.path}${Platform.pathSeparator}KapyNotes-$version-setup.exe');

  test('downloads, checks the signature, and runs it silently', () async {
    final server = _Server(_payload);
    final updates = installer(server.client);
    final progress = <double?>[];

    final staged = await updates.download(_update(), onProgress: progress.add);

    expect(staged.version, '1.29.0');
    expect(staged.build, 34);
    expect(installerFile().readAsBytesSync(), _payload);
    expect(File('${installerFile().path}.part').existsSync(), isFalse);
    expect(progress.first, 0);
    expect(progress.last, 1);
    expect(progress, orderedEquals([...progress]..sort()));

    await updates.install();
    expect(launches, [
      [installerFile().path, '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'],
    ]);
    expect(updates.quitsTheApp, isFalse);
  });

  test('refuses a file that does not match its signature', () async {
    final tampered = List<int>.of(_payload)..[3] ^= 0x20;
    final updates = installer(_Server(tampered).client);

    await expectLater(
      updates.download(_update()),
      throwsA(isA<UpdateInstallerException>()),
    );
    expect(dir.listSync(), isEmpty, reason: 'nothing unverified is kept');
    await expectLater(
      updates.install(),
      throwsA(isA<UpdateInstallerException>()),
    );
    expect(launches, isEmpty);
  });

  test('refuses a download longer than the release says', () async {
    final updates = installer(_Server([..._payload, 0]).client);

    await expectLater(
      updates.download(_update()),
      throwsA(isA<UpdateInstallerException>()),
    );
    expect(installerFile().existsSync(), isFalse);
  });

  test('carries on from where an interrupted download stopped', () async {
    File(
      '${installerFile().path}.part',
    ).writeAsBytesSync(_payload.sublist(0, 10));
    final server = _Server(_payload);

    await installer(server.client).download(_update());

    expect(server.requests.single.headers['range'], 'bytes=10-');
    expect(installerFile().readAsBytesSync(), _payload);
  });

  test('starts again when the server ignores the range', () async {
    File('${installerFile().path}.part').writeAsBytesSync([1, 2, 3]);
    final server = _Server(_payload, honoursRange: false);

    await installer(server.client).download(_update());

    expect(installerFile().readAsBytesSync(), _payload);
  });

  test('does not fetch again what is already downloaded', () async {
    final first = _Server(_payload);
    await installer(first.client).download(_update());
    final second = _Server(_payload);

    final staged = await installer(second.client).download(_update());

    expect(staged.version, '1.29.0');
    expect(second.requests, isEmpty);
  });

  test('a later run finds the download an earlier one finished', () async {
    await installer(_Server(_payload).client).download(_update());

    final later = installer(_Server(_payload).client);
    final staged = await later.restore(_update());

    expect(staged?.version, '1.29.0');
    await later.install();
    expect(launches.single.first, installerFile().path);
  });

  test('a later run discards a download that no longer verifies', () async {
    installerFile().writeAsBytesSync(List<int>.of(_payload)..[0] ^= 1);

    final later = installer(_Server(_payload).client);

    expect(await later.restore(_update()), isNull);
    expect(installerFile().existsSync(), isFalse);
  });

  test('checks the file again if it changed after it was verified', () async {
    final updates = installer(_Server(_payload).client);
    await updates.download(_update());
    // Same length, different bytes, and a different modification time.
    installerFile().writeAsBytesSync(List<int>.of(_payload)..[5] ^= 1);
    installerFile().setLastModifiedSync(
      DateTime.now().add(const Duration(minutes: 1)),
    );

    await expectLater(
      updates.install(),
      throwsA(
        isA<UpdateInstallerException>().having(
          (error) => error.message,
          'message',
          'The downloaded update was damaged',
        ),
      ),
    );
    expect(launches, isEmpty);
    expect(installerFile().existsSync(), isFalse);
    expect(await updates.restore(_update()), isNull);
  });

  test('keeps only the download that is still wanted', () async {
    final updates = installer(_Server(_payload).client);
    await updates.download(_update());
    installerFile('1.28.0').writeAsStringSync('old');
    File('${installerFile('1.27.0').path}.part').writeAsStringSync('older');

    await updates.cleanUp(keep: _update());
    expect(dir.listSync().map((entry) => entry.path), [installerFile().path]);

    await updates.cleanUp();
    expect(dir.listSync(), isEmpty);
  });

  test('never turns a version from the manifest into a path', () async {
    final server = _Server(_payload);

    await expectLater(
      installer(server.client).download(_update(version: r'..\..\evil')),
      throwsA(isA<UpdateInstallerException>()),
    );
    expect(server.requests, isEmpty);
  });

  test('says so when a release carries no Windows installer', () async {
    const bare = AvailableUpdate(version: '1.29.0', build: 34, notesUrl: '');

    await expectLater(
      installer(_Server(_payload).client).download(bare),
      throwsA(isA<UpdateInstallerException>()),
    );
    expect(await installer(_Server(_payload).client).restore(bare), isNull);
  });

  test('a server error is a failed download, not a crash', () async {
    final client = MockClient((_) async => http.Response('gone', 404));

    await expectLater(
      installer(client).download(_update()),
      throwsA(isA<UpdateInstallerException>()),
    );
  });

  test('reads the installer from the manifest only over HTTPS', () {
    final decoded = {
      'version': '1.29.0',
      'build': 34,
      'notesUrl': '',
      'windows': {
        'url': 'http://dl.kapynotes.com/downloads/KapyNotes-1.29.0-setup.exe',
        'length': 10,
        'dsaSignature': 'abc',
      },
    };
    expect(AvailableUpdate.fromJson(decoded)?.windows, isNull);

    (decoded['windows'] as Map)['url'] =
        'https://dl.kapynotes.com/downloads/KapyNotes-1.29.0-setup.exe';
    final package = AvailableUpdate.fromJson(decoded)!.windows!;
    expect(package.length, 10);
    expect(package.signature, 'abc');
    expect(
      AvailableUpdate.fromJson(
        AvailableUpdate.fromJson(decoded)!.toJson(),
      )?.windows?.url,
      package.url,
    );
  });
}
