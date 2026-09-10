import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/speech/apple_transcriber.dart';
import 'package:kapy_notes/speech/transcriber.dart';
import 'package:path_provider/path_provider.dart';

/// Apple's recognisers on a real recording, through the real runner.
///
/// Run it twice on a Mac that has both engines:
///
///     flutter test integration_test/apple_transcribe_test.dart -d macos
///     flutter test integration_test/apple_transcribe_test.dart -d macos \
///         --dart-define=KAPY_APPLE_SPEECH=legacy
///
/// The second is the only way to exercise the older engine on a machine new
/// enough to have the newer one, and the older engine is the one every Mac
/// and iPhone below the 26s will use. Both must produce the words.
///
/// Looks for the recording beside the models rather than in the repo,
/// because the app is sandboxed and cannot read the project directory. Copy
/// `test/fixtures/speech.m4a` (or a longer one) into Application Support.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// `speech.m4a` is the five-second fixture; `speech-long.m4a`, if present,
  /// is anything over a minute — the older engine's windowing is only
  /// exercised by the second.
  for (final (name, mustContain, atLeast) in [
    ('speech.m4a', 'milk', 1),
    ('speech-long.m4a', null, 4),
  ]) {
    test('Apple turns $name into words, on this machine', () async {
      final support = await getApplicationSupportDirectory();
      final recording = File('${support.path}/$name');
      if (!recording.existsSync()) {
        // ignore: avoid_print
        print('SKIP: put test/fixtures/$name at ${recording.path}');
        return;
      }

      final transcriber = AppleTranscriber();
      final readiness = await transcriber.readiness();
      // ignore: avoid_print
      print('READINESS: $readiness');
      expect(readiness, TranscriberReadiness.ready);

      final started = DateTime.now();
      final draft = await transcriber.transcribe(
        audio: recording,
        requestId: 'integration',
      );
      final elapsed = DateTime.now().difference(started);

      // ignore: avoid_print
      print('ENGINE: ${draft.engine}');
      // ignore: avoid_print
      print('ELAPSED: ${elapsed.inMilliseconds} ms for $name');
      for (final segment in draft.segments) {
        // ignore: avoid_print
        print('SEGMENT [${segment.s}-${segment.e}] ${segment.t}');
      }

      expect(draft.segments.length, greaterThanOrEqualTo(atLeast));
      if (mustContain != null) {
        final text = draft.segments.map((s) => s.t).join(' ').toLowerCase();
        expect(text, contains(mustContain));
      }
      // Every segment is timed, in order, and none of them ends before it
      // starts — which is the property a windowed engine most easily breaks.
      var last = 0;
      for (final segment in draft.segments) {
        expect(segment.s, greaterThanOrEqualTo(last));
        expect(segment.e, greaterThanOrEqualTo(segment.s));
        last = segment.s;
      }
    });
  }
}
