import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:material_ui/material_ui.dart';

import 'core/platform.dart';
import 'core/desktop_integration.dart';
import 'core/theme.dart';
import 'data/engine_provider.dart';
import 'data/layout_prefs.dart';
import 'data/local_store.dart';
import 'data/notes_store.dart';
import 'data/rates.dart';
import 'data/shortcut_prefs.dart';
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
    this.desktopIntegration,
  });

  final LocalStore store;
  final NotesStore notes;
  final RatesRepository rates;
  final LayoutPrefs prefs;
  final ShortcutPrefs shortcuts;
  final DesktopIntegration? desktopIntegration;

  @override
  State<KapyNotesApp> createState() => _KapyNotesAppState();
}

class _KapyNotesAppState extends State<KapyNotesApp>
    with WidgetsBindingObserver {
  static const _rateRefreshDelay = Duration(seconds: 2);

  final TextEditingController _launchController = TextEditingController();
  EngineProvider? _engines;
  Future<void>? _hydration;
  Timer? _rateRefreshTimer;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.notes.isLoaded) {
      _activateLoadedApp();
    } else {
      _hydration = _hydrateInBackground();
    }
  }

  Future<void> _hydrateInBackground() async {
    await widget.notes.load();
    if (!mounted) return;

    widget.prefs.load();
    widget.shortcuts.load();
    _activateLoadedApp(capturedText: _launchController.text);
    setState(() {});
  }

  void _activateLoadedApp({String capturedText = ''}) {
    if (_ready) return;
    if (capturedText.isNotEmpty) {
      // The text snapshot and tree switch are synchronous. No platform text
      // event can land between capturing the draft and mounting its note.
      widget.notes.create(body: capturedText);
    } else if (AppPlatform.isMobile && widget.notes.isEmpty) {
      // HomePage can create this after its first frame, but doing it before the
      // handoff avoids flashing an empty state and reconnecting the keyboard.
      widget.notes.create();
    }
    widget.rates.loadCache();
    _engines = EngineProvider(widget.rates);
    _ready = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scheduleRateRefresh();
    });
  }

  void _scheduleRateRefresh() {
    if (!_ready || AppPlatform.isFlutterTest) return;
    _rateRefreshTimer?.cancel();
    _rateRefreshTimer = Timer(
      _rateRefreshDelay,
      () => unawaited(widget.rates.refreshIfStale()),
    );
  }

  Future<void> _flushAfterHydration() async {
    final hydration = _hydration;
    if (hydration != null) await hydration;
    await widget.store.flush();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _rateRefreshTimer?.cancel();
    _launchController.dispose();
    _engines?.dispose();
    widget.rates.dispose();
    widget.desktopIntegration?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Writes are coalesced while the app is in use; losing focus or being
    // backgrounded is the moment to make sure everything is on disk.
    if (state == AppLifecycleState.resumed) {
      _scheduleRateRefresh();
    } else {
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
        prefs: widget.prefs,
        shortcuts: widget.shortcuts,
        desktopIntegration: widget.desktopIntegration,
        store: widget.store,
      ),
    );
  }
}
