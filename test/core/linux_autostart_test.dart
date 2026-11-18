import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/linux_autostart.dart';

void main() {
  late Directory home;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('kapy-autostart');
  });

  tearDown(() async {
    if (await home.exists()) await home.delete(recursive: true);
  });

  LinuxAutostart autostart({
    String command = '/opt/Kapy Notes/kapynotes',
    Map<String, String>? environment,
  }) => LinuxAutostart(
    environment: environment ?? {'HOME': home.path},
    command: command,
  );

  test(
    'an entry in ~/.config/autostart runs this copy, and goes away',
    () async {
      final entry = autostart();
      expect(await entry.isEnabled(), isFalse);

      await entry.setEnabled(true);

      expect(
        entry.entry.path,
        '${home.path}/.config/autostart/com.kapybara.kapynotes.desktop',
      );
      final text = await entry.entry.readAsString();
      expect(text, startsWith('[Desktop Entry]\n'));
      expect(text, contains('Exec="/opt/Kapy Notes/kapynotes"\n'));
      expect(text, contains('Icon=com.kapybara.kapynotes\n'));
      expect(await entry.isEnabled(), isTrue);

      await entry.setEnabled(false);
      expect(await entry.entry.exists(), isFalse);
      expect(await entry.isEnabled(), isFalse);
    },
  );

  test('XDG_CONFIG_HOME wins when it is absolute, as the spec says', () {
    expect(
      autostart(
        environment: {'HOME': home.path, 'XDG_CONFIG_HOME': '/srv/config'},
      ).entry.path,
      '/srv/config/autostart/com.kapybara.kapynotes.desktop',
    );
    expect(
      autostart(environment: {'HOME': home.path, 'XDG_CONFIG_HOME': 'relative'})
          .entry
          .path,
      '${home.path}/.config/autostart/com.kapybara.kapynotes.desktop',
    );
  });

  test('an entry a desktop switched off reads as off', () async {
    final entry = autostart();
    await entry.setEnabled(true);
    final enabled = await entry.entry.readAsString();

    await entry.entry.writeAsString('${enabled}Hidden=true\n');
    expect(await entry.isEnabled(), isFalse);

    await entry.entry.writeAsString(
      enabled.replaceAll(
        'X-GNOME-Autostart-enabled=true',
        'X-GNOME-Autostart-enabled=false',
      ),
    );
    expect(await entry.isEnabled(), isFalse);
  });

  test(
    'refresh follows a copy that moved, and leaves one switched off',
    () async {
      await autostart(command: '/old/kapynotes').setEnabled(true);

      await autostart(command: '/new/kapynotes').refresh();
      expect(
        await autostart().entry.readAsString(),
        contains('Exec=/new/kapynotes\n'),
      );

      final entry = autostart();
      final off = '${await entry.entry.readAsString()}Hidden=true\n';
      await entry.entry.writeAsString(off);
      await autostart(command: '/newer/kapynotes').refresh();
      expect(await entry.entry.readAsString(), off);
    },
  );

  test('Exec arguments are quoted and escaped as desktop entries need', () {
    expect(
      LinuxAutostart.execArgument('/usr/bin/kapynotes'),
      '/usr/bin/kapynotes',
    );
    expect(
      LinuxAutostart.execArgument('/home/a b/KapyNotes.AppImage'),
      '"/home/a b/KapyNotes.AppImage"',
    );
    expect(
      LinuxAutostart.execArgument(r'/x/$HOME/"q"'),
      r'"/x/\\$HOME/\\"q\\""',
    );
    expect(LinuxAutostart.execArgument(r'/a\b'), r'"/a\\\\b"');
  });
}
