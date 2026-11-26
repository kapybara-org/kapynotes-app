import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/audio/voice_recorder.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:record/record.dart';

/// The `record` plugin's native side, as far as looking for a microphone
/// reaches it.
class _FakeRecordPlatform extends RecordPlatform {
  _FakeRecordPlatform(this.devices);

  final List<InputDevice> devices;
  int asked = 0;

  @override
  Future<void> create(String recorderId) async {}

  @override
  Future<List<InputDevice>> listInputDevices(String recorderId) async {
    asked++;
    return devices;
  }

  @override
  Future<void> dispose(String recorderId) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RecordPlatform original;

  setUp(() => original = RecordPlatform.instance);
  tearDown(() {
    RecordPlatform.instance = original;
    AppPlatform.debugTargetPlatformOverride = null;
  });

  Future<bool> hasMicrophone(
    TargetPlatform platform,
    _FakeRecordPlatform fake,
  ) async {
    AppPlatform.debugTargetPlatformOverride = platform;
    RecordPlatform.instance = fake;
    final recorder = VoiceRecorder();
    addTearDown(recorder.dispose);
    return recorder.hasMicrophone();
  }

  for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
    test('${platform.name} with no input device has no microphone', () async {
      expect(await hasMicrophone(platform, _FakeRecordPlatform([])), isFalse);
    });

    test('${platform.name} with one has a microphone', () async {
      final fake = _FakeRecordPlatform([
        const InputDevice(id: 'built-in', label: 'MacBook Pro Microphone'),
      ]);
      expect(await hasMicrophone(platform, fake), isTrue);
    });
  }

  test('a phone is not asked: it always has one', () async {
    final fake = _FakeRecordPlatform([]);
    expect(await hasMicrophone(TargetPlatform.android, fake), isTrue);
    expect(await hasMicrophone(TargetPlatform.iOS, fake), isTrue);
    expect(fake.asked, 0);
  });
}
