import 'dart:convert';
import 'dart:typed_data';

import 'note_attachment.dart';
import 'note_drawing.dart';
import 'note_format.dart';

const Object _keepArchivedAt = Object();
const Object _keepHiddenAt = Object();
const Object _keepDrawing = Object();

/// A single note. Its title is derived from [body] rather than stored, so it
/// can never drift out of sync with the text.
class Note {
  final String id;
  final String body;
  final List<NoteFormatRange> formats;

  /// Images anchored to U+FFFC placeholders in [body], ordered by offset.
  ///
  /// Held on the note rather than in a side table because an image is part of
  /// the note's content: it has to move, sync, export and be thrown away with
  /// it, and every one of those paths already carries a [Note].
  final List<NoteAttachmentRef> attachments;

  /// The canvas, when this is a drawing rather than written text; null for a
  /// written note.
  ///
  /// A note is one or the other, chosen while it is still new. A drawing's
  /// [body] is only its title, so a build from before drawings still lists it
  /// by name — and syncs its canvas along untouched, because it lives in the
  /// note's document rather than in this model.
  final NoteDrawing? drawing;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// When the note left the main list, or null while it is active.
  ///
  /// Archiving is content state rather than a tombstone. It therefore travels
  /// with the note, can be synced, and can be cleared to restore the note.
  final DateTime? archivedAt;

