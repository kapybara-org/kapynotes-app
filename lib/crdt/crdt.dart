/// The per-note CRDT: Fugue text plus anchored side tables.
///
/// Everything in here is plaintext and pure Dart. Sealing ops for the server
/// and moving them over the wire live elsewhere; this library only knows how
/// to turn edits into ops and ops back into a document.
library;

export 'anchor.dart';
export 'fugue_text.dart' show FugueNode, FugueText, Placement, EncodedRun;
export 'node_id.dart';
export 'note_doc.dart';
export 'text_diff.dart';
