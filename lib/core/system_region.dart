import 'package:flutter/services.dart';

/// The country the device is *set to*, which is not the language it is read in.
///
/// Flutter only ever offers the second. `PlatformDispatcher.locale` comes from
/// the preferred-languages list, so a Mac whose language is English (US) and
/// whose Region is India reports `en_US` — `Locale.current.identifier` on that
/// same machine is `en_US@rg=inzzzz`, and only the native side can see the
/// `IN` in it. Reading the language and calling it a region is why "Match my
/// region" wrote millions for people who count in crore.
///
/// Every platform here has a setting that means exactly this and is separate
/// from the display language: Region on macOS and iOS, Country or region on
/// Windows, and the system locale on Android — which is the one place the two
/// genuinely are the same thing, so the answer only differs there when an app
/// has been given a language of its own.
///
/// A platform with no handler behind this channel answers null, and the caller
/// falls back to reading the locale as before. Nothing here throws.
class SystemRegion {
  const SystemRegion._();

  static const MethodChannel channel = MethodChannel('kapynotes/region');

  /// An upper-case ISO 3166-1 alpha-2 code, or null where the platform will
  /// not say. Anything that is not two letters is treated as no answer: the
  /// UN M.49 numeric codes some systems return ("419" for Latin America) name
  /// a group of countries rather than one, and a group cannot be looked up.
  static Future<String?> read() async {
    try {
      final code = await channel.invokeMethod<String>('region');
      if (code == null) return null;
      final trimmed = code.trim().toUpperCase();
      return RegExp(r'^[A-Z]{2}$').hasMatch(trimmed) ? trimmed : null;
    } catch (_) {
      // Deliberately everything. A missing handler and a platform that
      // refused are the expected two, but a unit test with no binding behind
      // the channel throws neither, and a preference read must not be the
      // thing that fails. Every one of them means the same: nobody said.
      return null;
    }
  }
}
