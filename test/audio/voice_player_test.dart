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

  setUp(() {
    backend = FakeBackend();
    player = VoicePlayer(backend: backend);
  });

  tearDown(() => player.dispose());

  test('a finished recording plays again from the start', () async {
    // The bug this pins: nothing rewinds when a recording ends, so the play
    // button asked the engine to resume from the very end and the recording
    // sat there. Pressing play on a finished recording means play it again.
    await player.play('a', fileA);
    backend.completionController.add(null);
    await pumpEventQueue();
    expect(player.playing, isFalse);

    backend.seekedTo = null;
    await player.play('a', fileA);

    expect(backend.seekedTo, Duration.zero, reason: 'the head has to go back');
    expect(backend.loaded, ['/tmp/a.m4a'], reason: 'and not reload the file');
    expect(backend.plays, 2);
    expect(player.playing, isTrue);
  });

  test('pausing and resuming still keeps its place', () async {
    // The other half of the same branch: a pause is not an ending, and
    // resuming must not rewind.
    await player.play('a', fileA);
    await player.pause();
    backend.seekedTo = null;

    await player.play('a', fileA);

    expect(backend.seekedTo, isNull);
    expect(backend.plays, 2);
  });

  test('seeking after the end lets it play on from there', () async {
    await player.play('a', fileA);
    backend.completionController.add(null);
    await pumpEventQueue();

    await player.seek(const Duration(seconds: 4));
    backend.seekedTo = null;
    await player.play('a', fileA);

    expect(backend.seekedTo, isNull, reason: 'the seek already placed it');
    expect(player.position, const Duration(seconds: 4));
  });

  test('playing from a position starts there', () async {
    await player.play('a', fileA, from: const Duration(seconds: 3));
    expect(backend.seekedTo, const Duration(seconds: 3));
    expect(player.position, const Duration(seconds: 3));
    expect(backend.plays, 1);
  });

  test('the position is published without waking the whole tree', () async {
    // The editor listens to the player and must not rebuild four times a
    // second; anything that wants the moving head listens to this instead.
    var notifications = 0;
    player.addListener(() => notifications++);
    await player.play('a', fileA);
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
    await player.play('a', fileA);
    expect(backend.loaded, ['/tmp/a.m4a']);
    expect(backend.plays, 1);
    expect(player.activeHash, 'a');
    expect(player.playing, isTrue);
  });

  test('progress is null for a recording that is not playing', () async {
    expect(player.progressFor('a').value, isNull);
    await player.play('a', fileA);
    expect(player.progressFor('b').value, isNull);
  });

  test('position updates arrive as a fraction on that hash alone', () async {
    await player.play('a', fileA);
    backend.positionController.add(const Duration(seconds: 5));
    await pumpEventQueue();
    expect(player.progressFor('a').value, closeTo(0.5, 0.001));
    expect(player.progressFor('b').value, isNull);
  });

  test('the editor is not rebuilt as the position moves', () async {
    // Four times a second, through the whole tree, would rebuild every result
    // chip and every highlight while a recording plays.
    await player.play('a', fileA);
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
    await player.play('a', fileA);
    backend.positionController.add(const Duration(seconds: 5));
    await pumpEventQueue();

    await player.play('b', fileB);
    expect(player.activeHash, 'b');
    expect(backend.stops, 1);
    expect(player.progressFor('a').value, isNull);
  });

  test('pressing play again resumes rather than reloading', () async {
    await player.play('a', fileA);
    await player.pause();
    await player.play('a', fileA);
    expect(backend.loaded, hasLength(1));
    expect(backend.plays, 2);
  });

  test('seeking moves the progress before the backend answers', () async {
    await player.play('a', fileA);
    await player.seek(const Duration(seconds: 2));
    expect(backend.seekedTo, const Duration(seconds: 2));
    expect(player.progressFor('a').value, closeTo(0.2, 0.001));
  });

  test('reaching the end stops without clearing the recording', () async {
    await player.play('a', fileA);
    backend.completionController.add(null);
    await pumpEventQueue();
    expect(player.playing, isFalse);
    expect(player.activeHash, 'a');
    expect(player.progressFor('a').value, 1);
  });

  test('speed is remembered and applied to the next recording', () async {
    await player.setSpeed(1.5);
    await player.play('a', fileA);
    expect(backend.speed, 1.5);
    expect(player.speed, 1.5);
  });

  test('a file that will not open leaves nothing playing', () async {
    backend.failLoad = true;
    await player.play('a', fileA);
    expect(player.activeHash, isNull);
    expect(player.playing, isFalse);
  });

  test('a recording with no readable duration does not divide by zero', () async {
    backend.reports = null;
    await player.play('a', fileA);
    backend.positionController.add(const Duration(seconds: 5));
    await pumpEventQueue();
    expect(player.progressFor('a').value, 0);
  });

  test('an idle player releases its engine', () async {
    final quick = VoicePlayer(
      backend: backend,
      idleTimeout: const Duration(milliseconds: 20),
    );
    await quick.play('a', fileA);
    await quick.pause();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(backend.disposals, greaterThan(0));
    expect(quick.activeHash, isNull);
    quick.dispose();
  });

  test('a player still playing is not released under itself', () async {
    final quick = VoicePlayer(
      backend: backend,
      idleTimeout: const Duration(milliseconds: 20),
    );
    await quick.play('a', fileA);
    await quick.pause();
    await quick.play('a', fileA);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(quick.activeHash, 'a');
    quick.dispose();
  });
}
