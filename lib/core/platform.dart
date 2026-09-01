import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

/// Platform questions the UI actually needs answered, in one place.
class AppPlatform {
  const AppPlatform._();

  static bool get isMacOS => !kIsWeb && Platform.isMacOS;
  static bool get isWindows => !kIsWeb && Platform.isWindows;
  static bool get isLinux => !kIsWeb && Platform.isLinux;
  static bool get isIOS => !kIsWeb && Platform.isIOS;
  static bool get isAndroid => !kIsWeb && Platform.isAndroid;

  static bool get isDesktop => isMacOS || isWindows || isLinux;
  static bool get isMobile => isIOS || isAndroid;

  /// Widget tests render without a native window behind transparent surfaces,
  /// so they keep the opaque fallback used on non-vibrant platforms.
  static bool get isFlutterTest =>
      !kIsWeb && Platform.environment['FLUTTER_TEST'] == 'true';

  /// True where the primary input is a mouse and a physical keyboard, which
  /// is what decides hover affordances and menu shortcuts.
  static bool get hasPointer => isDesktop;

  /// The monospace stack the editor and gutter share. Both layers must use
  /// exactly the same list or measured line positions drift.
  static const List<String> monoFontFallback = [
    'SF Mono',
    'SFMono-Regular',
    'Menlo',
    'Cascadia Mono',
    'Consolas',
    'Roboto Mono',
    'DejaVu Sans Mono',
    'monospace',
  ];
}
