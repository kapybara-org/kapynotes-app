import 'entitlements.dart';

/// One thing the store will sell, with the price it will charge here.
///
/// The price is the store's own string — `$24.00`, `₹2,300`, `24,99 €` — and is
/// never rebuilt from a number: the store knows the storefront's currency and
/// how it is written, and this app has no business guessing either.
class StoreOffer {
  const StoreOffer({required this.sku, required this.price});

  final Sku sku;
  final String price;
}

/// How asking the store to take money ended.
sealed class PurchaseOutcome {
  const PurchaseOutcome();
}

/// The store took the money. The entitlement follows through the server.
class PurchaseCompleted extends PurchaseOutcome {
  const PurchaseCompleted();
}

/// Closed the sheet. Not an error, and not worth a word.
class PurchaseCancelled extends PurchaseOutcome {
  const PurchaseCancelled();
}

/// Waiting on someone else — Ask to Buy, or a bank's own confirmation. The
/// store finishes it later, and the webhook grants it whenever it does.
class PurchasePending extends PurchaseOutcome {
  const PurchasePending();
}

class PurchaseFailed extends PurchaseOutcome {
  const PurchaseFailed(this.message);

  /// One sentence a person can act on.
  final String message;
}

/// The app side of whichever store this platform buys through.
///
/// A seam rather than calls into the SDK, for two reasons: tests have no
/// plugin behind them, and only one platform can buy anything yet. The phones
/// buy through their stores; the desktop builds ship outside any store, so
/// there is nothing on them to call.
abstract class PurchaseStore {
  /// Whether anything can be bought here at all.
  bool get isSupported;

  /// Ties every purchase from now on to this account, and hands over anything
  /// bought before there was one.
  Future<void> logIn(String userId);

  Future<void> logOut();

  /// What is for sale, with prices. Empty when the store will not say.
  ///
  /// [userId] is null when nobody is signed in, which is allowed: the store
  /// keeps the purchase under an id of its own until an account claims it.
  Future<List<StoreOffer>> offers({String? userId});

  Future<PurchaseOutcome> buy(Sku sku, {String? userId});

  /// Asks the store what this store account has already bought, and returns
  /// the skus it owns for good. Consumables are not restorable, so this is Pro
  /// or nothing.
  Future<Set<Sku>> restore({String? userId});

  /// Whether the store itself says Pro Lifetime was bought here.
  ///
  /// The one thing the SDK is believed about, and only while signed out: the
  /// note limit is the only part of Pro that works without an account, so it
  /// is the only part that can be unlocked without one. Everything else is the
  /// server's to grant, and once somebody signs in the server's answer decides
  /// this too.
  Future<bool> ownsProHere();
}

/// Everywhere there is no store to buy through.
class UnsupportedPurchaseStore implements PurchaseStore {
  const UnsupportedPurchaseStore();

  @override
  bool get isSupported => false;

  @override
  Future<void> logIn(String userId) async {}

  @override
  Future<void> logOut() async {}

  @override
  Future<List<StoreOffer>> offers({String? userId}) async => const [];

  @override
  Future<PurchaseOutcome> buy(Sku sku, {String? userId}) async =>
      const PurchaseFailed('Purchases are not available on this device.');

  @override
  Future<Set<Sku>> restore({String? userId}) async => const {};

  @override
  Future<bool> ownsProHere() async => false;
}
