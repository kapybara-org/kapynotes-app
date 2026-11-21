import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/audio/audio_decode.dart';
import 'package:kapy_notes/speech/local_model_store.dart';
import 'package:kapy_notes/speech/local_models.dart';
import 'package:kapy_notes/speech/sherpa_transcriber.dart';
import 'package:kapy_notes/speech/transcriber.dart';

/// The only test that can answer "does the local recogniser actually work".
///
/// `flutter test` runs against fakes: there is no plugin registrar, no native
/// library and no 670 MB of weights, so everything under `test/` can check the
/// guards around the model and nothing about the model. This runs the real
/// engine, through the real decoder, on a real recording.
///
/// It skips itself when the model is not installed, which is every machine
/// that has not downloaded it — including CI. Install it by pressing Download
/// in Settings, or by dropping the four files into the store's directory,
/// whose path this prints when it finds nothing.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('Parakeet turns a recording into words, on this machine', () async {
    final models = LocalModelStore(catalogue: localSpeechModels);
    await models.refresh();
    if (models.stateOf(parakeetTdt06bV3Int8).status != LocalModelStatus.ready) {
      final where = await models.directoryFor(parakeetTdt06bV3Int8);
      // ignore: avoid_print
      print('SKIP: ${parakeetTdt06bV3Int8.name} is not downloaded.');
      // ignore: avoid_print
      print('SKIP: expected its four files in ${where.path}');
      return;
    }

    // The fixture is exactly what the recorder makes: AAC-LC, mono, 16 kHz,
    // 48 kbps — see `VoiceRecorder.config`. Anything else would be testing a
    // decode this app never has to do.
    //
    // Looked for beside the models rather than in the repo, because the app
    // is sandboxed on macOS and cannot read the project directory. Copy
    // `test/fixtures/speech.m4a` next to `speech-models` to run this.
    final support = (await models.directoryFor(parakeetTdt06bV3Int8)).parent.parent;
    final recording = File('${support.path}/speech.m4a');
    if (!recording.existsSync()) {
      // ignore: avoid_print
      print('SKIP: put test/fixtures/speech.m4a at ${recording.path}');
      return;
    }

    // The decode is half of what is being tested. A recogniser that works on
    // samples somebody else prepared proves nothing about this app.
    final decoded = await const AudioDecoder().decode(recording);
    addTearDown(decoded.dispose);
    // ignore: avoid_print
    print('DECODED: ${decoded.frames} frames at ${decoded.sampleRate} Hz '
        '(${decoded.duration.inMilliseconds} ms)');
    expect(decoded.sampleRate, 16000);
    expect(decoded.frames, greaterThan(0));

    final transcriber = SherpaTranscriber(models: models);
    expect(await transcriber.readiness(), TranscriberReadiness.ready);

    final started = DateTime.now();
    final draft = await transcriber.transcribe(
      audio: recording,
      requestId: 'integration',
    );
    final elapsed = DateTime.now().difference(started);

    // ignore: avoid_print
    print('ELAPSED: ${elapsed.inMilliseconds} ms for '
        '${decoded.duration.inMilliseconds} ms of audio '
        '(${(decoded.duration.inMilliseconds / elapsed.inMilliseconds).toStringAsFixed(1)}x real time)');
    for (final segment in draft.segments) {
      // ignore: avoid_print
      print('SEGMENT [${segment.s}-${segment.e}] ${segment.t}');
    }

    expect(draft.engine, 'sherpa/parakeet-tdt-0.6b-v3-int8');
    expect(
      draft.jobId,
      isNull,
      reason: 'nothing was billed, so there is nothing to ask about later',
    );
    expect(draft.segments, isNotEmpty);

    final text = draft.segments.map((s) => s.t).join(' ').toLowerCase();
    // Checking the content rather than merely that something came back is the
    // difference between "the engine ran" and "the engine works". Both
    // fixtures say these.
    expect(text, anyOf(contains('milk'), contains('foundations')));

    // More than one segment on anything longer than a sentence. One segment
    // for a whole recording is what a broken word-boundary rule looks like,
    // and it is invisible unless something asserts against it: the text is
    // perfect and only the timings are gone.
    if (decoded.duration.inSeconds > 20) {
      expect(
        draft.segments.length,
        greaterThan(1),
        reason: 'sentences have to be separable for playback to follow them',
      );
    }

    // Times have to be real and ordered, or playback cannot follow them.
    expect(draft.segments.first.s, lessThan(draft.segments.first.e));
    for (var i = 1; i < draft.segments.length; i++) {
      expect(
        draft.segments[i].s,
        greaterThanOrEqualTo(draft.segments[i - 1].s),
        reason: 'segments arrive in the order they were spoken',
      );
    }
    expect(
      draft.segments.last.e,
      lessThanOrEqualTo(decoded.duration.inMilliseconds + 1000),
      reason: 'nothing is said after the recording ends',
    );
  }, timeout: const Timeout(Duration(minutes: 10)));
}
