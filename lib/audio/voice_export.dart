import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/file_export.dart';
import '../core/platform.dart';
import '../data/note_attachment.dart';

/// What became of a recording's audio offered to save.
enum VoiceExportOutcome {
  /// Written where the person chose.
  done,

  /// They closed the save panel or picker. Nothing to say.
  cancelled,

  /// This device does not have the audio and could not fetch it.
  notDownloaded,

  /// Something went wrong on the way.
  failed,
}

/// Where a computer's save panel put the file, or null for a cancel. A
/// hook so a test can answer for the panel.
@visibleForTesting
Future<String?> Function(String suggestedName) voiceSaveLocation =
    (suggestedName) async =>
        (await getSaveLocation(suggestedName: suggestedName))?.path;

/// The folder a phone's copy is made in for the system picker to read. A
/// hook so a test can keep it out of the real temporary folder.
@visibleForTesting
Future<Directory> Function() voiceSaveFolder = () async =>
    Directory('${(await getTemporaryDirectory()).path}/kapy-voice');

/// Saves a copy of a recording's audio where the person chooses, named
/// [title]: a save panel on a computer, "Save to Files" on iOS, the document
/// picker on Android.
///
/// [locate] finds the audio, fetching it first when it was recorded on
/// another device. Never throws.
Future<VoiceExportOutcome> exportVoiceAudio({
  required Future<File?> Function() locate,
  required String title,
}) async {
  final name = '${_fileTitle(title)}${NoteVoiceRef.voiceExtension}';
  try {
    final audio = await locate();
    if (audio == null) return VoiceExportOutcome.notDownloaded;

    if (AppPlatform.isDesktop) {
      final path = await voiceSaveLocation(name);
      if (path == null) return VoiceExportOutcome.cancelled;
      try {
        await audio.copy(path);
      } catch (_) {
        // A copy that failed halfway is not left under the chosen name.
        try {
          await File(path).delete();
        } catch (_) {}
        rethrow;
      }
      return VoiceExportOutcome.done;
    }

    // The picker copies from a file under the name it offers, so the blob
    // is copied out under the recording's name first, and deleted once the
    // picker has answered.
    final folder = await voiceSaveFolder();
    await folder.create(recursive: true);
    final copy = await audio.copy('${folder.path}/$name');
    try {
      final result = await FileExport.save(
        path: copy.path,
        suggestedName: name,
        mimeType: NoteVoiceRef.voiceMime,
      );
      return switch (result.outcome) {
        FileExportOutcome.saved => VoiceExportOutcome.done,
        FileExportOutcome.cancelled => VoiceExportOutcome.cancelled,
        FileExportOutcome.unsupported ||
        FileExportOutcome.failed => VoiceExportOutcome.failed,
      };
    } finally {
      try {
        await copy.delete();
      } catch (_) {}
    }
  } catch (error) {
    // The type only: a path here carries the recording's title.
    debugPrint('KapyNotes: could not export a recording: ${error.runtimeType}');
    return VoiceExportOutcome.failed;
  }
}

/// [title] as a file name every platform accepts.
String _fileTitle(String title) {
  final cleaned = title
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (cleaned.isEmpty || cleaned.startsWith('.')) return 'Voice note';
  return cleaned.length > 80 ? cleaned.substring(0, 80).trim() : cleaned;
}
