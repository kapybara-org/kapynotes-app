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
    this.noteLimit,
    this.trialEndsAt,
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

  /// How many notes may be kept editable, or null for no limit. Past it the
  /// rest turn read-only; see `NoteLimit` for which.
  ///
  /// Sent for the same reason [sync] is: it is null for everybody until plans
  /// are enforced and for as long as Pro, or a trial of it, lasts. A server
  /// that predates it sends nothing, which reads as no limit.
  final int? noteLimit;

  /// When this account's Pro trial ends, or ended. Null where there is no
  /// trial to speak of: the account owns Pro, or plans are not enforced yet.
  ///
  /// While it is ahead, everything above already describes Pro. Once it has
  /// passed, this answer is stale — every field changes at that moment — and
  /// has to be asked for again rather than read.
  final DateTime? trialEndsAt;

  bool get isPro => plan == 'pro';

  /// Trying Pro rather than owning it.
  bool trialRunningAt(DateTime now) =>
      !isPro && (trialEndsAt?.isAfter(now) ?? false);

  static Entitlements fromJson(Map<String, Object?> raw) {
    int count(String key) => switch (raw[key]) {
      final int value when value >= 0 => value,
      final double value when value >= 0 => value.round(),
      _ => 0,
    };
    final limit = raw['noteLimit'];
    final trial = raw['trialEndsAt'];
    return Entitlements(
      plan: raw['plan'] == 'pro' ? 'pro' : 'free',
      storageBytes: count('storageBytes'),
      storageUsedBytes: count('storageUsedBytes'),
      speechSecondsPerMonth: count('speechSecondsPerMonth'),
      speechCreditSeconds: count('speechCreditSeconds'),
      sync: raw['sync'] == true,
      sharing: raw['sharing'] == true,
      noteLimit: limit is int && limit > 0 ? limit : null,
      trialEndsAt: trial is String ? DateTime.tryParse(trial) : null,
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
    'noteLimit': noteLimit,
    'trialEndsAt': trialEndsAt?.toUtc().toIso8601String(),
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
