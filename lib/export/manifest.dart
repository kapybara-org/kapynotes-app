import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../data/note_format.dart';

/// The archive's index, and the reason import can be lossless.
///
/// Markdown alone cannot say everything a note can — see
/// `renderNoteMarkdown` — so the exact ranges travel here instead, next to the
/// ids and timestamps that make a restore a restore rather than a paste.

/// Bumped only when an older build could no longer read what a newer one
/// writes. A reader that meets a higher number stops rather than guesses; the
/// golden archives under `test/goldens/archives/` are what stop this changing
/// by accident.
/// Bumped to 2 when recordings joined pictures in the archive.
///
/// An archive written by this build still reads in an older one: version 2
/// only *adds* attachment kinds, and an older reader that meets a `voice`
/// entry skips it rather than failing. Import accepts 1 and 2.
const int exportSchemaVersion = 2;

const String exportManifestPath = 'manifest.json';
const String exportNotesDirectory = 'notes';

/// Where pictures live in an archive, beside `notes/` rather than inside it.
///
/// One directory for the whole export, addressed by content hash, so the same
/// picture used in four notes is written once — and a reader who opens the
/// archive in a file browser sees a flat, obvious folder of images.
const String exportImagesDirectory = 'images';

/// Where recordings live in an archive. Its own directory rather than sharing
/// `images/`, so somebody opening the zip in a file browser finds their voice
/// notes in an obvious place, playable by double-clicking.
const String exportAttachmentsDirectory = 'attachments';

/// `sha256:<hex>` over the UTF-8 of a rendered `.md` file.
///
/// Import compares this against the file it finds. A match means the manifest
/// still describes that file and its ranges can be trusted; a mismatch means a
/// human has been in there, and their edit is the more recent intent.
String bodyHashOf(String markdown) =>
    'sha256:${sha256.convert(utf8.encode(markdown))}';

/// One attachment in an archive: enough to rebuild the note's reference to it
/// without opening the file.
///
/// Pictures and recordings share this rather than having a class each, because
/// almost everything about them here is the same — a hash, a path, a MIME type
/// — and the parts that differ are exactly the parts that are optional.
class ExportedAttachment {
  const ExportedAttachment({
    required this.hash,
    required this.path,
    required this.mime,
    this.kind = 'image',
    this.width,
    this.height,
    this.durationMs,
    this.transcript,
    this.summary,
  });

  /// sha256 of the bytes, which is also what the file is named.
  final String hash;

  /// Where the bytes live inside the archive.
  final String path;

  final String mime;

  /// `image` or `voice`. Defaulted, so an archive written before recordings
  /// existed reads correctly without a migration.
  final String kind;

  /// Pictures only.
  final int? width;
  final int? height;

  /// Recordings only.
  final int? durationMs;
  final Map<String, Object?>? transcript;
  final Map<String, Object?>? summary;

  bool get isVoice => kind == 'voice';

  Map<String, Object?> toJson() => {
    'hash': hash,
    'path': path,
    'mime': mime,
    // Omitted for pictures, which is what an older reader expects to find.
    if (kind != 'image') 'kind': kind,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    if (durationMs != null) 'durationMs': durationMs,
    if (transcript != null) 'transcript': transcript,
    if (summary != null) 'summary': summary,
  };

  static ExportedAttachment? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final hash = raw['hash'];
    final path = raw['path'];
    final mime = raw['mime'];
    if (hash is! String || hash.isEmpty) return null;
    if (path is! String || !isSafeArchivePath(path)) return null;
    if (mime is! String) return null;

    final kind = raw['kind'] is String ? raw['kind']! as String : 'image';
    final width = raw['width'];
    final height = raw['height'];
    final durationMs = raw['durationMs'];

    // A picture with no size cannot be laid out, and a recording with no
    // duration cannot be drawn; either way the entry is not usable.
    if (kind == 'image' && (width is! int || height is! int)) return null;
    if (kind == 'voice' && (durationMs is! int || durationMs <= 0)) return null;

    return ExportedAttachment(
      hash: hash,
      path: path,
      mime: mime,
      kind: kind,
      width: width is int ? width : null,
      height: height is int ? height : null,
      durationMs: durationMs is int ? durationMs : null,
      transcript: raw['transcript'] is Map
          ? (raw['transcript']! as Map).cast<String, Object?>()
          : null,
      summary: raw['summary'] is Map
          ? (raw['summary']! as Map).cast<String, Object?>()
          : null,
    );
  }
}

