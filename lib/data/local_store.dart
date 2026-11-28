import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// A tiny JSON-file store used for notes and layout preferences.
///
/// The web original kept everything in `localStorage` and wrote on every
/// keystroke. On desktop and mobile a synchronous disk write per keystroke is
/// the wrong trade, so writes are coalesced and forced out whenever the app
/// loses focus or shuts down. The in-memory copy is always current, so
/// nothing the user sees depends on the flush.
class LocalStore {
  final String fileName;

  /// How long a change waits for the write that takes it to disk, at most.
  /// Counted from the first change since the last write, not the latest, so
  /// typing without a pause cannot hold the write back: a process killed
  /// mid-sentence, where nothing can flush, loses at most this much.
  final Duration delay;

  File? _file;
  Map<String, Object?> _data = {};
  Timer? _delayTimer;
  Timer? _retryTimer;
  Future<void>? _inFlight;
  Future<void>? _loadFuture;
  bool _dirty = false;
  bool _disposed = false;

  /// Whether everything put here is on disk, still on its way there, or
  /// failed its last write, which is tried again after [retry].
  final ValueNotifier<StoreWrite> writes = ValueNotifier(StoreWrite.written);

  /// How long the last write came out, so the next one knows whether it is
  /// worth an isolate. Starts high so a store that has never been written
  /// takes the safe path once and measures itself.
  int _lastEncodedLength = _inlineEncodeLimit;

  /// Below this an encode is faster than spawning an isolate to do it in.
  /// The same line [_load] draws for decoding: a spawn costs a copy of the
  /// whole tree on the way in and a copy of the text on the way out, which
  /// for a small store is more work than the encode it was meant to hide.
  static const _inlineEncodeLimit = 64 * 1024;

  LocalStore({
    required this.fileName,
    this.delay = const Duration(milliseconds: 250),
    this.retry = const Duration(seconds: 5),
  });

  final Duration retry;

  Map<String, Object?> get data => _data;

  Future<void> load() => _loadFuture ??= _load();

  Future<void> _load() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/$fileName');
      _file = file;
      if (!await file.exists()) return;
      final text = await file.readAsString();
      if (text.trim().isEmpty) return;
      // Small files are cheaper inline. Large note histories parse elsewhere
      // so storage hydration never stalls the launch editor's input isolate.
      final decoded = text.length < 64 * 1024
          ? jsonDecode(text)
          : await Isolate.run<Object?>(() => jsonDecode(text));
      if (decoded is Map<String, Object?>) _data = decoded;
    } catch (error, stack) {
      // A corrupt or unreadable store must not stop the app from opening;
      // it starts empty and the next successful write repairs it.
      debugPrint('KapyNotes: could not read $fileName: $error\n$stack');
    }
  }

  void put(String key, Object? value) {
    _data[key] = value;
    _dirty = true;
    if (writes.value == StoreWrite.written) writes.value = StoreWrite.pending;
    // A retry waiting out a failed write must not hold this keystroke. The
    // delay itself is counted from the first change, so a pause is not required.
    _retryTimer?.cancel();
    _retryTimer = null;
    _delayTimer ??= Timer(delay, () => unawaited(flush()));
  }

  /// Writes without waiting for [delay].
  ///
  /// For settings rather than notes. Coalescing exists because a note changes
  /// on every keystroke; a preference changes when somebody deliberately
  /// changes it, and the moment after that is exactly when they are likely to
  /// quit. Waiting 250ms to write a choice the user just made is how the
  /// choice gets lost.
  void putNow(String key, Object? value) {
    _data[key] = value;
    _dirty = true;
    if (writes.value == StoreWrite.written) writes.value = StoreWrite.pending;
    _retryTimer?.cancel();
    _retryTimer = null;
    _delayTimer?.cancel();
    _delayTimer = null;
    unawaited(flush());
  }

  T? read<T>(String key) {
    final value = _data[key];
    return value is T ? value : null;
  }

  /// Writes immediately. Safe to call at any time; concurrent calls queue.
  Future<void> flush() async {
    _delayTimer?.cancel();
    _delayTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    if (!_dirty) return;
    _dirty = false;

    final previous = _inFlight;
    late final Future<void> next;
    next = () async {
      if (previous != null) await previous;
      final wrote = await _write();
      // A dispose during the write must not schedule a retry or touch
      // [writes], which is already disposed.
      if (_disposed) return;
      // Scheduled here rather than in _write, whose context its isolate
      // copies, and which must not hold this store.
      if (!wrote) {
        _retryTimer ??= Timer(retry, () => unawaited(flush()));
      }
      if (_disposed || !identical(_inFlight, next) || _dirty && wrote) return;
      writes.value = wrote ? StoreWrite.written : StoreWrite.failed;
    }();
    _inFlight = next;
    return next;
  }

  /// Whether the store is on disk once this returns. A failed write leaves
  /// it dirty and tries again after [retry], unless a change comes first.
  Future<bool> _write() async {
    final file = _file;
    if (file == null) return true;
    try {
      await file.parent.create(recursive: true);
      // Every keystroke lands here a quarter of a second later, so this is
      // the hottest write in the app. Small stores encode on the spot; large
      // note histories go to an isolate so a long note never stalls a frame.
      final String encoded;
      if (_lastEncodedLength < _inlineEncodeLimit) {
        encoded = jsonEncode(_data);
      } else {
        final snapshot = Map<String, Object?>.from(_data);
        encoded = await Isolate.run(() => jsonEncode(snapshot));
      }
      _lastEncodedLength = encoded.length;
      // Write-then-rename so a crash mid-write cannot truncate the notes.
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(encoded, flush: true);
      await temp.rename(file.path);
      return true;
    } catch (error, stack) {
      _dirty = true;
      debugPrint('KapyNotes: could not write $fileName: $error\n$stack');
      return false;
    }
  }

  void dispose() {
    _disposed = true;
    _delayTimer?.cancel();
    _retryTimer?.cancel();
    writes.dispose();
  }
}

enum StoreWrite { written, pending, failed }
