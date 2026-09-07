import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../data/note.dart';
import '../data/note_attachment.dart';
import '../data/note_format.dart';
import '../sync/aead.dart' show randomKey;
import 'manifest.dart';
import 'markdown.dart';

/// Writes and reads the `.zip` an export is.
///
/// Both directions are pure functions over bytes so they can run in an
/// isolate — see `ExportService` — and so a test can round-trip an archive
/// without touching a disk or a plugin.

/// What a picture is called inside an archive: its content hash, plus an
/// extension so the file opens by double-clicking it.
String archiveImageName(NoteAttachmentRef ref) =>
    '${ref.hash}${extensionForImageMime(ref.mime)}';

String extensionForImageMime(String mime) => switch (mime) {
  'image/png' => '.png',
  'image/jpeg' => '.jpg',
  'image/webp' => '.webp',
  'image/gif' => '.gif',
  'image/bmp' => '.bmp',
  'image/tiff' => '.tif',
  'image/heic' => '.heic',
  'image/heif' => '.heif',
  _ => '.bin',
};

/// Replaces each U+FFFC in rendered markdown with an ordinary markdown image
/// link, in order.
///
/// Positional rather than offset-based, and safely so: [images] is built from
/// the note's own ordered attachments, and rendering never reorders or removes
/// a placeholder. The result is a file that reads as an illustrated note in
/// any markdown editor, which is the whole point of exporting as markdown.
///
/// A placeholder with no picture behind it — an image this device never
/// downloaded — is dropped rather than written out. U+FFFC must never reach
/// the file: it is invisible in every editor, so it would read as a stray
/// character nobody can see, delete, or explain.
String withImageLinks(String markdown, List<ExportedImage> images) {
  if (!markdown.contains(NoteAttachmentRef.placeholder)) return markdown;
  final buffer = StringBuffer();
  var next = 0;
  for (var i = 0; i < markdown.length; i++) {
    if (markdown.codeUnitAt(i) == 0xFFFC) {
      if (next < images.length) buffer.write('![](../${images[next++].path})');
      continue;
    }
    buffer.writeCharCode(markdown.codeUnitAt(i));
  }
  return buffer.toString();
}

/// The inverse: turns image links back into the placeholder the note stores.
///
/// Recognises exactly what [withImageLinks] writes, and nothing else. A
/// markdown image somebody added by hand in another editor stays as text —
/// there are no bytes in the archive behind it, so inventing an attachment for
/// it would produce a note pointing at a picture that does not exist.
({String markdown, List<String> paths}) withoutImageLinks(String markdown) {
  final paths = <String>[];
  final pattern = RegExp(r'!\[\]\(\.\./(images/[^)\s]+)\)');
  final replaced = markdown.replaceAllMapped(pattern, (match) {
    paths.add(match.group(1)!);
    return NoteAttachmentRef.placeholder;
  });
  return (markdown: replaced, paths: paths);
}

