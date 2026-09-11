import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/local_store.dart';
import 'billing_api.dart';
import 'entitlements.dart';
import 'purchase_store.dart';

/// What billing is busy with, so the sheet can say so instead of spinning.
enum BillingActivity { idle, buying, confirming, restoring }

/// How asking the store for past purchases ended.
enum RestoreResult {
  /// Pro is on this account now.
  restored,

  /// This store account never bought anything that restores.
  nothingFound,

  /// This store account bought Pro, but for another Kapy Notes account. The
  /// licence is the account that paid, so it stays there.
  belongsToAnotherAccount,
  signedOut,
  failed,
}

/// What this account has, and the way to buy more.
///
/// Follows the account rather than living inside it: a purchase belongs to a
/// session, not to the unlocked vault that sync hangs off, so it must work in
/// every signed-in state — including the ones before a passphrase exists.
///
/// A purchase is not finished when the store says so. The store tells
/// RevenueCat, RevenueCat tells the server, and only the server's answer is
/// shown — so after every purchase this asks the server until the thing bought
/// is there, rather than trusting the store's word on the device.
class Billing extends ChangeNotifier {
  Billing({
    required Listenable session,
    required String? Function() userId,
    required String? Function() token,
    required BillingApi Function(String token) api,
    required PurchaseStore store,
    LocalStore? cache,
    DateTime Function()? now,
    this.confirmEvery = const Duration(milliseconds: 1500),
    this.confirmFor = const Duration(seconds: 30),
    this.restoreConfirmFor = const Duration(seconds: 10),
    this.trialEndGrace = const Duration(seconds: 2),
  }) : _session = session,
       _userIdOf = userId,
       _tokenOf = token,
       _apiFor = api,
       _store = store,
       _cache = cache,
       _now = now ?? DateTime.now {
    _session.addListener(_onSession);
    _onSession();
  }

  static const _cacheKey = 'billing.v1';

  final Listenable _session;
  final String? Function() _userIdOf;
  final String? Function() _tokenOf;
  final BillingApi Function(String token) _apiFor;
  final PurchaseStore _store;
  final LocalStore? _cache;
  final DateTime Function() _now;

  /// Asks again the moment a trial ends, because every field of the answer
  /// changes then and nothing on the server announces it to an app without
  /// a socket. See [Entitlements.trialEndsAt].
  Timer? _trialEnd;
  DateTime? _askedAt;

  /// How often, and for how long, to ask the server whether a purchase has
  /// arrived. A webhook normally lands in seconds; past this the sheet stops
  /// waiting and says the payment went through and the rest is on its way.
  final Duration confirmEvery;
  final Duration confirmFor;
  final Duration restoreConfirmFor;

  /// How long past the end of a trial to ask again: a moment, so the server's
  /// clock has certainly moved on too.
  final Duration trialEndGrace;

  String? _userId;
  Entitlements? _entitlements;
  List<StoreOffer> _offers = const [];
  bool _offersLoading = false;
  bool _offersFailed = false;
  BillingActivity _activity = BillingActivity.idle;
  Sku? _activeSku;
  String? _notice;

  /// Whether this build can buy anything at all.
  bool get canPurchase => _store.isSupported;
  bool get isSignedIn => _userId != null;

  /// The server's last answer for this account. Null while signed out, and
  /// until the first answer arrives on a device that has never had one.
  Entitlements? get entitlements => _entitlements;

  /// Whether this account is trying Pro rather than owning it, right now.
  bool get trialRunning => _entitlements?.trialRunningAt(_now()) ?? false;

  /// Whole days of the trial left, counting today, while one runs: 14 on the
  /// day it starts, 1 on its last. Null otherwise.
  int? get trialDaysLeft {
    final ends = _entitlements?.trialEndsAt;
    if (ends == null || !trialRunning) return null;
    final left = ends.difference(_now());
    return (left.inMinutes / Duration.minutesPerDay).ceil().clamp(1, 1 << 16);
  }

  /// What the store will sell here, with its prices. Empty until asked.
  List<StoreOffer> get offers => _offers;
  bool get offersLoading => _offersLoading;

  /// The store was asked and did not answer, or had nothing to sell.
  bool get offersFailed => _offersFailed;
  BillingActivity get activity => _activity;

