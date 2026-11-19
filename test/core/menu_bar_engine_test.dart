import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// The menu bar panel turns on the macOS engine's multi-view switch by its
/// private name (macos/Runner/MenuBarPanel.swift). An engine that renames it
/// quietly loses the panel, the icon falls back to its menu, and nothing else
/// would say so. This does, on the Mac that runs the upgrade's tests.
void main() {
  test(
    "the macOS engine still has the panel's multi-view switch",
    () {
      final engine = Directory(
        File(Platform.resolvedExecutable).parent.path,
      ).uri.resolve(
        '../darwin-x64/FlutterMacOS.xcframework/macos-arm64_x86_64/'
        'FlutterMacOS.framework/Versions/A/FlutterMacOS',
      );
      final binary = File.fromUri(engine);
      expect(binary.existsSync(), isTrue, reason: 'no engine at $engine');
      expect(
        _contains(binary.readAsBytesSync(), '_multiViewEnabled'.codeUnits),
        isTrue,
        reason:
            'FlutterEngine no longer has _multiViewEnabled: the menu bar '
            'panel is gone on this engine. See MenuBarPanel.multiViewIvar.',
      );
    },
    skip: !Platform.isMacOS,
  );
}

bool _contains(Uint8List haystack, List<int> needle) {
  outer:
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}
