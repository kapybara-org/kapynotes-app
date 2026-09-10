import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../core/file_export.dart';
import '../core/platform.dart';
import '../data/note.dart';
import '../data/blob_store.dart';
import 'archive.dart';

/// Picks a place, and moves the bytes.
///
/// Everything that knows what an archive *is* lives in `archive.dart` as pure
/// functions over bytes. This is the half that needs a disk and a file picker,
/// kept separate so the format can be tested without either.

const _zipTypes = [
  XTypeGroup(
    label: 'Kapy Notes export',
    extensions: ['zip'],
    mimeTypes: ['application/zip'],
  ),
];

enum ExportStatus { written, cancelled, failed }

class ExportResult {
  const ExportResult(
    this.status, {
    this.path,
    this.noteCount = 0,
    this.error,
    this.chosenByUser = true,
  });

  final ExportStatus status;

  /// Where it landed.
  final String? path;

  /// Whether the person exporting picked the place. False only where the
  /// system's own save UI could not be reached and the app fell back to a
  /// folder of its own — the one case where the message afterwards has to
  /// name a location, because nobody else knows it.
  final bool chosenByUser;

  final int noteCount;
  final String? error;
}

class NoteArchiveService {
  NoteArchiveService({@visibleForTesting DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  String? _appVersion;

  /// Every picture the given notes refer to, by hash, skipping any this
  /// device does not hold. A missing image costs its note nothing.
  Future<Map<String, Uint8List>> _readImages(
    List<Note> notes,
    BlobStore? images,
  ) async {
    if (images == null) return const {};
    final wanted = {
      for (final note in notes)
        for (final ref in note.attachments) ref.hash,
    };
    final bytes = <String, Uint8List>{};
    for (final hash in wanted) {
      final data = await images.read(hash);
      if (data != null) bytes[hash] = data;
    }
    return bytes;
  }

  Future<String> _version() async {
    if (_appVersion != null) return _appVersion!;
    try {
      _appVersion = (await PackageInfo.fromPlatform()).version;
    } catch (_) {
      // A test or a platform without the plugin. The manifest records what
      // wrote the archive; an empty string is honest about not knowing.
      _appVersion = '';
    }
    return _appVersion!;
  }

  /// Writes every note in [notes] to a `.zip` the user chooses.
  ///
  /// The choosing is the system's, on every platform. The desktops open a real
  /// save dialog before anything is built; the phones have no such dialog for
  /// a file the app is producing, so the archive is built into a temporary
  /// file and handed to the picker that *is* native there — see [FileExport].
  ///
  /// [images] is where the pictures are read from. Null leaves them out, which
  /// is what a build with no image store wants and what every export did
  /// before there were any.
  Future<ExportResult> exportNotes(
    List<Note> notes, {
    BlobStore? images,
  }) async {
    final at = _now();
    final name = suggestedExportName(at);
    return AppPlatform.isDesktop
        ? _exportToChosenPath(notes, images, at, name)
        : _exportThroughSystemPicker(notes, images, at, name);
  }

  /// Desktop: ask first, then write straight into the answer.
  Future<ExportResult> _exportToChosenPath(
    List<Note> notes,
    BlobStore? images,
    DateTime at,
    String name,
  ) async {
    final String path;
    try {
      final location = await getSaveLocation(
        suggestedName: name,
        acceptedTypeGroups: _zipTypes,
      );
      if (location == null) return const ExportResult(ExportStatus.cancelled);
      path = location.path;
    } catch (error, stack) {
      debugPrint(
        'KapyNotes: could not choose an export location: $error\n$stack',
      );
      return const ExportResult(
        ExportStatus.failed,
        error: 'Kapy Notes could not open a save dialog.',
      );
    }

    try {
      final bytes = await _build(notes, images, at);
      await File(path).writeAsBytes(bytes, flush: true);
      return ExportResult(
        ExportStatus.written,
        path: path,
        noteCount: notes.length,
      );
    } catch (error, stack) {
      debugPrint('KapyNotes: export failed: $error\n$stack');
      return const ExportResult(
        ExportStatus.failed,
        error: 'Kapy Notes could not write the export.',
      );
    }
  }

  /// Phones: build it, then let the system's picker put it where it is asked.
  ///
  /// Backwards from the desktop order, and unavoidably so — iOS copies the
  /// file it is given and Android fills a stream from one, so on both the
  /// archive has to exist before the question can be asked. The temporary copy
  /// is removed either way, including after a cancel.
  Future<ExportResult> _exportThroughSystemPicker(
    List<Note> notes,
    BlobStore? images,
    DateTime at,
    String name,
  ) async {
    final File temporary;
    try {
      final bytes = await _build(notes, images, at);
      final directory = await getTemporaryDirectory();
      temporary = File('${directory.path}/$name');
      await temporary.writeAsBytes(bytes, flush: true);
    } catch (error, stack) {
      debugPrint('KapyNotes: export failed: $error\n$stack');
      return const ExportResult(
        ExportStatus.failed,
        error: 'Kapy Notes could not write the export.',
      );
    }

    try {
      final result = await FileExport.save(
        path: temporary.path,
        suggestedName: name,
        mimeType: 'application/zip',
      );
      switch (result.outcome) {
        case FileExportOutcome.cancelled:
          return const ExportResult(ExportStatus.cancelled);
        case FileExportOutcome.saved:
          return ExportResult(
            ExportStatus.written,
            path: result.name,
            noteCount: notes.length,
          );
        case FileExportOutcome.failed:
          return const ExportResult(
            ExportStatus.failed,
            error: 'Kapy Notes could not save the export.',
          );
        case FileExportOutcome.unsupported:
          // Awaited, not returned: the copy has to finish before the `finally`
          // below removes the file it is copying from.
          return await _keepInDocuments(temporary, name, notes.length);
      }
    } finally {
      // Only after the platform is done with it — both pickers read the file
      // before they answer — and awaited, so an export that has returned has
      // left nothing of itself in the cache.
      await _discard(temporary);
    }
  }

  /// The old behaviour, kept for a build whose picker cannot be reached at
  /// all: the archive goes to the app's own documents folder, which is
  /// visible in Files and in the Android file manager, and the caller says so
  /// because nobody chose it.
  Future<ExportResult> _keepInDocuments(
    File temporary,
    String name,
    int noteCount,
  ) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final destination = '${directory.path}/$name';
      await temporary.copy(destination);
      return ExportResult(
        ExportStatus.written,
        path: destination,
        noteCount: noteCount,
        chosenByUser: false,
      );
    } catch (error, stack) {
      debugPrint('KapyNotes: export failed: $error\n$stack');
      return const ExportResult(
        ExportStatus.failed,
        error: 'Kapy Notes could not write the export.',
      );
    }
  }

