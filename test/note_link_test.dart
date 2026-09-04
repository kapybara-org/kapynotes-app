import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/note_link.dart';

void main() {
  test('finds pasted web links and keeps their exact source text', () {
    const source =
        'Docs: https://example.com/a?q=1, www.kapy.app/help and '
        'kapy.app?from=note.';

    expect(findNoteLinks(source), [
      NoteLink(
        start: source.indexOf('https://'),
        end: source.indexOf('https://') + 'https://example.com/a?q=1'.length,
        text: 'https://example.com/a?q=1',
        uri: Uri.parse('https://example.com/a?q=1'),
      ),
      NoteLink(
        start: source.indexOf('www.'),
        end: source.indexOf('www.') + 'www.kapy.app/help'.length,
        text: 'www.kapy.app/help',
        uri: Uri.parse('https://www.kapy.app/help'),
      ),
      NoteLink(
        start: source.lastIndexOf('kapy.app'),
        end: source.lastIndexOf('kapy.app') + 'kapy.app?from=note'.length,
        text: 'kapy.app?from=note',
        uri: Uri.parse('https://kapy.app?from=note'),
      ),
    ]);
  });

  test('keeps balanced URL punctuation and trims sentence punctuation', () {
    const source =
        'See (https://example.com/topics_(new)), then https://example.com/x...';
    final links = findNoteLinks(source);

    expect(links.map((link) => link.text), [
      'https://example.com/topics_(new)',
      'https://example.com/x',
    ]);
  });

  test(
    'does not turn email addresses or dotted identifiers into partial links',
    () {
      expect(findNoteLinks('Email hello@example.com'), isEmpty);
      expect(findNoteLinks('value_example.com'), isEmpty);
      expect(findNoteLinks('Compare budget.total next'), isEmpty);
      expect(findNoteLinks('https://'), isEmpty);
      expect(findNoteLinks('Open example.test'), hasLength(1));
    },
  );

  test('resolves a caret or partial selection to the whole link', () {
    const source = 'Open https://example.com/path here';
    final link = findNoteLinks(source).single;

    expect(
      noteLinkForSelection([
        link,
      ], TextSelection.collapsed(offset: source.indexOf('example'))),
      link,
    );
    expect(
      noteLinkForSelection(
        [link],
        TextSelection(
          baseOffset: source.indexOf('example'),
          extentOffset: source.indexOf('.com'),
        ),
      ),
      link,
    );
    expect(
      noteLinkForSelection(
        [link],
        TextSelection(
          baseOffset: source.indexOf('Open'),
          extentOffset: source.indexOf('.com'),
        ),
      ),
      isNull,
    );
  });
}
