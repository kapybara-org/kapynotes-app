import 'dart:convert';
import 'dart:typed_data';

import 'note_format.dart';

/// A single note. Its title is derived from [body] rather than stored, so it
/// can never drift out of sync with the text.
class Note {
  final String id;
  final String body;
  final List<NoteFormatRange> formats;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// The [updatedAt] the server has confirmed it holds, or null if this note
  /// has never been pushed.
  ///
  /// Storing the confirmed timestamp rather than a boolean flag is what makes
  /// a push safe to interleave with typing: if the user edits while a push is
  /// in flight, [updatedAt] moves on, no longer matches what came back, and
  /// the note simply stays dirty. A flag cleared on success would have thrown
  /// that edit away.
  final DateTime? syncedAt;

  /// Which space this note lives in. Null means the personal space — the
  /// only space a note written before sharing existed could be in, and the
  /// one every note starts in.
  final String? spaceId;

  /// The 32-byte key this note's content is sealed under when it lives in a
  /// shared space. Null for a personal note, which is sealed under the master
  /// key exactly as before sharing existed. Minted the first time the note
  /// moves into a team space, and only then.
  ///
  /// Kept beside the plaintext on local disk, which is no more sensitive than
  /// the plaintext it opens.
  final Uint8List? contentKey;

  /// Bumped every time [contentKey] is replaced, so a stale writer can be
  /// refused by an integer comparison rather than by cryptography.
  final int contentKeyEpoch;

  /// The space's key generation when [contentKey] was minted. A note whose
  /// key predates a removal — its generation is behind the space's — gets a
  /// fresh key on its next write, so the person removed cannot read what is
  /// written after they left.
  final int contentKeyGeneration;

  const Note({
    required this.id,
    required this.body,
    this.formats = const [],
    required this.createdAt,
    required this.updatedAt,
    this.syncedAt,
    this.spaceId,
    this.contentKey,
    this.contentKeyEpoch = 1,
    this.contentKeyGeneration = 1,
  });

  static const String untitled = 'New Note';
  static const int _titleLimit = 60;

  /// True when this note is in a shared space rather than the personal one.
  bool get isShared => spaceId != null;

  Note copyWith({
    String? body,
    List<NoteFormatRange>? formats,
    DateTime? updatedAt,
  }) => Note(
    id: id,
    body: body ?? this.body,
    formats: formats ?? this.formats,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    // Deliberately carried over: an edit must not look synced.
    syncedAt: syncedAt,
    spaceId: spaceId,
    contentKey: contentKey,
    contentKeyEpoch: contentKeyEpoch,
    contentKeyGeneration: contentKeyGeneration,
  );

  /// Records that the server now holds this exact revision.
  Note markSynced(DateTime at) => Note(
    id: id,
    body: body,
    formats: formats,
    createdAt: createdAt,
    updatedAt: updatedAt,
    syncedAt: at,
    spaceId: spaceId,
    contentKey: contentKey,
    contentKeyEpoch: contentKeyEpoch,
    contentKeyGeneration: contentKeyGeneration,
  );

  /// The same note in another space under another key, as a write. A move is
  /// an edit as far as last-writer-wins is concerned, so [updatedAt] moves and
  /// the note goes back to being dirty.
  Note movedTo({
    required String? spaceId,
    required Uint8List? contentKey,
    required int contentKeyEpoch,
    required int contentKeyGeneration,
    required DateTime at,
  }) => Note(
    id: id,
    body: body,
    formats: formats,
    createdAt: createdAt,
    updatedAt: at,
    syncedAt: null,
    spaceId: spaceId,
    contentKey: contentKey,
    contentKeyEpoch: contentKeyEpoch,
    contentKeyGeneration: contentKeyGeneration,
  );

  /// A new key for the same content, in place. Used when a write has to
  /// rotate the content key: the body is unchanged, the envelope is not.
  Note withKey({
    required Uint8List contentKey,
    required int contentKeyEpoch,
    required int contentKeyGeneration,
  }) => Note(
    id: id,
    body: body,
    formats: formats,
    createdAt: createdAt,
    updatedAt: updatedAt,
    syncedAt: syncedAt,
    spaceId: spaceId,
    contentKey: contentKey,
    contentKeyEpoch: contentKeyEpoch,
    contentKeyGeneration: contentKeyGeneration,
  );