  /// Which sku the current purchase is for, while one is under way.
  Sku? get activeSku => _activeSku;

  /// Something worth saying that outlives a toast: a payment the account has
  /// not heard about yet, or one waiting on approval.
  String? get notice => _notice;

  StoreOffer? offerFor(Sku sku) {
    for (final offer in _offers) {
      if (offer.sku == sku) return offer;
    }
    return null;
  }

  /// Whether another storage pack would still add anything. Past the cap the
  /// server clamps rather than refuses — the money is taken by then — so the
  /// buy button is where it has to stop.
  bool get canAddStorage {
    final now = _entitlements;
    if (now == null || !now.isPro) return false;
    final bonus = now.storageBytes - proStorageBytes;
    return bonus + storagePackBytes <= maxBonusStorageBytes;
  }

  void clearNotice() {
    if (_notice == null) return;
    _notice = null;
    notifyListeners();
  }

  /// Runs on every account notification, which is often — sync forwards its
  /// status through it — so everything past the id check is rare.
  void _onSession() {
    final id = _userIdOf();
    if (id == _userId) return;
    _userId = id;
    _offers = const [];
    _offersFailed = false;
    _notice = null;
    // A null id is also what a launch looks like before the keystore has
    // been read, so it leaves the cache alone: the cache is keyed by account,
    // and a different account simply never reads this one's answer.
    _entitlements = id == null ? null : _readCache(id);
    _askedAt = null;
    _armTrialEnd();
    if (id == null) {
      unawaited(_quietly(_store.logOut));
    } else {
      unawaited(_quietly(() => _store.logIn(id)));
      unawaited(refresh());
    }
    notifyListeners();
  }

  /// Asks again if the answer here is older than [maxAge], or describes a
  /// trial that has since ended. For coming back to the foreground: a timer
  /// does not run while a phone has the app suspended.
  Future<void> refreshIfStale({
    Duration maxAge = const Duration(minutes: 30),
  }) async {
    if (_userId == null) return;
    final asked = _askedAt;
    final ends = _entitlements?.trialEndsAt;
    final trialOver =
        ends != null &&
        !(_entitlements?.isPro ?? false) &&
        !ends.isAfter(_now()) &&
        _entitlements?.noteLimit == null;
    if (asked != null && _now().difference(asked) < maxAge && !trialOver) {
      return;
    }
    await refresh();
  }

  void _armTrialEnd() {
    _trialEnd?.cancel();
    _trialEnd = null;
    final ends = _entitlements?.trialEndsAt;
    if (ends == null || !trialRunning) return;
    final wait = ends.difference(_now()) + trialEndGrace;
    _trialEnd = Timer(wait, () {
      _trialEnd = null;
      unawaited(refresh());
    });
  }

  /// Asks the server again, and keeps what it says.
  ///
  /// Quiet on failure: a cached answer, or none, is better than an error about
  /// something the user did not ask for. Returns the fresh answer, or null.
  Future<Entitlements?> refresh() async {
    final id = _userId;
    final token = _tokenOf();
    if (id == null || token == null) return null;
    try {
      final fresh = await _apiFor(token).entitlements();
      // Signed out, or somebody else signed in, while this was in flight.
      if (_userId != id) return null;
      _entitlements = fresh;
      _askedAt = _now();
      _cache?.put(_cacheKey, {'userId': id, 'entitlements': fresh.toJson()});
      _armTrialEnd();
      notifyListeners();
      return fresh;
    } catch (error) {
      debugPrint('KapyNotes: could not read entitlements: $error');
      return null;
    }
  }

  /// Fetches prices, which only the store can give. Needs an account, because
  /// the store is never set up without one.
  Future<void> loadOffers() async {
    final id = _userId;
    if (!canPurchase || id == null || _offersLoading) return;
    _offersLoading = true;
    _offersFailed = false;
    notifyListeners();
    try {
      final offers = await _store.offers(userId: id);
      if (_userId != id) return;
      _offers = offers;
      _offersFailed = offers.isEmpty;
    } catch (error) {
      debugPrint('KapyNotes: could not load store offers: $error');
      if (_userId == id) _offersFailed = true;
    } finally {
      _offersLoading = false;
      notifyListeners();
    }
  }

