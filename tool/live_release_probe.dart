// A probe of live translation in the Android release build, for the
// release_check job in .github/workflows/phones.yml. Never the app's
// entrypoint: only that job builds it, with
// `flutter build appbundle --release -t tool/live_release_probe.dart`, so it
// carries the app's manifest, R8 rules and on-demand translation_runtime.
//
// It drives the real PlatformLiveTranslation as turning live translation on
// does, then runs a short live session, and prints one `LIVE_PROBE` line per
// step for tool/ci/android_release_check.sh to read from logcat. Each line is
// an outcome only, never a word heard or translated.
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:kapy_notes/speech/live_translation.dart';
import 'package:path_provider/path_provider.dart';

const _from = 'es';
const _to = 'en';
const _phrase = 'Hola, ¿cómo estás?';

void _mark(String line) => print('LIVE_PROBE $line');

// Spelled out rather than `.name`: the release build is obfuscated.
String _pair(LivePairStatus status) => switch (status) {
  LivePairStatus.installed => 'installed',
  LivePairStatus.downloadable => 'downloadable',
  LivePairStatus.unsupported => 'unsupported',
};

String _prepared(LivePrepareResult result) => switch (result) {
  LivePrepareResult.ready => 'ready',
  LivePrepareResult.denied => 'denied',
  LivePrepareResult.declined => 'declined',
  LivePrepareResult.unsupported => 'unsupported',
};

String _stopped(LiveTranslationStop stop) => switch (stop) {
  LiveTranslationStop.denied => 'denied',
  LiveTranslationStop.interrupted => 'interrupted',
  LiveTranslationStop.failed => 'failed',
};

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ColoredBox(color: Color(0xFFFFFFFF)));
  await WidgetsBinding.instance.endOfFrame;

  final live = PlatformLiveTranslation();
  const channel = MethodChannel(PlatformLiveTranslation.channelName);

  _mark('available=${await live.isAvailable()}');
  _mark('pair_before=${_pair((await live.pairStatus(_from, _to)).status)}');
  _mark(
    'prepare=${_prepared(await live.prepare(_from, _to, wifiOnly: false))}',
  );
  _mark('pair_after=${_pair((await live.pairStatus(_from, _to)).status)}');

  try {
    final out = await channel.invokeListMethod<String>('translate', {
      'from': _from,
      'to': _to,
      'texts': [_phrase],
    });
    final ok =
        out != null &&
        out.length == 1 &&
        out.single.trim().isNotEmpty &&
        out.single != _phrase;
    _mark('translate=${ok ? 'ok' : 'empty'}');
  } on PlatformException catch (error) {
    _mark('translate=error:${error.code}');
  }

  final path =
      '${(await getApplicationSupportDirectory()).path}/live_probe.aac';
  live.stops.listen((stop) => _mark('live_stop=${_stopped(stop)}'));
  var phrases = 0;
  live.phrases.listen((_) => phrases++);
  try {
    await live.start(from: _from, to: _to, path: path);
    _mark('live=started');
    await Future<void>.delayed(const Duration(seconds: 20));
    final written = await live.stop();
    final bytes = written == null ? 0 : File(written).lengthSync();
    _mark('live=stopped file=${written != null} bytes=$bytes phrases=$phrases');
  } on PlatformException catch (error) {
    _mark('live=error:${error.code}');
  }

  try {
    final again = await channel.invokeMapMethod<String, Object?>('stop');
    _mark('second_stop=${again?['path'] == null ? 'idle' : 'session'}');
  } on PlatformException catch (error) {
    _mark('second_stop=error:${error.code}');
  }
  _mark('done');
}
