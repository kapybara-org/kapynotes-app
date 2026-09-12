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
///
/// Signed out there is no account for the server to grant to, and one thing
/// still has to work: the note limit, which is the only part of Pro that needs
/// no account. So buying signed out is allowed, [proOnThisDevice] comes from
/// the store itself, and signing in hands the purchase over — the SDK aliases
/// it, the server claims it (`adopt`), and from then on the server's answer is
/// the only one that counts again.
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
    _proOnThisDevice =
        _cache?.read<Map<String, Object?>>(_deviceKey)?['pro'] == true;
    _session.addListener(_onSession);
    _onSession();
    // A launch signed out notifies nothing — the id has not changed — so the
    // check that a refund has not taken this back belongs here.
    if (_proOnThisDevice) unawaited(_readStore());
  }

  static const _cacheKey = 'billing.v1';

  /// Kept beside the account's answer but not keyed by an account, because
  /// what it records happened before there was one.
  static const _deviceKey = 'billing.device.v1';

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

  /// What the store said was bought here, for the stretch where there is no
  /// account to ask instead. Never consulted while signed in.
  ///
  /// Remembered on disk so a launch knows it without asking, and re-checked
  /// against the store whenever it is true — a refund has to take it back.
  /// A device that has never bought anything never asks, and so never tells
  /// RevenueCat that it exists.
  bool _proOnThisDevice = false;

  /// Whether this build can buy anything at all.
  bool get canPurchase => _store.isSupported;
  bool get isSignedIn => _userId != null;

  /// Whether Pro was bought on this device but has no account yet.
  ///
  /// Only the note limit follows it; sync, sharing, storage and minutes all
  /// belong to an account and wait for one. False the moment somebody signs
  /// in, because the server answers for them from then on.
  bool get proOnThisDevice => _userId == null && _proOnThisDevice;

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
      // Signed out, the store is the only record again — and it may still
      // hold a purchase made on this Apple ID, whoever was signed in.
      unawaited(_readStore(force: true));
    } else {
      unawaited(_joinAccount(id));
    }
    notifyListeners();
  }

  /// Signing in: the store hands whatever was bought here to this account,
  /// and the server claims it. Only then is its answer worth asking for.
  Future<void> _joinAccount(String id) async {
    await _quietly(() => _store.logIn(id));
    if (_userId != id) return;
    await _adopt(id);
    if (_userId == id) await refresh();
  }

  /// Claims a purchase made before there was an account. Quiet unless the
  /// answer is one somebody has to hear: a purchase that stays where it is.
  Future<void> _adopt(String id) async {
    final token = _tokenOf();
    if (token == null) return;
    try {
      final adopted = await _apiFor(token).adopt();
      if (_userId != id) return;
      _entitlements = adopted.entitlements;
      _askedAt = _now();
      _cache?.put(_cacheKey, {
        'userId': id,
        'entitlements': adopted.entitlements.toJson(),
      });
      _armTrialEnd();
      if (adopted.heldByAnother) {
        _notice =
            'A purchase on this Apple ID belongs to a different Kapy Notes '
            'account. Sign in to that account to use it.';
      }
      notifyListeners();
    } catch (error) {
      // A server too old to know the route, no key configured, or offline.
      // The webhook is the ordinary way in; this was the repair.
      debugPrint('KapyNotes: could not claim earlier purchases: $error');
    }
  }

  /// Asks the store what it has sold here. Signed out only; see
  /// [proOnThisDevice].
  ///
  /// Without [force] it asks only when this device already believes it bought
  /// something, so a fresh install never reaches RevenueCat at all.
  Future<void> _readStore({bool force = false}) async {
    if (!canPurchase || (!force && !_proOnThisDevice)) return;
    try {
      final owned = await _store.ownsProHere();
      if (_userId != null || owned == _proOnThisDevice) return;
      _proOnThisDevice = owned;
      _cache?.put(_deviceKey, {'pro': owned});
      notifyListeners();
    } catch (error) {
      debugPrint('KapyNotes: could not read the store: $error');
    }
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

  /// Fetches prices, which only the store can give. Works signed out: the
  /// store keeps an id of its own until an account claims what it sold.
  Future<void> loadOffers() async {
    final id = _userId;
    if (!canPurchase || _offersLoading) return;
    _offersLoading = true;
    _offersFailed = false;
    notifyListeners();
    try {
      final offers = await _store.offers(userId: id);
      if (_userId != id) return;
      // Asking for prices is the first thing a signed-out sheet does, and it
      // sets the store up; what it already sold is worth reading while there.
      if (id == null) unawaited(_readStore(force: true));
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
    // Signed out, only the one product that unlocks something without an
    // account: a pack bought with no account to add it to would be money for
    // nothing until somebody signed in.
    if (id == null && sku != Sku.proLifetime) {
      return const PurchaseFailed(
        'Sign in first. Packs are added to your Kapy Notes account.',
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
      final before = _entitlements ?? (id == null ? null : await refresh());
      final outcome = await _store.buy(sku, userId: id);
      if (outcome is PurchaseCompleted && id == null) {
        // Nothing to confirm against: the store is the only record until an
        // account claims it.
        await _readStore(force: true);
      } else if (outcome is PurchaseCompleted) {
        _activity = BillingActivity.confirming;
        notifyListeners();
        final arrived = await _waitFor(sku, before, id!, confirmFor);
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
    if (_activity != BillingActivity.idle) return RestoreResult.failed;

    _activity = BillingActivity.restoring;
    _notice = null;
    notifyListeners();
    try {
      final owned = await _store.restore(userId: id);
      if (id == null) {
        // Restoring with no account puts Pro back on this device, which is
        // all it can put back; the rest waits for somebody to sign in.
        await _readStore(force: true);
        return owned.contains(Sku.proLifetime)
            ? RestoreResult.restored
            : RestoreResult.nothingFound;
      }
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
