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
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/calc/highlight.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/core/theme.dart';
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

  setUp(() {
    engine = CalcEngine();
    shortcuts = ShortcutPrefs(_MemoryStore())..load();
  });

  NoteField field(WidgetTester tester) =>
      tester.widget<NoteField>(find.byType(NoteField));

  Future<void> open(WidgetTester tester, String body) async {
    await tester.pumpWidget(const SizedBox.shrink());
    for (var i = 0; i < 150 && tester.view.viewInsets.bottom > 0; i++) {
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
        await tester.pump(const Duration(milliseconds: 500));
        return;
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

  testWidgets('Hide keyboard puts the keyboard and the bar away', (
    tester,
  ) async {
    await open(tester, 'Trip budget');
    await tap(tester, 'dismiss-keyboard');
    for (var i = 0; i < 40 && tester.view.viewInsets.bottom > 0; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.view.viewInsets.bottom, 0);
    expect(find.byKey(_bar), findsNothing);
    expect(field(tester).focusNode.hasFocus, isFalse);
    await screenshot('format-bar-keyboard-hidden', device: true);
  });
}
