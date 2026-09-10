import 'package:flutter/services.dart' show TextEditingValue, TextSelection;

import '../../data/note_attachment.dart';

/// A note after images have been dropped into it.
class ImageInsertion {
  const ImageInsertion({
    required this.body,
    required this.attachments,
    required this.selection,
  });

  final String body;
  final List<NoteAttachmentRef> attachments;

  /// Where the caret should land: on the empty line after the images, ready
  /// for whatever the writer wants to say about them.
  final int selection;
}

/// Places [incoming] images into [body] at [caret].
///
/// Images are block-level, so an insert always starts its own line and always
/// leaves one behind it. Dropping three pictures into the middle of a sentence
/// should not split the sentence around them, and it should not leave the
/// caret wedged between a picture and a full stop.
///
/// Several images added at once land side by side, which is what turns them
/// into a gallery: `imageBoxFor` sizes images by how many share their line.
/// One added on its own gets the whole writing column. Both follow from where
/// the placeholders go, so there is no separate notion of a "grid block" to
/// keep in step with the text.
///
/// The offsets on [incoming] are ignored; this function assigns them.
ImageInsertion insertImagesIntoBody({
  required String body,
  required List<NoteAttachmentRef> existing,
  required int caret,
  required List<NoteAttachmentRef> incoming,
}) {
  if (incoming.isEmpty) {
    return ImageInsertion(
      body: body,
      attachments: normalizeNoteAttachments(existing, body),
      selection: caret.clamp(0, body.length),
    );
  }

  final at = caret.clamp(0, body.length);
  final atLineStart = at == 0 || body.codeUnitAt(at - 1) == 0x0A;
  final atLineEnd = at == body.length || body.codeUnitAt(at) == 0x0A;

  final prefix = atLineStart ? '' : '\n';
  // A trailing newline always, so the caret has somewhere to go that is not
  // beside a picture. When the caret was mid-line, the rest of that line
  // follows the images rather than being cut adrift above them.
  final suffix = atLineEnd ? '\n' : '\n';

  final placeholders = NoteAttachmentRef.placeholder * incoming.length;
  final inserted = '$prefix$placeholders$suffix';
  final newBody = body.substring(0, at) + inserted + body.substring(at);

  final firstAnchor = at + prefix.length;
  final placed = <NoteAttachmentRef>[
    for (var i = 0; i < incoming.length; i++)
      incoming[i].copyWith(offset: firstAnchor + i),
  ];

  // Everything that already sat at or after the caret slides along.
  final shift = inserted.length;
  final moved = <NoteAttachmentRef>[
    for (final ref in existing)
      if (ref.offset < at) ref else ref.copyWith(offset: ref.offset + shift),
  ];

  return ImageInsertion(
    body: newBody,
    attachments: normalizeNoteAttachments([...moved, ...placed], newBody),
    selection: firstAnchor + incoming.length + suffix.length,
  );
}

