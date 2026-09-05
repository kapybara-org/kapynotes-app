import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../data/note.dart';
import '../data/note_format.dart';

/// How long a share link stays openable.
///
/// `forever` is the absence of an expiry rather than a distant date, so a link
/// the user meant to keep cannot rot because of a clock. Mirrors `ShareExpiry`
/// in `packages/contract`.
enum ShareExpiry {
  hour('1h', 'After 1 hour'),
  day('24h', 'After 24 hours'),
  week('7d', 'After 7 days'),
  month('30d', 'After 30 days'),
  forever('forever', 'Never');

  const ShareExpiry(this.wire, this.label);

  /// The value the API expects.
  final String wire;

  /// What the dropdown reads. Phrased as an answer to "Link expires:" so the
  /// row is a sentence rather than a pair of nouns.
  final String label;

  static ShareExpiry fromWire(String? value) => values.firstWhere(
    (expiry) => expiry.wire == value,
    orElse: () => ShareExpiry.forever,
  );
}

/// Live or paused.
///
/// Pausing keeps the row, and therefore the URL: somebody who switches a note
/// off for a week should not have to re-send a new link to everyone they gave
/// the old one to.
enum ShareVisibility {
  public('public'),
  private('private');

  const ShareVisibility(this.wire);

  final String wire;

  bool get isPublic => this == ShareVisibility.public;

  static ShareVisibility fromWire(String? value) =>
      value == 'private' ? ShareVisibility.private : ShareVisibility.public;
}

/// The secret half of a link, held only on the device.
///
/// The server issues [token] and never learns [key]: the key travels in the
/// URL fragment, which a browser does not transmit. Losing it means the link
/// can no longer be reconstructed — which is why it is persisted rather than
/// held in memory, and why replacing it is offered as an explicit action
/// rather than happening silently.
class ShareSecret {
  final String token;
  final Uint8List key;

  const ShareSecret({required this.token, required this.key});

  /// XChaCha20 key width, matching `Vault.keyLength`.
  static const int keyLength = 32;

  /// A fresh key for a new share.
  ///
  /// Never the account's master key. That one opens every note the user owns,
  /// and a URL is the last place it should ever appear.
  static Uint8List newKey() {
    final random = Random.secure();
    final bytes = Uint8List(keyLength);
    for (var i = 0; i < keyLength; i++) {
      bytes[i] = random.nextInt(256);
    }
    return bytes;
  }

  Map<String, Object?> toJson() => {
    'token': token,
    'key': base64.encode(key),
  };

  static ShareSecret? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final token = raw['token'];
    final key = raw['key'];
    if (token is! String || key is! String || token.isEmpty) return null;
    final Uint8List decoded;
    try {
      decoded = base64.decode(key);
    } on FormatException {
      return null;
    }
    return decoded.length == keyLength
        ? ShareSecret(token: token, key: decoded)
        : null;
  }

  /// The link itself.
  ///
  /// Both halves ride in the fragment. The token is there rather than in the
  /// path because the marketing site builds statically — a path segment would
  /// need an SSR adapter or a catch-all rewrite that would swallow the 404
  /// page — and keeping it there means the web host never learns which note
  /// was opened either. Only the API sees the token, and only when the page
  /// fetches the ciphertext.
  Uri linkFor(Uri siteOrigin) {
    final key64 = base64Url.encode(key).replaceAll('=', '');
    return siteOrigin.replace(path: '/s', fragment: '$token.$key64');
  }
}

/// What the server knows about a link.
class ShareState {
  final String token;
  final String noteId;
  final ShareVisibility visibility;

  /// Null means forever.
  final DateTime? expiresAt;
  final DateTime updatedAt;

  const ShareState({
    required this.token,
    required this.noteId,
    required this.visibility,
    required this.expiresAt,
    required this.updatedAt,
  });

  bool get hasExpired =>
      expiresAt != null && expiresAt!.isBefore(DateTime.now());

  /// Whether a visitor opening the link right now would see the note.
  bool get isLive => visibility.isPublic && !hasExpired;

  static ShareState? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final token = raw['token'];
    final noteId = raw['noteId'];
    final updatedAt = raw['updatedAt'];
    if (token is! String || noteId is! String || updatedAt is! String) {
      return null;
    }
    final parsedUpdated = DateTime.tryParse(updatedAt);
    if (parsedUpdated == null) return null;

    final expiresAt = raw['expiresAt'];
    return ShareState(
      token: token,
      noteId: noteId,
      visibility: ShareVisibility.fromWire(raw['visibility'] as String?),
      expiresAt: expiresAt is String ? DateTime.tryParse(expiresAt)?.toLocal() : null,
      updatedAt: parsedUpdated.toLocal(),
    );
  }
}

/// One line's computed value, as this device rendered it.
class SharedResult {
  final int line;
  final String text;

  const SharedResult({required this.line, required this.text});

  Map<String, Object?> toJson() => {'line': line, 'text': text};
}

/// The plaintext sealed under a share key — the whole of what a visitor gets.
///
/// Deliberately not a [NotePayload]. That shape exists to round-trip a note
/// back into the app and carries attachment ids and their per-file keys; this
/// one has nowhere to put them, so a file key cannot reach a public link by
/// anybody forgetting a step.
///
/// It carries the *results* instead. The web viewer has no calculator, and
/// porting the engine to JavaScript would mean two implementations of the
/// thing the product is actually about, drifting apart one rounding rule at a
/// time. The device that already has the engine sends what it computed.
class SharedNote {
  final String title;
  final String body;
  final List<NoteFormatRange> formats;
  final List<SharedResult> results;
  final int updatedAt;

  const SharedNote({
    required this.title,
    required this.body,
    required this.formats,
    required this.results,
    required this.updatedAt,
  });

  /// Matches `SHARED_NOTE_VERSION`.
  static const int version = 1;

  /// The heading the page shows, lifted here so the browser never has to guess
  /// at one. Same rule the notes list uses, kept in step with [Note.title].
  static String titleOf(Note note) {
    final line = note.body
        .split('\n')
        .map((line) => line.trim())
        .firstWhere((line) => line.isNotEmpty, orElse: () => '');
    return line.length <= 200 ? line : line.substring(0, 200);
  }

  factory SharedNote.of(Note note, {required List<SharedResult> results}) =>
      SharedNote(
        title: titleOf(note),
        body: note.body,
        formats: note.formats,
        results: results,
        updatedAt: note.updatedAt.millisecondsSinceEpoch,
      );

  Map<String, Object?> toJson() => {
    'title': title,
    'body': body,
    'formats': formats.map((format) => format.toJson()).toList(),
    'results': results.map((result) => result.toJson()).toList(),
    'updatedAt': updatedAt,
  };
}
