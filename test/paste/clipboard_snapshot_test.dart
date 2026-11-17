import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/paste/clipboard_snapshot.dart';

/// Windows' "HTML Format" around [fragment], with byte offsets the way
/// Windows writes them and [before] ahead of the fragment inside the page.
String windowsHtml(String fragment, {String before = '', String? sourceUrl}) {
  final source = sourceUrl == null ? '' : 'SourceURL:$sourceUrl\r\n';
  String header(
    int startHtml,
    int endHtml,
    int startFragment,
    int endFragment,
  ) {
    String pad(int value) => value.toString().padLeft(10, '0');
    return 'Version:0.9\r\n'
        'StartHTML:${pad(startHtml)}\r\n'
        'EndHTML:${pad(endHtml)}\r\n'
        'StartFragment:${pad(startFragment)}\r\n'
        'EndFragment:${pad(endFragment)}\r\n'
        '$source';
  }

  final headerLength = utf8.encode(header(0, 0, 0, 0)).length;
  final prefix = '<html><body>$before<!--StartFragment-->';
  const suffix = '<!--EndFragment--></body></html>';
  final startFragment = headerLength + utf8.encode(prefix).length;
  final endFragment = startFragment + utf8.encode(fragment).length;
  final endHtml = endFragment + utf8.encode(suffix).length;
  return header(headerLength, endHtml, startFragment, endFragment) +
      prefix +
      fragment +
      suffix;
}

