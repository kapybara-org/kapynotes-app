import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/audio/voice_export.dart';
import 'package:kapy_notes/core/file_export.dart';
import 'package:kapy_notes/core/platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late File audio;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('voice-export-');
    audio = File('${temp.path}/blob')..writeAsBytesSync([1, 2, 3, 4]);
  });

  tearDown(() async {
    AppPlatform.debugTargetPlatformOverride = null;
    await temp.delete(recursive: true);
  });

  group('on a computer', () {
    setUp(() => AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS);

    test('saves a copy where the person chose, under the title', () async {
      String? suggested;
      voiceSaveLocation = (name) async {
        suggested = name;
        return '${temp.path}/chosen.m4a';
      };

      final outcome = await exportVoiceAudio(
        locate: () async => audio,
        title: 'Pricing: plan / Arjun',
      );

      expect(outcome, VoiceExportOutcome.done);
      expect(suggested, 'Pricing plan Arjun.m4a');
      expect(File('${temp.path}/chosen.m4a').readAsBytesSync(), [1, 2, 3, 4]);
    });

    test('a closed save panel writes nothing', () async {
      voiceSaveLocation = (_) async => null;
      final outcome = await exportVoiceAudio(
        locate: () async => audio,
        title: 'Voice note',
      );
      expect(outcome, VoiceExportOutcome.cancelled);
    });

    test('says when the audio is not on this device', () async {
      var asked = false;
      voiceSaveLocation = (_) async {
        asked = true;
        return null;
      };
      final outcome = await exportVoiceAudio(
        locate: () async => null,
        title: 'Voice note',
      );
      expect(outcome, VoiceExportOutcome.notDownloaded);
      expect(asked, isFalse);
    });

    test('a copy that fails leaves nothing under the chosen name', () async {
      final target = '${temp.path}/chosen.m4a';
      voiceSaveLocation = (_) async => target;
      final outcome = await exportVoiceAudio(
        locate: () async => File('${temp.path}/gone'),
        title: 'Voice note',
      );
      expect(outcome, VoiceExportOutcome.failed);
      expect(File(target).existsSync(), isFalse);
    });

    test('a locator that throws is a failure, not a crash', () async {
      final outcome = await exportVoiceAudio(
        locate: () async => throw const SocketException('offline'),
        title: 'Voice note',
      );
      expect(outcome, VoiceExportOutcome.failed);
    });

    test('a title that names no file is saved as Voice note', () async {
      String? suggested;
      voiceSaveLocation = (name) async {
        suggested = name;
        return null;
      };
      await exportVoiceAudio(locate: () async => audio, title: ' / : ');
      expect(suggested, 'Voice note.m4a');
    });
  });

  group('on a phone', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late List<MethodCall> calls;
    late bool copyThere;

    setUp(() {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      voiceSaveFolder = () async => Directory('${temp.path}/kapy-voice');
      calls = [];
    });

    tearDown(
      () => messenger.setMockMethodCallHandler(FileExport.channel, null),
    );

    void answer(Object? Function() reply) =>
        messenger.setMockMethodCallHandler(FileExport.channel, (call) async {
          calls.add(call);
          final path = (call.arguments as Map)['path'] as String;
          copyThere = File(path).existsSync();
          return reply();
        });

    test('offers a named copy to the system picker, then clears it', () async {
      answer(() => 'Standup.m4a');

      final outcome = await exportVoiceAudio(
        locate: () async => audio,
        title: 'Standup',
      );

      expect(outcome, VoiceExportOutcome.done);
      expect(calls.single.method, 'save');
      final arguments = calls.single.arguments as Map;
      expect(arguments['path'], '${temp.path}/kapy-voice/Standup.m4a');
      expect(arguments['suggestedName'], 'Standup.m4a');
      expect(arguments['mimeType'], 'audio/mp4');
      expect(copyThere, isTrue);
      expect(File(arguments['path'] as String).existsSync(), isFalse);
    });

    test('a dismissed picker is a cancel', () async {
      answer(() => null);
      final outcome = await exportVoiceAudio(
        locate: () async => audio,
        title: 'Standup',
      );
      expect(outcome, VoiceExportOutcome.cancelled);
    });

    test('a picker that could not write is a failure', () async {
      answer(() => throw PlatformException(code: 'write-failed'));
      final outcome = await exportVoiceAudio(
        locate: () async => audio,
        title: 'Standup',
      );
      expect(outcome, VoiceExportOutcome.failed);
    });
  });
}
