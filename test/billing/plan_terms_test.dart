import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/billing/plan_terms.dart';
import 'package:kapy_notes/data/local_store.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'plan-terms-test.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
}

class _FakeTermsApi implements PlanTermsApi {
  bool enforced = false;
  bool fail = false;
  int calls = 0;

  @override
  Future<PlanTermsAnswer> fetch() async {
    calls++;
    if (fail) throw Exception('offline');
    return PlanTermsAnswer(enforced: enforced, trialDays: 14, freeNoteLimit: 5);
  }
}

void main() {
  late _MemoryStore store;
  late _FakeTermsApi api;
  late DateTime clock;

  PlanTerms build() => PlanTerms(store: store, api: api, now: () => clock);

  setUp(() {
    store = _MemoryStore();
    api = _FakeTermsApi();
    clock = DateTime.utc(2026, 10, 1, 9);
  });

  test('before launch nothing applies, however long the app has been here', () async {
    final terms = build();
    await terms.refreshIfStale();
    clock = clock.add(const Duration(days: 90));
    expect(terms.enforced, isFalse);
    expect(terms.deviceTrialEndsAt, isNull);
    expect(terms.limitApplies, isFalse);
  });

  test('the fortnight starts when this device hears plans are enforced', () async {
    final terms = build();
    await terms.refreshIfStale();
    clock = clock.add(const Duration(days: 40));
    api.enforced = true;
    await terms.refreshIfStale();
    final heard = clock;

    expect(terms.deviceTrialEndsAt, heard.add(const Duration(days: 14)));
    expect(terms.limitApplies, isFalse);
    clock = heard.add(const Duration(days: 14));
    expect(terms.limitApplies, isTrue);
  });

  test('it asks about once a day, and never twice at once', () async {
    final terms = build();
    await Future.wait([terms.refreshIfStale(), terms.refreshIfStale()]);
    await terms.refreshIfStale();
    expect(api.calls, 1);

    clock = clock.add(const Duration(hours: 25));
    await terms.refreshIfStale();
    expect(api.calls, 2);
  });

  test('a failed check keeps what was known, and tries again next time', () async {
    api.enforced = true;
    final terms = build();
    await terms.refreshIfStale();
    final ends = terms.deviceTrialEndsAt;

    api.fail = true;
    clock = clock.add(const Duration(days: 2));
    await terms.refreshIfStale();
    expect(terms.enforced, isTrue);
    expect(terms.deviceTrialEndsAt, ends);
    await terms.refreshIfStale();
    expect(api.calls, 3, reason: 'a failure is not a check');
  });

  test('an account showing plans are enforced starts the clock once', () {
    final terms = build();
    terms.noteEnforced();
    final first = terms.deviceTrialEndsAt;
    clock = clock.add(const Duration(days: 5));
    terms.noteEnforced();
    expect(terms.deviceTrialEndsAt, first, reason: 'never restarted');
  });

  test('what was learned survives a relaunch', () async {
    api.enforced = true;
    await build().refreshIfStale();
    final again = build()..loadCache();
    expect(again.enforced, isTrue);
    // Read back in local time; the same instant is what matters.
    expect(
      again.deviceTrialEndsAt!.isAtSameMomentAs(
        clock.add(const Duration(days: 14)),
      ),
      isTrue,
    );
    await again.refreshIfStale();
    expect(api.calls, 1, reason: 'checked today already');
  });
}
