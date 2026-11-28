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

// Spanish to English first, as a person would turn it on. Where that isn't
// ready, English to Spanish follows, to show whether translation_runtime
// arrives for a pair whose recogniser language the phone has.
const _pairs = [
  (from: 'es', to: 'en', phrase: 'Hola, ¿cómo estás?'),
  (from: 'en', to: 'es', phrase: 'Hello, how are you?'),
];

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
  // The recogniser learns which languages it has from its own download of
  // its configuration, which can come a few minutes after a fresh boot.
  final waited = Stopwatch()..start();
  var spoken = (await live.languages()).spoken;
  while (spoken.isEmpty && waited.elapsed < const Duration(minutes: 10)) {
    await Future<void>.delayed(const Duration(seconds: 15));
    spoken = (await live.languages()).spoken;
  }
  _mark(
    'spoken=${(spoken.toList()..sort()).join(',')} after=${waited.elapsed.inSeconds}s',
  );

  var pair = _pairs.first;
  for (final candidate in _pairs) {
    pair = candidate;
    final tag = '${pair.from}-${pair.to}';
    _mark(
      '$tag pair_before=${_pair((await live.pairStatus(pair.from, pair.to)).status)}',
    );
    final prepared = await live.prepare(pair.from, pair.to, wifiOnly: false);
    _mark('$tag prepare=${_prepared(prepared)}');
    _mark(
      '$tag pair_after=${_pair((await live.pairStatus(pair.from, pair.to)).status)}',
    );
    try {
      final out = await channel.invokeListMethod<String>('translate', {
        'from': pair.from,
        'to': pair.to,
        'texts': [pair.phrase],
      });
      final ok =
          out != null &&
          out.length == 1 &&
          out.single.trim().isNotEmpty &&
          out.single != pair.phrase;
      _mark('$tag translate=${ok ? 'ok' : 'empty'}');
    } on PlatformException catch (error) {
      _mark('$tag translate=error:${error.code}');
    }
    if (prepared == LivePrepareResult.ready) break;
  }

  final path =
      '${(await getApplicationSupportDirectory()).path}/live_probe.aac';
  live.stops.listen((stop) => _mark('live_stop=${_stopped(stop)}'));
  var phrases = 0;
  live.phrases.listen((_) => phrases++);
  try {
    await live.start(from: pair.from, to: pair.to, path: path);
    _mark('live=started ${pair.from}-${pair.to}');
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