/// Keeps a picture's line to itself, moving anything typed there above or
/// below it.
///
/// An image is one U+FFFC in the body, and nothing stops a caret sitting
/// beside it. Text left there renders on the picture's own row — squeezed into
/// whatever width the picture leaves, on every platform — which is never what
/// anybody meant. Writing *about* a picture is something people do constantly;
/// writing *beside* one is not.
///
/// The rule is one line: a line holding a picture holds nothing else. Text
/// that would break it moves to a line of its own, below the pictures when it
/// was typed after them and above when it was typed before, and the caret goes
/// with it so typing simply continues.
///
/// Two useful things fall out of the same rule rather than needing their own
/// handling. Backspace at the start of the line under a picture would merge
/// that text onto the picture's line, so it is undone and the key does
/// nothing — which is the honest answer, since the merge it asked for is not a
/// state this editor has. And selecting a picture and typing still replaces
/// it: the placeholder is gone from the result, so there is no picture line
/// left to keep clear.
///
/// Only the lines this edit actually touched are considered. A note that
/// arrived from a sync, or from a version of the app that did not have this
/// rule, is left as its author wrote it until somebody edits that line.
TextEditingValue keepImageLinesToThemselves(
  TextEditingValue previous,
  TextEditingValue next,
) {
  const placeholder = NoteAttachmentRef.placeholder;
  final text = next.text;
  if (!text.contains(placeholder)) return next;

  // The span this edit rewrote, found from the ends inwards. Everything
  // outside it is untouched and none of its business.
  final before = previous.text;
  var start = 0;
  while (start < before.length &&
      start < text.length &&
      before.codeUnitAt(start) == text.codeUnitAt(start)) {
    start++;
  }
  var oldEnd = before.length;
  var newEnd = text.length;
  while (oldEnd > start &&
      newEnd > start &&
      before.codeUnitAt(oldEnd - 1) == text.codeUnitAt(newEnd - 1)) {
    oldEnd--;
    newEnd--;
  }

  // Pictures arriving bring their own arrangement — a paste of copied text and
  // images, or an undo putting a picture back where it was. This rule is about
  // *writing* beside a picture, so an edit that carries one is not its business.
  if (text.substring(start, newEnd).contains(placeholder)) return next;

  // A line somebody else already wrote a picture into, or one from a version
  // of the app that had no such rule. Editing near it is not the moment to
  // rearrange it, and refusing to would leave it uneditable.
  if (_hasMixedLine(
    before.substring(_lineStart(before, start), _lineEnd(before, oldEnd)),
  )) {
    return next;
  }

  final firstLine = _lineStart(text, start);
  final lastLine = _lineEnd(text, newEnd);
  final touched = text.substring(firstLine, lastLine);
  if (!_hasMixedLine(touched)) return next;

  final caret = next.selection.isValid
      ? next.selection.extentOffset.clamp(0, text.length)
      : -1;
  final rebuilt = StringBuffer();
  var movedCaret = caret;
  var changed = false;
  var cursor = firstLine;

  for (final line in touched.split('\n')) {
    final lineStart = cursor;
    cursor += line.length + 1;
    if (rebuilt.isNotEmpty) rebuilt.write('\n');
    final split = _splitPictureLine(line);
    if (split == null) {
      rebuilt.write(line);
      continue;
    }
    changed = true;
    final written = rebuilt.length + firstLine;
    rebuilt.write(split.text);
    if (caret >= lineStart && caret <= lineStart + line.length) {
      movedCaret = written + split.caretFor(caret - lineStart);
    }
  }
  if (!changed) return next;

  final replaced = text.replaceRange(firstLine, lastLine, rebuilt.toString());
  return TextEditingValue(
    text: replaced,
    selection: caret < 0
        ? next.selection
        : TextSelection.collapsed(offset: movedCaret.clamp(0, replaced.length)),
  );
}

/// Whether any line here holds a picture and something else.
bool _hasMixedLine(String text) =>
    text.split('\n').any((line) => _splitPictureLine(line) != null);

int _lineStart(String text, int offset) {
  final from = offset.clamp(0, text.length);
  // An edit that begins at the very start of the note has no line before it,
  // and `lastIndexOf` will not be asked to search from -1.
  if (from == 0) return 0;
  final index = text.lastIndexOf('\n', from - 1);
  return index < 0 ? 0 : index + 1;
}

int _lineEnd(String text, int offset) {
  final index = text.indexOf('\n', offset.clamp(0, text.length));
  return index < 0 ? text.length : index;
}

/// One picture line rewritten, and where a caret in the old line lands in it.
class _PictureLine {
  _PictureLine({
    required this.source,
    required this.text,
    required this.headLength,
    required this.tailStart,
    required this.firstPicture,
  });

  /// The line as it was, mixed.
  final String source;

  /// The same content as two or three lines, pictures on their own.
  final String text;

  /// The words that were before the first picture, now the line above it.
  final int headLength;

  /// Where the words below begin in [text], or the end of the pictures when
  /// there are none.
  final int tailStart;

  /// Where the first picture was in [source].
  final int firstPicture;

  int caretFor(int offset) {
    // Anything up to the first picture belongs to the line above it.
    if (offset <= firstPicture) return offset.clamp(0, headLength);
    // Everything after follows the line below: count the characters the caret
    // had passed, ignoring the pictures it stepped over.
    final passed = source
        .substring(firstPicture, offset.clamp(firstPicture, source.length))
        .replaceAll(NoteAttachmentRef.placeholder, '')
        .length;
    return tailStart + passed;
  }
}

/// Splits [line] into words above, pictures, and words below — or null when
/// the line is already only pictures, or holds none at all.
_PictureLine? _splitPictureLine(String line) {
  const placeholder = NoteAttachmentRef.placeholder;
  final firstPicture = line.indexOf(placeholder);
  if (firstPicture < 0) return null;
  final count = placeholder.allMatches(line).length;
  final pictures = placeholder * count;
  if (line == pictures) return null;

  final head = line.substring(0, firstPicture);
  final tail = line.substring(firstPicture).replaceAll(placeholder, '');
  final picturesAt = head.isEmpty ? 0 : head.length + 1;
  return _PictureLine(
    source: line,
    text: [
      if (head.isNotEmpty) head,
      pictures,
      if (tail.isNotEmpty) tail,
    ].join('\n'),
    headLength: head.length,
    // One past the pictures when words follow, to step over the line break.
    tailStart: picturesAt + count + (tail.isEmpty ? 0 : 1),
    firstPicture: firstPicture,
  );
}
