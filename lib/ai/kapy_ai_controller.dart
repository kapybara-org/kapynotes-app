import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../billing/billing.dart';
import '../core/platform.dart';
import '../data/local_store.dart';
import '../data/notes_store.dart';
import '../sync/config.dart';
import '../sync/key_store.dart';
import 'answer_engine.dart';
import 'cloud_client.dart';
import 'device_model.dart';
import 'kapy_ai.dart';
import 'kapy_ai_store.dart';
import 'kapy_chat_book.dart';
import 'local_tools.dart';
import 'open_router.dart';
import 'retrieval.dart';
import 'tool_helper.dart';

/// Kapy AI's engine: chats, models, accounts, and the answer to each
/// question, with every state that can hold one up.
///
/// Built once, beside the voice summaries it shares a model with:
///
/// ```dart
/// KapyAiController(
///   store: widget.store,
///   notes: widget.notes,
///   device: PlatformDeviceModel(
///     apple: AppleSummarizer(),
///     gemma: _gemma!,
///     models: _localModels!,
///   ),
///   billing: widget.account?.billing,
///   token: () => widget.account?.token,
/// )
/// ```
///
/// Everything else has a default: the API at [kApiBaseUrl], the keychain
/// for the OpenRouter key, the Codex and Claude Code programs on this
/// computer, the process environment (where [appSandboxVariable] says the
/// app is sandboxed), and the macOS helper that runs both tools for a
/// sandboxed app, which offers them only when that helper answers. Tests
/// pass their own.
///
/// Nothing happens at construction: no disk scan, no keychain read, no
/// network, no program run. The first read of [device], [accounts] or
/// [cloudUsage], or the first question, starts that, so a build or a person
/// that never opens the panel pays nothing for it.
///
/// Hidden notes never reach a model: [retrieve] skips them, and
/// [readableNotes] checks every note again on its way out.
class KapyAiController extends KapyAi {
  KapyAiController({
    required LocalStore store,
    required NotesStore notes,
    required DeviceModel device,
    Billing? billing,
    KapyChatBook? chats,
    String? Function()? token,
    http.Client? client,
    SecureStore? secrets,
    LocalTool? codex,
    LocalTool? claudeCode,
    Uri? apiBaseUrl,
    DateTime Function()? now,
    Map<String, String>? environment,
    ToolHelper? toolHelper,
  }) : _store = KapyAiStore(store),
       _book =
           chats ?? KapyChatBook(store, ready: () => notes.isLoaded, now: now),
       _notes = notes,
       _device = device,
       _billing = billing,
       _now = now ?? DateTime.now,
       _sandboxed = (environment ?? Platform.environment).containsKey(
         appSandboxVariable,
       ),
       _toolHelper = toolHelper ?? const MacToolHelper() {
    final helper = _sandboxed ? _toolHelper : null;
    _codex = codex ?? CodexCli(helper: helper);
    _claudeCode = claudeCode ?? ClaudeCodeCli(helper: helper);
    final web = client ?? http.Client();
    _cloud = KapyCloudClient(
      baseUrl: apiBaseUrl ?? Uri.parse(kApiBaseUrl),
      token: token ?? () => null,
      client: web,
    );
    _openRouter = OpenRouterAccount(
      secrets: secrets ?? defaultSecureStore(),
      client: web,
    );
    _wasPro = isPro;
    _device.addListener(_onDevice);
    _notes.addListener(_linkSources.clear);
    _billing?.addListener(_onBilling);
    _book.addListener(_notify);
  }

  final KapyAiStore _store;
  final KapyChatBook _book;
  final NotesStore _notes;
  final DeviceModel _device;
  final Billing? _billing;
  final DateTime Function() _now;
  final bool _sandboxed;
  final ToolHelper _toolHelper;

  /// A sandboxed macOS app's helper answered: Codex and Claude Code run
  /// through it.
  bool _helperReady = false;
  late final LocalTool _codex;
  late final LocalTool _claudeCode;
  late final KapyCloudClient _cloud;
  late final OpenRouterAccount _openRouter;

