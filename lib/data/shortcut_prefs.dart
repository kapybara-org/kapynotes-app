import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../core/platform.dart';
import 'local_store.dart';

enum ShortcutAction {
  openApp,
  newNoteAnywhere,
  newNote,
  findNotes,
  nextNote,
  previousNote,
  toggleSidebar,
  toggleResults,
  toggleAlwaysOnTop,
  deleteNote,
  cycleTextStyle,
  formatBold,
  formatItalic,
  formatBullets,
  formatChecklist,
}

extension ShortcutActionCopy on ShortcutAction {
  String get label => switch (this) {
    ShortcutAction.openApp => 'Open Kapy Notes',
    ShortcutAction.newNoteAnywhere => 'New note from anywhere',
    ShortcutAction.newNote => 'New note',
    ShortcutAction.findNotes => 'Search notes',
    ShortcutAction.nextNote => 'Next note',
    ShortcutAction.previousNote => 'Previous note',
    ShortcutAction.toggleSidebar => 'Toggle notes list',
    ShortcutAction.toggleResults => 'Toggle results column',
    ShortcutAction.toggleAlwaysOnTop => 'Keep window on top',
    ShortcutAction.deleteNote => 'Delete current note',
    ShortcutAction.cycleTextStyle => 'Cycle text style',
    ShortcutAction.formatBold => 'Bold',
    ShortcutAction.formatItalic => 'Italic',
    ShortcutAction.formatBullets => 'Bulleted list',
    ShortcutAction.formatChecklist => 'Checklist',
  };

  String get description => switch (this) {
    ShortcutAction.openApp => 'Show the app from anywhere, or hide it again',
    ShortcutAction.newNoteAnywhere =>
      'Come forward on a blank note, whatever you were in',
    ShortcutAction.newNote => 'Create and focus a blank note',
    ShortcutAction.findNotes => 'Open the sidebar and search',
    ShortcutAction.nextNote => 'Open the next note down the list',
    ShortcutAction.previousNote => 'Open the note above it',
    ShortcutAction.toggleSidebar => 'Show or hide the notes list on the left',
    ShortcutAction.toggleResults =>
      'Show or hide the results column on the right',
    ShortcutAction.toggleAlwaysOnTop =>
      'Float the window over other apps, or let it fall behind again',
    ShortcutAction.deleteNote => 'Remove the note you are editing',
    ShortcutAction.cycleTextStyle =>
      'Switch between Text, Heading, and Subtitle',
    ShortcutAction.formatBold => 'Toggle bold on the selection or new text',
    ShortcutAction.formatItalic => 'Toggle italic on the selection or new text',
    ShortcutAction.formatBullets =>
      'Toggle a bulleted list on the current lines',
    ShortcutAction.formatChecklist => 'Toggle a checklist on the current lines',
  };

  /// Registered with the operating system rather than the widget tree, so it
  /// answers while another app is in front — and can be refused outright if
  /// something else already holds the chord.
  bool get isGlobal => switch (this) {
    ShortcutAction.openApp || ShortcutAction.newNoteAnywhere => true,
    _ => false,
  };

  bool get isFormatting => switch (this) {
    ShortcutAction.cycleTextStyle ||
    ShortcutAction.formatBold ||
    ShortcutAction.formatItalic ||
    ShortcutAction.formatBullets ||
    ShortcutAction.formatChecklist => true,
    _ => false,
  };
}

@immutable
class ShortcutBinding {
  const ShortcutBinding({
    required this.logicalKey,
    required this.physicalKey,
    this.meta = false,
    this.control = false,
    this.alt = false,
    this.shift = false,
  });

  final LogicalKeyboardKey logicalKey;
  final PhysicalKeyboardKey physicalKey;
  final bool meta;
  final bool control;
  final bool alt;
  final bool shift;

  bool get hasModifier => meta || control || alt || shift;

  SingleActivator get activator => SingleActivator(
    logicalKey,
    meta: meta,
    control: control,
    alt: alt,
    shift: shift,
  );

