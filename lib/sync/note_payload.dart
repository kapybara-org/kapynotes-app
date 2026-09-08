import 'dart:typed_data';

import '../data/note.dart';
import '../data/note_attachment.dart';
import '../data/note_format.dart';

/// The plaintext sealed into a note's `SealedBox`.
///
/// `createdAt` lives in here rather than on the wire row on purpose. Sync only
/// needs `updatedAt`, so keeping creation time inside the envelope hands the
/// server one less fact about the user.
class NotePayload {
  final String body;
  final List<NoteFormatRange> formats;
  final List<NoteAttachmentRef> attachments;
  final int? archivedAt;

  /// Epoch milliseconds, matching the on-disk format of the Flutter model.
  final int createdAt;

  const NotePayload({
    required this.body,
    this.formats = const [],
    this.attachments = const [],
    this.archivedAt,
    required this.createdAt,
  });

  factory NotePayload.fromNote(Note note) => NotePayload(
    body: note.body,
    formats: note.formats,
    attachments: note.attachments,
    archivedAt: note.archivedAt?.millisecondsSinceEpoch,
    createdAt: note.createdAt.millisecondsSinceEpoch,
  );

  /// Rebuilds a local note. [id], [updatedAt] and the space come from the
  /// wire row, since the server needs them in plaintext to order, page and
  /// route; the content key is what this payload was just opened with.
  Note toNote({
    required String id,
    required DateTime updatedAt,
    String? spaceId,
    Uint8List? contentKey,
    int contentKeyEpoch = 1,
    int contentKeyGeneration = 1,
  }) => Note(
    id: id,
    body: body,
    formats: normalizeNoteFormats(formats, body.length),
    attachments: normalizeNoteAttachments(attachments, body),
    createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt),
    updatedAt: updatedAt,
    archivedAt: archivedAt == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(archivedAt!),
    spaceId: spaceId,
    contentKey: contentKey,
    contentKeyEpoch: contentKeyEpoch,
    contentKeyGeneration: contentKeyGeneration,
  );

  Map<String, Object?> toJson() => {
    'body': body,
    'formats': formats.map((format) => format.toJson()).toList(),
    'attachments': attachments.map((ref) => ref.toJson()).toList(),
    if (archivedAt != null) 'archivedAt': archivedAt,
    'createdAt': createdAt,
  };

  static NotePayload? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final body = raw['body'];
    if (body is! String) return null;
    final createdAt = raw['createdAt'];

    final attachmentsRaw = raw['attachments'];
    final attachments = attachmentsRaw is List
        ? attachmentsRaw
              .map(NoteAttachmentRef.fromJson)
              .whereType<NoteAttachmentRef>()
              .toList(growable: false)
        : const <NoteAttachmentRef>[];

    return NotePayload(
      body: body,
      formats: noteFormatsFromJson(raw['formats'], body.length),
      attachments: attachments,
      archivedAt: raw['archivedAt'] is int ? raw['archivedAt']! as int : null,
      createdAt: createdAt is int && createdAt >= 0 ? createdAt : 0,
    );
  }
}
