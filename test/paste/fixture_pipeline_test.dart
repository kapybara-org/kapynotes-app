import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/paste/clipboard_snapshot.dart';
import 'package:kapy_notes/paste/paste_converter.dart';
import 'package:kapy_notes/paste/paste_tree.dart';

/// Every captured clipboard in test/fixtures/paste goes through the whole
/// paste pipeline, once for a markdown note and once for a plain one, and
/// comes out as the committed expected.md and expected.plain.txt beside it.
///
/// Run with PASTE_FIXTURES_UPDATE=1 to write those files afresh, then read
/// the diff: it is the review of what a paste from that source looks like.
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

  test(
    'the corpus is there',
    () => expect(fixtures, hasLength(greaterThan(50))),
  );

  for (final fixture in fixtures) {
    final name = fixture.path.substring('test/fixtures/paste/'.length);
    test(name, () {
      final snapshot = fixtureSnapshot(fixture);
      for (final markdown in [true, false]) {
        final described = describePaste(
          snapshot,
          convertPaste(snapshot, markdown: markdown),
        );
        final expected = File(
          '${fixture.path}/${markdown ? 'expected.md' : 'expected.plain.txt'}',
        );
        if (update) {
          expected.writeAsStringSync(described);
        } else {
          expect(
            described,
            expected.existsSync() ? expected.readAsStringSync() : '(missing)',
            reason: '${expected.path} differs; see the test for how to update',
          );
        }
      }
    });
  }
}

/// What the platform hands the app for [fixture]: the snapshot the macOS
/// reader recorded for it when one is committed, and otherwise the
/// representations themselves, as every platform passes them through.
ClipboardSnapshot fixtureSnapshot(Directory fixture) {
  final recorded = File('${fixture.path}/macos-snapshot.json');
  if (recorded.existsSync()) {
    return ClipboardSnapshot.fromChannel(
      _decodeBinary(jsonDecode(recorded.readAsStringSync())),
    );
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
  return ClipboardSnapshot.fromChannel({
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
  });
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
/// text with each picture shown where it sits, then the pictures and the
/// plain note's styles.
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
    for (final range in output.formats)
      '${range.format.name} ${range.start}..${range.end}: '
          '${jsonEncode(output.text.substring(range.start, range.end))}',
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
