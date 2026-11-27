// Does the phone formatting bar work with a real keyboard under it?
//
// The widget tests in test/phone_format_bar_test.dart fake the keyboard with a
// view inset, which proves the bar's logic but not the thing HIS-53 broke on
// desktop: a tap on a toolbar that takes focus from the note, or ends its
// selection, and so takes the keyboard down with it. This mounts the editor
// on a real device and taps each button with the system keyboard up.
//
//   flutter test integration_test/phone_format_bar_test.dart -d <ios sim id>
//   flutter test integration_test/phone_format_bar_test.dart -d <android id>
//
// On the iOS Simulator turn off I/O > Keyboard > Connect Hardware Keyboard, or
// the software keyboard never appears and the first case says so.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/calc/highlight.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/blob_store.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/editor/note_field.dart';
import 'package:material_ui/material_ui.dart';

import 'screenshot.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'phone-format-bar-integration.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

const _bar = ValueKey('phone-format-bar');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late CalcEngine engine;
  late ShortcutPrefs shortcuts;
  late BlobStore images;
  var recordings = 0;

  setUp(() {
    engine = CalcEngine();
    shortcuts = ShortcutPrefs(_MemoryStore())..load();
    final blobs = Directory.systemTemp.createTempSync('phone-format-bar');
    addTearDown(() => blobs.deleteSync(recursive: true));
    images = BlobStore(directory: blobs);
    recordings = 0;
  });

  NoteField field(WidgetTester tester) =>
      tester.widget<NoteField>(find.byType(NoteField));

  Future<void> open(
    WidgetTester tester,
    String body, {
    bool again = false,
  }) async {
    await tester.pumpWidget(const SizedBox.shrink());
    // Each case starts with the keyboard down, whatever the last one left.
    // A case that failed can leave a keyboard up with nothing focused under
    // it, which nothing else would ever take down, so ask for it to go, and
    // ask again each second in case a request lands mid-animation and is
    // lost.
    for (var i = 0; i < 150 && tester.view.viewInsets.bottom != 0; i++) {
      if (i % 10 == 0) {
        await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      }
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      tester.view.viewInsets.bottom,
      0,
      reason:
          'the last case\'s keyboard is still going down; mounting over it '
          'would have the editor let go when it finally does',
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Scaffold(
          body: NoteEditor(
            key: ValueKey(body),
            noteId: 'phone-bar',
            initialBody: body,
            engine: engine,
            highlighter: Highlighter(engine.registry),
            resultsVisible: true,
            markdownEnabled: true,
            // With somewhere to keep pictures and something to record with,
            // as in the app, so Attach and its sheet are as people see them.
            images: images,
            onRecordVoice: () => recordings++,
            // Opened the way the app reopens a note within the day: both
            // NoteEditor call sites in lib/ui/home_page.dart pass startAtEnd
            // and initialCaret along with autofocus and ensureKeyboardVisible.
            // startAtEnd is what starts the editor's keyboard retry, and the
            // first case needs it: just after launch, Android refuses the
            // first request while FlutterView is still becoming the served
            // input view. initialCaret keeps the body as written, where a
            // fresh open would add a blank line to start the day's writing.
            autofocus: true,
            startAtEnd: true,
            initialCaret: body.length,
            ensureKeyboardVisible: true,
            onDocumentChanged: (_, _, _, _) {},
            onSettingsPressed: () {},
            shortcuts: shortcuts,
            writingFont: WritingFont.handwritten,
          ),
        ),
      ),
    );
    for (var i = 0; i < 300; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (tester.view.viewInsets.bottom > 0 &&
          find.byKey(_bar).evaluate().isNotEmpty) {
        var inset = tester.view.viewInsets.bottom;
        for (var j = 0; j < 50; j++) {
          await tester.pump(const Duration(milliseconds: 100));
          if (tester.view.viewInsets.bottom != inset) {
            inset = tester.view.viewInsets.bottom;
            continue;
          }
          // Android's window manager can call off a keyboard it has just
          // shown and leave the inset at zero under a keyboard that stays up,
          // which takes the bar with it (KAP-324). Told apart from a keyboard
          // that really went by asking the device, that opens the note once
          // more, with a warning, rather than failing the case on what isn't
          // the bar's doing.
          for (var k = 0; k < 10; k++) {
            await tester.pump(const Duration(milliseconds: 100));
            if (tester.view.viewInsets.bottom > 0) continue;
            if (again || await deviceAction('keyboard-shown') != null) return;
            await deviceAction(
              'warn:phone_format_bar_test: the inset went to zero under a '
              'keyboard Android still shows (KAP-324), so the note opens again',
            );
            return open(tester, body, again: true);
          }
          return;
        }
        fail(
          'The software keyboard was still coming up after 5 s; the bar '
          'would be measured against a keyboard that has not settled.',
        );
      }
    }
    fail(
      'The software keyboard never came up. On the iOS Simulator, turn off '
      'I/O > Keyboard > Connect Hardware Keyboard.',
    );
  }

  Future<void> tap(WidgetTester tester, String key) async {
    final button = find.byKey(ValueKey(key));
    await tester.ensureVisible(button);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(button);
    await tester.pump(const Duration(milliseconds: 500));
  }

  void expectStillWriting(WidgetTester tester, {required String reason}) {
    expect(
      field(tester).focusNode.hasFocus,
      isTrue,
      reason: '$reason took focus from the note',
    );
    expect(
      tester.view.viewInsets.bottom,
      greaterThan(0),
      reason: '$reason put the keyboard away',
    );
    expect(find.byKey(_bar), findsOneWidget, reason: '$reason hid the bar');
  }

  testWidgets('the bar sits on the real keyboard', (tester) async {
    await open(tester, 'Trip budget');
    final bar = tester.getRect(find.byKey(_bar));
    final keyboardTop =
        tester.view.physicalSize.height / tester.view.devicePixelRatio -
        tester.view.viewInsets.bottom / tester.view.devicePixelRatio;
    expect(bar.height, 44);
    expect(bar.bottom, closeTo(keyboardTop, 1));
    await screenshot('format-bar-on-keyboard', device: true);
  });

  const cases = <(String, String, String)>[
    ('format-style', 'Trip budget', '# Trip budget'),
    ('format-bold', 'Trip budget', '**Trip** budget'),
    ('format-italic', 'Trip budget', '*Trip* budget'),
    ('format-checklist', 'Trip budget', '- [ ] Trip budget'),
    ('format-bullets', 'Trip budget', '- Trip budget'),
    ('format-numbered', 'Trip budget', '1. Trip budget'),
    ('format-quote', 'Trip budget', '> Trip budget'),
    ('format-code', 'Trip budget', '`Trip` budget'),
  ];
  for (final (key, body, expected) in cases) {
    testWidgets('button $key applies and leaves focus and the keyboard', (
      tester,
    ) async {
      await open(tester, body);
      field(tester).controller.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 4,
      );
      await tester.pump();
      await tap(tester, key);

      expect(field(tester).controller.text, expected, reason: key);
      expect(field(tester).controller.selection.isValid, isTrue, reason: key);
      expectStillWriting(tester, reason: key);
      await screenshot(
        'format-bar-${key.replaceFirst('format-', '')}',
        device: true,
      );
    });
  }

  testWidgets('Link asks for an address and wraps the selection', (
    tester,
  ) async {
    await open(tester, 'Trip budget');
    field(tester).controller.selection = const TextSelection(
      baseOffset: 0,
      extentOffset: 4,
    );
    await tester.pump();
    await tap(tester, 'format-link');
    await tester.enterText(
      find.byKey(const ValueKey('link-address')),
      'https://example.com',
    );
    await screenshot('format-bar-link-address', device: true);
    await tap(tester, 'link-add');

    expect(field(tester).controller.text, '[Trip](https://example.com) budget');
    expectStillWriting(tester, reason: 'link');
  });

  testWidgets('bold keeps the selection on the same words', (tester) async {
    await open(tester, 'Trip budget');
    field(tester).controller.selection = const TextSelection(
      baseOffset: 0,
      extentOffset: 4,
    );
    await tester.pump();
    await tap(tester, 'format-bold');

    final controller = field(tester).controller;
    final selected = controller.selection;
    expect(controller.text.substring(selected.start, selected.end), 'Trip');
    expectStillWriting(tester, reason: 'bold');
  });

  testWidgets('a list line offers Indent and Outdent', (tester) async {
    await open(tester, '- one\n- two');
    field(tester).controller.selection = const TextSelection.collapsed(
      offset: 11,
    );
    await tester.pump();
    await tap(tester, 'format-indent');
    expect(field(tester).controller.text, '- one\n  - two');
    expectStillWriting(tester, reason: 'indent');
    await screenshot('format-bar-indent', device: true);

    await tap(tester, 'format-outdent');
    expect(field(tester).controller.text, '- one\n- two');
    expectStillWriting(tester, reason: 'outdent');
  });

  testWidgets('Commands opens the menu and Divider goes into the note', (
    tester,
  ) async {
    await open(tester, 'Trip budget');
    field(tester).controller.selection = const TextSelection.collapsed(
      offset: 11,
    );
    await tester.pump();
    await tap(tester, 'format-commands');
    expect(find.byKey(const ValueKey('slash-command-menu')), findsOneWidget);
    await screenshot('format-bar-commands', device: true);

    final divider = find.byKey(const ValueKey('slash-command-divider'));
    await tester.ensureVisible(divider);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(divider);
    await tester.pump(const Duration(milliseconds: 500));

    expect(field(tester).controller.text, contains('---'));
    expect(find.byKey(const ValueKey('slash-command-menu')), findsNothing);
    expect(
      field(tester).focusNode.hasFocus,
      isTrue,
      reason: 'the note did not get focus back after the menu',
    );
  });

  testWidgets('Attach leads the bar and offers Photo, Video, Voice note and '
      'File', (tester) async {
    await open(tester, 'Trip budget');
    final bar = tester.getRect(find.byKey(_bar));
    final attach = tester.getRect(find.byKey(const ValueKey('format-attach')));
    await tap(tester, 'format-attach');
    // The keyboard goes down under the sheet; the shot waits for it to stop.
    var inset = -1.0;
    for (var i = 0; i < 30 && tester.view.viewInsets.bottom != inset; i++) {
      inset = tester.view.viewInsets.bottom;
      await tester.pump(const Duration(milliseconds: 200));
    }
    await screenshot('format-bar-attach-sheet', device: true);

    expect(attach.left, closeTo(bar.left, 1), reason: 'Attach is not first');
    final sheet = find.byType(BottomSheet);
    expect(
      [
        for (final tile in tester.widgetList<ListTile>(
          find.descendant(of: sheet, matching: find.byType(ListTile)),
        ))
          (tile.title! as Text).data,
      ],
      ['Photo', 'Video', 'Voice note', 'File'],
    );

    await tester.tap(find.byKey(const ValueKey('attach-voice')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(recordings, 1);
    expect(sheet, findsNothing);
  });

  testWidgets('Hide keyboard puts the keyboard and the bar away', (
    tester,
  ) async {
    await open(tester, 'Trip budget');
    await tap(tester, 'dismiss-keyboard');
    for (var i = 0; i < 150 && tester.view.viewInsets.bottom != 0; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      tester.view.viewInsets.bottom,
      0,
      reason: 'Hide keyboard left the keyboard up after 15 s',
    );
    expect(find.byKey(_bar), findsNothing);
    expect(field(tester).focusNode.hasFocus, isFalse);
    await screenshot('format-bar-keyboard-hidden', device: true);
  });
}
