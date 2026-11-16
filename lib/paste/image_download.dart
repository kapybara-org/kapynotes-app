import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../images/image_ingest.dart' show mimeForFilename;

/// Fetches the pictures a paste links to, so they become the note's own
/// before the links expire — ChatGPT's, Notion's and Google Docs' do.
///
/// This is the only thing a paste sends anywhere: one GET per picture, with
/// no cookies and no referrer, at most four at a time, each given 20 seconds
/// and 25 MB, and kept only when the server says it is an image.
class PastedImageDownloader {
  PastedImageDownloader({http.Client? client}) : _client = client;

  static final shared = PastedImageDownloader();

  static const maxConcurrent = 4;
  static const timeout = Duration(seconds: 20);
  static const maxBytes = 25 * 1024 * 1024;

  final http.Client? _client;
  var _active = 0;
  final _waiting = Queue<Completer<void>>();

  Future<({Uint8List bytes, String mime})?> fetch(String address) async {
    final uri = Uri.tryParse(address);
    if (uri == null) return null;
    if (uri.scheme == 'file') return _readFile(uri);
    if (uri.scheme != 'https' && uri.scheme != 'http') return null;
    await _acquire();
    try {
      return await _download(uri).timeout(timeout, onTimeout: () => null);
    } on Object catch (error) {
      debugPrint('KapyNotes: could not fetch a pasted image: $error');
      return null;
    } finally {
      _release();
    }
  }

  Future<({Uint8List bytes, String mime})?> _download(Uri uri) async {
    final client = _client ?? http.Client();
    try {
      final request = http.Request('GET', uri)
        ..headers['Accept'] = 'image/*'
        ..followRedirects = true
        ..maxRedirects = 5;
      final response = await client.send(request);
      final mime = (response.headers['content-type'] ?? '')
          .split(';')
          .first
          .trim()
          .toLowerCase();
      final declared = response.contentLength;
      if (response.statusCode != 200 ||
          !mime.startsWith('image/') ||
          (declared != null && declared > maxBytes)) {
        unawaited(response.stream.drain<void>().catchError((_) {}));
        return null;
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream) {
        bytes.add(chunk);
        if (bytes.length > maxBytes) return null;
      }
      if (bytes.isEmpty) return null;
      return (bytes: bytes.takeBytes(), mime: mime);
    } finally {
      if (_client == null) client.close();
    }
  }

  /// A picture a desktop app left on disk for its clipboard, as Word does.
  /// Readable only where the app's sandbox allows; otherwise null, like any
  /// other failed fetch.
  static Future<({Uint8List bytes, String mime})?> _readFile(Uri uri) async {
    try {
      final file = File(uri.toFilePath());
      if (await file.length() > maxBytes) return null;
      final bytes = await file.readAsBytes();
      final mime = mimeForFilename(file.path);
      if (bytes.isEmpty || !mime.startsWith('image/')) return null;
      return (bytes: bytes, mime: mime);
    } on Object {
      return null;
    }
  }

  Future<void> _acquire() async {
    if (_active < maxConcurrent) {
      _active++;
      return;
    }
    final turn = Completer<void>();
    _waiting.add(turn);
    await turn.future;
  }

  void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    } else {
      _active--;
    }
  }
}
