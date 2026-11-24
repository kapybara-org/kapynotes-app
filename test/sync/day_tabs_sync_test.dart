import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/day_tabs.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/tags.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/account.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/sync/key_store.dart';
import 'package:kapy_notes/sync/sync_api.dart';
import 'package:kapy_notes/sync/sync_state.dart';

import 'fake_server.dart';
import 'record_device.dart';

/// One device signed in through [Account], for the first run of this build
/// and for signing out.
class AccountDevice {
  AccountDevice(this.server, {MemoryStore? store})
    : store = store ?? MemoryStore() {
    notes = NotesStore(this.store);
    tags = TagStore(this.store);
    dayTabs = DayTabsStore(this.store);
    final state = SyncState(this.store);
    tasks = TaskLibrary(
      notes: notes,
      store: this.store,
      state: state,
      storage: MemoryDocStorage(),
    );
    account = Account(
      auth: auth,
      syncApi: (_) => FakeApi(server, userId: auth.id),
      keys: KeyStore(InMemorySecureStore()),
      notes: notes,
      state: state,
      store: this.store,
      tasks: tasks,
      tags: tags,
      dayTabs: dayTabs,
    );
  }

  final FakeServer server;
  final MemoryStore store;
  final auth = FakeAuth(id: 'user-1');
  late final NotesStore notes;
  late final TaskLibrary tasks;
  late final TagStore tags;
  late final DayTabsStore dayTabs;
  late final Account account;

  Future<void> boot() async {
    await notes.load();
    await account.restore();
  }

  void dispose() => account.dispose();
}

