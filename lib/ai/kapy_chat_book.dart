import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/local_store.dart';
import 'kapy_ai.dart';
import 'kapy_ai_store.dart';
import 'kapy_chat_records.dart';

/// A chat record the server is owed: its key (see [chatKey]), the
/// `updatedAt` to send, the payload (null for a deletion) and its
/// fingerprint.
typedef OwedChat = ({
  String key,
  int updatedAt,
  Map<String, Object?>? payload,
  String? sig,
});

/// What the server holds for one record, as of the last push or pull.
class _Known {
  const _Known(this.at, this.sig);

  final int at;
  final String sig;
}

/// The person's Kapy AI chats, and what it takes to sync them.
///
/// The chats and the ids of the deleted ones are kept in [KapyAiStore]'s
/// record. Beside them, under `kapyAi.chatSync.v1`, is what this device knows
/// of the account's copy: which records the server holds and what each said,
/// pieces of messages that came in before the rest, and the chats deleted
/// while sync was off. Nothing here talks to the network: `TaskSync` asks
/// what is [owed], and hands over what it pulls.
///
/// Chats sync only while [syncing], which `TaskSync` sets for as long as
/// the account has Pro. Without it nothing of a chat is sent, and a chat
/// deleted meanwhile is deleted here only: it is never turned into a deletion
/// on the account later.
class KapyChatBook extends ChangeNotifier {
  KapyChatBook(
    LocalStore store, {
    bool Function()? ready,
    DateTime Function()? now,
  }) : _store = store,
       _chatStore = KapyAiStore(store),
       _ready = ready ?? (() => true),
       _now = now ?? DateTime.now;

  final LocalStore _store;
  final KapyAiStore _chatStore;
  final bool Function() _ready;
  final DateTime Function() _now;

  static const String _key = 'kapyAi.chatSync.v1';

  List<KapyChat>? _chats;
  Map<String, DateTime> _deleted = {};
  final Map<String, _Known> _known = {};
  Map<String, String>? _byRecord;
  String Function(String key)? _recordIdOf;
  final Map<String, int> _synced = {};
  final Map<String, ChatMeta> _meta = {};
  final Map<String, ChatMessagePart> _parked = {};
  final Set<String> _localDeleted = {};
  bool _skipped = false;
  bool Function()? _gate;
  Future<void> Function()? _pull;

  /// Reads what this device holds, once the store has it.
  Future<void> load() async {
    await _store.load();
    _read();
  }

  void _read() {
    if (_chats != null) return;
    _chats = _chatStore.readChats();
    _deleted = _chatStore.readDeleted();
    final raw = _store.read<Map<String, Object?>>(_key);
    _skipped = true;
    if (raw == null) return;
    for (final item in (raw['known'] as List?) ?? const []) {
      if (item is Map &&
          item['k'] is String &&
          item['at'] is int &&
          item['sig'] is String) {
        _known[item['k'] as String] = _Known(
          item['at'] as int,
          item['sig'] as String,
        );
      }
    }
    for (final entry in ((raw['synced'] as Map?) ?? const {}).entries) {
      if (entry.value is int) _synced['${entry.key}'] = entry.value as int;
    }
    for (final item in (raw['meta'] as List?) ?? const []) {
      final meta = ChatMeta.fromPayload(item);
      if (meta != null) _meta[meta.chatId] = meta;
    }
    for (final item in (raw['parked'] as List?) ?? const []) {
      final part = ChatMessagePart.fromPayload(item);
      if (part != null) _parked[part.key] = part;
    }
    _localDeleted.addAll([
      for (final id in (raw['localDeleted'] as List?) ?? const [])
        if (id is String) id,
    ]);
    _skipped = raw['skipped'] == true;
  }

  void _saveLedger() {
    if (_held) {
      _ledgerOwed = true;
      return;
    }
    _ledgerOwed = false;
    _store.put(_key, {
      'known': [
        for (final entry in _known.entries)
          {'k': entry.key, 'at': entry.value.at, 'sig': entry.value.sig},
      ],
      'synced': _synced,
      'meta': [for (final meta in _meta.values) meta.toPayload()],
      'parked': [for (final part in _parked.values) part.toPayload()],
      'localDeleted': _localDeleted.toList(),
      'skipped': _skipped,
    });
  }

  // -------------------------------------------------------------------------
  // The chats

  /// Newest first.
  List<KapyChat> get chats {
    if (_chats == null && _ready()) _read();
    return _chats ?? const [];
  }

  KapyChat? chat(String id) {
    for (final chat in chats) {
      if (chat.id == id) return chat;
    }
    return null;
  }

