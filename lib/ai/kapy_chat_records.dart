import 'dart:convert';

import 'package:crypto/crypto.dart' as hashes;

import '../data/stamped.dart';
import 'kapy_ai.dart';

/// A chat as the records it syncs as. One for the chat, and one for each
/// message, or each part of a long one: a record holds about 3 KB, and an
/// answer can be longer. Mirrors `packages/contract/src/chats.ts`.

/// One record's plaintext: 4096 base64 characters less the 16-byte tag.
const int chatPayloadMax = 4096 ~/ 4 * 3 - 16;

/// The most parts a message is split into; the text past them stays on the
/// device that wrote it.
const int chatMessagePartsMax = 16;

/// The most chat records one account holds live, of the 20,000 the record
/// stream allows in all. A push over that limit is refused whole, tasks and
/// tags with it, so chats stop short of it.
const int chatRecordsMax = 8000;

/// A chat's title, in characters, as the contract allows.
const int chatTitleMax = 120;

/// The most that a message's list of notes may take of a record before the
/// notes at its end are left off, so the text keeps room.
const int _readBytesMax = 1400;

const String chatKind = 'chat';
const String chatMessageKind = 'chatMessage';

/// A record on this device, by what it is: `c:<chat>` for a chat,
/// `m:<chat>:<message>:<part>` for a part of a message. The account's record
/// ids derive from these under its key (`Vault.chatRecordId`).
String chatKey(String chatId) => 'c:$chatId';
String messageKey(String chatId, String messageId, int part) =>
    'm:$chatId:$messageId:$part';

/// The chat a key belongs to.
String chatOfKey(String key) => key.split(':')[1];

/// A short fingerprint of a payload, to tell what the server holds from what
/// this device would send.
String chatSig(Map<String, Object?> payload) => hashes.sha256
    .convert(utf8.encode(jsonEncode(payload)))
    .toString()
    .substring(0, 24);

/// A chat's own record: title and model, each with the moment it was set, so
/// a rename on one device and another model on a second both hold.
class ChatMeta {
  ChatMeta({
    required this.chatId,
    required this.title,
    required this.model,
    required this.createdAt,
    this.extra = const {},
  });

  factory ChatMeta.of(KapyChat chat) => ChatMeta(
    chatId: chat.id,
    title: Stamped(
      String.fromCharCodes(chat.title.runes.take(chatTitleMax)),
      chat.titleAt.millisecondsSinceEpoch,
    ),
    model: Stamped(chat.model.toJson(), chat.modelAt.millisecondsSinceEpoch),
    createdAt: chat.createdAt.millisecondsSinceEpoch,
    extra: {
      if (chat.recording case final recording?)
        recordingField: recording.toJson(),
    },
  );

  final String chatId;
  final Stamped<String> title;
  final Stamped<Map<String, Object?>> model;
  final int createdAt;

  /// Fields a later build wrote, kept and written back. The chat's
  /// recording rides here too, as [recordingField], so a build from before
  /// it, which keeps whatever it does not know, writes it back on a rename.
  final Map<String, Object?> extra;

  static const String recordingField = 'recording';

  KapyRecordingRef? get recording =>
      KapyRecordingRef.fromJson(extra[recordingField]);

  static const _known = {'kind', 'chatId', 'title', 'model', 'createdAt'};

  /// Field by field, the same whichever side merges.
  ChatMeta merge(ChatMeta other) => ChatMeta(
    chatId: chatId,
    title: title.merge(other.title),
    model: model.merge(other.model),
    createdAt: createdAt < other.createdAt ? createdAt : other.createdAt,
    extra: mergeExtra(extra, other.extra),
  );

  Map<String, Object?> toPayload() => {
    ...extra,
    'kind': chatKind,
    'chatId': chatId,
    'title': title.toJson(),
    'model': model.toJson(),
    'createdAt': createdAt,
  };

  /// Null for a payload missing anything this build needs.
  static ChatMeta? fromPayload(Object? raw) {
    if (raw is! Map) return null;
    final chatId = raw['chatId'];
    final title = Stamped.fromJson<String>(raw['title']);
    final model = Stamped.fromJson<Map>(raw['model']);
    final createdAt = raw['createdAt'];
    if (chatId is! String ||
        title == null ||
        title.v.isEmpty ||
        model == null ||
        createdAt is! int) {
      return null;
    }
    return ChatMeta(
      chatId: chatId,
      title: Stamped(
        String.fromCharCodes(title.v.runes.take(chatTitleMax)),
        title.at,
      ),
      model: Stamped(model.v.cast<String, Object?>(), model.at),
      createdAt: createdAt,
      extra: {
        for (final entry in raw.entries)
          if (entry.key is String && !_known.contains(entry.key))
            entry.key as String: entry.value,
      },
    );
  }
}

/// One part of a message. Part 0 carries what is not text.
class ChatMessagePart {
  ChatMessagePart({
    required this.chatId,
    required this.messageId,
    required this.part,
    required this.parts,
    required this.text,
    this.role,
    this.at,
    this.read = const [],
    this.matching = 0,
    this.model,
    this.readTo,
  });

  final String chatId;
  final String messageId;
  final int part;
  final int parts;
  final String text;
  final KapyRole? role;
  final int? at;
  final List<KapyNoteRef> read;
  final int matching;
  final KapyModel? model;
  final int? readTo;

  String get key => messageKey(chatId, messageId, part);

