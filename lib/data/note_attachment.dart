import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Something anchored to one U+FFFC placeholder in a note's body.
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
///     attachment has on a device with no account. Attachments work fully
///     offline, so this is never null.
///   * [attachmentId] is the server's, minted when the file is uploaded, and
///     null until then. A note can be written, read and exported forever
///     without one.
///
/// Dedupe is deliberately local-only. Every file gets its own random [key], so
/// two people storing identical bytes produce different ciphertext and the
/// server could not dedupe them even if it wanted to. Deriving the key from
/// the content instead would buy cross-user dedupe by leaking which users hold
/// the same file, which is not a trade this app makes.
///
/// This is a sealed hierarchy so that every place which renders, exports or
/// syncs an attachment has to say out loud what it does with a kind it does
/// not know. [NoteUnknownRef] is the answer for all of them: keep the bytes of
/// the record exactly as they arrived and put them back on the way out. A
/// client that dropped an unknown ref instead would delete a newer device's
/// attachment on its next push, which is the one failure this design exists to
/// prevent.
sealed class NoteAttachmentRef {
  /// Index of the U+FFFC character this attachment renders at.
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

  /// Size of the stored bytes. What quota is billed on.
  final int bytes;

  /// Server id, null until this attachment has been uploaded.
  final String? attachmentId;

  const NoteAttachmentRef({
    required this.offset,
    required this.hash,
    required this.key,
    required this.mime,
    required this.bytes,
    this.attachmentId,
  });

  /// The character an attachment anchors to. Inert to the calculator lexer.
  static const String placeholder = '￼';

  bool get isUploaded => attachmentId != null;

  /// Only the fields every kind has. Subclasses widen this with their own.
  NoteAttachmentRef copyWith({int? offset, String? attachmentId});

  Map<String, Object?> toJson();

  /// Reads one ref, dispatching on `kind`.
  ///
  /// A record with no `kind` is an image: that is every attachment written
  /// before voice notes existed, and there is no other thing it could be.
  static NoteAttachmentRef? fromJson(Object? raw) {
    if (raw is! Map) return null;

    final offset = raw['offset'];
    final hash = raw['hash'];
    final mime = raw['mime'];
    if (offset is! int || offset < 0) return null;
    if (hash is! String || hash.isEmpty) return null;
    if (mime is! String || mime.isEmpty) return null;

    final Uint8List key;
    try {
      final keyRaw = raw['key'];
      key = base64.decode(keyRaw is String ? keyRaw : '');
    } catch (_) {
      return null;
    }
    if (key.length != 32) return null;

    final bytesRaw = raw['bytes'];
    final bytes = bytesRaw is int ? bytesRaw : 0;
    final attachmentIdRaw = raw['attachmentId'];
    final attachmentId = attachmentIdRaw is String ? attachmentIdRaw : null;

    final kind = raw['kind'];
    switch (kind) {
      case null:
      case 'image':
        return NoteImageRef._fromJson(
          raw,
          offset: offset,
          hash: hash,
          key: key,
          mime: mime,
          bytes: bytes,
          attachmentId: attachmentId,
        );
      case 'voice':
        return NoteVoiceRef._fromJson(
          raw,
          offset: offset,
          hash: hash,
          key: key,
          mime: mime,
          bytes: bytes,
          attachmentId: attachmentId,
        );
      default:
        // Everything the shared fields need is here, so the record is
        // well-formed — it is simply newer than this build. Keep it whole.
        return NoteUnknownRef(
          offset: offset,
          hash: hash,
          key: key,
          mime: mime,
          bytes: bytes,
          attachmentId: attachmentId,
          raw: Map<String, Object?>.unmodifiable(
            raw.map((k, v) => MapEntry('$k', v)),
          ),
        );
    }
  }
}

/// An image. Everything attachments could be before voice notes existed.
final class NoteImageRef extends NoteAttachmentRef {
  /// Intrinsic size of the stored image, in pixels. Held so the editor can
  /// reserve the right box *before* any bytes are decoded — without it every
  /// note with images would reflow as each one loaded.
  final int width;
  final int height;

  /// sha256 of a ~600px preview, stored as its own object under the *same*
  /// file key with its own nonce. The note view fetches only these; the full
  /// image is fetched on tap. Null when the image is small enough that a
  /// thumbnail would cost more than it saves.
  final String? thumbHash;

  final String? thumbId;

