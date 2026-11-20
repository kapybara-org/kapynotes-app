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
}
