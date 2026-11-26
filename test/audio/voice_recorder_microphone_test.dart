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

  test('a Mac with no input device has no microphone', () async {
    expect(
      await hasMicrophone(TargetPlatform.macOS, _FakeRecordPlatform([])),
      isFalse,
    );
  });

  test('a Mac with one has a microphone', () async {
    final fake = _FakeRecordPlatform([
      const InputDevice(id: 'built-in', label: 'MacBook Pro Microphone'),
    ]);
    expect(await hasMicrophone(TargetPlatform.macOS, fake), isTrue);
  });

  test('Windows and the phones are not asked, and record as before', () async {
    final fake = _FakeRecordPlatform([]);
    for (final platform in [
      TargetPlatform.windows,
      TargetPlatform.android,
      TargetPlatform.iOS,
    ]) {
      expect(
        await hasMicrophone(platform, fake),
        isTrue,
        reason: platform.name,
      );
    }
    expect(fake.asked, 0);
  });
}
