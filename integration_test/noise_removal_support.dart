// Remove noise on a real device, for the tests that run on one: the model
// fetched from the app's own hosts, the recording decoded and cleaned here, the
// clean copy encoded by this platform's own encoder, read back by its decoder
// and played. `flutter test` covers the same steps with stand-ins for every
// one of them; this is where a platform's half could still be wrong.
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/audio/audio_decode.dart';
import 'package:kapy_notes/audio/noise_removal.dart';
import 'package:kapy_notes/audio/noise_removals.dart';
import 'package:kapy_notes/audio/voice_player.dart';
import 'package:kapy_notes/data/clean_copies.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/voice_prefs.dart';
import 'package:kapy_notes/speech/local_model_store.dart';
import 'package:kapy_notes/speech/local_models.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'remove-noise-integration.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

/// Removes the noise from [recording] the way a press on Remove noise does,
/// with everything it writes kept under [temp], and plays the clean copy.
Future<void> removeNoiseAndPlay(File recording, Directory temp) async {
  expect(
    NoiseRemover.isPossibleHere,
    isTrue,
    reason: 'this build carries no noise removal library',
  );

  final original = await const AudioDecoder().decode(recording);
  final originalMs = original.frames * 1000 ~/ original.sampleRate;
  await original.dispose();
  expect(originalMs, greaterThan(1500));

  final hash = sha256.convert(await recording.readAsBytes()).toString();
  final switched = <String>[];
  final noise = NoiseRemovals(
    models: LocalModelStore(
      catalogue: const [noiseRemovalModel],
      directory: Directory('${temp.path}/models'),
    ),
    prefs: VoicePrefs(_MemoryStore()),
    copies: CleanCopies(directory: Directory('${temp.path}/clean')),
    originals: (_) async => recording,
    switched: switched.add,
  );
  addTearDown(noise.dispose);

  final problem = await noise.turnOn(hash).timeout(const Duration(minutes: 5));
  expect(problem, isNull, reason: 'Remove noise gave up: $problem');
  expect(noise.stateOf(hash).stage, NoiseStage.on);
  expect(switched, [hash], reason: 'playback was not moved to the copy');

  final clean = await noise.playable(hash);
  expect(clean, isNotNull, reason: 'no clean copy to play');
  expect(clean!.path, isNot(recording.path));

  final decoded = await const AudioDecoder().decode(clean);
  final cleanMs = decoded.frames * 1000 ~/ decoded.sampleRate;
  await decoded.dispose();
  expect(cleanMs, closeTo(originalMs, 500));

  final player = VoicePlayer(files: (_) async => clean);
  addTearDown(player.dispose);
  await player.play(hash);
  expect(player.duration, isNotNull, reason: 'the player could not read it');
  expect(player.duration!.inMilliseconds, closeTo(originalMs, 500));
  await player.stop();
}
