import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'fake_cli.dart';

void main() {
  test(
    'a run still reading its stdin is not listed until it is complete',
    () async {
      final cli = await FakeCli.create();
      addTearDown(cli.dispose);
      final process = await Process.start(cli.path, ['--print', 'hi']);
      bool started() => cli.root
          .listSync(recursive: true)
          .any((entry) => entry.path.endsWith('/run-${process.pid}'));
      while (!started()) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(cli.runs(), isEmpty);

      process.stdin.write('the question');
      await process.stdin.close();
      expect(await process.exitCode, 0);
      expect(cli.answers().single.stdin, 'the question');
    },
  );
}
