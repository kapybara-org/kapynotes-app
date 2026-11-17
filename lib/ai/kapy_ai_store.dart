import '../data/local_store.dart';
import 'kapy_ai.dart';

/// Kapy AI's settings and chats, in the app's [LocalStore].
///
/// Two records. `kapyAi.v1` holds the settings, and everything in it is
/// about this device: the switch, the default model, which notices were
/// agreed to here. `kapyAi.chats.v1` holds the chats and the ids of the ones
/// deleted. Chats are local in this release, but each is already the record
/// sync will seal: plain JSON with its own id and [KapyChat.updatedAt], and a
/// deletion is kept as an id and a time rather than as an absence, so a device
/// that syncs later can tell "deleted" from "never had it".
///
/// Keys and tokens never come here: they live in the keychain.
class KapyAiStore {
  KapyAiStore(this._store);

  final LocalStore _store;

  static const String _settingsKey = 'kapyAi.v1';
  static const String _chatsKey = 'kapyAi.chats.v1';

  Map<String, Object?> get _settings =>
      _store.read<Map<String, Object?>>(_settingsKey) ?? const {};

  void _set(String key, Object? value) =>
      _store.putNow(_settingsKey, {..._settings, key: value});

  bool get enabled => _settings['enabled'] != false;
  set enabled(bool value) => _set('enabled', value);

  /// Null until somebody picks one in Settings.
  KapyModel? get defaultModel => KapyModel.fromJson(_settings['defaultModel']);
  set defaultModel(KapyModel? value) => _set('defaultModel', value?.toJson());

  /// "Before the first answer", agreed to on this device.
  bool get cloudConsent => _settings['cloudConsent'] == true;
  set cloudConsent(bool value) => _set('cloudConsent', value);

  /// "Goes to OpenAI", once per account.
  bool hasAccountConsent(KapyAccountKind account) =>
      (_settings['accountConsent'] as List?)?.contains(account.name) ?? false;

  void giveAccountConsent(KapyAccountKind account) {
    if (hasAccountConsent(account)) return;
    _set('accountConsent', [
      ...?(_settings['accountConsent'] as List?),
      account.name,
    ]);
  }

  /// Codex's and Claude Code's switches in Settings: on, the default, means
  /// Kapy may run the tool once it finds it signed in.
  bool isToolAllowed(KapyAccountKind tool) =>
      !((_settings['toolsOff'] as List?)?.contains(tool.name) ?? false);

  void allowTool(KapyAccountKind tool, bool allowed) {
    if (isToolAllowed(tool) == allowed) return;
    final off = [...?(_settings['toolsOff'] as List?)];
    allowed ? off.remove(tool.name) : off.add(tool.name);
    _set('toolsOff', off);
  }

  Map<String, Object?> get _chatsRecord =>
      _store.read<Map<String, Object?>>(_chatsKey) ?? const {};

  /// Newest first.
  List<KapyChat> readChats() {
    final chats = [
      for (final raw in (_chatsRecord['chats'] as List?) ?? const [])
        ?chatFromJson(raw),
    ];
    chats.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return chats;
  }

  /// Deleted chats' ids, with when.
  Map<String, DateTime> readDeleted() => {
    for (final entry in ((_chatsRecord['deleted'] as Map?) ?? const {}).entries)
      if (entry.value is int)
        '${entry.key}': DateTime.fromMillisecondsSinceEpoch(entry.value as int),
  };

  /// Chats change every time somebody asks, so they go out with the store's
  /// usual coalescing rather than one write per answer.
  void writeChats(List<KapyChat> chats, Map<String, DateTime> deleted) =>
      _store.put(_chatsKey, {
        'chats': [for (final chat in chats) chatToJson(chat)],
        'deleted': {
          for (final entry in deleted.entries)
            entry.key: entry.value.millisecondsSinceEpoch,
        },
      });

  /// Clearing is somebody deciding the history should be gone, so it is
  /// written at once, like a setting.
  void clearChats(Map<String, DateTime> deleted) {
    writeChats(const [], deleted);
    _store.flush();
  }
}

Map<String, Object?> chatToJson(KapyChat chat) => {
  'id': chat.id,
  'title': chat.title,
  'createdAt': chat.createdAt.millisecondsSinceEpoch,
  'updatedAt': chat.updatedAt.millisecondsSinceEpoch,
  'titleAt': chat.titleAt.millisecondsSinceEpoch,
  'modelAt': chat.modelAt.millisecondsSinceEpoch,
  'model': chat.model.toJson(),
  'messages': [for (final message in chat.messages) _messageToJson(message)],
};

KapyChat? chatFromJson(Object? raw) {
  if (raw is! Map) return null;
  final id = raw['id'];
  final title = raw['title'];
  final model = KapyModel.fromJson(raw['model']);
  if (id is! String || title is! String || model == null) return null;
  return KapyChat(
    id: id,
    title: title,
    createdAt: _date(raw['createdAt']),
    updatedAt: _date(raw['updatedAt']),
    titleAt: raw['titleAt'] is int ? _date(raw['titleAt']) : null,
    modelAt: raw['modelAt'] is int ? _date(raw['modelAt']) : null,
    model: model,
    messages: [
      for (final message in (raw['messages'] as List?) ?? const [])
        ?_messageFromJson(message),
    ],
  );
}

Map<String, Object?> _messageToJson(KapyMessage message) => {
  'id': message.id,
  'role': message.role.name,
  'text': message.text,
  'at': message.at.millisecondsSinceEpoch,
  if (message.read.isNotEmpty)
    'read': [
      for (final note in message.read)
        {
          'noteId': note.noteId,
          'title': note.title,
          'edited': note.edited.millisecondsSinceEpoch,
        },
    ],
  if (message.matching > 0) 'matching': message.matching,
  if (message.model case final model?) 'model': model.toJson(),
};

KapyMessage? _messageFromJson(Object? raw) {
  if (raw is! Map) return null;
  final id = raw['id'];
  final role = KapyRole.values.asNameMap()[raw['role']];
  final text = raw['text'];
  if (id is! String || role == null || text is! String) return null;
  final matching = raw['matching'];
  return KapyMessage(
    id: id,
    role: role,
    text: text,
    at: _date(raw['at']),
    read: [
      for (final note in (raw['read'] as List?) ?? const [])
        if (note is Map && note['noteId'] is String && note['title'] is String)
          KapyNoteRef(
            noteId: note['noteId'] as String,
            title: note['title'] as String,
            edited: _date(note['edited']),
          ),
    ],
    matching: matching is int ? matching : 0,
    model: KapyModel.fromJson(raw['model']),
  );
}

DateTime _date(Object? value) =>
    DateTime.fromMillisecondsSinceEpoch(value is int ? value : 0);
