import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/billing/billing.dart';
import 'package:kapy_notes/billing/note_limit.dart';
import 'package:kapy_notes/billing/plan_terms.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/sync/account.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/sync/key_store.dart';
import 'package:kapy_notes/sync/sync_state.dart';

import '../sync/fake_server.dart';
import 'billing_fakes.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'note-limit-test.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
  @override
  void putNow(String key, Object? value) => data[key] = value;
}

class _TermsApi implements PlanTermsApi {
  bool enforced = false;
  @override
  Future<PlanTermsAnswer> fetch() async =>
      PlanTermsAnswer(enforced: enforced, trialDays: 14, freeNoteLimit: 5);
}

void main() {
  late _MemoryStore store;
  late NotesStore notes;
  late Account account;
  late FakeBillingApi billingApi;
  late _TermsApi termsApi;
  late PlanTerms terms;
  late NoteLimit limit;
  late DateTime clock;

  setUp(() async {
    clock = DateTime.utc(2026, 10, 1, 9);
    store = _MemoryStore();
    var tick = 0;
    // Each note a minute newer than the last, so the list's order is known.
    notes = NotesStore(
      store,
      now: () => DateTime.utc(2026, 9, 1).add(Duration(minutes: tick++)),
    );
    await notes.load();
    account = Account(
      auth: FakeAuth(),
      syncApi: (_) => FakeApi(FakeServer()),
      keys: KeyStore(InMemorySecureStore()),
      notes: notes,
      state: SyncState(store),
      store: store,
      docStorage: MemoryDocStorage(),
    );
    billingApi = FakeBillingApi();
    account.billing = Billing(
      session: account,
      userId: () => account.user?.id,
      token: () => account.token,
      api: (_) => billingApi,
      store: FakePurchaseStore(),
    );
    termsApi = _TermsApi();
    terms = PlanTerms(store: store, api: termsApi, now: () => clock);
    limit = NoteLimit(
      notes: notes,
      account: account,
      terms: terms,
      now: () => clock,
    );
  });

  tearDown(() {
    limit.dispose();
    account.dispose();
  });

  List<Note> write(int count) => [
    for (var i = 0; i < count; i++) notes.create(body: 'Note $i'),
  ];

  Future<void> signInOnFree() async {
    billingApi.answer = afterTrial;
    await account.restore();
    await account.signIn(email: 'a@b.co', password: 'x');
    await account.billing!.refresh();
  }

  test('while the account is still being read, nothing locks', () {
    write(8);
    expect(account.state, AccountState.restoring);
    expect(limit.limit, isNull);
    expect(limit.lockedIds, isEmpty);
    expect(limit.canCreate, isTrue);
  });

  test('before plans are enforced nothing is limited, signed in or out', () async {
    write(8);
    await account.restore();
    await Future<void>.delayed(Duration.zero);
    expect(account.state, AccountState.signedOut);
    expect(limit.limit, isNull);

    billingApi.answer = entitlementsFor;
    await account.signIn(email: 'a@b.co', password: 'x');
    await account.billing!.refresh();
    expect(limit.limit, isNull);
    expect(limit.canCreate, isTrue);
  });

  test('the five at the top of the list stay editable, pinned first', () async {
    final written = write(8); // written[7] is the most recent
    notes.togglePinned(written[0].id);
    await signInOnFree();

    expect(limit.limit, 5);
    expect(limit.count, 8);
    expect(limit.canCreate, isFalse);
    // The pinned note, then the four most recently edited.
    expect(limit.lockedIds, {written[1].id, written[2].id, written[3].id});
    expect(limit.isLocked(written[0]), isFalse);
    expect(limit.isLocked(written[7]), isFalse);
  });

  test('pinning is how somebody chooses which notes stay editable', () async {
    final written = write(6);
    await signInOnFree();
    expect(limit.lockedIds, {written[0].id});

    notes.togglePinned(written[0].id);
    expect(limit.lockedIds, {written[1].id});
  });

  test('archived notes count, and stay read-only while over', () async {
    final written = write(7);
    notes.archive(written[0].id);
    notes.archive(written[1].id);
    notes.archive(written[2].id);
    await signInOnFree();

    expect(limit.count, 7);
    expect(limit.canCreate, isFalse);
    // Four notes in the list, all editable; the archive is what is over.
    expect(limit.lockedIds, {written[0].id, written[1].id, written[2].id});
  });

  test('deleting makes room: first to edit, then to write', () async {
    final written = write(6);
    await signInOnFree();
    expect(limit.lockedIds, {written[0].id});

    notes.delete(written[5].id);
    expect(limit.lockedIds, isEmpty);
    expect(limit.canCreate, isFalse, reason: 'five is the limit, not under it');

    notes.delete(written[4].id);
    expect(limit.canCreate, isTrue);
  });

  test('a trial, or Pro, lifts it the moment the answer says so', () async {
    final written = write(7);
    await signInOnFree();
    expect(limit.lockedIds, hasLength(2));

    billingApi.answer = () => entitlementsFor(pro: true);
    await account.billing!.refresh();
    expect(limit.limit, isNull);
    expect(limit.isLocked(written[0]), isFalse);
    expect(limit.canCreate, isTrue);
  });

  test('signed out, the device keeps its own fortnight from the day it heard', () async {
    final written = write(6);
    termsApi.enforced = true;
    await account.restore();
    await Future<void>.delayed(Duration.zero);
    expect(account.state, AccountState.signedOut);
    expect(terms.enforced, isTrue);
    expect(limit.limit, isNull, reason: 'its own fourteen days have started');

    clock = clock.add(const Duration(days: 14, minutes: 1));
    notes.updateBody(written[5].id, 'Still writing'); // anything that asks
    expect(limit.limit, 5);
    expect(limit.lockedIds, {written[0].id});
  });

  test('an account that showed plans are enforced leaves the clock running', () async {
    write(6);
    await signInOnFree();
    expect(terms.deviceTrialEndsAt, isNotNull);
    expect(
      terms.deviceTrialEndsAt,
      clock.add(const Duration(days: 14)),
      reason: 'started when the account said so, so signing out later does '
          'not hand out a fresh fortnight',
    );
  });
}
