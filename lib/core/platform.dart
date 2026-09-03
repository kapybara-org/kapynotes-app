import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

/// Platform questions the UI actually needs answered, in one place.
class AppPlatform {
  const AppPlatform._();

  @visibleForTesting
  static TargetPlatform? debugTargetPlatformOverride;

  static bool _is(TargetPlatform target, bool hostValue) =>
      !kIsWeb &&
      (debugTargetPlatformOverride == null
          ? hostValue
          : debugTargetPlatformOverride == target);

  static bool get isMacOS => _is(TargetPlatform.macOS, Platform.isMacOS);
  static bool get isWindows => _is(TargetPlatform.windows, Platform.isWindows);
  static bool get isLinux => _is(TargetPlatform.linux, Platform.isLinux);
  static bool get isIOS => _is(TargetPlatform.iOS, Platform.isIOS);
  static bool get isAndroid => _is(TargetPlatform.android, Platform.isAndroid);

  static bool get isDesktop => isMacOS || isWindows || isLinux;
  static bool get isMobile => isIOS || isAndroid;

  /// Where the app updates itself. Sparkle and WinSparkle cover macOS and
  /// Windows; Linux has no equivalent, and the stores update the phones.
  static bool get hasAutoUpdate => isMacOS || isWindows;

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
