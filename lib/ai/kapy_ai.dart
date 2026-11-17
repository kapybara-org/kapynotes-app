import 'package:flutter/foundation.dart';

/// The shared contract between Kapy AI's engine (lib/ai/) and its UI
/// (lib/ui/kapy_ai/). The engine implements [KapyAi]; the UI only reads
/// these types and calls these members.

/// The whole of Kapy AI, off until every part is done and verified, the
/// deployed Cloud endpoint included, so a release before then shows none of
/// it: no toolbar button, no ⌘J, no Settings group, no ⌘K row. A build turns
/// it on with `--dart-define=KAPYNOTES_KAPY_AI=true`; tests set it directly.
bool kapyAiAvailable = const bool.fromEnvironment('KAPYNOTES_KAPY_AI');

/// One switch per local tool, so either can be turned off in one line if its
/// maker's rules change. Both run only the person's own signed-in CLI.
const bool claudeCodeAvailable = true;
const bool codexAvailable = true;

/// Where an answer is made.
enum KapyModelKind { device, cloud, codex, claudeCode, openRouter }

/// One row of the model picker, and the model a chat answers with.
@immutable
class KapyModel {
  const KapyModel({required this.kind, required this.id, required this.label});

  /// The one Kapy AI Cloud row. It never names the model behind it.
  static const KapyModel cloud = KapyModel(
    kind: KapyModelKind.cloud,
    id: 'cloud',
    label: 'Kapy AI Cloud',
  );

  final KapyModelKind kind;

  /// Stable across launches: 'apple', 'gemma', 'cloud', or the account's own
  /// model id ('gpt-5.5', 'sonnet', 'google/gemini-3.8-flash').
  final String id;

  /// What the picker shows: 'Apple Intelligence', 'Gemma', 'Kapy AI Cloud',
  /// 'GPT-5.5', 'Claude Sonnet 5.5', 'Gemini 3.8 Flash'.
  final String label;

  /// The quiet line under an answer: 'On this device', 'Kapy AI Cloud',
  /// 'GPT-5.5 · Codex on this Mac', 'Sonnet 5.5 · Claude Code on this Mac',
  /// 'Gemini 3.8 Flash · your OpenRouter key'. [device] is the platform's
  /// word for the computer ('Mac', 'PC').
  String sourceLine(String device) => switch (kind) {
    KapyModelKind.device => 'On this device',
    KapyModelKind.cloud => 'Kapy AI Cloud',
    KapyModelKind.codex => '$label · ${whereItRuns(device)}',
    KapyModelKind.claudeCode =>
      '${label.replaceFirst('Claude ', '')} · ${whereItRuns(device)}',
    KapyModelKind.openRouter => '$label · your OpenRouter key',
  };

  /// The picker's subline for an account model: 'Codex on this Mac',
  /// 'Claude Code on this Mac', 'Your OpenRouter key'.
  String whereItRuns(String device) => switch (kind) {
    KapyModelKind.codex => 'Codex on this $device',
    KapyModelKind.claudeCode => 'Claude Code on this $device',
    KapyModelKind.openRouter => 'Your OpenRouter key',
    KapyModelKind.device => 'Answers stay on this $device',
    KapyModelKind.cloud => 'Kapy AI Cloud',
  };

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'id': id,
    'label': label,
  };

  static KapyModel? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final kind = KapyModelKind.values.asNameMap()[raw['kind']];
    final id = raw['id'];
    final label = raw['label'];
    if (kind == null || id is! String || label is! String) return null;
    return KapyModel(kind: kind, id: id, label: label);
  }

  @override
  bool operator ==(Object other) =>
      other is KapyModel && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

/// The on-device model of this device.
enum DeviceModelStatus {
  /// Apple Intelligence, ready: no download and no button.
  builtIn,
  notDownloaded,
  downloading,
  ready,

  /// Apple Intelligence is off in System Settings, or still arriving.
  needsSystemFeature,

  /// This device can't run one ("This phone can't run one").
  unavailable,
}

@immutable
class DeviceModelState {
  const DeviceModelState({
    required this.status,
    this.model,
    this.receivedBytes = 0,
    this.totalBytes = 0,
  });

  final DeviceModelStatus status;

  /// Apple Intelligence or Gemma; null when [status] is unavailable.
  final KapyModel? model;
  final int receivedBytes;
  final int totalBytes;
}

/// Kapy AI Cloud's monthly allowance. Pro only.
@immutable
class CloudUsage {
  const CloudUsage({
    required this.remaining,
    required this.limit,
    required this.resetsAt,
  });

  final int remaining;
  final int limit;
  final DateTime resetsAt;
}

/// Codex and Claude Code are desktop only; phones offer only OpenRouter.
enum KapyAccountKind { codex, claudeCode, openRouter }

enum KapyAccountStatus { notConnected, connecting, connected, error }

@immutable
class KapyAccountState {
  const KapyAccountState({
    required this.kind,
    required this.status,
    this.models = const [],
    this.detail,
    this.enabled = true,
  });

  final KapyAccountKind kind;
  final KapyAccountStatus status;

  /// The models this account offers, by name. Empty unless connected.
  final List<KapyModel> models;

  /// The key's last four characters for OpenRouter.
  final String? detail;

