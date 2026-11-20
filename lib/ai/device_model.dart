import 'dart:async';

import 'package:flutter/foundation.dart';

import '../speech/apple_summarizer.dart';
import '../speech/gemma_summarizer.dart';
import '../speech/local_model_store.dart';
import '../speech/local_models.dart';
import '../speech/summarizer.dart';
import 'answer_engine.dart';
import 'kapy_ai.dart';

/// This device's own model, as Kapy AI sees it: which one, whether it is
/// here, and the way to get it.
///
/// Abstract so the controller's download states can be tested without 2.6 GB
/// or a runner; [PlatformDeviceModel] is the one the app uses.
abstract class DeviceModel extends ChangeNotifier implements AnswerEngine {
  DeviceModelState get state;

  /// How many characters of notes fit beside the question and the answer.
  int get noteChars;

  /// Asks the platform and the disk again. Never downloads anything.
  Future<void> refresh();

  void download();
  void cancel();
  Future<void> remove();

  /// Whether a download now would spend mobile data.
  Future<bool> onMobileData();

  /// Downloads once the phone is on Wi-Fi.
  void downloadOnWifi();
}

/// Apple Intelligence where it is ready, and Gemma everywhere else.
///
/// The same two the voice summaries use, and the same objects: one
/// [GemmaSummarizer] means one copy of the weights in memory whichever
/// feature asked, and one [LocalModelStore] means one download.
class PlatformDeviceModel extends DeviceModel {
  PlatformDeviceModel({
    required AppleSummarizer apple,
    required GemmaSummarizer gemma,
    required LocalModelStore models,
    LocalSummaryModel model = gemma4E2bIt,
  }) : _apple = apple,
       _gemma = gemma,
       _models = models,
       _model = model {
    _models.addListener(notifyListeners);
  }

  final AppleSummarizer _apple;
  final GemmaSummarizer _gemma;
  final LocalModelStore _models;
  final LocalSummaryModel _model;

  static const KapyModel appleIntelligence = KapyModel(
    kind: KapyModelKind.device,
    id: 'apple',
    label: 'Apple Intelligence',
  );

  static const KapyModel gemma = KapyModel(
    kind: KapyModelKind.device,
    id: 'gemma',
    label: 'On this device',
  );

  /// Apple Intelligence is installed but off, and the downloadable model
  /// cannot run here. Names the switch, because that is what the person has
  /// to find in System Settings.
  static const String appleOffNoRoom =
      'Turn on Apple Intelligence in System Settings, or use Kapy AI Cloud '
      'with Pro.';

  /// Apple Intelligence is still downloading, and the downloadable model
  /// cannot run here.
  static const String applePreparingNoRoom =
      'Apple Intelligence is still downloading. Until then, Kapy AI Cloud '
      'with Pro can answer.';

  /// Unknown until [refresh] has asked: both answers are a channel call or
  /// a disk scan, and neither belongs in a constructor.
  SummarizerReadiness? _appleReadiness;
  bool _gemmaFits = false;

  @override
  DeviceModelState get state {
    final apple = _appleReadiness;
    // Ready is the only state in which Apple Intelligence answers. Off, or
    // still downloading, falls through to Gemma rather than blocking it.
    if (apple == SummarizerReadiness.ready) {
      return const DeviceModelState(
        status: DeviceModelStatus.builtIn,
        model: appleIntelligence,
      );
    }
    if (_gemmaFits) {
      final local = _models.stateOf(_model);
      return DeviceModelState(
        status: switch (local.status) {
          LocalModelStatus.ready => DeviceModelStatus.ready,
          LocalModelStatus.fetchingRuntime ||
          LocalModelStatus.downloading ||
          LocalModelStatus.verifying => DeviceModelStatus.downloading,
          // Waiting for Wi-Fi is still not here: asking again offers the
          // download again, now or later.
          LocalModelStatus.absent ||
          LocalModelStatus.failed ||
          LocalModelStatus.waitingForWifi => DeviceModelStatus.notDownloaded,
        },
        model: gemma,
        receivedBytes: local.receivedBytes,
        totalBytes: local.totalBytes > 0 ? local.totalBytes : _model.bytes,
      );
    }
    return switch (apple) {
      SummarizerReadiness.needsSystemFeature => const DeviceModelState(
        status: DeviceModelStatus.needsSystemFeature,
        note: appleOffNoRoom,
      ),
      SummarizerReadiness.preparing => const DeviceModelState(
        status: DeviceModelStatus.needsSystemFeature,
        note: applePreparingNoRoom,
      ),
      _ => const DeviceModelState(status: DeviceModelStatus.unavailable),
    };
  }

  /// Apple's model has a 4,096-token context like Gemma's, so it gets the
  /// same share: two thirds of it, at four characters to the token.
  @override
  int get noteChars => _gemma.maximumTranscriptChars;

  @override
  Future<void> refresh() async {
    _appleReadiness = await _apple.readiness();
    _gemmaFits =
        GemmaSummarizer.isPossibleHere && await _gemma.hasEnoughMemory();
    if (_gemmaFits) await _models.refresh();
    notifyListeners();
  }

  @override
  void download() => _models.download(_model);

  @override
  Future<bool> onMobileData() => _models.mobileData.inUse();

  @override
  void downloadOnWifi() => unawaited(_models.downloadOnWifi(_model));

  @override
  void cancel() => _models.cancel(_model);

  @override
  Future<void> remove() => _models.remove(_model);

  @override
  Future<String> answer(KapyModel model, AnswerRequest request) async {
    final instructions = answerInstructions(request.today);
    final prompt = answerPrompt(request);
    try {
      return state.model == appleIntelligence
          ? await _apple.answer(instructions: instructions, prompt: prompt)
          : await _gemma.answer(instructions: instructions, prompt: prompt);
    } on SummarizerUnavailable catch (error) {
      throw AnswerFailed(error.message);
    }
  }

  @override
  void dispose() {
    _models.removeListener(notifyListeners);
    super.dispose();
  }
}
