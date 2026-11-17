import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/ai/kapy_ai_controller.dart';
import 'package:kapy_notes/ai/kapy_ai_store.dart';
import 'package:kapy_notes/ai/kapy_chat_records.dart';
import 'package:kapy_notes/ai/kapy_chat_book.dart';
import 'package:kapy_notes/billing/billing.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/tags.dart';
import 'package:kapy_notes/data/task_index.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/account.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/sync/key_store.dart';
import 'package:kapy_notes/sync/sync_api.dart';
import 'package:kapy_notes/sync/sync_state.dart';
import '../ai/ai_fakes.dart' hide MemoryStore, settle;
import '../billing/billing_fakes.dart';

import 'fake_server.dart';
import 'record_device.dart';

const _cloud = KapyModel.cloud;
const _gemma = KapyModel(
  kind: KapyModelKind.device,
  id: 'gemma',
  label: 'Gemma',
);

/// One device signed in through [Account], whose plan decides whether its
/// chats sync.
class _AccountDevice {
  _AccountDevice(this.server) {
    notes = NotesStore(store);
    tags = TagStore(store);
    chats = KapyChatBook(store);
    final state = SyncState(store);
    final auth = FakeAuth(id: 'user-1');
    account = Account(
      auth: auth,
      syncApi: (_) => FakeApi(server, userId: auth.id),
      keys: KeyStore(InMemorySecureStore()),
      notes: notes,
      state: state,
      store: store,
      tasks: TaskLibrary(
        notes: notes,
        store: store,
        state: state,
        storage: MemoryDocStorage(),
      ),
      tags: tags,
      chats: chats,
    );
    account.billing = billing = Billing(
      session: account,
      userId: () => account.user?.id,
      token: () => account.token,
      api: (_) => plan,
      store: FakePurchaseStore(supported: false),
    );
  }

  final FakeServer server;
  final MemoryStore store = MemoryStore();
  final FakeBillingApi plan = FakeBillingApi();
  late final NotesStore notes;
  late final TagStore tags;
  late final KapyChatBook chats;
  late final Account account;
  late final Billing billing;
}

