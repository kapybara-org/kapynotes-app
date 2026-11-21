import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'lib/ draws every icon through KapyIcons, never Material or Cupertino',
    () {
      final material = RegExp(r'(?<![A-Za-z0-9_])(Icons|CupertinoIcons)\.');
      final offenders = <String>[];
      for (final file in Directory('lib').listSync(recursive: true)) {
        if (file is! File || !file.path.endsWith('.dart')) continue;
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (material.hasMatch(lines[i])) {
            offenders.add('${file.path}:${i + 1}: ${lines[i].trim()}');
          }
        }
      }
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    },
  );

  test('every KapyIcons glyph is a Hugeicons path, never a drawn one', () {
    final source = File('lib/core/iconography.dart').readAsStringSync();
    final custom = RegExp(
      r"static const \w+ = KapyIconData\(\s*0x[0-9A-Fa-f]+,\s*\[",
    );
    expect(custom.allMatches(source).map((m) => m.group(0)), isEmpty);
  });
}