class ExportedNote {
  const ExportedNote({
    required this.id,
    required this.path,
    required this.updatedAt,
    required this.createdAt,
    required this.bodyHash,
    this.archivedAt,
    this.formats = const [],
    this.images = const [],
  });

  /// Preserved so a restore puts the note back where it was rather than
  /// beside itself.
  final String id;

  /// Where the markdown lives inside the archive, always under `notes/`.
  final String path;

  final DateTime updatedAt;

  /// Epoch milliseconds, matching `NotePayload` and the on-disk note.
  final int createdAt;
  final DateTime? archivedAt;

  final String bodyHash;
  final List<NoteFormatRange> formats;

  /// The pictures this note holds, in the order they appear.
  ///
  /// Recorded so an import can restore a note's images without decoding every
  /// file to rediscover its size. The file *key* is deliberately absent: an
  /// archive is plaintext, the bytes are right there beside the manifest, and
  /// a key that unlocks nothing is a secret with nowhere useful to go. Import
  /// mints a fresh one.
  final List<ExportedAttachment> images;

  Map<String, Object?> toJson() => {
    'id': id,
    'path': path,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'createdAt': createdAt,
    if (archivedAt != null) 'archivedAt': archivedAt!.toUtc().toIso8601String(),
    'bodyHash': bodyHash,
    if (formats.isNotEmpty)
      'formats': formats.map((format) => format.toJson()).toList(),
    if (images.isNotEmpty)
      'images': images.map((image) => image.toJson()).toList(),
  };

  /// Returns null for an entry too damaged to place. Import reports those and
  /// carries on with the rest — a partly readable archive is worth more than
  /// a refusal.
  static ExportedNote? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final path = raw['path'];
    final bodyHash = raw['bodyHash'];
    if (id is! String || id.isEmpty) return null;
    if (path is! String || !isSafeArchivePath(path)) return null;
    if (bodyHash is! String) return null;

    final updatedAt = DateTime.tryParse('${raw['updatedAt']}');
    if (updatedAt == null) return null;
    final createdAt = raw['createdAt'];
    final archivedAt = raw['archivedAt'] == null
        ? null
        : DateTime.tryParse('${raw['archivedAt']}');

    return ExportedNote(
      id: id,
      path: path,
      updatedAt: updatedAt.toLocal(),
      createdAt: createdAt is int && createdAt >= 0 ? createdAt : 0,
      archivedAt: archivedAt?.toLocal(),
      bodyHash: bodyHash,
      images: raw['images'] is List
          ? (raw['images'] as List)
                .map(ExportedAttachment.fromJson)
                .whereType<ExportedAttachment>()
                .toList(growable: false)
          : const [],
      // Clipped against the body once it is read, not here: the manifest is
      // parsed before the file it describes.
      formats: raw['formats'] is List
          ? (raw['formats'] as List)
                .map((entry) => NoteFormatRange.fromJson(entry, 1 << 30))
                .whereType<NoteFormatRange>()
                .toList(growable: false)
          : const [],
    );
  }
}

class ExportManifest {
  const ExportManifest({
    required this.appVersion,
    required this.exportedAt,
    required this.notes,
    this.schema = exportSchemaVersion,
  });

  final int schema;
  final String appVersion;
  final DateTime exportedAt;
  final List<ExportedNote> notes;

  static const String appName = 'KapyNotes';

  Map<String, Object?> toJson() => {
    'schema': schema,
    'app': appName,
    'appVersion': appVersion,
    'exportedAt': exportedAt.toUtc().toIso8601String(),
    'notes': notes.map((note) => note.toJson()).toList(),
  };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());
}

/// Why a manifest could not be read at all.
enum ManifestFault {
  /// Not JSON, or not an object with a `notes` list.
  unreadable,

  /// Written by a build that knows something this one does not.
  futureSchema,
}

class ManifestResult {
  const ManifestResult.ok(this.manifest, this.skipped)
    : fault = null,
      schema = null;
  const ManifestResult.failed(this.fault, {this.schema})
    : manifest = null,
      skipped = 0;

  final ExportManifest? manifest;
  final ManifestFault? fault;

  /// The number this archive claims, when that is what went wrong.
  final int? schema;

  /// Entries that were present but unusable. Reported, never fatal.
  final int skipped;
}