  /// Codex's and Claude Code's switch: whether Kapy may use it.
  final bool enabled;
}

/// A note an answer read. Opening it opens the note.
@immutable
class KapyNoteRef {
  const KapyNoteRef({
    required this.noteId,
    required this.title,
    required this.edited,
  });

  final String noteId;
  final String title;
  final DateTime edited;
}

enum KapyRole { user, assistant }

@immutable
class KapyMessage {
  const KapyMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.at,
    this.read = const [],
    this.matching = 0,
    this.model,
  });

  final String id;
  final KapyRole role;
  final String text;
  final DateTime at;

  /// For an answer: the notes it read ("Read 3 of the 7 matching notes").
  final List<KapyNoteRef> read;
  final int matching;

  /// For an answer: what wrote it, for its source line.
  final KapyModel? model;
}

@immutable
class KapyChat {
  const KapyChat({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.model,
    this.messages = const [],
  });

  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// The pick sticks to the chat.
  final KapyModel model;
  final List<KapyMessage> messages;
}

/// What holds up the last question, drawn inline under it (kapy-ai-7/8).
/// Null [KapyAi.pending] with [KapyAi.answering] false means nothing does.
sealed class KapyPending {
  const KapyPending();
}

/// "Before the first answer": once per device. Go ahead · Use this device.
class KapyCloudConsent extends KapyPending {
  const KapyCloudConsent();
}

/// "Goes to OpenAI / Anthropic / OpenRouter" (Codex / Claude Code / key):
/// once per account.
/// Go ahead · Pick another.
class KapyAccountConsent extends KapyPending {
  const KapyAccountConsent(this.account);
  final KapyAccountKind account;
}

/// Gemma picked before it is downloaded: Download 2.6 GB · Not now.
class KapyDownloadAsk extends KapyPending {
  const KapyDownloadAsk(this.totalBytes);
  final int totalBytes;
}

/// "Getting Gemma ready", with a 14 px pie. Cancel.
class KapyDownloading extends KapyPending {
  const KapyDownloading({required this.received, required this.total});
  final int received;
  final int total;
}

/// "No answers left until 1 Dec". Use the device model.
class KapyLimitReached extends KapyPending {
  const KapyLimitReached({required this.resetsAt, this.fallback});
  final DateTime resetsAt;
  final KapyModel? fallback;
}

/// "You're offline". Use the device model · Try again.
class KapyOffline extends KapyPending {
  const KapyOffline({this.fallback});
  final KapyModel? fallback;
}

/// A signed-out Codex or Claude Code, or a rejected OpenRouter key.
class KapyAccountError extends KapyPending {
  const KapyAccountError({required this.account, required this.model});
  final KapyAccountKind account;
  final KapyModel model;
}

/// Anything else that stopped an answer. Try again.
class KapyFailed extends KapyPending {
  const KapyFailed(this.message);
  final String message;
}

/// Kapy AI: chats, models, accounts and answers.
abstract class KapyAi extends ChangeNotifier {
  /// The Settings switch. Off hides the toolbar button, ⌘J does nothing and
  /// ⌘K reads "Search". Chats are kept.
  bool get enabled;
  set enabled(bool value);

  bool get isPro;

  /// What new chats start with. Pro: Kapy AI Cloud. Free: the device model.
  KapyModel get defaultModel;
  set defaultModel(KapyModel model);

  DeviceModelState get device;
  void downloadDeviceModel();
  void cancelDeviceDownload();
  Future<void> removeDeviceModel();

  /// Null on Free, and until the server has answered once.
  CloudUsage? get cloudUsage;

  /// Every account offered on this platform: Codex and Claude Code on
  /// desktop only (and only while their switches are on), OpenRouter
  /// everywhere.
  List<KapyAccountState> get accounts;

  /// Newest first.
  List<KapyChat> get chats;
  KapyChat? get current;

  /// The model the composer shows: the current chat's, or [defaultModel].
  KapyModel get model;

  /// Picks a model for the current chat (or the next new one).
  void pickModel(KapyModel model);

  void newChat();
  void openChat(String id);
  void renameChat(String id, String title);
  void deleteChat(String id);
  Future<void> clearHistory();

  /// Asks [question]. [noteId] is the "This note" chip's note, searched
  /// first; null searches all notes. Hidden notes are never read.
  Future<void> ask(String question, {String? noteId});

  /// The empty chat's third suggestion when opened from [noteId], drawn from
  /// that note ("Draft the weekly report email"). Null shows only the two
  /// that fit any note.
  String? suggestionFor(String noteId) => null;

  /// True while an answer is being written.
  bool get answering;
  KapyPending? get pending;

  /// The pending state's primary action: Go ahead (remembered), Download,
  /// Try again.
  Future<void> proceed();

  /// Use [model] for this chat and answer the held question with it.
  Future<void> answerWith(KapyModel model);

  /// Cancel / Not now: drops the pending state and keeps the question.
  void dismissPending();

  /// OpenRouter: validates [key] with OpenRouter, then keeps it in the
  /// keychain. Returns false when OpenRouter rejected it.
  Future<bool> saveOpenRouterKey(String key);
  Future<void> removeOpenRouterKey();

  Future<void> checkCodex();
  void allowCodex(bool allowed);

  Future<void> checkClaudeCode();
  void allowClaudeCode(bool allowed);
}