  Future<void>? _started;
  String? _currentId;

  /// Picked with no chat open: the model the next new chat starts with.
  KapyModel? _next;
  KapyPending? _pending;
  bool _answering = false;

  /// The held question's "This note" chip, kept for Try again.
  String? _heldNoteId;

  /// Seen moving since the download ask, so a download that has not begun
  /// yet is not mistaken for one that failed.
  bool _downloadMoved = false;

  final Map<KapyAccountKind, LocalToolCheck> _checks = {};
  late bool _wasPro;
  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Everything the panel needs and the constructor must not do, once.
  Future<void> _ready() => _started ??= _start();

  Future<void> _start() async {
    try {
      await Future.wait([_device.refresh(), _openRouter.load()]);
    } catch (error) {
      debugPrint(
        'KapyNotes: Kapy AI could not look at its models: ${error.runtimeType}',
      );
    }
    unawaited(_refreshUsage());
    if (_sandboxed && AppPlatform.isMacOS) {
      _helperReady = await _toolHelper.available();
    }
    for (final tool in [_codex, _claudeCode]) {
      if (_toolPlatform(tool.kind)) unawaited(_check(tool));
    }
    _notify();
  }

  // -------------------------------------------------------------------------
  // Settings and models

  @override
  bool get enabled => _store.enabled;

  @override
  set enabled(bool value) {
    if (value == enabled) return;
    _store.enabled = value;
    _notify();
  }

  /// Pro or its trial. Unknown counts as Free here, unlike voice: Kapy AI
  /// Cloud refuses Free anyway, and a default that falls back for a moment
  /// at launch costs nothing, since the stored choice is never rewritten.
  @override
  bool get isPro => _billing?.hasPro ?? false;

  void _onBilling() {
    if (isPro == _wasPro) return;
    _wasPro = isPro;
    if (_started != null) unawaited(_refreshUsage());
    _notify();
  }

  Future<void> _refreshUsage() async {
    if (!isPro) return;
    try {
      await _cloud.fetchUsage();
      _notify();
    } on AnswerFailure {
      // The row reads without a count until the server answers.
    }
  }

  /// The device's model, when it has one it could ever run.
  KapyModel? get _deviceModel =>
      _device.state.status == DeviceModelStatus.unavailable
      ? null
      : _device.state.model;

  @override
  KapyModel get defaultModel {
    final stored = _store.defaultModel;
    if (stored != null && _usable(stored)) return stored;
    // Someone who picked the device picked it for what it does not send, so a
    // device model that can answer still answers for them even on Pro. Only
    // when no device model can run does this fall through to the cloud.
    if (stored?.kind == KapyModelKind.device) {
      final device = _deviceModel;
      if (device != null && _usable(device)) return device;
    }
    return isPro ? KapyModel.cloud : _fallback;
  }

  @override
  set defaultModel(KapyModel model) {
    _store.defaultModel = model;
    _notify();
  }

  /// Whether [model] can be picked here and now. Own accounts count while
  /// they are offered: one that has since signed out says so when asked,
  /// rather than the chat quietly moving to another model. A signed-in tool
  /// that no longer lists the model, because its catalogue changed or the
  /// model now brings a tool of its own, does not count.
  /// Whether [model] can answer for this person right now.
  bool _usable(KapyModel model) => switch (model.kind) {
    KapyModelKind.cloud => isPro,
    // A device model counts only when it can actually answer: the device may
    // be reporting that nothing here can run, in [DeviceModelState.note].
    KapyModelKind.device => model == _deviceModel && _device.state.note == null,
    KapyModelKind.codex => _toolModelUsable(KapyAccountKind.codex, model),
    KapyModelKind.claudeCode => _toolModelUsable(
      KapyAccountKind.claudeCode,
      model,
    ),
    KapyModelKind.openRouter => true,
  };

  bool _toolModelUsable(KapyAccountKind kind, KapyModel model) {
    if (!_offered(kind)) return false;
    final check = _checks[kind];
    return check?.status != KapyAccountStatus.connected ||
        check!.models.contains(model);
  }

