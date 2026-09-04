import 'dart:ui' show Locale;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/calc/format.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/core/platform.dart';
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
    expect(prefs.resultsVisible, isTrue);
    expect(prefs.dailySeparatorsEnabled, isTrue);
    expect(prefs.writingFont, WritingFont.handwritten);
    expect(prefs.timeZoneId, isNull);
  });

  test('window, divider, and daily-section preferences survive reload', () {
    final store = _MemoryStore();
    final prefs = LayoutPrefs(store)..load();

    prefs.windowSize = const Size(684, 712);
    prefs.sidebarWidth = 318;
    prefs.gutterWidth = 224;
    prefs.resultsVisible = false;
    prefs.dailySeparatorsEnabled = false;
    prefs.writingFont = WritingFont.clean;

    final restored = LayoutPrefs(store)..load();
    expect(restored.windowSize, const Size(684, 712));
    expect(restored.sidebarWidth, 318);
    expect(restored.gutterWidth, 224);
    expect(restored.resultsVisible, isFalse);
    expect(restored.dailySeparatorsEnabled, isFalse);
    expect(restored.writingFont, WritingFont.clean);
  });

  test('resetting panel widths also brings a hidden results pane back', () {
    final prefs = LayoutPrefs(_MemoryStore())..load();
    prefs.gutterWidth = 320;
    prefs.resultsVisible = false;

    prefs.resetPanelWidths();

    expect(prefs.gutterWidth, LayoutPrefs.defaultGutterWidth);
    expect(prefs.resultsVisible, isTrue);
  });

  test('panel widths stop at compact usable sizes without hiding', () {
    final prefs = LayoutPrefs(_MemoryStore())..load();

    prefs.gutterWidth = 1;
    prefs.sidebarWidth = 1;

    expect(prefs.gutterWidth, LayoutPrefs.minGutterWidth);
    expect(prefs.sidebarWidth, LayoutPrefs.minSidebarWidth);
    expect(prefs.resultsVisible, isTrue);
    expect(prefs.sidebarVisible, isTrue);
  });

  test('number system follows the region until the user overrides it', () {
    final store = _MemoryStore();
    LayoutPrefs prefsIn(Locale locale) =>
        LayoutPrefs(store, locale: () => locale)..load();

    final indian = prefsIn(const Locale('en', 'IN'));
    expect(indian.numberSystem, NumberSystem.auto);
    expect(indian.digitGrouping, DigitGrouping.indian);
    expect(indian.exampleFor(NumberSystem.auto), '1,23,45,678');

    // A South Asian language with no region attached still means lakh.
    expect(prefsIn(const Locale('hi')).digitGrouping, DigitGrouping.indian);
    expect(
      prefsIn(const Locale('en', 'US')).digitGrouping,
      DigitGrouping.international,
    );

    // An explicit choice wins over the region, and survives a reload.
    prefsIn(const Locale('en', 'IN')).numberSystem = NumberSystem.international;
    final restored = prefsIn(const Locale('en', 'IN'));
    expect(restored.numberSystem, NumberSystem.international);
    expect(restored.digitGrouping, DigitGrouping.international);
    expect(restored.exampleFor(NumberSystem.indian), '1,23,45,678');
  });

  test('an unreadable stored number system falls back to the region', () {
    final store = _MemoryStore()..put('numberSystem.v1', 'martian');
    final prefs = LayoutPrefs(store, locale: () => const Locale('en', 'GB'))
      ..load();

    expect(prefs.numberSystem, NumberSystem.auto);
    expect(prefs.digitGrouping, DigitGrouping.international);
  });

  test('an unreadable writing font falls back to handwritten', () {
    final store = _MemoryStore()..put('writingFont.v1', 'papyrus');
    final prefs = LayoutPrefs(store)..load();

    expect(prefs.writingFont, WritingFont.handwritten);
  });

  test('time zone selection converts timestamps and survives reload', () {
    final store = _MemoryStore();
    final prefs = LayoutPrefs(store)..load();

    prefs.timeZoneId = 'Asia/Kolkata';
    final displayed = prefs.displayTime(DateTime.utc(2026, 9, 1, 18, 12));
    expect(displayed.hour, 23);
    expect(displayed.minute, 42);
    expect(displayed.timeZoneOffset, const Duration(hours: 5, minutes: 30));

    final restored = LayoutPrefs(store)..load();
    expect(restored.timeZoneId, 'Asia/Kolkata');

    restored.timeZoneId = null;
    expect(store.data['timeZone.v1'], '');
    expect((LayoutPrefs(store)..load()).timeZoneId, isNull);
  });

  test('an unreadable stored time zone follows the system', () {
    final store = _MemoryStore()..put('timeZone.v1', 'Mars/Olympus_Mons');
    final prefs = LayoutPrefs(store)..load();

    expect(prefs.timeZoneId, isNull);
  });

  test('keeping the app running past its window is off until asked for', () {
    final store = _MemoryStore();
    final prefs = LayoutPrefs(store)..load();

    // An app that will not go away when you close it is the user's call.
    expect(prefs.keepRunningInBackground, isFalse);

    prefs.keepRunningInBackground = true;
    expect((LayoutPrefs(store)..load()).keepRunningInBackground, isTrue);
  });

  // The summon shortcut is the only one registered system-wide, so the exact
  // chord matters: Cmd/Ctrl+Shift+Space collided with 1Password's Quick Access
  // and simply never fired. Windows differs from macOS on purpose — Ctrl+Alt is
  // AltGr on international layouts.
  test('the summon shortcut avoids the combinations other apps claim', () {
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);

    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
    final mac = ShortcutPrefs.defaultFor(ShortcutAction.openApp);
    expect(mac.displayLabel, 'Cmd + Option + X');
    expect(mac.shift, isFalse, reason: 'Cmd+Shift+Space is 1Password');

    AppPlatform.debugTargetPlatformOverride = TargetPlatform.windows;
    final windows = ShortcutPrefs.defaultFor(ShortcutAction.openApp);
    expect(windows.displayLabel, 'Ctrl + Shift + X');
    expect(windows.alt, isFalse, reason: 'Ctrl+Alt is AltGr on many layouts');
  });

  // The second and last shortcut the OS hears. It mirrors the summon chord so
  // that one teaches the other, and it must not sit on the in-app Cmd/Ctrl+N.
  test('the global new-note shortcut mirrors the summon chord', () {
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);

    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
    final mac = ShortcutPrefs.defaultFor(ShortcutAction.newNoteAnywhere);
    expect(mac.displayLabel, 'Cmd + Option + N');

    AppPlatform.debugTargetPlatformOverride = TargetPlatform.windows;
    final windows = ShortcutPrefs.defaultFor(ShortcutAction.newNoteAnywhere);
    expect(windows.displayLabel, 'Ctrl + Shift + N');
    expect(windows.alt, isFalse, reason: 'Ctrl+Alt is AltGr on many layouts');
  });

  test('no two shortcuts ship on the same combination', () {
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);

    for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
      AppPlatform.debugTargetPlatformOverride = platform;
      final claimed = <ShortcutBinding, ShortcutAction>{};
      for (final action in ShortcutAction.values) {
        final binding = ShortcutPrefs.defaultFor(action);
        expect(
          claimed[binding],
          isNull,
          reason:
              '${action.name} ships on ${binding.displayLabel}, which '
              '${claimed[binding]?.name} already has on $platform',
        );
        claimed[binding] = action;
      }
    }
  });

  test('only the summon and new-note shortcuts reach the OS', () {
    expect(ShortcutAction.values.where((action) => action.isGlobal), [
      ShortcutAction.openApp,
      ShortcutAction.newNoteAnywhere,
    ]);
  });

  test(
    'an install still on the 1Password-shadowed shortcut is moved across',
    () {
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;

      // What 1.0.0 wrote to disk.
      final store = _MemoryStore();
      store.data['shortcuts.v1'] = {
        'openApp': ShortcutBinding(
          logicalKey: LogicalKeyboardKey.space,
          physicalKey: PhysicalKeyboardKey.space,
          meta: true,
          shift: true,
        ).toJson(),
      };

      final prefs = ShortcutPrefs(store)..load();
      expect(
        prefs.bindingFor(ShortcutAction.openApp).displayLabel,
        'Cmd + Option + X',
      );

      // Written back, so the move survives a restart.
      final reloaded = ShortcutPrefs(store)..load();
      expect(
        reloaded.bindingFor(ShortcutAction.openApp).displayLabel,
        'Cmd + Option + X',
      );
    },
  );

  test('a shortcut the user chose themselves is left alone', () {
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;

    final chosen = ShortcutBinding(
      logicalKey: LogicalKeyboardKey.f9,
      physicalKey: PhysicalKeyboardKey.f9,
      control: true,
    );
    final store = _MemoryStore();
    store.data['shortcuts.v1'] = {'openApp': chosen.toJson()};

    final prefs = ShortcutPrefs(store)..load();
    expect(prefs.bindingFor(ShortcutAction.openApp), chosen);
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

    expect(prefs.bindingFor(ShortcutAction.openApp).keyLabel, 'X');
    expect(prefs.conflictFor(ShortcutAction.findNotes, replacement), isNull);

    prefs.update(ShortcutAction.findNotes, replacement);
    expect(
      prefs.conflictFor(ShortcutAction.newNote, replacement),
      ShortcutAction.findNotes,
    );

    final restored = ShortcutPrefs(store)..load();
    expect(restored.bindingFor(ShortcutAction.findNotes), replacement);
  });

  test('formatting shortcuts have distinct OS-specific defaults', () {
    final prefs = ShortcutPrefs(_MemoryStore())..load();
    final defaults = [
      for (final action in ShortcutAction.values) prefs.bindingFor(action),
    ];

    expect(defaults.toSet(), hasLength(ShortcutAction.values.length));
    expect(
      prefs.bindingFor(ShortcutAction.cycleTextStyle).logicalKey,
      LogicalKeyboardKey.keyT,
    );
    expect(
      prefs.bindingFor(ShortcutAction.formatBold).logicalKey,
      LogicalKeyboardKey.keyB,
    );
    expect(
      prefs.bindingFor(ShortcutAction.formatItalic).logicalKey,
      LogicalKeyboardKey.keyI,
    );
    expect(prefs.bindingFor(ShortcutAction.formatBullets).shift, isTrue);
    expect(
      prefs.bindingFor(ShortcutAction.formatChecklist).logicalKey,
      LogicalKeyboardKey.keyC,
    );
    expect(prefs.bindingFor(ShortcutAction.formatChecklist).shift, isTrue);

    final bold = prefs.bindingFor(ShortcutAction.formatBold);
    expect(bold.meta, AppPlatform.isMacOS);
    expect(bold.control, !AppPlatform.isMacOS);
    expect(bold.displayLabel, contains(AppPlatform.isMacOS ? 'Cmd' : 'Ctrl'));
  });
}
