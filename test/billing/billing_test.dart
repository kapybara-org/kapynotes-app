import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/billing/billing.dart';
import 'package:kapy_notes/billing/billing_api.dart';
import 'package:kapy_notes/billing/entitlements.dart';
import 'package:kapy_notes/billing/purchase_store.dart';
import 'package:kapy_notes/data/local_store.dart';

import 'billing_fakes.dart';

class _Session extends ChangeNotifier {
  String? userId;
  String? get token => userId == null ? null : 'token-$userId';

  void signIn(String id) {
    userId = id;
    notifyListeners();
  }

  void signOut() {
    userId = null;
    notifyListeners();
  }
}

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'billing-test.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
  @override
  void putNow(String key, Object? value) => data[key] = value;
}

/// Lets the fire-and-forget work a session change starts run to the end.
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 5));

void main() {
  late _Session session;
  late FakeBillingApi api;
  late FakePurchaseStore store;
  late _MemoryStore cache;
  late Billing billing;

  Billing build() => Billing(
    session: session,
    userId: () => session.userId,
    token: () => session.token,
    api: (token) {
      api.tokens.add(token);
      return api;
    },
    store: store,
    cache: cache,
    confirmEvery: const Duration(milliseconds: 5),
    confirmFor: const Duration(milliseconds: 60),
    restoreConfirmFor: const Duration(milliseconds: 30),
  );

  setUp(() {
    session = _Session();
    api = FakeBillingApi();
    store = FakePurchaseStore();
    cache = _MemoryStore();
    billing = build();
  });

  tearDown(() => billing.dispose());

  test('signing in ties the store to the account and asks the server', () async {
    session.signIn('user-1');
    await settle();

    expect(store.log, contains('logIn user-1'));
    // Claiming whatever was bought before, then asking what the account has.
    expect(api.tokens, ['token-user-1', 'token-user-1']);
    expect(api.adoptCalls, 1);
    expect(billing.entitlements?.plan, 'free');
    expect(billing.isSignedIn, isTrue);
  });

  test('a cached answer shows at once, but only for its own account', () async {
    cache.data['billing.v1'] = {
      'userId': 'user-1',
      'entitlements': entitlementsFor(pro: true).toJson(),
    };
    api.answer = () => throw Exception('offline');

    session.signIn('user-1');
    expect(billing.entitlements?.isPro, isTrue);

    session.signIn('user-2');
    expect(billing.entitlements, isNull);
  });

  test('a launch leaves the cache alone until the keystore has been read', () {
    cache.data['billing.v1'] = {
      'userId': 'user-1',
      'entitlements': entitlementsFor(pro: true).toJson(),
    };
    // No session yet — which is also what a launch looks like — must not
    // throw away the answer the next session will want.
    expect(billing.entitlements, isNull);
    expect(cache.data['billing.v1'], isNotNull);
    expect(store.log, isEmpty);
  });

  test('a purchase is not finished until the server has it', () async {
    session.signIn('user-1');
    await settle();

    var calls = 0;
    api.answer = () => entitlementsFor(pro: ++calls >= 3);

    final outcome = await billing.buy(Sku.proLifetime);

    expect(outcome, isA<PurchaseCompleted>());
    expect(store.log, contains('buy pro_lifetime as user-1'));
    expect(billing.entitlements?.isPro, isTrue);
    expect(billing.notice, isNull);
    expect(billing.activity, BillingActivity.idle);
    expect(calls, greaterThanOrEqualTo(3));
  });

  test('a payment the server never hears of says so, and keeps asking no more', () async {
    session.signIn('user-1');
    await settle();

    final outcome = await billing.buy(Sku.proLifetime);

    expect(outcome, isA<PurchaseCompleted>());
    expect(billing.entitlements?.isPro, isFalse);
    expect(billing.notice, contains('payment has gone through'));
    expect(billing.activity, BillingActivity.idle);
  });

  test('a cancelled purchase is not an error and leaves nothing behind', () async {
    session.signIn('user-1');
    await settle();
    store.next = const PurchaseCancelled();
    final before = api.calls;

    final outcome = await billing.buy(Sku.proLifetime);

    expect(outcome, isA<PurchaseCancelled>());
    expect(billing.notice, isNull);
    // Nothing was bought, so there is nothing to wait for.
    expect(api.calls, before);
  });

  test('a purchase waiting on Ask to Buy leaves a notice', () async {
    session.signIn('user-1');
    await settle();
    store.next = const PurchasePending();

    await billing.buy(Sku.proLifetime);

    expect(billing.notice, contains('waiting for approval'));
  });

  group('bought before signing in', () {
    test('Pro unlocks this device, and waits for an account for the rest', () async {
      final outcome = await billing.buy(Sku.proLifetime);

      expect(outcome, isA<PurchaseCompleted>());
      expect(store.log, contains('buy pro_lifetime as nobody'));
      expect(billing.proOnThisDevice, isTrue);
      // Nothing was asked of the server: there is no account to ask about.
      expect(api.calls, 0);
      expect(billing.entitlements, isNull);
    });

    test('a pack is not, because it has nowhere to go', () async {
      final outcome = await billing.buy(Sku.storage5gb);

      expect(outcome, isA<PurchaseFailed>());
      expect(store.log.where((line) => line.startsWith('buy')), isEmpty);
    });

    test('a device that never bought anything never asks the store', () async {
      expect(store.ownsProCalls, 0);
      expect(billing.proOnThisDevice, isFalse);
    });

    test('and a later launch knows it without asking anybody', () async {
      await billing.buy(Sku.proLifetime);
      expect(cache.data['billing.device.v1'], {'pro': true});

      final relaunched = build();
      addTearDown(relaunched.dispose);
      expect(relaunched.proOnThisDevice, isTrue);
    });

    test('a refund takes it back on the next look', () async {
      await billing.buy(Sku.proLifetime);
      expect(billing.proOnThisDevice, isTrue);

      store.ownsPro = false;
      final relaunched = build();
      addTearDown(relaunched.dispose);
      await settle();
      expect(relaunched.proOnThisDevice, isFalse);
    });

    test('signing in hands it to the account', () async {
      await billing.buy(Sku.proLifetime);
      api.claimed = ['pro_lifetime'];
      api.answer = () => entitlementsFor(pro: true);

      session.signIn('user-1');
      await settle();

      expect(store.log, contains('logIn user-1'));
      expect(api.adoptCalls, 1);
      expect(billing.entitlements?.isPro, isTrue);
      // Signed in, the server answers for the device as well.
      expect(billing.proOnThisDevice, isFalse);
    });

    test('one that belongs to another account says so rather than nothing', () async {
      await billing.buy(Sku.proLifetime);
      api.heldByAnother = true;

      session.signIn('user-2');
      await settle();

      expect(billing.notice, contains('different Kapy Notes account'));
      expect(billing.entitlements?.isPro, isFalse);
    });

    test('a server that cannot claim it leaves the account as it was', () async {
      await billing.buy(Sku.proLifetime);
      api.adoptFailure = Exception('no route');

      session.signIn('user-1');
      await settle();

      expect(api.calls, greaterThan(0), reason: 'it still asks what it has');
      expect(billing.notice, isNull);
    });
  });

  test('a storage pack is confirmed by the storage growing', () async {
    api.answer = () => entitlementsFor(pro: true);
    session.signIn('user-1');
    await settle();

    var bought = false;
    store.onBuy = () => bought = true;
    api.answer = () => entitlementsFor(
      pro: true,
      storageBytes: proStorageBytes + (bought ? storagePackBytes : 0),
    );

    final outcome = await billing.buy(Sku.storage5gb);

    expect(outcome, isA<PurchaseCompleted>());
    expect(billing.notice, isNull);
    expect(billing.entitlements?.storageBytes, proStorageBytes + storagePackBytes);
  });

  test('no more storage packs once the cap is reached', () async {
    api.answer = () => entitlementsFor(
      pro: true,
      storageBytes: proStorageBytes + maxBonusStorageBytes,
    );
    session.signIn('user-1');
    await settle();

    expect(billing.canAddStorage, isFalse);

    api.answer = () => entitlementsFor(pro: true);
    await billing.refresh();
    expect(billing.canAddStorage, isTrue);
  });

  test('packs are never offered to a free account', () async {
    session.signIn('user-1');
    await settle();
    expect(billing.canAddStorage, isFalse);
  });

  test('restoring Pro this account already has says so', () async {
    api.answer = () => entitlementsFor(pro: true);
    session.signIn('user-1');
    await settle();
    store.owned = {Sku.proLifetime};

    expect(await billing.restore(), RestoreResult.restored);
  });

  test('restoring with nothing bought finds nothing', () async {
    session.signIn('user-1');
    await settle();

    expect(await billing.restore(), RestoreResult.nothingFound);
  });

  test('Pro bought for another account stays with that account', () async {
    session.signIn('user-1');
    await settle();
    store.owned = {Sku.proLifetime};

    expect(await billing.restore(), RestoreResult.belongsToAnotherAccount);
    expect(billing.entitlements?.isPro, isFalse);
  });

  test('a restore that races a fresh purchase waits for it', () async {
    session.signIn('user-1');
    await settle();
    store.owned = {Sku.proLifetime};
    var calls = 0;
    api.answer = () => entitlementsFor(pro: ++calls >= 3);

    expect(await billing.restore(), RestoreResult.restored);
  });

  test('signing out logs the store out and forgets the answer', () async {
    session.signIn('user-1');
    await settle();
    session.signOut();
    await settle();

    expect(billing.entitlements, isNull);
    expect(billing.isSignedIn, isFalse);
    expect(store.log, contains('logOut'));
    // And then asked what it still holds: this Apple ID may have bought Pro
    // here, whoever was signed in at the time.
    expect(store.log.last, 'ownsProHere');
  });

  test('prices are shown before signing in, because buying does not need it', () async {
    await billing.loadOffers();
    expect(billing.offerFor(Sku.proLifetime)?.price, r'$24.00');
    expect(store.log, contains('offers as nobody'));

    session.signIn('user-1');
    await settle();
    await billing.loadOffers();
    expect(billing.offerFor(Sku.proLifetime)?.price, r'$24.00');
    expect(store.log, contains('offers as user-1'));
  });

  test('a store with nothing to sell reads as a failure to answer', () async {
    store.offerList = const [];
    session.signIn('user-1');
    await settle();
    await billing.loadOffers();
    expect(billing.offersFailed, isTrue);
  });

  test('an answer for an account that has since signed out is dropped', () async {
    session.signIn('user-1');
    await settle();
    api.answer = () {
      session.signOut();
      return entitlementsFor(pro: true);
    };

    expect(await billing.refresh(), isNull);
    expect(billing.entitlements, isNull);
  });

  group('the trial', () {
    test('is read from the answer, with the days counted from today', () async {
      final clock = DateTime.utc(2026, 10, 1, 12);
      billing.dispose();
      billing = Billing(
        session: session,
        userId: () => session.userId,
        token: () => session.token,
        api: (_) => api,
        store: store,
        now: () => clock,
      );
      api.answer = () =>
          trialFor(const Duration(days: 3, hours: 12), from: clock);
      session.signIn('user-1');
      await settle();

      expect(billing.trialRunning, isTrue);
      expect(billing.trialDaysLeft, 4);
      // Trying Pro is not owning it, so nothing sold only to owners shows.
      expect(billing.entitlements!.isPro, isFalse);
      expect(billing.canAddStorage, isFalse);
    });

    test('is asked about again the moment it ends', () async {
      billing.dispose();
      billing = Billing(
        session: session,
        userId: () => session.userId,
        token: () => session.token,
        api: (_) => api,
        store: store,
        trialEndGrace: Duration.zero,
      );
      api.answer = () => trialFor(const Duration(milliseconds: 60));
      session.signIn('user-1');
      await settle();
      expect(billing.trialRunning, isTrue);
      final asked = api.calls;

      api.answer = afterTrial;
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(api.calls, asked + 1);
      expect(billing.trialRunning, isFalse);
      expect(billing.trialDaysLeft, isNull);
      expect(billing.entitlements!.noteLimit, 5);
    });

    test('coming back asks again only once the answer is old or the trial over', () async {
      var clock = DateTime.utc(2026, 10, 1, 12);
      billing.dispose();
      billing = Billing(
        session: session,
        userId: () => session.userId,
        token: () => session.token,
        api: (_) => api,
        store: store,
        now: () => clock,
      );
      api.answer = () => trialFor(const Duration(days: 2), from: clock);
      session.signIn('user-1');
      await settle();
      final asked = api.calls;

      await billing.refreshIfStale();
      expect(api.calls, asked, reason: 'fresh, and the trial still running');

      // Suspended past the end of it: no timer fired, so resuming asks.
      clock = clock.add(const Duration(days: 2, minutes: 1));
      await billing.refreshIfStale(maxAge: const Duration(days: 30));
      expect(api.calls, asked + 1);
    });

    test('survives in the cache the way the rest of the answer does', () {
      final ends = DateTime.utc(2026, 10, 15, 9, 30);
      final read = Entitlements.fromJson(
        entitlementsFor(noteLimit: 5, trialEndsAt: ends).toJson(),
      );
      expect(read.noteLimit, 5);
      expect(read.trialEndsAt, ends);
      // A server from before trials sends neither, which is no limit at all.
      final old = Entitlements.fromJson({'plan': 'free', 'sync': true});
      expect(old.noteLimit, isNull);
      expect(old.trialEndsAt, isNull);
    });
  });

  test('the http client refuses to run signed out', () async {
    final http = HttpBillingApi(
      baseUrl: Uri.parse('https://example.invalid/'),
      token: () async => null,
    );
    await expectLater(http.entitlements(), throwsA(anything));
  });
}
