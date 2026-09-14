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
  splitEditor,
  closePane,
  focusFirstPane,
  focusSecondPane,
  focusThirdPane,
  toggleSidebar,
  toggleHiddenFolder,
  toggleResults,
  toggleAlwaysOnTop,
  deleteNote,
  openSettings,
  insertImage,
  cycleTextStyle,
  formatBold,
  formatItalic,
  formatBullets,
  formatChecklist,
  recordVoiceNote,
}

extension ShortcutActionCopy on ShortcutAction {
  String get label => switch (this) {
    ShortcutAction.openApp => 'Open Kapy Notes',
    ShortcutAction.newNoteAnywhere => 'New note from anywhere',
    ShortcutAction.newNote => 'New note',
    ShortcutAction.findNotes => 'Global search',
    ShortcutAction.nextNote => 'Next note',
    ShortcutAction.previousNote => 'Previous note',
    ShortcutAction.splitEditor => 'Split view',
    ShortcutAction.closePane => 'Close pane',
    ShortcutAction.focusFirstPane => 'Focus pane 1',
    ShortcutAction.focusSecondPane => 'Focus pane 2',
    ShortcutAction.focusThirdPane => 'Focus pane 3',
    ShortcutAction.toggleSidebar => 'Toggle notes list',
    ShortcutAction.toggleHiddenFolder => 'Toggle Hidden Notes folder',
    ShortcutAction.toggleResults => 'Toggle results column',
    ShortcutAction.toggleAlwaysOnTop => 'Keep window on top',
    ShortcutAction.deleteNote => 'Archive current note',
    ShortcutAction.openSettings => 'Open settings',
    ShortcutAction.insertImage => 'Add an image',
    ShortcutAction.cycleTextStyle => 'Cycle text style',
    ShortcutAction.formatBold => 'Bold',
    ShortcutAction.formatItalic => 'Italic',
    ShortcutAction.formatBullets => 'Bulleted list',
    ShortcutAction.formatChecklist => 'Checklist',
    ShortcutAction.recordVoiceNote => 'Record a voice note',
  };

  String get description => switch (this) {
    ShortcutAction.openApp => 'Show or hide Kapy Notes from anywhere',
    ShortcutAction.newNoteAnywhere => 'Open a blank note from anywhere',
    ShortcutAction.newNote => 'Create and focus a blank note',
    ShortcutAction.findNotes =>
      'Search titles, nested content, and voice notes from the sidebar',
    ShortcutAction.nextNote => 'Open the next note down the list',
    ShortcutAction.previousNote => 'Open the note above it',
    ShortcutAction.splitEditor =>
      'Open a pane beside this note, for up to three side by side',
    ShortcutAction.closePane =>
      'Close the focused pane. Its note stays in the list',
    ShortcutAction.focusFirstPane => 'Move the keyboard to the leftmost pane',
    ShortcutAction.focusSecondPane => 'Move the keyboard to the second pane',
    ShortcutAction.focusThirdPane => 'Move the keyboard to the third pane',
    ShortcutAction.toggleSidebar => 'Show or hide the notes list on the left',
    ShortcutAction.toggleHiddenFolder =>
      'Reveal or hide Hidden Notes in the notes list',
    ShortcutAction.toggleResults =>
      'Show or hide the results column on the right',
    ShortcutAction.toggleAlwaysOnTop =>
      'Float the window over other apps, or let it fall behind again',
    ShortcutAction.deleteNote =>
      'Move the note you are editing to Archived Notes, or delete it for good '
          'if it is already there',
    ShortcutAction.openSettings => 'Open Settings',
    ShortcutAction.insertImage => 'Choose a picture or take a photo',
    ShortcutAction.cycleTextStyle =>
      'Switch between Text, Heading, and Subtitle',
    ShortcutAction.formatBold => 'Toggle bold on the selection or new text',
    ShortcutAction.formatItalic => 'Toggle italic on the selection or new text',
    ShortcutAction.formatBullets =>
      'Toggle a bulleted list on the current lines',
    ShortcutAction.formatChecklist => 'Toggle a checklist on the current lines',
    ShortcutAction.recordVoiceNote =>
      'Start recording into this note, or stop the one running',
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
    // A Mac has one key with delete written on it, and it is the one every
    // other keyboard calls Backspace. Naming it Backspace in a pane on a Mac
    // sends the reader looking for a key that is not there.
    if (logicalKey == LogicalKeyboardKey.backspace) {
      return AppPlatform.isMacOS ? 'Delete' : 'Backspace';
    }
    if (logicalKey == LogicalKeyboardKey.delete) {
      return AppPlatform.isMacOS ? 'Forward Delete' : 'Delete';
    }
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
  ShortcutPrefs(this._store) {
    // Settings can be painted while the on-disk store is still opening. The
    // shipped defaults are a safe answer for that brief window; [load] then
    // replaces them with the user's saved choices and notifies listeners.
    _bindings = {
      for (final action in ShortcutAction.values) action: defaultFor(action),
    };
  }

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
    // carrying a superseded binding never chose it — it was simply what
    // shipped — so move them across and write it back once. A binding they
    // actually picked, even an unlucky one, is theirs to keep.
    var migrated = false;
    for (final action in ShortcutAction.values) {
      final current = _bindings[action];
      if (current == null || !_supersededDefaults(action).contains(current)) {
        continue;
      }
      final replacement = defaultFor(action);
      // Unless something else already answers to the new default. An old
      // default that still works beats two actions on one chord — and a
      // system-wide one would swallow the other's key outright.
      if (conflictFor(action, replacement) != null) continue;
      _bindings[action] = replacement;
      migrated = true;
    }
    if (migrated) {
      _persist();
      return;
    }

    notifyListeners();
  }

