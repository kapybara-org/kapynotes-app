import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What a recording does when someone presses one of the buttons the phone
/// shows outside the app.
enum RecordingCommand { pause, resume, stop }

/// The recording as the phone shows it while the app is out of sight, and the
/// buttons on it.
///
/// On Android this is a foreground service of type microphone, which is the
/// only way Android lets the microphone stay open with the screen off, and
/// the ongoing notification every such service carries. On the iPhone it is a
/// Live Activity on the Lock Screen and in the Dynamic Island; there the
/// `audio` background mode is what keeps the recorder running.
///
/// None of it stands in the recording's way. A phone that cannot show any of
/// it (an iPhone below iOS 16.1, somebody who said no to notifications) still
/// records the same, and every failure here is logged, never thrown.
abstract class RecordingControls {
  /// Asks, the first time anybody records, for what showing them needs: on
  /// Android 13 and later, permission to post notifications. Resolves once the
  /// question is answered, whatever the answer. Never awaited before a
  /// recording starts, so a question nobody answers cannot hold one up.
  Future<void> prepare();

  /// Shows them, or brings them up to date.
  ///
  /// [elapsed] is how long the recording is at this moment. While it is
  /// neither [paused] nor [interrupted], the phone counts on from there by
  /// itself, so nothing needs to be sent every second.
  Future<void> show({
    required Duration elapsed,
    required bool paused,
    required bool interrupted,
  });

  /// Takes them away, including any a run that ended without warning left
  /// behind.
  Future<void> hide();

  /// What a press on them does. Answers whether there was a recording to do
  /// it to: the iPhone ends a Live Activity that nothing is behind.
  set onCommand(Future<bool> Function(RecordingCommand command)? handler);
}

/// The `kapynotes/recording_controls` channel: RecordingService.kt and
/// RecordingControls.kt on Android, RecordingActivity.swift on iOS.
class PlatformRecordingControls implements RecordingControls {
  PlatformRecordingControls({
    MethodChannel channel = const MethodChannel(channelName),
  }) : _channel = channel {
    _channel.setMethodCallHandler(_handle);
  }

  static const String channelName = 'kapynotes/recording_controls';

  final MethodChannel _channel;
  Future<bool> Function(RecordingCommand command)? _onCommand;

  @override
  set onCommand(Future<bool> Function(RecordingCommand command)? handler) =>
      _onCommand = handler;

  Future<bool> _handle(MethodCall call) async {
    final command = RecordingCommand.values
        .where((command) => command.name == call.method)
        .firstOrNull;
    final handler = _onCommand;
    if (command == null || handler == null) return false;
    return handler(command);
  }

  @override
  Future<void> prepare() => _call('prepare');

  @override
  Future<void> show({
    required Duration elapsed,
    required bool paused,
    required bool interrupted,
  }) => _call('show', {
    'elapsedMs': elapsed.inMilliseconds,
    'paused': paused,
    'interrupted': interrupted,
  });

  @override
  Future<void> hide() => _call('hide');

  Future<void> _call(String method, [Map<String, Object>? arguments]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } catch (error) {
      debugPrint('KapyNotes: recording controls could not $method: $error');
    }
  }
}
