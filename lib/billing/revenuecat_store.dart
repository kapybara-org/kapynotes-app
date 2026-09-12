import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:purchases_flutter/purchases_flutter.dart' as rc;

import 'entitlements.dart';
import 'purchase_store.dart';

/// Buying through the phone's own store, by way of RevenueCat.
///
/// The only file that talks to the SDK. RevenueCat sees the store transaction
/// and forwards it to the server's webhook; the server, not this, decides what
/// it grants.
///
/// Signed out there is no account for it to grant to, so the SDK is configured
/// anonymously and the purchase waits under an id of RevenueCat's own.
/// [logIn] hands it to the account, and the server claims it from RevenueCat
/// (`/billing/adopt`) rather than taking this side's word for it. The one
/// thing this side is believed about is [ownsProHere], for the one part of Pro
/// that works with no account at all.
class RevenueCatStore implements PurchaseStore {
  RevenueCatStore({required String apiKey}) : _apiKey = apiKey;

  final String _apiKey;

  /// The account the SDK is identified as, or null for the anonymous id it
  /// keeps for somebody who has not signed in.
  String? _identified;

  /// Calls run one at a time. A sign-in arriving while a purchase sheet is up
  /// would otherwise switch the SDK's user out from under the purchase.
  Future<void> _queue = Future.value();

  @override
  bool get isSupported => _apiKey.isNotEmpty;

  Future<T> _serial<T>(Future<T> Function() body) {
    final previous = _queue;
    final done = Completer<void>();
    _queue = done.future;
    return previous.then((_) => body()).whenComplete(done.complete);
  }

  /// Sets the SDK up if it is not already, as [userId] or as nobody.
  ///
  /// Identifying an already-anonymous SDK is what hands an anonymous purchase
  /// to the account: RevenueCat aliases the two, and the account owns what was
  /// bought before it existed.
  Future<void> _identify(String? userId) async {
    if (!await rc.Purchases.isConfigured) {
      await rc.Purchases.setLogLevel(
        kDebugMode ? rc.LogLevel.debug : rc.LogLevel.warn,
      );
      await rc.Purchases.configure(
        rc.PurchasesConfiguration(_apiKey)..appUserID = userId,
      );
      _identified = userId;
      return;
    }
    // Nothing identifies as nobody: going back to anonymous is a sign-out,
    // which is its own call.
    if (userId == null || userId == _identified) return;
    await rc.Purchases.logIn(userId);
    _identified = userId;
  }

  @override
  Future<void> logIn(String userId) => _serial(() => _identify(userId));

  @override
  Future<void> logOut() => _serial(() async {
    if (_identified == null) return;
    _identified = null;
    try {
      await rc.Purchases.logOut();
    } on PlatformException {
      // Already anonymous, or offline. Either way nothing is left pointing at
      // the account that signed out, which is all this was for.
    }
  });

  @override
  Future<List<StoreOffer>> offers({String? userId}) => _serial(() async {
    await _identify(userId);
    final products = await rc.Purchases.getProducts([
      for (final sku in Sku.values) sku.storeProductId,
    ], productCategory: rc.ProductCategory.nonSubscription);
    return [
      for (final product in products)
        if (Sku.forStoreProduct(product.identifier) case final sku?)
          StoreOffer(sku: sku, price: product.priceString),
    ];
  });

  @override
  Future<PurchaseOutcome> buy(Sku sku, {String? userId}) => _serial(() async {
    try {
      await _identify(userId);
      final products = await rc.Purchases.getProducts([
        sku.storeProductId,
      ], productCategory: rc.ProductCategory.nonSubscription);
      if (products.isEmpty) {
        return PurchaseFailed('This is not for sale on $storeName right now.');
      }
      await rc.Purchases.purchase(
        rc.PurchaseParams.storeProduct(products.first),
      );
      return const PurchaseCompleted();
    } on PlatformException catch (error) {
      return _outcomeFor(error);
    }
  });

  @override
  Future<Set<Sku>> restore({String? userId}) => _serial(() async {
    await _identify(userId);
    final info = await rc.Purchases.restorePurchases();
    return {
      for (final id in info.allPurchasedProductIdentifiers)
        if (Sku.forStoreProduct(id) case final sku? when sku == Sku.proLifetime)
          sku,
    };
  });

  @override
  Future<bool> ownsProHere() => _serial(() async {
    try {
      // Sets the SDK up anonymously if nothing has yet. Billing only asks
      // when this device already believes it bought something, so a device
      // that never did is never introduced to RevenueCat.
      await _identify(null);
      final info = await rc.Purchases.getCustomerInfo();
      return info.allPurchasedProductIdentifiers.contains(
        Sku.proLifetime.storeProductId,
      );
    } on PlatformException catch (error) {
      debugPrint('KapyNotes: could not read the store: $error');
      return false;
    }
  });

  PurchaseOutcome _outcomeFor(
    PlatformException error,
  ) => switch (rc.PurchasesErrorHelper.getErrorCode(error)) {
    rc.PurchasesErrorCode.purchaseCancelledError => const PurchaseCancelled(),
    rc.PurchasesErrorCode.paymentPendingError => const PurchasePending(),
    // The store will not sell a non-consumable twice. Whether the account
    // has heard about the first one yet is the server's to say, so this is
    // treated as done and confirmed there like any other purchase.
    rc.PurchasesErrorCode.productAlreadyPurchasedError =>
      const PurchaseCompleted(),
    rc.PurchasesErrorCode.purchaseNotAllowedError => const PurchaseFailed(
      'This device is not allowed to make purchases. Screen Time or a '
      'work profile may be blocking them.',
    ),
    rc.PurchasesErrorCode.networkError => PurchaseFailed(
      'Could not reach $storeName. Check your connection and try again.',
    ),
    rc.PurchasesErrorCode.productNotAvailableForPurchaseError => PurchaseFailed(
      'This is not for sale on $storeName right now.',
    ),
    rc.PurchasesErrorCode.receiptAlreadyInUseError ||
    rc.PurchasesErrorCode.receiptInUseByOtherSubscriberError => PurchaseFailed(
      'This $storeAccountName already bought this for a different Kapy '
      'Notes account.',
    ),
    _ => PurchaseFailed(
      'Something went wrong at $storeName. Try again in a moment.',
    ),
  };
}
