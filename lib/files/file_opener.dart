import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/file_export.dart';
import '../core/platform.dart';
import '../data/blob_store.dart';
import '../data/note_attachment.dart';
import '../images/note_image_provider.dart';

enum FileHandoffOutcome {
  /// Handed to another app, or written where the user chose.
  done,

  /// The user closed the save panel. Nothing to say.
  cancelled,

  /// This device does not have the bytes and could not fetch them — offline,
  /// signed out, or the upload never finished on the device that has them.
  notDownloaded,

  /// A program, which this app will not launch. Saving it is still offered.
  blocked,

  /// Something else went wrong on the way.
  failed,
}

/// Extensions that run something when "opened". A note is a place people
/// paste things from other people, so a click on a chip must never be the
/// thing that executes one; the file can still be saved and run deliberately.
const Set<String> _executableExtensions = {
  '.app',
  '.bat',
  '.cmd',
  '.com',
  '.command',
  '.cpl',
  '.dll',
  '.exe',
  '.hta',
  '.jar',
  '.js',
  '.jse',
  '.lnk',
  '.msc',
  '.msi',
  '.msp',
  '.pif',
  '.ps1',
  '.reg',
  '.scr',
  '.sh',
  '.url',
  '.vb',
  '.vbe',
  '.vbs',
  '.workflow',
  '.wsf',
  '.wsh',
  '.apk',
  '.pkg',
  '.dmg',
  '.appimage',
  '.deb',
  '.rpm',
  '.run',
  '.desktop',
  // macOS: scripts, Terminal and installer documents, and links that open
  // whatever they point at.
  '.tool',
  '.terminal',
  '.scpt',
  '.scptd',
  '.applescript',
  '.fileloc',
  '.inetloc',
  '.webloc',
  '.mpkg',
  '.prefpane',
  // Windows: installers, help and shell files that run what they hold, disk
  // images that mount with programs inside, and scripts a runtime may be
  // associated with.
  '.chm',
  '.msix',
  '.msixbundle',
  '.appx',
  '.appxbundle',
  '.appinstaller',
  '.application',
  '.appref-ms',
  '.settingcontent-ms',
  '.library-ms',
  '.search-ms',
  '.diagcab',
  '.gadget',
  '.inf',
  '.ins',
  '.isp',
  '.jnlp',
  '.iso',
  '.img',
  '.vhd',
  '.vhdx',
  '.xll',
  '.py',
  '.pyw',
  '.pl',
  '.rb',
  '.wsc',
  '.sct',
  '.scf',
  '.psm1',
  '.psd1',
  '.ps1xml',
  '.website',
};

/// Whether [ref] is a program, or something that runs one when opened.
///
/// Read off the name itself as well as [NoteFileRef.extension], which only
/// admits plain letters and digits: `.appref-ms` has neither shape, and would
/// otherwise open.
bool isExecutableFile(NoteFileRef ref) {
  if (_executableExtensions.contains(ref.extension)) return true;
  final name = ref.name.toLowerCase();
  return _executableExtensions.any(name.endsWith);
}

/// Whether "Open" means anything here. Phones have no "open with the default
/// app" for an arbitrary file, so there the chip saves instead.
bool get canOpenAttachmentFiles => AppPlatform.isDesktop;

/// Where [ref]'s bytes are on this device, downloading them first if needed.
/// Null when they are neither here nor fetchable.
Future<File?> locateAttachmentFile(
  NoteFileRef ref, {
  required BlobStore store,
  NoteImageFetcher? fetch,
}) async {
  final local = await store.fileFor(ref.hash);
  if (local != null || fetch == null) return local;
  final bytes = await fetch(ref.hash);
  if (bytes == null) return null;
  final kept = await store.fileFor(ref.hash);
  if (kept != null) return kept;
  if (BlobStore.hashOf(bytes) != ref.hash) return null;
  await store.put(bytes, extension: ref.extension);
  return store.fileFor(ref.hash);
}

