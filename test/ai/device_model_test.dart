import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:kapy_notes/ai/device_model.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/speech/apple_summarizer.dart';
import 'package:kapy_notes/speech/gemma_summarizer.dart';
import 'package:kapy_notes/speech/local_model_store.dart';
import 'package:kapy_notes/speech/local_models.dart';

void main() {
  late Directory temp;
  late LocalModelStore models;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    temp = Directory.systemTemp.createTempSync('device-model');
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

  Future<DeviceModelState> stateFor({
    required String availability,
    required int memoryBytes,
  }) async {
    const channel = MethodChannel(AppleSummarizer.channelName);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'availability' => availability,
        'physicalMemory' => memoryBytes,
        _ => null,
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final device = PlatformDeviceModel(
      apple: AppleSummarizer(),
      gemma: GemmaSummarizer(models: models),
      models: models,
    );
    addTearDown(device.dispose);
    await device.refresh();
    return device.state;
  }

  const room = 8 * 1000 * 1000 * 1000;
  const tight = 2 * 1000 * 1000 * 1000;

  test('Apple Intelligence off falls through to Gemma', () async {
    final state = await stateFor(availability: 'disabled', memoryBytes: room);
    expect(state.status, DeviceModelStatus.notDownloaded);
    expect(state.model, PlatformDeviceModel.gemma);
    expect(state.note, isNull);
  });

  test('Apple Intelligence still downloading falls through to Gemma', () async {
    final state = await stateFor(availability: 'preparing', memoryBytes: room);
    expect(state.status, DeviceModelStatus.notDownloaded);
    expect(state.model, PlatformDeviceModel.gemma);
  });

  test('ready Apple Intelligence is the device model', () async {
    final state = await stateFor(availability: 'ready', memoryBytes: room);
    expect(state.status, DeviceModelStatus.builtIn);
    expect(state.model, PlatformDeviceModel.appleIntelligence);
  });

  test(
    'no room for Gemma, and Apple Intelligence off, says what would work',
    () async {
      final state = await stateFor(
        availability: 'disabled',
        memoryBytes: tight,
      );
      expect(state.model, isNull);
      expect(state.status, DeviceModelStatus.needsSystemFeature);
      expect(state.note, PlatformDeviceModel.appleOffNoRoom);
      expect(state.note, contains('System Settings'));
    },
  );
}