  /// What answers when the chosen model cannot: the device's own, then
  /// Kapy AI Cloud on Pro, then the first account model there is.
  KapyModel get _fallback {
    final device = _deviceModel;
    if (device != null) return device;
    if (isPro) return KapyModel.cloud;
    for (final account in accounts) {
      if (account.enabled && account.models.isNotEmpty) {
        return account.models.first;
      }
    }
    return KapyModel.cloud;
  }

  @override
  KapyModel get model {
    final chosen = current?.model ?? _next ?? defaultModel;
    return _usable(chosen) ? chosen : defaultModel;
  }

  @override
  void pickModel(KapyModel model) {
    final chat = current;
    if (chat == null) {
      _next = model;
    } else {
      _replace(_edit(chat, model: model));
    }
    _notify();
  }

  @override
  DeviceModelState get device {
    unawaited(_ready());
    return _device.state;
  }

  @override
  void downloadDeviceModel() => _device.download();

  @override
  Future<bool> deviceDownloadOnMobileData() => _device.onMobileData();

  @override
  void downloadDeviceModelOnWifi() {
    _device.downloadOnWifi();
    dismissPending();
  }

  @override
  void cancelDeviceDownload() => _device.cancel();

  @override
  Future<void> removeDeviceModel() => _device.remove();

  void _onDevice() {
    if (_pending is KapyDownloading) {
      final state = _device.state;
      switch (state.status) {
        case DeviceModelStatus.downloading:
          _downloadMoved = true;
          _pending = KapyDownloading(
            received: state.receivedBytes,
            total: state.totalBytes,
          );
        case DeviceModelStatus.ready || DeviceModelStatus.builtIn:
          _pending = null;
          unawaited(_answer());
        case DeviceModelStatus.notDownloaded when _downloadMoved:
          _pending = KapyFailed(
            "Couldn't download ${state.model?.label ?? 'the model'}. "
            'Try again.',
          );
        default:
          break;
      }
    }
    _notify();
  }

  @override
  CloudUsage? get cloudUsage {
    unawaited(_ready());
    return isPro ? _cloud.usage : null;
  }

  // -------------------------------------------------------------------------
  // Accounts

  @override
  List<KapyAccountState> get accounts {
    unawaited(_ready());
    return [
      for (final kind in [KapyAccountKind.codex, KapyAccountKind.claudeCode])
        if (_toolPlatform(kind)) _toolState(kind),
      _openRouter.state,
    ];
  }

  static bool _isTool(KapyAccountKind kind) =>
      kind == KapyAccountKind.codex || kind == KapyAccountKind.claudeCode;

  /// Codex and Claude Code: on a desktop, while their const is on, where
  /// the app is not sandboxed or its helper answered (a sandboxed app cannot
  /// run them itself; the Mac App Store build has no helper, so it never
  /// offers them).
  ///
  /// Not on Windows either, until a canary and a check that a timeout kills
  /// the whole process tree have passed on a Windows machine. The shim code
  /// in local_tools.dart stays for the day one does.
  bool _toolPlatform(KapyAccountKind kind) =>
      AppPlatform.isDesktop &&
      !AppPlatform.isWindows &&
      (!_sandboxed || _helperReady) &&
      switch (kind) {
        KapyAccountKind.codex => codexAvailable,
        KapyAccountKind.claudeCode => claudeCodeAvailable,
        KapyAccountKind.openRouter => false,
      };

  /// Offered on this platform and allowed by its switch.
  bool _offered(KapyAccountKind kind) =>
      !_isTool(kind) || (_toolPlatform(kind) && _store.isToolAllowed(kind));

  KapyAccountState _toolState(KapyAccountKind kind) {
    final check = _checks[kind];
    final allowed = _store.isToolAllowed(kind);
    final status = check?.status ?? KapyAccountStatus.notConnected;
    return KapyAccountState(
      kind: kind,
      status: status,
      models: allowed && status == KapyAccountStatus.connected
          ? check!.models
          : const [],
      enabled: allowed,
    );
  }

