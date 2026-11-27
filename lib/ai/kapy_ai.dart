import 'package:flutter/foundation.dart';

/// The shared contract between Kapy AI's engine (lib/ai/) and its UI
/// (lib/ui/kapy_ai/). The engine implements [KapyAi]; the UI only reads
/// these types and calls these members.

/// The whole of Kapy AI. On in every build packaging/release.sh and the
/// Windows CI and release jobs make, from 1.35.0, via KAPYNOTES_KAPY_AI.
/// Off in a local debug build and in tests unless they set it, so the suite
/// can still cover a build that does not ship it. When it is off there is
/// no toolbar button, no Cmd-J, no Settings group and no Cmd-K row.
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

  /// Stored with the chat. The picker shows [plainLabel], never this, so a
  /// name saved by an older build does not reach the screen.
  final String label;

  /// What a person sees: the feature, not the model behind it.
  String get plainLabel => switch (kind) {
    KapyModelKind.device =>
      id == 'apple' ? 'Apple Intelligence' : 'On this device',
    KapyModelKind.cloud => 'Kapy AI Cloud',
    KapyModelKind.codex => 'Codex',
    KapyModelKind.claudeCode => switch (id) {
      'opus' => 'Claude Code, deeper',
      _ => 'Claude Code',
    },
    KapyModelKind.openRouter => switch (id) {
      'google/gemini-3.8-flash' => 'Fast',
      'openai/gpt-5.5' => 'Strong',
      'anthropic/claude-sonnet-5.5' => 'Careful',
      _ => 'Your key',
    },
  };

  /// The quiet line under an answer. [device] is the platform's word for the
  /// computer ('Mac', 'PC').
  String sourceLine(String device) => switch (kind) {
    KapyModelKind.device => 'On this device',
    KapyModelKind.cloud => 'Kapy AI Cloud',
    KapyModelKind.codex => 'Codex on this $device',
    KapyModelKind.claudeCode => 'Claude Code on this $device',
    KapyModelKind.openRouter => 'Through your key',
  };

  /// The picker's subline for the models a key offers. A name alone does not
  /// say which one to pick, so each says what it is good for. Null when the
  /// model is not one of these.
  String? get goodFor => switch (id) {
    'google/gemini-3.8-flash' => 'Quick answers and short notes',
    'openai/gpt-5.5' => 'Harder questions and planning',
    'anthropic/claude-sonnet-5.5' => 'Long writing and summaries',
    _ => null,
  };

  /// The picker's subline for an account model.
  String whereItRuns(String device) => switch (kind) {
    KapyModelKind.codex || KapyModelKind.claudeCode => 'On this $device',
    KapyModelKind.openRouter => 'Through your key',
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

  /// Apple Intelligence is on this platform but not ready, and Gemma cannot
  /// run here either. [DeviceModelState.note] says what would work.
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
    this.note,
  });

  final DeviceModelStatus status;

  /// Apple Intelligence or Gemma; null when nothing here can answer.
  final KapyModel? model;

  /// Why nothing on this device can answer, when Apple Intelligence is on
  /// the platform but not ready and Gemma cannot run. Shown instead of a
  /// device row.
  final String? note;
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

/// The recording a chat asks about: the note it is in and its hash. Kept in
/// the chat's sealed record, which builds that do not know it keep as is.
@immutable
class KapyRecordingRef {
  const KapyRecordingRef({required this.noteId, required this.hash});

  final String noteId;
  final String hash;

  Map<String, Object?> toJson() => {'noteId': noteId, 'hash': hash};

  static KapyRecordingRef? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final noteId = raw['noteId'];
    final hash = raw['hash'];
    if (noteId is! String || hash is! String) return null;
    return KapyRecordingRef(noteId: noteId, hash: hash);
  }

  @override
  bool operator ==(Object other) =>
      other is KapyRecordingRef && other.noteId == noteId && other.hash == hash;

  @override
  int get hashCode => Object.hash(noteId, hash);
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
    this.readTo,
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

  /// For an answer about a recording too long to read whole: how far into
  /// it the answer read ("Read the first 12 minutes of 48").
  final Duration? readTo;
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
    DateTime? titleAt,
    DateTime? modelAt,
    this.recording,
  }) : titleAt = titleAt ?? createdAt,
       modelAt = modelAt ?? createdAt;

  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// The pick sticks to the chat.
  final KapyModel model;
  final List<KapyMessage> messages;

  /// When the title and the model were last set, which is how two devices
  /// that changed one each both keep theirs. [updatedAt] cannot say: an
  /// answer moves it too.
  final DateTime titleAt;
  final DateTime modelAt;

  /// The recording this chat asks about, which it reads instead of the
  /// notes. Null for a chat about the notes.
  final KapyRecordingRef? recording;
}

