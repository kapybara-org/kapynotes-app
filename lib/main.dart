import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'core/desktop_integration.dart';
import 'core/platform.dart';
import 'data/layout_prefs.dart';
import 'data/local_store.dart';
import 'data/notes_store.dart';
import 'data/rates.dart';
import 'data/shortcut_prefs.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final store = LocalStore(fileName: 'kapy-notes.json');
  final notes = NotesStore(store);
  final prefs = LayoutPrefs(store);
  final shortcuts = ShortcutPrefs(store);
  final rates = RatesRepository(store);

  DesktopIntegration? desktopIntegration;
  if (AppPlatform.isDesktop) {
    // Desktop needs saved window geometry and the global shortcut before its
    // native window is shown. Mobile starts Flutter immediately and hydrates
    // behind an editable first frame inside KapyNotesApp.
    await notes.load();
    prefs.load();
    shortcuts.load();
    await _configureWindow(prefs.windowSize);
    desktopIntegration = DesktopIntegration(layoutPrefs: prefs);
    await desktopIntegration.initialize(
      shortcuts.bindingFor(ShortcutAction.openApp),
    );
  }

  runApp(
    KapyNotesApp(
      store: store,
      notes: notes,
      rates: rates,
      prefs: prefs,
      shortcuts: shortcuts,
      desktopIntegration: desktopIntegration,
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