  Future<void> _check(LocalTool tool) async {
    _checks[tool.kind] = await tool.check();
    _notify();
  }

  @override
  Future<void> checkCodex() => _check(_codex);

  @override
  void allowCodex(bool allowed) => _allow(KapyAccountKind.codex, allowed);

  @override
  Future<void> checkClaudeCode() => _check(_claudeCode);

  @override
  void allowClaudeCode(bool allowed) =>
      _allow(KapyAccountKind.claudeCode, allowed);

  void _allow(KapyAccountKind tool, bool allowed) {
    _store.allowTool(tool, allowed);
    _notify();
  }

  @override
  Future<bool> saveOpenRouterKey(String key) async {
    final saved = await _openRouter.save(key);
    _notify();
    return saved;
  }

  @override
  Future<void> removeOpenRouterKey() async {
    await _openRouter.remove();
    _notify();
  }

  // -------------------------------------------------------------------------
  // Chats

  List<KapyChat> get _all => _book.chats;

  @override
  List<KapyChat> get chats => _all;

  @override
  bool get chatsSync => _book.syncing;

  @override
  KapyChat? get current {
    for (final chat in _all) {
      if (chat.id == _currentId) return chat;
    }
    return null;
  }

  @override
  void newChat() {
    _currentId = null;
    _next = null;
    _pending = null;
    _notify();
  }

  @override
  void openChat(String id) {
    if (!_all.any((chat) => chat.id == id)) return;
    _currentId = id;
    _pending = null;
    _notify();
  }

  @override
  void renameChat(String id, String title) {
    final name = _oneLine(title);
    final chat = _chat(id);
    if (name.isEmpty || chat == null || chat.title == name) return;
    _replace(_edit(chat, title: name));
    _notify();
  }

  @override
  void deleteChat(String id) {
    if (_chat(id) == null) return;
    if (_currentId == id) {
      _currentId = null;
      _pending = null;
    }
    _book.delete(id);
  }

  @override
  Future<void> clearHistory() async {
    await _book.pull();
    _currentId = null;
    _pending = null;
    _book.clear();
  }

  KapyChat? _chat(String id) => _book.chat(id);

  /// Puts [chat] in place of the one with its id, at the top: every edit
  /// moves [KapyChat.updatedAt], and the list is newest first.
  void _replace(KapyChat chat) => _book.put(chat);

  KapyChat _edit(
    KapyChat chat, {
    String? title,
    KapyModel? model,
    List<KapyMessage>? messages,
  }) {
    final at = _now();
    return KapyChat(
      id: chat.id,
      title: title ?? chat.title,
      createdAt: chat.createdAt,
      updatedAt: at,
      model: model ?? chat.model,
      messages: messages ?? chat.messages,
      titleAt: title == null ? chat.titleAt : at,
      modelAt: model == null ? chat.modelAt : at,
    );
  }

  /// A chat is named by its first question, on one line and no longer than
  /// a note's title.
  static String _titleFor(String question) {
    final line = _oneLine(question);
    return line.length > _titleLimit
        ? '${line.substring(0, _titleLimit).trimRight()}…'
        : line;
  }

  static const int _titleLimit = 60;

  static String _oneLine(String text) =>
      text.replaceAll(RegExp(r'\s+'), ' ').trim();

  // -------------------------------------------------------------------------
  // Asking

  @override
  bool get answering => _answering;

  @override
  KapyPending? get pending => _pending;

  @override
  Future<void> ask(String question, {String? noteId}) async {
    final text = question.trim();
    if (text.isEmpty || _answering) return;
    final asked = KapyMessage(
      id: NotesStore.newId(),
      role: KapyRole.user,
      text: text.length > AnswerRequest.maxQuestionChars
          ? text.substring(0, AnswerRequest.maxQuestionChars)
          : text,
      at: _now(),
    );
    final chat = current;
    if (chat == null) {
      final at = _now();
      final created = KapyChat(
        id: NotesStore.newId(),
        title: _titleFor(asked.text),
        createdAt: at,
        updatedAt: at,
        model: model,
        messages: [asked],
      );
      _currentId = created.id;
      _next = null;
      _replace(created);
    } else {
      _replace(_edit(chat, messages: [...chat.messages, asked]));
    }
    _heldNoteId = noteId;
    _pending = null;
    _notify();
    await _answer();
  }

