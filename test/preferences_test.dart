import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'preferences-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

void main() {
  test('desktop window size defaults to the compact portrait layout', () {
    final prefs = LayoutPrefs(_MemoryStore())..load();

    expect(prefs.windowSize, const Size(600, 630));
    expect(prefs.dailySeparatorsEnabled, isTrue);
  });

  test('window, divider, and daily-section preferences survive reload', () {
    final store = _MemoryStore();
    final prefs = LayoutPrefs(store)..load();

    prefs.windowSize = const Size(684, 712);
    prefs.sidebarWidth = 318;
    prefs.gutterWidth = 224;
    prefs.dailySeparatorsEnabled = false;

    final restored = LayoutPrefs(store)..load();
    expect(restored.windowSize, const Size(684, 712));
    expect(restored.sidebarWidth, 318);
    expect(restored.gutterWidth, 224);
    expect(restored.dailySeparatorsEnabled, isFalse);
  });

  test('shortcuts are editable, persistent, and cannot collide', () {
    final store = _MemoryStore();
    final prefs = ShortcutPrefs(store)..load();
    final replacement = ShortcutBinding(
      logicalKey: LogicalKeyboardKey.keyP,
      physicalKey: PhysicalKeyboardKey.keyP,
      control: true,
      shift: true,
    );

    expect(prefs.bindingFor(ShortcutAction.openApp).keyLabel, 'Space');
    expect(prefs.conflictFor(ShortcutAction.findNotes, replacement), isNull);

    prefs.update(ShortcutAction.findNotes, replacement);
    expect(
      prefs.conflictFor(ShortcutAction.newNote, replacement),
      ShortcutAction.findNotes,
    );

    final restored = ShortcutPrefs(store)..load();
    expect(restored.bindingFor(ShortcutAction.findNotes), replacement);
  });
}
