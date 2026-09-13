import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../data/local_store.dart';

/// What the server tells anybody who asks about plans. Mirrors `PlanTerms` in
/// the contract.
class PlanTermsAnswer {
  const PlanTermsAnswer({
    required this.enforced,
    required this.trialDays,
    required this.freeNoteLimit,
  });

  final bool enforced;
  final int trialDays;
  final int freeNoteLimit;
}

/// `GET /plans`: unauthenticated, and the same answer for everybody.
abstract class PlanTermsApi {
  Future<PlanTermsAnswer> fetch();
}

class HttpPlanTermsApi implements PlanTermsApi {
  HttpPlanTermsApi({required Uri baseUrl, http.Client? client})
    : _url = baseUrl.resolve('plans'),
      _client = client ?? http.Client();

  final Uri _url;
  final http.Client _client;

  @override
  Future<PlanTermsAnswer> fetch() async {
    // No token and no device id: the answer is the same for everybody, and
    // the privacy policy says this request carries nothing about anyone.
    final response = await _client
        .get(_url, headers: const {'accept': 'application/json'})
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw http.ClientException('plans answered ${response.statusCode}');
    }
    final body = jsonDecode(response.body);
    if (body is! Map) throw const FormatException('plans: not an object');
    final days = body['trialDays'];
    final limit = body['freeNoteLimit'];
    return PlanTermsAnswer(
      enforced: body['enforced'] == true,
      trialDays: days is int && days > 0 ? days : PlanTerms.defaultTrialDays,
      freeNoteLimit: limit is int && limit > 0
          ? limit
          : PlanTerms.defaultFreeNoteLimit,
    );
  }
}

/// This device's copy of the plan terms, and its own fourteen days.
///
/// Signed out there is no account to ask, and the note limit is the one Pro
/// feature that works without one, so the device keeps a trial of its own.
/// Its clock starts where the server's does — the first time this device
/// learns plans are enforced, from `/plans` or from an account's answer — and
/// not the day it was installed, or every install made before launch would
/// have spent its fortnight while it already had everything.
///
/// Signed in, the account's answer wins; this is only the signed-out rule.
class PlanTerms extends ChangeNotifier {
  PlanTerms({
    required LocalStore store,
    required PlanTermsApi api,
    DateTime Function()? now,
    this.checkEvery = const Duration(hours: 24),
  }) : _store = store,
       _api = api,
       _now = now ?? DateTime.now;

  static const String _key = 'plans.v1';

  /// `TRIAL_DAYS` and `FREE_NOTE_LIMIT`, until the server has said otherwise.
  static const int defaultTrialDays = 14;
  static const int defaultFreeNoteLimit = 5;

  final LocalStore _store;
  final PlanTermsApi _api;
  final DateTime Function() _now;

  /// How often to ask while signed out. The privacy policy says "about once
  /// a day", so it must not become more often than that.
  final Duration checkEvery;

  bool _loaded = false;
  bool _enforced = false;
  DateTime? _enforcedSince;
  int _trialDays = defaultTrialDays;
  int _freeNoteLimit = defaultFreeNoteLimit;
  DateTime? _checkedAt;
  Future<void>? _asking;

  /// Whether plans were enforced when this device last heard.
  bool get enforced => _enforced;

  int get freeNoteLimit => _freeNoteLimit;
  int get trialDays => _trialDays;

  /// When this device's own fourteen days end, or null before they start.
  DateTime? get deviceTrialEndsAt =>
      _enforcedSince?.add(Duration(days: _trialDays));

  /// Whether the signed-out note limit applies now: plans are enforced and
  /// this device's own fourteen days are over.
  bool get limitApplies {
    final ends = deviceTrialEndsAt;
    return _enforced && ends != null && !_now().isBefore(ends);
  }

  /// Reads what the last run learned. After the store has loaded.
  void loadCache() {
    if (_loaded) return;
    _loaded = true;
    final raw = _store.read<Map<String, Object?>>(_key);
    if (raw == null) return;
    _enforced = raw['enforced'] == true;
    _enforcedSince = _date(raw['enforcedSince']);
    _checkedAt = _date(raw['checkedAt']);
    final days = raw['trialDays'];
    final limit = raw['freeNoteLimit'];
    if (days is int && days > 0) _trialDays = days;
    if (limit is int && limit > 0) _freeNoteLimit = limit;
    notifyListeners();
  }

  /// Asks the server, unless this device asked within [checkEvery]. Quiet on
  /// failure: the answer from last time, or none, is the right one to keep.
  Future<void> refreshIfStale() {
    loadCache();
    final checked = _checkedAt;
    if (checked != null && _now().difference(checked) < checkEvery) {
      return Future.value();
    }
    return _asking ??= _ask().whenComplete(() => _asking = null);
  }

  Future<void> _ask() async {
    try {
      final answer = await _api.fetch();
      _checkedAt = _now();
      _trialDays = answer.trialDays;
      _freeNoteLimit = answer.freeNoteLimit;
      _record(answer.enforced);
    } catch (error) {
      debugPrint('KapyNotes: could not read the plan terms: $error');
    }
  }

  /// An account's answer showed plans are enforced — it carried a trial or a
  /// note limit — which starts this device's clock if nothing had yet, so
  /// signing out later does not hand out a fresh fortnight.
  void noteEnforced() {
    loadCache();
    if (_enforced && _enforcedSince != null) return;
    _record(true);
  }

  void _record(bool enforced) {
    _enforced = enforced;
    if (enforced) _enforcedSince ??= _now();
    _save();
    notifyListeners();
  }

  void _save() => _store.put(_key, {
    'enforced': _enforced,
    'enforcedSince': _enforcedSince?.millisecondsSinceEpoch,
    'checkedAt': _checkedAt?.millisecondsSinceEpoch,
    'trialDays': _trialDays,
    'freeNoteLimit': _freeNoteLimit,
  });

  static DateTime? _date(Object? value) =>
      value is int ? DateTime.fromMillisecondsSinceEpoch(value) : null;
}
