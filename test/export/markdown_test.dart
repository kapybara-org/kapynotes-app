import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/note_format.dart';
import 'package:kapy_notes/export/markdown.dart';

NoteFormatRange _range(int start, int end, NoteFormat format) =>
    NoteFormatRange(start: start, end: end, format: format);

void main() {
  group('rendering', () {
    test('wraps bold and italic in their markers', () {
      expect(
        renderNoteMarkdown('one two three', [
          _range(0, 3, NoteFormat.bold),
          _range(4, 7, NoteFormat.italic),
        ]),
        '**one** *two* three',
      );
    });

    test('splits overlapping ranges instead of crossing their markers', () {
      // The failure this guards against is `**a*b**c*`, where bold closes
      // from inside italic and no reader can agree what was meant. Crossing
      // ranges cannot nest, so the italic is split at the boundary instead.
      final markdown = renderNoteMarkdown('abcdefgh', [
        _range(0, 5, NoteFormat.bold),
        _range(3, 8, NoteFormat.italic),
      ]);
      final parsed = parseNoteMarkdown(markdown);
      expect(parsed.body, 'abcdefgh');
      expect(parsed.formats, contains(_range(0, 5, NoteFormat.bold)));
      expect(
        parsed.formats.where((f) => f.format == NoteFormat.italic),
        isNotEmpty,
      );
    });

    test('a formatted line escapes every marker character in its text', () {
      // Unguarded, the body's own `*` would sit against an emitted one and
      // the pair would read as a single marker.
      expect(
        renderNoteMarkdown('* b *', [_range(2, 5, NoteFormat.italic)]),
        r'\* *b \**',
      );
    });

    test('widens a heading to the whole line it touches', () {
      expect(
        renderNoteMarkdown('Weekly review\nbody', [
          _range(0, 6, NoteFormat.heading),
        ]),
        '# Weekly review\nbody',
      );
    });

    test('a subtitle is two hashes', () {
      expect(
        renderNoteMarkdown('Costs', [_range(0, 5, NoteFormat.subtitle)]),
        '## Costs',
      );
    });

    test('leaves an empty line inside a heading range without a bare hash', () {
      expect(
        renderNoteMarkdown('a\n\nb', [_range(0, 4, NoteFormat.heading)]),
        '# a\n\n# b',
      );
    });

    test('keeps markers off the whitespace at a range edge', () {
      expect(
        renderNoteMarkdown('a  bold  b', [_range(1, 9, NoteFormat.bold)]),
        'a  **bold**  b',
      );
    });

    test('leaves multiplication alone', () {
      // The whole app is lines like this. `daily \\* 7` would spoil the half
      // of the archive that is meant to be read by a person.
      expect(renderNoteMarkdown('daily * 7', const []), 'daily * 7');
      expect(renderNoteMarkdown('2 * 3 * 4', const []), '2 * 3 * 4');
    });

    test('escapes what would otherwise read back as formatting', () {
      expect(renderNoteMarkdown('a*b', const []), r'a\*b');
      expect(renderNoteMarkdown('*hi*', const []), r'\*hi\*');
      expect(
        renderNoteMarkdown('# not a heading', const []),
        r'\# not a heading',
      );
      expect(renderNoteMarkdown('use `code`', const []), r'use \`code\`');
      expect(renderNoteMarkdown('[link]', const []), r'\[link]');
      expect(renderNoteMarkdown(r'back\slash', const []), r'back\\slash');
    });

    test('leaves an intraword underscore readable', () {
      expect(
        renderNoteMarkdown('snake_case_name', const []),
        'snake_case_name',
      );
      expect(renderNoteMarkdown('_lead', const []), r'\_lead');
    });
  });

  group('parsing', () {
    test('reads back the markers it writes', () {
      final parsed = parseNoteMarkdown('**one** *two* three');
      expect(parsed.body, 'one two three');
      expect(parsed.formats, [
        _range(0, 3, NoteFormat.bold),
        _range(4, 7, NoteFormat.italic),
      ]);
    });

    test('a heading covers the line it prefixes', () {
      final parsed = parseNoteMarkdown('# Title\nbody');
      expect(parsed.body, 'Title\nbody');
      expect(parsed.formats, [_range(0, 5, NoteFormat.heading)]);
    });

    test('keeps every space after the hash but the first', () {
      expect(parseNoteMarkdown('#   Title').body, '  Title');
    });

    test('does not find emphasis in arithmetic', () {
      final parsed = parseNoteMarkdown('2 * 3 * 4');
      expect(parsed.body, '2 * 3 * 4');
      expect(parsed.formats, isEmpty);
    });

    test('leaves an unmatched marker as text', () {
      final parsed = parseNoteMarkdown('**loud');
      expect(parsed.body, '**loud');
      expect(parsed.formats, isEmpty);
    });

    test('underscores are emphasis too, but not inside a word', () {
      expect(parseNoteMarkdown('__loud__').formats, [
        _range(0, 4, NoteFormat.bold),
      ]);
      expect(parseNoteMarkdown('snake_case_name').formats, isEmpty);
    });

    test('an escape survives as the character it protected', () {
      expect(parseNoteMarkdown(r'a\*b').body, 'a*b');
      expect(parseNoteMarkdown(r'\# heading').body, '# heading');
    });

    test('a trailing backslash is text, not a dangling escape', () {
      expect(parseNoteMarkdown(r'end\').body, r'end\');
    });
  });

  group('round trip', () {
    // The plan calls this the test that actually protects the feature, and it
    // is: the conversion is where the bugs are, and a body that comes back
    // wrong is a note somebody has lost.
    test('a random body and ranges survive render then parse', () {
      final random = Random(20260905);
      const alphabet = 'ab cd*_#`[]\\\n*  _ 12.-\n';

      for (var attempt = 0; attempt < 800; attempt++) {
        final length = random.nextInt(40);
        final body = List.generate(
          length,
          (_) => alphabet[random.nextInt(alphabet.length)],
        ).join();

        final ranges = <NoteFormatRange>[];
        for (var i = 0; i < random.nextInt(4); i++) {
          final start = body.isEmpty ? 0 : random.nextInt(body.length);
          final end = body.isEmpty
              ? 0
              : start + 1 + random.nextInt(body.length - start);
          ranges.add(
            _range(
              start,
              end,
              NoteFormat.values[random.nextInt(NoteFormat.values.length)],
            ),
          );
        }
        final formats = normalizeNoteFormats(ranges, body.length);

        final markdown = renderNoteMarkdown(body, formats);
        final parsed = parseNoteMarkdown(markdown);
        expect(
          parsed.body,
          body,
          reason: 'body changed for ${jsonish(body)} via ${jsonish(markdown)}',
        );
        // And what came back renders to the same file, so a hand-edited note
        // does not churn the archive the next time it is exported.
        expect(
          renderNoteMarkdown(parsed.body, parsed.formats),
          markdown,
          reason: 'rendering moved for ${jsonish(body)}',
        );
      }
    });

    test('rendering is stable, so a second export writes the same file', () {
      final random = Random(7);
      const alphabet = 'ab *_#\n';
      for (var attempt = 0; attempt < 400; attempt++) {
        final body = List.generate(
          random.nextInt(24),
          (_) => alphabet[random.nextInt(alphabet.length)],
        ).join();
        final once = renderNoteMarkdown(body, const []);
        final parsed = parseNoteMarkdown(once);
        expect(renderNoteMarkdown(parsed.body, parsed.formats), once);
      }
    });
  });
}

/// Makes a failing body readable in the test output.
String jsonish(String value) =>
    value.replaceAll('\n', r'\n').replaceAll('\\', r'\\');