  Map<String, Object?> toPayload() => {
    'kind': chatMessageKind,
    'chatId': chatId,
    'messageId': messageId,
    'part': part,
    'parts': parts,
    'text': text,
    if (role != null) 'role': role!.name,
    if (at != null) 'at': at,
    if (read.isNotEmpty)
      'read': [
        for (final note in read)
          {
            'noteId': note.noteId,
            'title': note.title,
            'edited': note.edited.millisecondsSinceEpoch,
          },
      ],
    if (matching > 0) 'matching': matching,
    if (model != null) 'model': model!.toJson(),
    if (readTo != null) 'readTo': readTo,
  };

  /// Null for a payload that is not a whole part this build can read.
  static ChatMessagePart? fromPayload(Object? raw) {
    if (raw is! Map) return null;
    final chatId = raw['chatId'];
    final messageId = raw['messageId'];
    final part = raw['part'];
    final parts = raw['parts'];
    final text = raw['text'];
    if (chatId is! String ||
        messageId is! String ||
        part is! int ||
        parts is! int ||
        text is! String ||
        part < 0 ||
        parts < 1 ||
        parts > chatMessagePartsMax ||
        part >= parts) {
      return null;
    }
    final role = KapyRole.values.asNameMap()[raw['role']];
    final at = raw['at'];
    if (part == 0 && (role == null || at is! int)) return null;
    return ChatMessagePart(
      chatId: chatId,
      messageId: messageId,
      part: part,
      parts: parts,
      text: text,
      role: role,
      at: at is int ? at : null,
      read: [
        for (final note in (raw['read'] as List?) ?? const [])
          if (note is Map &&
              note['noteId'] is String &&
              note['title'] is String &&
              note['edited'] is int)
            KapyNoteRef(
              noteId: note['noteId'] as String,
              title: note['title'] as String,
              edited: DateTime.fromMillisecondsSinceEpoch(
                note['edited'] as int,
              ),
            ),
      ],
      matching: raw['matching'] is int ? raw['matching'] as int : 0,
      model: KapyModel.fromJson(raw['model']),
      readTo: raw['readTo'] is int ? raw['readTo'] as int : null,
    );
  }
}

/// [message] as the parts that carry it, each within [chatPayloadMax]. The
/// notes it read go as their id and when they were edited, with no title: a
/// record never changes, so a title sent now would stay in it after the note
/// was hidden. Each device names a note from its own notes. The ones at the
/// end are left off if they would crowd the text out, and so is text past
/// [chatMessagePartsMax] parts.
List<ChatMessagePart> chatMessageParts(String chatId, KapyMessage message) {
  var read = [
    for (final note in message.read)
      KapyNoteRef(noteId: note.noteId, title: '', edited: note.edited),
  ];
  ChatMessagePart head(String text, int parts) => ChatMessagePart(
    chatId: chatId,
    messageId: message.id,
    part: 0,
    parts: parts,
    text: text,
    role: message.role,
    at: message.at.millisecondsSinceEpoch,
    read: read,
    matching: message.matching,
    model: message.model,
    readTo: message.readTo?.inMilliseconds,
  );
  int size(ChatMessagePart part) =>
      utf8.encode(jsonEncode(part.toPayload())).length;
  while (read.isNotEmpty &&
      size(head('', chatMessagePartsMax)) > _readBytesMax) {
    read = read.sublist(0, read.length - 1);
  }
  final firstRoom = chatPayloadMax - size(head('', chatMessagePartsMax));
  final laterRoom =
      chatPayloadMax -
      size(
        ChatMessagePart(
          chatId: chatId,
          messageId: message.id,
          part: chatMessagePartsMax - 1,
          parts: chatMessagePartsMax,
          text: '',
        ),
      );
  final slices = <String>[];
  final runes = message.text.runes.toList();
  var at = 0;
  do {
    var room = slices.isEmpty ? firstRoom : laterRoom;
    final start = at;
    while (at < runes.length) {
      final cost = _jsonBytes(runes[at]);
      if (cost > room) break;
      room -= cost;
      at++;
    }
    slices.add(String.fromCharCodes(runes.sublist(start, at)));
  } while (at < runes.length && slices.length < chatMessagePartsMax);
  return [
    head(slices.first, slices.length),
    for (var i = 1; i < slices.length; i++)
      ChatMessagePart(
        chatId: chatId,
        messageId: message.id,
        part: i,
        parts: slices.length,
        text: slices[i],
      ),
  ];
}

/// What one character of text takes in a JSON string, in UTF-8 bytes.
int _jsonBytes(int rune) {
  if (rune == 0x22 || rune == 0x5c) return 2;
  if (rune < 0x20) {
    return const {8, 9, 10, 12, 13}.contains(rune) ? 2 : 6;
  }
  if (rune < 0x80) return 1;
  if (rune < 0x800) return 2;
  if (rune >= 0xd800 && rune < 0xe000) return 6;
  return rune < 0x10000 ? 3 : 4;
}

/// The message [parts] make once all are in, or null while any is missing.
KapyMessage? chatMessageOf(List<ChatMessagePart> parts) {
  if (parts.isEmpty) return null;
  final byPart = {for (final part in parts) part.part: part};
  final head = byPart[0];
  if (head == null || byPart.length != head.parts) return null;
  for (var i = 0; i < head.parts; i++) {
    if (byPart[i] == null || byPart[i]!.parts != head.parts) return null;
  }
  return KapyMessage(
    id: head.messageId,
    role: head.role!,
    text: [for (var i = 0; i < head.parts; i++) byPart[i]!.text].join(),
    at: DateTime.fromMillisecondsSinceEpoch(head.at!),
    read: head.read,
    matching: head.matching,
    model: head.model,
    readTo: head.readTo == null ? null : Duration(milliseconds: head.readTo!),
  );
}