  /// Puts [chat] in place of the one with its id, at the top.
  void put(KapyChat chat) {
    _chats = [
      chat,
      for (final other in chats)
        if (other.id != chat.id) other,
    ];
    _chatStore.writeChats(_chats!, _deleted);
    notifyListeners();
  }

  /// Deletes a chat for good. Where sync is off, for this device only.
  void delete(String id) {
    if (chat(id) == null) return;
    _remove([id], _now());
    _chatStore.writeChats(_chats!, _deleted);
    notifyListeners();
  }

  /// Deletes every chat, written at once.
  void clear() {
    _remove([for (final chat in chats) chat.id], _now());
    _chatStore.clearChats(_deleted);
    notifyListeners();
  }

  void _remove(List<String> ids, DateTime at) {
    final syncs = syncing;
    _deleted = {..._deleted};
    for (final id in ids) {
      _deleted[id] = at;
      if (!syncs) {
        _localDeleted.add(id);
        for (final key in _known.keys.toList()) {
          if (chatOfKey(key) == id) _unlearn(key);
        }
      }
      _forget(id);
    }
    _chats = [
      for (final chat in chats)
        if (!ids.contains(chat.id)) chat,
    ];
    _saveLedger();
  }

  void _forget(String chatId) {
    _synced.remove(chatId);
    _meta.remove(chatId);
    _parked.removeWhere((_, part) => part.chatId == chatId);
  }

  // -------------------------------------------------------------------------
  // Syncing

  /// Whether chats sync now, as `TaskSync` last said.
  bool get syncing => _gate?.call() ?? false;

  /// `TaskSync` says whether chats sync, for as long as it runs, how to take
  /// in what the account has, and what record id the account gives a key.
  void attach(
    bool Function() gate,
    Future<void> Function() pull,
    String Function(String key) recordIdOf,
  ) {
    _gate = gate;
    _pull = pull;
    _recordIdOf = recordIdOf;
    _byRecord = null;
    notifyListeners();
  }

  void detach() {
    _gate = null;
    _pull = null;
    _recordIdOf = null;
    _byRecord = null;
    notifyListeners();
  }

  /// Takes in what the account has, where chats sync. Whatever stops it
  /// leaves the chats as they are.
  Future<void> pull() async {
    final pull = _pull;
    if (pull == null || !syncing) return;
    try {
      await pull();
    } on Object {
      return;
    }
  }

  /// The plan changed, and with it perhaps [syncing].
  void refreshGate() => notifyListeners();

  /// Whether a pull may have gone by without reading the chats' records, so
  /// the stream is read again from the start once they are on: one went by
  /// while chats were off, or none has run here since a build that reads
  /// them, which an older build's cursor may be past (it keeps them as ids
  /// only). Held until the first pass that does read them, so a device with
  /// no ledger yet counts as skipped.
  bool get skipped => _skipped;

  void markSkipped() {
    if (_skipped) return;
    _skipped = true;
    _saveLedger();
  }

  void clearSkipped() {
    _skipped = false;
    _saveLedger();
  }

  /// Whether the server is owed anything.
  bool get owes {
    if (!syncing) return false;
    _read();
    return chats.any((chat) => _synced[chat.id] != _ms(chat.updatedAt)) ||
        _known.keys.any(_deletedAndLive);
  }

  bool _deletedAndLive(String key) {
    final id = chatOfKey(key);
    return _deleted.containsKey(id) && !_localDeleted.contains(id);
  }

  /// The key of the record this device knows the server holds under
  /// [recordId], from a map that is built once, with each key's id, and
  /// kept as keys come and go, so a lookup costs no more than one.
  String? keyOfRecord(String recordId) {
    _read();
    final recordIdOf = _recordIdOf;
    if (recordIdOf == null) return null;
    return (_byRecord ??= {
      for (final key in _known.keys) recordIdOf(key): key,
    })[recordId];
  }

  void _learn(String key, _Known known) {
    _known[key] = known;
    _byRecord?[_recordIdOf!(key)] = key;
  }

  void _unlearn(String key) {
    if (_known.remove(key) == null) return;
    _byRecord?.remove(_recordIdOf!(key));
  }

