import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Alignment;
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import '../data/layout_prefs.dart';
import 'linux_desktop.dart';

/// Places the native window before it is shown.
///
/// A placement the user chose wins exactly while its title area is still on
/// a connected display. A first launch, or a display which has since been
/// unplugged, gets the sticky-note default on the right of the active screen.
///
/// Wayland leaves placement to the compositor: a window there can neither
/// move itself nor read where it is, so only its size is restored.
Future<void> placeInitialDesktopWindow(LayoutPrefs prefs) async {
  final wayland = await LinuxDesktop.isWayland();
  final savedBounds = prefs.windowBounds;
  var restored = wayland;

  if (!restored && savedBounds != null && await _canRestore(savedBounds)) {
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
    prefs.rememberWindowBounds(
      await rememberedWindowBounds(prefs, wayland: wayland),
    );
  } catch (error) {
    debugPrint('KapyNotes: could not read the initial window bounds: $error');
  }
}

/// The bounds worth saving. Wayland reports every window at the origin, so
/// there only the size is news, and the position stays the last one a session
/// that could see it saved.
Future<Rect> rememberedWindowBounds(
  LayoutPrefs prefs, {
  required bool wayland,
}) async {
  final bounds = await windowManager.getBounds();
  if (!wayland) return bounds;
  return (prefs.windowBounds?.topLeft ?? Offset.zero) & bounds.size;
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

/// The work area of the display holding the middle of [window], or of the
/// first display when none does. Null when the displays cannot be asked.
Future<Rect?> workAreaHolding(Rect window) async {
  try {
    final areas = (await screenRetriever.getAllDisplays()).map(_visibleBounds);
    return areas.where((area) => area.contains(window.center)).firstOrNull ??
        areas.firstOrNull;
  } catch (error) {
    debugPrint('KapyNotes: could not read the displays: $error');
    return null;
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