/// Opens [ref] in whatever app the system uses for its type.
///
/// Always through a copy, never the stored blob. The store names files by the
/// checksum of their contents; an editor that saved changes into that file
/// would leave bytes that no longer match their own name, and the next upload
/// would send a file the other devices refuse. The copy also carries the real
/// file name, so the app that opens it shows "Invoice.pdf" and not a hash.
Future<FileHandoffOutcome> openAttachmentFile(
  NoteFileRef ref, {
  required BlobStore store,
  NoteImageFetcher? fetch,
  Future<bool> Function(Uri uri)? launch,
}) async {
  if (isExecutableFile(ref)) return FileHandoffOutcome.blocked;
  try {
    final blob = await locateAttachmentFile(ref, store: store, fetch: fetch);
    if (blob == null) return FileHandoffOutcome.notDownloaded;
    final copy = await _handoffCopy(ref, blob);
    final opened = await (launch ?? launchUrl)(Uri.file(copy.path));
    return opened ? FileHandoffOutcome.done : FileHandoffOutcome.failed;
  } catch (error, stack) {
    debugPrint('KapyNotes: could not open ${ref.name}: $error\n$stack');
    return FileHandoffOutcome.failed;
  }
}

/// Saves a copy of [ref] where the user chooses: a save panel on the
/// desktops, "Save to Files" on iOS, the document picker on Android.
Future<FileHandoffOutcome> saveAttachmentFile(
  NoteFileRef ref, {
  required BlobStore store,
  NoteImageFetcher? fetch,
}) async {
  try {
    final blob = await locateAttachmentFile(ref, store: store, fetch: fetch);
    if (blob == null) return FileHandoffOutcome.notDownloaded;

    if (AppPlatform.isDesktop) {
      final location = await getSaveLocation(suggestedName: ref.name);
      if (location == null) return FileHandoffOutcome.cancelled;
      // Straight to the chosen path: the macOS sandbox grants that one path
      // and nothing beside it, so there is no temporary sibling to rename
      // from. A copy that fails halfway is deleted rather than left behind
      // under the name the user typed.
      final target = File(location.path);
      try {
        await blob.copy(target.path);
      } catch (_) {
        await _quietlyDelete(target);
        rethrow;
      }
      return FileHandoffOutcome.done;
    }

    final copy = await _handoffCopy(ref, blob);
    try {
      final result = await FileExport.save(
        path: copy.path,
        suggestedName: ref.name,
        mimeType: ref.mime,
      );
      return switch (result.outcome) {
        FileExportOutcome.saved => FileHandoffOutcome.done,
        FileExportOutcome.cancelled => FileHandoffOutcome.cancelled,
        FileExportOutcome.unsupported ||
        FileExportOutcome.failed => FileHandoffOutcome.failed,
      };
    } finally {
      // The system picker has taken its own copy by the time it answers.
      await _quietlyDelete(copy);
    }
  } catch (error, stack) {
    debugPrint('KapyNotes: could not save ${ref.name}: $error\n$stack');
    return FileHandoffOutcome.failed;
  }
}

/// Copies handed to other apps live here, one folder per file, and are
/// cleared once they are a day old. Opening the same file twice reuses the
/// copy, so a viewer already showing it is not pointed at a new path.
const Duration _handoffKept = Duration(days: 1);

@visibleForTesting
Future<Directory> Function() handoffRoot = () async {
  final temp = await getTemporaryDirectory();
  return Directory('${temp.path}/kapy-files');
};

Future<File> _handoffCopy(NoteFileRef ref, File blob) async {
  final root = await handoffRoot();
  await _pruneHandoffs(root, keep: ref.hash);
  final dir = Directory('${root.path}/${ref.hash.substring(0, 16)}');
  await dir.create(recursive: true);
  final target = File('${dir.path}/${ref.name}');
  if (await target.exists() && await target.length() == await blob.length()) {
    return target;
  }
  final partial = File('${target.path}.partial');
  try {
    await blob.copy(partial.path);
    await partial.rename(target.path);
  } catch (_) {
    await _quietlyDelete(partial);
    rethrow;
  }
  return target;
}

/// Deletes handoff folders older than a day. Best effort: a file another app
/// still has open may refuse, and is tried again next time.
Future<void> _pruneHandoffs(Directory root, {required String keep}) async {
  try {
    if (!await root.exists()) return;
    final now = DateTime.now();
    await for (final entity in root.list()) {
      if (entity is! Directory) continue;
      if (entity.uri.pathSegments.where((s) => s.isNotEmpty).last ==
          keep.substring(0, 16)) {
        continue;
      }
      try {
        final modified = (await entity.stat()).modified;
        if (now.difference(modified) > _handoffKept) {
          await entity.delete(recursive: true);
        }
      } catch (_) {}
    }
  } catch (error) {
    debugPrint('KapyNotes: could not tidy opened files: $error');
  }
}

Future<void> _quietlyDelete(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } catch (_) {}
}