  /// [linkSources] by answer id, until a note changes.
  final _linkSources = <String, String>{};

  @override
  String linkSources(KapyChat chat, KapyMessage answer) =>
      _linkSources[answer.id] ??= () {
        final at = chat.messages.indexWhere(
          (message) => message.id == answer.id,
        );
        final read = {for (final ref in answer.read) ref.noteId};
        return [
          if (at > 0) chat.messages[at - 1].text,
          for (final note in _notes.allNotes)
            if (read.contains(note.id) && !note.isHidden) note.body,
        ].join('\n');
      }();

  /// Answers the current chat's last question, if nothing holds it up.
  Future<void> _answer() async {
    await _ready();
    final chat = current;
    if (_answering || chat == null || chat.messages.isEmpty) return;
    final question = chat.messages.last;
    if (question.role != KapyRole.user) return;

    final using = model;
    final held = _holdFor(using);
    if (held != null) {
      _pending = held;
      _downloadMoved = false;
      _notify();
      return;
    }

    _answering = true;
    _pending = null;
    _notify();
    KapyPending? failed;
    try {
      final retrieval = retrieve(
        store: _notes,
        question: question.text,
        noteId: _heldNoteId,
        budget: using.kind == KapyModelKind.device
            ? RetrievalBudget.device(_device.noteChars)
            : RetrievalBudget.cloud,
      );
      final read = readableNotes(_notes, retrieval.notes);
      final hidden = {
        for (final note in _notes.allNotes)
          if (note.isHidden) note.id,
      };
      final before = chat.messages.sublist(0, chat.messages.length - 1);
      final cut = before.indexWhere(
        (message) => message.read.any((ref) => hidden.contains(ref.noteId)),
      );
      final earlier = cut < 0 ? before : before.sublist(0, cut);
      final text = await _engineFor(using).answer(
        using,
        AnswerRequest(
          question: question.text,
          notes: read,
          history: [
            for (final message in earlier.sublist(
              max(0, earlier.length - AnswerRequest.maxHistory),
            ))
              _clipped(message),
          ],
          today: _now(),
        ),
      );
      final now = _chat(chat.id);
      if (now != null) {
        _replace(
          _edit(
            now,
            messages: [
              ...now.messages,
              KapyMessage(
                id: NotesStore.newId(),
                role: KapyRole.assistant,
                text: text,
                at: _now(),
                read: [
                  for (final note in read)
                    KapyNoteRef(
                      noteId: note.id,
                      title: note.title,
                      edited: note.edited,
                    ),
                ],
                matching: retrieval.matching,
                model: using,
              ),
            ],
          ),
        );
      }
    } on AnswerOffline {
      failed = KapyOffline(fallback: _otherDeviceModel(using));
    } on AnswerLimitReached catch (limit) {
      failed = KapyLimitReached(
        resetsAt: limit.usage.resetsAt,
        fallback: _otherDeviceModel(using),
      );
    } on AnswerAccountRejected catch (rejected) {
      if (_isTool(rejected.account)) {
        _checks[rejected.account] = (
          status: KapyAccountStatus.error,
          models: const <KapyModel>[],
        );
      }
      failed = KapyAccountError(account: rejected.account, model: using);
    } on AnswerFailed catch (failure) {
      failed = KapyFailed(failure.message);
    } catch (error) {
      debugPrint('KapyNotes: Kapy AI could not answer: ${error.runtimeType}');
      failed = const KapyFailed('Something went wrong. Try again.');
    } finally {
      _answering = false;
    }
    if (_currentId == chat.id) _pending = failed;
    _notify();
  }

