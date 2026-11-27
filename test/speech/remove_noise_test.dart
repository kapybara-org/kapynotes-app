import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kapy_notes/audio/noise_removals.dart';
import 'package:kapy_notes/audio/voice_player.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/clean_copies.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/data/voice_prefs.dart';
import 'package:kapy_notes/speech/local_model_store.dart';
import 'package:kapy_notes/ui/editor/voice_chip.dart';
import 'package:kapy_notes/ui/voice_note_dialog.dart';
import 'package:material_ui/material_ui.dart';

import '../kapy_icon_finder.dart';

final String hash = 'ab' * 32;

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'remove-noise-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;

  @override
  void putNow(String key, Object? value) => data[key] = value;
}

/// Answers without the disk, which a fake-async test never gets back from.
class _Copies extends CleanCopies {
  _Copies({required this.made});

  final bool made;

  @override
  Future<File?> existing(String hash) async =>
      made ? File('/tmp/$hash.m4a') : null;
}

class _Backend implements VoicePlayerBackend {
  @override
  Future<Duration?> load(File file) async => const Duration(seconds: 60);
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setSpeed(double value) async {}
  @override
  Future<void> stop() async {}
  @override
  Stream<Duration> get positions => const Stream.empty();
  @override
  Stream<void> get completions => const Stream.empty();
  @override
  Future<void> dispose() async {}
}

final NoteVoiceRef ref = NoteVoiceRef(
  offset: 0,
  hash: hash,
  key: Uint8List(32),
  bytes: 2048,
  durationMs: 60000,
  peaks: Uint8List.fromList(List.filled(100, 128)),
);

void main() {
  late VoicePrefs prefs;
  late VoicePlayer player;
  late List<String> switched;

  setUp(() {
    prefs = VoicePrefs(_MemoryStore())..load();
    player = VoicePlayer(
      backend: _Backend(),
      files: (hash) async => File('/tmp/$hash.m4a'),
    );
    switched = [];
  });
  tearDown(() => player.dispose());

  NoiseRemovals noise({
    required bool made,
    Directory? models,
    http.Client? client,
  }) => NoiseRemovals(
    models: LocalModelStore(directory: models, client: client),
    prefs: prefs,
    copies: _Copies(made: made),
    originals: (_) async => File('/tmp/original.m4a'),
    switched: switched.add,
  );

  Widget host(NoiseRemovals noise, Widget child) => MaterialApp(
    theme: KapyTheme.dark(),
    builder: (context, child) =>
        NoiseRemovalScope(notifier: noise, child: child!),
    home: Scaffold(body: child),
  );

  Finder toggle({required bool on}) => find.byWidgetPredicate(
    (widget) =>
        widget is Semantics &&
        widget.properties.label == 'Remove noise' &&
        widget.properties.toggled == on,
  );

  testWidgets('one toggle switches between the copy and the original', (
    tester,
  ) async {
    prefs.setNoiseOff(hash, true);
    final removals = noise(made: true);
    addTearDown(removals.dispose);
    await tester.pumpWidget(
      host(removals, VoiceNotePlayerRow(ref: ref, player: player)),
    );
    await tester.pump();

    expect(find.text('Remove noise'), findsOneWidget);
    expect(toggle(on: false), findsOneWidget);
    expect(find.byTooltip('Remove noise'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('voice-remove-noise')));
    await tester.pump();
    expect(toggle(on: true), findsOneWidget);
    expect(find.byTooltip('Play the original'), findsOneWidget);
    expect(prefs.isNoiseOff(hash), isFalse);
    expect(switched, [hash]);

    await tester.tap(find.byKey(const ValueKey('voice-remove-noise')));
    await tester.pump();
    expect(toggle(on: false), findsOneWidget);
    expect(prefs.isNoiseOff(hash), isTrue);
    expect(switched, [hash, hash]);
  });

  testWidgets('explains itself on a recording never cleaned', (tester) async {
    final removals = noise(made: false);
    addTearDown(removals.dispose);
    await tester.pumpWidget(
      host(removals, VoiceNotePlayerRow(ref: ref, player: player)),
    );
    await tester.pump();
    expect(
      find.byTooltip('Clears background noise. Your original is kept.'),
      findsOneWidget,
    );
  });

  for (final phone in [false, true]) {
    testWidgets(
      'the first press downloads, shows it, and the × stops it${phone ? ' on a phone' : ''}',
      (tester) async {
        if (phone) {
          AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
          addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
        }
        final dir = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('kapy-remove-noise'),
        ))!;
        addTearDown(() => dir.delete(recursive: true));
        final answer = Completer<http.StreamedResponse>();
        final removals = noise(
          made: false,
          models: dir,
          client: MockClient.streaming((_, _) => answer.future),
        );
        addTearDown(removals.dispose);
        await tester.pumpWidget(
          host(removals, VoiceNotePlayerRow(ref: ref, player: player)),
        );
        await tester.pump();

        await tester.tap(find.byKey(const ValueKey('voice-remove-noise')));
        await settle(tester);
        expect(find.text('Downloading'), findsOneWidget);
        expect(find.byTooltip('Stop'), findsOneWidget);
        expect(
          tester.getSize(find.byKey(const ValueKey('voice-remove-noise-stop'))),
          AppPlatform.hasPointer ? const Size(24, 24) : const Size(44, 44),
        );
        expect(find.byKey(const ValueKey('voice-remove-noise')), findsNothing);

        await tester.tap(find.byKey(const ValueKey('voice-remove-noise-stop')));
        answer.completeError(http.ClientException('stopped'));
        await settle(tester);
        expect(find.text('Remove noise'), findsOneWidget);
        expect(switched, isEmpty);
      },
    );
  }

  testWidgets('the card shows the sign once the noise is removed', (
    tester,
  ) async {
    final removals = noise(made: true);
    addTearDown(removals.dispose);
    await tester.pumpWidget(
      host(
        removals,
        NoteVoiceChip(
          ref: ref,
          state: VoiceChipState.done,
          progress: const AlwaysStoppedAnimation<double?>(null),
          playing: false,
        ),
      ),
    );
    await tester.pump();
    expect(findKapyIcon(KapyIcons.voiceIdRounded), findsOneWidget);
    expect(find.byTooltip('Noise removed'), findsOneWidget);

    removals.turnOff(hash);
    await tester.pump();
    expect(findKapyIcon(KapyIcons.voiceIdRounded), findsNothing);
  });
}

/// Lets real file and network work started in the test's fake-async zone
/// finish: each round hands the real event loop a moment, then runs what it
/// woke.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
}