  String get keyLabel {
    if (logicalKey == LogicalKeyboardKey.space) return 'Space';
    if (logicalKey == LogicalKeyboardKey.tab) return 'Tab';
    if (logicalKey == LogicalKeyboardKey.backspace) return 'Backspace';
    if (logicalKey == LogicalKeyboardKey.delete) return 'Delete';
    if (logicalKey == LogicalKeyboardKey.backslash) return r'\';
    final label = logicalKey.keyLabel.trim();
    return label.isEmpty
        ? (physicalKey.debugName ?? 'Key')
        : label.toUpperCase();
  }

  String get displayLabel {
    if (AppPlatform.isMacOS) {
      return [
        if (meta) 'Cmd',
        if (control) 'Ctrl',
        if (alt) 'Option',
        if (shift) 'Shift',
        keyLabel,
      ].join(' + ');
    }
    return [
      if (control) 'Ctrl',
      if (alt) 'Alt',
      if (shift) 'Shift',
      if (meta) 'Win',
      keyLabel,
    ].join(' + ');
  }

  Map<String, Object?> toJson() => {
    'logicalKey': logicalKey.keyId,
    'physicalKey': physicalKey.usbHidUsage,
    'meta': meta,
    'control': control,
    'alt': alt,
    'shift': shift,
  };

