import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'file_export.dart';
import 'platform.dart';

/// Saves a small plain-text file through the platform's native file UI.
///
/// Desktop platforms can write straight to the location chosen in the save
/// panel. Phones first create the source file their document picker requires,
/// then remove that temporary copy as soon as the picker is finished.
typedef TextFileSaver =
    Future<FileExportOutcome> Function({
      required String contents,
      required String suggestedName,
    });

class TextFileExport {
  const TextFileExport._();

  static const _textTypes = [
    XTypeGroup(
      label: 'Text file',
      extensions: ['txt'],
      mimeTypes: ['text/plain'],
    ),
  ];

  static Future<FileExportOutcome> save({
    required String contents,
    required String suggestedName,
  }) async {
    if (AppPlatform.isDesktop) {
      try {
        final location = await getSaveLocation(
          suggestedName: suggestedName,
          acceptedTypeGroups: _textTypes,
        );
        if (location == null) return FileExportOutcome.cancelled;
        await File(location.path).writeAsString(contents, flush: true);
        return FileExportOutcome.saved;
      } catch (error, stack) {
        debugPrint('KapyNotes: could not save text file: $error\n$stack');
        return FileExportOutcome.failed;
      }
    }

    File? temporary;
    try {
      final directory = await getTemporaryDirectory();
      temporary = File('${directory.path}/$suggestedName');
      await temporary.writeAsString(contents, flush: true);
      return (await FileExport.save(
        path: temporary.path,
        suggestedName: suggestedName,
        mimeType: 'text/plain',
      )).outcome;
    } catch (error, stack) {
      debugPrint('KapyNotes: could not save text file: $error\n$stack');
      return FileExportOutcome.failed;
    } finally {
      try {
        if (temporary != null && await temporary.exists()) {
          await temporary.delete();
        }
      } catch (_) {
        // The exported copy is already safe. A temporary-file cleanup failure
        // must not turn that successful save into an error.
      }
    }
  }
}