ManifestResult readExportManifest(String json) {
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return const ManifestResult.failed(ManifestFault.unreadable);
  }
  if (decoded is! Map) {
    return const ManifestResult.failed(ManifestFault.unreadable);
  }

  final schema = decoded['schema'];
  if (schema is! int) {
    return const ManifestResult.failed(ManifestFault.unreadable);
  }
  if (schema > exportSchemaVersion) {
    return ManifestResult.failed(ManifestFault.futureSchema, schema: schema);
  }

  final rawNotes = decoded['notes'];
  if (rawNotes is! List) {
    return const ManifestResult.failed(ManifestFault.unreadable);
  }

  final notes = <ExportedNote>[];
  var skipped = 0;
  for (final entry in rawNotes) {
    final note = ExportedNote.fromJson(entry);
    if (note == null) {
      skipped++;
    } else {
      notes.add(note);
    }
  }

  final appVersion = decoded['appVersion'];
  return ManifestResult.ok(
    ExportManifest(
      schema: schema,
      appVersion: appVersion is String ? appVersion : '',
      exportedAt:
          DateTime.tryParse('${decoded['exportedAt']}')?.toLocal() ??
          DateTime.fromMillisecondsSinceEpoch(0),
      notes: notes,
    ),
    skipped,
  );
}

/// Rejects any path that could escape the folder it is meant to land in.
///
/// Nothing here writes an archive entry to the place its name asks for, but
/// zip-slip is the kind of hole that opens the moment someone adds the feature
/// that does, so entries are refused at the door instead.
bool isSafeArchivePath(String path) {
  if (path.isEmpty || path.length > 240) return false;
  if (path.contains('\u0000')) return false;
  if (path.startsWith('/') || path.startsWith(r'\')) return false;
  // `C:notes/x.md` and `C:/notes/x.md` are both absolute on Windows.
  if (path.length > 1 && path[1] == ':') return false;

  for (final segment in path.split(RegExp(r'[/\\]'))) {
    if (segment.isEmpty || segment == '.' || segment == '..') return false;
  }
  return true;
}

/// Names Windows will not let a file have, whatever the extension.
const _reservedNames = {
  'con',
  'prn',
  'aux',
  'nul',
  'com1',
  'com2',
  'com3',
  'com4',
  'com5',
  'com6',
  'com7',
  'com8',
  'com9',
  'lpt1',
  'lpt2',
  'lpt3',
  'lpt4',
  'lpt5',
  'lpt6',
  'lpt7',
  'lpt8',
  'lpt9',
};

/// Longest slug allowed, so `notes/<slug>-12.md` stays far short of the 260
/// characters Windows stops at even after the user has saved the archive
/// somewhere deep.
const int _slugLimit = 64;

/// A file name for [title], unique among [taken], which it adds itself to.
///
/// [fallbackId] is used when the title slugifies to nothing — an untitled
/// note, or one written entirely in punctuation.
String archiveFileName(String title, String fallbackId, Set<String> taken) {
  var slug = _slugify(title);
  if (slug.isEmpty) {
    final short = fallbackId.replaceAll('-', '');
    slug = 'note-${short.substring(0, short.length < 8 ? short.length : 8)}';
  }
  if (_reservedNames.contains(slug)) slug = 'note-$slug';

  var candidate = slug;
  var suffix = 1;
  while (taken.contains(candidate.toLowerCase())) {
    suffix++;
    final tail = '-$suffix';
    final head = slug.length + tail.length > _slugLimit
        ? slug.substring(0, _slugLimit - tail.length)
        : slug;
    candidate = '$head$tail';
  }
  taken.add(candidate.toLowerCase());
  return '$candidate.md';
}

String _slugify(String title) {
  final out = StringBuffer();
  var pendingDash = false;
  for (final char in title.toLowerCase().split('')) {
    final unit = char.codeUnitAt(0);
    // Control characters, the set Windows forbids, and anything that would
    // make a path separator.
    final forbidden =
        unit < 0x20 || r'<>:"/\|?*.'.contains(char) || char == "'";
    if (forbidden || _isSpace(unit) || char == '-' || char == '_') {
      pendingDash = out.isNotEmpty;
      continue;
    }
    if (pendingDash) {
      out.write('-');
      pendingDash = false;
    }
    if (out.length >= _slugLimit) break;
    out.write(char);
  }
  return out.toString();
}

bool _isSpace(int unit) =>
    unit == 0x20 || unit == 0x09 || unit == 0x0a || unit == 0x0d;
