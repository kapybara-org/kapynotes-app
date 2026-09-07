import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Every image byte this device holds, addressed by the sha256 of its content.
///
/// Notes themselves live in one JSON file that is rewritten whenever anything
/// changes (see [LocalStore]); image bytes obviously cannot live there. They
/// get their own directory, and content addressing falls out of that decision
/// with three properties worth having:
///
///   * The same picture dropped into five notes is stored once.
///   * A file is either complete and correct or absent, because its name *is*
///     its checksum. There is no half-written state to detect.
///   * Nothing is ever keyed by a presigned URL. Those are re-minted on every
///     fetch, so a URL-keyed cache re-downloads the same bytes forever and
///     turns a free read into a billed one.
///
/// This layer knows nothing about accounts. Images work in full on a device
/// that has never signed in; sync is a thing that happens to them afterwards.
class ImageStore {
  ImageStore({Directory? directory}) : _directory = directory;

  Directory? _directory;
  Future<Directory>? _resolving;

  /// Names of blobs known to exist, so a hit costs no syscall. Only ever
  /// added to after a successful write or read.
  final Set<String> _present = <String>{};

  Future<Directory> _dir() async {
    final existing = _directory;
    if (existing != null) return existing;
    return _resolving ??= () async {
      final support = await getApplicationSupportDirectory();
      final dir = Directory('${support.path}/images');
      await dir.create(recursive: true);
      _directory = dir;
      return dir;
    }();
  }

  /// Blobs are sharded by the first byte of the hash. A note-taking app can
  /// accumulate thousands of images, and some filesystems get measurably
  /// slower listing a single directory that large.
  Future<File> _fileFor(String hash) async {
    final dir = await _dir();
    return File('${dir.path}/${hash.substring(0, 2)}/$hash');
  }

  static String hashOf(Uint8List bytes) => sha256.convert(bytes).toString();

  /// Writes [bytes] and returns their address. A second call with the same
  /// bytes is free.
  Future<String> put(Uint8List bytes) async {
    final hash = hashOf(bytes);
    if (_present.contains(hash)) return hash;
    final file = await _fileFor(hash);
    if (await file.exists()) {
      _present.add(hash);
      return hash;
    }
    await file.parent.create(recursive: true);
    // Write-then-rename, so a crash cannot leave a truncated file sitting at
    // a name that claims to be the checksum of its contents.
    final temp = File('${file.path}.tmp');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(file.path);
    _present.add(hash);
    return hash;
  }

  Future<Uint8List?> read(String hash) async {
    try {
      final file = await _fileFor(hash);
      if (!await file.exists()) {
        _present.remove(hash);
        return null;
      }
      final bytes = await file.readAsBytes();
      _present.add(hash);
      return bytes;
    } catch (error) {
      debugPrint('KapyNotes: could not read image $hash: $error');
      return null;
    }
  }

  Future<bool> has(String hash) async {
    if (_present.contains(hash)) return true;
    final file = await _fileFor(hash);
    final exists = await file.exists();
    if (exists) _present.add(hash);
    return exists;
  }

  Future<void> delete(String hash) async {
    _present.remove(hash);
    try {
      final file = await _fileFor(hash);
      if (await file.exists()) await file.delete();
    } catch (error) {
      debugPrint('KapyNotes: could not delete image $hash: $error');
    }
  }

  /// Deletes every blob no note refers to, and reports how many bytes came
  /// back.
  ///
  /// Deleting an image is deleting a character, and a character can be deleted
  /// by undo, by a sync arriving, or by a note being thrown away — so no edit
  /// path tries to work out whether it was the last user of some bytes. The
  /// sweep answers that question in one place, from the only source that can
  /// know: the whole set of live notes.
  ///
  /// [live] must be complete. Passing a partial set deletes real images.
  Future<int> sweep(Set<String> live) async {
    var reclaimed = 0;
    try {
      final dir = await _dir();
      if (!await dir.exists()) return 0;
      await for (final entity in dir.list(recursive: true)) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (name.endsWith('.tmp')) {
          // Debris from a crash mid-write. Nothing refers to it by definition.
          reclaimed += await _sizeThenDelete(entity);
          continue;
        }
        if (live.contains(name)) continue;
        reclaimed += await _sizeThenDelete(entity);
        _present.remove(name);
      }
    } catch (error) {
      debugPrint('KapyNotes: image sweep failed: $error');
    }
    return reclaimed;
  }

  Future<int> _sizeThenDelete(File file) async {
    try {
      final size = await file.length();
      await file.delete();
      return size;
    } catch (_) {
      return 0;
    }
  }

  /// Total bytes held on disk. Shown in settings, and the honest answer to
  /// "why is this app taking up space".
  Future<int> totalBytes() async {
    var total = 0;
    try {
      final dir = await _dir();
      if (!await dir.exists()) return 0;
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File) total += await entity.length();
      }
    } catch (error) {
      debugPrint('KapyNotes: could not size the image store: $error');
    }
    return total;
  }
}