  static ShortcutBinding? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final logicalId = raw['logicalKey'];
    final physicalId = raw['physicalKey'];
    if (logicalId is! num || physicalId is! num) return null;
    final logical = LogicalKeyboardKey.findKeyByKeyId(logicalId.toInt());
    final physical = PhysicalKeyboardKey.findKeyByCode(physicalId.toInt());
    if (logical == null || physical == null) return null;
    return ShortcutBinding(
      logicalKey: logical,
      physicalKey: physical,
      meta: raw['meta'] == true,
      control: raw['control'] == true,
      alt: raw['alt'] == true,
      shift: raw['shift'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ShortcutBinding &&
      other.logicalKey == logicalKey &&
      other.physicalKey == physicalKey &&
      other.meta == meta &&
      other.control == control &&
      other.alt == alt &&
      other.shift == shift;

  @override
  int get hashCode =>
      Object.hash(logicalKey, physicalKey, meta, control, alt, shift);
}

class ShortcutPrefs extends ChangeNotifier {
  ShortcutPrefs(this._store);

  static const String _key = 'shortcuts.v1';

  /// What a deliberately cleared shortcut looks like on disk.
  ///
  /// A missing entry cannot mean this: an action added in a later version is
  /// missing from every file written before it existed, and those installs
  /// must get its default rather than nothing. So "the user removed this" is
  /// written down, in a word rather than as an absence.
  static const String _unbound = 'unbound';

  final LocalStore _store;

  /// Only the actions that have a key. An action missing from here is one the
  /// user cleared, which is why [bindingFor] can answer null.
  late Map<ShortcutAction, ShortcutBinding> _bindings;

  void load() {
    final raw = _store.data[_key];
    final saved = raw is Map ? raw : const <Object?, Object?>{};
    _bindings = {
      for (final action in ShortcutAction.values)
        if (saved[action.name] != _unbound)
          action:
              ShortcutBinding.fromJson(saved[action.name]) ??
              defaultFor(action),
    };

    // Changing the default alone would only reach new installs. Anyone still
    // carrying the superseded binding never chose it — it was simply what
    // shipped — so move them across and write it back once. A binding they
    // actually picked, even an unlucky one, is theirs to keep.
    if (_bindings[ShortcutAction.openApp] == _supersededOpenApp()) {
      _bindings[ShortcutAction.openApp] = defaultFor(ShortcutAction.openApp);
      _persist();
      return;
    }

    notifyListeners();
  }

  /// The 1.0.0 default for [ShortcutAction.openApp]: Cmd/Ctrl+Shift+Space,
  /// which is also 1Password's Quick Access. Registration went to whichever
  /// app asked first, and it was rarely this one.
  ///
  /// A method rather than a constant because the answer depends on the host
  /// platform, which tests override.
  static ShortcutBinding _supersededOpenApp() => ShortcutBinding(
    logicalKey: LogicalKeyboardKey.space,
    physicalKey: PhysicalKeyboardKey.space,
    meta: AppPlatform.isMacOS,
    control: !AppPlatform.isMacOS,
    shift: true,
  );

  /// The key [action] answers to, or null where the user has cleared it.
  ///
  /// Nullable on purpose: every caller has to decide what an action with no
  /// key does, and the compiler is a better reminder than a comment. Callers
  /// that only want to say the shortcut out loud drop the mention; callers
  /// that bind keys leave the entry out of the map entirely.
  ShortcutBinding? bindingFor(ShortcutAction action) => _bindings[action];

  ShortcutAction? conflictFor(
    ShortcutAction action,
    ShortcutBinding candidate,
  ) {
    for (final entry in _bindings.entries) {
      if (entry.key != action && entry.value == candidate) return entry.key;
    }
    return null;
  }

  void update(ShortcutAction action, ShortcutBinding binding) {
    if (_bindings[action] == binding) return;
    _bindings[action] = binding;
    _persist();
  }

  /// Leaves [action] with no key at all. The action stays reachable wherever
  /// it has a button; it simply stops answering the keyboard.
  void clear(ShortcutAction action) {
    if (_bindings.remove(action) == null) return;
    _persist();
  }

  void resetAll() {
    _bindings = {
      for (final action in ShortcutAction.values) action: defaultFor(action),
    };
    _persist();
  }

  void _persist() {
    _store.putNow(_key, {
      for (final action in ShortcutAction.values)
        action.name: _bindings[action]?.toJson() ?? _unbound,
    });
    notifyListeners();
  }

  static ShortcutBinding defaultFor(ShortcutAction action) {
    final useMeta = AppPlatform.isMacOS;
    return switch (action) {
      // The only shortcut registered system-wide, so it has to dodge every
      // other app rather than just this one. It used to be Cmd/Ctrl+Shift+
      // Space, which is 1Password's Quick Access default — whoever asked
      // first won, and it usually was not us.
      //
      // Option+Cmd+X is clear of the macOS bindings that neighbour it:
      // Option+Cmd+Space is Finder search, +D toggles the Dock, +T the
      // toolbar, +W closes all windows, +C/+V are copy and paste style,
      // +Esc is Force Quit.
      //
      // Windows deliberately differs. Ctrl+Alt is what AltGr sends on
      // international layouts, so a global Ctrl+Alt+X would fire whenever a
      // German or Nordic user typed a character in that layer. Ctrl+Shift+X
      // has no such double life.
      //
      // X sits bottom-left, so the whole chord is one comfortable left hand.
      ShortcutAction.openApp => ShortcutBinding(
        logicalKey: LogicalKeyboardKey.keyX,
        physicalKey: PhysicalKeyboardKey.keyX,
        meta: useMeta,
        control: !useMeta,
        alt: useMeta,
        shift: !useMeta,
      ),
      // The summon shortcut's sibling, and the second and last one the OS
      // hears. It carries the same modifiers so that learning one teaches the
      // other, over N because that is the letter every app already spends on
      // "new".
      //
      // Nothing in this range is unclaimed. Holding it system-wide takes
      // Option+Cmd+N from Finder's New Smart Folder, and Ctrl+Shift+N from
      // Explorer's New Folder and Chrome's private window — for as long as
      // this app is running, and only until Settings hands it back.
      ShortcutAction.newNoteAnywhere => ShortcutBinding(
        logicalKey: LogicalKeyboardKey.keyN,
        physicalKey: PhysicalKeyboardKey.keyN,
        meta: useMeta,
        control: !useMeta,
        alt: useMeta,
        shift: !useMeta,
      ),
      ShortcutAction.newNote => ShortcutBinding(
        logicalKey: LogicalKeyboardKey.keyN,
        physicalKey: PhysicalKeyboardKey.keyN,
        meta: useMeta,
        control: !useMeta,
      ),
      ShortcutAction.findNotes => ShortcutBinding(
        logicalKey: LogicalKeyboardKey.keyF,
        physicalKey: PhysicalKeyboardKey.keyF,
        meta: useMeta,
        control: !useMeta,
      ),
      // Control on both platforms, and the one pair of defaults that does not
      // follow [useMeta]. Cmd+Tab is the macOS application switcher: the window
      // server takes it before any app is told a key moved, so a Cmd default
      // here would simply never fire. Ctrl+Tab is free on both, and is
      // already what every tabbed app means by "the next one".
      ShortcutAction.nextNote => const ShortcutBinding(
        logicalKey: LogicalKeyboardKey.tab,
        physicalKey: PhysicalKeyboardKey.tab,
        control: true,
      ),
      ShortcutAction.previousNote => const ShortcutBinding(
        logicalKey: LogicalKeyboardKey.tab,
        physicalKey: PhysicalKeyboardKey.tab,
        control: true,
        shift: true,
      ),
      ShortcutAction.toggleSidebar => ShortcutBinding(
        logicalKey: LogicalKeyboardKey.backslash,
        physicalKey: PhysicalKeyboardKey.backslash,
        meta: useMeta,
        control: !useMeta,
      ),
      // R for results. The obvious pairing would be Shift plus the sidebar's
      // own backslash, but the logical key a shifted punctuation key reports
      // is the character it produces, and that is layout-dependent — on a US
      // keyboard Shift+\ arrives as `|`, so a default written as backslash
      // would match nothing. Letters carry their unshifted identity
      // everywhere, which is why every other modified default here is one.
      ShortcutAction.toggleResults => ShortcutBinding(
        logicalKey: LogicalKeyboardKey.keyR,
        physicalKey: PhysicalKeyboardKey.keyR,
        meta: useMeta,
        control: !useMeta,
      ),
      // T for top, one modifier along from the T that cycles text style.
      // Not P for pin: Cmd+Shift+P is the chord the settings pane's own test
      // rebinds onto, and a default that occupies it would be refused there
      // by [conflictFor] — see the defaults-do-not-collide test.
      ShortcutAction.toggleAlwaysOnTop => ShortcutBinding(
        logicalKey: LogicalKeyboardKey.keyT,
        physicalKey: PhysicalKeyboardKey.keyT,
        meta: useMeta,
        control: !useMeta,
        shift: true,
      ),
      ShortcutAction.deleteNote => ShortcutBinding(
        logicalKey: useMeta
            ? LogicalKeyboardKey.backspace
            : LogicalKeyboardKey.delete,
        physicalKey: useMeta
            ? PhysicalKeyboardKey.backspace
            : PhysicalKeyboardKey.delete,
        meta: useMeta,
        control: !useMeta,
        shift: true,
      ),
      ShortcutAction.cycleTextStyle => ShortcutBinding(
        logicalKey: LogicalKeyboardKey.keyT,
        physicalKey: PhysicalKeyboardKey.keyT,
        meta: useMeta,
        control: !useMeta,
      ),
      ShortcutAction.formatBold => ShortcutBinding(
        logicalKey: LogicalKeyboardKey.keyB,
        physicalKey: PhysicalKeyboardKey.keyB,
        meta: useMeta,
        control: !useMeta,
      ),
      ShortcutAction.formatItalic => ShortcutBinding(
        logicalKey: LogicalKeyboardKey.keyI,
        physicalKey: PhysicalKeyboardKey.keyI,
        meta: useMeta,
        control: !useMeta,
      ),
      ShortcutAction.formatBullets => ShortcutBinding(
        logicalKey: LogicalKeyboardKey.keyB,
        physicalKey: PhysicalKeyboardKey.keyB,
        meta: useMeta,
        control: !useMeta,
        shift: true,
      ),
      ShortcutAction.formatChecklist => ShortcutBinding(
        logicalKey: LogicalKeyboardKey.keyC,
        physicalKey: PhysicalKeyboardKey.keyC,
        meta: useMeta,
        control: !useMeta,
        shift: true,
      ),
    };
  }
}