void main() {
  late FakeServer server;

  setUp(() => server = FakeServer());

  Map<String, ({WireTaskRecord record, int seq})> stored() =>
      server.tasks['user-1'] ?? {};

  String tabsRecordOf(String day) => sharedVault().dayTabsRecordId(day);

  final tue = DateTime(2026, 11, 18);

  Future<(Device, Device)> pair() async {
    final laptop = Device(server, name: 'laptop');
    final phone = Device(server, name: 'phone');
    await laptop.boot();
    await phone.boot();
    return (laptop, phone);
  }

  Future<void> passes(List<Device> devices) async {
    for (final d in devices) {
      await d.pass();
    }
  }

  /// Three notes on Tue 18 on [d], earliest first.
  List<String> three(Device d) => [
    for (final title in ['Standup notes', 'Lunch with Maya', 'Q4 budget'])
      d.notes.create(body: title).id,
  ];

  test('an order and its pins reach another device, under an id that names '
      'no day', () async {
    final (a, b) = await pair();
    final notes = three(a);
    await passes([a, b]);

    expect(a.dayTabs.pin(tue, notes, notes[2]), isTrue);
    expect(a.dayTabs.move(tue, notes, notes[0], 2), isTrue);
    await passes([a, b]);
    final record = tabsRecordOf('2026-11-18');
    expect(record, isNot(contains('2026')));
    expect(stored().keys, contains(record));
    expect(stored()[record]!.record.deletedAt, isNull);
    final shown = b.dayTabs.arrange(tue, notes);
    expect(shown.order, [notes[2], notes[1], notes[0]]);
    expect(shown.pinned, 1);
    expect(a.dayTabs.owed, isEmpty);
    expect(b.dayTabs.owed, isEmpty);
    a.dispose();
    b.dispose();
  });

  test('a day put back in its own order goes back on every device', () async {
    final (a, b) = await pair();
    final notes = three(a);
    a.dayTabs.move(tue, notes, notes[2], 0);
    await passes([a, b]);
    expect(b.dayTabs.arrange(tue, notes).order.first, notes[2]);

    b.dayTabs.move(tue, notes, notes[2], 2);
    await passes([b, a]);
    expect(stored()[tabsRecordOf('2026-11-18')]!.record.deletedAt, isNotNull);
    expect(a.dayTabs.arrange(tue, notes).order, notes);
    expect(a.dayTabs.owed, isEmpty);
    expect(b.dayTabs.owed, isEmpty);
    a.dispose();
    b.dispose();
  });

  test(
    'a pin on one device and a drag on another leave the later whole',
    () async {
      final (a, b) = await pair();
      final notes = three(a);
      await passes([a, b]);

      a.dayTabs.pin(tue, notes, notes[1]);
      b.clock = a.clock.add(const Duration(seconds: 1));
      b.dayTabs.move(tue, notes, notes[2], 0);
      await passes([a, b, a]);
      for (final d in [a, b]) {
        final shown = d.dayTabs.arrange(tue, notes);
        expect(shown.order, [notes[2], notes[0], notes[1]], reason: d.name);
        expect(shown.pinned, 0, reason: d.name);
      }
      a.dispose();
      b.dispose();
    },
  );

  test(
    "a day's order moved onto another day's id is not taken for it",
    () async {
      final (laptop, phone) = await pair();
      final notes = three(laptop);
      laptop.dayTabs.move(tue, notes, notes[2], 0);
      await passes([laptop, phone]);
      final stale = stored()[tabsRecordOf('2026-11-18')]!.record;

      laptop.dayTabs.move(tue, notes, notes[2], 2);
      await passes([laptop, phone]);
      expect(stored()[tabsRecordOf('2026-11-18')]!.record.deletedAt, isNotNull);
      expect(phone.dayTabs.arrange(tue, notes).order, notes);

      server.pushTasks('user-1', 'mallory', [
        WireTaskRecord(
          id: tabsRecordOf('2026-11-17'),
          updatedAt: stale.updatedAt,
          payload: stale.payload,
        ),
      ]);
      await phone.pass();
      expect(
        phone.dayTabs.arrange(tue, notes).order,
        notes,
        reason: "the 18th's old order, under the 17th's id",
      );
      laptop.dispose();
      phone.dispose();
    },
  );

  test(
    'a device relaunched after an order came down still takes its delete',
    () async {
      final (laptop, phone) = await pair();
      final notes = three(laptop);
      laptop.dayTabs.move(tue, notes, notes[2], 0);
      await passes([laptop, phone]);
      expect(phone.dayTabs.arrange(tue, notes).order.first, notes[2]);
      phone.dispose();

      final relaunched = Device(server, name: 'phone', resume: phone.store);
      await relaunched.boot();
      laptop.dayTabs.move(tue, notes, notes[2], 2);
      await passes([laptop, relaunched]);
      expect(relaunched.dayTabs.arrange(tue, notes).order, notes);
      laptop.dispose();
      relaunched.dispose();
    },
  );

  test(
    'a build from before day tabs keeps the record and never writes one',
    () async {
      final newer = Device(server, name: 'laptop');
      final older = Device(server, name: 'phone', withDayTabs: false);
      await newer.boot();
      await older.boot();
      final notes = three(newer);
      newer.dayTabs.pin(tue, notes, notes[2]);
      await passes([newer, older]);
      final record = tabsRecordOf('2026-11-18');
      final before = (
        stored()[record]!.seq,
        stored()[record]!.record.updatedAt,
      );
      expect(
        (older.store.data['tags.v1'] as Map)['unknown'] as List,
        contains(predicate((entry) => (entry as Map)['id'] == record)),
        reason: 'kept by id and time alone',
      );

      older.notes.updateBody(notes[0], 'Standup notes, moved');
      newer.notes.updateBody(notes[1], 'Lunch with Maya on the 30th');
      server.taskPushes.clear();
      await passes([older, newer, older]);

      expect((
        stored()[record]!.seq,
        stored()[record]!.record.updatedAt,
      ), before);
      expect(
        server.taskPushes.expand((ids) => ids),
        isNot(contains(record)),
        reason: 'a build from before day tabs never writes one',
      );
      expect(newer.dayTabs.arrange(tue, notes).order.first, notes[2]);
      expect(older.dayTabs.days, isEmpty);
      newer.dispose();
      older.dispose();
    },
  );
  group('signed in through Account', () {
    final day = DateTime(2026, 11, 18);
    Future<AccountDevice> signedIn({
      MemoryStore? store,
      bool fresh = true,
    }) async {
      final d = AccountDevice(server, store: store);
      await d.boot();
      await d.account.signIn(email: 'a@b.co', password: 'x');
      if (fresh) {
        await d.account.createPassphrase('a good passphrase');
      } else {
        expect(await d.account.unlock('a good passphrase'), isTrue);
      }
      return d;
    }

    test('the first run of a day tabs build reads the stream again once, and '
        'every order arrives', () async {
      final first = await signedIn();
      final notes = [
        for (final title in ['Standup notes', 'Lunch with Maya', 'Q4 budget'])
          first.notes.create(body: title).id,
      ];
      first.dayTabs.pin(day, notes, notes[2]);
      await first.account.sync!.syncNow();
      await until(
        () => first.dayTabs.owed.isEmpty && stored().length == 1,
        reason: 'the first device never sent its order',
      );
      final seq = stored().values.map((r) => r.seq).reduce(max);
      first.dispose();

      // A device on a build from before day tabs, which read past the
      // order and kept its id alone.
      final store = MemoryStore();
      store.data['tasks.v1'] = {
        'cursor': seq,
        'scanned': true,
        'entries': <Object?>[],
        'stones': <String, Object?>{},
      };
      store.data['tags.v1'] = {
        'tags': <Object?>[],
        'notes': <Object?>[],
        'unknown': [
          for (final MapEntry(:key, :value) in stored().entries)
            {
              'id': key,
              'updatedAt': value.record.updatedAt.millisecondsSinceEpoch,
            },
        ],
      };
      final second = await signedIn(store: store, fresh: false);
      await until(
        () => second.dayTabs.arrange(day, notes).pinned == 1,
        reason: 'the order never came down',
      );
      expect(second.dayTabs.arrange(day, notes).order.first, notes[2]);
      expect(second.tasks.index.cursor, seq);
      second.dispose();

      final relaunched = AccountDevice(server, store: store);
      await relaunched.boot();
      expect(relaunched.dayTabs.arrange(day, notes).pinned, 1);
      expect(
        relaunched.tasks.index.cursor,
        seq,
        reason: 'once, not every launch',
      );
      relaunched.dispose();
    });

    test('signing out keeps the orders, owed to the next account', () async {
      final d = await signedIn();
      final notes = [
        for (final title in ['Standup notes', 'Lunch with Maya'])
          d.notes.create(body: title).id,
      ];
      d.dayTabs.pin(day, notes, notes[1]);
      await d.account.sync!.syncNow();
      await until(() => d.dayTabs.owed.isEmpty);

      await d.account.signOut();
      expect(d.dayTabs.arrange(day, notes).order, [notes[1], notes[0]]);
      expect(d.dayTabs.owed.map((r) => r.key), ['2026-11-18']);
      d.dispose();
    });
  });
}
