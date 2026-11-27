import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'note_attachment.dart';

/// The cleaned copies of recordings, kept on this device and nowhere else.
///
/// One `.m4a` per recording, named by the recording's hash, in a folder of
/// its own beside the attachment store rather than in it. The store is what
/// syncs; a cleaned copy is derived, as large as the original, and this
/// device's business. Another device plays the original until noise is
/// removed there too.
///
/// Like the store, nothing deletes a copy when its voice note goes: [sweep]
/// does, from the same live set, for the same reasons (see
/// [NotesStore.sweepBlobs]).
class CleanCopies {
  CleanCopies({
    Directory? directory,
    DateTime Function()? now,
    this.sweepGrace = const Duration(minutes: 10),
  }) : _directory = directory,
       _now = now ?? DateTime.now;

  Directory? _directory;
  final DateTime Function() _now;

  /// A file written this recently is left alone by [sweep]: it may be a copy
  /// still being written, or one whose note has not been saved yet.
  final Duration sweepGrace;

  static final RegExp _hash = RegExp(r'^[0-9a-f]{64}$');

  Future<Directory> _dir() async => _directory ??= Directory(
    '${(await getApplicationSupportDirectory()).path}/voice-clean',
  );

  /// Where the copy of the recording with [hash] lives, whether or not it
  /// exists yet. Hashes arrive from other devices, so anything but a sha256
  /// in hex is refused rather than allowed to name a path.
  Future<File> fileFor(String hash) async {
    if (!_hash.hasMatch(hash)) throw ArgumentError.value(hash, 'hash');
    return File('${(await _dir()).path}/$hash${NoteVoiceRef.voiceExtension}');
  }

  /// The copy, if this device has made one.
  Future<File?> existing(String hash) async {
    final file = await fileFor(hash);
    return await file.exists() ? file : null;
  }

  /// Deletes every copy whose recording no note refers to, and any debris of
  /// a run that died, and reports the bytes reclaimed.
  Future<int> sweep(Set<String> live) async {
    var reclaimed = 0;
    try {
      final dir = await _dir();
      if (!await dir.exists()) return 0;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        final hash = name.split('.').first;
        final complete = name == '$hash${NoteVoiceRef.voiceExtension}';
        if (complete && live.contains(hash)) continue;
        final modified = await entity.lastModified();
        if (_now().difference(modified) < sweepGrace) continue;
        reclaimed += await entity.length();
        await entity.delete();
      }
    } catch (error) {
      debugPrint('KapyNotes: clean copy sweep failed: $error');
    }
    return reclaimed;
  }
}