  /// The defaults [action] has shipped with and since given up.
  ///
  /// A method rather than a constant because the answer depends on the host
  /// platform, which tests override.
  static List<ShortcutBinding> _supersededDefaults(ShortcutAction action) {
    final useMeta = AppPlatform.isMacOS;
    return switch (action) {
      ShortcutAction.openApp => [
        // 1.0.0: Cmd/Ctrl+Shift+Space, which is also 1Password's Quick
        // Access. Registration went to whichever app asked first, and it was
        // rarely this one.
        ShortcutBinding(
          logicalKey: LogicalKeyboardKey.space,
          physicalKey: PhysicalKeyboardKey.space,
          meta: useMeta,
          control: !useMeta,
          shift: true,
        ),
        // Then Option+Cmd+X and Ctrl+Shift+X, which other apps spend on
        // their own shortcuts. See [defaultFor].
        ShortcutBinding(
          logicalKey: LogicalKeyboardKey.keyX,
          physicalKey: PhysicalKeyboardKey.keyX,
          meta: useMeta,
          control: !useMeta,
          alt: useMeta,
          shift: !useMeta,
        ),
      ],
      // Option+Cmd+N and Ctrl+Shift+N: Finder's New Smart Folder, Explorer's
      // New folder, a browser's private window.
      ShortcutAction.newNoteAnywhere => [
        ShortcutBinding(
          logicalKey: LogicalKeyboardKey.keyN,
          physicalKey: PhysicalKeyboardKey.keyN,
          meta: useMeta,
          control: !useMeta,
          alt: useMeta,
          shift: !useMeta,
        ),
      ],
      // Cmd+Shift+Delete and Ctrl+Shift+Delete: a chord chosen to collide
      // with nothing, which is also a chord nobody reaches for. Anyone who
      // still carries it never picked it, so they are moved to the key their
      // machine already uses for this. See [defaultFor].
      ShortcutAction.deleteNote => [
        ShortcutBinding(
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
      ],
      // The first notes-list default. Cmd/Ctrl+S is a better fit because
      // every note saves itself and there is no manual Save to displace.
      ShortcutAction.toggleSidebar => [
        ShortcutBinding(
          logicalKey: LogicalKeyboardKey.backslash,
          physicalKey: PhysicalKeyboardKey.backslash,
          meta: useMeta,
          control: !useMeta,
        ),
      ],
      _ => const [],
    };
  }

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
      // Registered system-wide, so for as long as this app runs, every other
      // app loses the chord: its own shortcut there simply stops working. The
      // bar is therefore "nothing else uses it", not "nothing here does".
      //
      // macOS: Shift+Option+Cmd, which nothing we checked binds to X — no
      // system shortcut, no Services item, no app menu. Option+Cmd alone was
      // the previous pair and is crowded: +X is Xcode's Pull, and +N is
      // Finder's New Smart Folder, IntelliJ's Inline and Arc's Little Arc,
      // which Arc also holds system-wide. Control stays out because
      // Control+Option is VoiceOver's own modifier (VO-X opens its Activity
      // Chooser, VO-N its notifications), and without Cmd, Option and
      // Option+Shift type characters.
      //
      // Windows: Alt+Shift. Win chords are the OS's. Ctrl+Alt is what AltGr
      // sends on international layouts, so a global Ctrl+Alt+X would fire
      // whenever a Polish or German user typed a character in that layer.
      // Ctrl+Shift is where apps keep their own shortcuts: Ctrl+Shift+X was
      // VS Code's Extensions, Slack's strikethrough and Teams' compose box.
      // What claims Alt+Shift+X is narrow — Word's Mark Index Entry,
      // Photoshop's Exclusion blend mode, Eclipse's Run As.
      //
      // Untested: Left Alt+Shift on its own is Windows' switch-language chord,
      // and fires on release. Whether a letter RegisterHotKey swallows still
      // cancels it has not been tried on a machine with two input languages.
      //
      // X sits bottom-left, so the whole chord is one comfortable left hand.
      ShortcutAction.openApp => ShortcutBinding(
        logicalKey: LogicalKeyboardKey.keyX,
        physicalKey: PhysicalKeyboardKey.keyX,
        meta: useMeta,
        alt: true,
        shift: true,
      ),
      // The summon shortcut's sibling, and the second and last one the OS
      // hears. It carries the same modifiers so that learning one teaches the
      // other, over N because that is the letter every app already spends on
      // "new".
      //
      // Which is also why N is the contested letter. Shift+Option+Cmd+N takes
      // only menu items inside other apps — Photoshop's new layer without the
      // dialog, a tab in Mail's viewer window, Xcode's new playground. Alt+
      // Shift+N takes Word's Merge a Document, Photoshop's Normal blend mode
      // and Eclipse's New menu. The pair it replaced took far more: Finder's
      // New Smart Folder and Arc's Little Arc on the Mac, Explorer's New folder
      // and Chrome's and Edge's private windows on Windows.
      ShortcutAction.newNoteAnywhere => ShortcutBinding(
        logicalKey: LogicalKeyboardKey.keyN,
        physicalKey: PhysicalKeyboardKey.keyN,
        meta: useMeta,
        alt: true,
        shift: true,
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
      // The same split chord as VS Code. The notes-list toggle originally
      // occupied it, but that default migrated to S and left this free.
      ShortcutAction.splitEditor => ShortcutBinding(
        logicalKey: LogicalKeyboardKey.backslash,
        physicalKey: PhysicalKeyboardKey.backslash,
        meta: useMeta,
        control: !useMeta,
      ),
      // What closes a tab or a document everywhere. The macOS menu bar has no
      // Close item to take it first, and with a single pane nothing answers
      // it at all, so it can never close the window by surprise.
      ShortcutAction.closePane => ShortcutBinding(
        logicalKey: LogicalKeyboardKey.keyW,
        physicalKey: PhysicalKeyboardKey.keyW,
        meta: useMeta,
        control: !useMeta,
      ),
      // Numbered the way a browser numbers its tabs: by position, from the
      // left.
      ShortcutAction.focusFirstPane => ShortcutBinding(
        logicalKey: LogicalKeyboardKey.digit1,
        physicalKey: PhysicalKeyboardKey.digit1,
        meta: useMeta,
        control: !useMeta,
      ),
      ShortcutAction.focusSecondPane => ShortcutBinding(
        logicalKey: LogicalKeyboardKey.digit2,
        physicalKey: PhysicalKeyboardKey.digit2,
        meta: useMeta,
        control: !useMeta,
      ),
      ShortcutAction.focusThirdPane => ShortcutBinding(
        logicalKey: LogicalKeyboardKey.digit3,
        physicalKey: PhysicalKeyboardKey.digit3,
        meta: useMeta,
        control: !useMeta,
      ),
      ShortcutAction.toggleSidebar => ShortcutBinding(
        logicalKey: LogicalKeyboardKey.keyS,
        physicalKey: PhysicalKeyboardKey.keyS,
        meta: useMeta,
        control: !useMeta,
      ),
      ShortcutAction.toggleHiddenFolder => ShortcutBinding(
        logicalKey: LogicalKeyboardKey.keyH,
        physicalKey: PhysicalKeyboardKey.keyH,
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
      // What the machine itself uses to take a row out of a list: Cmd+Delete
      // in the Finder and in Apple's own Notes, Shift+Delete in Explorer.
      // Neither is free — the editor would otherwise read Cmd+Delete as
      // "delete to the start of the line" and Shift+Delete as Cut — and both
      // are given up deliberately. A note is the thing on screen; a line
      // start and a cut both have other keys, and no shortcut nobody can
      // guess is worth more than the one everybody already knows.
      ShortcutAction.deleteNote => ShortcutBinding(
        logicalKey: useMeta
            ? LogicalKeyboardKey.backspace
            : LogicalKeyboardKey.delete,
        physicalKey: useMeta
            ? PhysicalKeyboardKey.backspace
            : PhysicalKeyboardKey.delete,
        meta: useMeta,
        shift: !useMeta,
      ),
      ShortcutAction.openSettings => ShortcutBinding(
        logicalKey: LogicalKeyboardKey.comma,
        physicalKey: PhysicalKeyboardKey.comma,
        meta: useMeta,
        control: !useMeta,
      ),
      // Shift keeps this distinct from Italic while retaining the mnemonic.
      ShortcutAction.insertImage => ShortcutBinding(
        logicalKey: LogicalKeyboardKey.keyI,
        physicalKey: PhysicalKeyboardKey.keyI,
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
      // Shift is what keeps this off ⌘R, which browsers and half the desktop
      // world have trained people to read as "reload".
      ShortcutAction.recordVoiceNote => ShortcutBinding(
        logicalKey: LogicalKeyboardKey.keyR,
        physicalKey: PhysicalKeyboardKey.keyR,
        meta: useMeta,
        control: !useMeta,
        shift: true,
      ),
    };
  }
}
