import 'dart:convert';
import 'dart:typed_data';

/// An image anchored to one U+FFFC placeholder in a note's body.
///
/// The placeholder exists because the calculator lexes every line: a markdown
/// image or a bare URL sitting in the body would be tokenised and evaluated.
/// One object-replacement character is inert to the lexer, survives every
/// existing text path unchanged, and still gives the editor a real caret
/// position to render a [WidgetSpan] at.
///
/// The same object serves two masters, which is why it carries two identities:
///
///   * [hash] is the local one — the sha256 of the bytes actually stored on
///     disk. It is the cache key, the dedupe key, and the only identity an
///     image has on a device with no account. Images work fully offline, so
///     this is never null.
///   * [attachmentId] is the server's, minted when the image is uploaded, and
///     null until then. A note can be written, read and exported forever
///     without one.
///
/// Dedupe is deliberately local-only. Every file gets its own random [key], so
/// two people storing identical bytes produce different ciphertext and the
/// server could not dedupe them even if it wanted to. Deriving the key from
/// the content instead would buy cross-user dedupe by leaking which users hold
/// the same image, which is not a trade this app makes.
class NoteAttachmentRef {
  /// Index of the U+FFFC character this image renders at.
  final int offset;

  /// sha256 (lowercase hex) of the stored bytes. The local content address.
  final String hash;

  /// The 32-byte file key. It rides *inside* the sealed note payload, so it is
  /// already encrypted under the master key by the time it leaves the device
  /// and the server never holds it — no second key-wrapping table.
  final Uint8List key;

  /// Real MIME type. Kept in here, not on the row: the server gets to know a
  /// byte count and nothing else about what the user stored.
  final String mime;

  /// Intrinsic size of the stored image, in pixels. Held so the editor can
  /// reserve the right box *before* any bytes are decoded — without it every
  /// note with images would reflow as each one loaded.
  final int width;
  final int height;

  /// Size of the stored bytes. What quota is billed on.
  final int bytes;

  /// sha256 of a ~600px preview, stored as its own object under the *same*
  /// file key with its own nonce. The note view fetches only these; the full
  /// image is fetched on tap. Null when the image is small enough that a
  /// thumbnail would cost more than it saves.
  final String? thumbHash;

  /// How much of the writing column this image takes, from
  /// [minImageWidthFactor] to 1.
  ///
  /// Part of the note's content, not a per-device view setting: a picture
  /// sized down to sit beside a paragraph should look the same on the laptop
  /// it was sized on, the phone that syncs it, and the markdown that exports
  /// it. Ignored for an image sharing its line with others, where the number
  /// of tiles decides the width instead.
  final double widthFactor;

  /// Server ids, null until this image has been uploaded.
  final String? attachmentId;
  final String? thumbId;

  const NoteAttachmentRef({
    required this.offset,
    required this.hash,
    required this.key,
    required this.mime,
    required this.width,
    required this.height,
    required this.bytes,
    this.thumbHash,
    this.widthFactor = 1,
    this.attachmentId,
    this.thumbId,
  });

  /// The character an attachment anchors to. Inert to the calculator lexer.
  static const String placeholder = '￼';

  /// Narrower than this and an image stops being a picture and starts being a
  /// smudge, so the handle refuses to go further.
  static const double minWidthFactor = 0.25;

  /// Aspect ratio, guarded so a corrupt record cannot divide by zero and take
  /// the editor's layout down with it.
  double get aspectRatio => height <= 0 || width <= 0 ? 1 : width / height;

  bool get isUploaded => attachmentId != null;

  NoteAttachmentRef copyWith({
    int? offset,
    double? widthFactor,
    String? attachmentId,
    String? thumbId,
  }) => NoteAttachmentRef(
    offset: offset ?? this.offset,
    hash: hash,
    key: key,
    mime: mime,
    width: width,
    height: height,
    bytes: bytes,
    thumbHash: thumbHash,
    widthFactor: clampImageWidthFactor(widthFactor ?? this.widthFactor),
    attachmentId: attachmentId ?? this.attachmentId,
    thumbId: thumbId ?? this.thumbId,
  );

  Map<String, Object?> toJson() => {
    'offset': offset,
    'hash': hash,
    'key': base64.encode(key),
    'mime': mime,
    'width': width,
    'height': height,
    'bytes': bytes,
    if (thumbHash != null) 'thumbHash': thumbHash,
    // Omitted at full width, which is almost every image, so a note's record
    // stays as small as it was.
    if (widthFactor < 1) 'widthFactor': widthFactor,
    if (attachmentId != null) 'attachmentId': attachmentId,
    if (thumbId != null) 'thumbId': thumbId,
  };

