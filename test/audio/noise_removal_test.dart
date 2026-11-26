import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:denoise/denoise.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/audio/audio_decode.dart';
import 'package:kapy_notes/audio/noise_removal.dart';
import 'package:kapy_notes/data/clean_copies.dart';

/// DPDFNet-2's inputs, outputs and metadata around a graph that passes both
/// straight through: the real signal path, minus the 10 MB model.
const String identityModel = 'packages/denoise/test/identity.onnx';

/// What the model's look-ahead moves the waveform back by, in samples.
const int lookahead = 640;

final String hash = 'ab' * 32;

Int16List speech(int n) {
  final random = Random(7);
  return Int16List.fromList([
    for (var i = 0; i < n; i++)
      (9000 * sin(i * 0.07) + 2000 * (random.nextDouble() - 0.5)).round(),
  ]);
}

Future<File> writePcm(Directory dir, String name, Int16List samples) =>
    File('${dir.path}/$name').writeAsBytes(samples.buffer.asUint8List());

Int16List readPcm(File file) => file.readAsBytesSync().buffer.asInt16List();

/// The identity model hands each frame back, so the cleaned copy is the input
/// moved earlier by the look-ahead, give or take a rounding.
void expectShifted(Int16List input, Int16List output) {
  expect(output.length, input.length);
  final real = input.length ~/ 160 * 160 - lookahead;
  for (var i = 0; i < real; i++) {
    expect(
      (output[i] - input[i + lookahead]).abs(),
      lessThanOrEqualTo(1),
      reason: 'sample $i',
    );
  }
  expect(output.sublist(real).every((s) => s == 0), isTrue);
}

class FakeDecoder extends AudioDecoder {
  FakeDecoder(this.dir, this.samples);

  final Directory dir;
  final Int16List samples;
  File? written;

  @override
  Future<DecodedAudio> decode(File source, {int sampleRate = 16000}) async {
    final file = written = await writePcm(dir, 'decoded.pcm', samples);
    return DecodedAudio(
      file: file,
      sampleRate: sampleRate,
      frames: samples.length,
    );
  }
}

