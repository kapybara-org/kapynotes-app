import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:kapy_notes/core/device_memory.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/speech/gemma_summarizer.dart';
import 'package:kapy_notes/speech/local_model_store.dart';
import 'package:kapy_notes/speech/local_models.dart';
import 'package:kapy_notes/speech/summarizer.dart';

void main() {
  late Directory temp;
  late LocalModelStore models;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    temp = Directory.systemTemp.createTempSync('gemma-summarizer');
    models = LocalModelStore(
      catalogue: localSummaryModels,
      directory: temp,
      client: MockClient((_) async => fail('nothing here downloads')),
    );
    addTearDown(() {
      models.dispose();
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
  });

  test('with nothing downloaded it asks for the download', () async {
    final summarizer = GemmaSummarizer(models: models);

    expect(await summarizer.readiness(), SummarizerReadiness.needsDownload);
  });

  test('summarising without the model throws rather than loading one', () async {
    final summarizer = GemmaSummarizer(models: models);

    await expectLater(
      summarizer.summarize(text: 'a transcript', lang: 'en'),
      throwsA(
        isA<SummarizerUnavailable>()
            .having(
              (e) => e.readiness,
              'readiness',
              SummarizerReadiness.needsDownload,
            )
            // Worth coming back to, once the download has happened.
            .having((e) => e.isTemporary, 'isTemporary', isTrue),
      ),
    );
  });

  test('unloading something never loaded is not an error', () async {
    await GemmaSummarizer(models: models).unload();
  });

  group('memory', () {
    Future<bool> enoughWith(int bytes) {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.linux;
      final meminfo = File('${temp.path}/meminfo')
        ..writeAsStringSync('MemTotal: ${bytes ~/ 1024} kB\n');
      return GemmaSummarizer(
        models: models,
        memory: DeviceMemory(procMeminfo: meminfo),
      ).hasEnoughMemory();
    }

    test('a machine with room is allowed', () async {
      expect(await enoughWith(8 * 1000 * 1000 * 1000), isTrue);
    });

    test('a machine without it is not', () async {
      expect(await enoughWith(2 * 1000 * 1000 * 1000), isFalse);
    });

    test('an unmeasurable machine is allowed to try', () async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.windows;
      final summarizer = GemmaSummarizer(models: models);

      expect(await summarizer.hasEnoughMemory(), isTrue);
    });
  });

  test('it reads only what the bundle can hold', () {
    final summarizer = GemmaSummarizer(models: models);

    // Two thirds of the window, four characters to the token. The rest of the
    // context has to hold the instructions and the answer.
    expect(summarizer.maximumTranscriptChars, (4096 * 4 * 2) ~/ 3);
    // Sanity: that is minutes of speech, not seconds, and well under the
    // 30-minute recordings the app allows — which is why it is documented as
    // summarising from the beginning.
    expect(summarizer.maximumTranscriptChars, greaterThan(8000));
  });
}
