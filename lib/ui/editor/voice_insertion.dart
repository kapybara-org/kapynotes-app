import '../../data/note_attachment.dart';
import 'image_insertion.dart';

/// Places one recording into [body] at [caret].
///
/// A recording is block-level in exactly the way an image is — it always gets
/// its own line and always leaves an empty one behind it — so this is
/// [insertImagesIntoBody] with a list of one, rather than a second copy of the
/// same careful line arithmetic. Sharing it is the point: the two kinds must
/// agree about where a placeholder goes, because the editor's line layout,
/// the rebase, and the orphan sweep all read that geometry and none of them
/// know which kind they are looking at.
///
/// Unlike images, recordings never land side by side. There is nothing to gain
/// from a row of chips, and a chip is full-width anyway.
ImageInsertion insertVoiceIntoBody({
  required String body,
  required List<NoteAttachmentRef> existing,
  required int caret,
  required NoteVoiceRef incoming,
}) => insertImagesIntoBody(
  body: body,
  existing: existing,
  caret: caret,
  incoming: [incoming],
);

/// Where a recording goes when its note is not the one on screen.
///
/// The recording still has to land — the user may have switched notes, closed
/// the window, or quit — and there is no editor to ask about the caret, so it
/// goes at the end. Returns the new body and the ref positioned in it.
({String body, List<NoteAttachmentRef> attachments}) appendVoiceToBody({
  required String body,
  required List<NoteAttachmentRef> existing,
  required NoteVoiceRef incoming,
}) {
  final result = insertVoiceIntoBody(
    body: body,
    existing: existing,
    caret: body.length,
    incoming: incoming,
  );
  return (body: result.body, attachments: result.attachments);
}
