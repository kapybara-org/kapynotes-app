import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../billing/billing.dart';
import '../core/platform.dart';
import '../data/local_store.dart';
import '../data/note.dart';
import '../data/note_attachment.dart';
import '../data/notes_store.dart';
import '../speech/languages.dart';
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
import 'recording_context.dart';
import 'recording_translation.dart';
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
       _token = token ?? (() => null),
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
      token: _token,
      client: web,
    );
    _openRouter = OpenRouterAccount(
      secrets: secrets ?? defaultSecureStore(),
      client: web,
    );
    _wasPro = isPro;
    _wasSignedIn = _signedIn;
    _device.addListener(_onDevice);
    _notes.addListener(_onNotes);
    _billing?.addListener(_onBilling);
    _book.addListener(_notify);
  }

  final KapyAiStore _store;
  final KapyChatBook _book;
  final NotesStore _notes;
  final DeviceModel _device;
  final Billing? _billing;
  final String? Function() _token;
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
  KapyTranslationDraft? _draft;

  /// The parts of a translation that came back before another failed, by
  /// the question they answer and what each part sent, so Try again asks
  /// only for the rest.
  ({String question, List<String> sent, List<String> done})? _translated;

  /// The held question's "This note" chip, kept for Try again.
  String? _heldNoteId;

  /// Seen moving since the download ask, so a download that has not begun
  /// yet is not mistaken for one that failed.
  bool _downloadMoved = false;

  final Map<KapyAccountKind, LocalToolCheck> _checks = {};
  late bool _wasPro;
  late bool _wasSignedIn;
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

  bool get _signedIn => _token() != null;

  void _onBilling() {
    if (isPro == _wasPro && _signedIn == _wasSignedIn) return;
    if (isPro != _wasPro && _started != null) unawaited(_refreshUsage());
    _wasPro = isPro;
    _wasSignedIn = _signedIn;
    // Signed in or upgraded from the card: the held question goes ahead, or
    // the card asks only for what is still missing.
    if (_pending is KapyCloudLocked) {
      _pending = null;
      unawaited(_answer());
    }
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
    // Whatever someone picked stays their pick. Kapy AI says why it cannot
    // answer and offers what else could, rather than switching for them.
    if (stored != null) return _sameChoice(stored) ?? stored;
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
    // A key is checked when it is used: a rejected one comes back as an
    // account error, which is the card that offers the alternatives.
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
    if (_usable(chosen)) return chosen;
    // A chat's own model is the person's choice too, so it is never swapped for
    // another one: the pending state says why it cannot answer instead.
    return _sameChoice(chosen) ?? chosen;
  }

  /// What answers for [chosen] when it can no longer be picked, if that is
  /// the same choice to a person rather than a different model: the device's
  /// model in place of another device model, and Codex's one offered model in
  /// place of one Codex no longer lists, since a person only ever sees Codex.
  KapyModel? _sameChoice(KapyModel chosen) {
    final same = switch (chosen.kind) {
      KapyModelKind.device => _deviceModel,
      KapyModelKind.codex => _checks[KapyAccountKind.codex]?.models.firstOrNull,
      _ => null,
    };
    return same != null && _usable(same) ? same : null;
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
      recording: chat.recording,
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
  KapyTranslationDraft? get draft => _draft;

  @override
  Future<void> ask(
    String question, {
    String? noteId,
    KapyRecordingRef? recording,
  }) async {
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
    final chat = recording == null || current?.recording == recording
        ? current
        : null;
    if (chat == null) {
      final at = _now();
      final translation = recording == null
          ? null
          : parseTranslationRequest(asked.text);
      final created = KapyChat(
        id: NotesStore.newId(),
        title: translation == null
            ? _titleFor(asked.text)
            : translationTitle(translation.scope, translation.language),
        createdAt: at,
        updatedAt: at,
        model: model,
        messages: [asked],
        recording: recording,
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

  /// [linkSources] and [readWhole] by answer id, until a note changes.
  final _linkSources = <String, String>{};
  final _readWhole = <String, bool>{};

  void _onNotes() {
    _linkSources.clear();
    _readWhole.clear();
  }

  @override
  bool readWhole(KapyChat chat, KapyMessage answer) =>
      _readWhole[answer.id] ??= () {
        if (answer.readTo != null) return false;
        final link = chat.recording;
        final model = answer.model;
        final voice = link == null ? null : _recording(link);
        if (voice == null || model == null) return false;
        return readRecording(voice.note, voice.ref, _budgetFor(model)).readTo ==
            null;
      }();

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

    final recording = chat.recording;
    final voice = recording == null ? null : _recording(recording);
    if (recording != null && voice == null) {
      _pending = KapyFailed(_refusal(recording), retry: false);
      _notify();
      return;
    }

    // A translation is long work that a device's model does poorly, so it
    // is always made in the cloud: Kapy AI Cloud, or the person's own account.
    final translation = recording == null
        ? null
        : parseTranslationRequest(question.text);
    final cloudOnly = translation != null;
    final using = cloudOnly && model.kind == KapyModelKind.device
        ? KapyModel.cloud
        : model;
    final held = _holdFor(
      using,
      recording: recording != null,
      cloudOnly: cloudOnly,
    );
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
      if (translation != null) {
        await _translate(chat, voice!, question, translation, using);
      } else {
        await _reply(chat, question, voice, using);
      }
    } on AnswerOffline {
      failed = KapyOffline(
        fallback: cloudOnly ? null : _otherDeviceModel(using),
      );
    } on AnswerLimitReached catch (limit) {
      failed = KapyLimitReached(
        resetsAt: limit.usage.resetsAt,
        fallback: cloudOnly ? null : _otherDeviceModel(using),
      );
    } on AnswerAccountRejected catch (rejected) {
      if (_isTool(rejected.account)) {
        _checks[rejected.account] = (
          status: KapyAccountStatus.error,
          models: const <KapyModel>[],
        );
      }
      failed = KapyAccountError(
        account: rejected.account,
        model: using,
        fallbacks: _alternativesTo(using, device: !cloudOnly),
      );
    } on AnswerSignInNeeded {
      failed = _cloudLocked(using, signIn: true, device: !cloudOnly);
    } on AnswerProNeeded {
      failed = _cloudLocked(using, upgrade: true, device: !cloudOnly);
    } on AnswerFailed catch (failure) {
      failed = KapyFailed(
        failure.message,
        fallbacks: _alternativesTo(using, device: !cloudOnly),
        retry: failure.retry,
      );
    } catch (error) {
      debugPrint('KapyNotes: Kapy AI could not answer: ${error.runtimeType}');
      failed = const KapyFailed('Something went wrong. Try again.');
    } finally {
      _answering = false;
      _draft = null;
    }
    if (_currentId == chat.id) _pending = failed;
    _notify();
  }

  /// Answers [question], the last of [chat], with [using]: from the notes
  /// that match it, or from [voice] when the chat is about a recording.
  Future<void> _reply(
    KapyChat chat,
    KapyMessage question,
    ({Note note, NoteVoiceRef ref})? voice,
    KapyModel using,
  ) async {
    final budget = _budgetFor(using);
    final heard = voice == null
        ? null
        : readRecording(voice.note, voice.ref, budget);
    final retrieval = heard == null
        ? retrieve(
            store: _notes,
            question: question.text,
            noteId: _heldNoteId,
            budget: budget,
          )
        : Retrieval(notes: heard.parts, matching: 0);
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
                for (final note in {
                  for (final note in read) note.id: note,
                }.values)
                  KapyNoteRef(
                    noteId: note.id,
                    title: note.title,
                    edited: note.edited,
                  ),
              ],
              matching: retrieval.matching,
              model: using,
              readTo: heard?.readTo,
            ),
          ],
        ),
      );
    }
  }

  /// Translates [voice] as [asked] says, a part at a time with [using], and
  /// adds the parts to [chat], each an answer of its own so that every one
  /// fits a synced record, once all of them are in. A translation that stops
  /// partway is never kept: the parts that came back wait for Try again,
  /// which asks only for the rest.
  Future<void> _translate(
    KapyChat chat,
    ({Note note, NoteVoiceRef ref}) voice,
    KapyMessage question,
    ({TranslateScope scope, Language language}) asked,
    KapyModel using,
  ) async {
    final sent = translationParts(voice.ref, asked.scope);
    if (sent.isEmpty) {
      throw AnswerFailed(switch (asked.scope) {
        TranslateScope.summary => 'This recording has no summary to translate.',
        TranslateScope.transcript =>
          "This recording's transcript has no words to translate.",
      }, retry: false);
    }
    final kept = _translated;
    final done =
        kept != null &&
            kept.question == question.id &&
            listEquals(kept.sent, sent)
        ? kept.done
        : <String>[];
    _translated = (question: question.id, sent: sent, done: done);
    final named = voice.ref.summary?.title.trim() ?? '';
    final title = named.isEmpty ? voice.note.title : named;
    for (var i = done.length; i < sent.length; i++) {
      _draft = KapyTranslationDraft(
        text: stitchTranslation(done),
        done: i,
        parts: sent.length,
      );
      _notify();
      final notes = readableNotes(_notes, [
        ReadNote(
          id: voice.note.id,
          title: title.length > 180 ? title.substring(0, 180) : title,
          text: sent[i],
          edited: voice.note.updatedAt,
        ),
      ]);
      if (notes.isEmpty) {
        throw AnswerFailed(_refusal(chat.recording!), retry: false);
      }
      final reply = await _engineFor(using).answer(
        using,
        AnswerRequest(
          question: translationQuestion(
            asked.scope,
            asked.language,
            part: i + 1,
            parts: sent.length,
          ),
          notes: notes,
          today: _now(),
        ),
      );
      final part = translatedPart(sent[i], reply);
      if (part == null) {
        throw const AnswerFailed(
          "Part of the translation didn't come back whole. Try again.",
        );
      }
      done.add(part);
    }
    _translated = null;
    final now = _chat(chat.id);
    if (now == null) return;
    final at = _now();
    final read = KapyNoteRef(
      noteId: voice.note.id,
      title: title,
      edited: voice.note.updatedAt,
    );
    _replace(
      _edit(
        now,
        messages: [
          ...now.messages,
          // A millisecond apart, so every device puts them in this order.
          for (final (index, text) in done.indexed)
            KapyMessage(
              id: NotesStore.newId(),
              role: KapyRole.assistant,
              text: text,
              at: at.add(Duration(milliseconds: index)),
              read: [read],
              model: using,
            ),
        ],
      ),
    );
  }

  /// The note and recording [link] names, when Kapy AI may read it: the
  /// note is there and not hidden, and the recording has a transcript.
  ({Note note, NoteVoiceRef ref})? _recording(KapyRecordingRef link) {
    for (final note in _notes.allNotes) {
      if (note.id != link.noteId || note.isHidden) continue;
      for (final ref in note.attachments) {
        if (ref is NoteVoiceRef &&
            ref.hash == link.hash &&
            (ref.transcript?.segments.isNotEmpty ?? false)) {
          return (note: note, ref: ref);
        }
      }
    }
    return null;
  }

  /// Why [_recording] found nothing to read for [link].
  String _refusal(KapyRecordingRef link) =>
      _notes.allNotes.any((note) => note.id == link.noteId && note.isHidden)
      ? "Kapy AI doesn't read hidden notes."
      : 'This recording has no transcript to read.';

  /// What [model] reads of the notes, or of a recording.
  RetrievalBudget _budgetFor(KapyModel model) =>
      model.kind == KapyModelKind.device
      ? RetrievalBudget.device(_device.noteChars)
      : RetrievalBudget.cloud;

  /// What has to happen before [model] may answer, or null when nothing.
  /// [recording] when the question is about one, and [cloudOnly] when it
  /// can't be answered on this device, which no card then offers.
  KapyPending? _holdFor(
    KapyModel model, {
    bool recording = false,
    bool cloudOnly = false,
  }) {
    final blocked = _device.state.note;
    // Nothing on this device can answer and the person is not on Pro: the
    // note says more than "part of Pro" would, so it goes first.
    if (blocked != null &&
        !cloudOnly &&
        !isPro &&
        model.kind != KapyModelKind.codex &&
        model.kind != KapyModelKind.claudeCode &&
        model.kind != KapyModelKind.openRouter) {
      return KapyFailed(blocked, fallbacks: _alternativesTo(model));
    }
    final account = _accountOf(model.kind);
    if (account != null) {
      // A choice that cannot answer right now says so, rather than asking
      // consent for a send that would fail. The card offers what would work.
      if (!_usable(model)) {
        return KapyAccountError(
          account: account,
          model: model,
          fallbacks: _alternativesTo(model, device: !cloudOnly),
        );
      }
      return _store.hasAccountConsent(account)
          ? null
          : KapyAccountConsent(account);
    }
    if (model.kind == KapyModelKind.cloud) {
      if (!isPro) return _cloudLocked(model, device: !cloudOnly);
      if (_store.cloudConsent || (recording && _store.recordingCloudConsent)) {
        return null;
      }
      return KapyCloudConsent(recording: recording, device: !cloudOnly);
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
        fallbacks: _alternativesTo(model),
      ),
      DeviceModelStatus.unavailable => KapyFailed(
        "This device can't run an on-device model.",
        fallbacks: _alternativesTo(model),
      ),
    };
  }

  /// Kapy AI Cloud refused [model]'s question: [signIn] when the server said
  /// the session ended, [upgrade] when it said there's no Pro, and either
  /// whenever this device already knows it. [device] offers the device's
  /// model among the ways out.
  KapyCloudLocked _cloudLocked(
    KapyModel model, {
    bool signIn = false,
    bool upgrade = false,
    bool device = true,
  }) => KapyCloudLocked(
    signIn: signIn || !_signedIn,
    upgrade: upgrade || !isPro,
    fallbacks: _alternativesTo(model, device: device),
  );

  /// What could answer instead of [using], as choices for the person to make,
  /// the device's model among them when [device]. Never applied on their
  /// behalf: each still asks for its own consent.
  List<KapyModel> _alternativesTo(KapyModel using, {bool device = true}) {
    final out = <KapyModel>[];
    final local = device ? _deviceModel : null;
    if (local != null && local != using && _usable(local)) out.add(local);
    if (isPro && using.kind != KapyModelKind.cloud) out.add(KapyModel.cloud);
    for (final account in accounts) {
      if (!account.enabled) continue;
      for (final model in account.models) {
        if (model != using && _usable(model)) out.add(model);
      }
    }
    return out;
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
      case KapyCloudConsent(:final recording):
        if (recording) {
          _store.recordingCloudConsent = true;
        } else {
          _store.cloudConsent = true;
        }
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
      case KapyDownloading() || KapyLimitReached() || KapyCloudLocked() || null:
        return;
    }
  }

  @override
  Future<void> answerWith(KapyModel model) async {
    pickModel(model);
    final chat = current;
    if (!_answering &&
        _pending == null &&
        chat != null &&
        chat.messages.length > 1 &&
        chat.messages.last.role == KapyRole.assistant) {
      final question = chat.messages.lastWhere(
        (message) => message.role == KapyRole.user,
      );
      _replace(
        _edit(
          chat,
          messages: [
            ...chat.messages,
            KapyMessage(
              id: NotesStore.newId(),
              role: KapyRole.user,
              text: question.text,
              at: _now(),
            ),
          ],
        ),
      );
    }
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
    _notes.removeListener(_onNotes);
    _billing?.removeListener(_onBilling);
    _book.removeListener(_notify);
    super.dispose();
  }
}
