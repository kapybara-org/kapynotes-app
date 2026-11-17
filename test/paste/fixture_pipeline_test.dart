import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/calc/highlight.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/blob_store.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/data/note_format.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/images/image_codec.dart';
import 'package:kapy_notes/paste/clipboard_snapshot.dart';
import 'package:kapy_notes/paste/paste_converter.dart';
import 'package:kapy_notes/paste/paste_tree.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:material_ui/material_ui.dart';
import 'package:kapy_notes/ui/editor/note_field.dart';

import '../support/note_driver.dart';

/// Every captured clipboard in test/fixtures/paste goes through the whole
/// paste pipeline a markdown note uses, and comes out as the committed
/// expected.md beside it. Then each is pasted into a note for real: a note
/// without markdown takes none of that pipeline and gets exactly what it
/// always has, and a markdown note gets the conversion.
///
/// Run with PASTE_FIXTURES_UPDATE=1 to write the expected.md files afresh,
/// then read the diff: it is the review of what a paste from that source
/// looks like.
void main() {
  final update = Platform.environment['PASTE_FIXTURES_UPDATE'] == '1';
  final fixtures =
      Directory('test/fixtures/paste')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.uri.pathSegments.last == 'fixture.json')
          .map((file) => file.parent)
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  String nameOf(Directory fixture) =>
      fixture.path.substring('test/fixtures/paste/'.length);

  test(
    'the corpus is there',
    () => expect(fixtures, hasLength(greaterThan(50))),
  );

  for (final fixture in fixtures) {
    test(nameOf(fixture), () {
      final snapshot = ClipboardSnapshot.fromChannel(
        fixtureChannelData(fixture),
      );
      final described = describePaste(snapshot, convertPaste(snapshot));
      final expected = File('${fixture.path}/expected.md');
      if (update) {
        expected.writeAsStringSync(described);
      } else {
        expect(
          described,
          expected.existsSync() ? expected.readAsStringSync() : '(missing)',
          reason: '${expected.path} differs; see the test for how to update',
        );
      }
    });
  }

  group('pasted into a note', () {
    late Directory temp;
    setUp(() => temp = Directory.systemTemp.createTempSync('kapy-paste'));
    tearDown(() => temp.deleteSync(recursive: true));

    for (final fixture in fixtures) {
      testWidgets('without markdown, exactly as before: ${nameOf(fixture)}', (
        tester,
      ) async {
        final data = {...fixtureChannelData(fixture)};
        // Files a paste reads from disk, made real.
        final copied = Directory('${temp.path}/copied')..createSync();
        final files = [
          for (final path in (data['files'] as List?) ?? const [])
            _realCopy(copied, path as String),
        ];
        data['files'] = files;

        final pasted = await _paste(
          tester,
          data,
          markdown: false,
          store: BlobStore(directory: temp),
        );

        // As ever: the clipboard's picture, or its picture files, ahead of
        // its words, and otherwise its words exactly as they came.
        if (data['image'] != null || files.any(_isPicture)) {
          expect(pasted.attachments.single, isA<NoteImageRef>());
          expect(pasted.note.replaceAll('\uFFFC', '').trim(), isEmpty);
        } else {
          expect(pasted.note, (data['text'] as String?) ?? '');
          expect(pasted.attachments, isEmpty);
        }
        expect(pasted.formats, isEmpty);
      });

      testWidgets('with markdown, converted: ${nameOf(fixture)}', (
        tester,
      ) async {
        final data = fixtureChannelData(fixture);
        final conversion = convertPaste(ClipboardSnapshot.fromChannel(data));

        final pasted = await _paste(tester, data, markdown: true);

        expect(
          pasted.note,
          conversion.kind == PasteKind.nothing
              ? ''
              : conversion.output.withoutPictures().text,
        );
      });
    }
  });
}

/// Pastes what [data] says the clipboard holds into an empty note, through
/// the editor's own Paste and the platform channels it reads, and returns
/// the note.
///
/// Without a [store] the note holds no pictures, which leaves the words of
/// a conversion to compare.
Future<
  ({
    String note,
    List<NoteAttachmentRef> attachments,
    List<NoteFormatRange> formats,
  })