void main() {
  late Directory dir;

  setUp(
    () async => dir = await Directory.systemTemp.createTemp('kapy-denoise'),
  );
  tearDown(() => dir.delete(recursive: true));

  group('the library', () {
    test('is in this build', () => expect(denoiseAvailable, isTrue));

    test(
      'cleans a file into one the same length, and reports it all done',
      () async {
        final input = speech(16000 + 77);
        final pcm = await writePcm(dir, 'in.pcm', input);
        final out = File('${dir.path}/out.pcm');
        final run = DenoiseRun.start(
          model: identityModel,
          input: pcm.path,
          output: out.path,
        );
        await run.done;
        expect(run.progress, 1.0);
        expectShifted(input, readPcm(out));
      },
    );

    test('refuses a file that is not the model', () async {
      final pcm = await writePcm(dir, 'in.pcm', speech(16000));
      final run = DenoiseRun.start(
        model: pcm.path,
        input: pcm.path,
        output: '${dir.path}/out.pcm',
      );
      await expectLater(
        run.done,
        throwsA(
          isA<DenoiseException>().having(
            (e) => e.failure,
            'failure',
            DenoiseFailure.badModel,
          ),
        ),
      );
    });

    test('stops when cancelled', () async {
      final pcm = await writePcm(dir, 'in.pcm', speech(16000 * 60));
      final run = DenoiseRun.start(
        model: identityModel,
        input: pcm.path,
        output: '${dir.path}/out.pcm',
      )..cancel();
      await expectLater(
        run.done,
        throwsA(
          isA<DenoiseException>().having(
            (e) => e.failure,
            'failure',
            DenoiseFailure.cancelled,
          ),
        ),
      );
    });
  });

  group('NoiseRemover', () {
    late CleanCopies copies;
    late FakeDecoder decoder;
    late Int16List input;
    File? encodedFrom;

    Future<void> copyEncode(File pcm, File destination) async {
      encodedFrom = pcm;
      await pcm.copy(destination.path);
    }

    setUp(() {
      copies = CleanCopies(directory: Directory('${dir.path}/clean'));
      input = speech(16000 * 3 + 5);
      decoder = FakeDecoder(dir, input);
      encodedFrom = null;
    });

    NoiseRemovalRun clean(
      NoiseRemover remover, {
      String model = identityModel,
    }) => remover.clean(
      recording: File('${dir.path}/original.m4a'),
      hash: hash,
      model: File(model),
    );

    test(
      'writes the cleaned copy under the recording\'s hash and tidies up',
      () async {
        final run = clean(
          NoiseRemover(copies: copies, decoder: decoder, encode: copyEncode),
        );
        final copy = await run.done;
        expect(copy.path, (await copies.fileFor(hash)).path);
        expectShifted(input, readPcm(copy));
        expect(run.progress.value, 1.0);
        expect(decoder.written!.existsSync(), isFalse);
        expect(encodedFrom!.existsSync(), isFalse);
        expect(
          Directory(
            '${dir.path}/clean',
          ).listSync().map((f) => f.uri.pathSegments.last),
          ['$hash.m4a'],
        );
      },
    );

    test('leaves nothing behind when cancelled', () async {
      decoder = FakeDecoder(dir, speech(16000 * 60));
      final run = clean(
        NoiseRemover(copies: copies, decoder: decoder, encode: copyEncode),
      )..cancel();
      await expectLater(
        run.done,
        throwsA(
          isA<NoiseRemovalException>().having(
            (e) => e.failure,
            'failure',
            NoiseRemovalFailure.cancelled,
          ),
        ),
      );
      expect(await copies.existing(hash), isNull);
      expect(decoder.written!.existsSync(), isFalse);
      expect(dir.listSync().whereType<File>(), isEmpty);
    });

    test('says the model is the problem when it is', () async {
      final run = clean(
        NoiseRemover(copies: copies, decoder: decoder, encode: copyEncode),
        model: '${dir.path}/missing.onnx',
      );
      await expectLater(
        run.done,
        throwsA(
          isA<NoiseRemovalException>().having(
            (e) => e.failure,
            'failure',
            NoiseRemovalFailure.model,
          ),
        ),
      );
      expect(await copies.existing(hash), isNull);
    });

    test(
      'says the recording is the problem when it cannot be decoded',
      () async {
        final run = clean(
          NoiseRemover(
            copies: copies,
            decoder: const _BrokenDecoder(),
            encode: copyEncode,
          ),
        );
        await expectLater(
          run.done,
          throwsA(
            isA<NoiseRemovalException>().having(
              (e) => e.failure,
              'failure',
              NoiseRemovalFailure.recording,
            ),
          ),
        );
      },
    );

    test('leaves no copy and no temporary files when encoding fails', () async {
      Future<void> failingEncode(File pcm, File destination) async {
        throw const AudioEncodeException('This recording could not be saved.');
      }

      final run = clean(
        NoiseRemover(copies: copies, decoder: decoder, encode: failingEncode),
      );
      await expectLater(run.done, throwsA(isA<NoiseRemovalException>()));
      expect(await copies.existing(hash), isNull);
      expect(Directory('${dir.path}/clean').listSync(), isEmpty);
      expect(dir.listSync().whereType<File>(), isEmpty);
    });
  });

  group('CleanCopies', () {
    test('refuses anything but a hash as a name', () async {
      final copies = CleanCopies(directory: dir);
      expect(() => copies.fileFor('../../notes'), throwsArgumentError);
      expect(() => copies.fileFor('AB' * 32), throwsArgumentError);
    });

    test(
      'sweeps copies no note refers to and stale debris, and keeps the rest',
      () async {
        var now = DateTime.now();
        final copies = CleanCopies(directory: dir, now: () => now);
        final live = 'aa' * 32, dead = 'dd' * 32;
        for (final name in ['$live.m4a', '$dead.m4a', '$live.m4a.123.tmp']) {
          await File('${dir.path}/$name').writeAsBytes([1, 2, 3, 4]);
        }
        expect(
          await copies.sweep({live}),
          0,
          reason: 'everything is still fresh',
        );
        now = now.add(const Duration(minutes: 11));
        expect(await copies.sweep({live}), 8);
        expect(dir.listSync().map((f) => f.uri.pathSegments.last), [
          '$live.m4a',
        ]);
      },
    );
  });
}

class _BrokenDecoder extends AudioDecoder {
  const _BrokenDecoder();

  @override
  Future<DecodedAudio> decode(File source, {int sampleRate = 16000}) =>
      throw const AudioDecodeException('This recording could not be read.');
}
