import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/calc/highlight.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/core/toast.dart';
import 'package:kapy_notes/data/blob_store.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/ui/editor/editor_formatting.dart' show bulletPrefix;
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/editor/note_field.dart';
import 'package:material_ui/material_ui.dart';

import 'support/note_driver.dart';
import 'test_fonts.dart';

late CalcEngine engine;
late ShortcutPrefs shortcutPrefs;

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'phone-format-bar-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

const _bar = ValueKey('phone-format-bar');
const _otherField = ValueKey('other-field');
const _activeFill = Color(0xFF2E3828);

/// The editor as a phone mounts it, with a field of its own under it that
/// stands in for the title and the tag row, which take focus the note gives
/// up.
Widget _harness(
  String body, {
  bool markdown = true,
  bool readOnly = false,
  ValueChanged<bool>? onMarkdownEnabledChanged,
  BlobStore? images,
  VoidCallback? onRecordVoice,
  bool voiceActionBusy = false,
}) => MaterialApp(
  theme: KapyTheme.dark(),
  home: Scaffold(
    body: Column(
      children: [
        const TextField(key: _otherField),
        Expanded(
          child: NoteEditor(
            key: ValueKey(body),
            noteId: 'phone-bar',
            initialBody: body,
            engine: engine,
            highlighter: Highlighter(engine.registry),
            resultsVisible: true,
            markdownEnabled: markdown,
            readOnly: readOnly,
            onMarkdownEnabledChanged: onMarkdownEnabledChanged,
            images: images,
            onRecordVoice: onRecordVoice,
            voiceActionBusy: voiceActionBusy,
            autofocus: true,
            onDocumentChanged: (_, _, _, _) {},
            onSettingsPressed: () {},
            shortcuts: shortcutPrefs,
            writingFont: WritingFont.handwritten,
            now: () => DateTime(2026, 9, 1, 15, 38),
          ),
        ),
      ],
    ),
  ),
);

NoteField _field(WidgetTester tester) => tester.widget<NoteField>(noteField);

String _text(WidgetTester tester) => _field(tester).controller.text;

TextSelection _selection(WidgetTester tester) =>
    _field(tester).controller.selection;

/// Mounts [body] on [platform] with the keyboard up and [selection] in it.
Future<void> _open(
  WidgetTester tester,
  TargetPlatform platform,
  String body,
  TextSelection selection, {
  bool markdown = true,
  bool readOnly = false,
  bool keyboard = true,
  ValueChanged<bool>? onMarkdownEnabledChanged,
  BlobStore? images,
  VoidCallback? onRecordVoice,
  bool voiceActionBusy = false,
}) async {
  AppPlatform.debugTargetPlatformOverride = platform;
  addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
  tester.view.physicalSize = const Size(390, 760);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    _harness(
      body,
      markdown: markdown,
      readOnly: readOnly,
      onMarkdownEnabledChanged: onMarkdownEnabledChanged,
      images: images,
      onRecordVoice: onRecordVoice,
      voiceActionBusy: voiceActionBusy,
    ),
  );
  await tester.pumpAndSettle();
  if (keyboard) {
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
  }
  _field(tester).controller.selection = selection;
  await tester.pump();
}

/// What a tap must never undo: the note keeps focus, the keyboard stays up,
/// and the bar is still there.
void _expectStillWriting(WidgetTester tester) {
  expect(_field(tester).focusNode.hasFocus, isTrue);
  expect(tester.testTextInput.isVisible, isTrue);
  expect(find.byKey(_bar), findsOneWidget);
}

Future<void> _tap(WidgetTester tester, String key) async {
  final button = find.byKey(ValueKey(key));
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

/// The rows of the sheet the attach button opens, top to bottom.
List<String?> _attachChoices(WidgetTester tester) => [
  for (final tile in tester.widgetList<ListTile>(
    find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byType(ListTile),
    ),
  ))
    (tile.title! as Text).data,
];

