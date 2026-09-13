import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/billing/billing_api.dart';
import 'package:kapy_notes/billing/entitlements.dart';
import 'package:kapy_notes/billing/plan_usage.dart';
import 'package:kapy_notes/data/attachment_limits.dart';
import 'package:kapy_notes/data/local_store.dart';

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

class _Store extends LocalStore {
  _Store() : super(fileName: 'plan-usage-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

Entitlements _answer({bool pro = false}) => Entitlements(
  plan: pro ? 'pro' : 'free',
  storageBytes: pro ? 1024 * 1024 * 1024 : 100 * 1024 * 1024,
  storageUsedBytes: 42,
  attachmentMaxBytes: pro ? proAttachmentMaxBytes : freeAttachmentMaxBytes,
  speechSecondsPerMonth: pro ? 7200 : 900,
  speechSecondsUsedThisMonth: 120,
  speechCreditSeconds: 60,
  summaryGenerationsPerMonth: pro ? 1000 : 100,
  summaryGenerationsUsedThisMonth: 7,
  speechResetsAt: DateTime.utc(2026, 10),
  sync: true,
  sharing: true,
);

class _Api implements BillingApi {
  Entitlements Function() answer = _answer;
  int calls = 0;

  @override
  Future<Entitlements> entitlements() async {
    calls++;
    return answer();
  }

  @override
  Future<AdoptedPurchases> adopt() async => AdoptedPurchases(
    claimed: const [],
    heldByAnother: false,
    entitlements: answer(),
  );

  @override
  Future<Uri> webCheckout() async => Uri.parse('https://kapynotes.com/buy');
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 5));

void main() {
  late _Session session;
  late _Store cache;
  late _Api api;
  late PlanUsage usage;
  late List<String> tokens;

  setUp(() {
    session = _Session();
    cache = _Store();
    api = _Api();
    tokens = [];
    usage = PlanUsage(
      session: session,
      userId: () => session.userId,
      token: () => session.token,
      api: (token) {
        tokens.add(token);
        return api;
      },
      cache: cache,
    );
  });

  tearDown(() => usage.dispose());

  test('an older server answer gets the published AI limit during rollout', () {
    final parsed = Entitlements.fromJson({
      'plan': 'pro',
      'storageBytes': 1073741824,
      'storageUsedBytes': 0,
      'speechSecondsPerMonth': 7200,
      'speechSecondsUsedThisMonth': 0,
      'speechCreditSeconds': 0,
      'speechResetsAt': '2026-10-01T00:00:00.000Z',
      'sync': true,
      'sharing': true,
    });

    expect(parsed.summaryGenerationsPerMonth, 1000);
    expect(parsed.summaryGenerationsUsedThisMonth, 0);
    expect(parsed.attachmentMaxBytes, freeAttachmentMaxBytes);
  });

  test('keeps the server-provided Pro attachment ceiling in the cache', () {
    final parsed = Entitlements.fromJson({
      'plan': 'pro',
      'attachmentMaxBytes': proAttachmentMaxBytes,
    });

    expect(parsed.attachmentMaxBytes, proAttachmentMaxBytes);
    expect(parsed.toJson()['attachmentMaxBytes'], proAttachmentMaxBytes);
  });

  test('signing in reads every server usage total', () async {
    api.answer = () => _answer(pro: true);
    session.signIn('user-1');
    await _settle();

    expect(tokens, ['token-user-1']);
    expect(usage.entitlements?.isPro, isTrue);
    expect(usage.entitlements?.speechSecondsUsedThisMonth, 120);
    expect(usage.entitlements?.summaryGenerationsUsedThisMonth, 7);
    expect(usage.entitlements?.storageUsedBytes, 42);
  });

  test('a cached plan appears immediately, only for its account', () async {
    cache.data['plan-usage.v1'] = {
      'userId': 'user-1',
      'entitlements': _answer(pro: true).toJson(),
    };
    api.answer = () => throw Exception('offline');

    session.signIn('user-1');
    expect(usage.entitlements?.isPro, isTrue);
    await _settle();
    expect(usage.refreshFailed, isTrue);
    expect(usage.entitlements?.isPro, isTrue);

    session.signIn('user-2');
    expect(usage.entitlements, isNull);
  });

  test('signing out hides usage without deleting the account cache', () async {
    session.signIn('user-1');
    await _settle();
    expect(cache.data['plan-usage.v1'], isNotNull);

    session.signOut();
    expect(usage.entitlements, isNull);
    expect(cache.data['plan-usage.v1'], isNotNull);
  });
}