  Future<void> _discard(File temporary) async {
    try {
      if (await temporary.exists()) await temporary.delete();
    } catch (error) {
      // A leftover in the cache directory is the system's to clean up.
      debugPrint('KapyNotes: could not remove the temporary export: $error');
    }
  }

  /// Renders every note and deflates the result.
  ///
  /// Off the thread the user is typing on: this is the one part of the feature
  /// that can take a visible moment. Images are read here rather than in the
  /// isolate — that is disk I/O, and the archive builder is a pure function
  /// over bytes precisely so it does not have to care where they came from.
  Future<Uint8List> _build(
    List<Note> notes,
    BlobStore? images,
    DateTime at,
  ) async {
    final json = notes.map((note) => note.toJson()).toList(growable: false);
    final version = await _version();
    final imageBytes = await _readImages(notes, images);
    return Isolate.run(
      () => buildExportArchiveFromJson(
        notes: json,
        appVersion: version,
        exportedAt: at,
        imageBytes: imageBytes,
      ),
    );
  }

  /// Asks for an archive and reads it. Null when the user backed out.
  Future<ArchiveContents?> openArchive() async {
    final XFile? file;
    try {
      file = await openFile(acceptedTypeGroups: _zipTypes);
    } catch (error, stack) {
      debugPrint('KapyNotes: could not open a file picker: $error\n$stack');
      return const ArchiveContents.failed(ArchiveFault.unreadable);
    }
    if (file == null) return null;

    try {
      final bytes = await file.readAsBytes();
      return await Isolate.run(() => readExportArchiveFromBytes(bytes));
    } catch (error, stack) {
      debugPrint('KapyNotes: could not read the archive: $error\n$stack');
      return const ArchiveContents.failed(ArchiveFault.unreadable);
    }
  }
}

/// `KapyNotes-export-2026-09-05.zip`.
String suggestedExportName(DateTime at) {
  final local = at.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return 'KapyNotes-export-${local.year}-$month-$day.zip';
}