void main() {
  test('reads every key the native side sends', () {
    final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2]);
    final photo = Uint8List.fromList([1, 2, 3]);
    final snapshot = ClipboardSnapshot.fromChannel({
      'types': ['public.html', 'public.utf8-plain-text'],
      'text': 'line one\r\nline two',
      'html': '<p>Hello</p>',
      'sourceUrl': 'https://example.com/page',
      'rtfHtml': '<p>From RTF <img src="file:///photo%20one.png"></p>',
      'resources': [
        {'name': 'file:///photo%20one.png', 'mime': 'IMAGE/PNG', 'data': photo},
        {'name': 'https://example.com/a.css', 'data': photo},
      ],
      'vscode': '{"version":1,"mode":"dart"}',
      'kapy': '{"body":"Hello"}',
      'files': ['/Users/me/a.txt', 'C:\\Users\\me\\b.txt'],
      'image': png,
      'imageMime': 'image/png',
    });

    expect(snapshot.types, ['public.html', 'public.utf8-plain-text']);
    expect(snapshot.text, 'line one\r\nline two');
    expect(snapshot.html, '<p>Hello</p>');
    expect(snapshot.sourceUrl, 'https://example.com/page');
    expect(snapshot.rtfHtml, contains('file:///photo%20one.png'));
    expect(snapshot.resources.keys, [
      'file:///photo%20one.png',
      'https://example.com/a.css',
    ]);
    expect(snapshot.resources['file:///photo%20one.png']!.mime, 'image/png');
    expect(snapshot.resources['file:///photo%20one.png']!.bytes, photo);
    expect(
      snapshot.resources['https://example.com/a.css']!.mime,
      'application/octet-stream',
    );
    expect(snapshot.vscode, '{"version":1,"mode":"dart"}');
    expect(snapshot.vscodeMode, 'dart');
    expect(snapshot.kapy, '{"body":"Hello"}');
    expect(snapshot.files, ['/Users/me/a.txt', 'C:\\Users\\me\\b.txt']);
    expect(snapshot.image, png);
    expect(snapshot.imageMime, 'image/png');
  });

  test('ignores values of the wrong type and empty values', () {
    final snapshot = ClipboardSnapshot.fromChannel({
      'types': ['public.html', 3, null],
      'text': 42,
      'html': '',
      'sourceUrl': ['https://example.com'],
      'rtfHtml': Uint8List(3),
      'resources': [
        'not a map',
        {
          'name': 7,
          'data': Uint8List.fromList([1]),
        },
        {'name': 'empty', 'data': Uint8List(0)},
        {
          'name': 'list',
          'data': [1, 2, 3],
        },
      ],
      'vscode': {'mode': 'dart'},
      'kapy': '',
      'files': 'C:\\a.txt',
      'image': [1, 2, 3],
      'imageMime': 5,
    });

    expect(snapshot.types, ['public.html']);
    expect(snapshot.text, isNull);
    expect(snapshot.html, isNull);
    expect(snapshot.sourceUrl, isNull);
    expect(snapshot.rtfHtml, isNull);
    expect(snapshot.resources, isEmpty);
    expect(snapshot.vscode, isNull);
    expect(snapshot.vscodeMode, isNull);
    expect(snapshot.kapy, isNull);
    expect(snapshot.files, isEmpty);
    expect(snapshot.image, isNull);
    expect(snapshot.imageMime, isNull);
  });

  test('anything but a map is an empty snapshot', () {
    for (final raw in [null, 'html', 3, <Object?>[]]) {
      final snapshot = ClipboardSnapshot.fromChannel(raw);
      expect(snapshot.types, isEmpty);
      expect(snapshot.text, isNull);
      expect(snapshot.html, isNull);
    }
  });

  test('a VS Code copy of plain text has no language', () {
    expect(
      ClipboardSnapshot.fromChannel({
        'vscode': '{"mode":"plaintext"}',
      }).vscodeMode,
      isNull,
    );
    expect(
      ClipboardSnapshot.fromChannel({'vscode': 'not json'}).vscodeMode,
      isNull,
    );
  });

  group("Windows' HTML Format", () {
    test('cuts the page at its byte offsets past multi-byte text', () {
      final raw = windowsHtml(
        '<p>Café 日本 🙂</p>',
        before: '<p>Ünïcödé 😀 ahead</p>',
        sourceUrl: 'https://example.com/ü',
      );

      final snapshot = ClipboardSnapshot.fromChannel({'html': raw});

      expect(
        snapshot.html,
        '<html><body><p>Ünïcödé 😀 ahead</p><!--StartFragment-->'
        '<p>Café 日本 🙂</p><!--EndFragment--></body></html>',
      );
      expect(snapshot.sourceUrl, 'https://example.com/ü');
    });

    test('a source URL from the native side wins over the header', () {
      final snapshot = ClipboardSnapshot.fromChannel({
        'html': windowsHtml('<p>x</p>', sourceUrl: 'https://header.example'),
        'sourceUrl': 'https://native.example',
      });

      expect(snapshot.sourceUrl, 'https://native.example');
      expect(snapshot.html, contains('<p>x</p>'));
    });

    test('falls back to the markup when the offsets are missing', () {
      final snapshot = ClipboardSnapshot.fromChannel({
        'html':
            'Version:0.9\r\nSourceURL:https://example.com\r\n'
            '<html><body><p>No offsets</p></body></html>',
      });

      expect(snapshot.html, '<html><body><p>No offsets</p></body></html>');
      expect(snapshot.sourceUrl, 'https://example.com');
    });

    test('falls back to the markup when the offsets are invalid', () {
      const markup = '<html><body><p>Bad offsets</p></body></html>';
      for (final offsets in [
        ['abc', '0000000100'],
        ['0000000200', '0000000100'],
        ['0000000010', '9999999999'],
        ['-000000001', '0000000040'],
      ]) {
        final snapshot = ClipboardSnapshot.fromChannel({
          'html':
              'Version:0.9\r\n'
              'StartHTML:${offsets[0]}\r\n'
              'EndHTML:${offsets[1]}\r\n'
              '$markup',
        });

        expect(snapshot.html, markup, reason: '$offsets');
      }
    });

    test('a header with no markup is empty', () {
      final snapshot = ClipboardSnapshot.fromChannel({
        'html': 'Version:0.9\r\nStartHTML:0000000999\r\n',
      });

      expect(snapshot.html, isEmpty);
    });
  });
}
