
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/speech/gemma_summarizer.dart';
import 'package:kapy_notes/speech/local_model_store.dart';
import 'package:kapy_notes/speech/local_models.dart';

/// The only test that can answer "does the local summariser actually work".
///
/// `flutter test` runs against fakes: there is no plugin registrar, no native
/// library and no 2.6 GB of weights, so everything under `test/` can check the
/// guards around the model and nothing about the model. This runs the real
/// engine on the real bundle.
///
/// It skips itself when the model is not installed, which is every machine
/// that has not downloaded it — including CI. Install it by pressing Download
/// in Settings, or by dropping the file into the store's directory.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('Gemma writes a summary of a transcript, on this machine', () async {
    final models = LocalModelStore(catalogue: localSummaryModels);
    await models.refresh();
    if (models.stateOf(gemma4E2bIt).status != LocalModelStatus.ready) {
      // ignore: avoid_print
      print('SKIP: ${gemma4E2bIt.name} is not downloaded on this machine.');
      return;
    }

    final summarizer = GemmaSummarizer(models: models);
    addTearDown(summarizer.unload);

    const transcript = '''
Okay so quick thoughts before standup tomorrow. The export bug that Priya
found is actually in the zip writer, not in the markdown, I traced it
yesterday evening and it only shows up when a note has an attachment. I want
to ship the fix today if review is quick. Also I still owe the landlord a
reply about the boiler service, they wanted Thursday morning but I have the
dentist then, so I need to suggest Friday instead. And I should book the
train to Leeds before the prices go up again.
''';

    final started = DateTime.now();
    final draft = await summarizer.summarize(text: transcript, lang: 'en');
    final elapsed = DateTime.now().difference(started);

    // ignore: avoid_print
    print('ELAPSED: ${elapsed.inMilliseconds} ms');
    // ignore: avoid_print
    print('TITLE: ${draft.title}');
    for (final point in draft.points) {
      // ignore: avoid_print
      print('POINT: $point');
    }

    expect(draft.engine, GemmaSummarizer.engineId);
    expect(draft.title, isNotEmpty);
    expect(draft.points, isNotEmpty);
    // A summary that is longer than what it summarises is not one.
    expect(draft.points.join(' ').length, lessThan(transcript.length));

    // Unloading has to actually give the memory back, and has to be safe to
    // call twice — the idle timer and a backgrounding can both reach it.
    await summarizer.unload();
    await summarizer.unload();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
