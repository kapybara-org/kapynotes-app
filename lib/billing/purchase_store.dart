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

  /// Ties every purchase from now on to this account.
  ///
  /// Called before a purchase can be offered, and only ever with the account's
  /// own id: the server grants a purchase to exactly the account RevenueCat
  /// reports, and an anonymous one reaches nobody.
  Future<void> logIn(String userId);

  Future<void> logOut();

  /// What is for sale, with prices. Empty when the store will not say.
  Future<List<StoreOffer>> offers({required String userId});

  Future<PurchaseOutcome> buy(Sku sku, {required String userId});

  /// Asks the store what this store account has already bought, and returns
  /// the skus it owns for good. Consumables are not restorable, so this is Pro
  /// or nothing.
  Future<Set<Sku>> restore({required String userId});
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
  Future<List<StoreOffer>> offers({required String userId}) async => const [];

  @override
  Future<PurchaseOutcome> buy(Sku sku, {required String userId}) async =>
      const PurchaseFailed('Purchases are not available on this device.');

  @override
  Future<Set<Sku>> restore({required String userId}) async => const {};
}