  /// What has to happen before [model] may answer, or null when nothing.
  KapyPending? _holdFor(KapyModel model) {
    final blocked = _device.state.note;
    // Free, signed out and nothing on this device can answer: say what would
    // work rather than sending the question to a cloud nobody asked for. Pro
    // is let through here and gets the cloud answer; an account the person
    // set up themselves is theirs to use.
    if (blocked != null &&
        !isPro &&
        model.kind != KapyModelKind.codex &&
        model.kind != KapyModelKind.claudeCode &&
        model.kind != KapyModelKind.openRouter) {
      return KapyFailed(blocked);
    }
    final account = _accountOf(model.kind);
    if (account != null) {
      return _store.hasAccountConsent(account)
          ? null
          : KapyAccountConsent(account);
    }
    if (model.kind == KapyModelKind.cloud) {
      return _store.cloudConsent ? null : const KapyCloudConsent();
    }
    final state = _device.state;
    return switch (state.status) {
      DeviceModelStatus.builtIn || DeviceModelStatus.ready => null,
      DeviceModelStatus.notDownloaded => KapyDownloadAsk(state.totalBytes),
      DeviceModelStatus.downloading => KapyDownloading(
        received: state.receivedBytes,
        total: state.totalBytes,
      ),
      DeviceModelStatus.needsSystemFeature => KapyFailed(
        state.note ?? PlatformDeviceModel.appleOffNoRoom,
      ),
      DeviceModelStatus.unavailable => const KapyFailed(
        "This device can't run an on-device model.",
      ),
    };
  }

  static KapyAccountKind? _accountOf(KapyModelKind kind) => switch (kind) {
    KapyModelKind.codex => KapyAccountKind.codex,
    KapyModelKind.claudeCode => KapyAccountKind.claudeCode,
    KapyModelKind.openRouter => KapyAccountKind.openRouter,
    KapyModelKind.device || KapyModelKind.cloud => null,
  };

  AnswerEngine _engineFor(KapyModel model) => switch (model.kind) {
    KapyModelKind.device => _device,
    KapyModelKind.cloud => _cloud,
    KapyModelKind.codex => _codex,
    KapyModelKind.claudeCode => _claudeCode,
    KapyModelKind.openRouter => _openRouter,
  };

  /// The device's model as the way out of a state, unless it is the model
  /// that is stuck.
  KapyModel? _otherDeviceModel(KapyModel using) {
    final device = _deviceModel;
    return device == using ? null : device;
  }

  static KapyMessage _clipped(KapyMessage message) =>
      message.text.length <= AnswerRequest.maxHistoryChars
      ? message
      : KapyMessage(
          id: message.id,
          role: message.role,
          text: message.text.substring(0, AnswerRequest.maxHistoryChars),
          at: message.at,
        );

  @override
  Future<void> proceed() async {
    switch (_pending) {
      case KapyCloudConsent():
        _store.cloudConsent = true;
        await _answer();
      case KapyAccountConsent(:final account):
        _store.giveAccountConsent(account);
        await _answer();
      case KapyDownloadAsk():
        _downloadMoved = false;
        _device.download();
        final state = _device.state;
        _pending = KapyDownloading(
          received: state.receivedBytes,
          total: state.totalBytes,
        );
        _notify();
      case KapyLimitReached(:final fallback?):
        await answerWith(fallback);
      case KapyAccountError(:final account) when _isTool(account):
        await _check(account == KapyAccountKind.codex ? _codex : _claudeCode);
        if (_checks[account]?.status == KapyAccountStatus.connected) {
          await _answer();
        }
      case KapyAccountError() || KapyOffline() || KapyFailed():
        await _answer();
      case KapyDownloading() || KapyLimitReached() || null:
        return;
    }
  }

  @override
  Future<void> answerWith(KapyModel model) async {
    pickModel(model);
    _pending = null;
    await _answer();
  }

  @override
  void dismissPending() {
    if (_pending is KapyDownloading) _device.cancel();
    _pending = null;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _device.removeListener(_onDevice);
    _notes.removeListener(_linkSources.clear);
    _billing?.removeListener(_onBilling);
    _book.removeListener(_notify);
    super.dispose();
  }
}
