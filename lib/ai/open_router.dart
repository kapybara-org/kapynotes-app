import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../sync/key_store.dart';
import 'answer_engine.dart';
import 'kapy_ai.dart';

/// The person's own OpenRouter key.
///
/// The key lives in the keychain on this device and nowhere else: never in
/// the JSON store, never synced, never sent anywhere but OpenRouter.
class OpenRouterAccount implements AnswerEngine {
  OpenRouterAccount({required SecureStore secrets, required http.Client client})
    : _secrets = secrets,
      _client = client;

  final SecureStore _secrets;
  final http.Client _client;

  static const String keyEntry = 'kapynotes.openRouterKey';
  static final Uri _api = Uri.parse('https://openrouter.ai/api/v1/');

  /// What the picker offers, by name: a short list rather than OpenRouter's
  /// hundreds, cut to the ones OpenRouter still lists once a key is saved.
  static const List<KapyModel> curated = [
    KapyModel(
      kind: KapyModelKind.openRouter,
      id: 'google/gemini-3.8-flash',
      label: 'Fast',
    ),
    KapyModel(
      kind: KapyModelKind.openRouter,
      id: 'openai/gpt-5.5',
      label: 'Strong',
    ),
    KapyModel(
      kind: KapyModelKind.openRouter,
      id: 'anthropic/claude-sonnet-5.5',
      label: 'Careful',
    ),
  ];

  String? _key;
  bool _rejected = false;
  List<KapyModel> _models = curated;

  KapyAccountState get state {
    final key = _key;
    if (_rejected) {
      return const KapyAccountState(
        kind: KapyAccountKind.openRouter,
        status: KapyAccountStatus.error,
      );
    }
    if (key == null) {
      return const KapyAccountState(
        kind: KapyAccountKind.openRouter,
        status: KapyAccountStatus.notConnected,
      );
    }
    return KapyAccountState(
      kind: KapyAccountKind.openRouter,
      status: KapyAccountStatus.connected,
      models: _models,
      detail: key.length > 4 ? key.substring(key.length - 4) : key,
    );
  }

  /// Reads the saved key. Keychain only: which models OpenRouter still
  /// lists is asked when there is a reason to, not at launch.
  Future<void> load() async {
    _key = await _secrets.read(keyEntry);
  }

  /// Keeps [key] once OpenRouter has accepted it. False when it was
  /// rejected, or OpenRouter could not be reached to ask: either way nothing
  /// was saved.
  Future<bool> save(String key) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) return false;
    final http.Response response;
    try {
      response = await _client
          .get(
            _api.resolve('key'),
            headers: {'authorization': 'Bearer $trimmed'},
          )
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      return false;
    }
    if (response.statusCode != 200) {
      // A bad replacement leaves a good key where it was.
      _rejected =
          _key == null &&
          (response.statusCode == 401 || response.statusCode == 403);
      return false;
    }
    await _secrets.write(keyEntry, trimmed);
    _key = trimmed;
    _rejected = false;
    await refreshModels();
    return true;
  }

  Future<void> remove() async {
    await _secrets.delete(keyEntry);
    _key = null;
    _rejected = false;
    _models = curated;
  }

  /// Cuts [curated] to what OpenRouter lists today. Keeps the list as it was
  /// when OpenRouter cannot be reached.
  Future<void> refreshModels() async {
    try {
      final response = await _client
          .get(_api.resolve('models'))
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) return;
      final data = (jsonDecode(response.body) as Map)['data'] as List;
      final listed = {for (final model in data) (model as Map)['id']};
      _models = [
        for (final model in curated)
          if (listed.contains(model.id)) model,
      ];
    } catch (_) {
      return;
    }
  }

  @override
  Future<String> answer(KapyModel model, AnswerRequest request) async {
    final key = _key;
    if (key == null) {
      throw const AnswerAccountRejected(KapyAccountKind.openRouter);
    }
    final http.Response response;
    try {
      response = await _client
          .post(
            _api.resolve('chat/completions'),
            headers: {
              'authorization': 'Bearer $key',
              'content-type': 'application/json',
              // OpenRouter's app attribution: who sent this, not who asked.
              'http-referer': 'https://kapynotes.com',
              'x-title': 'Kapy Notes',
            },
            body: jsonEncode({
              'model': model.id,
              'messages': [
                {
                  'role': 'system',
                  'content': answerInstructions(request.today),
                },
                {'role': 'user', 'content': answerPrompt(request)},
              ],
            }),
          )
          .timeout(const Duration(seconds: 120));
    } catch (_) {
      throw const AnswerOffline();
    }
    switch (response.statusCode) {
      case 200:
        break;
      case 401 || 403:
        _rejected = true;
        throw const AnswerAccountRejected(KapyAccountKind.openRouter);
      case 402:
        throw const AnswerFailed('Your key is out of credits.');
      case 429:
        throw const AnswerFailed('Busy just now. Try again in a moment.');
      default:
        throw const AnswerFailed("Couldn't answer. Try again.");
    }
    try {
      final body = jsonDecode(response.body) as Map;
      final choice = (body['choices'] as List).first as Map;
      final text = ((choice['message'] as Map)['content'] as String).trim();
      if (text.isNotEmpty) return text;
    } catch (_) {
      // Falls through to the same answer as an empty one.
    }
    throw const AnswerFailed("Couldn't answer. Try again.");
  }
}
