import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'html_reader.dart' show PasteResources;

/// Everything the clipboard held at one moment.
///
/// Read in one native call, so its representations agree with each other
/// (a dictation app can't swap the text out between two reads) and iOS asks
/// for permission at most once.
class ClipboardSnapshot {
  const ClipboardSnapshot({
    this.types = const [],
    this.text,
    this.html,
    this.sourceUrl,
    this.rtfHtml,
    this.resources = const {},
    this.vscode,
    this.kapy,
    this.files = const [],
    this.image,
    this.imageMime,
  });

  /// The platform's own names for what was there.
  final List<String> types;
  final String? text;
  final String? html;

  /// The page the copy came from, for resolving its relative links.
  final String? sourceUrl;

  /// Rich text (RTF, RTFD) converted to HTML by the platform.
  final String? rtfHtml;

  /// Picture bytes the clipboard carried beside its markup, by the name or
  /// URL the markup refers to them by.
  final PasteResources resources;

  /// VS Code's description of a copy, as JSON.
  final String? vscode;

  /// Kapy Notes' own fragment, from its private clipboard type.
  final String? kapy;

  /// Paths of copied files.
  final List<String> files;
  final Uint8List? image;
  final String? imageMime;

  /// The language VS Code says the copied code is in.
  String? get vscodeMode {
    final raw = vscode;
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded['mode'] is String) {
        final mode = (decoded['mode'] as String).trim();
        return mode.isEmpty || mode == 'plaintext' ? null : mode;
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  static const _channel = MethodChannel('kapynotes/rich_clipboard');

  /// Reads the clipboard, or the private pasteboard named [pasteboard] on
  /// Apple platforms, which is how tests avoid the user's own clipboard.
  static Future<ClipboardSnapshot> read({String? pasteboard}) async {
    try {
      final raw = await _channel.invokeMethod<Object?>('read', {
        'pasteboard': ?pasteboard,
      });
      return fromChannel(raw);
    } on MissingPluginException {
      return _readLegacy();
    } on PlatformException catch (error) {
      debugPrint('KapyNotes: could not read the clipboard: $error');
      return _readLegacy();
    }
  }

  /// What an older native side offers: the text and the HTML, read apart.
  static Future<ClipboardSnapshot> _readLegacy() async {
    String? html;
    try {
      html = await _channel.invokeMethod<String>('readHtml');
    } on Object {
      html = null;
    }
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    return fromChannel({'text': text, 'html': html});
  }

  @visibleForTesting
  static ClipboardSnapshot fromChannel(Object? raw) {
    if (raw is! Map) return const ClipboardSnapshot();
    String? string(String key) {
      final value = raw[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    var html = string('html');
    var sourceUrl = string('sourceUrl');
    if (html != null && html.startsWith('Version:')) {
      final parsed = _parseWindowsHtml(html);
      html = parsed.html;
      sourceUrl ??= parsed.sourceUrl;
    }
    final resources = <String, ({Uint8List bytes, String mime})>{};
    final rawResources = raw['resources'];
    if (rawResources is List) {
      for (final entry in rawResources) {
        if (entry is! Map) continue;
        final name = entry['name'];
        final data = entry['data'];
        final mime = entry['mime'];
        if (name is String && data is Uint8List && data.isNotEmpty) {
          resources[name] = (
            bytes: data,
            mime: mime is String && mime.isNotEmpty
                ? mime.toLowerCase()
                : 'application/octet-stream',
          );
        }
      }
    }
    final types = raw['types'];
    final files = raw['files'];
    final image = raw['image'];
    return ClipboardSnapshot(
      types: types is List ? [...types.whereType<String>()] : const [],
      text: string('text')?.replaceAll('\r\n', '\n'),
      html: html,
      sourceUrl: sourceUrl,
      rtfHtml: string('rtfHtml'),
      resources: resources,
      vscode: string('vscode'),
      kapy: string('kapy'),
      files: files is List ? [...files.whereType<String>()] : const [],
      image: image is Uint8List && image.isNotEmpty ? image : null,
      imageMime: string('imageMime'),
    );
  }

  /// Windows' "HTML Format": a header of byte offsets and the page's
  /// address, then the markup.
  static ({String html, String? sourceUrl}) _parseWindowsHtml(String raw) {
    String? sourceUrl;
    int? startHtml;
    int? endHtml;
    final markup = raw.indexOf('<');
    for (final line in const LineSplitter().convert(
      markup < 0 ? raw : raw.substring(0, markup),
    )) {
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      final name = line.substring(0, colon);
      final value = line.substring(colon + 1).trim();
      switch (name) {
        case 'StartHTML':
          startHtml = int.tryParse(value);
        case 'EndHTML':
          endHtml = int.tryParse(value);
        case 'SourceURL':
          if (value.isNotEmpty) sourceUrl = value;
      }
    }
    final bytes = utf8.encode(raw);
    if (startHtml != null &&
        endHtml != null &&
        startHtml >= 0 &&
        startHtml < endHtml &&
        endHtml <= bytes.length) {
      return (
        html: utf8.decode(
          bytes.sublist(startHtml, endHtml),
          allowMalformed: true,
        ),
        sourceUrl: sourceUrl,
      );
    }
    return (
      html: markup < 0 ? '' : raw.substring(markup),
      sourceUrl: sourceUrl,
    );
  }
}
