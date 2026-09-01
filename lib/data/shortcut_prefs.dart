import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../core/platform.dart';
import 'local_store.dart';

enum ShortcutAction { openApp, newNote, findNotes, toggleSidebar, deleteNote }

extension ShortcutActionCopy on ShortcutAction {
  String get label => switch (this) {
    ShortcutAction.openApp => 'Open Kapy Notes',
    ShortcutAction.newNote => 'New note',
    ShortcutAction.findNotes => 'Search notes',
    ShortcutAction.toggleSidebar => 'Toggle sidebar',
    ShortcutAction.deleteNote => 'Delete current note',
  };

  String get description => switch (this) {
    ShortcutAction.openApp => 'Show the app from anywhere',
    ShortcutAction.newNote => 'Create and focus a blank note',
    ShortcutAction.findNotes => 'Open the sidebar and search',
    ShortcutAction.toggleSidebar => 'Show or hide the notes list',
    ShortcutAction.deleteNote => 'Remove the note you are editing',
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

  final LocalStore _store;
  late Map<ShortcutAction, ShortcutBinding> _bindings;

  void load() {
    final raw = _store.data[_key];
    final saved = raw is Map ? raw : const <Object?, Object?>{};
    _bindings = {
      for (final action in ShortcutAction.values)
        action:
            ShortcutBinding.fromJson(saved[action.name]) ?? defaultFor(action),
    };
    notifyListeners();
  }

  ShortcutBinding bindingFor(ShortcutAction action) => _bindings[action]!;

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

  void resetAll() {
    _bindings = {
      for (final action in ShortcutAction.values) action: defaultFor(action),
    };
    _persist();
  }

  void _persist() {
    _store.put(_key, {
      for (final entry in _bindings.entries)
        entry.key.name: entry.value.toJson(),
    });
    notifyListeners();
  }

  static ShortcutBinding defaultFor(ShortcutAction action) {
    final useMeta = AppPlatform.isMacOS;
    return switch (action) {
      ShortcutAction.openApp => ShortcutBinding(
        logicalKey: LogicalKeyboardKey.space,
        physicalKey: PhysicalKeyboardKey.space,
        meta: useMeta,
        control: !useMeta,
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
      ShortcutAction.toggleSidebar => ShortcutBinding(
        logicalKey: LogicalKeyboardKey.backslash,
        physicalKey: PhysicalKeyboardKey.backslash,
        meta: useMeta,
        control: !useMeta,
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
    };
  }
}