/// What holds up the last question, drawn inline under it (kapy-ai-7/8).
/// Null [KapyAi.pending] with [KapyAi.answering] false means nothing does.
sealed class KapyPending {
  const KapyPending();
}

/// "Before the first answer": once per device. Go ahead · Use this device.
/// A [recording] chat's is worded for its transcript, and agreeing to it
/// covers recording chats alone; the panel's covers both.
class KapyCloudConsent extends KapyPending {
  const KapyCloudConsent({this.recording = false, this.device = true});

  final bool recording;

  /// Whether this device's model may answer instead. Not for a translation,
  /// which is only made in the cloud.
  final bool device;
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
  const KapyAccountError({
    required this.account,
    required this.model,
    this.fallbacks = const [],
  });
  final KapyAccountKind account;
  final KapyModel model;
  final List<KapyModel> fallbacks;
}

/// Kapy AI Cloud won't answer for this person yet: Sign in when nobody is
/// signed in or the session ended, Upgrade without Pro, and Use your own
/// account either way.
class KapyCloudLocked extends KapyPending {
  const KapyCloudLocked({
    required this.signIn,
    required this.upgrade,
    this.fallbacks = const [],
  });
  final bool signIn;
  final bool upgrade;
  final List<KapyModel> fallbacks;
}

/// Anything else that stopped an answer, with the models that could answer
/// instead for the person to choose from. Try again only when [retry].
class KapyFailed extends KapyPending {
  const KapyFailed(
    this.message, {
    this.fallbacks = const [],
    this.retry = true,
  });
  final String message;
  final List<KapyModel> fallbacks;
  final bool retry;
}

/// A translation being written: the parts that have come back, stitched in
/// order, and how many there are in all. Never a whole translation: that
/// joins the chat once every part is in.
@immutable
class KapyTranslationDraft {
  const KapyTranslationDraft({
    required this.text,
    required this.done,
    required this.parts,
  });

  final String text;
  final int done;
  final int parts;
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

  /// Whether downloading the device model now would spend mobile data.
  Future<bool> deviceDownloadOnMobileData();

  /// Downloads the device model once on Wi-Fi, and drops the question
  /// waiting for it: asking again answers it.
  void downloadDeviceModelOnWifi();
  Future<void> removeDeviceModel();

  /// Null on Free, and until the server has answered once.
  CloudUsage? get cloudUsage;

  /// Every account offered on this platform: Codex and Claude Code on
  /// desktop only (and only while their switches are on), OpenRouter
  /// everywhere.
  List<KapyAccountState> get accounts;

  /// Whether the chats are syncing to the account's other devices right now:
  /// Pro, and signed in with sync on. False keeps them on this device.
  bool get chatsSync => false;

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
  ///
  /// With [recording], the question is about that recording alone: it goes
  /// on the current chat when that chat is about the same recording, and
  /// starts one that is otherwise. Its answers read the recording's
  /// transcript, with times and speakers, rather than the notes.
  Future<void> ask(
    String question, {
    String? noteId,
    KapyRecordingRef? recording,
  });

  /// The empty chat's third suggestion when opened from [noteId], drawn from
  /// that note ("Draft the weekly report email"). Null shows only the two
  /// that fit any note.
  String? suggestionFor(String noteId) => null;

  /// What a link in [answer] may come from: the question it answered and the
  /// notes it read that are still here and not hidden. Empty makes no link
  /// live.
  String linkSources(KapyChat chat, KapyMessage answer) => '';

  /// Whether [answer], in [chat] about a recording, read its transcript to
  /// the end. One that does not say where it stopped did only when the
  /// transcript fits what its model reads: a build older than recording
  /// chats drops that mark from an answer it sends again, after signing in.
  bool readWhole(KapyChat chat, KapyMessage answer) => answer.readTo == null;

  /// True while an answer is being written.
  bool get answering;

  /// While the current chat's answer is a translation being written in
  /// parts, the parts so far; null otherwise.
  KapyTranslationDraft? get draft => null;
  KapyPending? get pending;

  /// The pending state's primary action: Go ahead (remembered), Download,
  /// Try again.
  Future<void> proceed();

  /// Use [model] for this chat and answer the held question with it. When
  /// nothing is held and the last question has its answer, [model] answers
  /// that question again: it joins the chat once more, since a message is
  /// never taken back from the other devices.
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
