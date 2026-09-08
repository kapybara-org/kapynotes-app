import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';

import 'image_codec.dart';

/// Keeps base64 expansion from turning a broad selection into a memory spike.
const int maxClipboardFragmentImages = 20;
const int maxClipboardFragmentBytes = 24 * 1024 * 1024;

/// What was on the clipboard, if it was a picture.
class ClipboardImage {
  const ClipboardImage({required this.bytes, required this.name});

  final Uint8List bytes;

  /// A name for the ingest to guess a MIME type from. Real when the clipboard
  /// held a file, invented when it held raw pixels.
  final String name;
}

/// One image inside a rich clipboard fragment.
///
/// [offset] is relative to the fragment's [NoteClipboardFragment.body], where
/// one U+FFFC object-replacement character reserves the image's position.
class ClipboardFragmentImage {
  const ClipboardFragmentImage({
    required this.offset,
    required this.bytes,
    required this.mime,
    required this.width,
    required this.height,
    required this.widthFactor,
  });

  final int offset;
  final Uint8List bytes;
  final String mime;
  final int width;
  final int height;
  final double widthFactor;
}

/// Text and pictures copied out of one editor selection, in document order.
class NoteClipboardFragment {
  const NoteClipboardFragment({required this.body, required this.images});

  final String body;
  final List<ClipboardFragmentImage> images;

  static const _placeholder = '\uFFFC';
  static const _marker = 'kapynotes:';

  /// The representation a plain-text-only destination receives.
  String get plainText {
    final byOffset = {for (final image in images) image.offset: image};
    return body.replaceAllMapped(
      RegExp(_placeholder),
      (match) => byOffset.containsKey(match.start) ? '[Image]' : '[Attachment]',
    );
  }

  /// The rich representation understood by mail, documents, and web editors.
  ///
  /// A compact marker describes the Kapy Notes offsets without duplicating
  /// image bytes. The pixels live once, in each img data URI, which also makes
  /// this ordinary HTML useful to every other app rather than a private-only
  /// clipboard flavor.
  String get html {
    final ordered = [...images]..sort((a, b) => a.offset.compareTo(b.offset));
    final descriptor = base64Url.encode(
      utf8.encode(
        jsonEncode({
          'v': 1,
          'body': body,
          'images': [
            for (final image in ordered)
              {
                'o': image.offset,
                'm': image.mime,
                'w': image.width,
                'h': image.height,
                'f': image.widthFactor,
              },
          ],
        }),
      ),
    );
    final byOffset = <int, ({int index, ClipboardFragmentImage image})>{
      for (var index = 0; index < ordered.length; index++)
        ordered[index].offset: (index: index, image: ordered[index]),
    };
    final result = StringBuffer(
      '<div data-kapynotes-fragment="1" style="white-space:pre-wrap">'
      '<!--$_marker$descriptor-->',
    );
    var cursor = 0;
    for (final entry in byOffset.entries) {
      final offset = entry.key;
      if (offset < cursor ||
          offset >= body.length ||
          body.codeUnitAt(offset) != 0xFFFC) {
        continue;
      }
      result.write(_htmlText(body.substring(cursor, offset)));
      {
        final image = entry.value.image;
        result
          ..write('<img data-kapynotes-image="${entry.value.index}" src="data:')
          ..write(_escapeHtml(image.mime))
          ..write(';base64,')
          ..write(base64Encode(image.bytes))
          ..write('" width="${image.width}" height="${image.height}" ')
          ..write('alt="Image" style="max-width:')
          ..write((image.widthFactor.clamp(0.25, 1) * 100).toStringAsFixed(2))
          ..write('%;height:auto">');
      }
      cursor = offset + 1;
    }
    result.write(_htmlText(body.substring(cursor)));
    result.write('</div>');
    return result.toString();
  }

  Map<String, Object> get platformData {
    final ordered = [...images]..sort((a, b) => a.offset.compareTo(b.offset));
    return {
      'text': plainText,
      'html': html,
      if (ordered.isNotEmpty) 'image': ordered.first.bytes,
      if (ordered.isNotEmpty) 'imageMime': ordered.first.mime,
    };
  }