  /// How much of the writing column this image takes, from
  /// [minWidthFactor] to 1.
  ///
  /// Part of the note's content, not a per-device view setting: a picture
  /// sized down to sit beside a paragraph should look the same on the laptop
  /// it was sized on, the phone that syncs it, and the markdown that exports
  /// it. Ignored for an image sharing its line with others, where the number
  /// of tiles decides the width instead.
  final double widthFactor;

  const NoteImageRef({
    required super.offset,
    required super.hash,
    required super.key,
    required super.mime,
    required this.width,
    required this.height,
    required super.bytes,
    this.thumbHash,
    this.widthFactor = 1,
    super.attachmentId,
    this.thumbId,
  });

  /// Narrower than this and an image stops being a picture and starts being a
  /// smudge, so the handle refuses to go further.
  static const double minWidthFactor = 0.25;

  /// Aspect ratio, guarded so a corrupt record cannot divide by zero and take
  /// the editor's layout down with it.
  double get aspectRatio => height <= 0 || width <= 0 ? 1 : width / height;

  /// A generated preview is part of the image upload. Treating the full-size
  /// object alone as complete strands mobile readers without the lightweight
  /// object they are meant to fetch.
  @override
  bool get isUploaded =>
      attachmentId != null && (thumbHash == null || thumbId != null);

  static NoteImageRef? _fromJson(
    Map<Object?, Object?> raw, {
    required int offset,
    required String hash,
    required Uint8List key,
    required String mime,
    required int bytes,
    required String? attachmentId,
  }) {
    final width = raw['width'];
    final height = raw['height'];
    if (width is! int || height is! int) return null;

    final thumbHash = raw['thumbHash'];
    final widthFactor = raw['widthFactor'];
    final thumbId = raw['thumbId'];
    return NoteImageRef(
      offset: offset,
      hash: hash,
      key: key,
      mime: mime,
      width: width,
      height: height,
      bytes: bytes,
      thumbHash: thumbHash is String ? thumbHash : null,
      widthFactor: widthFactor is num
          ? clampImageWidthFactor(widthFactor.toDouble())
          : 1,
      attachmentId: attachmentId,
      thumbId: thumbId is String ? thumbId : null,
    );
  }

