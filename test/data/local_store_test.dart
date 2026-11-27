import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Puts the store's file under the system temp, so the test reads what a
/// killed process would leave behind.
class _FakePaths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _FakePaths(this.root);

  final Directory root;

  @override
  Future<String?> getApplicationSupportPath() async => root.path;
}

void main() {
  late Directory root;
  late LocalStore store;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('kapy-local-store-test');
    PathProviderPlatform.instance = _FakePaths(root);
    store = LocalStore(fileName: 'notes.json');
    await store.load();
  });

  tearDown(() {
    store.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// What a process killed right now would find on disk.
  String? onDisk() {
    final file = File('${root.path}/notes.json');
    if (!file.existsSync()) return null;
    return (jsonDecode(file.readAsStringSync()) as Map)['note'] as String?;
  }

  test('typing without a pause reaches the disk within the delay of its '
      'first key, so a kill mid-sentence loses only the last moment', () async {
    expect(store.delay, const Duration(milliseconds: 250));
    final typed = StringBuffer();
    final onDiskWhileTyping = <String?>[];
    // Ten keys a second for two seconds, with no pause long enough for a
    // write that waits for one.
    for (var key = 0; key < 20; key++) {
      typed.write('a');
      store.put('note', typed.toString());
      await Future<void>.delayed(const Duration(milliseconds: 100));
      onDiskWhileTyping.add(onDisk());
    }
    expect(onDiskWhileTyping.take(2), everyElement(isNull));
    // From the fifth key on, the disk is never more than a few keys behind.
    for (var key = 4; key < 20; key++) {
      expect(
        onDiskWhileTyping[key]?.length,
        greaterThanOrEqualTo(key + 1 - 5),
        reason: 'after key ${key + 1}: ${onDiskWhileTyping[key]}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(onDisk(), typed.toString());
  });

  test('flush writes at once and leaves nothing waiting', () async {
    store.put('note', 'hello');
    await store.flush();
    expect(onDisk(), 'hello');
    store.put('note', 'hello there');
    await store.flush();
    expect(onDisk(), 'hello there');
  });
}
