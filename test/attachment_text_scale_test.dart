import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/calc/highlight.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/blob_store.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/ui/editor/file_chip.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/editor/note_image_layout.dart';
import 'package:kapy_notes/ui/editor/note_image_view.dart';
import 'package:kapy_notes/ui/editor/note_video_view.dart';
import 'package:kapy_notes/ui/editor/results_gutter.dart';
import 'package:kapy_notes/ui/editor/voice_chip.dart';
import 'package:material_ui/material_ui.dart';

import 'support/note_driver.dart';
import 'test_fonts.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'attachment-text-scale-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

const _p = NoteAttachmentRef.placeholder;

/// A note holding a sum and one of every attachment, each followed by a
/// line of words.
const _body =
    'Kinds\n12 + 30\n$_p\nafter\n$_p\nafter\n$_p\nafter\n$_p\nafter\n$_p\nafter';

void main() {
  late CalcEngine engine;
  late BlobStore store;
  late ShortcutPrefs shortcuts;

  setUpAll(() async {
    await loadTestFonts();
    engine = CalcEngine();
    store = BlobStore(
      directory: await Directory.systemTemp.createTemp('kapy-text-scale'),
    );
    shortcuts = ShortcutPrefs(_MemoryStore())..load();
  });
  tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

  final key = Uint8List(32);

  List<int> offsets(String body) => [
    for (var i = body.indexOf(_p); i >= 0; i = body.indexOf(_p, i + 1)) i,
  ];

  NoteImageRef image(int offset, {int width = 800, int height = 600}) =>
      NoteImageRef(
        offset: offset,
        hash: 'image-$offset',
        key: key,
        mime: 'image/png',
        width: width,
        height: height,
        bytes: 1000,
      );

  /// One of every attachment, at [at] in turn.
  List<NoteAttachmentRef> kinds(List<int> at) => [
    NoteVoiceRef(
      offset: at[0],
      hash: 'voice',
      key: key,
      bytes: 2048,
      durationMs: 123000,
    ),
    NoteFileRef(
      offset: at[1],
      hash: 'file',
      key: key,
      mime: 'application/pdf',
      bytes: 120000,
      name: 'Quarterly report.pdf',
    ),
    NoteUnknownRef(
      offset: at[2],
      hash: 'unknown',
      key: key,
      mime: 'application/octet-stream',
      bytes: 10,
      attachmentId: 'a',
      raw: const {'kind': 'sketch'},
    ),
    NoteVideoRef(
      offset: at[3],
      hash: 'video',
      key: key,
      mime: 'video/mp4',
      bytes: 1000,
      width: 1280,
      height: 720,
      durationMs: 65000,
    ),
    image(at[4]),
  ];

  /// [body] at [scale], on a phone or a desktop as [platform] says, holding
  /// [attachments], or one of every attachment.
  Future<void> pumpNote(
    WidgetTester tester,
    TargetPlatform platform,
    double scale, {
    String body = _body,
    List<NoteAttachmentRef>? attachments,
  }) async {
    AppPlatform.debugTargetPlatformOverride = platform;
    final width = platform == TargetPlatform.android ? 412.0 : 900.0;
    tester.view.physicalSize = Size(width * 2, 1600 * 2);
    tester.view.devicePixelRatio = 2;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.light(),
        home: Scaffold(
          body: NoteEditor(
            noteId: 'kinds',
            initialBody: body,
            initialAttachments: attachments ?? kinds(offsets(body)),
            images: store,
            engine: engine,
            highlighter: Highlighter(engine.registry),
            resultsVisible: true,
            writingFont: WritingFont.handwritten,
            shortcuts: shortcuts,
            voiceStateFor: (_) => VoiceChipState.transcribing,
            onOpenVoiceNote: (_) {},
            onDocumentChanged: (_, _, _, _) {},
            onSettingsPressed: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Words inside each kind of chip, and the chip they are in.
  final words = <String, Type>{
    '42': ResultChip,
    'Transcribing…': NoteVoiceChip,
    'Quarterly report.pdf': NoteFileChip,
    'Needs a newer Kapy Notes': NoteEditor,
    'Loading video…': NoteVideoView,
  };

  for (final platform in [TargetPlatform.android, TargetPlatform.macOS]) {
    final where = platform == TargetPlatform.android ? 'a phone' : 'a desktop';

    testWidgets('on $where, words in a chip grow once with the text', (
      tester,
    ) async {
      Map<String, double> heights() => {
        for (final MapEntry(key: text, value: kind) in words.entries)
          text: tester
              .getRect(
                find.descendant(
                  of: find.byType(kind),
                  matching: find.text(text),
                ),
              )
              .height,
      };
      await pumpNote(tester, platform, 1);
      final plain = heights();
      await pumpNote(tester, platform, 1.3);
      final large = heights();
      for (final text in words.keys) {
        expect(
          large[text]! / plain[text]!,
          moreOrLessEquals(1.3, epsilon: 0.05),
          reason: '"$text" at 1.3x text',
        );
      }
    });

    testWidgets('on $where, every tooltip on an attachment grows once with '
        'the text', (tester) async {
      Future<Map<String, double>> tips() async {
        final messages = {
          for (final tip in tester.widgetList<Tooltip>(
            find.descendant(
              of: find.byWidgetPredicate(
                (widget) =>
                    widget is NoteVoiceChip ||
                    widget is NoteFileChip ||
                    widget is NoteImageView ||
                    widget is NoteVideoView,
              ),
              matching: find.byType(Tooltip),
            ),
          ))
            tip.message!,
        };
        final heights = <String, double>{};
        for (final message in messages) {
          tester
              .state<TooltipState>(
                find
                    .byWidgetPredicate(
                      (widget) =>
                          widget is Tooltip && widget.message == message,
                    )
                    .first,
              )
              .ensureTooltipVisible();
          await tester.pumpAndSettle();
          heights[message] = tester.getRect(find.text(message)).height;
          Tooltip.dismissAllToolTips();
          await tester.pumpAndSettle();
        }
        return heights;
      }

      await pumpNote(tester, platform, 1);
      final plain = await tips();
      await pumpNote(tester, platform, 1.3);
      final large = await tips();
      expect(
        plain.keys,
        containsAll([
          'Open this recording',
          if (platform == TargetPlatform.macOS) 'Remove voice note',
          platform == TargetPlatform.android
              ? 'Save a copy of Quarterly report.pdf'
              : 'Open Quarterly report.pdf',
          'Remove file',
          'Remove image',
          'Remove video',
        ]),
      );
      expect(large.keys, unorderedEquals(plain.keys));
      for (final message in plain.keys) {
        expect(
          large[message]! / plain[message]!,
          moreOrLessEquals(1.3, epsilon: 0.05),
          reason: '"$message" at 1.3x text',
        );
      }
    });

    for (final scale in [1.0, 1.3]) {
      testWidgets('on $where at ${scale}x, the line under every attachment '
          'is clear of it, as far under a recording as under a file', (
        tester,
      ) async {
        await pumpNote(tester, platform, scale);
        final editable = tester.getRect(noteField);
        final kinds = [
          NoteVoiceChip,
          NoteFileChip,
          null,
          NoteVideoView,
          NoteImageView,
        ];
        final at = offsets(_body);
        final gaps = <Type?, double>{};
        for (var i = 0; i < kinds.length; i++) {
          final kind = kinds[i];
          final drawn = kind == null
              ? tester.getRect(find.text('Needs a newer Kapy Notes'))
              : tester.getRect(find.byType(kind));
          final next =
              NoteDriver(
                tester,
              ).caretRect(TextPosition(offset: at[i] + 2)).top +
              editable.top;
          expect(
            next,
            greaterThanOrEqualTo(drawn.bottom),
            reason: '${kind ?? 'the unknown attachment'} at ${scale}x text',
          );
          gaps[kind] = next - drawn.bottom;
        }
        expect(
          gaps[NoteVoiceChip],
          moreOrLessEquals(gaps[NoteFileChip]!, epsilon: 0.5),
        );
      });
    }

    testWidgets('on $where at large text, pictures side by side still meet '
        'edge to edge', (tester) async {
      const body = 'Two\n$_p$_p\nafter';
      final at = offsets(body);
      await pumpNote(
        tester,
        platform,
        1.3,
        body: body,
        attachments: [image(at[0]), image(at[1])],
      );
      final first = tester.getRect(find.byType(NoteImageView).first);
      final second = tester.getRect(find.byType(NoteImageView).last);
      expect(second.left, greaterThanOrEqualTo(first.right - 0.5));
      expect(second.top, moreOrLessEquals(first.top, epsilon: 0.5));
    });

    testWidgets('on $where, a tall picture keeps to the same height at large '
        'text', (tester) async {
      const body = 'Tall\n$_p\nafter';
      final at = offsets(body);
      final tall = [image(at[0], width: 600, height: 2400)];
      await pumpNote(tester, platform, 1, body: body, attachments: tall);
      final plain = tester.getRect(find.byType(NoteImageView)).height;
      await pumpNote(tester, platform, 1.3, body: body, attachments: tall);
      final large = tester.getRect(find.byType(NoteImageView)).height;
      expect(
        large,
        moreOrLessEquals(plain, epsilon: 0.3 * noteImageGap + 0.5),
        reason: 'only the gap around it grows',
      );
    });
  }
}
