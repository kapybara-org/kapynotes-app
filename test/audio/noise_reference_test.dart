import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:denoise/denoise.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/speech/local_models.dart';

/// The real DPDFNet-2 against sherpa-onnx's own output on the same two
/// seconds, so any drift in the runner, the STFT or a prebuilt library fails
/// here. The model is downloaded, not in the repository: the Suite workflow
/// fetches the pinned file, checks its sha256 and names it in
/// KAPY_DENOISE_MODEL.
void main() {
  final model = Platform.environment['KAPY_DENOISE_MODEL'];
  const reference = 'packages/denoise/test/reference';

  test(
    'matches sherpa-onnx on the real model to 1e-4',
    () async {
      expect(
        sha256.convert(File(model!).readAsBytesSync()).toString(),
        noiseRemovalModel.files.single.sha256,
        reason: 'the model the app downloads',
      );
      final dir = await Directory.systemTemp.createTemp('kapy-reference');
      addTearDown(() => dir.delete(recursive: true));
      final output = '${dir.path}/out.pcm';
      await DenoiseRun.start(
        model: model,
        input: '$reference/input.pcm',
        output: output,
      ).done;

      final ours = File(output).readAsBytesSync().buffer.asInt16List();
      final sherpa = Float32List.view(
        File('$reference/sherpa.f32').readAsBytesSync().buffer,
      );
      expect(ours.length, sherpa.length);
      var worst = 0.0;
      for (var i = 0; i < ours.length; i++) {
        final difference = (ours[i] / 32768 - sherpa[i]).abs();
        if (difference > worst) worst = difference;
      }
      expect(worst, lessThanOrEqualTo(1e-4));
    },
    skip: model == null
        ? 'KAPY_DENOISE_MODEL names no DPDFNet-2 model here'
        : false,
  );
}
