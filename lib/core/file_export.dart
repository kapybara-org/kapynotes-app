import 'package:flutter/services.dart';

/// What became of a file offered to the system's own save UI.
enum FileExportOutcome {
  /// The user picked a place and the bytes are there.
  saved,

  /// They backed out. Nothing was written and nothing needs saying.
  cancelled,

  /// No handler answered. The caller falls back to a folder of its own —
  /// losing the export entirely would be the worse failure.
  unsupported,

  /// The platform tried and could not.
  failed,
}

class FileExportResult {
  const FileExportResult(this.outcome, {this.name});

  final FileExportOutcome outcome;

  /// What the destination ended up being called, where the platform says. The
  /// user chose it, so this is for the record rather than for telling them.
  final String? name;
}

/// "Where do you want this?", asked by the operating system rather than drawn
/// by the app.
///
/// The desktops already have this in `file_selector`: a real NSSavePanel,
/// IFileSaveDialog or GtkFileChooser. The phones have nothing behind that
/// package's `getSaveLocation` — it throws — which is why an export on a phone
/// used to land in the app's documents folder without anybody being asked.
/// This is the phones' equivalent, and it is deliberately *their* UI:
///
/// - iOS presents `UIDocumentPickerViewController(forExporting:)`, the same
///   "Save to Files" sheet every other app uses.
/// - Android fires `ACTION_CREATE_DOCUMENT`, the Storage Access Framework
///   picker, and writes into the document it hands back.
///
/// Both want the file to exist before they are asked — iOS copies from a URL,
/// Android fills a stream from one — so the caller writes a temporary file and
/// offers that.
class FileExport {
  const FileExport._();

  static const MethodChannel channel = MethodChannel('kapynotes/file_export');

  /// Offers the file at [path] under [suggestedName], and answers what
  /// happened. Never throws.
  static Future<FileExportResult> save({
    required String path,
    required String suggestedName,
    String mimeType = 'application/octet-stream',
  }) async {
    try {
      final name = await channel.invokeMethod<String>('save', {
        'path': path,
        'suggestedName': suggestedName,
        'mimeType': mimeType,
      });
      // Null is the cancel: every platform here can report a dismissal, and
      // none of them can name a file that was never created.
      return name == null
          ? const FileExportResult(FileExportOutcome.cancelled)
          : FileExportResult(FileExportOutcome.saved, name: name);
    } on MissingPluginException {
      return const FileExportResult(FileExportOutcome.unsupported);
    } on PlatformException {
      return const FileExportResult(FileExportOutcome.failed);
    } catch (_) {
      // A unit test with no binding behind the channel throws neither of the
      // above, and an export must not fail on the way to asking a question.
      return const FileExportResult(FileExportOutcome.unsupported);
    }
  }
}