  /// True when the server does not yet have this revision.
  ///
  /// Compared as epoch milliseconds rather than with `==`, which on [DateTime]
  /// also compares the UTC flag: a timestamp that survived a round trip
  /// through storage is local-flavoured, and would otherwise never look equal
  /// to one that came off the wire as UTC.
  bool get isDirty =>
      syncedAt == null ||
      syncedAt!.millisecondsSinceEpoch != updatedAt.millisecondsSinceEpoch;

  /// First non-empty line, without heading markers or a trailing colon.
  String get title {
    final line = _firstNonEmptyLine();
    if (line == null) return untitled;

    var text = line.trimLeft();
    text = text.replaceFirst(RegExp(r'^#{1,6}\s*'), '');
    text = text.trimRight();
    if (text.endsWith(':')) {
      text = text.substring(0, text.length - 1).trimRight();
    }
    if (text.isEmpty) return untitled;

    return text.length > _titleLimit
        ? '${text.substring(0, _titleLimit).trimRight()}…'
        : text;
  }

  bool get isEmpty => body.trim().isEmpty;

  /// Case-insensitive match against the whole body, not just the title.
  bool matches(String query) =>
      body.toLowerCase().contains(query.toLowerCase());

  /// The first line containing [query], shown while searching so the user can
  /// see why a note matched.
  String? matchSnippet(String query) {
    if (query.isEmpty) return null;
    final needle = query.toLowerCase();
    for (final line in body.split('\n')) {
      if (line.toLowerCase().contains(needle)) {
        final trimmed = line.trim();
        if (trimmed.isNotEmpty) return trimmed;
      }
    }
    return null;
  }

  String? _firstNonEmptyLine() {
    for (final line in body.split('\n')) {
      if (line.trim().isNotEmpty) return line;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'body': body,
    if (formats.isNotEmpty)
      'formats': formats.map((format) => format.toJson()).toList(),
    'createdAt': createdAt.millisecondsSinceEpoch,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    // Omitted while null so a store that has never synced stays byte-identical
    // to what earlier builds wrote.
    if (syncedAt != null) 'syncedAt': syncedAt!.millisecondsSinceEpoch,
    // Likewise: a personal note's record is exactly what it always was.
    if (spaceId != null) 'spaceId': spaceId,
    if (contentKey != null) 'contentKey': base64.encode(contentKey!),
    if (contentKey != null) 'contentKeyEpoch': contentKeyEpoch,
    if (contentKey != null) 'contentKeyGeneration': contentKeyGeneration,
  };

  static Note? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final body = raw['body'];
    if (id is! String || body is! String) return null;
    final spaceId = raw['spaceId'];
    final epoch = raw['contentKeyEpoch'];
    final generation = raw['contentKeyGeneration'];
    return Note(
      id: id,
      body: body,
      formats: noteFormatsFromJson(raw['formats'], body.length),
      createdAt: _date(raw['createdAt']),
      updatedAt: _date(raw['updatedAt']),
      syncedAt: _optionalDate(raw['syncedAt']),
      spaceId: spaceId is String && spaceId.isNotEmpty ? spaceId : null,
      contentKey: _optionalKey(raw['contentKey']),
      contentKeyEpoch: epoch is int && epoch > 0 ? epoch : 1,
      contentKeyGeneration: generation is int && generation > 0
          ? generation
          : 1,
    );
  }

  static DateTime _date(Object? value) =>
      DateTime.fromMillisecondsSinceEpoch(value is int ? value : 0);

  static DateTime? _optionalDate(Object? value) =>
      value is int ? DateTime.fromMillisecondsSinceEpoch(value) : null;

  static Uint8List? _optionalKey(Object? value) {
    if (value is! String) return null;
    try {
      final bytes = base64.decode(value);
      return bytes.length == 32 ? bytes : null;
    } on FormatException {
      return null;
    }
  }
}
