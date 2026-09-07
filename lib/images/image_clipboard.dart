import 'package:flutter/foundation.dart';
import 'package:pasteboard/pasteboard.dart';

import 'image_codec.dart';

/// What was on the clipboard, if it was a picture.
class ClipboardImage {
  const ClipboardImage({required this.bytes, required this.name});

  final Uint8List bytes;

  /// A name for the ingest to guess a MIME type from. Real when the clipboard
  /// held a file, invented when it held raw pixels.
  final String name;
}

/// Reads an image from the system clipboard, or returns null.
///
/// Two shapes count as an image, and both are ordinary:
///
///   * Raw bitmap data, which is what a screenshot tool puts there. Every
///     platform hands this over as PNG.
///   * A copied *file*, which is what Finder and Explorer put there. Only the
///     path comes across, so it is read from disk by the caller.
///
/// Null covers the common case by far — the clipboard holds text — and is not
/// an error. The caller falls through to an ordinary paste.
class ImageClipboard {
  const ImageClipboard();

  /// Bitmap data on the clipboard, already decoded to bytes.
  Future<ClipboardImage?> readImage() async {
    try {
      final bytes = await Pasteboard.image;
      if (bytes == null || bytes.isEmpty) return null;
      // Every platform's implementation converts to PNG on the way out, so
      // the name is honest about what these bytes are.
      return ClipboardImage(bytes: bytes, name: 'pasted.png');
    } catch (error) {
      debugPrint('KapyNotes: could not read the clipboard: $error');
      return null;
    }
  }

  /// Paths of image files on the clipboard, in the order they were copied.
  Future<List<String>> readImageFiles() async {
    try {
      final paths = await Pasteboard.files();
      return [
        for (final path in paths)
          if (_looksLikeImage(path)) path,
      ];
    } catch (error) {
      debugPrint('KapyNotes: could not read clipboard files: $error');
      return const [];
    }
  }

  static bool _looksLikeImage(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0) return false;
    return supportedImageExtensions.contains(
      path.substring(dot + 1).toLowerCase(),
    );
  }
}
