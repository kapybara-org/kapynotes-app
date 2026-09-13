import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Alignment;
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import '../data/layout_prefs.dart';

/// Places the native window before it is shown.
///
/// A placement the user chose wins exactly while its title area is still on
/// a connected display. A first launch, or a display which has since been
/// unplugged, gets the sticky-note default on the right of the active screen.
Future<void> placeInitialDesktopWindow(LayoutPrefs prefs) async {
  final savedBounds = prefs.windowBounds;
  var restored = false;

  if (savedBounds != null && await _canRestore(savedBounds)) {
    try {
      await windowManager.setPosition(savedBounds.topLeft);
      restored = true;
    } catch (error) {
      debugPrint('KapyNotes: could not restore the window position: $error');
    }
  }

  if (!restored) {
    try {
      await windowManager.setAlignment(Alignment.centerRight);
    } catch (error) {
      // The host's own placement is still usable if display discovery is
      // unavailable. Showing the app matters more than enforcing a default.
      debugPrint('KapyNotes: could not place the window on the right: $error');
    }
  }

  try {
    // Save what the OS actually accepted. It may constrain an oversized
    // legacy window to the current work area, and that adjusted answer is the
    // one the next launch should reproduce.
    prefs.rememberWindowBounds(await windowManager.getBounds());
  } catch (error) {
    debugPrint('KapyNotes: could not read the initial window bounds: $error');
  }
}

Future<bool> _canRestore(Rect savedBounds) async {
  try {
    final displays = await screenRetriever.getAllDisplays();
    return isWindowPlacementReachable(
      savedBounds,
      displays.map(_visibleBounds),
    );
  } catch (error) {
    // Display discovery is a safety check. If it is unavailable, preserving
    // the user's exact saved position is a better fallback than discarding it.
    debugPrint('KapyNotes: could not validate the saved display: $error');
    return true;
  }
}

Rect _visibleBounds(Display display) =>
    (display.visiblePosition ?? Offset.zero) &
    (display.visibleSize ?? display.size);

/// Whether enough of the draggable top edge remains on any work area for the
/// user to recover the window themselves.
@visibleForTesting
bool isWindowPlacementReachable(Rect window, Iterable<Rect> workAreas) {
  if (!window.left.isFinite ||
      !window.top.isFinite ||
      !window.width.isFinite ||
      !window.height.isFinite) {
    return false;
  }

  final chrome = Rect.fromLTWH(
    window.left,
    window.top,
    window.width,
    math.min(window.height, 48),
  );
  final neededWidth = math.min(window.width, 80);
  final neededHeight = math.min(chrome.height, 24);

  return workAreas.any((area) {
    final visibleChrome = chrome.intersect(area);
    return visibleChrome.width >= neededWidth &&
        visibleChrome.height >= neededHeight;
  });
}