bool _lit(WidgetTester tester, String key) {
  final tile = tester.widget<Container>(
    find
        .descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(Container),
        )
        .first,
  );
  return (tile.decoration! as BoxDecoration).color == _activeFill;
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() {
    engine = CalcEngine();
    shortcutPrefs = ShortcutPrefs(_MemoryStore())..load();
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    group('on ${platform.name}', () {
      TextSelection word(int start, int end) =>
          TextSelection(baseOffset: start, extentOffset: end);

      testWidgets('sits on the keyboard and goes with it', (tester) async {
        await _open(tester, platform, 'Trip budget', word(0, 4));
        final bar = tester.getRect(find.byKey(_bar));
        expect(bar.height, 44);
        expect(bar.bottom, closeTo(760 - 300, 0.01));
        expect(bar.width, 390);

        await tester.tap(find.byKey(const ValueKey('dismiss-keyboard')));
        await tester.pumpAndSettle();
        expect(_field(tester).focusNode.hasFocus, isFalse);
        tester.view.viewInsets = FakeViewPadding.zero;
        await tester.pumpAndSettle();
        expect(find.byKey(_bar), findsNothing);
      });

      testWidgets('is not there with the keyboard down', (tester) async {
        await _open(
          tester,
          platform,
          'Trip budget',
          word(0, 4),
          keyboard: false,
        );
        expect(_field(tester).focusNode.hasFocus, isTrue);
        expect(find.byKey(_bar), findsNothing);
      });

      testWidgets('is not there in a field that is not the note', (
        tester,
      ) async {
        await _open(tester, platform, 'Trip budget', word(0, 4));
        expect(find.byKey(_bar), findsOneWidget);

        await tester.tap(find.byKey(_otherField));
        await tester.pumpAndSettle();
        expect(_field(tester).focusNode.hasFocus, isFalse);
        expect(find.byKey(_bar), findsNothing);

        _field(tester).focusNode.requestFocus();
        await tester.pumpAndSettle();
        expect(find.byKey(_bar), findsOneWidget);
      });

      testWidgets('is not there in a note that cannot be changed', (
        tester,
      ) async {
        await _open(
          tester,
          platform,
          'Trip budget',
          word(0, 4),
          readOnly: true,
        );
        expect(find.byKey(_bar), findsNothing);
      });

      final cases = <(String, String, TextSelection, String, String)>[
        ('heading', 'format-style', word(0, 4), 'Trip budget', '# Trip budget'),
        ('bold', 'format-bold', word(0, 4), 'Trip budget', '**Trip** budget'),
        ('italic', 'format-italic', word(0, 4), 'Trip budget', '*Trip* budget'),
        (
          'checklist',
          'format-checklist',
          word(0, 4),
          'Trip budget',
          '- [ ] Trip budget',
        ),
        (
          'bullets',
          'format-bullets',
          word(0, 4),
          'Trip budget',
          '- Trip budget',
        ),
        (
          'numbered list',
          'format-numbered',
          word(0, 4),
          'Trip budget',
          '1. Trip budget',
        ),
        ('quote', 'format-quote', word(0, 4), 'Trip budget', '> Trip budget'),
        (
          'inline code',
          'format-code',
          word(0, 4),
          'Trip budget',
          '`Trip` budget',
        ),
        (
          'code block',
          'format-code',
          const TextSelection.collapsed(offset: 0),
          '',
          '```\n\n```',
        ),
      ];
      for (final (name, key, selection, body, expected) in cases) {
        testWidgets('$name applies and leaves the note focused', (
          tester,
        ) async {
          await _open(
            tester,
            platform,
            body.isEmpty ? '' : 'Trip budget',
            selection,
          );
          await _tap(tester, key);

          expect(_text(tester), expected);
          expect(_selection(tester).isValid, isTrue);
          _expectStillWriting(tester);
        });
      }

      testWidgets('bold keeps the selection on the same words', (tester) async {
        await _open(tester, platform, 'Trip budget', word(0, 4));
        await _tap(tester, 'format-bold');
        final selected = _selection(tester);
        expect(_text(tester).substring(selected.start, selected.end), 'Trip');
        expect(_lit(tester, 'format-bold'), isTrue);

        await _tap(tester, 'format-bold');
        expect(_text(tester), 'Trip budget');
        expect(_lit(tester, 'format-bold'), isFalse);
        _expectStillWriting(tester);
      });

      testWidgets('lists and quotes turn the line back into text', (
        tester,
      ) async {
        for (final (key, line) in const [
          ('format-bullets', '- Trip'),
          ('format-checklist', '- [ ] Trip'),
          ('format-numbered', '1. Trip'),
          ('format-quote', '> Trip'),
        ]) {
          await _open(
            tester,
            platform,
            line,
            const TextSelection.collapsed(offset: 6),
          );
          expect(_lit(tester, key), isTrue, reason: key);
          await _tap(tester, key);
          expect(_text(tester), 'Trip', reason: key);
          expect(_lit(tester, key), isFalse, reason: key);
          _expectStillWriting(tester);
        }
      });

      testWidgets('the heading button steps down to text', (tester) async {
        await _open(
          tester,
          platform,
          '# Trip',
          const TextSelection.collapsed(offset: 6),
        );
        expect(_lit(tester, 'format-style'), isTrue);
        await _tap(tester, 'format-style');
        await _tap(tester, 'format-style');
        await _tap(tester, 'format-style');
        expect(_text(tester), 'Trip');
        expect(_lit(tester, 'format-style'), isFalse);
      });

      testWidgets('a list line swaps Heading for Outdent and Indent', (
        tester,
      ) async {
        const body = '- one\n- two';
        await _open(
          tester,
          platform,
          body,
          const TextSelection.collapsed(offset: 11),
        );
        expect(find.byKey(const ValueKey('format-style')), findsNothing);
        expect(
          tester.getRect(find.byKey(const ValueKey('format-outdent'))).left,
          lessThan(
            tester.getRect(find.byKey(const ValueKey('format-indent'))).left,
          ),
        );
        expect(
          tester.getRect(find.byKey(const ValueKey('format-indent'))).left,
          lessThan(
            tester.getRect(find.byKey(const ValueKey('format-bold'))).left,
          ),
        );

        await _tap(tester, 'format-indent');
        expect(_text(tester), '- one\n  - two');
        _expectStillWriting(tester);
        await _tap(tester, 'format-outdent');
        expect(_text(tester), body);
        _expectStillWriting(tester);
      });

      testWidgets('a code block takes none of the formatting', (tester) async {
        const body = '```\ntrip\n```';
        await _open(
          tester,
          platform,
          body,
          const TextSelection.collapsed(offset: 6),
        );
        expect(_lit(tester, 'format-code'), isTrue);
        for (final key in [
          'format-style',
          'format-bold',
          'format-italic',
          'format-checklist',
          'format-bullets',
          'format-numbered',
          'format-quote',
          'format-link',
          'format-commands',
          'format-code',
        ]) {
          await _tap(tester, key);
          expect(
            find.byKey(const ValueKey('slash-command-menu')),
            findsNothing,
          );
          expect(_text(tester), body, reason: key);
          expect(_selection(tester), const TextSelection.collapsed(offset: 6));
          _expectStillWriting(tester);
        }
      });

      testWidgets('link asks for an address and wraps the selection', (
        tester,
      ) async {
        await _open(tester, platform, 'Trip budget', word(0, 4));
        await _tap(tester, 'format-link');
        await tester.enterText(
          find.byKey(const ValueKey('link-address')),
          'https://example.com',
        );
        await _tap(tester, 'link-add');

        expect(_text(tester), '[Trip](https://example.com) budget');
        expect(_field(tester).focusNode.hasFocus, isTrue);
        expect(find.byKey(_bar), findsOneWidget);
      });

      testWidgets('link at a caret writes the address as its own link', (
        tester,
      ) async {
        await _open(
          tester,
          platform,
          'Trip ',
          const TextSelection.collapsed(offset: 5),
        );
        await _tap(tester, 'format-link');
        await tester.enterText(
          find.byKey(const ValueKey('link-address')),
          'a.co',
        );
        await _tap(tester, 'link-add');
        expect(_text(tester), 'Trip [a.co](a.co)');
      });

      testWidgets('a link still goes in when the note changed elsewhere', (
        tester,
      ) async {
        await _open(tester, platform, 'Trip budget', word(0, 4));
        await _tap(tester, 'format-link');
        _field(tester).controller.text = 'Trip budget!';
        await tester.enterText(
          find.byKey(const ValueKey('link-address')),
          'a.co',
        );
        await _tap(tester, 'link-add');

        expect(_text(tester), '[Trip](a.co) budget!');
        _expectStillWriting(tester);
      });

      testWidgets('a link that cannot go in says so and keeps the keyboard', (
        tester,
      ) async {
        await _open(tester, platform, 'Trip budget', word(0, 4));
        await _tap(tester, 'format-link');
        _field(tester).controller.text = 'Flip budget';
        await tester.enterText(
          find.byKey(const ValueKey('link-address')),
          'a.co',
        );
        await _tap(tester, 'link-add');

        expect(_text(tester), 'Flip budget');
        expect(find.text('Link not added, the note changed'), findsOneWidget);
        _expectStillWriting(tester);
      });

      testWidgets('Commands opens the menu and a choice returns to the note', (
        tester,
      ) async {
        await _open(
          tester,
          platform,
          'Trip',
          const TextSelection.collapsed(offset: 4),
        );
        await _tap(tester, 'format-commands');
        expect(
          find.byKey(const ValueKey('slash-command-menu')),
          findsOneWidget,
        );
        expect(_text(tester), 'Trip');

        final divider = find.byKey(const ValueKey('slash-command-divider'));
        await tester.ensureVisible(divider);
        await tester.pumpAndSettle();
        await tester.tap(divider);
        await tester.pumpAndSettle();

        expect(_text(tester), contains('---'));
        expect(_field(tester).focusNode.hasFocus, isTrue);
        expect(find.byKey(const ValueKey('slash-command-menu')), findsNothing);
        expect(find.byKey(_bar), findsOneWidget);
      });

      for (final (name, address, written) in const [
        ('a space', 'a.co/my page', '[a.co/my page](a.co/my%20page)'),
        ('an unbalanced bracket', 'a.co/x)y', '[a.co/x)y](<a.co/x)y>)'),
      ]) {
        testWidgets('a link at a caret escapes an address with $name', (
          tester,
        ) async {
          await _open(
            tester,
            platform,
            'Trip ',
            const TextSelection.collapsed(offset: 5),
          );
          await _tap(tester, 'format-link');
          await tester.enterText(
            find.byKey(const ValueKey('link-address')),
            address,
          );
          await _tap(tester, 'link-add');
          expect(_text(tester), 'Trip $written');
        });
      }

      testWidgets('a link at a caret escapes brackets in its text', (
        tester,
      ) async {
        await _open(
          tester,
          platform,
          'Trip ',
          const TextSelection.collapsed(offset: 5),
        );
        await _tap(tester, 'format-link');
        await tester.enterText(
          find.byKey(const ValueKey('link-address')),
          r'a.co/x[1]\y',
        );
        await _tap(tester, 'link-add');
        expect(_text(tester), r'Trip [a.co/x\[1\]\\y](a.co/x[1]\y)');
      });

      testWidgets(
        'a link at a caret is dropped when the text before it moved',
        (tester) async {
          await _open(
            tester,
            platform,
            'Trip budget',
            const TextSelection.collapsed(offset: 5),
          );
          await _tap(tester, 'format-link');
          _field(tester).controller.text = 'Hey Trip budget';
          await tester.enterText(
            find.byKey(const ValueKey('link-address')),
            'a.co',
          );
          await _tap(tester, 'link-add');

          expect(_text(tester), 'Hey Trip budget');
          expect(find.text('Link not added, the note changed'), findsOneWidget);
          _expectStillWriting(tester);
        },
      );

      testWidgets('a link at a caret goes in when only far-off text changed', (
        tester,
      ) async {
        const body = 'Trip budget for the whole summer holiday';
        await _open(
          tester,
          platform,
          body,
          const TextSelection.collapsed(offset: 5),
        );
        await _tap(tester, 'format-link');
        _field(tester).controller.text = '$body!';
        await tester.enterText(
          find.byKey(const ValueKey('link-address')),
          'a.co',
        );
        await _tap(tester, 'link-add');

        expect(
          _text(tester),
          'Trip [a.co](a.co)budget for the whole summer holiday!',
        );
      });

      testWidgets('cancelling the link leaves the note and its selection', (
        tester,
      ) async {
        await _open(tester, platform, 'Trip budget', word(0, 4));
        await _tap(tester, 'format-link');
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(_text(tester), 'Trip budget');
        expect(_selection(tester), word(0, 4));
        expect(_field(tester).focusNode.hasFocus, isTrue);
      });

      testWidgets('a plain note asks before it writes markdown', (
        tester,
      ) async {
        var enabled = false;
        await _open(
          tester,
          platform,
          'Trip',
          const TextSelection.collapsed(offset: 4),
          markdown: false,
          onMarkdownEnabledChanged: (value) => enabled = value,
        );
        await _tap(tester, 'format-quote');
        expect(find.text('Turn on Markdown?'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(_text(tester), 'Trip');
        expect(enabled, isFalse);
      });

      testWidgets('a plain note keeps the formatting it already had', (
        tester,
      ) async {
        await _open(
          tester,
          platform,
          'Trip',
          const TextSelection.collapsed(offset: 4),
          markdown: false,
        );
        await _tap(tester, 'format-bullets');
        expect(_text(tester), '${bulletPrefix}Trip');
        _expectStillWriting(tester);
      });

      testWidgets('attach is the first button, ahead of the line tools', (
        tester,
      ) async {
        for (final (body, next) in const [
          ('Trip', 'format-style'),
          ('- Trip', 'format-outdent'),
        ]) {
          await _open(
            tester,
            platform,
            body,
            TextSelection.collapsed(offset: body.length),
          );
          final attach = tester.getRect(
            find.byKey(const ValueKey('format-attach')),
          );
          expect(attach.left, tester.getRect(find.byKey(_bar)).left);
          expect(
            attach.right,
            lessThanOrEqualTo(tester.getRect(find.byKey(ValueKey(next))).left),
            reason: body,
          );
        }
      });

      testWidgets('a screen reader hears attach as Attach', (tester) async {
        final semantics = tester.ensureSemantics();
        await _open(
          tester,
          platform,
          'Trip',
          const TextSelection.collapsed(offset: 4),
          images: BlobStore(),
        );
        expect(
          tester.getSemantics(find.byKey(const ValueKey('format-attach'))),
          isSemantics(label: 'Attach', isButton: true, isEnabled: true),
        );
        semantics.dispose();
      });

      testWidgets('attach offers Photo, Video, Voice note and File, and Voice '
          'note starts one', (tester) async {
        var recordings = 0;
        await _open(
          tester,
          platform,
          'Trip',
          const TextSelection.collapsed(offset: 4),
          images: BlobStore(),
          onRecordVoice: () => recordings++,
        );
        await _tap(tester, 'format-attach');
        expect(_attachChoices(tester), [
          'Photo',
          'Video',
          'Voice note',
          'File',
        ]);

        await tester.tap(find.byKey(const ValueKey('attach-voice')));
        await tester.pumpAndSettle();
        expect(recordings, 1);
        expect(find.byType(BottomSheet), findsNothing);
        expect(_text(tester), 'Trip');
      });

      for (final (name, onRecordVoice, busy) in <(String, VoidCallback?, bool)>[
        ('with nothing to record with', null, false),
        ('while a recording starts or stops', () {}, true),
      ]) {
        testWidgets('attach leaves out Voice note $name', (tester) async {
          await _open(
            tester,
            platform,
            'Trip',
            const TextSelection.collapsed(offset: 4),
            images: BlobStore(),
            onRecordVoice: onRecordVoice,
            voiceActionBusy: busy,
          );
          await _tap(tester, 'format-attach');
          expect(_attachChoices(tester), ['Photo', 'Video', 'File']);
        });
      }

      testWidgets('Code, lit past the end of the row, scrolls into view', (
        tester,
      ) async {
        await _open(
          tester,
          platform,
          'Trip\n```\ntrip\n```',
          const TextSelection.collapsed(offset: 0),
        );
        final row = tester.getRect(
          find.byKey(const ValueKey('phone-format-scroll')),
        );
        final code = find.byKey(const ValueKey('format-code'));
        expect(tester.getRect(code).left, greaterThan(row.right));

        _field(tester).controller.selection = const TextSelection.collapsed(
          offset: 11,
        );
        await tester.pumpAndSettle();
        expect(_lit(tester, 'format-code'), isTrue);
        expect(tester.getRect(code).left, greaterThanOrEqualTo(row.left));
        expect(tester.getRect(code).right, lessThanOrEqualTo(row.right + 0.01));
      });

      testWidgets('the attach button is dimmed without a place to keep one', (
        tester,
      ) async {
        await _open(
          tester,
          platform,
          'Trip',
          const TextSelection.collapsed(offset: 4),
        );
        await _tap(tester, 'format-attach');
        expect(find.byKey(const ValueKey('attach-photo')), findsNothing);
        _expectStillWriting(tester);
      });
    });
  }
  group('a notice', () {
    const card = ValueKey('toast-surface');

    testWidgets('sits above the format bar at the same width, not over it', (
      tester,
    ) async {
      await _open(
        tester,
        TargetPlatform.iOS,
        'Trip budget',
        const TextSelection.collapsed(offset: 0),
      );
      final bar = tester.getRect(find.byKey(_bar));
      Toast.show(tester.element(find.byKey(_bar)), 'Copied');
      await tester.pumpAndSettle();

      expect(tester.getRect(find.byKey(card)).bottom, bar.top - 16);
      expect(tester.getSize(find.byKey(card)).width, 390 - 32);
    });

    testWidgets('sits on the keyboard where there is no format bar', (
      tester,
    ) async {
      await _open(
        tester,
        TargetPlatform.android,
        'Trip budget',
        const TextSelection.collapsed(offset: 0),
      );
      await tester.tap(find.byKey(_otherField));
      await tester.pumpAndSettle();
      expect(find.byKey(_bar), findsNothing);
      Toast.show(tester.element(find.byKey(_otherField)), 'Copied');
      await tester.pumpAndSettle();

      expect(tester.getRect(find.byKey(card)).bottom, 760 - 300 - 16);
      expect(tester.getSize(find.byKey(card)).width, 390 - 32);
    });

    testWidgets('one already showing steps up when the format bar comes in '
        'under it, and down when it goes', (tester) async {
      await _open(
        tester,
        TargetPlatform.iOS,
        'Trip budget',
        const TextSelection.collapsed(offset: 0),
      );
      await tester.tap(find.byKey(_otherField));
      await tester.pumpAndSettle();
      expect(find.byKey(_bar), findsNothing);
      Toast.show(tester.element(find.byKey(_otherField)), 'Copied');
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byKey(card)).bottom, 760 - 300 - 16);

      _field(tester).focusNode.requestFocus();
      await tester.pumpAndSettle();
      final bar = tester.getRect(find.byKey(_bar));
      expect(tester.getRect(find.byKey(card)).bottom, bar.top - 16);

      await tester.tap(find.byKey(_otherField));
      await tester.pumpAndSettle();
      expect(find.byKey(_bar), findsNothing);
      expect(tester.getRect(find.byKey(card)).bottom, 760 - 300 - 16);
    });

    testWidgets('one already showing keeps above the format bar as the '
        'keyboard grows under it', (tester) async {
      await _open(
        tester,
        TargetPlatform.iOS,
        'Trip budget',
        const TextSelection.collapsed(offset: 0),
      );
      Toast.show(tester.element(find.byKey(_bar)), 'Copied');
      await tester.pumpAndSettle();

      tester.view.viewInsets = const FakeViewPadding(bottom: 340);
      await tester.pumpAndSettle();
      final bar = tester.getRect(find.byKey(_bar));
      expect(bar.bottom, closeTo(760 - 340, 0.01));
      expect(tester.getRect(find.byKey(card)).bottom, bar.top - 16);
    });

    testWidgets('one already showing steps down with the keyboard, the note '
        'still focused', (tester) async {
      await _open(
        tester,
        TargetPlatform.android,
        'Trip budget',
        const TextSelection.collapsed(offset: 0),
      );
      Toast.show(tester.element(find.byKey(_bar)), 'Copied');
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(card)).bottom,
        tester.getRect(find.byKey(_bar)).top - 16,
      );

      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pumpAndSettle();
      expect(_field(tester).focusNode.hasFocus, isTrue);
      expect(find.byKey(_bar), findsNothing);
      expect(tester.getRect(find.byKey(card)).bottom, 760 - 16);
    });

    testWidgets('on a desktop, there is no format bar and the notice stays '
        'at the foot, a pill', (tester) async {
      await _open(
        tester,
        TargetPlatform.macOS,
        'Trip budget',
        const TextSelection.collapsed(offset: 0),
        keyboard: false,
      );
      expect(find.byKey(_bar), findsNothing);
      Toast.show(tester.element(find.byKey(_otherField)), 'Copied');
      await tester.pumpAndSettle();

      expect(tester.getRect(find.byKey(card)).bottom, 760 - 24);
      expect(
        (tester.widget<Container>(find.byKey(card)).decoration!
                as BoxDecoration)
            .borderRadius,
        BorderRadius.circular(999),
      );
    });
  });
}
