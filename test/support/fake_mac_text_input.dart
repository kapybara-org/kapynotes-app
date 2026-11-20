// A stand-in for the macOS embedder's text input plugin, for widget tests.
//
// It keeps the plugin's model (FlutterTextInputPlugin.mm over TextInputModel)
// from the editing states the framework sends, and sends the deltas the plugin
// sends for the IME's setMarkedText, insertText and unmarkText. It also keeps
// the string and selection of the NSTextView the plugin is, which is what
// AppKit's accessibility reads and what macos/Runner/AccessibilityText.swift
// replaces when a dictation tool writes AXSelectedText or AXValue.
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeMacTextInput {
  FakeMacTextInput(this.tester);

  final WidgetTester tester;
  int _seen = 0;

  // TextInputModel.
  String text = '';
  int selectionBase = 0;
  int selectionExtent = 0;
  bool composingActive = false;
  int composingBase = 0;
  int composingExtent = 0;
  String affinity = 'TextAffinity.upstream';

  // The plugin's NSTextView.
  String viewText = '';
  TextRange viewSelection = const TextRange.collapsed(0);

  /// The text length of each editing state the framework sent.
  final List<int> editingStates = [];

  /// The deltas sent, as their JSON.
  final List<Map<String, Object?>> deltasSent = [];

  int get selectionStart => math.min(selectionBase, selectionExtent);
  int get selectionEnd => math.max(selectionBase, selectionExtent);
  bool get _composingCollapsed => composingBase == composingExtent;

  int get clientId {
    final call = tester.testTextInput.log.lastWhere(
      (call) => call.method == 'TextInput.setClient',
    );
    return (call.arguments as List<Object?>)[0]! as int;
  }

  /// Applies the calls the framework has made since the last sync.
  void sync() {
    final log = tester.testTextInput.log;
    for (; _seen < log.length; _seen++) {
      final call = log[_seen];
      switch (call.method) {
        case 'TextInput.setClient':
          text = '';
          selectionBase = selectionExtent = 0;
          composingActive = false;
          composingBase = composingExtent = 0;
          affinity = 'TextAffinity.upstream';
        case 'TextInput.setEditingState':
          _setEditingState(
            (call.arguments as Map<Object?, Object?>).cast<String, Object?>(),
          );
      }
    }
  }

  void _setEditingState(Map<String, Object?> state) {
    final newAffinity = state['selectionAffinity'] as String?;
    if (newAffinity != null) affinity = newAffinity;
    final base = state['selectionBase'] as int?;
    final extent = state['selectionExtent'] as int?;
    if (base != null && extent != null) {
      final none = base == -1 && extent == -1;
      selectionBase = none ? 0 : base;
      selectionExtent = none ? 0 : extent;
    }
    final cBase = state['composingBase'] as int?;
    final cExtent = state['composingExtent'] as int?;
    if (cBase != null && cExtent != null) {
      final none = cBase == -1 && cExtent == -1;
      composingBase = none ? 0 : cBase;
      composingExtent = none ? 0 : cExtent;
    }
    text = state['text']! as String;
    composingActive = !_composingCollapsed;
    editingStates.add(text.length);
    _updateTextAndSelection();
  }

  void _updateTextAndSelection() {
    viewText = text;
    viewSelection = TextRange(start: selectionStart, end: selectionEnd);
  }

  bool _setSelection(int base, int extent) {
    if (composingActive && base != extent) return false;
    final low = composingActive ? math.min(composingBase, composingExtent) : 0;
    final high = composingActive
        ? math.max(composingBase, composingExtent)
        : text.length;
    if (math.min(base, extent) < low || math.max(base, extent) > high) {
      return false;
    }
    selectionBase = base;
    selectionExtent = extent;
    return true;
  }

  void _deleteSelected() {
    if (selectionBase == selectionExtent) return;
    final start = selectionStart;
    text = text.replaceRange(start, selectionEnd, '');
    selectionBase = selectionExtent = start;
    if (composingActive) composingBase = composingExtent = start;
  }

  void _addText(String string) {
    _deleteSelected();
    if (composingActive) {
      final start = math.min(composingBase, composingExtent);
      text = text.replaceRange(
        start,
        math.max(composingBase, composingExtent),
        '',
      );
      selectionBase = selectionExtent = start;
      composingBase = start;
      composingExtent = start + string.length;
    }
    final position = selectionExtent;
    text = text.replaceRange(position, position, string);
    selectionBase = selectionExtent = position + string.length;
  }

  void _commitComposing() {
    if (_composingCollapsed) return;
    composingBase = composingExtent;
    selectionBase = selectionExtent = composingExtent;
  }

  void _endComposing() {
    composingActive = false;
    composingBase = composingExtent = 0;
  }

  /// setMarkedText:selectedRange:replacementRange:, with the selected range
  /// at [selectedLocation] (the marked text's end by default).
  Future<void> setMarkedText(
    String marked, {
    int? selectedLocation,
    int selectedLength = 0,
    TextRange? replacement,
  }) async {
    sync();
    final before = text;
    if (!composingActive) {
      composingActive = true;
      composingBase = composingExtent = selectionStart;
    }
    if (replacement != null &&
        replacement.start >= 0 &&
        replacement.end <= text.length) {
      composingBase = replacement.start;
      composingExtent = replacement.end;
      selectionBase = selectionExtent = replacement.start;
    }
    final composingBefore = TextRange(
      start: composingBase,
      end: composingExtent,
    );
    final selectionBefore = TextRange(start: selectionStart, end: selectionEnd);
    final collapsed = selectionBase == selectionExtent;
    if (!(marked.isEmpty && _composingCollapsed)) {
      final start = composingBase;
      final delete = _composingCollapsed
          ? selectionBefore
          : TextRange(start: composingBase, end: composingExtent);
      text = text.replaceRange(delete.start, delete.end, marked);
      composingExtent = start + marked.length;
      final location = selectedLocation ?? marked.length;
      selectionBase = start + location;
      selectionExtent = start + location + selectedLength;
    }
    final range = collapsed ? composingBefore : selectionBefore;
    await _send(before, marked, range.start, range.end);
  }

  /// insertText:replacementRange:, which commits a composition, types a
  /// character, and carries what AccessibilityText.swift re-expresses an
  /// accessibility write as. With [racing], the key is typed against what
  /// the plugin held before the framework's latest editing states reached it.
  Future<void> insertText(
    String string, {
    TextRange? replacement,
    bool racing = false,
  }) async {
    if (!racing) sync();
    if (replacement != null) {
      _setSelection(
        replacement.start.clamp(0, text.length),
        replacement.end.clamp(0, text.length),
      );
    } else if (composingActive &&
        !(composingBase == selectionBase &&
            composingExtent == selectionExtent)) {
      _setSelection(composingBase, composingBase);
    }
    final oldSelection = TextRange(start: selectionStart, end: selectionEnd);
    final composingBefore = TextRange(
      start: composingBase,
      end: composingExtent,
    );
    final before = text;
    _addText(string);
    TextRange replaced;
    if (composingActive) {
      replaced = composingBefore;
      _commitComposing();
      _endComposing();
    } else {
      replaced = replacement ?? oldSelection;
    }
    await _send(before, string, replaced.start, replaced.end);
  }

  Future<void> _send(
    String oldText,
    String deltaText,
    int start,
    int end,
  ) async {
    final delta = <String, Object?>{
      'oldText': oldText,
      'deltaText': deltaText,
      'deltaStart': start,
      'deltaEnd': end,
      'selectionBase': selectionBase,
      'selectionExtent': selectionExtent,
      'selectionAffinity': affinity,
      'selectionIsDirectional': false,
      'composingBase': composingActive ? composingBase : -1,
      'composingExtent': composingActive ? composingExtent : -1,
    };
    deltasSent.add(delta);
    _updateTextAndSelection();
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.textInput.name,
      SystemChannels.textInput.codec.encodeMethodCall(
        MethodCall('TextInputClient.updateEditingStateWithDeltas', <Object?>[
          clientId,
          <String, Object?>{
            'deltas': <Object?>[delta],
          },
        ]),
      ),
      (_) {},
    );
    await tester.pump();
    sync();
  }
}
