import '../../data/note_attachment.dart';
import 'image_insertion.dart';

/// Places [incoming] files into [body] at [caret], one to a line.
///
/// The same block rule as pictures and recordings — a new line before when the
/// caret is mid-line, an empty one after for the caret — so every kind agrees
/// on where a placeholder goes. Unlike pictures, several files never share a
/// line: a file chip is full width, and a row of them would be a gallery of
/// names nobody asked for.
///
/// The offsets on [incoming] are ignored; this function assigns them.
ImageInsertion insertFilesIntoBody({
  required String body,
  required List<NoteAttachmentRef> existing,
  required int caret,
  required List<NoteFileRef> incoming,
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
  final prefix = atLineStart ? '' : '\n';
  final placeholders = List.filled(
    incoming.length,
    NoteAttachmentRef.placeholder,
  ).join('\n');
  final inserted = '$prefix$placeholders\n';
  final newBody = body.substring(0, at) + inserted + body.substring(at);

  final firstAnchor = at + prefix.length;
  final placed = <NoteAttachmentRef>[
    for (var i = 0; i < incoming.length; i++)
      incoming[i].copyWith(offset: firstAnchor + i * 2),
  ];

  final shift = inserted.length;
  final moved = <NoteAttachmentRef>[
    for (final ref in existing)
      if (ref.offset < at) ref else ref.copyWith(offset: ref.offset + shift),
  ];

  return ImageInsertion(
    body: newBody,
    attachments: normalizeNoteAttachments([...moved, ...placed], newBody),
    selection: at + inserted.length,
  );
}