void main() {
  late FakeServer server;

  setUp(() => server = FakeServer());

  final vault = sharedVault();
  final base = DateTime.utc(2026, 11, 17, 10);

  KapyMessage question(String text, int minute) => KapyMessage(
    id: NotesStore.newId(),
    role: KapyRole.user,
    text: text,
    at: base.add(Duration(minutes: minute)),
  );

  KapyMessage answer(
    String text,
    int minute, {
    List<KapyNoteRef> read = const [],
  }) => KapyMessage(
    id: NotesStore.newId(),
    role: KapyRole.assistant,
    text: text,
    at: base.add(Duration(minutes: minute)),
    read: read,
    matching: read.length,
    model: _cloud,
  );

  KapyChat chat({
    String title = 'What is in my trip note?',
    List<KapyMessage>? messages,
    int minute = 0,
    KapyModel model = _cloud,
  }) {
    final list =
        messages ??
        [question(title, minute), answer('Flights and a hotel.', minute + 1)];
    return KapyChat(
      id: NotesStore.newId(),
      title: title,
      createdAt: base.add(Duration(minutes: minute)),
      updatedAt: list.last.at,
      model: model,
      messages: list,
    );
  }

  Map<String, ({WireTaskRecord record, int seq})> stored() =>
      server.tasks['user-1'] ?? {};

  Future<Map<String, Object?>?> opened(WireTaskRecord record) async {
    final payload = record.payload;
    if (payload == null) return null;
    final bytes = await vault.openRaw(payload, null);
    return jsonDecode(utf8.decode(bytes!)) as Map<String, Object?>;
  }

  Future<List<Map<String, Object?>>> live(String kind) async => [
    for (final row in stored().values)
      if ((await opened(row.record))?['kind'] == kind)
        (await opened(row.record))!,
  ];

  int tombstones() => [
    for (final row in stored().values)
      if (row.record.payload == null) row,
  ].length;

  Future<(Device, Device)> pair() async {
    final laptop = Device(server, name: 'laptop');
    final phone = Device(server, name: 'phone');
    await laptop.boot();
    await phone.boot();
    return (laptop, phone);
  }

  void later(Device d) => d.clock = d.clock.add(const Duration(seconds: 1));

  void afterChats(Device a, [Device? b]) {
    for (final d in [a, ?b]) {
      d.clock = base.add(const Duration(hours: 2));
    }
  }

  String shape(KapyChat c) => jsonEncode({
    'id': c.id,
    'title': c.title,
    'model': c.model.toJson(),
    'updatedAt': c.updatedAt.millisecondsSinceEpoch,
    'messages': [
      for (final m in c.messages)
        {
          'id': m.id,
          'role': m.role.name,
          'text': m.text,
          'at': m.at.millisecondsSinceEpoch,
          'read': [
            for (final n in m.read)
              [n.noteId, n.title, n.edited.millisecondsSinceEpoch],
          ],
          'matching': m.matching,
          'model': m.model?.toJson(),
        },
    ],
  });

  group('a chat on the stream', () {
    test(
      'reaches another device as sealed records under ids only the account can name',
      () async {
        final (laptop, phone) = await pair();
        final trip = chat(
          messages: [
            question('What is in my trip note?', 0),
            answer(
              'Flights and a hotel.',
              1,
              read: [
                KapyNoteRef(
                  noteId: NotesStore.newId(),
                  title: 'Trip to Kochi',
                  edited: base,
                ),
              ],
            ),
          ],
        );
        laptop.chats.put(trip);
        await laptop.pass();

        expect(stored(), hasLength(3), reason: 'the chat, and each message');
        expect(stored().keys.toSet(), {
          vault.chatRecordId(trip.id),
          for (final m in trip.messages)
            vault.chatMessageRecordId(trip.id, m.id, 0),
        });
        expect(
          vault.chatRecordId(trip.id)[14],
          '8',
          reason: 'a version-8 UUID',
        );
        for (final row in stored().values) {
          final raw = utf8.decode(
            row.record.payload!.cipherText,
            allowMalformed: true,
          );
          for (final secret in ['trip note', 'Flights', 'Kochi', trip.id]) {
            expect(raw, isNot(contains(secret)));
          }
        }
        expect(laptop.chats.owed(), isEmpty);

        await phone.pass();
        expect(phone.chats.chats.map(shape), [
          shape(trip).replaceAll('Trip to Kochi', ''),
        ], reason: 'a note read goes without its title');
        expect(phone.chats.owed(), isEmpty);
        laptop.dispose();
        phone.dispose();
      },
    );

    test(
      'a long answer is split into parts that each fit a record, and is whole on the other side',
      () async {
        final (laptop, phone) = await pair();
        final text = [
          for (var i = 0; i < 700; i++) 'Line $i: "quoted" \\ café 日本語 😀\n',
        ].join();
        final long = chat(
          messages: [question('Tell me everything', 0), answer(text, 1)],
        );
        laptop.chats.put(long);
        await laptop.pass();

        final parts = await live(chatMessageKind);
        expect(parts.length, greaterThan(3));
        for (final part in parts) {
          expect(
            utf8.encode(jsonEncode(part)).length,
            lessThanOrEqualTo(chatPayloadMax),
          );
        }
        for (final row in stored().values) {
          expect(
            row.record.payload!.cipherText.length * 4 / 3,
            lessThanOrEqualTo(4096 + 4),
          );
        }

        await phone.pass();
        final got = phone.chats.chats.single.messages.last.text;
        expect(got.length, lessThanOrEqualTo(text.length));
        expect(text.startsWith(got), isTrue);
        expect(
          got.length,
          parts.length >= chatMessagePartsMax
              ? lessThan(text.length)
              : text.length,
          reason: 'whole, unless the text ran past the most parts',
        );
        laptop.dispose();
        phone.dispose();
      },
    );

    test(
      'text past the most parts stays on the device that wrote it',
      () async {
        final (laptop, phone) = await pair();
        final huge = 'x' * 200000;
        final long = chat(messages: [question('Go', 0), answer(huge, 1)]);
        laptop.chats.put(long);
        await laptop.pass();

        final parts = await live(chatMessageKind);
        expect(
          parts.where((p) => p['messageId'] == long.messages.last.id),
          hasLength(chatMessagePartsMax),
        );
        await phone.pass();
        final got = phone.chats.chats.single.messages.last.text;
        expect(got.length, lessThan(huge.length));
        expect(huge.startsWith(got), isTrue);
        expect(laptop.chats.chats.single.messages.last.text, huge);
        laptop.dispose();
        phone.dispose();
      },
    );

    test('a message with parts missing is not shown until they come', () async {
      final (laptop, phone) = await pair();
      final long = chat(messages: [question('Go', 0), answer('y' * 9000, 1)]);
      laptop.chats.put(long);
      await laptop.pass();
      final partId = vault.chatMessageRecordId(
        long.id,
        long.messages.last.id,
        1,
      );
      final held = stored()[partId]!;
      server.tasks['user-1']!.remove(partId);

      await phone.pass();
      expect(phone.chats.chats.single.messages.map((m) => m.role), [
        KapyRole.user,
      ]);

      server.pushTasks('user-1', 'laptop', [held.record]);
      await phone.pass();
      expect(phone.chats.chats.single.messages.last.text, 'y' * 9000);
      laptop.dispose();
      phone.dispose();
    });

    test(
      'the notes an answer read go up as an id and an edit time, with no title',
      () async {
        final (laptop, phone) = await pair();
        final secret = laptop.notes.create(body: 'Therapy notes\nprivate');
        final fine = laptop.notes.create(body: 'Trip to Kochi');
        final trip = chat(
          messages: [
            question('Anything?', 0),
            answer(
              'Yes.',
              1,
              read: [
                KapyNoteRef(
                  noteId: secret.id,
                  title: 'Therapy notes',
                  edited: base,
                ),
                KapyNoteRef(
                  noteId: fine.id,
                  title: 'Trip to Kochi',
                  edited: base,
                ),
              ],
            ),
          ],
        );
        laptop.notes.hide(secret.id);
        laptop.chats.put(trip);
        await laptop.pass();

        final sent = (await live(chatMessageKind)).last;
        final read = (sent['read'] as List).cast<Map>();
        expect([for (final n in read) n['noteId']], [secret.id, fine.id]);
        expect([for (final n in read) n['title']], ['', '']);
        expect(
          jsonEncode(await live(chatMessageKind)),
          allOf(isNot(contains('Therapy')), isNot(contains('Kochi'))),
        );
        await phone.pass();
        expect(
          phone.chats.chats.single.messages.last.read.map((n) => n.noteId),
          [secret.id, fine.id],
        );
        laptop.dispose();
        phone.dispose();
      },
    );
  });

  group('a payload is bound to its record', () {
    test('payloads swapped between two records are both refused', () async {
      final (laptop, phone) = await pair();
      final trip = chat();
      laptop.chats.put(trip);
      await laptop.pass();
      final chatRecord = stored()[vault.chatRecordId(trip.id)]!.record;
      final askedId = vault.chatMessageRecordId(
        trip.id,
        trip.messages.first.id,
        0,
      );
      final asked = stored()[askedId]!.record;
      server.pushTasks('user-1', 'mallory', [
        WireTaskRecord(
          id: chatRecord.id,
          updatedAt: chatRecord.updatedAt.add(const Duration(seconds: 1)),
          payload: asked.payload,
        ),
        WireTaskRecord(
          id: askedId,
          updatedAt: asked.updatedAt.add(const Duration(seconds: 1)),
          payload: chatRecord.payload,
        ),
      ]);
      await phone.pass();
      expect(phone.chats.chats, isEmpty);
      laptop.dispose();
      phone.dispose();
    });

    test(
      'a message replayed under another part or another id is refused',
      () async {
        final (laptop, phone) = await pair();
        final trip = chat();
        laptop.chats.put(trip);
        await laptop.pass();
        final real =
            stored()[vault.chatMessageRecordId(
                  trip.id,
                  trip.messages.last.id,
                  0,
                )]!
                .record;
        server.pushTasks('user-1', 'mallory', [
          WireTaskRecord(
            id: vault.chatMessageRecordId(trip.id, trip.messages.last.id, 1),
            updatedAt: real.updatedAt,
            payload: real.payload,
          ),
          WireTaskRecord(
            id: '0195f0d0-aaaa-4bbb-8ccc-000000000000',
            updatedAt: real.updatedAt,
            payload: real.payload,
          ),
        ]);
        await phone.pass();
        expect([for (final c in phone.chats.chats) c.messages.length], [2]);
        expect(phone.chats.owed(), isEmpty);
        laptop.dispose();
        phone.dispose();
      },
    );
  });

  group('Pro only', () {
    test(
      'on Free nothing of a chat is sent or taken in, and Free keeps its chats',
      () async {
        final (laptop, phone) = await pair();
        laptop.chats.put(chat(title: 'From the laptop'));
        await laptop.pass();
        final stream = stored().length;
        expect(stream, 3);

        phone.pro = false;
        phone.chats.put(chat(title: 'Free chat', minute: 5));
        server.log.clear();
        await phone.pass();

        expect(stored(), hasLength(stream), reason: 'nothing was sent');
        expect(
          server.log.where((e) => e.call.startsWith('pushTasks')),
          isEmpty,
        );
        expect([for (final c in phone.chats.chats) c.title], ['Free chat']);
        expect(phone.chats.skipped, isTrue);
        laptop.dispose();
        phone.dispose();
      },
    );

    test(
      'a Free account that turns Pro uploads what it kept and takes in what is there',
      () async {
        final (laptop, phone) = await pair();
        laptop.chats.put(chat(title: 'From the laptop'));
        await laptop.pass();

        phone.pro = false;
        phone.chats.put(chat(title: 'Kept on the phone', minute: 5));
        phone.chats.put(chat(title: 'Another', minute: 6));
        await phone.pass();
        expect(stored(), hasLength(3));

        phone.pro = true;
        phone.sync.planChanged();
        await settle(server);

        expect(stored(), hasLength(3 + 2 * 3));
        expect(
          {for (final c in phone.chats.chats) c.title},
          {'From the laptop', 'Kept on the phone', 'Another'},
        );
        await laptop.pass();
        expect(
          {for (final c in laptop.chats.chats) c.title},
          {'From the laptop', 'Kept on the phone', 'Another'},
        );
        expect(phone.chats.skipped, isFalse);
        laptop.dispose();
        phone.dispose();
      },
    );

    test(
      'a device whose cursor is past chats it never read, from a build that kept them as ids, reads them once',
      () async {
        final laptop = Device(server, name: 'laptop');
        var phone = Device(server, name: 'phone', withChats: false);
        await laptop.boot();
        await phone.boot();
        laptop.chats.put(chat(title: 'From the laptop'));
        await laptop.pass();
        await phone.pass();
        expect(phone.tasks.cursor, greaterThan(0));
        expect(phone.chats.chats, isEmpty);
        final store = phone.store;
        phone.dispose();

        List<String> pulls() => [
          for (final e in server.log)
            if (e.device == phone.api.device && e.call.startsWith('pullTasks'))
              e.call,
        ];

        phone = Device(server, name: 'phone', resume: store);
        await phone.boot();
        expect(phone.tasks.cursor, greaterThan(0), reason: 'past the chats');
        server.log.clear();
        await phone.pass();
        expect(pulls(), contains('pullTasks:0'), reason: 'read from the start');
        expect(
          [for (final c in phone.chats.chats) c.title],
          ['From the laptop'],
        );
        expect(phone.chats.skipped, isFalse);
        phone.dispose();

        phone = Device(server, name: 'phone', resume: store);
        await phone.boot();
        server.log.clear();
        await phone.pass();
        expect(pulls(), isNotEmpty);
        expect(pulls(), isNot(contains('pullTasks:0')), reason: 'not again');
        expect(phone.chats.chats, hasLength(1));
        laptop.dispose();
        phone.dispose();
      },
    );

    test(
      'when Pro lapses the chats stay, and a deletion then is this device only',
      () async {
        final (laptop, phone) = await pair();
        final a = chat(title: 'Keep me');
        final b = chat(title: 'Delete me while Free', minute: 5);
        laptop.chats.put(a);
        laptop.chats.put(b);
        await laptop.pass();
        await phone.pass();
        expect(phone.chats.chats, hasLength(2));

        phone.pro = false;
        phone.sync.planChanged();
        phone.chats.delete(b.id);
        phone.chats.put(chat(title: 'New while Free', minute: 9));
        await phone.pass();
        expect(
          [for (final c in phone.chats.chats) c.title],
          ['New while Free', 'Keep me'],
        );
        expect(tombstones(), 0);
        expect(stored(), hasLength(6));

        phone.pro = true;
        phone.sync.planChanged();
        await settle(server);
        expect(
          tombstones(),
          0,
          reason: 'never turned into a deletion on the account',
        );
        expect(phone.chats.chats.any((c) => c.id == b.id), isFalse);
        await laptop.pass();
        expect(laptop.chats.chat(b.id), isNotNull);
        expect(laptop.chats.chats, hasLength(3));
        laptop.dispose();
        phone.dispose();
      },
    );
  });

  group('two devices', () {
    test('a rename on one and a new answer on the other both hold', () async {
      final (laptop, phone) = await pair();
      final trip = chat();
      laptop.chats.put(trip);
      await laptop.pass();
      await phone.pass();

      afterChats(laptop, phone);
      later(laptop);
      final renamed = KapyChat(
        id: trip.id,
        title: 'Kochi plans',
        createdAt: trip.createdAt,
        updatedAt: laptop.clock,
        model: trip.model,
        messages: trip.messages,
        titleAt: laptop.clock,
      );
      laptop.chats.put(renamed);
      final more = [
        ...trip.messages,
        question('And the hotel?', 10),
        answer('The Taj.', 11),
      ];
      phone.chats.put(
        KapyChat(
          id: trip.id,
          title: trip.title,
          createdAt: trip.createdAt,
          updatedAt: more.last.at,
          model: trip.model,
          messages: more,
        ),
      );
      await laptop.pass();
      await phone.pass();
      await laptop.pass();

      for (final d in [laptop, phone]) {
        final got = d.chats.chats.single;
        expect(got.title, 'Kochi plans', reason: d.name);
        expect(got.messages.map((m) => m.text), [
          'What is in my trip note?',
          'Flights and a hotel.',
          'And the hotel?',
          'The Taj.',
        ], reason: d.name);
        expect(d.chats.owed(), isEmpty, reason: d.name);
      }
      expect(shape(laptop.chats.chats.single), shape(phone.chats.chats.single));
      laptop.dispose();
      phone.dispose();
    });

    test(
      'of two renames the later wins on both, and the model pick travels',
      () async {
        final (laptop, phone) = await pair();
        final trip = chat();
        laptop.chats.put(trip);
        await laptop.pass();
        await phone.pass();

        afterChats(laptop, phone);
        KapyChat edit(Device d, {String? title, KapyModel? model}) {
          later(d);
          final c = d.chats.chats.single;
          return KapyChat(
            id: c.id,
            title: title ?? c.title,
            createdAt: c.createdAt,
            updatedAt: d.clock,
            model: model ?? c.model,
            messages: c.messages,
            titleAt: title == null ? c.titleAt : d.clock,
            modelAt: model == null ? c.modelAt : d.clock,
          );
        }

        laptop.chats.put(edit(laptop, title: 'First'));
        phone.clock = laptop.clock.add(const Duration(seconds: 5));
        phone.chats.put(edit(phone, title: 'Second', model: _gemma));
        await laptop.pass();
        await phone.pass();
        await laptop.pass();
        for (final d in [laptop, phone]) {
          expect(d.chats.chats.single.title, 'Second', reason: d.name);
          expect(d.chats.chats.single.model, _gemma, reason: d.name);
        }
        laptop.dispose();
        phone.dispose();
      },
    );

    test(
      'a deletion leaves tombstones for the chat and every message, and the other device drops it for good',
      () async {
        final (laptop, phone) = await pair();
        final trip = chat();
        final other = chat(title: 'Stays', minute: 5);
        laptop.chats.put(trip);
        laptop.chats.put(other);
        await laptop.pass();
        await phone.pass();
        expect(phone.chats.chats, hasLength(2));

        laptop.chats.delete(trip.id);
        await laptop.pass();
        expect(tombstones(), 3);
        expect(
          {
            for (final row in stored().values)
              if (row.record.payload == null) row.record.id,
          },
          {
            vault.chatRecordId(trip.id),
            for (final m in trip.messages)
              vault.chatMessageRecordId(trip.id, m.id, 0),
          },
        );
        expect(await live(chatKind), hasLength(1));

        await phone.pass();
        expect([for (final c in phone.chats.chats) c.title], ['Stays']);
        await phone.pass();
        expect(phone.chats.owed(), isEmpty);
        expect([for (final c in phone.chats.chats) c.title], ['Stays']);
        laptop.dispose();
        phone.dispose();
      },
    );

    test(
      'a device that meets only the tombstone of a chat sends its own for the messages it holds',
      () async {
        final (laptop, phone) = await pair();
        final trip = chat();
        laptop.chats.put(trip);
        await laptop.pass();
        await phone.pass();
        final id = vault.chatRecordId(trip.id);
        final at = stored()[id]!.record.updatedAt.add(
          const Duration(minutes: 1),
        );
        server.pushTasks('user-1', 'laptop-2', [
          WireTaskRecord(id: id, updatedAt: at, deletedAt: at),
        ]);

        await phone.pass();
        expect(phone.chats.chats, isEmpty);
        await phone.pass();
        expect(tombstones(), 3);
        expect(phone.chats.owed(), isEmpty);
        laptop.dispose();
        phone.dispose();
      },
    );

    test('Clear history on Pro deletes every chat on every device', () async {
      final (laptop, phone) = await pair();
      for (var i = 0; i < 3; i++) {
        laptop.chats.put(chat(title: 'Chat $i', minute: i * 3));
      }
      await laptop.pass();
      await phone.pass();
      expect(phone.chats.chats, hasLength(3));

      phone.chats.clear();
      await phone.pass();
      expect(tombstones(), 9);
      expect(await live(chatKind), isEmpty);
      await laptop.pass();
      expect(laptop.chats.chats, isEmpty);
      laptop.dispose();
      phone.dispose();
    });

    test('Clear history on Free is this device only', () async {
      final (laptop, phone) = await pair();
      laptop.chats.put(chat(title: 'Shared'));
      await laptop.pass();
      await phone.pass();

      phone.pro = false;
      phone.sync.planChanged();
      phone.chats.clear();
      await phone.pass();
      expect(phone.chats.chats, isEmpty);
      expect(tombstones(), 0);

      phone.pro = true;
      phone.sync.planChanged();
      await settle(server);
      expect(tombstones(), 0);
      expect(phone.chats.chats, isEmpty, reason: 'it does not come back here');
      await laptop.pass();
      expect(laptop.chats.chats, hasLength(1));
      laptop.dispose();
      phone.dispose();
    });

    test(
      'signing out keeps the chats and owes them all to the next account',
      () async {
        final (laptop, _) = await pair();
        laptop.chats.put(chat());
        await laptop.pass();
        expect(laptop.chats.owed(), isEmpty);

        laptop.chats.forgetAccount();
        expect(laptop.chats.chats, hasLength(1));
        expect(laptop.chats.owed(), hasLength(3));
        laptop.dispose();
      },
    );
  });

  group('older clients', () {
    test('a task reader takes neither kind for a task', () async {
      final (laptop, _) = await pair();
      final trip = chat();
      laptop.chats.put(trip);
      await laptop.pass();
      for (final row in stored().values) {
        final payload = (await opened(row.record))!;
        expect(TaskEntry.fromPayload(row.record.id, payload), isNull);
      }
      expect(stored(), hasLength(3));
      laptop.dispose();
    });

    test(
      'a build without chats keeps them as they are, sends none, and loses nothing',
      () async {
        final laptop = Device(server, name: 'laptop');
        final old = Device(server, name: 'old', withChats: false);
        await laptop.boot();
        await old.boot();
        laptop.chats.put(chat());
        laptop.chats.put(chat(title: 'Second', minute: 5));
        laptop.tags.create('Work');
        await laptop.pass();
        final before = {
          for (final e in stored().entries)
            e.key: (e.value.seq, e.value.record.updatedAt),
        };
        expect(before, hasLength(1 + 3 + 3));

        server.log.clear();
        await old.pass();
        await old.pass();
        expect(old.chats.chats, isEmpty);
        expect(old.tags.tags.map((t) => t.name.v), ['Work']);
        expect(old.tags.owed, isEmpty);
        expect(
          server.log.where(
            (e) => e.device == old.api.device && e.call.startsWith('pushTasks'),
          ),
          isEmpty,
        );
        expect({
          for (final e in stored().entries)
            e.key: (e.value.seq, e.value.record.updatedAt),
        }, before);

        later(old);
        old.tags.create('Travel');
        await old.pass();
        await laptop.pass();
        expect(laptop.chats.chats, hasLength(2));
        expect(await live(chatKind), hasLength(2));
        laptop.dispose();
        old.dispose();
      },
    );

    test('a protocol 5 build never asks for the stream', () async {
      final laptop = Device(server, name: 'laptop');
      final old = Device(server, name: 'old', protocol: 5, withChats: false);
      for (final d in [laptop, old]) {
        await d.boot();
        d.sync.resume();
      }
      await settle(server);
      server.log.clear();

      laptop.chats.put(chat());
      await laptop.pass();
      await settle(server);
      final heard = [
        for (final e in server.log)
          if (e.device == old.api.device) e.call,
      ];
      expect(heard.where((c) => c.startsWith('pullTasks')), isEmpty);
      expect(stored(), hasLength(3));
      laptop.dispose();
      old.dispose();
    });

    test(
      'a record of a kind a later build adds to a chat is kept and written back',
      () async {
        final (laptop, phone) = await pair();
        final trip = chat();
        laptop.chats.put(trip);
        await laptop.pass();
        final id = vault.chatRecordId(trip.id);
        final real = (await opened(stored()[id]!.record))!;
        final later = {...real, 'pinned': true};
        server.pushTasks('user-1', 'future', [
          WireTaskRecord(
            id: id,
            updatedAt: stored()[id]!.record.updatedAt.add(
              const Duration(seconds: 1),
            ),
            payload: await vault.sealRaw(utf8.encode(jsonEncode(later)), null),
          ),
        ]);
        await phone.pass();
        afterChats(phone);
        phone.clock = phone.clock.add(const Duration(minutes: 5));
        final c = phone.chats.chats.single;
        phone.chats.put(
          KapyChat(
            id: c.id,
            title: 'Renamed',
            createdAt: c.createdAt,
            updatedAt: phone.clock,
            model: c.model,
            messages: c.messages,
            titleAt: phone.clock,
          ),
        );
        await phone.pass();
        expect((await opened(stored()[id]!.record))!['pinned'], isTrue);
        expect(
          (await opened(stored()[id]!.record))!['title'],
          containsPair('v', 'Renamed'),
        );
        laptop.dispose();
        phone.dispose();
      },
    );
  });

  group('Clear history', () {
    Future<KapyAiController> controllerOver(Device d) async {
      final ai = KapyAiController(
        store: d.store,
        notes: await notesWith([], store: d.store),
        device: FakeDeviceModel(),
        billing: await billingOn(pro: true),
        chats: d.chats,
        token: () => 'session-token',
        client: MockClient((_) async => http.Response('{}', 500)),
        secrets: InMemorySecureStore(),
        codex: FakeLocalTool(KapyAccountKind.codex),
        claudeCode: FakeLocalTool(KapyAccountKind.claudeCode),
        apiBaseUrl: Uri.parse('https://api.test/'),
        now: d.tick,
        environment: const {},
      );
      addTearDown(ai.dispose);
      return ai;
    }

    test(
      'first takes in a chat another device made that this one has not pulled',
      () async {
        final (laptop, phone) = await pair();
        laptop.chats.put(chat(title: 'On the laptop'));
        await laptop.pass();
        await phone.pass();
        phone.chats.put(chat(title: 'Made on the phone', minute: 5));
        await phone.pass();
        expect(laptop.chats.chats, hasLength(1), reason: 'not pulled yet');

        final ai = await controllerOver(laptop);
        await ai.clearHistory();
        await settle(server);
        expect(laptop.chats.chats, isEmpty);
        expect(await live(chatKind), isEmpty);
        expect(tombstones(), 6);

        await phone.pass();
        expect(phone.chats.chats, isEmpty);
        laptop.dispose();
        phone.dispose();
      },
    );

    test(
      'with the account out of reach it clears what it has, and says nothing',
      () async {
        final (laptop, phone) = await pair();
        laptop.chats.put(chat(title: 'On the laptop'));
        await laptop.pass();
        server.tasksServed = false;

        final ai = await controllerOver(laptop);
        await ai.clearHistory();
        expect(laptop.chats.chats, isEmpty);
        expect(ai.pending, isNull);

        server.tasksServed = true;
        await laptop.pass();
        expect(tombstones(), 3);
        laptop.dispose();
        phone.dispose();
      },
    );

    test('on Free it does not ask the account at all', () async {
      final (laptop, phone) = await pair();
      laptop.chats.put(chat(title: 'Here'));
      laptop.pro = false;
      server.log.clear();

      final ai = await controllerOver(laptop);
      await ai.clearHistory();
      expect(laptop.chats.chats, isEmpty);
      expect(server.log.where((e) => e.call.startsWith('pullTasks')), isEmpty);
      laptop.dispose();
      phone.dispose();
    });
  });

  group('the account', () {
    test(
      'a Free account keeps its chats, and uploads them when billing says Pro',
      () async {
        final d = _AccountDevice(server);
        await d.notes.load();
        await d.account.restore();
        await d.account.signIn(email: 'a@b.co', password: 'x');
        await d.account.createPassphrase('a good passphrase');
        d.plan.answer = () => entitlementsFor(pro: false);
        await d.billing.refreshIfStale(maxAge: Duration.zero);
        expect(d.billing.hasPro, isFalse);
        expect(d.chats.syncing, isFalse);

        d.chats.put(chat(title: 'Kept here'));
        await d.account.sync!.syncNow();
        await settle(server);
        expect(stored(), isEmpty);

        d.plan.answer = () => entitlementsFor(pro: true);
        await d.billing.refreshIfStale(maxAge: Duration.zero);
        expect(d.chats.syncing, isTrue);
        await until(
          () => stored().length == 3,
          reason: 'the chat never went up',
        );
        d.plan.answer = () => entitlementsFor(pro: false);
        await d.billing.refreshIfStale(maxAge: Duration.zero);
        expect(d.chats.syncing, isFalse);
        expect(d.chats.chats, hasLength(1), reason: 'a lapse keeps them');
        await d.account.signOut();
        expect(d.chats.chats, hasLength(1), reason: 'so does signing out');
        expect(d.chats.syncing, isFalse);
        d.account.dispose();
      },
    );
  });

  group('finding the record a deletion is for', () {
    test('costs one lookup, however many chats are known', () async {
      final book = KapyChatBook(MemoryStore(), now: () => base);
      await book.load();
      final chats = [for (var i = 0; i < 300; i++) chat(minute: i)];
      for (final c in chats) {
        book.applyRemoteChat(ChatMeta.of(c), 1000);
      }
      var calls = 0;
      String recordId(String key) {
        calls++;
        return 'record-for-$key';
      }

      book.attach(() => true, () async {}, recordId);
      String idOf(KapyChat c) => 'record-for-${chatKey(c.id)}';
      expect(book.keyOfRecord(idOf(chats.first)), chatKey(chats.first.id));
      expect(calls, 300, reason: 'every known key named once');

      calls = 0;
      for (var i = 0; i < 1000; i++) {
        expect(
          book.keyOfRecord(idOf(chats[i % 300])),
          chatKey(chats[i % 300].id),
        );
        expect(book.keyOfRecord('record-for-a-task'), isNull);
      }
      expect(calls, 0, reason: 'a lookup names nothing');

      final fresh = chat(minute: 400);
      book.applyRemoteChat(ChatMeta.of(fresh), 1000);
      expect(calls, 1, reason: 'a key that joins is named once');
      expect(book.keyOfRecord(idOf(fresh)), chatKey(fresh.id));

      calls = 0;
      book.applyRemoteDelete(chatKey(fresh.id), 2000);
      expect(calls, 1, reason: 'a key that leaves is named once');
      expect(book.keyOfRecord(idOf(fresh)), isNull);
      expect(book.keyOfRecord(idOf(chats.first)), chatKey(chats.first.id));
      expect(calls, 1);
    });
  });

  group('a pull holds the chat book', () {
    test('writes it about once per page, not once per record', () async {
      final laptop = Device(server, name: 'laptop');
      await laptop.boot();
      for (var i = 0; i < 200; i++) {
        laptop.chats.put(chat(title: 'Chat $i', minute: i));
      }
      await laptop.pass();
      final records = stored().length;
      expect(records, greaterThanOrEqualTo(600));

      server.taskPageSize = 50;
      final phone = Device(server, name: 'phone');
      await phone.boot();
      phone.store.puts.clear();
      await phone.pass();

      final pages = (records / 50).ceil();
      expect(phone.chats.chats, hasLength(200));
      expect(
        phone.store.puts['kapyAi.chats.v1'] ?? 0,
        lessThanOrEqualTo(pages + 1),
      );
      expect(
        phone.store.puts['kapyAi.chatSync.v1'] ?? 0,
        lessThanOrEqualTo(pages + 2),
        reason: 'a page each, and the first pass clearing its skipped mark',
      );
      laptop.dispose();
      phone.dispose();
    });

    test('tells listeners of every record while the writes wait', () async {
      final store = MemoryStore();
      final book = KapyChatBook(store, now: () => base);
      await book.load();
      var told = 0;
      book.addListener(() => told++);
      book.hold();
      for (var i = 0; i < 5; i++) {
        book.applyRemoteChat(ChatMeta.of(chat(minute: i)), 1000 + i);
      }
      expect(told, 5);
      expect(store.puts, isEmpty);

      book.release();
      expect(store.puts['kapyAi.chats.v1'], 1);
      expect(store.puts['kapyAi.chatSync.v1'], 1);
      book.release();
      expect(store.puts['kapyAi.chats.v1'], 1, reason: 'nothing to write');
    });

    test(
      'a chat id kept bare by an older build is dropped once taken',
      () async {
        final laptop = Device(server, name: 'laptop');
        await laptop.boot();
        final first = chat();
        laptop.chats.put(first);
        await laptop.pass();

        final phone = Device(server, name: 'phone');
        await phone.boot();
        final ids = [for (final row in stored().values) row.record.id];
        expect(ids, contains(vault.chatRecordId(first.id)));
        for (final id in ids) {
          phone.tags.keepUnknown(id, 1);
        }
        List unknown() =>
            (phone.store.data['tags.v1'] as Map)['unknown'] as List;
        expect(unknown(), hasLength(ids.length));

        await phone.pass();
        expect(phone.chats.chats, hasLength(1));
        expect(unknown(), isEmpty);
        laptop.dispose();
        phone.dispose();
      },
    );
  });

  group('the ledger waits for the hold', () {
    test(
      'saves the ledger about once per chunk, not once per record',
      () async {
        final laptop = Device(server, name: 'laptop');
        await laptop.boot();
        for (var i = 0; i < 200; i++) {
          laptop.chats.put(chat(title: 'Chat $i', minute: i));
        }
        laptop.store.puts.clear();
        await laptop.pass();

        final records = stored().length;
        expect(records, greaterThanOrEqualTo(600));
        final chunks = (records / tasksPushMax).ceil();
        expect(
          laptop.store.puts['kapyAi.chatSync.v1'] ?? 0,
          lessThanOrEqualTo(chunks + 3),
          reason:
              'a chunk each, and the pass marking and clearing what it owes',
        );
        laptop.dispose();
      },
    );

    test('a pull of many deleted chats saves the ledger once a page', () async {
      final laptop = Device(server, name: 'laptop');
      await laptop.boot();
      final made = [
        for (var i = 0; i < 100; i++) chat(title: 'Chat $i', minute: i),
      ];
      for (final one in made) {
        laptop.chats.put(one);
      }
      await laptop.pass();
      final phone = Device(server, name: 'phone');
      await phone.boot();
      await phone.pass();
      expect(phone.chats.chats, hasLength(100));

      for (final one in made) {
        laptop.chats.delete(one.id);
      }
      await laptop.pass();
      server.taskPageSize = 50;
      phone.store.puts.clear();
      await phone.pass();

      expect(phone.chats.chats, isEmpty);
      final pages = (stored().length / 50).ceil();
      expect(
        phone.store.puts['kapyAi.chatSync.v1'] ?? 0,
        lessThanOrEqualTo(pages + 2),
      );
      laptop.dispose();
      phone.dispose();
    });
  });

  group('what a push holds', () {
    test('chats go in chunks of their own, after the tasks and tags', () async {
      final laptop = Device(server, name: 'laptop');
      await laptop.boot();
      laptop.tags.create('Work');
      laptop.tags.create('Travel');
      laptop.chats.put(chat());
      laptop.chats.put(chat(title: 'Second', minute: 5));
      await laptop.pass();

      final kinds = {
        for (final row in stored().values)
          row.record.id: (await opened(row.record))?['kind'],
      };
      final pushes = [
        for (final push in server.taskPushes)
          [
            for (final id in push)
              kinds[id] == chatKind || kinds[id] == chatMessageKind,
          ],
      ];
      expect(pushes.expand((push) => push), contains(true));
      expect(pushes.expand((push) => push), contains(false));
      for (final push in pushes) {
        expect(
          push.toSet(),
          hasLength(1),
          reason: 'no push holds chats beside a tag or a task',
        );
      }
      expect(pushes.map((push) => push.first), [
        false,
        true,
      ], reason: 'the chats come last');
      laptop.dispose();
    });
  });

  group('the cap', () {
    test('chats stop short of the live-record limit, newest first', () async {
      final laptop = Device(server, name: 'laptop');
      final all = [
        for (var i = 2700; i > 0; i--)
          chat(title: 'Chat $i', minute: i * 3, messages: null),
      ];
      laptop.store.data['kapyAi.chats.v1'] = {
        'chats': [for (final c in all) chatToJson(c)],
        'deleted': <String, Object?>{},
      };
      await laptop.boot();

      final owed = laptop.chats.owed();
      expect(owed, hasLength(2666 * 3));
      expect(owed.length, lessThanOrEqualTo(chatRecordsMax));
      final keys = {for (final item in owed) item.key};
      expect(keys, contains(chatKey(all.first.id)));
      expect(keys, isNot(contains(chatKey(all.last.id))));
      laptop.dispose();
    });
  });
}
