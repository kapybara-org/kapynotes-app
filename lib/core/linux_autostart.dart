import 'dart:io';

import 'linux_desktop.dart';

/// "Open at login" on Linux: an XDG autostart entry, which every desktop that
/// follows the freedesktop.org specification reads at login.
///
/// The entry names the command that started this copy, so an AppImage runs
/// from where it was saved and a tarball from where it was unpacked. Moving
/// either leaves an entry that points at nothing; [refresh] rewrites it on
/// the next launch.
class LinuxAutostart {
  LinuxAutostart({Map<String, String>? environment, String? command})
    : _environment = environment ?? Platform.environment,
      _command = command;

  static const String fileName = 'com.kapybara.kapynotes.desktop';

  final Map<String, String> _environment;
  final String? _command;

  String get _launch => _command ?? LinuxDesktop.launchCommand();

  File get entry {
    final configured = _environment['XDG_CONFIG_HOME'];
    final config = configured != null && configured.startsWith('/')
        ? configured
        : '${_environment['HOME'] ?? ''}/.config';
    return File('$config/autostart/$fileName');
  }

  /// Whether the entry is there and switched on. A desktop's own startup
  /// settings can switch it off without deleting it, through either key.
  Future<bool> isEnabled() async {
    try {
      final lines = await entry.readAsLines();
      return !lines.any(
        (line) =>
            line.replaceAll(' ', '') == 'Hidden=true' ||
            line.replaceAll(' ', '') == 'X-GNOME-Autostart-enabled=false',
      );
    } on FileSystemException {
      return false;
    }
  }

  /// Writes or removes the entry. Throws a [FileSystemException] when the
  /// directory cannot be written.
  Future<void> setEnabled(bool enabled) async {
    final file = entry;
    if (!enabled) {
      if (await file.exists()) await file.delete();
      return;
    }
    await file.parent.create(recursive: true);
    await file.writeAsString(contents(_launch));
  }

  /// Points an enabled entry at this copy, if it has moved since the entry
  /// was written.
  Future<void> refresh() async {
    if (!await isEnabled()) return;
    final wanted = contents(_launch);
    if (await entry.readAsString() != wanted) {
      await entry.writeAsString(wanted);
    }
  }

  static String contents(String command) =>
      '[Desktop Entry]\n'
      'Type=Application\n'
      'Name=Kapy Notes\n'
      'Comment=Notes where every line is a live calculator\n'
      'Exec=${execArgument(command)}\n'
      'Icon=com.kapybara.kapynotes\n'
      'Terminal=false\n'
      'X-GNOME-Autostart-enabled=true\n';

  /// One argument of a desktop entry's Exec key: quoted when it has to be,
  /// with the four characters that need it escaped inside the quotes, and
  /// then a string value's own escaping applied on top, as the specification
  /// requires.
  static String execArgument(String argument) {
    const reserved = ' \t\n"\'\\><~|&;\$*?#()`';
    final needsQuotes = argument.split('').any(reserved.contains);
    final quoted = needsQuotes
        ? '"${argument.replaceAllMapped(RegExp(r'["`$\\]'), (m) => '\\${m[0]}')}"'
        : argument;
    return quoted.replaceAll(r'\', r'\\');
  }
}
