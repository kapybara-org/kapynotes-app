import 'dart:io';
import 'dart:math' as math;

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
  final List<({String name, FileRejection reason, int bytes})> rejections;
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
  final rejections = <({String name, FileRejection reason, int bytes})>[];
  final maxBytes = maxFileSourceBytesFor(attachmentMaxBytes);

  for (final file in picked.take(limit)) {
    final name = sanitizeFileName(displayNameOf(file));
    try {
      if (file.path.isNotEmpty &&
          await FileSystemEntity.isDirectory(file.path)) {
        rejections.add((name: name, reason: FileRejection.directory, bytes: 0));
        continue;
      }
      final length = await file.length();
      if (length <= 0) {
        rejections.add((name: name, reason: FileRejection.empty, bytes: 0));
        continue;
      }
      if (length > maxBytes) {
        rejections.add((
          name: name,
          reason: FileRejection.tooLarge,
          bytes: length,
        ));
        continue;
      }

      final hash = await store.importStream(
        file.openRead(),
        extension: fileExtensionOf(name),
      );
      final stored = await store.fileFor(hash);
      final bytes = stored == null ? 0 : await stored.length();
      if (bytes <= 0) {
        rejections.add((name: name, reason: FileRejection.empty, bytes: 0));
        continue;
      }
      if (bytes > maxBytes) {
        // Left for the sweep rather than deleted here: the same bytes may
        // already sit in another note under this very hash.
        rejections.add((
          name: name,
          reason: FileRejection.tooLarge,
          bytes: bytes,
        ));
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
      rejections.add((name: name, reason: FileRejection.unreadable, bytes: 0));
    }
  }

  for (final file in picked.skip(limit)) {
    rejections.add((
      name: sanitizeFileName(displayNameOf(file)),
      reason: FileRejection.tooMany,
      bytes: 0,
    ));
  }
  return FileBatch(files: files, rejections: rejections);
}

/// The photo library's iPhone picker copies a clip to a temporary file named
/// "image_picker_" and a long random id before its real name.
final RegExp _pickerCopyPrefix = RegExp(
  r'^image_picker_[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}-\d+-[0-9A-Fa-f]{16}',
);

/// Pickers normally give a display name; some document providers give only a
/// path, which still ends in one. A picker's temporary copy is named by what
/// it was copied from.
String displayNameOf(XFile file) {
  var name = file.name;
  if (name.isEmpty) {
    final path = file.path.replaceAll('\\', '/');
    final slash = path.lastIndexOf('/');
    name = slash < 0 ? path : path.substring(slash + 1);
  }
  final original = name.replaceFirst(_pickerCopyPrefix, '');
  return original.isEmpty ? name : original;
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

/// Who a refusal is about: the file's own name, or [fallback] when a picker
/// gave only the name of its temporary copy.
String rejectionSubject(String name, String fallback) =>
    name.isEmpty || name.startsWith('image_picker_') ? fallback : name;

/// "big.mp4 (300 MB) is too big to add. Videos can be up to 25 MB. Try a
/// shorter clip." Said alike for a video, a file and the camera's review.
/// [others] more were refused for the same reason.
String tooBigMessage({
  required String subject,
  required int bytes,
  required int others,
  required String kind,
  required int attachmentMaxBytes,
  required String adjective,
  required String noun,
}) {
  final what = others > 0
      ? '$subject and $others ${others == 1 ? 'other' : 'others'} are too big'
      : bytes > 0
      ? '$subject (${formatSizeOver(bytes, attachmentMaxBytes)}) is too big'
      : '$subject is too big';
  final advice = others > 0 ? '$adjective ${noun}s' : 'a $adjective $noun';
  return '$what to add. $kind can be up to '
      '${attachmentMaxBytes ~/ (1024 * 1024)} MB. Try $advice.';
}

/// What a toast says for a file that could not be added. [others] more were
/// refused for the same reason.
String describeFileRejection(
  FileRejection reason, {
  String name = '',
  int others = 0,
  int bytes = 0,
  int attachmentMaxBytes = freeAttachmentMaxBytes,
}) {
  final subject = rejectionSubject(name, 'This file');
  final more = others > 0 ? ' $others more could not be added.' : '';
  return switch (reason) {
    FileRejection.tooLarge => tooBigMessage(
      subject: subject,
      bytes: bytes,
      others: others,
      kind: 'Files',
      attachmentMaxBytes: attachmentMaxBytes,
      adjective: 'smaller',
      noun: 'file',
    ),
    FileRejection.tooMany =>
      '$subject is beyond the $fileSelectionLimit-file selection limit.$more',
    FileRejection.unreadable => '$subject could not be read.$more',
    FileRejection.empty => '$subject is empty.$more',
    FileRejection.directory =>
      '$subject is a folder. Zip it first to attach it.$more',
  };
}

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

/// A refused size, rounded up a tenth so that it always reads as more than the
/// limit it was refused by.
String formatSizeOver(int bytes, int limit) {
  const tenth = 1024 * 1024 / 10;
  return formatFileSize(
    ((math.max(bytes, limit + 1) / tenth).ceil() * tenth).ceil(),
  );
}

String _oneDecimal(double value, String unit) {
  final text = value >= 100
      ? value.round().toString()
      : value.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');
  return '$text $unit';
}