  @override
  NoteImageRef copyWith({
    int? offset,
    double? widthFactor,
    String? attachmentId,
    String? thumbId,
  }) => NoteImageRef(
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

  @override
  Map<String, Object?> toJson() => {
    // `kind` is omitted for images on purpose. It is the default on the way
    // in, so writing it would change every existing note's bytes for nothing
    // and make a no-op edit look like a real one to sync.
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

  @override
  bool operator ==(Object other) =>
      other is NoteImageRef &&
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

/// One span of transcribed speech.
///
/// The field names are single letters because a half-hour recording runs to
/// thousands of these and the whole list rides inside the note's sealed
/// payload, which is pushed on every edit.
class TranscriptSegment {
  /// Milliseconds from the start of the recording.
  final int s;
  final int e;
  final String t;

  /// Who said it, numbered from zero in the order they first spoke.
  ///
  /// Null when the provider did not separate speakers. Null and zero are
  /// different facts — "nobody looked" against "one person, throughout" —
  /// and the transcript view draws them differently: a single speaker gets
  /// no labels at all, because a memo somebody recorded alone should not
  /// grow a column saying so.
  final int? speaker;

  const TranscriptSegment({
    required this.s,
    required this.e,
    required this.t,
    this.speaker,
  });

  static TranscriptSegment? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final s = raw['s'];
    final e = raw['e'];
    final t = raw['t'];
    final speaker = raw['sp'];
    if (s is! int || s < 0) return null;
    if (e is! int || e < 0) return null;
    if (t is! String) return null;
    return TranscriptSegment(
      s: s,
      e: e,
      t: t,
      speaker: speaker is int && speaker >= 0 ? speaker : null,
    );
  }

  Map<String, Object?> toJson() => {
    's': s,
    'e': e,
    't': t,
    if (speaker != null) 'sp': speaker,
  };

  @override
  bool operator ==(Object other) =>
      other is TranscriptSegment &&
      other.s == s &&
      other.e == e &&
      other.t == t &&
      other.speaker == speaker;

  @override
  int get hashCode => Object.hash(s, e, t, speaker);
}

/// What an engine heard, and when.
///
/// [engine] and [at] together are the transcript's identity. Comparing those
/// two integers-and-a-string is how [NoteVoiceRef] tells two transcripts apart
/// without ever walking the segments — see the note on [NoteVoiceRef.==].
class VoiceTranscript {
  /// ISO-639-1 where the provider knows it, else the provider's own word,
  /// lowercased. Not an enum: providers invent labels.
  final String lang;

  /// e.g. `cf/deepgram-nova-3`, later `sherpa/...`.
  final String engine;

  /// Epoch milliseconds.
  final int at;

  final List<TranscriptSegment> segments;

  /// The server's handle on the transcription this came from.
  ///
  /// Kept here rather than only in the transcription queue, which forgets it
  /// the moment both stages finish. Without it, asking for a second summary
  /// — or a post written from this transcript — a week later has nothing to
  /// bill against, and the server rightly refuses. Null for a transcript no
  /// server made, which is every local one.
  final String? jobId;

  /// What the user has called each speaker, by speaker number.
  ///
  /// Empty until somebody names one: a number is a perfectly good name for a
  /// voice you have not identified, and inventing "Speaker 1" as stored data
  /// would mean syncing a name nobody chose.
  final Map<int, String> speakers;

  VoiceTranscript({
    required this.lang,
    required this.engine,
    required this.at,
    required List<TranscriptSegment> segments,
    this.jobId,
    Map<int, String> speakers = const {},
  }) : segments = List.unmodifiable(segments),
       speakers = Map.unmodifiable(speakers);

  /// Every distinct speaker, in the order they first spoke.
  ///
  /// Empty when the provider named nobody, which is the signal the transcript
  /// view uses to draw itself exactly as it always has.
  List<int> get speakerIds {
    final seen = <int>[];
    for (final segment in segments) {
      final speaker = segment.speaker;
      if (speaker != null && !seen.contains(speaker)) seen.add(speaker);
    }
    return seen;
  }

  /// What to call [speaker] on screen: their name, or their number.
  String nameFor(int speaker) {
    final given = speakers[speaker];
    if (given != null && given.trim().isNotEmpty) return given.trim();
    return 'Speaker ${speaker + 1}';
  }

  /// The same transcript with one speaker renamed. A blank name is a removal
  /// rather than an empty label.
  VoiceTranscript renaming(int speaker, String? name) {
    final next = {...speakers};
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty) {
      next.remove(speaker);
    } else {
      next[speaker] = trimmed.length > 40 ? trimmed.substring(0, 40) : trimmed;
    }
    return VoiceTranscript(
      lang: lang,
      engine: engine,
      at: at,
      segments: segments,
      jobId: jobId,
      speakers: next,
    );
  }

  /// Everything the transcript says, joined. What search matches on.
  String get text => segments.map((segment) => segment.t).join(' ');

  static VoiceTranscript? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final lang = raw['lang'];
    final engine = raw['engine'];
    final at = raw['at'];
    final segments = raw['segments'];
    if (lang is! String || engine is! String || at is! int) return null;
    if (segments is! List) return null;
    final jobId = raw['jobId'];
    final speakers = raw['speakers'];
    return VoiceTranscript(
      lang: lang,
      engine: engine,
      at: at,
      segments: segments
          .map(TranscriptSegment.fromJson)
          .whereType<TranscriptSegment>()
          .toList(growable: false),
      jobId: jobId is String && jobId.isNotEmpty ? jobId : null,
      speakers: speakers is Map
          ? {
              for (final entry in speakers.entries)
                if (int.tryParse('${entry.key}') case final int id)
                  if (entry.value is String) id: entry.value as String,
            }
          : const {},
    );
  }

  Map<String, Object?> toJson() => {
    'lang': lang,
    'engine': engine,
    'at': at,
    'segments': segments.map((segment) => segment.toJson()).toList(),
    if (jobId != null) 'jobId': jobId,
    if (speakers.isNotEmpty)
      'speakers': {
        for (final entry in speakers.entries) '${entry.key}': entry.value,
      },
  };

  /// Identity, not content — with one exception. See [NoteVoiceRef.==].
  ///
  /// The speaker names are compared properly, because they are the one part
  /// of a transcript the user edits: renaming somebody leaves the engine,
  /// the timestamp and the segment count identical, and a cheap comparison
  /// would decide the note had not changed and never sync the new name.
  /// There are at most a handful of them, so this stays cheap.
  @override
  bool operator ==(Object other) =>
      other is VoiceTranscript &&
      other.engine == engine &&
      other.at == at &&
      other.lang == lang &&
      other.jobId == jobId &&
      other.segments.length == segments.length &&
      mapEquals(other.speakers, speakers);

