import 'dart:io';

import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/linux_desktop.dart';
import 'package:kapy_notes/core/platform.dart';

void main() {
  test('an AppImage starts from the file, not from where it is mounted', () {
    expect(
      LinuxDesktop.launchCommand(
        environment: {'APPIMAGE': '/home/a/Apps/KapyNotes.AppImage'},
        executable: '/tmp/.mount_KapyNoabc/usr/lib/kapynotes/kapynotes',
      ),
      '/home/a/Apps/KapyNotes.AppImage',
    );
  });

  test('the .deb starts through its link on PATH', () async {
    final temp = await Directory.systemTemp.createTemp('kapy-launch');
    addTearDown(() => temp.delete(recursive: true));
    final root = temp.resolveSymbolicLinksSync();
    final binary = File('$root/lib/kapynotes/kapynotes')
      ..createSync(recursive: true);
    final link = Link('$root/bin/kapynotes')
      ..createSync(binary.path, recursive: true);

    expect(
      LinuxDesktop.launchCommand(
        environment: const {},
        executable: binary.path,
        installed: link.path,
      ),
      link.path,
    );
    expect(
      LinuxDesktop.launchCommand(
        environment: const {},
        executable: '/home/a/kapynotes/kapynotes',
        installed: link.path,
      ),
      '/home/a/kapynotes/kapynotes',
      reason: 'another copy installed beside this tarball is not this one',
    );
  });

  test('a shortcut command reads as a person would type it', () {
    expect(LinuxDesktop.shortcutCommand('/usr/bin/kapynotes'), 'kapynotes');
    expect(
      LinuxDesktop.shortcutCommand(
        '/home/a/Apps/KapyNotes-1.33.0-x86_64.AppImage',
      ),
      '/home/a/Apps/KapyNotes-1.33.0-x86_64.AppImage',
    );
    expect(
      LinuxDesktop.shortcutCommand('/home/a/Kapy Notes/kapynotes'),
      "'/home/a/Kapy Notes/kapynotes'",
    );
    expect(
      LinuxDesktop.shortcutCommand("/home/o'neil/kapynotes/kapynotes"),
      "'/home/o'\\''neil/kapynotes/kapynotes'",
    );
  });

  test('the Flatpak is started by its ID, not by a path in its sandbox', () {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.linux;
    AppPlatform.debugIsFlatpakOverride = true;
    addTearDown(() {
      AppPlatform.debugTargetPlatformOverride = null;
      AppPlatform.debugIsFlatpakOverride = null;
    });

    expect(
      LinuxDesktop.shortcutCommand(),
      'flatpak run com.kapybara.kapynotes',
    );
    expect(
      LinuxDesktop.shortcutCommand('/app/lib/kapynotes/kapynotes'),
      'flatpak run com.kapybara.kapynotes',
    );
  });
}
