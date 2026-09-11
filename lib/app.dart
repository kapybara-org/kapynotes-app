import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:material_ui/material_ui.dart';

import 'core/platform.dart';
import 'core/appearance.dart';
import 'core/desktop_integration.dart';
import 'audio/voice_player.dart';
import 'data/voice_prefs.dart';
import 'speech/apple_summarizer.dart';
import 'speech/apple_transcriber.dart';
import 'speech/cloud_summarizer.dart';
import 'speech/cloud_transcriber.dart';
import 'speech/gemma_summarizer.dart';
import 'speech/runtime_pack.dart';
import 'speech/sherpa_transcriber.dart';
import 'speech/transcriber.dart';
import 'speech/local_model_store.dart';
import 'speech/local_models.dart';
import 'speech/summarizer.dart';
import 'speech/transcription_queue.dart';
import 'audio/voice_recording_controller.dart';
import 'core/quick_capture.dart';
import 'core/theme.dart';
import 'core/window_material.dart';
import 'data/engine_provider.dart';
import 'data/layout_prefs.dart';
import 'data/local_store.dart';
import 'data/notes_store.dart';
import 'data/onboarding.dart';
import 'data/rates.dart';
import 'data/shortcut_prefs.dart';
import 'data/update_checker.dart';
import 'images/image_picker.dart';
import 'sync/account.dart';
import 'ui/app_logo.dart';
import 'ui/home_page.dart';
import 'ui/instant_capture.dart';

/// Root widget. Owns the app-wide singletons and the macOS menu bar.
class KapyNotesApp extends StatefulWidget {
  const KapyNotesApp({
    super.key,
    required this.store,
    required this.notes,
    required this.rates,
    required this.prefs,
    required this.shortcuts,
    this.updates,
    this.desktopIntegration,
    this.account,
    this.recording,
    this.imageAcquirer,
    this.lostImageRetriever,
  });

  final LocalStore store;
  final NotesStore notes;
  final RatesRepository rates;
  final LayoutPrefs prefs;
  final ShortcutPrefs shortcuts;

  /// Null off macOS and Windows, where the app cannot update itself.
  final UpdateChecker? updates;
  final DesktopIntegration? desktopIntegration;

  /// Null when the build has no server to sync with.
  final Account? account;

  /// Owns the microphone. Injectable so a test can hand over a recorder with
  /// no microphone behind it — the real one starts a one-second ticker that
  /// `pumpAndSettle` would wait on forever.
  final VoiceRecordingController? recording;

  /// Native image boundaries, injectable for launch and recovery tests.
  final ImageFileAcquirer? imageAcquirer;
  final LostImageRetriever? lostImageRetriever;

  @override
  State<KapyNotesApp> createState() => _KapyNotesAppState();
}

