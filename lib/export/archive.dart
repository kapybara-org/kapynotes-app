import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../data/note.dart';
import '../data/note_format.dart';
import 'manifest.dart';
import 'markdown.dart';

/// Writes and reads the `.zip` an export is.
///
/// Both directions are pure functions over bytes so they can run in an
/// isolate — see `ExportService` — and so a test can round-trip an archive
/// without touching a disk or a plugin.

/// Builds the archive for [notes].
///
/// Every note contributes a markdown file under `notes/` and an entry in the
/// manifest. Nothing else is written: tombstones are sync bookkeeping, and
/// there are no attachments to collect until the app can make one.
Uint8List buildExportArchive({
  required List<Note> notes,
  required String appVersion,
  required DateTime exportedAt,
}) {
  final archive = Archive();
  final entries = <ExportedNote>[];
  final taken = <String>{};
  final modified = exportedAt.millisecondsSinceEpoch ~/ 1000;

  final files = <ArchiveFile>[];

  for (final note in notes) {
    // `Note.title` reports a placeholder for a note with nothing to take a
    // title from. That is a label for a sidebar, not a file name — two of them
    // would only be told apart by a counter — so those fall back to the id.
    final title = note.title == Note.untitled ? '' : note.title;
    final name = archiveFileName(title, note.id, taken);
    final path = '$exportNotesDirectory/$name';
    final markdown = renderNoteMarkdown(note.body, note.formats);

    files.add(ArchiveFile.string(path, markdown)..lastModTime = modified);
    entries.add(
      ExportedNote(
        id: note.id,
        path: path,
        updatedAt: note.updatedAt,
        createdAt: note.createdAt.millisecondsSinceEpoch,
        bodyHash: bodyHashOf(markdown),
        formats: note.formats,
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
}) => buildExportArchive(
  notes: notes.map(Note.fromJson).whereType<Note>().toList(growable: false),
  appVersion: appVersion,
  exportedAt: exportedAt,
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
    this.problems = const [],
  }) : fault = null,
       schema = null;

  const ArchiveContents.failed(
    this.fault, {
    this.schema,
    this.problems = const [],
  }) : manifest = null,
       markdown = const {};

  final ExportManifest? manifest;

  /// Archive path to the markdown found there.
  final Map<String, String> markdown;

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
  Map<String, String> markdown,
) {
  final source = markdown[entry.path];
  if (source == null) return null;

  final handEdited = bodyHashOf(source) != entry.bodyHash;
  final parsed = parseNoteMarkdown(source);
  final formats = handEdited ? parsed.formats : entry.formats;

  return (
    note: Note(
      id: entry.id,
      body: parsed.body,
      formats: normalizeNoteFormats(formats, parsed.body.length),
      createdAt: DateTime.fromMillisecondsSinceEpoch(entry.createdAt),
      updatedAt: entry.updatedAt,
    ),
    handEdited: handEdited,
  );
}