  /// Recovers a fragment only from HTML emitted by this app.
  ///
  /// Foreign HTML is deliberately ignored: it should continue through the
  /// established plain-text/image paste path rather than being interpreted as
  /// trusted attachment metadata.
  static NoteClipboardFragment? fromHtml(String? html) {
    if (html == null || html.isEmpty) return null;
    final marker = RegExp('<!--$_marker([A-Za-z0-9_=-]+)-->').firstMatch(html);
    if (marker == null) return null;

    try {
      final raw = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(marker.group(1)!))),
      );
      if (raw is! Map || raw['v'] != 1 || raw['body'] is! String) return null;
      final body = raw['body'] as String;
      final metadata = raw['images'];
      if (metadata is! List ||
          metadata.isEmpty ||
          metadata.length > maxClipboardFragmentImages) {
        return null;
      }

      final encoded = <int, ({String mime, Uint8List bytes})>{};
      var decodedBytes = 0;
      final imagePattern = RegExp(
        '<img\\s+data-kapynotes-image="(\\d+)"\\s+'
        'src="data:([^";]+);base64,([^"]+)"[^>]*>',
        caseSensitive: false,
      );
      for (final match in imagePattern.allMatches(html)) {
        final index = int.tryParse(match.group(1)!);
        if (index == null || encoded.containsKey(index)) return null;
        if (match.group(3)!.length >
            ((maxClipboardFragmentBytes + 2) ~/ 3) * 4) {
          return null;
        }
        final bytes = base64Decode(match.group(3)!);
        if (bytes.isEmpty) return null;
        decodedBytes += bytes.length;
        if (decodedBytes > maxClipboardFragmentBytes) return null;
        encoded[index] = (mime: match.group(2)!, bytes: bytes);
      }
      if (encoded.length != metadata.length) return null;

      final images = <ClipboardFragmentImage>[];
      final offsets = <int>{};
      for (var index = 0; index < metadata.length; index++) {
        final item = metadata[index];
        final source = encoded[index];
        if (item is! Map || source == null) return null;
        final offset = item['o'];
        final width = item['w'];
        final height = item['h'];
        final factor = item['f'];
        final describedMime = item['m'];
        if (offset is! int ||
            offset < 0 ||
            offset >= body.length ||
            body[offset] != _placeholder ||
            !offsets.add(offset) ||
            width is! int ||
            width <= 0 ||
            height is! int ||
            height <= 0 ||
            factor is! num ||
            describedMime is! String ||
            describedMime != source.mime ||
            !supportedImageMimes.contains(source.mime.toLowerCase())) {
          return null;
        }
        images.add(
          ClipboardFragmentImage(
            offset: offset,
            bytes: source.bytes,
            mime: source.mime,
            width: width,
            height: height,
            widthFactor: factor.toDouble().clamp(0.25, 1),
          ),
        );
      }
      return NoteClipboardFragment(body: body, images: images);
    } catch (_) {
      return null;
    }
  }

  static String _escapeHtml(String source) => source
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  static String _htmlText(String source) => _escapeHtml(
    source.replaceAll(_placeholder, '[Attachment]'),
  ).replaceAll('\n', '<br>');
}

/// Reads an image from the system clipboard, or returns null.
///
/// Two shapes count as an image, and both are ordinary:
///
///   * Raw bitmap data, which is what a screenshot tool puts there. Every
///     platform hands this over as PNG.
///   * A copied *file*, which is what Finder and Explorer put there. Only the
///     path comes across, so it is read from disk by the caller.
///
/// Null covers the common case by far — the clipboard holds text — and is not
/// an error. The caller falls through to an ordinary paste.
class ImageClipboard {
  const ImageClipboard();

  static const _richChannel = MethodChannel('kapynotes/rich_clipboard');

  /// A Kapy Notes rich fragment, when the clipboard carries one.
  Future<NoteClipboardFragment?> readFragment() async {
    try {
      final html = await _richChannel.invokeMethod<String>('readHtml');
      return NoteClipboardFragment.fromHtml(html);
    } catch (error) {
      debugPrint('KapyNotes: could not read rich clipboard data: $error');
      return null;
    }
  }

  /// Publishes the rich fragment in native, HTML, and plain-text forms.
  Future<void> writeFragment(NoteClipboardFragment fragment) async {
    await _richChannel.invokeMethod<void>('write', fragment.platformData);
  }

  /// Bitmap data on the clipboard, already decoded to bytes.
  Future<ClipboardImage?> readImage() async {
    try {
      final bytes = await Pasteboard.image;
      if (bytes == null || bytes.isEmpty) return null;
      // Every platform's implementation converts to PNG on the way out, so
      // the name is honest about what these bytes are.
      return ClipboardImage(bytes: bytes, name: 'pasted.png');
    } catch (error) {
      debugPrint('KapyNotes: could not read the clipboard: $error');
      return null;
    }
  }

  /// Paths of image files on the clipboard, in the order they were copied.
  Future<List<String>> readImageFiles() async {
    try {
      final paths = await Pasteboard.files();
      return [
        for (final path in paths)
          if (_looksLikeImage(path)) path,
      ];
    } catch (error) {
      debugPrint('KapyNotes: could not read clipboard files: $error');
      return const [];
    }
  }

  static bool _looksLikeImage(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0) return false;
    return supportedImageExtensions.contains(
      path.substring(dot + 1).toLowerCase(),
    );
  }
}
