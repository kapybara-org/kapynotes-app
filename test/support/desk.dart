import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/calc/highlight.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/blob_store.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/data/tags.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/editor/slash_commands.dart';
import 'package:kapy_notes/ui/tag_ui.dart';
import 'package:material_ui/material_ui.dart';

import 'fake_mac_text_input.dart';
import 'note_driver.dart';

/// The desktop platforms, each with its own key mapping.
final desktopPlatforms = TargetPlatformVariant({
  TargetPlatform.macOS,
  TargetPlatform.windows,
});

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'editor-ux-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

/// Drives the desktop editor the way a person does: mouse presses that take
/// real time between down and up, drags, repeated clicks, key events with
/// their modifiers held, and text that arrives from the platform's input.
class Desk {
  Desk(this.tester)
    : note = NoteDriver(tester),
      input = FakeMacTextInput(tester);

  final WidgetTester tester;
  final NoteDriver note;
  final FakeMacTextInput input;
  late ShortcutPrefs shortcuts;

  /// The clipboard: its plain text and, for rich text, its HTML.
  Map<String, Object?> clipboard = {};

  /// The pictures and files the note holds, as the editor last reported them.
  List<NoteAttachmentRef> attachments = const [];

  bool get mac => defaultTargetPlatform == TargetPlatform.macOS;
  String get _platform => mac ? 'macos' : 'windows';
  String get text => note.controller.text;
  TextSelection get selection => note.controller.selection;

  NoteEditorState get editor =>
      tester.state<NoteEditorState>(find.byType(NoteEditor));

