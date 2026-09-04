import 'package:flutter/services.dart';

/// "Open at login", which the runners implement and this asks about.
///
/// Native rather than a package for two reasons. The ones on pub pin a `win32`
/// major that `package_info_plus` has already moved past, so adding one means
/// giving up the version check. And their macOS half writes a LaunchAgent
/// plist into `~/Library`, which this bundle is sandboxed out of — the
/// registration would fail on exactly the builds that ship.
///
/// Every call answers rather than throws. A platform with no handler behind
/// this channel — the phones, a widget test — reads as "not supported here",
/// which is the truth and leaves the setting hidden.
class LoginItem {
  const LoginItem._();

  static const MethodChannel _channel = MethodChannel('kapynotes/login_item');

  /// Whether this host can register the app at all.
  ///
  /// False on macOS 12, where the only mechanism is the one the sandbox
  /// forbids: the API that replaced it arrived in 13.
  static Future<bool> isSupported() async => await _ask('isSupported') ?? false;

  /// Read from the OS every time. A login item can also be removed from
  /// System Settings or the Task Manager's Startup tab, and a remembered
  /// answer would go on claiming otherwise.
  static Future<bool> isEnabled() async => await _ask('isEnabled') ?? false;

  /// Adds or removes the login item, returning what went wrong in words the
  /// settings pane can show, or null if it worked.
  static Future<String?> setEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod<void>('setEnabled', {'enabled': enabled});
      return null;
    } on PlatformException catch (error) {
      return error.message ?? 'Kapy Notes could not change your login items.';
    } on MissingPluginException {
      return 'Opening at login is not available on this system.';
    }
  }

  static Future<bool?> _ask(String method) async {
    try {
      return await _channel.invokeMethod<bool>(method);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
