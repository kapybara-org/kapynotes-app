import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'core/desktop_integration.dart';
import 'core/focus_hold.dart';
import 'core/platform.dart';
import 'data/layout_prefs.dart';
import 'data/local_store.dart';
import 'data/notes_store.dart';
import 'data/rates.dart';
import 'data/shortcut_prefs.dart';
import 'data/update_checker.dart';
import 'speech/speech_api.dart';
import 'sync/account.dart';
import 'sync/auth_api.dart';
import 'sync/config.dart';
import 'sync/key_store.dart';
import 'sync/sync_api.dart';
import 'sync/sync_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // After the binding has claimed the view-focus callback, so it wraps the
  // framework's handler rather than being replaced by it.
  if (AppPlatform.isMacOS) {
    holdFocusWhileInactive(WidgetsBinding.instance.platformDispatcher);
  }

  // Flutter otherwise retains up to 100 MB of decoded images globally. Note
  // previews are durable on disk and cheap to decode again, so a smaller
  // screenful-sized cache saves real RAM without changing what stays visible.
  final imageCache = PaintingBinding.instance.imageCache;
  imageCache.maximumSize = AppPlatform.isMobile ? 80 : 160;
  imageCache.maximumSizeBytes = AppPlatform.isMobile ? 24 << 20 : 48 << 20;

  final store = LocalStore(fileName: 'kapy-notes.json');
  final notes = NotesStore(store);
  final prefs = LayoutPrefs(store);
  final shortcuts = ShortcutPrefs(store);
  final rates = RatesRepository(store);
  // Only where Sparkle/WinSparkle can actually install: Linux desktop and the
  // phones get their updates elsewhere and would show a button that lies.
  final updates = AppPlatform.hasAutoUpdate ? UpdateChecker(store) : null;

  // One object owns the session, the key and the sync loop; everything else
  // just hands it along. Constructed eagerly because it is cheap — nothing
  // here touches the keystore or the network until `restore()` runs, after
  // the first frame.
  // Hoisted out of the constructor because the api needs the device id it
  // holds. `restore()` loads it before anything can call this closure.
  final syncState = SyncState(store);
  final account = kSyncEnabled
      ? Account(
          auth: HttpAuthApi(baseUrl: Uri.parse(kApiBaseUrl)),
          syncApi: (token) => HttpSyncApi(
            baseUrl: Uri.parse(kApiBaseUrl),
            token: () async => token,
            deviceId: syncState.deviceId,
          ),
          keys: KeyStore(defaultSecureStore()),
          notes: notes,
          state: syncState,
          store: store,
        )
      : null;
  // Built here rather than inside Account so that a build with no
  // transcription in it simply never sets this, and the queue never runs.
  account?.speechApiFor = (token) =>
      HttpSpeechApi(baseUrl: Uri.parse(kApiBaseUrl), token: () async => token);

  DesktopIntegration? desktopIntegration;
  if (AppPlatform.isDesktop) {
    // Desktop needs saved window geometry and the global shortcuts before its
    // native window is shown. Mobile starts Flutter immediately and hydrates
    // behind an editable first frame inside KapyNotesApp.
    await notes.load();
    prefs.load();
    shortcuts.load();
    await _configureWindow(prefs.windowSize);
    desktopIntegration = DesktopIntegration(layoutPrefs: prefs);
    await desktopIntegration.initialize(shortcuts);
  }

  runApp(
    KapyNotesApp(
      store: store,
      notes: notes,
      rates: rates,
      prefs: prefs,
      shortcuts: shortcuts,
      updates: updates,
      desktopIntegration: desktopIntegration,
      account: account,
    ),
  );
}

Future<void> _configureWindow(Size size) async {
  await windowManager.ensureInitialized();

  final options = WindowOptions(
    size: size,
    minimumSize: LayoutPrefs.minimumWindowSize,
    center: true,
    title: 'Kapy Notes',
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    // On macOS the toolbar doubles as the title bar, with the traffic lights
    // inset into the sidebar. Windows and Linux keep their native caption —
    // hiding it there would leave the window with no close button.
    titleBarStyle: AppPlatform.isMacOS
        ? TitleBarStyle.hidden
        : TitleBarStyle.normal,
    windowButtonVisibility: true,
  );

  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}