  @override
  int get hashCode =>
      Object.hash(engine, at, lang, jobId, segments.length, speakers.length);
}

/// What the recording was about, in a title and a few points.
class VoiceSummary {
  final String engine;
  final int at;
  final String title;
  final List<String> points;

  VoiceSummary({
    required this.engine,
    required this.at,
    required this.title,
    required List<String> points,
  }) : points = List.unmodifiable(points);

  static VoiceSummary? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final engine = raw['engine'];
    final at = raw['at'];
    final title = raw['title'];
    final points = raw['points'];
    if (engine is! String || at is! int || title is! String) return null;
    if (points is! List) return null;
    final kept = points.whereType<String>().toList(growable: false);
    if (kept.isEmpty) return null;
    return VoiceSummary(engine: engine, at: at, title: title, points: kept);
  }

  Map<String, Object?> toJson() => {
    'engine': engine,
    'at': at,
    'title': title,
    'points': points,
  };

  /// Identity, not content. See [NoteVoiceRef.==].
  @override
  bool operator ==(Object other) =>
      other is VoiceSummary &&
      other.engine == engine &&
      other.at == at &&
      other.points.length == points.length &&
      other.title == title;

  @override
  int get hashCode => Object.hash(engine, at, title, points.length);
}

/// Which rewrite produced a take.
///
/// The two presets carry their wording in the app rather than on the note,
/// so the instruction behind "Post for X" can be improved without migrating
/// everything anybody ever generated.
enum VoiceTakeKind {
  x,
  linkedin,
  custom;

  static VoiceTakeKind? parse(Object? raw) => switch (raw) {
    'x' => VoiceTakeKind.x,
    'linkedin' => VoiceTakeKind.linkedin,
    'custom' => VoiceTakeKind.custom,
    _ => null,
  };

  /// What the card calls it.
  String get label => switch (this) {
    VoiceTakeKind.x => 'Post for X',
    VoiceTakeKind.linkedin => 'Post for LinkedIn',
    VoiceTakeKind.custom => 'Your instruction',
  };
}

/// One thing written from the transcript because the user asked for it.
///
/// Free text rather than a title and points: a post is a paragraph, and
/// forcing it into the summary's shape would make it a worse post. Kept on
/// the note because it cost a model call, it was asked for deliberately, and
/// something written on the desktop is wanted on the phone.
class VoiceTake {
  final VoiceTakeKind kind;

  /// What was asked for, in the user's words. Only ever set for
  /// [VoiceTakeKind.custom] — the presets would only be repeating themselves.
  final String? instruction;

  final String text;
  final String engine;

  /// Epoch milliseconds. Also this take's identity: two of them cannot be
  /// written in the same millisecond by the same person.
  final int at;

  const VoiceTake({
    required this.kind,
    required this.text,
    required this.engine,
    required this.at,
    this.instruction,
  });

  static VoiceTake? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final kind = VoiceTakeKind.parse(raw['kind']);
    final text = raw['text'];
    final engine = raw['engine'];
    final at = raw['at'];
    if (kind == null || text is! String || engine is! String || at is! int) {
      return null;
    }
    if (text.trim().isEmpty) return null;
    final instruction = raw['instruction'];
    return VoiceTake(
      kind: kind,
      text: text,
      engine: engine,
      at: at,
      instruction: instruction is String && instruction.isNotEmpty
          ? instruction
          : null,
    );
  }

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'text': text,
    'engine': engine,
    'at': at,
    if (instruction != null) 'instruction': instruction,
  };

  @override
  bool operator ==(Object other) =>
      other is VoiceTake && other.at == at && other.kind == kind;

  @override
  int get hashCode => Object.hash(at, kind);
}

/// A recording.
///
/// [durationMs] and [peaks] are held for the same reason an image carries its
/// intrinsic size: the chip draws itself, at the right size and with its
/// waveform, before a single audio byte is read. Without them every note with
/// a recording would reflow as each one loaded.
///
/// [transcript] and [summary] are optional at every moment of their life. A
/// recording made offline, or by someone who never turned transcription on, is
/// a complete and valid voice note forever — it is simply one you listen to.
final class NoteVoiceRef extends NoteAttachmentRef {
  final int durationMs;

