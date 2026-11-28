import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/audio/live_text.dart';
import 'package:kapy_notes/audio/voice_recording_controller.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/voice_prefs.dart';
import 'package:kapy_notes/speech/live_translation.dart';

import 'voice_recording_controller_test.dart'
    show FakeRecordingControls, FakeVoiceRecorder;

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'live-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;

  @override
  void putNow(String key, Object? value) => data[key] = value;
}

/// The device's engines, as a list of what they were asked.
class FakeLiveEngine implements LiveTranslationEngine {
  final calls = <String>[];
  bool available = true;
  LivePairStatus status = LivePairStatus.installed;
  int? bytes;
  Object? startError;
  String? written;
  Future<String?>? stopping;

  final phraseEvents = StreamController<LivePhrase>.broadcast();
  final levelEvents = StreamController<double>.broadcast();
  final stopEvents = StreamController<LiveTranslationStop>.broadcast();
  final interruptionEvents = StreamController<bool>.broadcast();

  @override
  Future<bool> isAvailable() async {
    calls.add('isAvailable');
    return available;
  }

  @override
  Future<LiveLanguages> languages() async {
    calls.add('languages');
    return const LiveLanguages(
      spoken: {'es', 'en'},
      targets: {'es', 'en'},
      names: {
        'es': (english: 'Spanish', own: 'Español'),
        'en': (english: 'English', own: 'English'),
      },
    );
  }

  @override
  Future<({LivePairStatus status, int? bytes})> pairStatus(
    String from,
    String to,
  ) async {
    calls.add('pairStatus $from $to');
    return (status: status, bytes: bytes);
  }

  @override
  Future<LivePrepareResult> prepare(
    String from,
    String to, {
    bool wifiOnly = true,
  }) async {
    calls.add('prepare $from $to');
    status = LivePairStatus.installed;
    return LivePrepareResult.ready;
  }

  @override
  Future<void> openSettings() async => calls.add('openSettings');

  @override
  Future<void> remove(String language) async => calls.add('remove $language');

  @override
  Future<void> start({
    required String from,
    required String to,
    String? path,
  }) async {
    calls.add(path == null ? 'start $from $to' : 'start $from $to $path');
    if (startError case final error?) throw error;
    if (path != null) await File(path).writeAsBytes(const [0xFF, 0xF1]);
  }

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> resume() async => calls.add('resume');

  @override
  Future<String?> stop() async {
    calls.add('stop');
    return stopping ?? written;
  }

