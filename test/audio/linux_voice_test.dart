@TestOn('linux')
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/audio/audio_decode.dart';
import 'package:kapy_notes/audio/linux_ffmpeg.dart';
import 'package:kapy_notes/audio/linux_voice_player.dart';
import 'package:kapy_notes/audio/linux_voice_recorder.dart';
import 'package:kapy_notes/audio/mp4_duration.dart';
import 'package:kapy_notes/audio/voice_recording_controller.dart';

/// Voice notes on Linux, through the real ffmpeg and a real PulseAudio
/// server: the rest of the suite runs against fakes, so this is the only
/// place that finds out whether recording, decoding and playback work here.
///
/// Skipped where ffmpeg cannot capture from a sound server. A machine with no
/// sound card gets one, with a microphone that hears a tone and a speaker
/// nobody hears, from `headless_pulse.sh`:
///
///     bash test/audio/headless_pulse.sh
///     flutter test test/audio/linux_voice_test.dart
void main() {
  final skip = _canCapture()
      ? false
      : 'needs ffmpeg on PATH and a PulseAudio server to capture from';

  group('a microphone', () {
    // What ffmpeg 7.1's `-sources pulse` prints, read off a PulseAudio
    // server with nothing but its null sink, then with a source added.
    const nullSinkOnly = '''
Auto-detected sources for pulse:
* auto_null.monitor [Monitor of Dummy Output] (none)
''';
    const withSource = '''
Auto-detected sources for pulse:
  auto_null.monitor [Monitor of Dummy Output] (none)
* fakemic [Null Input] (none)
''';

    test('is a source that is not a monitor', () {
      expect(LinuxVoiceRecorder.listsMicrophone(withSource), isTrue);
    });

    test('is not an output\'s monitor, which records silence', () {
      expect(LinuxVoiceRecorder.listsMicrophone(nullSinkOnly), isFalse);
    });

    test('is not there when there is no sound server to ask', () {
      expect(LinuxVoiceRecorder.listsMicrophone(''), isFalse);
      expect(
        LinuxVoiceRecorder.listsMicrophone(
          'Auto-detected sources for pulse:\n',
        ),
        isFalse,
      );
    });
  });

  late Directory temp;
  late VoiceRecordingController controller;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('kapy-linux-voice');
    controller = VoiceRecordingController(
      recorder: LinuxVoiceRecorder(),
      tempDirectory: temp,
    );
  });

  tearDown(() async {
    controller.dispose();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  group('recording', () {
    test('stops into an .m4a whose header has its length', () async {
      expect(await controller.start(noteId: 'n1'), isTrue);
      await Future<void>.delayed(const Duration(seconds: 3));
      final result = await controller.stop();

      expect(result, isNotNull);
      final ms = mp4DurationMs(await result!.file.readAsBytes());
      expect(ms, isNotNull, reason: 'the encoder did not finish the file');
      expect(ms, inInclusiveRange(2500, 3500));
      expect(result.duration, Duration(milliseconds: ms!));
      expect(result.peaks, hasLength(100));
      expect(_capturing(), isEmpty);
    }, skip: skip);

    test('a pause is not in the file', () async {
      expect(await controller.start(noteId: 'n1'), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      await controller.pause();
      expect(
        _capturing(),
        isEmpty,
        reason: 'a paused recording holds no microphone',
      );
      await Future<void>.delayed(const Duration(seconds: 3));
      await controller.resume();
      expect(controller.session!.paused, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final result = await controller.stop();

      // Three seconds recorded around a three-second pause. Six would mean
      // the pause was recorded too.
      final ms = mp4DurationMs(await result!.file.readAsBytes());
      expect(ms, inInclusiveRange(2500, 3700));
    }, skip: skip);

    test(
      'stopping while paused finishes the file and frees the microphone',
      () async {
        expect(await controller.start(noteId: 'n1'), isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        await controller.pause();
        final result = await controller.stop();

        expect(mp4DurationMs(await result!.file.readAsBytes()), isNotNull);
        expect(_capturing(), isEmpty);
      },
      skip: skip,
    );

    test('cancelling leaves nothing on disk or on the microphone', () async {
      expect(await controller.start(noteId: 'n1'), isTrue);
      await Future<void>.delayed(const Duration(seconds: 1));
      await controller.cancel();

      expect(await temp.list().toList(), isEmpty);
      expect(_capturing(), isEmpty);
    }, skip: skip);

    test(
      'the speech model gets 16 kHz mono samples of the whole recording',
      () async {
        expect(await controller.start(noteId: 'n1'), isTrue);
        await Future<void>.delayed(const Duration(seconds: 2));
        final result = await controller.stop();

        final decoded = await const AudioDecoder().decode(result!.file);
        addTearDown(decoded.dispose);
        expect(decoded.sampleRate, 16000);
        expect(
          decoded.duration.inMilliseconds,
          closeTo(result.duration.inMilliseconds, 100),
        );
        await decoded.dispose();
        expect(await decoded.file.exists(), isFalse);
      },
      skip: skip,
    );
  });

  group('playback', () {
    late LinuxVoicePlayerBackend player;
    final positions = <Duration>[];
    late StreamSubscription<Duration> listening;

    setUp(() {
      player = LinuxVoicePlayerBackend();
      positions.clear();
      listening = player.positions.listen(positions.add);
    });

    tearDown(() async {
      await listening.cancel();
      await player.dispose();
    });

    /// How long it takes [player] to reach the end of what is left.
    Future<Duration> untilDone() async {
      final clock = Stopwatch()..start();
      await player.completions.first.timeout(const Duration(seconds: 15));
      return clock.elapsed;
    }

    test('plays to the end, and says so', () async {
      final length = await player.load(File('test/fixtures/tone_5s.m4a'));
      expect(length!.inMilliseconds, closeTo(5000, 50));

      await player.play();
      expect(_playing(), hasLength(1));
      final took = await untilDone();

      // Paced by PulseAudio rather than written out at decoding speed. The
      // top end is loose: a null sink in a virtual machine can take half as
      // long again, and playing it twice would still be past it.
      expect(took.inMilliseconds, inInclusiveRange(4800, 9000));
      expect(positions.last, length);
      expect(_playing(), isEmpty);
    }, skip: skip);

    test('pausing silences it and keeps its place', () async {
      await player.load(File('test/fixtures/tone_5s.m4a'));
      await player.play();
      await Future<void>.delayed(const Duration(seconds: 1));
      await player.pause();
      await Future<void>.delayed(Duration.zero);
      final paused = positions.last;

      // Counted from the first samples, which come a moment after play.
      expect(paused.inMilliseconds, inInclusiveRange(600, 1300));
      expect(_playing(), isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(positions.last, paused);

      await player.play();
      final took = await untilDone();
      expect(took.inMilliseconds, inInclusiveRange(3600, 8000));
    }, skip: skip);

    test('a seek and a faster speed both reach ffmpeg', () async {
      await player.load(File('test/fixtures/tone_5s.m4a'));
      await player.setSpeed(2);
      await player.seek(const Duration(seconds: 3));
      await player.play();

      final decoders = _decoders();
      expect(decoders, hasLength(1));
      expect(decoders.single, containsAllInOrder(['-ss', '3.000', '-i']));
      expect(decoders.single, contains('atempo=2.0'));

      // Two seconds left at twice the speed: one second of sound, where all
      // five at normal speed would mean neither took.
      final took = await untilDone();
      expect(took.inMilliseconds, inInclusiveRange(900, 4000));
    }, skip: skip);

    test(
      'a run of seeks while playing starts one player, once they stop',
      () async {
        await player.load(File('test/fixtures/tone_5s.m4a'));
        await player.play();
        for (var ms = 1000; ms <= 4000; ms += 100) {
          await player.seek(Duration(milliseconds: ms));
          await Future<void>.delayed(const Duration(milliseconds: 16));
        }
        expect(
          _playing(),
          isEmpty,
          reason: 'still dragging: nothing should play',
        );

        final took = await untilDone();
        expect(took.inMilliseconds, inInclusiveRange(1100, 3500));
      },
      skip: skip,
    );

    test('a file with no header will not open', () async {
      final broken = File('${temp.path}/broken.m4a')
        ..writeAsBytesSync([0, 0, 0, 8]);

      await expectLater(player.load(broken), throwsFormatException);
    }, skip: skip);
  });
}

/// Whether ffmpeg on PATH can capture from the default PulseAudio source.
bool _canCapture() {
  try {
    final probe = Process.runSync(ffmpegExecutable, [
      '-nostdin',
      '-loglevel',
      'error',
      '-f',
      'pulse',
      '-i',
      'default',
      '-t',
      '0.2',
      '-f',
      's16le',
      '-',
    ], stdoutEncoding: null);
    return probe.exitCode == 0 && (probe.stdout as List<int>).isNotEmpty;
  } on ProcessException {
    return false;
  }
}

/// This process's ffmpegs reading from PulseAudio: a microphone held open.
List<int> _capturing() =>
    _children((arguments) => _before(arguments, '-i', 'pulse'));

/// This process's ffmpegs writing to PulseAudio: something audible.
List<int> _playing() => _children(
  (arguments) =>
      arguments.contains('pulse') && !_before(arguments, '-i', 'pulse'),
);

/// The arguments of this process's ffmpegs decoding a recording to play.
List<List<String>> _decoders() => [
  for (final id in _children(
    (arguments) => arguments.contains('-ss') && arguments.contains('pipe:1'),
  ))
    _argumentsOf(id),
];

bool _before(List<String> arguments, String marker, String value) {
  final at = arguments.indexOf(marker);
  return at > 0 && arguments.sublist(0, at).contains(value);
}

List<int> _children(bool Function(List<String> arguments) matches) => [
  for (final entry in Directory('/proc').listSync())
    if (int.tryParse(entry.uri.pathSegments.where((s) => s.isNotEmpty).last)
        case final id?)
      if (_parentOf(id) == pid && matches(_argumentsOf(id))) id,
];

int? _parentOf(int id) {
  try {
    final status = File('/proc/$id/status').readAsLinesSync();
    final line = status.firstWhere((line) => line.startsWith('PPid:'));
    return int.parse(line.substring(5).trim());
  } on Object {
    return null;
  }
}

List<String> _argumentsOf(int id) {
  try {
    return File('/proc/$id/cmdline').readAsStringSync().split('\u0000');
  } on Object {
    return const [];
  }
}