  /// Exactly 100 bytes when present: one unsigned level per 1% of the
  /// recording, bucketed from 10 Hz amplitude samples rather than from PCM, so
  /// nothing large ever crosses the UI isolate to draw a waveform.
  final Uint8List? peaks;

  final VoiceTranscript? transcript;
  final VoiceSummary? summary;

  /// Posts and rewrites the user asked for, oldest first.
  ///
  /// Capped at [maxTakes] because these ride inside the note's payload and
  /// nobody needs a seventh version of the same post; the oldest goes when a
  /// new one arrives, which is what somebody trying wordings expects.
  final List<VoiceTake> takes;

  const NoteVoiceRef({
    required super.offset,
    required super.hash,
    required super.key,
    required super.bytes,
    required this.durationMs,
    super.mime = voiceMime,
    this.peaks,
    this.transcript,
    this.summary,
    this.takes = const [],
    super.attachmentId,
  });

  static const int maxTakes = 6;

  /// What `record` writes on every platform: AAC-LC in an MPEG-4 container.
  static const String voiceMime = 'audio/mp4';

  /// The file extension the blob is stored under. Not cosmetic: iOS picks its
  /// decoder from the extension, so a recording saved without one will not
  /// play back there.
  static const String voiceExtension = '.m4a';

  static const int peaksLength = 100;

  Duration get duration => Duration(milliseconds: durationMs);

  static NoteVoiceRef? _fromJson(
    Map<Object?, Object?> raw, {
    required int offset,
    required String hash,
    required Uint8List key,
    required String mime,
    required int bytes,
    required String? attachmentId,
  }) {
    final durationMs = raw['durationMs'];
    if (durationMs is! int || durationMs <= 0) return null;

    // A malformed transcript or summary is dropped on its own. Losing the
    // words is a bad afternoon; losing the ref loses the recording.
    return NoteVoiceRef(
      offset: offset,
      hash: hash,
      key: key,
      mime: mime,
      bytes: bytes,
      durationMs: durationMs,
      peaks: _peaksFromJson(raw['peaks']),
      transcript: VoiceTranscript.fromJson(raw['transcript']),
      summary: VoiceSummary.fromJson(raw['summary']),
      takes: _takesFromJson(raw['takes']),
      attachmentId: attachmentId,
    );
  }

  static List<VoiceTake> _takesFromJson(Object? raw) {
    if (raw is! List) return const [];
    final kept = raw
        .map(VoiceTake.fromJson)
        .whereType<VoiceTake>()
        .toList(growable: false);
    // A payload that somehow carries more than the cap is trimmed to the
    // newest rather than refused: losing a post is better than losing the
    // recording it was written from.
    if (kept.length <= maxTakes) return kept;
    return kept.sublist(kept.length - maxTakes);
  }