  /// What the server has not been told, in the order to send it: for each
  /// chat its own record, then its messages; the deleted chats' records
  /// last. A chat with nothing left to send is marked as in step.
  List<OwedChat> owed() {
    _read();
    final out = <OwedChat>[];
    var room = chatRecordsMax - _known.length;
    Set<String>? held;
    var marked = false;
    for (final chat in chats) {
      if (_synced[chat.id] == _ms(chat.updatedAt)) continue;
      held ??= {
        for (final key in _known.keys)
          if (key.startsWith('m:')) key.split(':').sublist(1, 3).join(':'),
      };
      final mine = <OwedChat>[];
      final own = _own(chat);
      final knownOwn = _known[chatKey(chat.id)];
      if (knownOwn == null || knownOwn.sig != chatSig(own)) {
        mine.add((
          key: chatKey(chat.id),
          updatedAt: _max(_ms(_now()), (knownOwn?.at ?? 0) + 1),
          payload: own,
          sig: chatSig(own),
        ));
      }
      for (final message in chat.messages) {
        if (held.contains('${chat.id}:${message.id}')) continue;
        for (final part in chatMessageParts(chat.id, message)) {
          final payload = part.toPayload();
          mine.add((
            key: part.key,
            updatedAt: _ms(message.at),
            payload: payload,
            sig: chatSig(payload),
          ));
        }
      }
      if (mine.isEmpty) {
        _synced[chat.id] = _ms(chat.updatedAt);
        marked = true;
        continue;
      }
      final fresh = mine.where((item) => !_known.containsKey(item.key)).length;
      if (fresh > room) break;
      room -= fresh;
      out.addAll(mine);
    }
    for (final entry in _known.entries.toList()) {
      if (!_deletedAndLive(entry.key)) continue;
      final deletedAt = _ms(_deleted[chatOfKey(entry.key)]!);
      out.add((
        key: entry.key,
        updatedAt: _max(deletedAt, entry.value.at + 1),
        payload: null,
        sig: null,
      ));
    }
    if (marked) _saveLedger();
    return out;
  }

  /// A chat's own record as it would be sent: this device's title and model
  /// merged with what the server last held, so a field a later build wrote
  /// goes back as it was.
  Map<String, Object?> _own(KapyChat chat) {
    final mine = ChatMeta.of(chat);
    final theirs = _meta[chat.id];
    return (theirs == null ? mine : mine.merge(theirs)).toPayload();
  }

  /// The server took the record as sent.
  void acknowledge(OwedChat item) {
    if (item.payload == null) {
      _unlearn(item.key);
    } else {
      _learn(item.key, _Known(item.updatedAt, item.sig!));
      _synced.remove(chatOfKey(item.key));
    }
    _saveLedger();
  }

  /// A chat's record as the server holds it, from a pull or a lost push.
  void applyRemoteChat(ChatMeta remote, int updatedAt) {
    _read();
    final id = remote.chatId;
    if (_refuses(id, chatKey(id), updatedAt, chatSig(remote.toPayload()))) {
      return;
    }
    _meta[id] = _meta[id]?.merge(remote) ?? remote;
    _learn(chatKey(id), _Known(updatedAt, chatSig(remote.toPayload())));
    final existing = chat(id);
    final merged = existing == null
        ? _meta[id]!
        : ChatMeta.of(existing).merge(_meta[id]!);
    final model = KapyModel.fromJson(merged.model.v);
    if (existing == null) {
      if (model != null) {
        _place(
          KapyChat(
            id: id,
            title: merged.title.v,
            createdAt: DateTime.fromMillisecondsSinceEpoch(merged.createdAt),
            updatedAt: DateTime.fromMillisecondsSinceEpoch(
              _max(merged.title.at, _max(merged.model.at, merged.createdAt)),
            ),
            model: model,
            titleAt: DateTime.fromMillisecondsSinceEpoch(merged.title.at),
            modelAt: DateTime.fromMillisecondsSinceEpoch(merged.model.at),
            recording: merged.recording,
            recap: merged.recap,
          ),
        );
        _assembleAll(id);
      }
    } else {
      final newModel = model != null && model != existing.model;
      final newRecap = jsonEncode(merged.recap) != jsonEncode(existing.recap);
      final changed = merged.title.v != existing.title || newModel || newRecap;
      if (changed) {
        _place(
          KapyChat(
            id: id,
            title: merged.title.v,
            createdAt: existing.createdAt,
            updatedAt: DateTime.fromMillisecondsSinceEpoch(
              _max(
                _ms(existing.updatedAt),
                _max(merged.title.at, merged.model.at),
              ),
            ),
            model: newModel ? model : existing.model,
            messages: existing.messages,
            titleAt: DateTime.fromMillisecondsSinceEpoch(merged.title.at),
            modelAt: newModel
                ? DateTime.fromMillisecondsSinceEpoch(merged.model.at)
                : existing.modelAt,
            recording: existing.recording,
            recap: merged.recap,
          ),
        );
      }
    }
    _finish();
  }

