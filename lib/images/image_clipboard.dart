import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';

import '../data/blob_store.dart';
import '../data/note_attachment.dart';
import '../data/note_format.dart';
import '../paste/clipboard_snapshot.dart';
import '../paste/note_text.dart';
import '../paste/paste_tree.dart' show PasteImage;
import '../sync/aead.dart' show randomKey;
import 'image_codec.dart';

/// Keeps base64 expansion from turning a broad selection into a memory spike.
const int maxClipboardFragmentImages = 20;
const int maxClipboardFragmentBytes = 24 * 1024 * 1024;

/// A fragment this large, counting its attachments' bytes, is written and
/// read on another isolate, so its base64 and its markdown cost no frames.
const int backgroundClipboardBytes = 32 * 1024;

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

/// A file, voice note or video inside a rich clipboard fragment.
///
/// [ref] is the attachment as its note holds it, anchored at its own U+FFFC
/// in the fragment's [NoteClipboardFragment.body]. Where its note stores it
/// is no part of it: [bytes] are what a paste stores anew.
class ClipboardFragmentAttachment {
  const ClipboardFragmentAttachment({required this.ref, required this.bytes});

  final NoteAttachmentRef ref;
  final Uint8List bytes;
}

/// Text and attachments copied out of one editor selection, in document
/// order.
class NoteClipboardFragment {
  const NoteClipboardFragment({
    required this.body,
    required this.images,
    this.attachments = const [],
    this.formats = const [],
    this.markdown,
  });

  final String body;
  final List<ClipboardFragmentImage> images;

  /// The files, voice notes and videos that travel with the words.
  final List<ClipboardFragmentAttachment> attachments;

  /// The bold, italic, heading and subtitle ranges over [body].
  final List<NoteFormatRange> formats;

  /// Whether [body] was written in a markdown note. Null when the fragment
  /// does not say, as an older build's does not.
  final bool? markdown;

  static const _placeholder = '\uFFFC';
  static const _marker = 'kapynotes:';

  /// Where a ref is stored and how it is sealed, which a paste makes anew.
  /// The key in particular never goes near a clipboard.
  static const _storageFields = {'hash', 'key', 'bytes', 'attachmentId'};

  /// What an attachment that cannot be pasted as itself is pasted as.
  static String labelFor(NoteAttachmentRef ref) =>
      ref is NoteVoiceRef ? '[Voice note]' : '[Attachment]';

  /// The words and every attachment's bytes, which decide whether the
  /// fragment is written and read on another isolate.
  int get size =>
      body.length +
      images.fold<int>(0, (sum, image) => sum + image.bytes.length) +
      attachments.fold<int>(0, (sum, item) => sum + item.bytes.length);

  /// The representation a plain-text-only destination receives, and the one
  /// ChatGPT, Slack and GitHub take: a markdown note's own markdown, with
  /// `![image]` for each picture, which has no address to give; a plain
  /// note's own text, with each picture as `[Image]`.
  String get plainText {
    final labels = {
      for (final image in images)
        image.offset: markdown == true ? '![image]' : '[Image]',
      for (final attachment in attachments)
        attachment.ref.offset: labelFor(attachment.ref),
    };
    return body.replaceAllMapped(
      RegExp(_placeholder),
      (match) => labels[match.start] ?? '[Attachment]',
    );
  }

  /// The rich representation understood by mail, documents, and web editors:
  /// the note's words as HTML, each picture an img whose data URI holds its
  /// bytes, sized as the note shows it.
  ///
  /// Ahead of it, a compact marker describes the pictures' places for older
  /// builds, which read only this HTML and only a fragment with pictures. It
  /// points at the img tags rather than repeating their bytes.
  String get html {
    final ordered = [...images]..sort((a, b) => a.offset.compareTo(b.offset));
    final words = noteHtml(
      body,
      markdown: markdown ?? false,
      formats: formats,
      embeds: {
        for (final attachment in attachments)
          attachment.ref.offset: _escapeHtml(labelFor(attachment.ref)),
        for (var index = 0; index < ordered.length; index++)
          ordered[index].offset: _imageHtml(index, ordered[index]),
      },
    );
    if (ordered.isEmpty) return words;
    return '<!--$_marker${_describe(ordered)}-->$words';
  }

  /// The marker older builds read: the body with every attachment but the
  /// pictures written as its label, since those builds carry only pictures,
  /// and where in it each picture is.
  String _describe(List<ClipboardFragmentImage> ordered) {
    final labels = {
      for (final attachment in attachments)
        attachment.ref.offset: labelFor(attachment.ref),
    };
    final moved = <int, int>{};
    var growth = 0;
    final labelled = body.replaceAllMapped(RegExp(_placeholder), (match) {
      final label = labels[match.start];
      if (label == null) {
        moved[match.start] = match.start + growth;
        return _placeholder;
      }
      growth += label.length - 1;
      return label;
    });
    return base64Url.encode(
      utf8.encode(
        jsonEncode({
          'v': 1,
          'body': labelled,
          'images': [
            for (final image in ordered)
              {
                'o': moved[image.offset],
                'm': image.mime,
                'w': image.width,
                'h': image.height,
                'f': image.widthFactor,
              },
          ],
        }),
      ),
    );
  }

  /// A picture at the width the note shows it, against the column a paste
  /// reads a width against, so pasting it back gives it the same width.
  static String _imageHtml(int index, ClipboardFragmentImage image) {
    final width =
        (image.widthFactor.clamp(NoteImageRef.minWidthFactor, 1) *
                PasteImage.referenceColumnWidth)
            .round();
    final height = image.width > 0 && image.height > 0
        ? ' height="${(width * image.height / image.width).round()}"'
        : '';
    return '<img data-kapynotes-image="$index" '
        'src="data:${_escapeHtml(image.mime)};base64,'
        '${base64Encode(image.bytes)}" alt="image" width="$width"$height>';
  }