  static Uint8List? _peaksFromJson(Object? raw) {
    if (raw is! String) return null;
    try {
      final decoded = base64.decode(raw);
      return decoded.length == peaksLength ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// Sentinel telling [copyWith] "leave this alone", which a plain null cannot
  /// do here: clearing a transcript and not touching one are different things.
  static const Object _keep = Object();

  @override
  NoteVoiceRef copyWith({
    int? offset,
    String? attachmentId,
    Object? transcript = _keep,
    Object? summary = _keep,
    List<VoiceTake>? takes,
  }) => NoteVoiceRef(
    offset: offset ?? this.offset,
    hash: hash,
    key: key,
    mime: mime,
    bytes: bytes,
    durationMs: durationMs,
    peaks: peaks,
    transcript: identical(transcript, _keep)
        ? this.transcript
        : transcript as VoiceTranscript?,
    summary: identical(summary, _keep)
        ? this.summary
        : summary as VoiceSummary?,
    takes: takes ?? this.takes,
    attachmentId: attachmentId ?? this.attachmentId,
  );

  /// The same recording with [take] added, dropping the oldest past the cap.
  NoteVoiceRef withTake(VoiceTake take) {
    final next = [...takes.where((held) => held != take), take];
    return copyWith(
      takes: next.length <= maxTakes
          ? next
          : next.sublist(next.length - maxTakes),
    );
  }

  NoteVoiceRef withoutTake(VoiceTake take) =>
      copyWith(takes: takes.where((held) => held != take).toList());

  /// Clears the server id, so the next sync uploads the bytes again.
  ///
  /// Used when a release has already freed the server's copy but the user
  /// brought the attachment back with Undo.
  NoteVoiceRef withoutAttachmentId() => NoteVoiceRef(
    offset: offset,
    hash: hash,
    key: key,
    mime: mime,
    bytes: bytes,
    durationMs: durationMs,
    peaks: peaks,
    transcript: transcript,
    summary: summary,
    takes: takes,
  );

  @override
  Map<String, Object?> toJson() => {
    'kind': 'voice',
    'offset': offset,
    'hash': hash,
    'key': base64.encode(key),
    'mime': mime,
    'bytes': bytes,
    'durationMs': durationMs,
    if (peaks != null) 'peaks': base64.encode(peaks!),
    if (transcript != null) 'transcript': transcript!.toJson(),
    if (summary != null) 'summary': summary!.toJson(),
    if (takes.isNotEmpty) 'takes': takes.map((take) => take.toJson()).toList(),
    if (attachmentId != null) 'attachmentId': attachmentId,
  };

  /// Equality is deliberately constant-time in the length of the transcript.
  ///
  /// Every keystroke rebases the attachment list and compares the result
  /// against the old one to decide whether the note is dirty. A half-hour
  /// recording carries thousands of segments and tens of thousands of words;
  /// comparing those on each keystroke would put a visible stutter into typing
  /// in exactly the notes people record into. `engine` and `at` already
  /// identify a transcript — the same engine cannot produce two different
  /// transcripts in the same millisecond — so the content never needs walking.
  ///
  /// [peaks] is compared by presence and length for the same reason: it is a
  /// pure function of the audio, which [hash] already pins down.
  @override
  bool operator ==(Object other) =>
      other is NoteVoiceRef &&
      other.offset == offset &&
      other.hash == hash &&
      other.mime == mime &&
      other.bytes == bytes &&
      other.durationMs == durationMs &&
      other.peaks?.length == peaks?.length &&
      other.transcript == transcript &&
      other.summary == summary &&
      // By identity, and cheaply: a take is written once and never edited,
      // so the timestamps being the same set means the takes are the same.
      listEquals(other.takes, takes) &&
      other.attachmentId == attachmentId;

  @override
  int get hashCode => Object.hash(
    offset,
    hash,
    mime,
    bytes,
    durationMs,
    peaks?.length,
    transcript,
    summary,
    attachmentId,
  );
}

/// An attachment written by a newer build than this one.
///
/// It renders as a small "needs a newer Kapy Notes" chip and is otherwise
/// inert — but it is kept, and [toJson] puts back exactly the record that
/// arrived, with only [offset] moved to wherever the placeholder has slid to.
/// That is the whole point: an older device may open, edit and push a note
/// full of things it cannot draw, and nothing is lost when it does.
final class NoteUnknownRef extends NoteAttachmentRef {
  /// The record as it arrived, re-emitted verbatim.
  final Map<String, Object?> raw;

  const NoteUnknownRef({
    required super.offset,
    required super.hash,
    required super.key,
    required super.mime,
    required super.bytes,
    required super.attachmentId,
    required this.raw,
  });

  /// What the newer build called it. Shown to nobody; useful in logs.
  String get kind => raw['kind'] is String ? raw['kind'] as String : 'unknown';

  @override
  NoteUnknownRef copyWith({int? offset, String? attachmentId}) =>
      NoteUnknownRef(
        offset: offset ?? this.offset,
        hash: hash,
        key: key,
        mime: mime,
        bytes: bytes,
        attachmentId: attachmentId ?? this.attachmentId,
        raw: raw,
      );

  @override
  Map<String, Object?> toJson() => {...raw, 'offset': offset};

  @override
  bool operator ==(Object other) =>
      other is NoteUnknownRef &&
      other.offset == offset &&
      other.hash == hash &&
      other.kind == kind &&
      other.attachmentId == attachmentId;

  @override
  int get hashCode => Object.hash(offset, hash, kind, attachmentId);
}

/// Keeps a width inside the range the handle allows, and treats anything
/// nonsensical — a NaN from a corrupt record, a negative from a bad edit — as
/// full width rather than as a reason to fail.
double clampImageWidthFactor(double value) {
  if (value.isNaN || value <= 0) return 1;
  return value.clamp(NoteImageRef.minWidthFactor, 1.0);
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
      ? [(start: start + delta, end: start), (start: start, end: start - delta)]
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
