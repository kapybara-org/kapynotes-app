import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';

typedef AttachmentFileAcquirer = Future<List<XFile>> Function();

/// Opens the platform's own "choose files" UI with no type filter: the Files
/// app on iOS, the document picker on Android, an open panel on the desktops.
/// A cancelled or failed picker is an empty list, never an error.
Future<List<XFile>> acquireAttachmentFiles() async {
  try {
    return await openFiles();
  } catch (error) {
    debugPrint('KapyNotes: file picker failed: $error');
    return const [];
  }
}