>
_paste(
  WidgetTester tester,
  Map<Object?, Object?> data, {
  required bool markdown,
  BlobStore? store,
}) async {
  final text = data['text'] as String?;
  final messenger = tester.binding.defaultBinaryMessenger;
  const rich = MethodChannel('kapynotes/rich_clipboard');
  const pasteboard = MethodChannel('pasteboard');
  messenger
    ..setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => switch (call.method) {
        'Clipboard.getData' => text == null ? null : {'text': text},
        'Clipboard.hasStrings' => {'value': text != null},
        _ => null,
      },
    )
    ..setMockMethodCallHandler(
      rich,
      (call) async => call.method == 'read' ? data : null,
    )
    ..setMockMethodCallHandler(
      pasteboard,
      (call) async => switch (call.method) {
        'image' => data['image'],
        'files' => data['files'] ?? const <String>[],
        _ => null,
      },
    );
  addTearDown(() {
    for (final channel in [SystemChannels.platform, rich, pasteboard]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  var attachments = <NoteAttachmentRef>[];
  var formats = <NoteFormatRange>[];
  final editor = GlobalKey<NoteEditorState>();
  final engine = CalcEngine();
  await tester.pumpWidget(
    MaterialApp(
      theme: KapyTheme.dark(),
      home: Scaffold(
        body: NoteEditor(
          key: editor,
          noteId: 'paste',
          initialBody: '',
          images: store,
          markdownEnabled: markdown,
          autofocus: true,
          engine: engine,
          highlighter: Highlighter(engine.registry),
          resultsVisible: true,
          writingFont: WritingFont.handwritten,
          shortcuts: ShortcutPrefs(_MemoryStore())..load(),
          onDocumentChanged: (_, newFormats, refs, _) {
            formats = newFormats;
            attachments = refs;
          },
          onSettingsPressed: () {},
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.runAsync(
    () => editor.currentState!.handlePaste(SelectionChangedCause.keyboard),
  );
  await tester.pump();
  final note = tester
      .state<NoteFieldState>(noteField)
      .widget
      .controller
      .value
      .text;
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 3));
  return (note: note, attachments: attachments, formats: formats);
}

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'paste-fixtures.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

bool _isPicture(String path) =>
    supportedImageExtensions.contains(path.split('.').last.toLowerCase());

/// A file named like [path] in [directory], holding a picture when its name
/// says it is one.
String _realCopy(Directory directory, String path) {
  final file = File('${directory.path}/${path.split('/').last}');
  file.writeAsBytesSync(
    _isPicture(path)
        ? img.encodePng(img.Image(width: 8, height: 6))
        : utf8.encode('notes'),
  );
  return file.path;
}

/// What the platform hands the app for [fixture], as its native reader
/// sends it over: what the macOS reader recorded for it when that is
/// committed, and otherwise the representations themselves, as every
/// platform passes them through.
Map<Object?, Object?> fixtureChannelData(Directory fixture) {
  final recorded = File('${fixture.path}/macos-snapshot.json');
  if (recorded.existsSync()) {
    return _decodeBinary(jsonDecode(recorded.readAsStringSync()))! as Map;
  }
  final description =
      jsonDecode(File('${fixture.path}/fixture.json').readAsStringSync())
          as Map<String, Object?>;
  final items = (description['items'] as List).cast<Map<String, Object?>>();
  final byType = <String, File>{};
  final fileUrls = <String>[];
  for (final item in items) {
    for (final representation
        in (item['representations'] as List).cast<Map<String, Object?>>()) {
      final type = representation['type'] as String;
      final file = File('${fixture.path}/${representation['file']}');
      byType.putIfAbsent(type, () => file);
      if (type == 'public.file-url') fileUrls.add(file.readAsStringSync());
    }
  }
  String? string(List<String> types) {
    for (final type in types) {
      final file = byType[type];
      if (file != null) return file.readAsStringSync();
    }
    return null;
  }

  Uint8List? bytes(List<String> types) {
    for (final type in types) {
      final file = byType[type];
      if (file != null) return file.readAsBytesSync();
    }
    return null;
  }

  final image = bytes(['public.png', 'PNG', 'public.tiff']);
  return {
    'types': byType.keys.toList(),
    'text': string(['public.utf8-plain-text', 'CF_UNICODETEXT', 'text/plain']),
    'html': string(['public.html', 'HTML Format', 'text/html']),
    'sourceUrl': string(['org.chromium.source-url']),
    'vscode': string(['vscode-editor-data']),
    'files': [for (final url in fileUrls) Uri.parse(url.trim()).toFilePath()],
    'image': ?image,
    if (image != null)
      'imageMime':
          byType.containsKey('public.tiff') &&
              !byType.containsKey('public.png') &&
              !byType.containsKey('PNG')
          ? 'image/tiff'
          : 'image/png',
  };
}

Object? _decodeBinary(Object? value) => switch (value) {
  {'base64': final String encoded} when value.length == 1 => base64Decode(
    encoded,
  ),
  Map() => {
    for (final entry in value.entries) entry.key: _decodeBinary(entry.value),
  },
  List() => [for (final entry in value) _decodeBinary(entry)],
  _ => value,
};

/// A paste written out for reading: which representation it came from, the
/// text with each picture shown where it sits, then the pictures.
String describePaste(ClipboardSnapshot snapshot, PasteConversion conversion) {
  final output = conversion.output;
  final text = StringBuffer();
  var picture = 0;
  for (final rune in output.text.runes) {
    text.write(
      rune == 0xFFFC ? '⟦picture ${++picture}⟧' : String.fromCharCode(rune),
    );
  }
  final notes = [
    for (final (index, placed) in output.images.indexed)
      'picture ${index + 1} at ${placed.offset}: ${_describeImage(placed.image)}',
    if (snapshot.image != null)
      'clipboard bitmap: ${snapshot.imageMime} ${snapshot.image!.length} bytes',
    for (final file in snapshot.files)
      'clipboard file: ${file.split('/').last}',
  ];
  return [
    '<!-- read as: ${conversion.kind.name} -->',
    text.toString(),
    if (notes.isNotEmpty) '<!--\n${notes.join('\n')}\n-->',
    '',
  ].join('\n');
}

String _describeImage(PasteImage image) {
  final parts = [
    if (image.hasBytes)
      '${image.mime} ${image.bytes!.length} bytes'
    else
      image.src ?? '(nothing)',
    if (image.alt.isNotEmpty) 'alt ${jsonEncode(image.alt)}',
    if (image.width != null || image.height != null)
      '${image.width?.round()}x${image.height?.round()}',
    'width ${image.widthFactor.toStringAsFixed(2)}',
  ];
  return parts.join(', ');
}
