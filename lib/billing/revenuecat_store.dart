import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:purchases_flutter/purchases_flutter.dart' as rc;

import 'entitlements.dart';
import 'purchase_store.dart';

/// Buying through the App Store, by way of RevenueCat.
///
/// The only file that talks to the SDK. RevenueCat sees the store transaction
/// and forwards it to the server's webhook; the server, not this, decides what
/// it grants. So nothing here reads entitlements back out of the SDK — it only
/// ever asks the store to sell something, or what it has already sold.
///
/// Never configured anonymously. The SDK is set up the first time an account
/// needs it, with that account's id, because the webhook grants a purchase to
/// exactly the id RevenueCat reports and an anonymous one reaches nobody.
class RevenueCatStore implements PurchaseStore {
  RevenueCatStore({required String apiKey}) : _apiKey = apiKey;

  final String _apiKey;

  /// The account the SDK is identified as. Null before it has been set up,
  /// and again after a sign-out.
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

  Future<void> _identify(String userId) async {
    if (_identified == userId) return;
    if (!await rc.Purchases.isConfigured) {
      await rc.Purchases.setLogLevel(
        kDebugMode ? rc.LogLevel.debug : rc.LogLevel.warn,
      );
      await rc.Purchases.configure(
        rc.PurchasesConfiguration(_apiKey)..appUserID = userId,
      );
    } else {
      await rc.Purchases.logIn(userId);
    }
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
  Future<List<StoreOffer>> offers({required String userId}) =>
      _serial(() async {
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
  Future<PurchaseOutcome> buy(Sku sku, {required String userId}) =>
      _serial(() async {
        try {
          await _identify(userId);
          final products = await rc.Purchases.getProducts([
            sku.storeProductId,
          ], productCategory: rc.ProductCategory.nonSubscription);
          if (products.isEmpty) {
            return const PurchaseFailed(
              'The App Store does not have this for sale right now.',
            );
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
  Future<Set<Sku>> restore({required String userId}) => _serial(() async {
    await _identify(userId);
    final info = await rc.Purchases.restorePurchases();
    return {
      for (final id in info.allPurchasedProductIdentifiers)
        if (Sku.forStoreProduct(id) case final sku?
            when sku == Sku.proLifetime)
          sku,
    };
  });

  PurchaseOutcome _outcomeFor(PlatformException error) =>
      switch (rc.PurchasesErrorHelper.getErrorCode(error)) {
        rc.PurchasesErrorCode.purchaseCancelledError =>
          const PurchaseCancelled(),
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
        rc.PurchasesErrorCode.networkError => const PurchaseFailed(
          'Could not reach the App Store. Check your connection and try '
          'again.',
        ),
        rc.PurchasesErrorCode.productNotAvailableForPurchaseError =>
          const PurchaseFailed(
            'The App Store does not have this for sale right now.',
          ),
        rc.PurchasesErrorCode.receiptAlreadyInUseError ||
        rc.PurchasesErrorCode.receiptInUseByOtherSubscriberError =>
          const PurchaseFailed(
            'This Apple ID already bought this for a different Kapy Notes '
            'account.',
          ),
        _ => const PurchaseFailed(
          'The App Store could not finish that. Try again in a moment.',
        ),
      };
}
