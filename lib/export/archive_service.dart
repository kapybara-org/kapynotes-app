import 'dart:io';
import 'dart:isolate';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../core/platform.dart';
import '../data/note.dart';
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
  const ExportResult(this.status, {this.path, this.noteCount = 0, this.error});

  final ExportStatus status;

  /// Where it landed. Shown to the user, because on a phone they did not
  /// choose it.
  final String? path;

  final int noteCount;
  final String? error;
}

class NoteArchiveService {
  NoteArchiveService({@visibleForTesting DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  String? _appVersion;

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
  Future<ExportResult> exportNotes(List<Note> notes) async {
    final at = _now();
    final String path;
    try {
      final chosen = await _destination(suggestedExportName(at));
      if (chosen == null) return const ExportResult(ExportStatus.cancelled);
      path = chosen;
    } catch (error, stack) {
      debugPrint(
        'KapyNotes: could not choose an export location: $error\n$stack',
      );
      return ExportResult(
        ExportStatus.failed,
        error: 'Kapy Notes could not open a save dialog.',
      );
    }

    try {
      final json = notes.map((note) => note.toJson()).toList(growable: false);
      final version = await _version();
      // Rendering every note and deflating the result is the one part of this
      // feature that can take a visible moment, so it happens off the thread
      // the user is typing on.
      final bytes = await Isolate.run(
        () => buildExportArchiveFromJson(
          notes: json,
          appVersion: version,
          exportedAt: at,
        ),
      );
      await File(path).writeAsBytes(bytes, flush: true);
      return ExportResult(
        ExportStatus.written,
        path: path,
        noteCount: notes.length,
      );
    } catch (error, stack) {
      debugPrint('KapyNotes: export failed: $error\n$stack');
      return ExportResult(
        ExportStatus.failed,
        error: 'Kapy Notes could not write the export.',
      );
    }
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

  /// Where the archive goes, or null if the user cancelled.
  ///
  /// Desktop gets a real save dialog. The phones have no such thing for a file
  /// the app is producing, so it goes into the app's own documents folder —
  /// visible in Files and in the Android file manager — and the path is shown
  /// afterwards so it can be found.
  Future<String?> _destination(String name) async {
    if (AppPlatform.isDesktop) {
      final location = await getSaveLocation(
        suggestedName: name,
        acceptedTypeGroups: _zipTypes,
      );
      return location?.path;
    }
    final directory = await getApplicationDocumentsDirectory();
    return '${directory.path}/$name';
  }
}

/// `KapyNotes-export-2026-09-05.zip`.
String suggestedExportName(DateTime at) {
  final local = at.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return 'KapyNotes-export-${local.year}-$month-$day.zip';
}
