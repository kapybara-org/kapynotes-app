import 'dart:convert';
import 'dart:typed_data';

import '../data/note.dart';
import '../data/note_format.dart';

/// An image anchored to one U+FFFC placeholder in the body.
///
/// The placeholder exists because the calculator lexes every line: a markdown
/// image or a bare URL sitting in the body would be tokenised and evaluated.
/// One object-replacement character is inert to the lexer and still gives the
/// editor a real caret position to render a WidgetSpan at.
class NoteAttachmentRef {
  /// Index of the U+FFFC character this image renders at.
  final int offset;
  final String attachmentId;

  /// The 32-byte file key. It rides *inside* the sealed payload, so it is
  /// already encrypted under the master key by the time it leaves the device
  /// and the server never holds it — no second key-wrapping table.
  final Uint8List key;

  /// Real MIME type. Kept in here, not on the row: the server gets to know a
  /// byte count and nothing else about what the user stored.
  final String mime;
  final int width;
  final int height;

  /// A ~400px preview stored as its own object, sealed under the *same* file
  /// key with its own nonce. The note view fetches only these; the full image
  /// is fetched on tap. Null when the image is small enough that a thumbnail
  /// would cost more than it saves.
  final String? thumbId;

  const NoteAttachmentRef({
    required this.offset,
    required this.attachmentId,
    required this.key,
    required this.mime,
    required this.width,
    required this.height,
    this.thumbId,
  });

  /// The character an attachment anchors to. Inert to the calculator lexer.
  static const String placeholder = '￼';

  Map<String, Object?> toJson() => {
    'offset': offset,
    'attachmentId': attachmentId,
    'key': base64.encode(key),
    'mime': mime,
    'width': width,
    'height': height,
    'thumbId': thumbId,
  };

  static NoteAttachmentRef? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final offset = raw['offset'];
    final id = raw['attachmentId'];
    final key = raw['key'];
    final mime = raw['mime'];
    final width = raw['width'];
    final height = raw['height'];
    final thumbId = raw['thumbId'];
    if (offset is! int || offset < 0) return null;
    if (id is! String || key is! String || mime is! String) return null;
    if (width is! int || height is! int || width <= 0 || height <= 0) {
      return null;
    }

    final Uint8List decoded;
    try {
      decoded = base64.decode(key);
    } on FormatException {
      return null;
    }

    return NoteAttachmentRef(
      offset: offset,
      attachmentId: id,
      key: decoded,
      mime: mime,
      width: width,
      height: height,
      thumbId: thumbId is String ? thumbId : null,
    );
  }
}

/// The plaintext sealed into a note's `SealedBox`.
///
/// `createdAt` lives in here rather than on the wire row on purpose. Sync only
/// needs `updatedAt`, so keeping creation time inside the envelope hands the
/// server one less fact about the user.
class NotePayload {
  final String body;
  final List<NoteFormatRange> formats;
  final List<NoteAttachmentRef> attachments;

  /// Epoch milliseconds, matching the on-disk format of the Flutter model.
  final int createdAt;

  const NotePayload({
    required this.body,
    this.formats = const [],
    this.attachments = const [],
    required this.createdAt,
  });

  factory NotePayload.fromNote(Note note) => NotePayload(
    body: note.body,
    formats: note.formats,
    createdAt: note.createdAt.millisecondsSinceEpoch,
  );

  /// Rebuilds a local note. [id] and [updatedAt] come from the wire row, since
  /// the server needs them in plaintext to order and page.
  Note toNote({required String id, required DateTime updatedAt}) => Note(
    id: id,
    body: body,
    formats: normalizeNoteFormats(formats, body.length),
    createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt),
    updatedAt: updatedAt,
  );

  Map<String, Object?> toJson() => {
    'body': body,
    'formats': formats.map((format) => format.toJson()).toList(),
    'attachments': attachments.map((ref) => ref.toJson()).toList(),
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
      createdAt: createdAt is int && createdAt >= 0 ? createdAt : 0,
    );
  }
}