  Future<PurchaseOutcome> buy(Sku sku) async {
    final id = _userId;
    if (id == null) {
      return const PurchaseFailed(
        'Sign in first. Pro belongs to your Kapy Notes account.',
      );
    }
    if (_activity != BillingActivity.idle) {
      return const PurchaseFailed('Another purchase is still finishing.');
    }

    _activity = BillingActivity.buying;
    _activeSku = sku;
    _notice = null;
    notifyListeners();
    try {
      // The baseline a pack is measured against. Packs are only offered to an
      // account whose answer is already here, but asking costs one request
      // and guessing would confirm a pack that never arrived.
      final before = _entitlements ?? await refresh();
      final outcome = await _store.buy(sku, userId: id);
      if (outcome is PurchaseCompleted) {
        _activity = BillingActivity.confirming;
        notifyListeners();
        final arrived = await _waitFor(sku, before, id, confirmFor);
        if (!arrived && _userId == id) {
          _notice =
              'The App Store has taken the payment. It can take a minute to '
              'reach your account, and it will show here when it does.';
        }
      } else if (outcome is PurchasePending) {
        _notice =
            'The purchase is waiting for approval. It will show here once '
            'the App Store finishes it.';
      }
      return outcome;
    } catch (error) {
      debugPrint('KapyNotes: purchase failed: $error');
      return const PurchaseFailed(
        'The App Store could not finish that. Try again in a moment.',
      );
    } finally {
      _activity = BillingActivity.idle;
      _activeSku = null;
      notifyListeners();
    }
  }

  Future<RestoreResult> restore() async {
    final id = _userId;
    if (id == null) return RestoreResult.signedOut;
    if (_activity != BillingActivity.idle) return RestoreResult.failed;

    _activity = BillingActivity.restoring;
    _notice = null;
    notifyListeners();
    try {
      final owned = await _store.restore(userId: id);
      final now = await refresh();
      if (now?.isPro ?? false) return RestoreResult.restored;
      if (!owned.contains(Sku.proLifetime)) return RestoreResult.nothingFound;
      // The store says this Apple ID bought Pro and the server has not
      // granted it here. A purchase made seconds ago can still be in flight,
      // so give it a moment before concluding it was bought for someone else.
      final arrived = await _waitFor(
        Sku.proLifetime,
        now,
        id,
        restoreConfirmFor,
      );
      return arrived
          ? RestoreResult.restored
          : RestoreResult.belongsToAnotherAccount;
    } catch (error) {
      debugPrint('KapyNotes: restore failed: $error');
      return RestoreResult.failed;
    } finally {
      _activity = BillingActivity.idle;
      notifyListeners();
    }
  }

  Future<bool> _waitFor(
    Sku sku,
    Entitlements? before,
    String id,
    Duration within,
  ) async {
    final clock = Stopwatch()..start();
    while (true) {
      final now = await refresh();
      if (_userId != id) return false;
      if (now != null && _reflects(sku, before, now)) return true;
      if (clock.elapsed >= within) return false;
      await Future<void>.delayed(confirmEvery);
    }
  }

  static bool _reflects(Sku sku, Entitlements? before, Entitlements now) =>
      switch (sku) {
        Sku.proLifetime => now.isPro,
        Sku.storage5gb => now.storageBytes > (before?.storageBytes ?? 0),
        Sku.voice1000 =>
          now.speechCreditSeconds > (before?.speechCreditSeconds ?? 0),
      };

  Entitlements? _readCache(String id) {
    final raw = _cache?.read<Map<String, Object?>>(_cacheKey);
    if (raw == null || raw['userId'] != id) return null;
    final stored = raw['entitlements'];
    return stored is Map
        ? Entitlements.fromJson(stored.cast<String, Object?>())
        : null;
  }

  /// Store bookkeeping that must never take the app down with it: a sign-in
  /// that cannot reach RevenueCat just means the next purchase identifies
  /// again first.
  Future<void> _quietly(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      debugPrint('KapyNotes: store session: $error');
    }
  }

  @override
  void dispose() {
    _trialEnd?.cancel();
    _session.removeListener(_onSession);
    super.dispose();
  }
}
