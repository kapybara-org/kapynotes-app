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