  /// Everything a paste into a note needs to rebuild the selection exactly,
  /// for Kapy Notes' own clipboard type: the body, its styles, whether it was
  /// markdown, and each attachment's ref with the bytes it stores.
  String get kapy => jsonEncode({
    'v': 2,
    'body': body,
    'markdown': ?markdown,
    'formats': [for (final range in formats) range.toJson()],
    'attachments': [
      for (final image in images)
        {
          'kind': 'image',
          'offset': image.offset,
          'mime': image.mime,
          'width': image.width,
          'height': image.height,
          'widthFactor': image.widthFactor,
          'data': base64Encode(image.bytes),
        },
      for (final attachment in attachments)
        {
          for (final MapEntry(:key, :value) in attachment.ref.toJson().entries)
            if (!_storageFields.contains(key)) key: value,
          'data': base64Encode(attachment.bytes),
        },
    ],
  });

  Map<String, Object> get platformData {
    final ordered = [...images]..sort((a, b) => a.offset.compareTo(b.offset));
    return {
      'text': plainText,
      'html': html,
      'kapy': kapy,
      if (ordered.isNotEmpty) 'image': ordered.first.bytes,
      if (ordered.isNotEmpty) 'imageMime': ordered.first.mime,
    };
  }

  /// The fragment a clipboard [snapshot] carries: Kapy Notes' own type
  /// first, then the marker in the HTML, which is all an older build wrote.
  static Future<NoteClipboardFragment?> fromSnapshot(
    ClipboardSnapshot snapshot,
  ) async {
    final kapy = snapshot.kapy;
    final fragment = kapy == null
        ? null
        : kapy.length < backgroundClipboardBytes
        ? fromKapy(kapy)
        : await Isolate.run(() => fromKapy(kapy));
    return fragment ?? fromHtml(snapshot.html);
  }

  /// Reads [kapy] back. Null unless it is whole and well formed, every U+FFFC
  /// in its body is one of its attachments, and it keeps to the caps a copy
  /// keeps to.
  static NoteClipboardFragment? fromKapy(String? source) {
    if (source == null || source.isEmpty) return null;
    try {
      final raw = jsonDecode(source);
      if (raw is! Map || raw['v'] != 2) return null;
      final body = raw['body'];
      final markdown = raw['markdown'];
      final entries = raw['attachments'];
      if (body is! String ||
          (markdown != null && markdown is! bool) ||
          entries is! List ||
          entries.length > maxClipboardFragmentImages) {
        return null;
      }

      final images = <ClipboardFragmentImage>[];
      final attachments = <ClipboardFragmentAttachment>[];
      final offsets = <int>{};
      var budget = maxClipboardFragmentBytes;
      for (final entry in entries) {
        if (entry is! Map) return null;
        final offset = entry['offset'];
        final data = entry['data'];
        if (offset is! int ||
            offset < 0 ||
            offset >= body.length ||
            body.codeUnitAt(offset) != 0xFFFC ||
            !offsets.add(offset) ||
            data is! String ||
            data.length > ((budget + 2) ~/ 3) * 4) {
          return null;
        }
        final bytes = base64Decode(data);
        budget -= bytes.length;
        if (bytes.isEmpty || budget < 0) return null;

        if (entry['kind'] == 'image') {
          final mime = entry['mime'];
          final width = entry['width'];
          final height = entry['height'];
          final factor = entry['widthFactor'];
          if (mime is! String ||
              !supportedImageMimes.contains(mime.toLowerCase()) ||
              width is! int ||
              width <= 0 ||
              height is! int ||
              height <= 0 ||
              factor is! num) {
            return null;
          }
          images.add(
            ClipboardFragmentImage(
              offset: offset,
              bytes: bytes,
              mime: mime,
              width: width,
              height: height,
              widthFactor: factor.toDouble().clamp(
                NoteImageRef.minWidthFactor,
                1,
              ),
            ),
          );
          continue;
        }

        final ref = NoteAttachmentRef.fromJson({
          for (final MapEntry(:key, :value) in entry.entries)
            if (key != 'data') '$key': value,
          'hash': BlobStore.hashOf(bytes),
          'key': base64Encode(randomKey()),
          'bytes': bytes.length,
        });
        if (ref == null || ref is NoteImageRef || ref is NoteUnknownRef) {
          return null;
        }
        attachments.add(ClipboardFragmentAttachment(ref: ref, bytes: bytes));
      }
      if (_placeholder.allMatches(body).length != offsets.length) return null;

      return NoteClipboardFragment(
        body: body,
        images: images,
        attachments: attachments,
        formats: noteFormatsFromJson(raw['formats'], body.length),
        markdown: markdown as bool?,
      );
    } catch (_) {
      return null;
    }
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

  /// Everything the clipboard holds, read at once.
  Future<ClipboardSnapshot> readSnapshot() => ClipboardSnapshot.read();

  /// Publishes the rich fragment in every form at once: plain text, HTML,
  /// Kapy Notes' own type, and its first picture as a native image.
  Future<void> writeFragment(NoteClipboardFragment fragment) async {
    final data = fragment.size < backgroundClipboardBytes
        ? fragment.platformData
        : await Isolate.run(() => fragment.platformData);
    await _richChannel.invokeMethod<void>('write', data);
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
