import 'dart:async';
import 'dart:io';

import '../speech/live_translation.dart';
import 'adts.dart';
import 'voice_recorder.dart';

/// An Android recording with live translation on.
///
/// Android lets only one capture of the microphone run safely, so here the
/// live session records the file itself (LiveTranslation.kt): the same ADTS
/// frames, written as they come, to the same file today's recorder uses, so
/// stopping and recovering a killed recording work exactly as they always
/// have. Used only for a recording that starts with live translation on.
class LiveVoiceRecorder implements VoiceRecorderBackend {
  LiveVoiceRecorder(this._engine, {required this.from, required this.to});

  final LiveTranslationEngine _engine;
  final String from;
  final String to;
  String? _path;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<bool> hasMicrophone() async => true;

  @override
  Future<void> start(String path) async {
    _path = path;
    await _engine.start(from: from, to: to, path: adtsBeside(path));
  }

  @override
  Future<void> pause() => _engine.pause();

  @override
  Future<void> resume() => _engine.resume();

  @override
  Future<String?> stop() async {
    final path = _path;
    _path = null;
    final written = await _engine.stop();
    if (path == null || written == null) return null;
    final adts = File(written);
    if (!await adts.exists()) return null;
    return await finishAdtsRecording(adts, File(path)) ? path : null;
  }

  @override
  Future<void> cancel() async {
    final path = _path;
    _path = null;
    final written =
        await _engine.stop() ?? (path == null ? null : adtsBeside(path));
    if (written == null) return;
    final adts = File(written);
    if (await adts.exists()) await adts.delete();
  }

  @override
  Stream<double> get amplitude => _engine.levels;

  @override
  Stream<bool> get paused => _engine.interruptions;

  @override
  Future<void> dispose() async {}
}
