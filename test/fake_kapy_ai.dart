import 'package:kapy_notes/ai/kapy_ai.dart';

/// Kapy AI with nothing behind it: every state the UI can be in is a field a
/// test sets, and every member the UI can call is written down in [calls].
///
/// A question is never answered on its own. A test that wants one hands it
/// over with [set], so the moment between asking and answering is there to
/// look at.
class FakeKapyAi extends KapyAi {
  FakeKapyAi({
    bool pro = false,
    this.chatList = const [],
    this.deviceState = const DeviceModelState(
      status: DeviceModelStatus.builtIn,
      model: appleIntelligence,
    ),
    this.accountList = const [],
    this.usage,
  }) : _pro = pro,
       _model = deviceState.model ?? KapyModel.cloud,
       _default = deviceState.model ?? KapyModel.cloud;

  static const appleIntelligence = KapyModel(
    kind: KapyModelKind.device,
    id: 'apple',
    label: 'Apple Intelligence',
  );
  static const gemma = KapyModel(
    kind: KapyModelKind.device,
    id: 'gemma',
    label: 'Gemma',
  );
  static const gpt = KapyModel(
    kind: KapyModelKind.codex,
    id: 'gpt-5.5',
    label: 'GPT-5.5',
  );
  static const gptMini = KapyModel(
    kind: KapyModelKind.codex,
    id: 'gpt-5.4-mini',
    label: 'GPT-5.4 mini',
  );
  static const sonnet = KapyModel(
    kind: KapyModelKind.claudeCode,
    id: 'sonnet',
    label: 'Claude Sonnet 5.5',
  );
  static const gemini = KapyModel(
    kind: KapyModelKind.openRouter,
    id: 'google/gemini-3.8-flash',
    label: 'Gemini 3.8 Flash',
  );

  /// Everything the UI called, in order, as "name" or "name:argument".
  final List<String> calls = [];

  bool _enabled = true;
  bool _pro;
  KapyModel _model;
  KapyModel _default;
  KapyChat? _current;
  bool _answering = false;
  KapyPending? _pending;

  List<KapyChat> chatList;
  DeviceModelState deviceState;
  List<KapyAccountState> accountList;
  CloudUsage? usage;

  /// What [saveOpenRouterKey] answers with.
  bool keyAccepted = true;

  /// What the key field handed over, so a test can check it went nowhere else.
  String? lastKey;

  /// A note's suggestion, for the empty state.
  final Map<String, String> suggestions = {};

  set pro(bool value) {
    _pro = value;
    notifyListeners();
  }

  /// Puts the fake in a state and tells whoever is listening.
  void set({
    List<KapyChat>? chats,
    KapyChat? current,
    bool clearCurrent = false,
    DeviceModelState? device,
    List<KapyAccountState>? accounts,
    CloudUsage? cloudUsage,
    KapyPending? pending,
    bool clearPending = false,
    bool? answering,
    KapyModel? model,
  }) {
    if (chats != null) chatList = chats;
    if (current != null) _current = current;
    if (clearCurrent) _current = null;
    if (device != null) deviceState = device;
    if (accounts != null) accountList = accounts;
    if (cloudUsage != null) usage = cloudUsage;
    if (pending != null) _pending = pending;
    if (clearPending) _pending = null;
    if (answering != null) _answering = answering;
    if (model != null) _model = model;
    notifyListeners();
  }

  @override
  bool get enabled => _enabled;
  @override
  set enabled(bool value) {
    calls.add('enabled:$value');
    _enabled = value;
    notifyListeners();
  }

  @override
  bool get isPro => _pro;

  @override
  KapyModel get defaultModel => _default;
  @override
  set defaultModel(KapyModel model) {
    calls.add('defaultModel:${model.id}');
    _default = model;
    notifyListeners();
  }

  @override
  DeviceModelState get device => deviceState;
  @override
  void downloadDeviceModel() => calls.add('downloadDeviceModel');
  @override
  void cancelDeviceDownload() => calls.add('cancelDeviceDownload');
  @override
  Future<void> removeDeviceModel() async => calls.add('removeDeviceModel');

  @override
  CloudUsage? get cloudUsage => usage;

  @override
  List<KapyAccountState> get accounts => accountList;

  @override
  List<KapyChat> get chats => chatList;
  @override
  KapyChat? get current => _current;

  @override
  KapyModel get model => _model;
  @override
  void pickModel(KapyModel model) {
    calls.add('pickModel:${model.id}');
    _model = model;
    notifyListeners();
  }

  @override
  void newChat() {
    calls.add('newChat');
    _current = null;
    notifyListeners();
  }

  @override
  void openChat(String id) {
    calls.add('openChat:$id');
    _current = chatList.firstWhere((chat) => chat.id == id);
    notifyListeners();
  }

  @override
  void renameChat(String id, String title) {
    calls.add('renameChat:$id:$title');
  }

  @override
  void deleteChat(String id) {
    calls.add('deleteChat:$id');
    chatList = [
      for (final chat in chatList)
        if (chat.id != id) chat,
    ];
    notifyListeners();
  }

  @override
  Future<void> clearHistory() async {
    calls.add('clearHistory');
    chatList = const [];
    _current = null;
    notifyListeners();
  }

  @override
  Future<void> ask(String question, {String? noteId}) async {
    calls.add('ask:$question:${noteId ?? ''}');
    _answering = true;
    notifyListeners();
  }

  @override
  String? suggestionFor(String noteId) => suggestions[noteId];

  @override
  bool get answering => _answering;
  @override
  KapyPending? get pending => _pending;

  @override
  Future<void> proceed() async {
    calls.add('proceed');
    _pending = null;
    notifyListeners();
  }

  @override
  Future<void> answerWith(KapyModel model) async {
    calls.add('answerWith:${model.id}');
    _pending = null;
    notifyListeners();
  }

  @override
  void dismissPending() {
    calls.add('dismissPending');
    _pending = null;
    notifyListeners();
  }

  @override
  Future<bool> saveOpenRouterKey(String key) async {
    calls.add('saveOpenRouterKey');
    lastKey = key;
    return keyAccepted;
  }

  @override
  Future<void> removeOpenRouterKey() async => calls.add('removeOpenRouterKey');

  @override
  Future<void> checkCodex() async => calls.add('checkCodex');
  @override
  void allowCodex(bool allowed) => calls.add('allowCodex:$allowed');

  @override
  Future<void> checkClaudeCode() async => calls.add('checkClaudeCode');
  @override
  void allowClaudeCode(bool allowed) => calls.add('allowClaudeCode:$allowed');
}