/// Builds the archive for [notes].
///
/// Every note contributes a markdown file under `notes/` and an entry in the
/// manifest. Tombstones are not written: they are sync bookkeeping.
///
/// [imageBytes] maps a content hash to the picture behind it, for every image
/// any note in [notes] holds. Bytes are passed in rather than read here so
/// this stays a pure function over data, testable without a disk — and so the
/// reading, which is I/O, happens before the isolate hop rather than inside
/// it. A hash with no entry is simply left out: the note still exports, and
/// its markdown says an image was there.
Uint8List buildExportArchive({
  required List<Note> notes,
  required String appVersion,
  required DateTime exportedAt,
  Map<String, Uint8List> imageBytes = const {},
}) {
  final archive = Archive();
  final entries = <ExportedNote>[];
  final taken = <String>{};
  final modified = exportedAt.millisecondsSinceEpoch ~/ 1000;

  final files = <ArchiveFile>[];
  // The same picture in four notes is written once.
  final imagePaths = <String>{};

  for (final note in notes) {
    // `Note.title` reports a placeholder for a note with nothing to take a
    // title from. That is a label for a sidebar, not a file name — two of them
    // would only be told apart by a counter — so those fall back to the id.
    final title = note.title == Note.untitled ? '' : note.title;
    final name = archiveFileName(title, note.id, taken);
    final path = '$exportNotesDirectory/$name';

    // Images are woven in after the markdown is rendered, so nothing here has
    // to think about how a placeholder interacts with formatting offsets: at
    // this point the ranges have already been turned into characters.
    final images = <ExportedImage>[];
    for (final ref in note.attachments) {
      // Recordings get their own export path; a kind this build does not know
      // is not something it can write a markdown image link for either.
      if (ref is! NoteImageRef) continue;
      if (!imageBytes.containsKey(ref.hash)) continue;
      images.add(
        ExportedImage(
          hash: ref.hash,
          path: '$exportImagesDirectory/${archiveImageName(ref)}',
          mime: ref.mime,
          width: ref.width,
          height: ref.height,
        ),
      );
    }
    final markdown = withImageLinks(
      renderNoteMarkdown(note.body, note.formats),
      images,
    );

    files.add(ArchiveFile.string(path, markdown)..lastModTime = modified);
    for (final image in images) {
      final bytes = imageBytes[image.hash];
      if (bytes == null || imagePaths.contains(image.path)) continue;
      imagePaths.add(image.path);
      files.add(
        ArchiveFile.bytes(image.path, bytes)..lastModTime = modified,
      );
    }
    entries.add(
      ExportedNote(
        id: note.id,
        path: path,
        updatedAt: note.updatedAt,
        createdAt: note.createdAt.millisecondsSinceEpoch,
        bodyHash: bodyHashOf(markdown),
        formats: note.formats,
        images: images,
      ),
    );
  }

  final manifest = ExportManifest(
    appVersion: appVersion,
    exportedAt: exportedAt,
    notes: entries,
  );
  // The manifest goes in first so a reader can know what it is holding before
  // it walks the rest. It does not rescue a truncated archive — a zip is
  // indexed from its tail, so one that stops early has no readable entries at
  // all — but the partial losses that *are* recoverable, a note whose file is
  // missing or unreadable, are reported per note rather than costing the run.
  archive.add(
    ArchiveFile.string(exportManifestPath, manifest.encode())
      ..lastModTime = modified,
  );
  for (final file in files) {
    archive.add(file);
  }

  return ZipEncoder().encodeBytes(archive);
}

/// Builds an archive from `Note.toJson()` maps.
///
/// The isolate hop wants plain JSON on the wire, and this keeps the decision
/// about what is cheap to send in one place rather than in the caller.
Uint8List buildExportArchiveFromJson({
  required List<Object?> notes,
  required String appVersion,
  required DateTime exportedAt,
  Map<String, Uint8List> imageBytes = const {},
}) => buildExportArchive(
  notes: notes.map(Note.fromJson).whereType<Note>().toList(growable: false),
  appVersion: appVersion,
  exportedAt: exportedAt,
  imageBytes: imageBytes,
);

/// Why an archive could not be opened.
enum ArchiveFault {
  /// Not a zip, or one that stops in the middle. Both are ordinary for a file
  /// that lives in a sync folder.
  unreadable,

  /// A zip, but not one of ours.
  noManifest,

  /// Ours, from a version that knows something this one does not.
  futureSchema,
}

class ArchiveContents {
  const ArchiveContents({
    required this.manifest,
    required this.markdown,
    this.images = const {},
    this.problems = const [],
  }) : fault = null,
       schema = null;

  const ArchiveContents.failed(
    this.fault, {
    this.schema,
    this.problems = const [],
  }) : manifest = null,
       markdown = const {},
       images = const {};

  final ExportManifest? manifest;

  /// Archive path to the markdown found there.
  final Map<String, String> markdown;

  /// Archive path to the picture found there.
  final Map<String, Uint8List> images;

  /// What was wrong but survivable, in words meant for the person importing.
  final List<String> problems;

  final ArchiveFault? fault;

  /// The schema an archive from the future claims, so the message can say it.
  final int? schema;

  bool get isReadable => manifest != null;
}

