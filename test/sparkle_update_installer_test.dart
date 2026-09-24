import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/sparkle_update_installer.dart';
import 'package:kapy_notes/data/update_installer.dart';
import 'package:kapy_notes/data/update_manifest.dart';

const _channel = MethodChannel('kapynotes/updater');
const _update = AvailableUpdate(version: '1.29.0', build: 34, notesUrl: '');

/// Stands in for `macos/Runner/AppUpdater.swift`: answers the calls, and
/// sends the events Sparkle's delegate would.
class _Native {
  _Native({this.downloadReply = const {'status': 'started'}}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'download' => downloadReply,
            'install' => installReply,
            _ => null,
          };
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null),
    );
  }

  final Map<String, Object?> downloadReply;
  bool installReply = true;
  final List<MethodCall> calls = [];

  Future<void> send(String event, [Map<String, Object?> details = const {}]) {
    return TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          _channel.name,
          _channel.codec.encodeMethodCall(MethodCall(event, details)),
          (_) {},
        );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('asks Sparkle for the feed, and is ready when Sparkle is', () async {
    final native = _Native();
    final installer = SparkleUpdateInstaller(feedUrl: 'https://feed.test');
    addTearDown(installer.dispose);
    final progress = <double?>[];

    final download = installer.download(_update, onProgress: progress.add);
    await pumpEventQueue();
    expect(native.calls.single.method, 'download');
    expect(native.calls.single.arguments, {'feedUrl': 'https://feed.test'});

    await native.send('ready', {'version': '1.29.0', 'build': '34'});
    final staged = await download;

    expect(staged.version, '1.29.0');
    expect(staged.build, 34);
    expect(progress, [null], reason: 'Sparkle reports no progress');
    expect((await installer.restore(_update))?.version, '1.29.0');
    expect(installer.quitsTheApp, isTrue);
  });

  test('one request, however many times it is asked for', () async {
    final native = _Native();
    final installer = SparkleUpdateInstaller(feedUrl: 'https://feed.test');
    addTearDown(installer.dispose);

    final first = installer.download(_update);
    final second = installer.download(_update);
    await pumpEventQueue();
    await native.send('ready', {'version': '1.29.0', 'build': '34'});

    expect((await first).version, '1.29.0');
    expect((await second).version, '1.29.0');
    expect(
      native.calls.where((call) => call.method == 'download'),
      hasLength(1),
    );

    // And none at all once it is ready.
    expect((await installer.download(_update)).version, '1.29.0');
    expect(
      native.calls.where((call) => call.method == 'download'),
      hasLength(1),
    );
  });

  test('an update Sparkle already holds is ready at once', () async {
    _Native(
      downloadReply: const {
        'status': 'ready',
        'version': '1.29.0',
        'build': '34',
      },
    );
    final installer = SparkleUpdateInstaller(feedUrl: 'https://feed.test');
    addTearDown(installer.dispose);

    expect((await installer.download(_update)).version, '1.29.0');
  });

  for (final (event, details) in [
    ('failed', {'message': 'The network connection was lost.'}),
    ('notFound', <String, Object?>{}),
    ('finished', <String, Object?>{}),
  ]) {
    test('"$event" from Sparkle fails the download', () async {
      final native = _Native();
      final installer = SparkleUpdateInstaller(feedUrl: 'https://feed.test');
      addTearDown(installer.dispose);

      final download = expectLater(
        installer.download(_update),
        throwsA(isA<UpdateInstallerException>()),
      );
      await pumpEventQueue();
      await native.send(event, details);

      await download;
      expect(await installer.restore(_update), isNull);
    });
  }

  test('a cycle ending after the download is ready changes nothing', () async {
    final native = _Native();
    final installer = SparkleUpdateInstaller(feedUrl: 'https://feed.test');
    addTearDown(installer.dispose);

    final download = installer.download(_update);
    await pumpEventQueue();
    await native.send('ready', {'version': '1.29.0', 'build': '34'});
    await native.send('finished');

    expect((await download).version, '1.29.0');
    expect(await installer.restore(_update), isNotNull);
  });

  test('a runner that cannot start Sparkle fails at once', () async {
    _Native(downloadReply: const {'status': 'error', 'message': 'no feed'});
    final installer = SparkleUpdateInstaller(feedUrl: 'https://feed.test');
    addTearDown(installer.dispose);

    await expectLater(
      installer.download(_update),
      throwsA(isA<UpdateInstallerException>()),
    );
  });

  test('a build without the runner half says it cannot update', () async {
    final installer = SparkleUpdateInstaller(feedUrl: 'https://feed.test');
    addTearDown(installer.dispose);

    await expectLater(
      installer.download(_update),
      throwsA(
        isA<UpdateInstallerException>().having(
          (error) => error.message,
          'message',
          'This build cannot update itself',
        ),
      ),
    );
  });

  test('installs through Sparkle, and forgets a download it lost', () async {
    final native = _Native();
    final installer = SparkleUpdateInstaller(feedUrl: 'https://feed.test');
    addTearDown(installer.dispose);

    await expectLater(
      installer.install(),
      throwsA(isA<UpdateInstallerException>()),
      reason: 'nothing to install yet',
    );

    final download = installer.download(_update);
    await pumpEventQueue();
    await native.send('ready', {'version': '1.29.0', 'build': '34'});
    await download;

    await installer.install();
    expect(native.calls.last.method, 'install');

    native.installReply = false;
    await expectLater(
      installer.install(),
      throwsA(isA<UpdateInstallerException>()),
    );
    expect(await installer.restore(_update), isNull);
  });
}
