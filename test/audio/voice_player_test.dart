import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/audio/voice_player.dart';

class FakeBackend implements VoicePlayerBackend {
  Duration? reports = const Duration(seconds: 10);
  bool failLoad = false;

  final positionController = StreamController<Duration>.broadcast();
  final completionController = StreamController<void>.broadcast();

  final loaded = <String>[];
  int plays = 0;
  int pauses = 0;
  int stops = 0;
  int disposals = 0;
  Duration? seekedTo;
  double? speed;

  @override
  Future<Duration?> load(File file) async {
    if (failLoad) throw const FileSystemException('gone');
    loaded.add(file.path);
    return reports;
  }

  @override
  Future<void> play() async => plays++;

  @override
  Future<void> pause() async => pauses++;

  @override
  Future<void> seek(Duration position) async => seekedTo = position;

  @override
  Future<void> setSpeed(double value) async => speed = value;

  @override
  Future<void> stop() async => stops++;

  @override
  Stream<Duration> get positions => positionController.stream;

  @override
  Stream<void> get completions => completionController.stream;

  @override
  Future<void> dispose() async => disposals++;
}

void main() {
  late FakeBackend backend;
  late VoicePlayer player;
  final fileA = File('/tmp/a.m4a');
  final fileB = File('/tmp/b.m4a');

  /// Both recordings are already on this device.
  Future<File?> onDisk(String hash) async => switch (hash) {
    'a' => fileA,
    'b' => fileB,
    _ => null,
  };

  setUp(() {
    backend = FakeBackend();
    player = VoicePlayer(backend: backend, files: onDisk);
  });

  tearDown(() => player.dispose());

  test('a finished recording plays again from the start', () async {
    // The bug this pins: nothing rewinds when a recording ends, so the play
    // button asked the engine to resume from the very end and the recording
    // sat there. Pressing play on a finished recording means play it again.
    await player.play('a');
    backend.completionController.add(null);
    await pumpEventQueue();
    expect(player.playing, isFalse);

    backend.seekedTo = null;
    await player.play('a');

    expect(backend.seekedTo, Duration.zero, reason: 'the head has to go back');
    expect(backend.loaded, ['/tmp/a.m4a'], reason: 'and not reload the file');
    expect(backend.plays, 2);
    expect(player.playing, isTrue);
  });

  test('pausing and resuming still keeps its place', () async {
    // The other half of the same branch: a pause is not an ending, and
    // resuming must not rewind.
    await player.play('a');
    await player.pause();
    backend.seekedTo = null;

    await player.play('a');

    expect(backend.seekedTo, isNull);
    expect(backend.plays, 2);
  });

  test('seeking after the end lets it play on from there', () async {
    await player.play('a');
    backend.completionController.add(null);
    await pumpEventQueue();

    await player.seek(const Duration(seconds: 4));
    backend.seekedTo = null;
    await player.play('a');

    expect(backend.seekedTo, isNull, reason: 'the seek already placed it');
    expect(player.position, const Duration(seconds: 4));
  });

  test('playing from a position starts there', () async {
    await player.play('a', from: const Duration(seconds: 3));
    expect(backend.seekedTo, const Duration(seconds: 3));
    expect(player.position, const Duration(seconds: 3));
    expect(backend.plays, 1);
  });

  test('the position is published without waking the whole tree', () async {
    // The editor listens to the player and must not rebuild four times a
    // second; anything that wants the moving head listens to this instead.
    var notifications = 0;
    player.addListener(() => notifications++);
    await player.play('a');
    final seen = <Duration>[];
    player.positionListenable.addListener(
      () => seen.add(player.positionListenable.value),
    );

    notifications = 0;
    backend.positionController.add(const Duration(seconds: 2));
    await pumpEventQueue();

    expect(seen, [const Duration(seconds: 2)]);
    expect(notifications, 0);
  });

  test('playing loads the file and starts', () async {
    await player.play('a');
    expect(backend.loaded, ['/tmp/a.m4a']);
    expect(backend.plays, 1);
    expect(player.activeHash, 'a');
    expect(player.playing, isTrue);
  });

  test('progress is null for a recording that is not playing', () async {
    expect(player.progressFor('a').value, isNull);
    await player.play('a');
    expect(player.progressFor('b').value, isNull);
  });

  test('position updates arrive as a fraction on that hash alone', () async {
    await player.play('a');
    backend.positionController.add(const Duration(seconds: 5));
    await pumpEventQueue();
    expect(player.progressFor('a').value, closeTo(0.5, 0.001));
    expect(player.progressFor('b').value, isNull);
  });

  test('the editor is not rebuilt as the position moves', () async {
    // Four times a second, through the whole tree, would rebuild every result
    // chip and every highlight while a recording plays.
    await player.play('a');
    var notifications = 0;
    player.addListener(() => notifications++);
    for (var i = 1; i <= 8; i++) {
      backend.positionController.add(Duration(seconds: i));
    }
    await pumpEventQueue();
    expect(notifications, 0);
    expect(player.progressFor('a').value, closeTo(0.8, 0.001));
  });

  test('playing a second recording stops the first', () async {
    await player.play('a');
    backend.positionController.add(const Duration(seconds: 5));
    await pumpEventQueue();

    await player.play('b');
    expect(player.activeHash, 'b');
    expect(backend.stops, 1);
    expect(player.progressFor('a').value, isNull);
  });

  test('pressing play again resumes rather than reloading', () async {
    await player.play('a');
    await player.pause();
    await player.play('a');
    expect(backend.loaded, hasLength(1));
    expect(backend.plays, 2);
  });

  test('seeking moves the progress before the backend answers', () async {
    await player.play('a');
    await player.seek(const Duration(seconds: 2));
    expect(backend.seekedTo, const Duration(seconds: 2));
    expect(player.progressFor('a').value, closeTo(0.2, 0.001));
  });

  test('reaching the end stops without clearing the recording', () async {
    await player.play('a');
    backend.completionController.add(null);
    await pumpEventQueue();
    expect(player.playing, isFalse);
    expect(player.activeHash, 'a');
    expect(player.progressFor('a').value, 1);
  });

  test('speed is remembered and applied to the next recording', () async {
    await player.setSpeed(1.5);
    await player.play('a');
    expect(backend.speed, 1.5);
    expect(player.speed, 1.5);
  });

  test('a file that will not open leaves nothing playing, and says so', () async {
    backend.failLoad = true;
    await player.play('a');
    expect(player.activeHash, isNull);
    expect(player.playing, isFalse);
    expect(player.failureFor('a'), VoicePlaybackFailure.unreadable);
  });

  test('a recording with no readable duration does not divide by zero', () async {
    backend.reports = null;
    await player.play('a');
    backend.positionController.add(const Duration(seconds: 5));
    await pumpEventQueue();
    expect(player.progressFor('a').value, 0);
  });

  test('an idle player releases its engine', () async {
    final quick = VoicePlayer(
      backend: backend,
      files: onDisk,
      idleTimeout: const Duration(milliseconds: 20),
    );
    await quick.play('a');
    await quick.pause();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(backend.disposals, greaterThan(0));
    expect(quick.activeHash, isNull);
    quick.dispose();
  });

  test('a player still playing is not released under itself', () async {
    final quick = VoicePlayer(
      backend: backend,
      files: onDisk,
      idleTimeout: const Duration(milliseconds: 20),
    );
    await quick.play('a');
    await quick.pause();
    await quick.play('a');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(quick.activeHash, 'a');
    quick.dispose();
  });

  group('a recording that is not on this device yet', () {
    // Recorded somewhere else, so it arrived as a ref and its audio comes down
    // only when somebody presses play. Every caller used to look on disk, find
    // nothing, and do nothing — a phone's recordings never played on the
    // desktop. Now the lookup can take as long as a download, and the user
    // can change their mind while it does.
    late Completer<File?> arriving;
    late int lookups;

    setUp(() {
      arriving = Completer<File?>();
      lookups = 0;
      player.dispose();
      player = VoicePlayer(
        backend: backend,
        files: (hash) {
          if (hash != 'a') return onDisk(hash);
          lookups++;
          return arriving.future;
        },
      );
    });

    test('is shown as on its way, then plays once it arrives', () async {
      final pressed = player.play('a');
      await pumpEventQueue();
      expect(player.isOpening('a'), isTrue);
      expect(player.activeHash, isNull);
      expect(backend.loaded, isEmpty);

      arriving.complete(fileA);
      await pressed;

      expect(player.isOpening('a'), isFalse);
      expect(player.isPlaying('a'), isTrue);
      expect(backend.loaded, ['/tmp/a.m4a']);
    });

    test('says when it could not be got, and the next press asks again', () async {
      final pressed = player.play('a');
      arriving.complete(null);
      await pressed;

      expect(player.failureFor('a'), VoicePlaybackFailure.notDownloaded);
      expect(player.isOpening('a'), isFalse);
      expect(player.activeHash, isNull);
      expect(backend.plays, 0);

      arriving = Completer<File?>()..complete(fileA);
      await player.play('a');

      expect(lookups, 2);
      expect(player.failureFor('a'), isNull);
      expect(player.isPlaying('a'), isTrue);
    });

    test('a lookup that throws is one that could not be got', () async {
      final pressed = player.play('a');
      // Listened to first: an error completed into a future nobody holds yet
      // is reported as uncaught.
      await pumpEventQueue();
      arriving.completeError(const SocketException('offline'));
      await pressed;

      expect(player.failureFor('a'), VoicePlaybackFailure.notDownloaded);
      expect(player.playing, isFalse);
    });

    test('is looked up once, however often play is pressed', () async {
      final first = player.play('a');
      await pumpEventQueue();
      final second = player.play('a');
      await pumpEventQueue();
      expect(lookups, 1);

      arriving.complete(fileA);
      await Future.wait([first, second]);

      expect(backend.loaded, ['/tmp/a.m4a']);
      expect(backend.plays, 1);
    });

    test('does not take over from one chosen while it was on its way', () async {
      final pressed = player.play('a');
      await pumpEventQueue();
      await player.play('b');
      expect(player.isPlaying('b'), isTrue);
      expect(player.isOpening('a'), isFalse);

      arriving.complete(fileA);
      await pressed;

      expect(player.activeHash, 'b');
      expect(player.isPlaying('b'), isTrue);
      expect(backend.loaded, ['/tmp/b.m4a']);
    });

    test('a pause before it arrives means it does not start', () async {
      final pressed = player.play('a');
      await pumpEventQueue();
      await player.pause();
      expect(player.isOpening('a'), isFalse);

      arriving.complete(fileA);
      await pressed;

      expect(player.activeHash, isNull);
      expect(backend.plays, 0);
      expect(player.failureFor('a'), isNull);
    });
  });
}