  Future<void> open(
    String body, {
    bool results = false,
    Size window = const Size(720, 640),
    BlobStore? images,
    List<NoteAttachmentRef> initialAttachments = const [],
    TagStore? tags,
    bool readOnly = false,
    Widget? below,
    Brightness brightness = Brightness.dark,
    DateTime Function()? now,
    ValueChanged<SlashCommandType>? onSlashCommandChosen,
  }) async {
    attachments = initialAttachments;
    AppPlatform.debugTargetPlatformOverride = defaultTargetPlatform;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    _mockClipboard();
    shortcuts = ShortcutPrefs(_MemoryStore())..load();
    final engine = CalcEngine();
    final editor = NoteEditor(
      noteId: 'ux',
      initialBody: body,
      initialAttachments: initialAttachments,
      images: images,
      imageAcquirer: (_) async => [],
      videoAcquirer: () async => [],
      fileAcquirer: () async => [],
      onSlashCommandChosen: onSlashCommandChosen,
      engine: engine,
      highlighter: Highlighter(engine.registry),
      resultsVisible: results,
      markdownEnabled: true,
      readOnly: readOnly,
      now: now,
      autofocus: true,
      onDocumentChanged: (_, _, refs, _) => attachments = refs,
      onSettingsPressed: () {},
      writingFont: WritingFont.handwritten,
      shortcuts: shortcuts,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: brightness == Brightness.dark
            ? KapyTheme.dark()
            : KapyTheme.light(),
        home: Scaffold(
          bottomNavigationBar: below,
          body: Padding(
            padding: const EdgeInsets.only(top: 80),
            child: tags == null
                ? editor
                : TagShelf(
                    store: tags,
                    listed: () => [
                      for (final tag in tags.tags) (tag: tag, count: 0),
                    ],
                    untagged: () => 0,
                    isShared: (_) => false,
                    onFilter: (_) {},
                    child: editor,
                  ),
          ),
        ),
      ),
    );
    await settle();
  }

  void _mockClipboard() {
    final messenger = tester.binding.defaultBinaryMessenger;
    const rich = MethodChannel('kapynotes/rich_clipboard');
    const pasteboard = MethodChannel('pasteboard');
    messenger
      ..setMockMethodCallHandler(SystemChannels.platform, (call) async {
        switch (call.method) {
          case 'Clipboard.setData':
            clipboard = {'text': (call.arguments as Map)['text']};
          case 'Clipboard.getData':
            final text = clipboard['text'];
            return text == null ? null : {'text': text};
          case 'Clipboard.hasStrings':
            return {'value': clipboard['text'] != null};
        }
        return null;
      })
      ..setMockMethodCallHandler(
        rich,
        (call) async => call.method == 'read' ? clipboard : null,
      )
      ..setMockMethodCallHandler(
        pasteboard,
        (call) async => call.method == 'files' ? const <String>[] : null,
      );
    addTearDown(() {
      for (final channel in [SystemChannels.platform, rich, pasteboard]) {
        messenger.setMockMethodCallHandler(channel, null);
      }
    });
  }

  Future<void> settle() async {
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  /// Just inside the character at [offset], on the screen.
  Offset at(int offset) {
    final caret = note.caretRect(TextPosition(offset: offset));
    return note.toGlobal(Offset(caret.left + 1, caret.center.dy));
  }

  /// Just inside [needle]'s character at [into].
  Offset on(String needle, [int into = 0]) => at(text.indexOf(needle) + into);

  Future<void> click(Offset where, {int times = 1, bool shift = false}) async {
    if (shift) await _down(LogicalKeyboardKey.shiftLeft);
    for (var i = 0; i < times; i++) {
      final gesture = await tester.startGesture(
        where,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 60));
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 60));
    }
    if (shift) await _up(LogicalKeyboardKey.shiftLeft);
    await settle();
  }

  Future<void> clickKey(String key) =>
      click(tester.getCenter(find.byKey(ValueKey(key))));

  Future<void> drag(Offset from, Offset to) async {
    final gesture = await tester.startGesture(
      from,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 60));
    for (var i = 1; i <= 10; i++) {
      await gesture.moveTo(Offset.lerp(from, to, i / 10)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await settle();
  }

  Future<void> _down(LogicalKeyboardKey key) =>
      tester.sendKeyDownEvent(key, platform: _platform);
  Future<void> _up(LogicalKeyboardKey key) =>
      tester.sendKeyUpEvent(key, platform: _platform);

  /// Presses [key] with the modifiers held. [primary] is ⌘ on a Mac and
  /// Ctrl on Windows. Answers whether the app handled the key.
  Future<bool> key(
    LogicalKeyboardKey key, {
    bool primary = false,
    bool control = false,
    bool alt = false,
    bool shift = false,
  }) async {
    final held = [
      if (primary)
        mac ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft,
      if (control) LogicalKeyboardKey.controlLeft,
      if (alt) LogicalKeyboardKey.altLeft,
      if (shift) LogicalKeyboardKey.shiftLeft,
    ];
    for (final modifier in held) {
      await _down(modifier);
    }
    final handled = await tester.sendKeyEvent(key, platform: _platform);
    for (final modifier in held.reversed) {
      await _up(modifier);
    }
    await tester.pump();
    return handled;
  }

  /// One step by a word: ⌥ on a Mac, Ctrl on Windows.
  Future<bool> wordKey(LogicalKeyboardKey key, {bool shift = false}) =>
      this.key(key, alt: mac, control: !mac, shift: shift);

  /// To the line's start or end: ⌘← and ⌘→ on a Mac, Home and End on
  /// Windows.
  Future<bool> lineKey({required bool end, bool shift = false}) => mac
      ? key(
          end ? LogicalKeyboardKey.arrowRight : LogicalKeyboardKey.arrowLeft,
          primary: true,
          shift: shift,
        )
      : key(
          end ? LogicalKeyboardKey.end : LogicalKeyboardKey.home,
          shift: shift,
        );

  Future<void> chord(ShortcutAction action) async {
    final binding = shortcuts.bindingFor(action)!;
    await key(
      binding.logicalKey,
      primary: mac ? binding.meta : binding.control,
      control: mac && binding.control,
      alt: binding.alt,
      shift: binding.shift,
    );
    await settle();
  }

  /// Typing, as the platform's input delivers it.
  Future<void> type(String characters) async {
    for (final character in characters.split('')) {
      await input.insertText(character);
      await tester.pump();
    }
    await settle();
  }

  /// Typing into a plain field, as a table cell or the tag picker is: the
  /// platform sends it the whole editing state rather than deltas.
  Future<void> typeInField(String characters) async {
    final state = tester.testTextInput.editingState!;
    var text = state['text'] as String;
    final base = state['selectionBase'] as int;
    final extent = state['selectionExtent'] as int;
    var caret = base < extent ? base : extent;
    text = text.replaceRange(caret, base < extent ? extent : base, '');
    for (final character in characters.split('')) {
      text = text.replaceRange(caret, caret, character);
      caret++;
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: caret),
        ),
      );
      await tester.pump();
    }
    await settle();
  }

  /// Return: the app sees the key first, and the platform's input inserts the
  /// line break when the app lets it through.
  Future<void> enter() async {
    if (!await key(LogicalKeyboardKey.enter)) await input.insertText('\n');
    await settle();
  }

  Future<void> undo() async {
    await key(LogicalKeyboardKey.keyZ, primary: true);
    await settle();
  }

  Future<void> redo() async {
    await key(LogicalKeyboardKey.keyZ, primary: true, shift: true);
    await settle();
  }

  Future<void> copy() async {
    await key(LogicalKeyboardKey.keyC, primary: true);
    await settle();
  }

  Future<void> cut() async {
    await key(LogicalKeyboardKey.keyX, primary: true);
    await settle();
  }

  /// ⌘V or Ctrl+V, with real time for the conversion the paste runs off
  /// the UI isolate.
  Future<void> paste() async {
    final primary = mac
        ? LogicalKeyboardKey.metaLeft
        : LogicalKeyboardKey.controlLeft;
    await tester.runAsync(() async {
      await _down(primary);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV, platform: _platform);
      await _up(primary);
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await settle();
  }

  void place(int offset) =>
      note.controller.selection = TextSelection.collapsed(offset: offset);
}