  static NoteAttachmentRef? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final offset = raw['offset'];
    final hash = raw['hash'];
    final keyRaw = raw['key'];
    final mime = raw['mime'];
    final width = raw['width'];
    final height = raw['height'];
    if (offset is! int || offset < 0) return null;
    if (hash is! String || hash.isEmpty) return null;
    if (mime is! String || mime.isEmpty) return null;
    if (width is! int || height is! int) return null;

    Uint8List key;
    try {
      key = base64.decode(keyRaw is String ? keyRaw : '');
    } catch (_) {
      return null;
    }
    if (key.length != 32) return null;

    final bytes = raw['bytes'];
    final thumbHash = raw['thumbHash'];
    final widthFactor = raw['widthFactor'];
    final attachmentId = raw['attachmentId'];
    final thumbId = raw['thumbId'];
    return NoteAttachmentRef(
      offset: offset,
      hash: hash,
      key: key,
      mime: mime,
      width: width,
      height: height,
      bytes: bytes is int ? bytes : 0,
      thumbHash: thumbHash is String ? thumbHash : null,
      widthFactor: widthFactor is num
          ? clampImageWidthFactor(widthFactor.toDouble())
          : 1,
      attachmentId: attachmentId is String ? attachmentId : null,
      thumbId: thumbId is String ? thumbId : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NoteAttachmentRef &&
      other.offset == offset &&
      other.hash == hash &&
      other.mime == mime &&
      other.width == width &&
      other.height == height &&
      other.bytes == bytes &&
      other.thumbHash == thumbHash &&
      other.widthFactor == widthFactor &&
      other.attachmentId == attachmentId &&
      other.thumbId == thumbId;

  @override
  int get hashCode => Object.hash(
    offset,
    hash,
    mime,
    width,
    height,
    bytes,
    thumbHash,
    widthFactor,
    attachmentId,
    thumbId,
  );
}

/// Keeps a width inside the range the handle allows, and treats anything
/// nonsensical — a NaN from a corrupt record, a negative from a bad edit — as
/// full width rather than as a reason to fail.
double clampImageWidthFactor(double value) {
  if (value.isNaN || value <= 0) return 1;
  return value.clamp(NoteAttachmentRef.minWidthFactor, 1.0);
}

/// Drops refs that no longer sit on a placeholder, and sorts what is left.
///
/// This is the reconciliation of record: [body] is the truth, and an image
/// exists exactly as long as its U+FFFC does. Everything else — deleting an
/// image by backspacing over it, a paste that drops one, a note arriving from
/// a client that stripped the refs but kept the characters — reduces to that
/// one rule, so no code path has to remember to clean up after itself.
List<NoteAttachmentRef> normalizeNoteAttachments(
  Iterable<NoteAttachmentRef> refs,
  String body,
) {
  final anchors = <int>{};
  for (var i = 0; i < body.length; i++) {
    if (body.codeUnitAt(i) == 0xFFFC) anchors.add(i);
  }
  if (anchors.isEmpty) return const [];

  final seen = <int>{};
  final kept = <NoteAttachmentRef>[];
  for (final ref in refs) {
    if (!anchors.contains(ref.offset)) continue;
    // Two refs on one placeholder cannot both be right; the first wins, which
    // makes the result deterministic rather than dependent on iteration order.
    if (!seen.add(ref.offset)) continue;
    kept.add(ref);
  }
  kept.sort((a, b) => a.offset.compareTo(b.offset));
  return List.unmodifiable(kept);
}

/// Placeholder characters in [body] that no ref claims.
///
/// These are the scar left by a client that understood the text but not the
/// images — it kept the U+FFFC and dropped the ref, so the note now renders a
/// box with nothing in it. The editor strips them on load rather than drawing
/// a permanent hole in somebody's note.
List<int> orphanedAttachmentAnchors(
  String body,
  Iterable<NoteAttachmentRef> refs,
) {
  final claimed = {for (final ref in refs) ref.offset};
  final orphans = <int>[];
  for (var i = 0; i < body.length; i++) {
    if (body.codeUnitAt(i) == 0xFFFC && !claimed.contains(i)) orphans.add(i);
  }
  return orphans;
}

/// Rebases image anchors across the one contiguous edit between two texts.
///
/// An image whose placeholder fell inside the replaced span is gone — that is
/// what deleting an image *is* — and anything after it slides by the length
/// delta.
///
/// Working out *which* span was replaced is the whole difficulty, because
/// U+FFFC characters are identical to each other. Delete the middle of three
/// adjacent images and the resulting string is the same one you would get by
/// deleting the first or the last, so a prefix/suffix diff — which is all
/// `rebaseNoteFormats` has — cannot tell them apart, and always blames the
/// last. For styles that is a cosmetic slip. For images it deletes the wrong
/// picture, and grids of adjacent images are a thing this app encourages.
///
/// So the edit is recovered from the caret when there is one.
/// [selectionStart] and [selectionEnd] are the selection *in [oldText], before
/// the edit*, which says exactly what was replaced. Every candidate is checked
/// against [newText] before it is believed, so a stale or invented selection
/// falls through to the diff rather than corrupting anything.
List<NoteAttachmentRef> rebaseNoteAttachments({
  required String oldText,
  required String newText,
  required List<NoteAttachmentRef> attachments,
  int? selectionStart,
  int? selectionEnd,
}) {
  if (attachments.isEmpty) return attachments;
  if (oldText == newText) return attachments;

  final region =
      _regionFromSelection(oldText, newText, selectionStart, selectionEnd) ??
      _regionFromDiff(oldText, newText);

  final delta = newText.length - oldText.length;
  final rebased = <NoteAttachmentRef>[];
  for (final ref in attachments) {
    if (ref.offset < region.start) {
      rebased.add(ref);
    } else if (ref.offset >= region.end) {
      rebased.add(ref.copyWith(offset: ref.offset + delta));
    }
    // Anything in [start, end) was replaced: the image is deleted.
  }
  return normalizeNoteAttachments(rebased, newText);
}

/// The replaced span, taken from where the caret was and then verified.
({int start, int end})? _regionFromSelection(
  String oldText,
  String newText,
  int? selectionStart,
  int? selectionEnd,
) {
  if (selectionStart == null || selectionEnd == null) return null;
  if (selectionStart < 0 || selectionEnd < 0) return null;
  final start = selectionStart < selectionEnd ? selectionStart : selectionEnd;
  final end = selectionStart < selectionEnd ? selectionEnd : selectionStart;
  if (end > oldText.length) return null;

  final delta = newText.length - oldText.length;
  final candidates = start != end
      // A selection was replaced, so the span is not in doubt.
      ? [(start: start, end: end)]
      : delta < 0
      // A collapsed caret losing characters is either a backspace or a
      // forward delete. Both are offered; only one will reproduce [newText].
      ? [
          (start: start + delta, end: start),
          (start: start, end: start - delta),
        ]
      : [(start: start, end: start)];

  for (final candidate in candidates) {
    if (_reproduces(oldText, newText, candidate.start, candidate.end)) {
      return candidate;
    }
  }
  return null;
}

/// True when replacing `[start, end)` of [oldText] with some run of characters
/// yields exactly [newText]. This is what keeps a wrong guess from ever being
/// acted on.
bool _reproduces(String oldText, String newText, int start, int end) {
  if (start < 0 || end > oldText.length || start > end) return false;
  final insertedLength = newText.length - oldText.length + (end - start);
  if (insertedLength < 0 || start + insertedLength > newText.length) {
    return false;
  }
  for (var i = 0; i < start; i++) {
    if (oldText.codeUnitAt(i) != newText.codeUnitAt(i)) return false;
  }
  final suffixLength = oldText.length - end;
  for (var i = 0; i < suffixLength; i++) {
    if (oldText.codeUnitAt(end + i) !=
        newText.codeUnitAt(start + insertedLength + i)) {
      return false;
    }
  }
  return true;
}

/// The fallback: match from both ends, exactly as `rebaseNoteFormats` does.
///
/// Used for changes no caret describes — a sync arriving, an import, a
/// formatter rewriting the line. Ambiguity between identical placeholders
/// resolves towards the end of the text, which is arbitrary but consistent.
({int start, int end}) _regionFromDiff(String oldText, String newText) {
  var editStart = 0;
  final sharedStartLimit = oldText.length < newText.length
      ? oldText.length
      : newText.length;
  while (editStart < sharedStartLimit &&
      oldText.codeUnitAt(editStart) == newText.codeUnitAt(editStart)) {
    editStart++;
  }

  var sharedEnd = 0;
  final oldRemaining = oldText.length - editStart;
  final newRemaining = newText.length - editStart;
  final sharedEndLimit = oldRemaining < newRemaining
      ? oldRemaining
      : newRemaining;
  while (sharedEnd < sharedEndLimit &&
      oldText.codeUnitAt(oldText.length - sharedEnd - 1) ==
          newText.codeUnitAt(newText.length - sharedEnd - 1)) {
    sharedEnd++;
  }

  return (start: editStart, end: oldText.length - sharedEnd);
}

/// Reads a persisted or received attachment list, reconciled against [body].
///
/// Reconciling on the way in is what makes every other path safe to write
/// naively: whatever a file, a sync or an older client hands over, what comes
/// back out is a list where every ref sits on a real placeholder.
List<NoteAttachmentRef> noteAttachmentsFromJson(Object? raw, String body) {
  if (raw is! List) return const [];
  return normalizeNoteAttachments(
    raw.map(NoteAttachmentRef.fromJson).whereType<NoteAttachmentRef>(),
    body,
  );
}
