import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';

import '../data/attachment_limits.dart';
import '../data/blob_store.dart';
import '../data/note_attachment.dart';
import '../sync/aead.dart';
import '../sync/sealed_box.dart';

/// Room left for the nonce, tag and framing sealing adds. The server measures
/// the ciphertext, so a file exactly at the limit would be refused after it
/// had already crossed the network.
const int fileSealingOverhead = 1 + SealedBox.nonceLength + SealedBox.macLength;

int maxFileSourceBytesFor(int attachmentMaxBytes) =>
    attachmentMaxBytes - fileSealingOverhead;

/// How many files one pick or drop may add. Beyond this the rest are named in
/// the toast rather than silently dropped.
const int fileSelectionLimit = 10;

enum FileRejection { tooLarge, tooMany, unreadable, empty, directory }

class FileBatch {
  const FileBatch({required this.files, required this.rejections});

  final List<NoteFileRef> files;
  final List<({String name, FileRejection reason})> rejections;
}

/// Copies picked or dropped files into the blob store and describes them.
///
/// Every check that can be made before bytes move is made first — size from
/// the file system, emptiness — so a 2 GB video picked by mistake is refused
/// in a millisecond rather than after a copy. The size is checked again on the
/// copy itself, because a file can grow between the two and the copy is what
/// will be uploaded.
///
/// Nothing here throws. One unreadable file costs that file, not the batch.
Future<FileBatch> ingestFileAttachments(
  List<XFile> picked, {
  required BlobStore store,
  int attachmentMaxBytes = freeAttachmentMaxBytes,
  int limit = fileSelectionLimit,
}) async {
  final files = <NoteFileRef>[];
  final rejections = <({String name, FileRejection reason})>[];
  final maxBytes = maxFileSourceBytesFor(attachmentMaxBytes);

  for (final file in picked.take(limit)) {
    final name = sanitizeFileName(displayNameOf(file));
    try {
      if (file.path.isNotEmpty &&
          await FileSystemEntity.isDirectory(file.path)) {
        rejections.add((name: name, reason: FileRejection.directory));
        continue;
      }
      final length = await file.length();
      if (length <= 0) {
        rejections.add((name: name, reason: FileRejection.empty));
        continue;
      }
      if (length > maxBytes) {
        rejections.add((name: name, reason: FileRejection.tooLarge));
        continue;
      }

      final hash = await store.importStream(
        file.openRead(),
        extension: fileExtensionOf(name),
      );
      final stored = await store.fileFor(hash);
      final bytes = stored == null ? 0 : await stored.length();
      if (bytes <= 0) {
        rejections.add((name: name, reason: FileRejection.empty));
        continue;
      }
      if (bytes > maxBytes) {
        // Left for the sweep rather than deleted here: the same bytes may
        // already sit in another note under this very hash.
        rejections.add((name: name, reason: FileRejection.tooLarge));
        continue;
      }

      files.add(
        NoteFileRef(
          offset: 0,
          hash: hash,
          key: randomKey(),
          mime: mimeForFile(file, name),
          bytes: bytes,
          name: name,
        ),
      );
    } catch (error) {
      debugPrint('KapyNotes: could not add file $name: $error');
      rejections.add((name: name, reason: FileRejection.unreadable));
    }
  }

  for (final file in picked.skip(limit)) {
    rejections.add((
      name: sanitizeFileName(displayNameOf(file)),
      reason: FileRejection.tooMany,
    ));
  }
  return FileBatch(files: files, rejections: rejections);
}

/// Pickers normally give a display name; some document providers give only a
/// path, which still ends in one.
String displayNameOf(XFile file) {
  if (file.name.isNotEmpty) return file.name;
  final path = file.path.replaceAll('\\', '/');
  final slash = path.lastIndexOf('/');
  return slash < 0 ? path : path.substring(slash + 1);
}

/// The picker's MIME type when it gave a real one, else one guessed from the
/// extension. Only ever used to label the file for the app that opens it.
String mimeForFile(XFile file, String name) {
  final given = file.mimeType;
  if (given != null && given.contains('/') && given.length < 128) return given;
  return _mimeByExtension[fileExtensionOf(name)] ?? 'application/octet-stream';
}

const Map<String, String> _mimeByExtension = {
  '.pdf': 'application/pdf',
  '.txt': 'text/plain',
  '.md': 'text/markdown',
  '.csv': 'text/csv',
  '.json': 'application/json',
  '.zip': 'application/zip',
  '.doc': 'application/msword',
  '.docx':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '.xls': 'application/vnd.ms-excel',
  '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  '.ppt': 'application/vnd.ms-powerpoint',
  '.pptx':
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  '.key': 'application/vnd.apple.keynote',
  '.pages': 'application/vnd.apple.pages',
  '.numbers': 'application/vnd.apple.numbers',
  '.rtf': 'application/rtf',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.heic': 'image/heic',
  '.webp': 'image/webp',
  '.svg': 'image/svg+xml',
  '.mp3': 'audio/mpeg',
  '.m4a': 'audio/mp4',
  '.wav': 'audio/wav',
  '.mp4': 'video/mp4',
  '.mov': 'video/quicktime',
};

String describeFileRejection(
  FileRejection reason, {
  int attachmentMaxBytes = freeAttachmentMaxBytes,
}) => switch (reason) {
  FileRejection.tooLarge =>
    'is larger than the ${attachmentMaxBytes ~/ (1024 * 1024)} MB attachment limit',
  FileRejection.tooMany =>
    'is beyond the $fileSelectionLimit-file selection limit',
  FileRejection.unreadable => 'could not be read',
  FileRejection.empty => 'is empty',
  FileRejection.directory => 'is a folder. Zip it first to attach it',
};

/// "12 KB", "3.4 MB". For a chip, so one decimal at most and never "0 B" for
/// something that exists.
String formatFileSize(int bytes) {
  const kb = 1024;
  const mb = kb * 1024;
  const gb = mb * 1024;
  if (bytes < kb) return '${bytes < 1 ? 1 : bytes} B';
  if (bytes < mb) return '${(bytes / kb).ceil()} KB';
  if (bytes < gb) return _oneDecimal(bytes / mb, 'MB');
  return _oneDecimal(bytes / gb, 'GB');
}

String _oneDecimal(double value, String unit) {
  final text = value >= 100
      ? value.round().toString()
      : value.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');
  return '$text $unit';
}