class _KapyNotesAppState extends State<KapyNotesApp>
    with WidgetsBindingObserver {
  static const _rateRefreshDelay = Duration(seconds: 2);

  /// Behind the rate refresh on purpose: whatever else is happening after the
  /// first frame, transcription is the least urgent of it.
  static const _transcriptionDrainDelay = Duration(seconds: 3);
  // Behind the rate refresh: neither is urgent, and launch belongs to the
  // first frame rather than to two background fetches racing it.
  static const _updateCheckDelay = Duration(seconds: 5);

  final TextEditingController _launchController = TextEditingController();

  /// Owns the microphone, and lives here rather than on the page below so a
  /// recording survives the page rebuilding — and so every lifecycle hook in
  /// this class can end one before the app goes away.
  late final VoiceRecordingController _recording =
      widget.recording ?? VoiceRecordingController();

  /// One player for the whole app: starting a second recording stops the
  /// first, and a phone never holds two claims on its audio session.
  final VoicePlayer _player = VoicePlayer();

  /// Turns recordings into words, across launches. Its file is only touched
  /// once something has been recorded, so a device that never records pays a
  /// single `File.exists` for it at startup and nothing else.
  TranscriptionQueue? _transcriptions;
  VoicePrefs? _voicePrefs;

  /// The speech models on this device. Held here rather than in the settings
  /// dialog so that closing settings does not abandon a download of two
  /// thirds of a gigabyte. Costs an allocation at launch and no disk at all
  /// until the voice pane asks it to look.
  LocalModelStore? _localModels;

  /// Where summaries are written, cloud or device. Built once and read
  /// through, so changing the setting takes effect on the next recording
  /// rather than on the next launch.
  Summarizer? _summarizer;

  /// Just the device half, which settings shows on its own so it can say why
  /// it is or is not available on this machine.
  DeviceSummarizer? _deviceSummarizer;

  /// Where recordings become words, cloud or device. The twin of
  /// [_summarizer], built and read the same way.
  Transcriber? _transcriber;

  /// Just the device half, for the same reason [_deviceSummarizer] is kept:
  /// settings has to say whether this machine can do it, and why not.
  DeviceTranscriber? _deviceTranscriber;

  /// Held separately from [_deviceSummarizer] because it is the one that owns
  /// memory: it has to be told when the app goes away.
  GemmaSummarizer? _gemma;
  EngineProvider? _engines;
  Future<void>? _hydration;
  Timer? _rateRefreshTimer;
  Timer? _updateCheckTimer;
  Timer? _transcriptionTimer;
  bool _ready = false;

  /// The welcome note, on the launch that seeded it. Null every other time.
  String? _welcomeNoteId;

  /// Which widget, if any, this launch came through. Kept because the page
  /// below acts on it after its first frame — Dictate and Capture each have
  /// something to do in the note once the note is on screen.
  LaunchIntent _launchIntent = LaunchIntent.open;

  /// Whether the window has a blurred desktop behind the Flutter view. The
  /// transparency setting asks for one; this is whether it got it. Until it
  /// has, and wherever it cannot, the surfaces keep their opaque paint, since
  /// tints over an unblurred window show black through every gap.
  bool _glassBehindWindow = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.prefs.transparencyListenable.addListener(_applyWindowMaterial);
    widget.prefs.transparencyAmountListenable.addListener(_applyWindowMaterial);
    _applyWindowMaterial();
    // Quitting from the tray never passes through the platform's exit
    // request, so the flush that request would have triggered has to be
    // handed over explicitly. This state owns the store; nothing below it
    // does.
    widget.desktopIntegration?.onBeforeQuit = _finishRecordingThenFlush;
    widget.updates?.onBeforeQuitForUpdate = widget.desktopIntegration?.quit;
    // Hiding to the tray must not leave the microphone open: an app with no
    // window on screen that is still recording is the worst thing this feature
    // could do.
    widget.desktopIntegration?.onBeforeClose =
        _recording.finishRecordingAndFlush;
    _recording.onFlush = _flushAfterHydration;
    _voicePrefs = VoicePrefs(widget.store);
    // Each model is offered only where this build carries something that
    // reads it: Parakeet where the platform has no recogniser of its own,
    // Gemma everywhere but iOS. On Android neither runtime is in the app;
    // Play delivers them on the first download, through the pack.
    _localModels = LocalModelStore(
      catalogue: [
        if (SherpaTranscriber.isPossibleHere) ...localSpeechModels,
        if (GemmaSummarizer.isPossibleHere) ...localSummaryModels,
      ],
      runtime: PlayRuntimePack.isPossibleHere
          ? PlayRuntimePack()
          : const BundledRuntimePack(),
    );
    // Apple's model first because it is free and already on the machine;
    // the downloaded one answers for every device Apple does not cover.
    _gemma = GemmaSummarizer(models: _localModels!);
    _deviceSummarizer = DeviceSummarizer([AppleSummarizer(), _gemma!]);
    _summarizer = RoutingSummarizer(
      engineOf: () => _voicePrefs?.summaryEngine ?? SummaryEngine.cloud,
      cloud: CloudSummarizer(() => widget.account?.speech),
      device: _deviceSummarizer!,
    );
    // Apple's recogniser first, for the same reason and not the same one: it
    // is already on the machine, and unlike the summariser it does not need
    // Apple Intelligence, so it answers for far more devices than that one
    // does. Parakeet covers Windows, Android, and everything too old for it.
    _deviceTranscriber = DeviceTranscriber([
      AppleTranscriber(language: () => _voicePrefs?.language),
      SherpaTranscriber(
        models: _localModels!,
        language: () => _voicePrefs?.language,
      ),
    ]);
    _transcriber = RoutingTranscriber(
      engineOf: () => _voicePrefs?.transcriptEngine ?? TranscriptEngine.cloud,
      cloud: CloudTranscriber(() => widget.account?.speech),
      device: _deviceTranscriber!,
    );
    _transcriptions = TranscriptionQueue(
      store: LocalStore(fileName: 'attachments-queue.json'),
      notes: widget.notes,
      blobs: widget.notes.blobs,
      prefs: _voicePrefs!,
      api: () => widget.account?.speech,
      summarizer: () => _summarizer,
      transcriber: () => _transcriber,
    );
    if (widget.notes.isLoaded) {
      _activateLoadedApp();
    } else {
      _hydration = _hydrateInBackground();
    }
  }

  Future<void> _hydrateInBackground() async {
    // Asked before storage is read and collected once it has been. The
    // platform knows the answer before Dart starts, so overlapping the two
    // costs the launch nothing — and the await below is the last one, which
    // keeps the draft handover under it synchronous.
    final launch = QuickCapture.launchIntent();
    await widget.notes.load();
    final intent = await launch;
    if (!mounted) return;

    widget.prefs.load();
    widget.shortcuts.load();
    _voicePrefs?.load();
    _activateLoadedApp(capturedText: _launchController.text, intent: intent);
    setState(() {});

    // Once a launch, after the notes are on screen and never before them: the
    // sweep needs the complete set of live notes to be safe, and it is disk
    // work nobody is waiting on. Images are deleted by deleting the character
    // that holds them, which can happen through an edit, an undo, a sync or a
    // note being thrown away — so no edit path counts references, and this
    // answers the question in one place instead.
    unawaited(widget.notes.sweepBlobs());
  }

  void _activateLoadedApp({
    String capturedText = '',
    LaunchIntent intent = LaunchIntent.open,
  }) {
    if (_ready) return;
    // A new install opens on a note that teaches itself rather than on a blank
    // page. Seeded ahead of the capture below so that a launch which arrives
    // with text still puts that text on screen, with the welcome underneath it
    // in the list rather than in its way.
    _welcomeNoteId = Onboarding(widget.store).seedWelcomeNote(widget.notes)?.id;
    _launchIntent = intent;
    final openingId = widget.prefs.resolveOpeningNoteId(
      widget.notes.notes.map((note) => note.id),
    );
    final openingNote = widget.notes.byId(openingId);
    if (capturedText.isNotEmpty || intent.continuesLastNote) {
      // The text snapshot and tree switch are synchronous. No platform text
      // event can land between capturing the draft and mounting its note.
      //
      // Which note that is depends on how the app was opened: every widget
      // action carries on the last one, and everything else starts a new one
      // exactly as it always has.
      QuickCapture.file(
        widget.notes,
        capturedText,
        intent,
        target: openingNote,
      );
    } else if (_welcomeNoteId == null &&
        AppPlatform.isMobile &&
        widget.notes.isEmpty) {
      // HomePage can create this after its first frame, but doing it before the
      // handoff avoids flashing an empty state and reconnecting the keyboard.
      widget.notes.create();
    }
    widget.rates.loadCache();
    widget.updates?.loadCache();
    // After the editor exists, never before it: restoring reads the platform
    // keystore and asks the server who we are, and neither belongs in front of
    // the first frame.
    final account = widget.account;
    if (account != null) {
      unawaited(account.restore());
    }
    _engines = EngineProvider(widget.rates, widget.prefs);
    _ready = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scheduleBackgroundFetches();
    });
  }

  void _scheduleBackgroundFetches() {
    if (!_ready || AppPlatform.isFlutterTest) return;
    _rateRefreshTimer?.cancel();
    _rateRefreshTimer = Timer(
      _rateRefreshDelay,
      () => unawaited(widget.rates.refreshIfStale()),
    );

    // Behind the rate refresh, and only ever after the first frame. Starts
    // with a `File.exists` on the queue file and does nothing more on a device
    // that has never recorded.
    _transcriptionTimer?.cancel();
    _transcriptionTimer = Timer(_transcriptionDrainDelay, () async {
      final queue = _transcriptions;
      if (queue == null) return;
      await queue.open();
      unawaited(queue.drain());
    });

    // Stray `voice-*.m4a` from a force quit: unreadable, unrecoverable, and
    // nothing else will ever clean them up.
    unawaited(VoiceRecordingController.sweepTempFiles());

    final updates = widget.updates;
    if (updates == null) return;
    _updateCheckTimer?.cancel();
    // Rate-limited to once a day inside the checker, so firing this on every
    // resume costs nothing but keeps a long-lived window current.
    _updateCheckTimer = Timer(
      _updateCheckDelay,
      () => unawaited(updates.checkIfDue()),
    );
  }

  /// Ends any recording, then flushes. The order matters: the recording has
  /// to become a ref in a note *before* the note is written to disk.
  Future<void> _finishRecordingThenFlush() async {
    await _recording.finishRecordingAndFlush();
    await _flushAfterHydration();
  }

  Future<void> _flushAfterHydration() async {
    final hydration = _hydration;
    if (hydration != null) await hydration;
    await widget.store.flush();
  }

  /// Tells the window which material to put behind the Flutter view, and
  /// records whether it did. The request and its answer straddle a platform
  /// call, so a toggle that flips twice in flight settles on the last answer
  /// that still matches the setting.
  Future<void> _applyWindowMaterial() async {
    final wanted = widget.prefs.transparencyEnabled;
    final amount = widget.prefs.transparencyAmount;
    // Asked either way: taking the glass away is as much a request as putting
    // it there, and a window left blurred under opaque paint wastes the
    // compositor's time for nothing anyone can see.
    final on = await WindowMaterial.setGlass(wanted, amount: amount) && wanted;
    if (!mounted || wanted != widget.prefs.transparencyEnabled) return;
    if (on != _glassBehindWindow) setState(() => _glassBehindWindow = on);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.prefs.transparencyListenable.removeListener(_applyWindowMaterial);
    widget.prefs.transparencyAmountListenable.removeListener(
      _applyWindowMaterial,
    );
    widget.updates?.onBeforeQuitForUpdate = null;
    _rateRefreshTimer?.cancel();
    _updateCheckTimer?.cancel();
    _transcriptionTimer?.cancel();
    _transcriptions?.dispose();
    _voicePrefs?.dispose();
    _localModels?.dispose();
    unawaited(_gemma?.unload() ?? Future<void>.value());
    _launchController.dispose();
    // Not the injected one: whoever passed it in owns it.
    if (widget.recording == null) _recording.dispose();
    _player.dispose();
    _engines?.dispose();
    widget.rates.dispose();
    widget.updates?.dispose();
    widget.desktopIntegration?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final sync = widget.account?.sync;
    // Writes are coalesced while the app is in use; losing focus or being
    // backgrounded is the moment to make sure everything is on disk.
    if (state == AppLifecycleState.resumed) {
      _scheduleBackgroundFetches();
      sync?.resume();
      // Coming back is the likeliest moment for another device to have moved
      // on without us.
      unawaited(sync?.syncNow() ?? Future<void>.value());
      // And for a trial to have ended while nothing here was running to
      // notice: a suspended phone does not fire timers.
      unawaited(
        widget.account?.billing?.refreshIfStale() ?? Future<void>.value(),
      );
    } else {
      // Deliberately not on `inactive` or `hidden`. On desktop those mean a
      // window that lost focus or was minimised, and an open window quietly
      // going stale is the whole reason the socket stays open. Only a
      // real backgrounding is worth closing a socket for — and there the OS
      // is about to close it anyway.
      if (state == AppLifecycleState.paused ||
          state == AppLifecycleState.detached) {
        sync?.pause();
        // A backgrounded app holding a billion parameters resident is the
        // first thing a phone kills. Give them back; the next summary reloads
        // in a couple of seconds.
        unawaited(_gemma?.unload() ?? Future<void>.value());
        // A phone that backgrounds the app has already stopped giving it the
        // microphone, so the recording is delivered rather than left running.
        // Deliberately not on `inactive`: that is the first moment of a phone
        // call and the app switcher, and `record` has paused itself for both.
        if (AppPlatform.isMobile) {
          unawaited(_finishRecordingThenFlush());
          return;
        }
      }
      unawaited(_flushAfterHydration());
    }
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    await _finishRecordingThenFlush();
    return AppExitResponse.exit;
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return InstantCaptureApp(controller: _launchController);
    }

    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.prefs.transparencyListenable,
        widget.prefs.transparencyAmountListenable,
        widget.prefs.appearanceListenable,
      ]),
      builder: (context, _) => MaterialApp(
        title: AppWordmark.name,
        debugShowCheckedModeBanner: false,
        theme: KapyTheme.light(
          transparency: widget.prefs.transparencyEnabled,
          amount: widget.prefs.transparencyAmount,
        ),
        darkTheme: KapyTheme.dark(
          transparency: widget.prefs.transparencyEnabled,
          amount: widget.prefs.transparencyAmount,
        ),
        themeMode: widget.prefs.appearance.themeMode,
        // The glass palette only applies once the window has a blurred
        // desktop behind it, and not while an accessibility mode asks for
        // solid surfaces. High Contrast is an explicit request for stronger
        // separation: keep the saved choice, but put the opaque paint back
        // for as long as the mode is on. macOS' own Reduce Transparency
        // already flattens the material behind the window; this covers the
        // Flutter side of it. Either way it costs a single palette copy
        // rather than a rebuilt ColorScheme on every frame.
        builder: (context, child) {
          final solid =
              !_glassBehindWindow || MediaQuery.highContrastOf(context);
          if (!widget.prefs.transparencyEnabled || !solid) {
            return child ?? const SizedBox.shrink();
          }
          final theme = Theme.of(context);
          final palette = theme.extension<CalcPalette>()!;
          return Theme(
            data: theme.copyWith(extensions: [palette.opaque]),
            child: child!,
          );
        },
        // Prose autocorrection has no place in a calculator, and the app is
        // plain-text only, so the default Material scroll behaviour is enough.
        home: HomePage(
          notes: widget.notes,
          engines: _engines!,
          rates: widget.rates,
          prefs: widget.prefs,
          shortcuts: widget.shortcuts,
          updates: widget.updates,
          desktopIntegration: widget.desktopIntegration,
          account: widget.account,
          store: widget.store,
          welcomeNoteId: _welcomeNoteId,
          launchIntent: _launchIntent,
          recording: _recording,
          player: _player,
          transcriptions: _transcriptions,
          voicePrefs: _voicePrefs,
          localModels: _localModels,
          deviceSummarizer: _deviceSummarizer,
          deviceTranscriber: _deviceTranscriber,
          summarizer: _summarizer,
          transcriber: _transcriber,
          imageAcquirer: widget.imageAcquirer,
          lostImageRetriever: widget.lostImageRetriever,
        ),
      ),
    );
  }
}
