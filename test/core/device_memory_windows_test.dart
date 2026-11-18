@TestOn('windows')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/device_memory.dart';

/// The real kernel32 probe, on a real Windows machine. Everywhere else the
/// probe is replaced, so this is the only test that shows the struct layout
/// is right: a wrong one reads a nonsense number or crashes the process.
void main() {
  test("the kernel reports this machine's memory", () async {
    final total = await DeviceMemory().total();

    expect(total, isNotNull);
    expect(total, greaterThan(1000 * 1000 * 1000));
    expect(total, lessThan(64 * 1000 * 1000 * 1000 * 1000));
  });
}
