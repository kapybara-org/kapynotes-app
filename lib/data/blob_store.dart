import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Every attachment byte this device holds, addressed by the sha256 of its
/// content — pictures, recordings, and whatever comes next.
///
/// Notes themselves live in one JSON file that is rewritten whenever anything
/// changes (see [LocalStore]); attachment bytes obviously cannot live there.
/// They get their own directory, and content addressing falls out of that
/// decision with three properties worth having:
///
///   * The same picture dropped into five notes is stored once.
///   * A file is either complete and correct or absent, because its name *is*
///     its checksum. There is no half-written state to detect.
///   * Nothing is ever keyed by a presigned URL. Those are re-minted on every
///     fetch, so a URL-keyed cache re-downloads the same bytes forever and
///     turns a free read into a billed one.
///
/// A blob may carry a file extension, because some things will not play
/// without one: iOS picks its audio decoder from the extension, so a recording
/// stored as a bare hash is silent there. The hash is still the whole identity
/// — the extension is a suffix the store keeps track of, never something a
/// caller has to know to read a blob back.
///
/// This layer knows nothing about accounts. Attachments work in full on a
/// device that has never signed in; sync is a thing that happens to them
/// afterwards.
class BlobStore {
  BlobStore({Directory? directory}) : _directory = directory;

  Directory? _directory;
  Future<Directory>? _resolving;

  /// hash -> file name, including any extension. Filled by listing the
  /// directory once, then kept current by every write and delete.
  ///
  /// The index exists because a hash alone no longer names a file. It doubles
  /// as the "known to exist" set it replaced, so a hit still costs no syscall.
  Map<String, String>? _names;
  Future<Map<String, String>>? _indexing;

  Future<Directory> _dir() async {
    final existing = _directory;
    if (existing != null) return existing;
    return _resolving ??= () async {
      final support = await getApplicationSupportDirectory();
      // Still `images`, though it holds more than images now. Version 1.13.0
      // shipped this path, so renaming it would strand every picture already
      // on a user's disk behind a migration that has to be perfect. The name
      // is a little wrong; losing somebody's photos would be worse.
      final dir = Directory('${support.path}/images');
      await dir.create(recursive: true);
      _directory = dir;
      return dir;
    }();
  }

  /// The hash part of a stored file's name — everything before the first dot.
  ///
  /// Split on the *first* dot rather than the last so that `.tmp` debris and
  /// any future double extension both reduce to the hash they claim to be.
  static String hashFromFileName(String name) {
    final dot = name.indexOf('.');
    return dot < 0 ? name : name.substring(0, dot);
  }

  /// Blobs are sharded by the first byte of the hash. A note-taking app can
  /// accumulate thousands of attachments, and some filesystems get measurably
  /// slower listing a single directory that large.
  Future<Directory> _shardFor(String hash) async {
    final dir = await _dir();
    return Directory('${dir.path}/${hash.substring(0, 2)}');
  }

  /// Lists the store once and remembers what is in it.
  Future<Map<String, String>> _index() async {
    final ready = _names;
    if (ready != null) return ready;
    return _indexing ??= () async {
      final names = <String, String>{};
      try {
        final dir = await _dir();
        if (await dir.exists()) {
          await for (final entity in dir.list(recursive: true)) {
            if (entity is! File) continue;
            final name = entity.uri.pathSegments.last;
            if (name.endsWith('.tmp')) continue;
            names[hashFromFileName(name)] = name;
          }
        }
      } catch (error) {
        debugPrint('KapyNotes: could not index the attachment store: $error');
      }
      _names = names;
      return names;
    }();
  }

  static String hashOf(Uint8List bytes) => sha256.convert(bytes).toString();

  /// Writes [bytes] and returns their address. A second call with the same
  /// bytes is free.
  Future<String> put(Uint8List bytes, {String extension = ''}) async {
    final hash = hashOf(bytes);
    final names = await _index();
    if (names.containsKey(hash)) return hash;

    final name = '$hash$extension';
    final shard = await _shardFor(hash);
    final file = File('${shard.path}/$name');
    if (await file.exists()) {
      names[hash] = name;
      return hash;
    }
    await shard.create(recursive: true);
    // Write-then-rename, so a crash cannot leave a truncated file sitting at
    // a name that claims to be the checksum of its contents.
    final temp = File('${file.path}.tmp');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(file.path);
    names[hash] = name;
    return hash;
  }

  /// The file holding [hash], or null when this device does not have it.
  ///
  /// Handed out so a player can stream from disk rather than being given the
  /// whole recording as bytes.
  Future<File?> fileFor(String hash) async {
    final names = await _index();
    final name = names[hash];
    if (name == null) return null;
    final shard = await _shardFor(hash);
    final file = File('${shard.path}/$name');
    if (await file.exists()) return file;
    names.remove(hash);
    return null;
  }

  Future<Uint8List?> read(String hash) async {
    try {
      final file = await fileFor(hash);
      if (file == null) return null;
      return await file.readAsBytes();
    } catch (error) {
      debugPrint('KapyNotes: could not read attachment $hash: $error');
      return null;
    }
  }

  Future<bool> has(String hash) async => await fileFor(hash) != null;

  Future<void> delete(String hash) async {
    try {
      final file = await fileFor(hash);
      (await _index()).remove(hash);
      if (file != null) await file.delete();
    } catch (error) {
      debugPrint('KapyNotes: could not delete attachment $hash: $error');
    }
  }

  /// Deletes every blob no note refers to, and reports how many bytes came
  /// back.
  ///
  /// Deleting an attachment is deleting a character, and a character can be
  /// deleted by undo, by a sync arriving, or by a note being thrown away — so
  /// no edit path tries to work out whether it was the last user of some
  /// bytes. The sweep answers that question in one place, from the only source
  /// that can know: the whole set of live notes.
  ///
  /// [live] holds hashes, not file names. Passing a partial set deletes real
  /// attachments.
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
        final hash = hashFromFileName(name);
        if (live.contains(hash)) continue;
        reclaimed += await _sizeThenDelete(entity);
        (await _index()).remove(hash);
      }
    } catch (error) {
      debugPrint('KapyNotes: attachment sweep failed: $error');
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
      debugPrint('KapyNotes: could not size the attachment store: \$error');
    }
    return total;
  }
}
