import 'package:flutter/foundation.dart';

import 'linux_desktop.dart';
import 'platform.dart';

/// Whether this launch can keep secrets in the system keyring.
///
/// Asked once, on Linux, before the first keystore read. A missing keyring is
/// remembered, so later reads and writes never ask again and the log says so
/// once. Other platforms keep their own keystore and are treated as available
/// until a call fails.
class KeyringStatus {
  KeyringStatus({bool available = true}) : _available = available;

  bool _available;
  bool _logged = false;

  bool get available => _available;

  static KeyringStatus instance = KeyringStatus();
  static Future<void>? _probe;

  @visibleForTesting
  static void debugReset({bool available = true}) {
    instance = KeyringStatus(available: available);
    _probe = null;
  }

  /// One question to the session bus. A second call waits on the first.
  static Future<void> probe() {
    if (!AppPlatform.isLinux) return Future.value();
    return _probe ??= _ask();
  }

  static Future<void> _ask() async {
    if (!await LinuxDesktop.hasKeyring()) instance.markUnavailable();
  }

  /// A read or a write failed. Later calls skip the keystore.
  void markUnavailable() {
    _available = false;
    if (_logged) return;
    _logged = true;
    debugPrint(
      "KapyNotes: your system's keyring is not running, so sign-in and sync "
      'will not be kept after quit',
    );
  }
}

/// What a person sees when the keyring isn't running, at the moment it matters.
abstract final class KeyringNotice {
  static const String _absent =
      "Your system's keyring (GNOME Keyring or KWallet) isn't running";

  static const String signIn =
      "$_absent, so you'll be signed out when you quit.";

  static const String passphrase =
      "$_absent, so the key for your synced notes can't be saved here. "
      "Sync would work until you quit, then you'd need this passphrase again.";

  static const String unlock =
      "$_absent, so you'll need your passphrase again each time you open "
      'Kapy Notes.';

  static const String syncing =
      '$_absent. Sync works until you quit, then you\'ll sign in and enter '
      'your passphrase again.';

  static const String connect =
      "$_absent, so a connection won't be remembered after you quit.";

  /// Hidden Notes keeps its PIN in the same keyring, so without one it can be
  /// neither set up nor opened. Said here rather than in the gate so it reads
  /// in the voice of the other notices.
  static const String hiddenNotes =
      "$_absent, so Hidden Notes can't be set up or opened on this computer.";
}
