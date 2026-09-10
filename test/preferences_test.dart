import 'dart:ui' show Locale;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/calc/format.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/appearance.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;
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

/// Persists only when flushed, the way the file on disk does. A write still
/// sitting in the coalescing window simply is not there.
class _FlushOnlyStore extends LocalStore {
  _FlushOnlyStore() : super(fileName: 'flush-only-test.json');

  final Map<String, Object?> persisted = {};

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async => persisted.addAll(data);
}

void main() {
  test('desktop window size defaults to the compact portrait layout', () {
    final prefs = LayoutPrefs(_MemoryStore())..load();

    expect(prefs.windowSize, const Size(600, 630));
    expect(prefs.resultsVisible, isTrue);
    expect(prefs.readyToTypeOnOpen, isTrue);
    expect(prefs.dailySeparatorsEnabled, isTrue);
    expect(prefs.spellCheckEnabled, isTrue);
    expect(prefs.writingFont, WritingFont.handwritten);
    expect(prefs.transparencyEnabled, isFalse);
    expect(prefs.timeZoneId, isNull);
  });

  test('window, divider, and daily-section preferences survive reload', () {
    final store = _MemoryStore();
    final prefs = LayoutPrefs(store)..load();

    prefs.windowSize = const Size(684, 712);
    prefs.sidebarWidth = 318;
    prefs.gutterWidth = 224;
    prefs.resultsVisible = false;
    prefs.readyToTypeOnOpen = false;
    prefs.dailySeparatorsEnabled = false;
    prefs.spellCheckEnabled = false;
    prefs.writingFont = WritingFont.clean;
    prefs.transparencyEnabled = true;

    final restored = LayoutPrefs(store)..load();
    expect(restored.windowSize, const Size(684, 712));
    expect(restored.sidebarWidth, 318);
    expect(restored.gutterWidth, 224);
    expect(restored.resultsVisible, isFalse);
    expect(restored.readyToTypeOnOpen, isFalse);
    expect(restored.dailySeparatorsEnabled, isFalse);
    expect(restored.spellCheckEnabled, isFalse);
    expect(restored.writingFont, WritingFont.clean);
    expect(restored.transparencyEnabled, isTrue);
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
    expect(prefs.sidebarVisible, isFalse, reason: 'closed until asked for');
  });

  test('a setting is on disk before the app can be quit', () {
    // The real store only persists on flush, so a value left waiting in the
    // coalescing window is a value a quit would have thrown away.
    final store = _FlushOnlyStore();
    final prefs = LayoutPrefs(store)..load();

    prefs.writingFont = WritingFont.clean;

    expect(
      store.persisted['writingFont.v1'],
      'clean',
      reason: 'changing then quitting must not lose the choice',
    );
  });

  test('sidebar visibility resets on every launch', () {
    final store = _MemoryStore();
    // Older builds persisted this. The launch rule deliberately ignores it.
    store.data['sidebarVisible.v1'] = true;
    final prefs = LayoutPrefs(store)..load();
    expect(prefs.sidebarVisible, isFalse);

    prefs.toggleSidebar();
    expect(prefs.sidebarVisible, isTrue);

    // A second instance over the same storage is the next launch.
    final restarted = LayoutPrefs(store)..load();
    expect(restarted.sidebarVisible, isFalse);
  });

  test('startup note follows the last opened note by default', () {
    final store = _MemoryStore();
    final prefs = LayoutPrefs(store)..load();

    expect(prefs.defaultNoteId, isNull);
    prefs.lastOpenedNoteId = 'note-2';

    final restored = LayoutPrefs(store)..load();
    expect(restored.resolveOpeningNoteId(['note-1', 'note-2']), 'note-2');
  });

  test('a fixed startup note falls back when it is deleted', () {
    final store = _MemoryStore();
    final prefs = LayoutPrefs(store)..load();
    prefs.lastOpenedNoteId = 'note-2';
    prefs.defaultNoteId = 'note-1';

    expect(prefs.resolveOpeningNoteId(['note-1', 'note-2']), 'note-1');
    expect(prefs.resolveOpeningNoteId(['note-2']), 'note-2');
    expect(prefs.defaultNoteId, isNull);
    expect(store.data['defaultNote.v1'], '');
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

  test('a desktop app stays in the tray, and a no is remembered', () {
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;

    final store = _MemoryStore();
    // The summon shortcut, the new-note shortcut and the tray icon all
    // assume the app is already running.
    expect((LayoutPrefs(store)..load()).keepRunningInBackground, isTrue);

    (LayoutPrefs(store)..load()).keepRunningInBackground = false;

    // The default only ever reaches somebody who has not answered. Once they
    // have, it stops having an opinion.
    expect((LayoutPrefs(store)..load()).keepRunningInBackground, isFalse);
  });

  test('a phone has no window to close and no tray to close it into', () {
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;

    expect(
      (LayoutPrefs(_MemoryStore())..load()).keepRunningInBackground,
      isFalse,
    );
  });

  test('a phone ignores a stored desktop transparency choice', () {
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    final store = _MemoryStore()..data['transparencyEnabled.v1'] = true;
    final prefs = LayoutPrefs(store)..load();

    expect(prefs.transparencyEnabled, isFalse);
    prefs.transparencyEnabled = true;
    expect(prefs.transparencyEnabled, isFalse);
  });

  group('appearance and paper', () {
    test('the system decides until somebody says otherwise', () {
      final store = _MemoryStore();
      final prefs = LayoutPrefs(store)..load();

      expect(prefs.appearance, AppearanceMode.system);
      expect(prefs.appearance.themeMode, ThemeMode.system);
      expect(prefs.paperStyle, PaperStyle.notepad);

      prefs.appearance = AppearanceMode.dark;
      prefs.paperStyle = PaperStyle.ruled;

      final reloaded = LayoutPrefs(store)..load();
      expect(reloaded.appearance, AppearanceMode.dark);
      expect(reloaded.appearance.themeMode, ThemeMode.dark);
      expect(reloaded.paperStyle, PaperStyle.ruled);
    });

    test(
      'a value written by a later version falls back rather than throws',
      () {
        final store = _MemoryStore()
          ..data['appearance.v1'] = 'sepia'
          ..data['paper.v1'] = 'graph';
        final prefs = LayoutPrefs(store)..load();

        expect(prefs.appearance, AppearanceMode.system);
        expect(prefs.paperStyle, PaperStyle.notepad);
      },
    );

    test('the theme has a signal of its own, narrower than the object', () {
      // The app root rebuilds its theme from this, and LayoutPrefs notifies
      // for every dragged pixel of the sidebar.
      final prefs = LayoutPrefs(_MemoryStore())..load();
      var themeSignals = 0;
      prefs.appearanceListenable.addListener(() => themeSignals++);

      prefs.sidebarWidth = LayoutPrefs.defaultSidebarWidth + 40;
      expect(themeSignals, 0);

      prefs.appearance = AppearanceMode.light;
      expect(themeSignals, 1);
    });
  });

  group('where the caret was left', () {
    test('is offered back the same day, and outlives the launch', () {
      final store = _MemoryStore();
      final prefs = LayoutPrefs(store)..load();
      expect(prefs.caretIn('n1'), isNull);

      prefs.rememberCaret('n1', 42);
      expect(prefs.caretIn('n1'), 42);
      expect((LayoutPrefs(store)..load()).caretIn('n1'), 42);
      // Each note keeps its own place.
      expect(prefs.caretIn('n2'), isNull);
    });

    test('is not offered back on another day, and is thrown away', () {
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      final store = _MemoryStore()
        ..data['caret.v1'] = {
          'n1': [42, yesterday.millisecondsSinceEpoch],
        };
      final prefs = LayoutPrefs(store)..load();

      expect(prefs.caretIn('n1'), isNull);
      // And not merely refused: a position nothing will ever offer back is
      // what would otherwise grow this map for the life of the install.
      expect(store.data['caret.v1'], isEmpty);
    });

    test('a record this version cannot read is dropped, not thrown on', () {
      final store = _MemoryStore()
        ..data['caret.v1'] = {
          'good': [7, DateTime.now().millisecondsSinceEpoch],
          'nonsense': 'not a pair',
          'short': [7],
          'negative': [-1, DateTime.now().millisecondsSinceEpoch],
        };
      final prefs = LayoutPrefs(store)..load();

      expect(prefs.caretIn('good'), 7);
      expect(prefs.caretIn('nonsense'), isNull);
      expect(prefs.caretIn('short'), isNull);
      expect(prefs.caretIn('negative'), isNull);
    });

    test('does not notify: the cursor moving is not a rebuild', () {
      final prefs = LayoutPrefs(_MemoryStore())..load();
      var notified = 0;
      prefs.addListener(() => notified++);

      prefs.rememberCaret('n1', 1);
      prefs.rememberCaret('n1', 2);

      expect(
        notified,
        0,
        reason: 'this moves with every keystroke; the sidebar must not',
      );
    });
  });

  test('the transparency amount persists, clamps and outlives the mode', () {
    final store = _MemoryStore();
    final prefs = LayoutPrefs(store)..load();
    expect(prefs.transparencyAmount, LayoutPrefs.defaultTransparencyAmount);

    prefs.transparencyAmount = 0.8;
    expect((LayoutPrefs(store)..load()).transparencyAmount, 0.8);

    prefs.transparencyAmount = 3;
    expect(prefs.transparencyAmount, 1);
    prefs.transparencyAmount = -1;
    expect(prefs.transparencyAmount, 0);

    // Off and on again finds the amount where it was left.
    prefs.transparencyAmount = 0.3;
    prefs.transparencyEnabled = false;
    expect((LayoutPrefs(store)..load()).transparencyAmount, 0.3);

    store.data['transparencyAmount.v1'] = 9;
    expect((LayoutPrefs(store)..load()).transparencyAmount, 1);
  });

  test('Windows keeps a transparency choice, Linux does not', () {
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    final store = _MemoryStore()..data['transparencyEnabled.v1'] = true;

    AppPlatform.debugTargetPlatformOverride = TargetPlatform.windows;
    expect((LayoutPrefs(store)..load()).transparencyEnabled, isTrue);

    AppPlatform.debugTargetPlatformOverride = TargetPlatform.linux;
    final linux = LayoutPrefs(store)..load();
    expect(linux.transparencyEnabled, isFalse);
    linux.transparencyEnabled = true;
    expect(linux.transparencyEnabled, isFalse);
  });

  test('the login-item default is spent once, and stays spent', () {
    final store = _MemoryStore();
    final prefs = LayoutPrefs(store)..load();
    expect(prefs.loginItemDefaultApplied, isFalse);

    prefs.markLoginItemDefaultApplied();

    // Written straight through rather than left in the coalescing window: a
    // launch that ends before the flush would apply the default a second
    // time, against a user who may have just turned it off.
    expect((LayoutPrefs(store)..load()).loginItemDefaultApplied, isTrue);
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
        prefs.bindingFor(ShortcutAction.openApp)!.displayLabel,
        'Cmd + Option + X',
      );

      // Written back, so the move survives a restart.
      final reloaded = ShortcutPrefs(store)..load();
      expect(
        reloaded.bindingFor(ShortcutAction.openApp)!.displayLabel,
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
    expect(prefs.bindingFor(ShortcutAction.openApp)!, chosen);
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

    expect(prefs.bindingFor(ShortcutAction.openApp)!.keyLabel, 'X');
    expect(prefs.conflictFor(ShortcutAction.findNotes, replacement), isNull);

    prefs.update(ShortcutAction.findNotes, replacement);
    expect(
      prefs.conflictFor(ShortcutAction.newNote, replacement),
      ShortcutAction.findNotes,
    );

    final restored = ShortcutPrefs(store)..load();
    expect(restored.bindingFor(ShortcutAction.findNotes)!, replacement);
  });

  test('formatting shortcuts have distinct OS-specific defaults', () {
    final prefs = ShortcutPrefs(_MemoryStore())..load();
    final defaults = [
      for (final action in ShortcutAction.values) prefs.bindingFor(action)!,
    ];

    expect(defaults.toSet(), hasLength(ShortcutAction.values.length));
    expect(
      prefs.bindingFor(ShortcutAction.cycleTextStyle)!.logicalKey,
      LogicalKeyboardKey.keyT,
    );
    expect(
      prefs.bindingFor(ShortcutAction.formatBold)!.logicalKey,
      LogicalKeyboardKey.keyB,
    );
    expect(
      prefs.bindingFor(ShortcutAction.formatItalic)!.logicalKey,
      LogicalKeyboardKey.keyI,
    );
    expect(prefs.bindingFor(ShortcutAction.formatBullets)!.shift, isTrue);
    expect(
      prefs.bindingFor(ShortcutAction.formatChecklist)!.logicalKey,
      LogicalKeyboardKey.keyC,
    );
    expect(prefs.bindingFor(ShortcutAction.formatChecklist)!.shift, isTrue);

    final bold = prefs.bindingFor(ShortcutAction.formatBold)!;
    expect(bold.meta, AppPlatform.isMacOS);
    expect(bold.control, !AppPlatform.isMacOS);
    expect(bold.displayLabel, contains(AppPlatform.isMacOS ? 'Cmd' : 'Ctrl'));
  });

  // Cmd+Tab is the macOS application switcher and never reaches an app, so
  // walking the notes is the one pair of defaults that stays on Control
  // wherever it runs.
  test('the walk between notes is Ctrl+Tab on every platform', () {
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);

    for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
      AppPlatform.debugTargetPlatformOverride = platform;
      final prefs = ShortcutPrefs(_MemoryStore())..load();

      final next = prefs.bindingFor(ShortcutAction.nextNote)!;
      expect(next.logicalKey, LogicalKeyboardKey.tab);
      expect(next.control, isTrue);
      expect(next.meta, isFalse);
      expect(next.shift, isFalse);
      expect(next.displayLabel, 'Ctrl + Tab');

      final previous = prefs.bindingFor(ShortcutAction.previousNote)!;
      expect(previous.logicalKey, LogicalKeyboardKey.tab);
      expect(previous.control, isTrue);
      expect(previous.shift, isTrue);
      expect(previous.displayLabel, 'Ctrl + Shift + Tab');
    }
  });

  test(
    'both panels toggle from keyboard shortcuts that survive layout changes',
    () {
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);

      for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
        AppPlatform.debugTargetPlatformOverride = platform;
        final useMeta = platform == TargetPlatform.macOS;
        final prefs = ShortcutPrefs(_MemoryStore())..load();

        final left = prefs.bindingFor(ShortcutAction.toggleSidebar)!;
        expect(left.logicalKey, LogicalKeyboardKey.keyS);
        expect(left.meta, useMeta);
        expect(left.control, !useMeta);
        expect(left.shift, isFalse);

        final right = prefs.bindingFor(ShortcutAction.toggleResults)!;
        expect(right.logicalKey, LogicalKeyboardKey.keyR);
        expect(right.meta, useMeta);
        expect(right.control, !useMeta);
        expect(right.shift, isFalse);
      }
    },
  );

  test('the old sidebar default moves to Cmd or Ctrl S', () {
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);

    for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
      AppPlatform.debugTargetPlatformOverride = platform;
      final useMeta = platform == TargetPlatform.macOS;
      final store = _MemoryStore();
      store.data['shortcuts.v1'] = {
        'toggleSidebar': ShortcutBinding(
          logicalKey: LogicalKeyboardKey.backslash,
          physicalKey: PhysicalKeyboardKey.backslash,
          meta: useMeta,
          control: !useMeta,
        ).toJson(),
      };

      final prefs = ShortcutPrefs(store)..load();
      final migrated = prefs.bindingFor(ShortcutAction.toggleSidebar)!;
      expect(migrated.logicalKey, LogicalKeyboardKey.keyS);
      expect(migrated.meta, useMeta);
      expect(migrated.control, !useMeta);
    }
  });

  test('a cleared shortcut does not come back at the next launch', () {
    final store = _MemoryStore();
    final prefs = ShortcutPrefs(store)..load();
    expect(prefs.bindingFor(ShortcutAction.toggleResults), isNotNull);

    prefs.clear(ShortcutAction.toggleResults);
    expect(prefs.bindingFor(ShortcutAction.toggleResults), isNull);
    // And it stops standing in the way of anything else claiming that chord.
    expect(
      prefs.conflictFor(
        ShortcutAction.formatBold,
        ShortcutPrefs.defaultFor(ShortcutAction.toggleResults),
      ),
      isNull,
    );

    // The whole reason "cleared" is written down rather than left as a gap:
    // a restart must not hand the default back.
    expect(
      (ShortcutPrefs(store)..load()).bindingFor(ShortcutAction.toggleResults),
      isNull,
    );
  });

  test('a shortcut the stored file predates still gets its default', () {
    // What an install written before a later version's shortcut existed looks
    // like: an entry for the actions of the day, and nothing for the rest.
    final store = _MemoryStore()
      ..put('shortcuts.v1', {
        ShortcutAction.newNote.name: ShortcutPrefs.defaultFor(
          ShortcutAction.newNote,
        ).toJson(),
      });

    final prefs = ShortcutPrefs(store)..load();

    expect(
      prefs.bindingFor(ShortcutAction.toggleResults),
      ShortcutPrefs.defaultFor(ShortcutAction.toggleResults),
    );
  });

  test('restoring defaults hands a cleared shortcut back', () {
    final prefs = ShortcutPrefs(_MemoryStore())..load();
    prefs.clear(ShortcutAction.formatBold);
    expect(prefs.bindingFor(ShortcutAction.formatBold), isNull);

    prefs.resetAll();

    expect(
      prefs.bindingFor(ShortcutAction.formatBold),
      ShortcutPrefs.defaultFor(ShortcutAction.formatBold),
    );
  });

  test('the results column remembers being folded away', () {
    final store = _MemoryStore();
    final prefs = LayoutPrefs(store)..load();
    expect(prefs.resultsVisible, isTrue);

    prefs.toggleResults();
    expect(prefs.resultsVisible, isFalse);

    expect((LayoutPrefs(store)..load()).resultsVisible, isFalse);
  });

  test('the pin is off for a new install and survives a restart', () {
    final store = _MemoryStore();
    final prefs = LayoutPrefs(store)..load();
    expect(prefs.alwaysOnTop, isFalse);

    prefs.toggleAlwaysOnTop();
    expect(prefs.alwaysOnTop, isTrue);

    // A window pinned for a task is still pinned tomorrow; the toolbar
    // button and its shortcut are how it gets undone.
    expect((LayoutPrefs(store)..load()).alwaysOnTop, isTrue);

    prefs.toggleAlwaysOnTop();
    expect((LayoutPrefs(store)..load()).alwaysOnTop, isFalse);
  });

  test('no two default shortcuts claim the same chord', () {
    // conflictFor refuses a rebind onto a chord already in use, so a default
    // that collided would be unreachable from the settings pane and silently
    // shadowed at the keyboard.
    for (final useMeta in [true, false]) {
      AppPlatform.debugTargetPlatformOverride = useMeta
          ? TargetPlatform.macOS
          : TargetPlatform.windows;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);

      final prefs = ShortcutPrefs(_MemoryStore())..load();
      final seen = <String, ShortcutAction>{};
      for (final action in ShortcutAction.values) {
        final label = prefs.bindingFor(action)!.displayLabel;
        expect(
          seen[label],
          isNull,
          reason: '$label is claimed by both ${seen[label]} and $action',
        );
        seen[label] = action;
      }
    }
  });

  test('a new install opens on a page, not on a list of nothing', () {
    final prefs = LayoutPrefs(_MemoryStore())..load();
    expect(prefs.sidebarVisible, isFalse);
    // And the paper-like face, not the mixed one.
    expect(prefs.writingFont, WritingFont.handwritten);
  });

  test('an opened sidebar is only open for the current session', () {
    final store = _MemoryStore();
    final prefs = LayoutPrefs(store)..load();
    prefs.toggleSidebar();
    expect(prefs.sidebarVisible, isTrue);
    expect((LayoutPrefs(store)..load()).sidebarVisible, isFalse);
  });
}