ArchiveContents readExportArchive(Uint8List bytes) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    // Anything the decoder throws — a bad signature, a truncated central
    // directory, a range error off the end of the buffer — means the same
    // thing to the user, and none of it should reach them as a stack trace.
    return const ArchiveContents.failed(ArchiveFault.unreadable);
  }

  if (archive.files.isEmpty) {
    // A zero-length file decodes to nothing at all rather than throwing, and
    // an empty archive is not something to report as missing a manifest.
    return const ArchiveContents.failed(ArchiveFault.unreadable);
  }

  final problems = <String>[];
  final markdown = <String, String>{};
  final images = <String, Uint8List>{};
  String? manifestJson;
  var unsafe = 0;

  for (final file in archive.files) {
    if (!file.isFile) continue;
    final name = file.name;
    if (!isSafeArchivePath(name)) {
      // Zip-slip. Refused at the door rather than on the way to disk.
      unsafe++;
      continue;
    }

    final data = file.readBytes();
    if (data == null) continue;

    // Pictures are read as bytes and never decoded as text, which is the
    // whole reason this branch comes first.
    if (name.startsWith('$exportImagesDirectory/')) {
      images[name] = Uint8List.fromList(data);
      continue;
    }

    final String text;
    try {
      text = utf8.decode(data);
    } on FormatException {
      problems.add('$name is not text and was skipped.');
      continue;
    }

    if (name == exportManifestPath) {
      manifestJson = text;
    } else if (name.startsWith('$exportNotesDirectory/')) {
      markdown[name] = text;
    }
  }

  if (unsafe > 0) {
    problems.add(
      '$unsafe ${unsafe == 1 ? 'entry' : 'entries'} had an unsafe path and '
      'were ignored.',
    );
  }

  if (manifestJson == null) {
    return ArchiveContents.failed(ArchiveFault.noManifest, problems: problems);
  }

  final result = readExportManifest(manifestJson);
  if (result.manifest == null) {
    return ArchiveContents.failed(
      result.fault == ManifestFault.futureSchema
          ? ArchiveFault.futureSchema
          : ArchiveFault.unreadable,
      schema: result.schema,
      problems: problems,
    );
  }
  if (result.skipped > 0) {
    problems.add(
      '${result.skipped} ${result.skipped == 1 ? 'note was' : 'notes were'} '
      'listed in a way this version could not read.',
    );
  }

  final listed = {for (final note in result.manifest!.notes) note.path};
  final stray = markdown.keys.where((path) => !listed.contains(path)).length;
  if (stray > 0) {
    problems.add(
      '$stray markdown ${stray == 1 ? 'file was' : 'files were'} not listed in '
      'the manifest and were skipped.',
    );
  }

  return ArchiveContents(
    manifest: result.manifest,
    markdown: markdown,
    images: images,
    problems: problems,
  );
}

/// Reads an archive from bytes that arrived as a plain list, for the isolate.
ArchiveContents readExportArchiveFromBytes(List<int> bytes) =>
    readExportArchive(Uint8List.fromList(bytes));

/// The note [entry] describes, or null if its markdown is missing.
///
/// The manifest is authoritative while it still matches the file. Once the
/// hash disagrees, somebody has edited the markdown by hand and their edit is
/// the newer intent, so the ranges are re-read from the text instead.
({Note note, bool handEdited})? noteFromArchive(
  ExportedNote entry,
  Map<String, String> markdown, {
  Set<String> availableImages = const {},
}) {
  final source = markdown[entry.path];
  if (source == null) return null;

  final handEdited = bodyHashOf(source) != entry.bodyHash;

  // Image links become placeholders again *before* parsing, so the format
  // ranges recorded against the original body still line up: one link becomes
  // exactly the one character it was rendered from.
  final stripped = withoutImageLinks(source);
  final parsed = parseNoteMarkdown(stripped.markdown);
  final formats = handEdited ? parsed.formats : entry.formats;

  // Paired by archive path, not by position: a link the reader could not find
  // bytes for drops out, and the placeholder it left behind is cleaned up by
  // the same rule that governs every other orphan.
  final byPath = {for (final image in entry.images) image.path: image};
  final attachments = <NoteAttachmentRef>[];
  var anchor = 0;
  for (final path in stripped.paths) {
    anchor = parsed.body.indexOf(NoteAttachmentRef.placeholder, anchor);
    if (anchor < 0) break;
    final image = byPath[path];
    if (image != null && availableImages.contains(path)) {
      attachments.add(
        NoteImageRef(
          offset: anchor,
          hash: image.hash,
          // A fresh key. The archive carried none, and this device is the
          // only place this copy of the picture has ever lived.
          key: randomKey(),
          mime: image.mime,
          width: image.width,
          height: image.height,
          bytes: 0,
        ),
      );
    }
    anchor++;
  }

  final body = parsed.body;
  return (
    note: Note(
      id: entry.id,
      body: body,
      formats: normalizeNoteFormats(formats, body.length),
      attachments: normalizeNoteAttachments(attachments, body),
      createdAt: DateTime.fromMillisecondsSinceEpoch(entry.createdAt),
      updatedAt: entry.updatedAt,
    ),
    handEdited: handEdited,
  );
}
