/// What the server says this account may do.
///
/// The server is the only authority on it, and the app never works it out for
/// itself: storage and transcription are enforced there on the way in, and a
/// purchase made anywhere but this device would be invisible to anything the
/// store SDK here could say. So this is parsed, cached and rendered — never
/// computed.
class Entitlements {
  const Entitlements({
    required this.plan,
    required this.storageBytes,
    required this.storageUsedBytes,
    required this.speechSecondsPerMonth,
    required this.speechCreditSeconds,
    required this.sync,
    required this.sharing,
  });

  /// `free` or `pro`. Anything else a newer server invents reads as free,
  /// which is the answer that never unlocks something by mistake.
  final String plan;

  /// The plan's storage plus every pack bought, already summed.
  final int storageBytes;
  final int storageUsedBytes;
  final int speechSecondsPerMonth;

  /// Bought minutes, spent only once a month's allowance is gone.
  final int speechCreditSeconds;

  /// Sent rather than derived from [plan]: until plans are enforced every
  /// account may sync and share, whatever it paid.
  final bool sync;
  final bool sharing;

  bool get isPro => plan == 'pro';

  static Entitlements fromJson(Map<String, Object?> raw) {
    int count(String key) => switch (raw[key]) {
      final int value when value >= 0 => value,
      final double value when value >= 0 => value.round(),
      _ => 0,
    };
    return Entitlements(
      plan: raw['plan'] == 'pro' ? 'pro' : 'free',
      storageBytes: count('storageBytes'),
      storageUsedBytes: count('storageUsedBytes'),
      speechSecondsPerMonth: count('speechSecondsPerMonth'),
      speechCreditSeconds: count('speechCreditSeconds'),
      sync: raw['sync'] == true,
      sharing: raw['sharing'] == true,
    );
  }

  Map<String, Object?> toJson() => {
    'plan': plan,
    'storageBytes': storageBytes,
    'storageUsedBytes': storageUsedBytes,
    'speechSecondsPerMonth': speechSecondsPerMonth,
    'speechCreditSeconds': speechCreditSeconds,
    'sync': sync,
    'sharing': sharing,
  };
}

/// The three things that can be bought, by the server's name for them.
///
/// Mirrors `PRODUCTS` in the contract. The server maps store ids onto these
/// same names, so a purchase and the entitlement it turns into are spoken of
/// the same way at both ends.
enum Sku {
  proLifetime('pro_lifetime', 'com.kapybara.kapynotes.pro_lifetime'),
  storage5gb('storage_5gb', 'com.kapybara.kapynotes.storage_5gb'),
  voice1000('voice_1000', 'com.kapybara.kapynotes.voice_1000');

  const Sku(this.id, this.storeProductId);

  final String id;

  /// The product id in App Store Connect. The contract's
  /// `STORE_PRODUCT_SKUS` maps exactly these back to [id]; a store id the
  /// server does not know is recorded and never granted.
  final String storeProductId;

  static Sku? forStoreProduct(String productId) {
    for (final sku in values) {
      if (sku.storeProductId == productId) return sku;
    }
    return null;
  }
}

/// What Pro gives on its own, before any pack. From the contract's
/// `PLAN_ENTITLEMENTS`; used only to tell bought storage from the plan's.
const int proStorageBytes = 1024 * 1024 * 1024;

/// One storage pack. From the contract's `PRODUCTS`.
const int storagePackBytes = 5 * 1024 * 1024 * 1024;

/// The most packs may add, from the contract's `MAX_BONUS_STORAGE_BYTES`.
///
/// The server clamps anything past it rather than refusing, because by then
/// the money is taken — so the buy button is where it has to stop.
const int maxBonusStorageBytes = 100 * 1024 * 1024 * 1024;