  /// One part of a message as the server holds it. A message joins its chat
  /// once every part and the chat's own record are in.
  void applyRemotePart(ChatMessagePart part, int updatedAt) {
    _read();
    if (_refuses(part.chatId, part.key, updatedAt, chatSig(part.toPayload()))) {
      return;
    }
    _learn(part.key, _Known(updatedAt, chatSig(part.toPayload())));
    if (chat(part.chatId)?.messages.any((m) => m.id == part.messageId) ??
        false) {
      return _finish();
    }
    _parked[part.key] = part;
    _assemble(part.chatId, part.messageId);
    _finish();
  }

  /// A deleted record as the server holds it. A chat's takes the chat with
  /// it for good, and leaves its messages' records owed a deletion.
  void applyRemoteDelete(String key, int updatedAt) {
    _read();
    if (!_known.containsKey(key)) return;
    _unlearn(key);
    if (key.startsWith('c:')) {
      final id = chatOfKey(key);
      _remove([id], DateTime.fromMillisecondsSinceEpoch(updatedAt));
    } else {
      _parked.remove(key);
    }
    _finish();
  }

  /// Whether a record of a deleted chat is not to be taken. One this device
  /// deleted for good is known to the server still, and is deleted there.
  bool _refuses(String chatId, String key, int updatedAt, String sig) {
    if (!_deleted.containsKey(chatId)) return false;
    if (!_localDeleted.contains(chatId)) _learn(key, _Known(updatedAt, sig));
    _finish();
    return true;
  }

  void _assembleAll(String chatId) {
    final messages = {
      for (final part in _parked.values)
        if (part.chatId == chatId) part.messageId,
    };
    for (final id in messages) {
      _assemble(chatId, id);
    }
  }

  void _assemble(String chatId, String messageId) {
    final chat = this.chat(chatId);
    if (chat == null) return;
    final parts = [
      for (final part in _parked.values)
        if (part.chatId == chatId && part.messageId == messageId) part,
    ];
    final message = chatMessageOf(parts);
    if (message == null) return;
    for (final part in parts) {
      _parked.remove(part.key);
    }
    final messages = [...chat.messages, message]
      ..sort((a, b) {
        final byTime = a.at.compareTo(b.at);
        return byTime != 0 ? byTime : a.id.compareTo(b.id);
      });
    _place(
      KapyChat(
        id: chat.id,
        title: chat.title,
        createdAt: chat.createdAt,
        updatedAt: message.at.isAfter(chat.updatedAt)
            ? message.at
            : chat.updatedAt,
        model: chat.model,
        messages: messages,
        titleAt: chat.titleAt,
        modelAt: chat.modelAt,
        recording: chat.recording,
        recap: chat.recap,
      ),
    );
  }

  /// Puts a chat among the others by when it last changed, ahead of any
  /// changed at the same moment.
  void _place(KapyChat chat) {
    final rest = [
      for (final other in chats)
        if (other.id != chat.id) other,
    ];
    var at = 0;
    while (at < rest.length && rest[at].updatedAt.isAfter(chat.updatedAt)) {
      at++;
    }
    _chats = rest..insert(at, chat);
  }

  bool _held = false;
  bool _chatsOwed = false;
  bool _ledgerOwed = false;

  /// Defers the writes until [release], so a pull or a push of many records
  /// writes once instead of once per record. Listeners are still told of
  /// each change.
  void hold() => _held = true;

  void release() {
    _held = false;
    if (_chatsOwed) _writeChats();
    if (_ledgerOwed) _saveLedger();
  }

  void _finish() {
    _writeChats();
    _saveLedger();
    notifyListeners();
  }

  void _writeChats() {
    if (_held) {
      _chatsOwed = true;
      return;
    }
    _chatsOwed = false;
    _chatStore.writeChats(_chats!, _deleted);
  }

  /// Signing out: the chats stay, and everything is owed again to the next
  /// account, whose record ids are its own.
  void forgetAccount() {
    _known.clear();
    _byRecord = null;
    _synced.clear();
    _meta.clear();
    _parked.clear();
    _localDeleted.clear();
    _skipped = false;
    _saveLedger();
  }

  /// Drops everything, for notes let go of on signing in as someone else.
  void forgetEverything() {
    _read();
    _chats = [];
    _deleted = {};
    forgetAccount();
    _chatStore.clearChats(_deleted);
    notifyListeners();
  }

  static int _ms(DateTime time) => time.millisecondsSinceEpoch;

  static int _max(int a, int b) => a > b ? a : b;
}
