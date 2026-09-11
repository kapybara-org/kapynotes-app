import 'package:kapy_notes/billing/billing_api.dart';
import 'package:kapy_notes/billing/entitlements.dart';
import 'package:kapy_notes/billing/purchase_store.dart';

Entitlements entitlementsFor({
  bool pro = false,
  int? storageBytes,
  int speechCreditSeconds = 0,
  bool sync = true,
}) => Entitlements(
  plan: pro ? 'pro' : 'free',
  storageBytes: storageBytes ?? (pro ? proStorageBytes : 100 * 1024 * 1024),
  storageUsedBytes: 0,
  speechSecondsPerMonth: pro ? 7200 : 900,
  speechCreditSeconds: speechCreditSeconds,
  sync: sync,
  sharing: sync,
);

/// The server's answer, scripted. Free until told otherwise.
class FakeBillingApi implements BillingApi {
  Entitlements Function() answer = entitlementsFor;
  final List<String> tokens = [];
  int calls = 0;

  @override
  Future<Entitlements> entitlements() async {
    calls++;
    return answer();
  }
}

/// A store that sells whatever it is told to, and writes down every call.
class FakePurchaseStore implements PurchaseStore {
  FakePurchaseStore({this.supported = true});

  bool supported;
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
  Future<List<StoreOffer>> offers({required String userId}) async {
    log.add('offers as $userId');
    return offerList;
  }

  @override
  Future<PurchaseOutcome> buy(Sku sku, {required String userId}) async {
    log.add('buy ${sku.id} as $userId');
    onBuy?.call();
    return next;
  }

  @override
  Future<Set<Sku>> restore({required String userId}) async {
    log.add('restore as $userId');
    return owned;
  }
}