  @override
  Stream<LivePhrase> get phrases => phraseEvents.stream;
  @override
  Stream<double> get levels => levelEvents.stream;
  @override
  Stream<LiveTranslationStop> get stops => stopEvents.stream;
  @override
  Stream<bool> get interruptions => interruptionEvents.stream;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late FakeVoiceRecorder recorder;
  late FakeRecordingControls controls;
  late FakeLiveEngine engine;
  late VoicePrefs prefs;
  late VoiceRecordingController controller;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('kapy-live-test');
    recorder = FakeVoiceRecorder();
    controls = FakeRecordingControls();
    engine = FakeLiveEngine();
    prefs = VoicePrefs(_MemoryStore())..load();
    prefs.language = 'es';
    controller = VoiceRecordingController(
      recorder: recorder,
      tempDirectory: temp,
      controls: controls,
    )..live = LiveTranslationLauncher(engine: engine, prefs: prefs);
  });

  tearDown(() async {
    controller.dispose();
    AppPlatform.debugTargetPlatformOverride = null;
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  void turnOn() {
    prefs.liveTranslateTo = 'en';
    prefs.liveTranslation = true;
  }

  group('with live translation off', () {
    for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
      test('a recording on ${platform.name} never touches it', () async {
        AppPlatform.debugTargetPlatformOverride = platform;
        prefs.liveTranslateTo = 'en';
        expect(prefs.liveTranslation, isFalse);

        expect(await controller.start(noteId: 'n1'), isTrue);
        expect(controller.liveText, isNull);
        expect(recorder.startedAt, endsWith('.m4a'));
        await controller.pause();
        await controller.resume();
        await controller.stop();

        expect(engine.calls, isEmpty);
        expect(controls.live, isFalse);
        expect(controls.phrase, isNull);
        expect(controls.heard, isNull);
      });
    }

    test('it is off until turned on', () {
      expect((VoicePrefs(_MemoryStore())..load()).liveTranslation, isFalse);
    });

    test('a pair the device doesn\'t have records exactly as before', () async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
      turnOn();
      engine.status = LivePairStatus.downloadable;

      await controller.start(noteId: 'n1');

      expect(engine.calls, ['pairStatus es en']);
      expect(controller.liveText, isNull);
      expect(recorder.startedAt, endsWith('.m4a'));
    });
  });

  group('on the iPhone and the Mac', () {
    setUp(() => AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS);

    test('it hears beside the recorder, and stops with it', () async {
      turnOn();
      await controller.start(noteId: 'n1');

      expect(recorder.startedAt, endsWith('.m4a'));
      expect(engine.calls, ['pairStatus es en', 'languages', 'start es en']);
      final text = controller.liveText!;
      expect((text.fromName, text.toName), ('Spanish', 'English'));

      await controller.pause();
      await controller.resume();
      expect(engine.calls.skip(3), ['pause', 'resume']);

      await controller.stop();
      expect(engine.calls.last, 'stop');
      expect(controller.liveText, isNull);
    });

    test(
      'a live session that never finishes stopping still ends the recording',
      () async {
        turnOn();
        await controller.start(noteId: 'n1');
        engine.stopping = Completer<String?>().future;

        await controller.stop().timeout(const Duration(seconds: 10));

        expect(engine.calls.last, 'stop');
        expect(recorder.stopped, isTrue);
        expect(controller.session, isNull);
        expect(controller.liveText, isNull);
      },
    );

    test('the latest translated phrase goes to the Lock Screen', () async {
      turnOn();
      await controller.start(noteId: 'n1');
      engine.phraseEvents.add(
        const LivePhrase(id: 1, heard: 'Llegamos el martes', finished: true),
      );
      await pumpEventQueue();
      expect(controls.phrase, isNull);

      engine.phraseEvents.add(
        const LivePhrase(
          id: 1,
          heard: 'Llegamos el martes',
          finished: true,
          translation: 'We land on Tuesday',
        ),
      );
      await pumpEventQueue();
      expect(controls.live, isTrue);
      expect(controls.phrase, 'We land on Tuesday');
      expect(controls.heard, 'Llegamos el martes');
    });

    test('the Lock Screen switch keeps the words off it', () async {
      turnOn();
      prefs.liveOnLockScreen = false;
      await controller.start(noteId: 'n1');
      engine.phraseEvents.add(
        const LivePhrase(id: 1, heard: 'Hola', translation: 'Hello'),
      );
      await pumpEventQueue();
      expect(controls.live, isTrue);
      expect(controls.phrase, isNull);
      expect(controls.heard, isNull);
    });

    test('a session that won\'t start leaves the recording going', () async {
      turnOn();
      engine.startError = PlatformException(code: 'failed');
      expect(await controller.start(noteId: 'n1'), isTrue);
      expect(controller.liveText, isNull);
      expect(controller.session, isNotNull);
    });
  });

  group('on Android', () {
    setUp(
      () => AppPlatform.debugTargetPlatformOverride = TargetPlatform.android,
    );

    test(
      'the live session records the file in place of the recorder',
      () async {
        turnOn();
        await controller.start(noteId: 'n1');

        expect(recorder.startedAt, isNull);
        expect(engine.calls.last, matches(RegExp(r'^start es en .*\.aac$')));
        expect(controller.liveText, isNotNull);
      },
    );

    test('cancel ends the session and deletes what it wrote', () async {
      turnOn();
      await controller.start(noteId: 'n1');
      final adts = engine.calls.last.split(' ').last;
      expect(File(adts).existsSync(), isTrue);
      engine.written = adts;

      await controller.cancel();
      expect(engine.calls.last, 'stop');
      expect(File(adts).existsSync(), isFalse);
      expect(controller.liveText, isNull);
    });

    test(
      'a session that won\'t start records with today\'s recorder',
      () async {
        turnOn();
        engine.startError = PlatformException(code: 'failed');
        expect(await controller.start(noteId: 'n1'), isTrue);
        expect(recorder.startedAt, endsWith('.m4a'));
        expect(controller.liveText, isNull);
      },
    );

    test('the system taking the microphone reads as interrupted', () async {
      turnOn();
      await controller.start(noteId: 'n1');
      engine.interruptionEvents.add(true);
      await pumpEventQueue();
      expect(controller.session!.interrupted, isTrue);
    });
  });

  group('LivePhrases', () {
    late LivePhrases text;
    setUp(
      () => text = LivePhrases(
        from: 'es',
        to: 'en',
        fromName: 'Spanish',
        toName: 'English',
        engine: engine,
      ),
    );
    tearDown(() => text.dispose());

    test('keeps the newest three phrases, revised in place', () async {
      for (var id = 1; id <= 4; id++) {
        engine.phraseEvents.add(LivePhrase(id: id, heard: 'frase $id'));
      }
      engine.phraseEvents.add(
        const LivePhrase(id: 3, heard: 'frase 3', translation: 'phrase 3'),
      );
      engine.phraseEvents.add(const LivePhrase(id: 5, heard: ' '));
      await pumpEventQueue();

      expect(text.phrases.map((p) => p.id), [2, 3, 4]);
      expect(text.latestTranslated?.translation, 'phrase 3');
    });

    test('says why it stopped', () async {
      engine.stopEvents.add(LiveTranslationStop.denied);
      await pumpEventQueue();
      expect(text.stopped, LiveTranslationStop.denied);
    });
  });

  test('a phrase is clipped at a word, never mid-word', () {
    expect(clipPhrase('  short  ', 300), 'short');
    expect(clipPhrase('one two three four', 12), 'one two…');
  });

  group('the platform channel', () {
    const channel = MethodChannel(PlatformLiveTranslation.channelName);
    const events = EventChannel(PlatformLiveTranslation.eventsName);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockStreamHandler(events, null);
    });

    test('is never asked where there is no engine', () async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.windows;
      var asked = false;
      messenger.setMockMethodCallHandler(channel, (_) async => asked = true);
      expect(await PlatformLiveTranslation().isAvailable(), isFalse);
      expect(asked, isFalse);
    });

    test('reads phrases, translations and errors from its events', () async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      final asked = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        asked.add(call);
        return null;
      });
      messenger.setMockStreamHandler(
        events,
        MockStreamHandler.inline(
          onListen: (_, sink) {
            sink.success({'id': 7, 'heard': 'Hola', 'final': false});
            sink.success({'id': 7, 'heard': 'Hola a todos', 'final': true});
            sink.success({'id': 7, 'translation': 'Hello everyone'});
            sink.success({'error': 'denied'});
          },
        ),
      );
      final live = PlatformLiveTranslation();
      final phrases = <LivePhrase>[];
      final stops = <LiveTranslationStop>[];
      live.phrases.listen(phrases.add);
      live.stops.listen(stops.add);

      await live.start(from: 'es', to: 'en');
      await pumpEventQueue();

      expect(asked.single.arguments, {'from': 'es', 'to': 'en'});
      expect(phrases.map((p) => (p.heard, p.finished, p.translation)), [
        ('Hola', false, null),
        ('Hola a todos', true, null),
        ('Hola a todos', true, 'Hello everyone'),
      ]);
      expect(stops, [LiveTranslationStop.denied]);
    });
  });
}
