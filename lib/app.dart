import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:material_ui/material_ui.dart';

import 'core/platform.dart';
import 'core/desktop_integration.dart';
import 'core/quick_capture.dart';
import 'core/theme.dart';
import 'data/engine_provider.dart';
import 'data/layout_prefs.dart';
import 'data/local_store.dart';
import 'data/notes_store.dart';
import 'data/onboarding.dart';
import 'data/rates.dart';
import 'data/shortcut_prefs.dart';
import 'data/update_checker.dart';
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

  @override
  State<KapyNotesApp> createState() => _KapyNotesAppState();
}

class _KapyNotesAppState extends State<KapyNotesApp>
    with WidgetsBindingObserver {
  static const _rateRefreshDelay = Duration(seconds: 2);
  // Behind the rate refresh: neither is urgent, and launch belongs to the
  // first frame rather than to two background fetches racing it.
  static const _updateCheckDelay = Duration(seconds: 5);

  final TextEditingController _launchController = TextEditingController();
  EngineProvider? _engines;
  Future<void>? _hydration;
  Timer? _rateRefreshTimer;
  Timer? _updateCheckTimer;
  bool _ready = false;

  /// The welcome note, on the launch that seeded it. Null every other time.
  String? _welcomeNoteId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Quitting from the tray never passes through the platform's exit
    // request, so the flush that request would have triggered has to be
    // handed over explicitly. This state owns the store; nothing below it
    // does.
    widget.desktopIntegration?.onBeforeQuit = _flushAfterHydration;
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
    _activateLoadedApp(capturedText: _launchController.text, intent: intent);
    setState(() {});
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
    if (capturedText.isNotEmpty || intent == LaunchIntent.continueWriting) {
      // The text snapshot and tree switch are synchronous. No platform text
      // event can land between capturing the draft and mounting its note.
      //
      // Which note that is depends on how the app was opened: the Write
      // widget carries on the last one, and everything else starts a new one
      // exactly as it always has.
      QuickCapture.file(widget.notes, capturedText, intent);
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
      // Every edit lands in the store; the service coalesces them into one
      // pass rather than one per keystroke.
      widget.notes.addListener(_onNotesChangedForSync);
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

  void _onNotesChangedForSync() => widget.account?.sync?.requestSync();

  Future<void> _flushAfterHydration() async {
    final hydration = _hydration;
    if (hydration != null) await hydration;
    await widget.store.flush();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.notes.removeListener(_onNotesChangedForSync);
    _rateRefreshTimer?.cancel();
    _updateCheckTimer?.cancel();
    _launchController.dispose();
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
    } else {
      // Deliberately not on `inactive` or `hidden`. On desktop those mean a
      // window that lost focus or was minimised, and an open window quietly
      // going stale is the whole reason the wake-up channel exists. Only a
      // real backgrounding is worth closing a socket for — and there the OS
      // is about to close it anyway.
      if (state == AppLifecycleState.paused ||
          state == AppLifecycleState.detached) {
        sync?.pause();
      }
      unawaited(_flushAfterHydration());
    }
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    await _flushAfterHydration();
    return AppExitResponse.exit;
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return InstantCaptureApp(controller: _launchController);
    }

    return MaterialApp(
      title: AppWordmark.name,
      debugShowCheckedModeBanner: false,
      theme: KapyTheme.light(),
      darkTheme: KapyTheme.dark(),
      themeMode: ThemeMode.system,
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
      ),
    );
  }
}
