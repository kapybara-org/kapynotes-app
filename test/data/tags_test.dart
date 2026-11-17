import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/stamped.dart';
import 'package:kapy_notes/data/tags.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'tags-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

const noteId = '0195f0d0-1111-4222-8333-444455556666';

Tag remoteTag(String id, String name, {int createdAt = 1, int at = 1}) => Tag(
  id: id,
  name: Stamped(name, at),
  colour: Stamped('teal', at),
  order: Stamped(0, at),
  createdAt: createdAt,
);

void main() {
  late _MemoryStore store;
  late DateTime clock;
  late TagStore tags;

  DateTime tick() => clock = clock.add(const Duration(milliseconds: 1));

  setUp(() async {
    store = _MemoryStore();
    clock = DateTime.utc(2026, 11, 17, 9);
    tags = TagStore(store, now: tick);
    await tags.load();
  });

  List<String> namesOn(String id, [TagStore? from]) => [
    for (final tag in (from ?? tags).tagsOf(id)) tag.name.v,
  ];

  Map<String, Object?>? owedPayload(String key, [TagStore? from]) =>
      (from ?? tags).owed.firstWhere((r) => r.key == key).payload;

  void acknowledgeAll([TagStore? from]) {
    final store = from ?? tags;
    store.owed.forEach(store.acknowledge);
  }

  group('names', () {
    test('are trimmed, at most 32 characters, and unique ignoring case', () {
      final work = tags.create('  Work ')!;
      expect(work.name.v, 'Work');
      expect(tags.create('WORK')!.id, work.id);
      expect(tags.create('   '), isNull);
      expect(tags.create('x' * 33), isNull);
      expect(tags.create('x' * 32)!.name.v, hasLength(32));
      expect(tags.tags.map((t) => t.name.v), ['Work', 'x' * 32]);
    });

    test('a synced name past 32 runes arrives cut to 32', () {
      final tag = Tag.fromPayload(
        't1',
        remoteTag('t1', '🏷' * 40).toPayload(),
      )!;
      expect(tag.name.v, '🏷' * 32);
      tags.applyRemoteTag(tag, 5);
      expect(tags.byId('t1')!.name.v.runes, hasLength(tagNameMax));
    });

    test('a rename to an empty, overlong or taken name changes nothing', () {
      final work = tags.create('Work')!;
      tags.create('Travel');
      expect(tags.rename(work.id, ' travel '), isFalse);
      expect(tags.rename(work.id, ' '), isFalse);
      expect(tags.rename(work.id, 'y' * 33), isFalse);
      expect(tags.byId(work.id)!.name.v, 'Work');
      expect(tags.rename(work.id, 'WORK'), isTrue);
      expect(tags.byId(work.id)!.name.v, 'WORK');
    });
  });

  group('colours', () {
    test('a new tag takes the least used colour, a tie in palette order', () {
      final colours = [
        for (var i = 0; i < 9; i++) tags.create('t$i')!.colour.v,
      ];
      expect(colours, [...tagColours, 'mustard']);

      tags.recolour(tags.tags[1].id, 'mustard');
      expect(tags.create('t9')!.colour.v, 'rust');

      tags.delete(tags.tags[2].id);
      expect(
        tags.create('t10')!.colour.v,
        'olive',
        reason: 'deleted tags do not count',
      );

      tags.recolour(tags.tags.first.id, noTagColour);
      tags.recolour(tags.tags.first.id, 'magenta');
      expect(tags.tags.first.colour.v, noTagColour);
    });
  });

  group('order', () {
    test('tags list in the order set, and a new one goes last', () {
      final a = tags.create('A')!;
      final b = tags.create('B')!;
      final c = tags.create('C')!;
      expect(tags.tags.map((t) => t.id), [a.id, b.id, c.id]);
      tags.reorder([c.id, a.id, b.id]);
      expect(tags.tags.map((t) => t.id), [c.id, a.id, b.id]);
      final d = tags.create('D')!;
      expect(tags.tags.last.id, d.id);
    });
  });

  group("a note's tags", () {
    test('read in their order, then any other by when it went on', () {
      final x = tags.create('X')!;
      final y = tags.create('Y')!;
      final z = tags.create('Z')!;
      final gone = tags.create('Gone')!;
      tags.delete(gone.id);
      tags.applyRemoteNote(
        NoteTags(
          noteId: noteId,
          tags: {
            x.id: const Stamped(true, 5),
            y.id: const Stamped(true, 3),
            z.id: const Stamped(true, 4),
            gone.id: const Stamped(true, 1),
            'not-arrived-yet': const Stamped(true, 2),
          },
          order: Stamped([z.id, gone.id, 'not-arrived-yet', x.id, y.id], 6),
        ),
        10,
      );
      expect(namesOn(noteId), ['Z', 'X', 'Y']);

      tags.applyRemoteNote(
        NoteTags(
          noteId: noteId,
          tags: {
            x.id: const Stamped(true, 5),
            y.id: const Stamped(true, 3),
            z.id: const Stamped(false, 7),
          },
          order: Stamped([x.id], 7),
        ),
        11,
      );
      expect(namesOn(noteId), ['X', 'Y'], reason: 'Y was not in the order');
    });

    test('add, remove and set, each a change of its own tag', () {
      final work = tags.create('Work')!;
      final home = tags.create('Home')!;
      final travel = tags.create('Travel')!;
      expect(tags.addTag(noteId, work.id), isTrue);
      expect(tags.addTag(noteId, home.id), isTrue);
      expect(namesOn(noteId), ['Work', 'Home']);
      expect(tags.setTags(noteId, [travel.id, work.id]), isTrue);
      expect(namesOn(noteId), ['Travel', 'Work']);
      tags.removeTag(noteId, travel.id);
      expect(namesOn(noteId), ['Work']);
      final payload = owedPayload(noteId)!;
      expect((payload['tags'] as Map)[home.id], {'v': false, 'at': isPositive});
      expect(payload['kind'], 'noteTags');
    });

    test('a 21st tag is refused, as is a tag that is not live', () {
      final ids = [for (var i = 0; i < 21; i++) tags.create('t$i')!.id];
      for (final id in ids.take(20)) {
        expect(tags.addTag(noteId, id), isTrue);
      }
      expect(tags.addTag(noteId, ids.last), isFalse);
      expect(tags.setTags(noteId, ids), isFalse);
      expect(tags.tagsOf(noteId), hasLength(20));

      tags.removeTag(noteId, ids.first);
      tags.delete(ids.last);
      expect(tags.addTag(noteId, ids.last), isFalse);
      expect(tags.addTag(noteId, 'no-such-tag'), isFalse);
      expect(tags.tagsOf(noteId), hasLength(19));
    });

    test('a note deleted for good takes its record with it', () {
      tags.addTag(noteId, tags.create('Work')!.id);
      acknowledgeAll();
      tags.forgetNote(noteId);
      expect(tags.tagsOf(noteId), isEmpty);
      expect(tags.owed.single.key, noteId);
      expect(tags.owed.single.payload, isNull);
      acknowledgeAll();
      expect(tags.noteIds, isEmpty);
    });
  });

  group('delete and undo', () {
    test(
      'a deleted tag stays on its notes, read past; undo puts it back in place',
      () {
        final a = tags.create('A')!;
        final b = tags.create('B')!;
        final c = tags.create('C')!;
        tags.setTags(noteId, [a.id, b.id, c.id]);

        tags.delete(b.id);
        expect(tags.byId(b.id), isNull);
        expect(tags.tags.map((t) => t.name.v), ['A', 'C']);
        expect(namesOn(noteId), ['A', 'C']);
        expect(
          tags.owed.where((r) => r.key == noteId),
          hasLength(1),
          reason: 'only the tag is written, not the notes',
        );
        acknowledgeAll();

        tags.setTags(noteId, [c.id, a.id]);
        tags.restore(b.id);
        expect(tags.byId(b.id)!.name.v, 'B');
        expect(namesOn(noteId), ['C', 'B', 'A']);
        expect(tags.owed.where((r) => r.key == b.id).single.payload, isNotNull);
      },
    );

    test(
      "a note's record drops a tag deleted over 30 days ago when next written",
      () {
        final a = tags.create('A')!;
        final b = tags.create('B')!;
        final c = tags.create('C')!;
        final d = tags.create('D')!;
        tags.setTags(noteId, [a.id, b.id]);
        tags.delete(b.id);

        clock = clock.add(const Duration(days: 29));
        tags.addTag(noteId, c.id);
        expect((owedPayload(noteId)!['tags'] as Map).keys, contains(b.id));

        clock = clock.add(const Duration(days: 2));
        tags.addTag(noteId, d.id);
        final payload = owedPayload(noteId)!;
        expect((payload['tags'] as Map).keys, isNot(contains(b.id)));
        expect((payload['order'] as Map)['v'], isNot(contains(b.id)));
        tags.restore(b.id);
        expect(namesOn(noteId), ['A', 'C', 'D']);
      },
    );
  });

  group('two tags of one name', () {
    test(
      'the earliest created stays and takes the other one\'s notes in place',
      () {
        const first = 'aaaaaaaa-0000-4000-8000-000000000002';
        const second = 'aaaaaaaa-0000-4000-8000-000000000001';
        const other = '0195f0d0-1111-4222-8333-777788889999';
        final x = tags.create('X')!;
        tags.applyRemoteTag(remoteTag(first, 'Work', createdAt: 100), 1);
        tags.applyRemoteTag(remoteTag(second, 'work ', createdAt: 200), 2);
        tags.applyRemoteNote(
          NoteTags(
            noteId: noteId,
            tags: {
              x.id: const Stamped(true, 1),
              second: const Stamped(true, 2),
            },
            order: Stamped([second, x.id], 3),
          ),
          3,
        );
        tags.applyRemoteNote(
          NoteTags(
            noteId: other,
            tags: {
              first: const Stamped(true, 1),
              second: const Stamped(true, 2),
            },
            order: Stamped([second, first], 3),
          ),
          4,
        );

        tags.settle();
        expect(tags.tags.map((t) => t.id), containsAll([first, x.id]));
        expect(tags.byId(second), isNull);
        expect(tags.tagsOf(noteId).map((t) => t.id), [first, x.id]);
        expect(tags.tagsOf(other).map((t) => t.id), [first]);
        expect(tags.owed.firstWhere((r) => r.key == second).payload, isNull);
        expect(tags.create('WORK')!.id, first);
      },
    );

    test('a tie goes to the lower id, and every device writes the same', () {
      const low = 'aaaaaaaa-0000-4000-8000-000000000001';
      const high = 'aaaaaaaa-0000-4000-8000-000000000002';
      final elsewhere = TagStore(_MemoryStore(), now: () => DateTime.utc(2027));
      for (final store in [tags, elsewhere]) {
        store.applyRemoteTag(remoteTag(high, 'Work', createdAt: 100), 1);
        store.applyRemoteTag(remoteTag(low, 'WORK', createdAt: 100), 2);
        store.applyRemoteNote(
          NoteTags(
            noteId: noteId,
            tags: {high: const Stamped(true, 5)},
            order: Stamped([high], 5),
          ),
          3,
        );
        store.settle();
      }
      expect(tags.tagsOf(noteId).single.id, low);
      expect(
        jsonEncode(owedPayload(noteId)),
        jsonEncode(owedPayload(noteId, elsewhere)),
      );
      expect(owedPayload(high), isNull);
      expect(owedPayload(high, elsewhere), isNull);
    });
  });

  group('sync bookkeeping', () {
    test('keeps fields and kinds a later build wrote', () async {
      final tag = Tag.fromPayload('t1', {
        ...remoteTag('t1', 'Work').toPayload(),
        'icon': 'briefcase',
      })!;
      tags.applyRemoteTag(tag, 5);
      tags.rename('t1', 'Office');
      expect(owedPayload('t1')!['icon'], 'briefcase');
      expect(owedPayload('t1')!['kind'], 'tag');

      tags.keepUnknown('r1', {'kind': 'folder', 'name': 'Later'}, 7);
      final again = TagStore(store, now: tick);
      expect(await again.load(), isTrue);
      again.applyRemoteDelete('r9', 8);
      expect(store.data['tags.v1'], isA<Map>());
      expect(
        jsonEncode((store.data['tags.v1'] as Map)['unknown']),
        contains('Later'),
      );
      again.applyRemoteDelete('r1', 8);
      expect(jsonEncode((store.data['tags.v1'] as Map)['unknown']), '[]');
    });

    test('survives a reload, owed records included', () async {
      final work = tags.create('Work')!;
      tags.addTag(noteId, work.id);
      tags.owed.where((r) => r.kind == Tag.kind).forEach(tags.acknowledge);
      final again = TagStore(store, now: tick);
      expect(await again.load(), isTrue);
      expect(namesOn(noteId, again), ['Work']);
      expect(again.owed.map((r) => r.key), [noteId]);
    });

    test('says once that it never held tags', () async {
      expect(await TagStore(_MemoryStore()).load(), isFalse);
      expect(await TagStore(store).load(), isTrue);
    });

    test(
      'a newer local delete outlives an older remote edit; a newer edit brings it back',
      () {
        final work = tags.create('Work')!;
        acknowledgeAll();
        tags.delete(work.id);
        final deletedAt = tags.owed.single.updatedAt;
        tags.applyRemoteTag(
          work.copyWith(colour: Stamped('rose', 1)),
          deletedAt - 1,
        );
        expect(tags.byId(work.id), isNull);
        tags.applyRemoteTag(
          work.copyWith(name: Stamped('Office', deletedAt + 5)),
          deletedAt + 5,
        );
        expect(tags.byId(work.id)!.name.v, 'Office');
      },
    );

    test('signing out keeps the tags and owes every live one again', () {
      final work = tags.create('Work')!;
      final gone = tags.create('Gone')!;
      tags.addTag(noteId, work.id);
      tags.delete(gone.id);
      tags.keepUnknown('r1', {'kind': 'folder'}, 1);
      acknowledgeAll();
      expect(tags.owed, isEmpty);

      tags.forgetAccount();
      expect(namesOn(noteId), ['Work']);
      expect(tags.owed.map((r) => r.key).toSet(), {work.id, noteId});
      expect(jsonEncode((store.data['tags.v1'] as Map)['unknown']), '[]');
    });

    test('a note too long to send drops its oldest removed entries first', () {
      final ids = [for (var i = 0; i < 40; i++) tags.create('tag $i')!.id];
      tags.setTags(noteId, ids.sublist(0, 20));
      tags.setTags(noteId, ids.sublist(20));
      final payload = owedPayload(noteId)!;
      expect(
        utf8.encode(jsonEncode(payload)).length,
        lessThanOrEqualTo(4096 ~/ 4 * 3 - 16),
      );
      expect(tags.tagsOf(noteId).map((t) => t.id), ids.sublist(20));
      final kept = (payload['tags'] as Map).keys;
      expect(kept, containsAll(ids.sublist(20)));
      expect(kept.length, lessThan(40));
    });
  });
}