  /// When the note entered Hidden Notes, or null while it is not hidden.
  ///
  /// Like [archivedAt], this is content state: it follows the note between the
  /// owner's devices inside the encrypted payload. Access credentials do not
  /// follow it. Each device protects the folder with its own system lock or
  /// PIN.
  final DateTime? hiddenAt;

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
    this.attachments = const [],
    this.drawing,
    required this.createdAt,
    required this.updatedAt,
    this.archivedAt,
    this.hiddenAt,
    this.syncedAt,
    this.spaceId,
    this.contentKey,
    this.contentKeyEpoch = 1,
    this.contentKeyGeneration = 1,
  });

  static const String untitled = 'New Note';
  static const String untitledDrawing = 'Drawing';
  static const int _titleLimit = 60;

  /// True when this note is in a shared space rather than the personal one.
  bool get isShared => spaceId != null;
  bool get isArchived => archivedAt != null;
  bool get isHidden => hiddenAt != null;
  bool get isDrawing => drawing != null;

  Note copyWith({
    String? body,
    List<NoteFormatRange>? formats,
    List<NoteAttachmentRef>? attachments,
    Object? drawing = _keepDrawing,
    DateTime? updatedAt,
    Object? archivedAt = _keepArchivedAt,
    Object? hiddenAt = _keepHiddenAt,
  }) => Note(
    id: id,
    body: body ?? this.body,
    formats: formats ?? this.formats,
    attachments: attachments ?? this.attachments,
    drawing: identical(drawing, _keepDrawing)
        ? this.drawing
        : drawing as NoteDrawing?,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    archivedAt: identical(archivedAt, _keepArchivedAt)
        ? this.archivedAt
        : archivedAt as DateTime?,
    hiddenAt: identical(hiddenAt, _keepHiddenAt)
        ? this.hiddenAt
        : hiddenAt as DateTime?,
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
    attachments: attachments,
    drawing: drawing,
    createdAt: createdAt,
    updatedAt: updatedAt,
    archivedAt: archivedAt,
    hiddenAt: hiddenAt,
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
    attachments: attachments,
    drawing: drawing,
    createdAt: createdAt,
    updatedAt: at,
    archivedAt: archivedAt,
    hiddenAt: hiddenAt,
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
    attachments: attachments,
    drawing: drawing,
    createdAt: createdAt,
    updatedAt: updatedAt,
    archivedAt: archivedAt,
    hiddenAt: hiddenAt,
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
  ///
  /// A note that opens with a picture or a recording has no words on that
  /// line to take one from, so it looks past it: the first thing typed
  /// underneath names the note, whatever it was that came first.
  ///
  /// With nothing typed at all, a recording can still say what it was about
  /// — its summary's title, or failing that the opening of what it was heard
  /// to say. A picture cannot, and neither can a recording nobody has
  /// transcribed yet, so those wait as [untitled] until there is something to
  /// go on.
  String get title {
    final fallback = isDrawing ? untitledDrawing : untitled;
    final spoken = _firstNonEmptyLine() ?? _spokenTitle();
    if (spoken == null) return fallback;

    var text = spoken.trimLeft();
    text = text.replaceFirst(RegExp(r'^#{1,6}\s*'), '');
    text = text.trimRight();
    if (text.endsWith(':')) {
      text = text.substring(0, text.length - 1).trimRight();
    }
    if (text.isEmpty) return fallback;

    return text.length > _titleLimit
        ? '${text.substring(0, _titleLimit).trimRight()}…'
        : text;
  }

  /// No words, and no strokes if it is a drawing. A blank canvas is as empty
  /// as a blank page.
  bool get isEmpty => body.trim().isEmpty && (drawing?.isEmpty ?? true);

  /// Case-insensitive match across every piece of searchable note content.
  ///
  /// Separate words may live in separate lines or attachments. This matters
  /// for outline-shaped notes: searching for a project name from the heading
  /// and a task from a deeply nested line should still find the note. Quoted
  /// text stays one phrase.
  bool matches(String query) {
    final terms = _noteSearchTerms(query);
    if (terms.isEmpty) return true;
    final candidates = _searchCandidates().toList(growable: false);
    return terms.every(
      (term) =>
          candidates.any((candidate) => candidate.normalized.contains(term)),
    );
  }

  /// The line that best explains why this note matched [query].
  ///
  /// The title is already visible above this text in the sidebar, so a nested
  /// line wins a tie. A summary wins over raw transcript speech, and generated
  /// takes are included too: all of them are content the user can see inside
  /// the note even though they are stored on its attachment.
  String? matchSnippet(String query) {
    final terms = _noteSearchTerms(query);
    if (terms.isEmpty) return null;
    final candidates = _searchCandidates().toList(growable: false);
    if (!terms.every(
      (term) =>
          candidates.any((candidate) => candidate.normalized.contains(term)),
    )) {
      return null;
    }

    final phrase = terms.join(' ');
    _NoteSearchCandidate? best;
    var bestScore = -1;
    for (final candidate in candidates) {
      final matched = terms.where(candidate.normalized.contains).length;
      if (matched == 0) continue;
      final score =
          matched * 1000 +
          (candidate.normalized.contains(phrase) ? 100 : 0) +
          candidate.priority;
      if (score > bestScore) {
        best = candidate;
        bestScore = score;
      }
    }
    return best?.display;
  }

  Iterable<_NoteSearchCandidate> _searchCandidates() sync* {
    var foundTitle = false;
    for (final line in body.split('\n')) {
      final text = line.replaceAll(NoteAttachmentRef.placeholder, '').trim();
      if (text.isEmpty) continue;
      final isTitle = !foundTitle;
      foundTitle = true;
      yield _NoteSearchCandidate(
        text,
        display: text,
        // A detail line explains a result the visible title cannot.
        priority: isTitle ? 10 : 60,
      );
    }

    for (final ref in attachments) {
      if (ref is! NoteVoiceRef) continue;
      final summary = ref.summary;
      if (summary != null) {
        yield _NoteSearchCandidate(
          summary.title,
          display: '🎙 ${summary.title.trim()}',
          priority: 50,
        );
        for (final point in summary.points) {
          yield _NoteSearchCandidate(
            point,
            display: '🎙 ${point.trim()}',
            priority: 50,
          );
        }
      }

      final transcript = ref.transcript;
      if (transcript != null) {
        for (final name in transcript.speakers.values) {
          yield _NoteSearchCandidate(
            name,
            display: '🎙 ${name.trim()}',
            priority: 20,
          );
        }
        for (final segment in transcript.segments) {
          yield _NoteSearchCandidate(
            segment.t,
            display: '🎙 ${segment.t.trim()}',
            priority: 20,
          );
        }
      }

      for (final take in ref.takes) {
        yield _NoteSearchCandidate(
          take.text,
          display: '${take.kind.label}: ${take.text.trim()}',
          priority: 40,
        );
        final instruction = take.instruction;
        if (instruction != null) {
          yield _NoteSearchCandidate(
            instruction,
            display: '${take.kind.label}: ${instruction.trim()}',
            priority: 30,
          );
        }
      }
    }
  }

  /// What the recordings in this note were heard to say, best first.
  ///
  /// A summary anywhere in the note beats raw speech from anywhere in it: the
  /// summary is a phrase somebody would have written, where a transcript
  /// opens with whatever the recording opened with — "um, so" and all. Both
  /// are clamped by [title], which is what keeps a transcript from arriving
  /// as a paragraph.
  ///
  /// A recording with neither is not named here. It used to be listed as
  /// "Voice note", which said what the note held but nothing about it, and
  /// every untranscribed recording said it — a column of identical rows. A
  /// note with nothing to say for itself reads better as a new one.
  String? _spokenTitle() {
    for (final ref in attachments) {
      if (ref is! NoteVoiceRef) continue;
      final title = ref.summary?.title.trim();
      if (title != null && title.isNotEmpty) return title;
    }
    for (final ref in attachments) {
      if (ref is! NoteVoiceRef) continue;
      final said = ref.transcript?.text.trim();
      if (said != null && said.isNotEmpty) return said;
    }
    return null;
  }

  /// The first line with words on it, with attachment anchors taken out.
  ///
  /// A line holding nothing but a picture or a recording is not a title. It
  /// has to be skipped explicitly because U+FFFC is not whitespace, so `trim`
  /// keeps it: without this, a note that opens with a photo is listed under an
  /// invisible character, and one that is *only* a recording is titled with a
  /// box glyph in every sidebar it appears in.
  String? _firstNonEmptyLine() {
    for (final line in body.split('\n')) {
      final text = line.replaceAll(NoteAttachmentRef.placeholder, '');
      if (text.trim().isNotEmpty) return text;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'body': body,
    if (formats.isNotEmpty)
      'formats': formats.map((format) => format.toJson()).toList(),
    if (attachments.isNotEmpty)
      'attachments': attachments.map((ref) => ref.toJson()).toList(),
    if (drawing != null) 'drawing': drawing!.toJson(),
    'createdAt': createdAt.millisecondsSinceEpoch,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    if (archivedAt != null) 'archivedAt': archivedAt!.millisecondsSinceEpoch,
    if (hiddenAt != null) 'hiddenAt': hiddenAt!.millisecondsSinceEpoch,
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
      attachments: noteAttachmentsFromJson(raw['attachments'], body),
      drawing: NoteDrawing.fromJson(raw['drawing']),
      createdAt: _date(raw['createdAt']),
      updatedAt: _date(raw['updatedAt']),
      archivedAt: _optionalDate(raw['archivedAt']),
      hiddenAt: _optionalDate(raw['hiddenAt']),
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

final RegExp _noteSearchToken = RegExp(r'"([^"]+)"|(\S+)');
final RegExp _noteSearchWhitespace = RegExp(r'\s+');

List<String> _noteSearchTerms(String query) {
  final terms = <String>[];
  for (final match in _noteSearchToken.allMatches(query)) {
    final value = match.group(1) ?? match.group(2)?.replaceAll('"', '');
    if (value == null) continue;
    final normalized = _normalizeNoteSearch(value);
    if (normalized.isNotEmpty && !terms.contains(normalized)) {
      terms.add(normalized);
    }
  }
  return terms;
}

String _normalizeNoteSearch(String value) =>
    value.toLowerCase().replaceAll(_noteSearchWhitespace, ' ').trim();

class _NoteSearchCandidate {
  _NoteSearchCandidate(
    String text, {
    required this.display,
    required this.priority,
  }) : normalized = _normalizeNoteSearch(text);

  final String normalized;
  final String display;
  final int priority;
}
