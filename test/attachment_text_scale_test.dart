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

  List<int> offsets() => [
    for (var i = _body.indexOf(_p); i >= 0; i = _body.indexOf(_p, i + 1)) i,
  ];

  /// The note at [scale], on a phone or a desktop as [platform] says.
  Future<void> pumpNote(
    WidgetTester tester,
    TargetPlatform platform,
    double scale,
  ) async {
    AppPlatform.debugTargetPlatformOverride = platform;
    final width = platform == TargetPlatform.android ? 412.0 : 900.0;
    tester.view.physicalSize = Size(width * 2, 1600 * 2);
    tester.view.devicePixelRatio = 2;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final at = offsets();
    final key = Uint8List(32);
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.light(),
        home: Scaffold(
          body: NoteEditor(
            noteId: 'kinds',
            initialBody: _body,
            initialAttachments: [
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
              NoteImageRef(
                offset: at[4],
                hash: 'image',
                key: key,
                mime: 'image/png',
                width: 800,
                height: 600,
                bytes: 1000,
              ),
            ],
            images: store,
            engine: engine,
            highlighter: Highlighter(engine.registry),
            resultsVisible: true,
            writingFont: WritingFont.handwritten,
            shortcuts: shortcuts,
            voiceStateFor: (_) => VoiceChipState.transcribing,
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

    testWidgets(
      'on $where at large text, the line under every attachment is clear of it',
      (tester) async {
        await pumpNote(tester, platform, 1.3);
        final editable = tester.getRect(noteField);
        final kinds = [
          NoteVoiceChip,
          NoteFileChip,
          null,
          NoteVideoView,
          NoteImageView,
        ];
        final at = offsets();
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
            reason: '${kind ?? 'the unknown attachment'} at 1.3x text',
          );
        }
      },
    );
  }
}
