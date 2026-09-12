import 'package:kapy_notes/billing/billing_api.dart';
import 'package:kapy_notes/billing/entitlements.dart';
import 'package:kapy_notes/billing/purchase_store.dart';

Entitlements entitlementsFor({
  bool pro = false,
  int? storageBytes,
  int speechCreditSeconds = 0,
  bool sync = true,
  int? noteLimit,
  DateTime? trialEndsAt,
}) => Entitlements(
  plan: pro ? 'pro' : 'free',
  storageBytes: storageBytes ?? (pro ? proStorageBytes : 100 * 1024 * 1024),
  storageUsedBytes: 0,
  speechSecondsPerMonth: pro ? 7200 : 900,
  speechCreditSeconds: speechCreditSeconds,
  sync: sync,
  sharing: sync,
  noteLimit: noteLimit,
  trialEndsAt: trialEndsAt,
);

/// A free account trying Pro, [left] from now.
Entitlements trialFor(Duration left, {DateTime? from}) =>
    entitlementsFor(trialEndsAt: (from ?? DateTime.now()).add(left));

/// A free account whose trial ended: no sync, and the note limit.
Entitlements afterTrial({DateTime? endedAt}) => entitlementsFor(
  sync: false,
  noteLimit: 5,
  trialEndsAt: endedAt ?? DateTime.now().subtract(const Duration(days: 1)),
);

/// The server's answer, scripted. Free until told otherwise.
class FakeBillingApi implements BillingApi {
  Entitlements Function() answer = entitlementsFor;
  final List<String> tokens = [];
  int calls = 0;

  /// What claiming an earlier purchase answers. Nothing to claim by default,
  /// which is what a purchase made after signing in looks like.
  List<String> claimed = const [];
  bool heldByAnother = false;
  int adoptCalls = 0;

  /// Set to fail adopting, as an old server or a missing key would.
  Object? adoptFailure;

  Uri checkoutUrl = Uri.parse('https://pay.rev.cat/pro-link/user-1');
  Object? checkoutFailure;
  int checkoutCalls = 0;

  @override
  Future<Entitlements> entitlements() async {
    calls++;
    return answer();
  }

  @override
  Future<AdoptedPurchases> adopt() async {
    adoptCalls++;
    final failure = adoptFailure;
    if (failure != null) throw failure;
    return AdoptedPurchases(
      claimed: claimed,
      heldByAnother: heldByAnother,
      entitlements: answer(),
    );
  }

  @override
  Future<Uri> webCheckout() async {
    checkoutCalls++;
    final failure = checkoutFailure;
    if (failure != null) throw failure;
    return checkoutUrl;
  }
}

/// A store that sells whatever it is told to, and writes down every call.
class FakePurchaseStore implements PurchaseStore {
  FakePurchaseStore({this.supported = true});

  bool supported;

  /// What the store itself says was bought on this device, for the stretch
  /// with no account to ask about instead.
  bool ownsPro = false;
  int ownsProCalls = 0;
  final List<String> log = [];
  PurchaseOutcome next = const PurchaseCompleted();
  Set<Sku> owned = {};
  void Function()? onBuy;
  List<StoreOffer> offerList = const [
    StoreOffer(sku: Sku.proLifetime, price: r'$24.00'),
    StoreOffer(sku: Sku.storage5gb, price: r'$10.00'),
    StoreOffer(sku: Sku.voice1000, price: r'$10.00'),
  ];

  @override
  bool get isSupported => supported;

  @override
  Future<void> logIn(String userId) async => log.add('logIn $userId');

  @override
  Future<void> logOut() async => log.add('logOut');

  @override
  Future<List<StoreOffer>> offers({String? userId}) async {
    log.add('offers as ${userId ?? 'nobody'}');
    return offerList;
  }

  @override
  Future<PurchaseOutcome> buy(Sku sku, {String? userId}) async {
    log.add('buy ${sku.id} as ${userId ?? 'nobody'}');
    onBuy?.call();
    if (next is PurchaseCompleted && sku == Sku.proLifetime) ownsPro = true;
    return next;
  }

  @override
  Future<Set<Sku>> restore({String? userId}) async {
    log.add('restore as ${userId ?? 'nobody'}');
    if (owned.contains(Sku.proLifetime)) ownsPro = true;
    return owned;
  }

  @override
  Future<bool> ownsProHere() async {
    ownsProCalls++;
    log.add('ownsProHere');
    return ownsPro;
  }
}
