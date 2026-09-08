import 'dart:typed_data';

import 'package:kapy_notes/crdt/crdt.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/data/note_format.dart';

final DateTime created = DateTime.utc(2026, 9, 7, 12);

/// Reconciles only the text, keeping whatever side tables the doc renders.
List<Object?> type(NoteDoc doc, String body, {DateTime? now}) {
  final view = doc.view;
  return doc.reconcile(
    body: body,
    formats: view.formats,
    attachments: view.attachments,
    createdAt: view.createdAt ?? created,
    archivedAt: view.archivedAt,
    now: now ?? created,
  );
}

NoteFormatRange bold(int start, int end) =>
    NoteFormatRange(start: start, end: end, format: NoteFormat.bold);

NoteAttachmentRef image(int offset, {String hash = 'abc'}) => NoteImageRef(
  offset: offset,
  hash: hash,
  key: Uint8List(32),
  mime: 'image/png',
  width: 10,
  height: 20,
  bytes: 100,
);

/// Applies [ops] to every doc in [docs] except its author.
void broadcast(List<NoteDoc> docs, NoteDoc from, List<Object?> ops) {
  for (final doc in docs) {
    if (!identical(doc, from)) doc.apply(ops);
  }
}
