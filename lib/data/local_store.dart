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
/// the wrong trade, so writes are coalesced into a short window and forced
/// out whenever the app loses focus or shuts down. The in-memory copy is
/// always current, so nothing the user sees depends on the flush.
class LocalStore {
  final String fileName;
  final Duration debounce;

  File? _file;
  Map<String, Object?> _data = {};
  Timer? _timer;
  Future<void>? _inFlight;
  Future<void>? _loadFuture;
  bool _dirty = false;

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
    this.debounce = const Duration(milliseconds: 250),
  });

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
    _timer?.cancel();
    _timer = Timer(debounce, () => unawaited(flush()));
  }

  /// Writes without waiting for the coalescing window.
  ///
  /// For settings rather than notes. Coalescing exists because a note changes
  /// on every keystroke; a preference changes when somebody deliberately
  /// changes it, and the moment after that is exactly when they are likely to
  /// quit. Waiting 250ms to write a choice the user just made is how the
  /// choice gets lost.
  void putNow(String key, Object? value) {
    _data[key] = value;
    _dirty = true;
    _timer?.cancel();
    _timer = null;
    unawaited(flush());
  }

  T? read<T>(String key) {
    final value = _data[key];
    return value is T ? value : null;
  }

  /// Writes immediately. Safe to call at any time; concurrent calls queue.
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    if (!_dirty) return;
    _dirty = false;

    final previous = _inFlight;
    final next = () async {
      if (previous != null) await previous;
      await _write();
    }();
    _inFlight = next;
    return next;
  }

  Future<void> _write() async {
    final file = _file;
    if (file == null) return;
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
    } catch (error, stack) {
      _dirty = true;
      debugPrint('KapyNotes: could not write $fileName: $error\n$stack');
    }
  }

  void dispose() {
    _timer?.cancel();
  }
}
