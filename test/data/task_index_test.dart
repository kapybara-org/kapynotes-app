import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/crdt/note_doc.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/task_index.dart';
import 'package:kapy_notes/data/task_lines.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'task-index-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

const noteId = '0195f0d0-1111-4222-8333-444455556666';

void write(NoteDoc doc, String body) => doc.reconcile(
  body: body,
  formats: const [],
  attachments: const [],
  createdAt: DateTime.utc(2026, 11, 1),
);

String idFor(String anchor) => 'id:$anchor';

void main() {
  late _MemoryStore store;
  late DateTime clock;
  late TaskIndex index;
  late NoteDoc doc;

  setUp(() {
    store = _MemoryStore();
    clock = DateTime.utc(2026, 11, 17, 9);
    index = TaskIndex(store, now: () => clock);
    doc = NoteDoc(replica: 'aaaaaaaaaaaa');
  });

  void reconcile() => index.reconcileNote(noteId, doc, idFor: idFor);

  TaskEntry entryWhoseLineReads(String words) {
    final lines = taskLines(doc.text);
    for (final entry in index.entries) {
      final offset = doc.lineOffsetOf(parseAnchor(entry.anchor)!)!;
      final line = lines.firstWhere((l) => l.start <= offset && offset <= l.end);
      if (doc.text.substring(line.textStart, line.end) == words) return entry;
    }
    throw StateError('no task reads $words');
  }

  group('checklist lines', () {
    test('both styles count, ticked or not, and only with words after the box', () {
      const text = '''Groceries
☐ Milk
☑ Bread
- [ ] Eggs
  * [x] Butter
☐
- [ ]  
- not a task
[ ] not one either''';
      final lines = taskLines(text);
      expect(
        [for (final l in lines) text.substring(l.textStart, l.end)],
        ['Milk', 'Bread', 'Eggs', 'Butter'],
      );
      expect([for (final l in lines) l.done], [false, true, false, true]);
    });
  });

  group('reconcile', () {
    test('an open line joins the end of the list in reading order; a ticked one does not', () {
      write(doc, '☐ First\n☑ Already done\n- [ ] Second');
      reconcile();

      final entries = index.entries.toList()
        ..sort((a, b) => a.position.compareTo(b.position));
      expect(entries, hasLength(2));
      expect(entries.first, entryWhoseLineReads('First'));
      expect(entries.last, entryWhoseLineReads('Second'));
      expect(entries.first.addedAt, clock.millisecondsSinceEpoch);
      expect(entries.first.enteredAt, 0, reason: 'never gone back in');
      expect(entries.first.words.v, wordsDigest('First'));
      expect(entries.first.id, idFor(entries.first.anchor));
      expect(index.owed, hasLength(2));
    });

    test('ticking and unticking in either style keeps the task and stamps when it was done', () {
      write(doc, '☐ Glyph\n- [ ] Markdown');
      reconcile();
      final ids = index.entries.map((e) => e.id).toSet();

      clock = clock.add(const Duration(hours: 1));
      write(doc, '☑ Glyph\n- [ ] Markdown');
      write(doc, '☑ Glyph\n- [x] Markdown');
      reconcile();
      expect(index.entries.map((e) => e.id).toSet(), ids);
      for (final entry in index.entries) {
        expect(entry.doneAt.v, clock.millisecondsSinceEpoch);
      }

      clock = clock.add(const Duration(hours: 1));
      write(doc, '☐ Glyph\n- [x] Markdown');
      reconcile();
      expect(entryWhoseLineReads('Glyph').doneAt, Stamped<int?>(null, clock.millisecondsSinceEpoch));
      expect(entryWhoseLineReads('Markdown').doneAt.v, isNotNull);
    });

    test('rewriting the words the task is anchored to keeps the task', () {
      write(doc, '☐ Call the bank\n☐ Pay rent');
      reconcile();
      final before = entryWhoseLineReads('Call the bank');

      write(doc, '☐ Email the bank\n☐ Pay rent');
      reconcile();
      expect(entryWhoseLineReads('Email the bank').id, before.id);
      expect(index.entries, hasLength(2));
    });

    test('a deleted line takes its task with it, and an edit elsewhere changes nothing', () {
      write(doc, 'Plan\n☐ Alpha\n☐ Bravo\n☐ Charlie');
      reconcile();
      final alpha = entryWhoseLineReads('Alpha');
      final charlie = entryWhoseLineReads('Charlie');

      write(doc, 'Plan\n☐ Alpha\n☐ Charlie');
      reconcile();
      write(doc, 'Plan for today\n☐ Alpha\n☐ Charlie');
      reconcile();
      expect(index.entries.map((e) => e.id).toSet(), {alpha.id, charlie.id});
      expect(entryWhoseLineReads('Alpha'), alpha);
      expect(index.owed.where((o) => o.entry == null), hasLength(1));
    });

    test('a line merged into the one above is no longer its own task', () {
      write(doc, '☐ Alpha\n☐ Bravo');
      reconcile();
      final alpha = entryWhoseLineReads('Alpha');

      write(doc, '☐ AlphaBravo');
      reconcile();
      expect(index.entries.map((e) => e.id), [alpha.id]);
    });

    test('a task whose anchor went with a rewritten stretch finds its line again by its words', () {
      write(doc, '☐ Alpha\n☐ Bravo\n☐ Charlie');
      reconcile();
      final bravo = entryWhoseLineReads('Bravo');
      index.update(bravo.copyWith(dot: Stamped(true, clock.millisecondsSinceEpoch)));

      // Ticked in two places at once, as an offline edit reaches the
      // document: one contiguous replacement from the first box to the last,
      // which takes Bravo's anchor and its newlines with it.
      write(doc, '☑ Alpha\n☐ Bravo\n☑ Charlie');
      reconcile();

      final found = entryWhoseLineReads('Bravo');
      expect(found.id, isNot(bravo.id));
      expect(found.dot.v, isTrue);
      expect(found.addedAt, bravo.addedAt);
      expect(index.byId(bravo.id), isNull);
      expect(index.entries, hasLength(3));
    });

    test('a line that stops being a checklist line stops being a task', () {
      write(doc, '☐ Alpha');
      reconcile();
      write(doc, 'Alpha');
      reconcile();
      expect(index.entries, isEmpty);
    });

    test('two records for one line become the older, with both histories', () {
      write(doc, '☐ Alpha');
      reconcile();
      final original = index.entries.single;
      // Another device met the line after its first word was retyped, before
      // it saw this record, and wrote its own under the new anchor.
      write(doc, '☐ Zalpha');
      final lines = taskLines(doc.text);
      final latecomer = TaskEntry(
        id: 'id:other',
        noteId: noteId,
        anchor: anchorKey(doc, lines.single),
        words: Stamped(wordsDigest('Zalpha'), original.addedAt + 5000),
        addedAt: original.addedAt + 5000,
        dot: Stamped(true, original.addedAt + 6000),
      );
      // Taken from the server, so not owed by this device.
      index.applyRemote(latecomer, original.addedAt + 6000);
      reconcile();

      final kept = index.entries.single;
      expect(kept.id, original.id);
      expect(kept.dot.v, isTrue);
      expect(kept.addedAt, original.addedAt);
      expect(index.owed.map((o) => o.id).toSet(), {original.id, 'id:other'});
    });

    test('a record whose anchor has not arrived yet is left alone', () {
      write(doc, '☐ Alpha');
      reconcile();
      final stranger = TaskEntry(
        id: 'id:x',
        noteId: noteId,
        anchor: 'bbbbbbbbbbbb:7',
        words: const Stamped('0000000000000000', 1),
        addedAt: 1,
      );
      index.applyRemote(stranger, 1);
      reconcile();
      expect(index.byId('id:x'), stranger);
    });

    test('a note that is gone takes every task with it', () {
      write(doc, '☐ Alpha\n☐ Bravo');
      reconcile();
      index.forgetNote(noteId);
      expect(index.entries, isEmpty);
      expect(index.owed.every((o) => o.entry == null), isTrue);
    });
  });

  group('merge', () {
    TaskEntry base({Map<String, Object?> extra = const {}}) => TaskEntry(
      id: 'id',
      noteId: noteId,
      anchor: 'aaaaaaaaaaaa:3',
      words: const Stamped('0000000000000000', 100),
      addedAt: 100,
      extra: extra,
    );

    test('field by field, the same whichever side merges', () {
      final phone = base().copyWith(
        dot: const Stamped(true, 200),
        enteredAt: 300,
        touchedAt: 300,
      );
      final laptop = base().copyWith(
        doneAt: const Stamped(250, 250),
        doNow: const Stamped(true, 240),
        touchedAt: 260,
      );
      final a = phone.merge(laptop);
      final b = laptop.merge(phone);
      expect(a, b);
      expect(a.dot.v, isTrue);
      expect(a.doneAt.v, 250);
      expect(a.doNow.v, isTrue);
      expect(a.enteredAt, 300);
      expect(a.touchedAt, 300);

      final tie = base().copyWith(dot: const Stamped(false, 200));
      expect(phone.merge(tie).dot, tie.merge(phone).dot);
    });

    test('keeps fields a later build wrote, through a round trip and a merge', () {
      final later = base(extra: {'snoozeUntil': 9});
      final payload = later.toPayload();
      final read = TaskEntry.fromPayload('id', payload)!;
      expect(read.extra, {'snoozeUntil': 9});
      expect(base().merge(read).toPayload()['snoozeUntil'], 9);
      expect(TaskEntry.fromPayload('id', {...payload, 'dot': true}), isNull);
    });
  });

  group('sync bookkeeping', () {
    test('an acknowledgement for an older write leaves the newer one owed', () {
      write(doc, '☐ Alpha');
      reconcile();
      final sent = index.owed.single;
      clock = clock.add(const Duration(seconds: 1));
      index.update(sent.entry!.copyWith(dot: Stamped(true, clock.millisecondsSinceEpoch)));
      index.acknowledge(sent.id, sent.updatedAt);
      expect(index.owed, hasLength(1));
      index.acknowledge(sent.id, index.owed.single.updatedAt);
      expect(index.owed, isEmpty);
    });

    test('a newer server copy merges into an owed one, which then outranks it', () {
      write(doc, '☐ Alpha');
      reconcile();
      final mine = index.entries.single;
      final theirs = mine.copyWith(doNow: const Stamped(true, 5));
      final serverAt = clock.millisecondsSinceEpoch + 10000;
      index.applyRemote(theirs, serverAt);
      final owed = index.owed.single;
      expect(owed.entry!.doNow.v, isTrue);
      expect(owed.updatedAt, greaterThan(serverAt));
    });

    test('a server delete older than a local change is outlived; a newer one wins', () {
      write(doc, '☐ Alpha');
      reconcile();
      final entry = index.entries.single;
      index.applyRemoteDelete(entry.id, 1);
      expect(index.byId(entry.id), isNotNull);
      index.applyRemoteDelete(entry.id, clock.millisecondsSinceEpoch + 1000);
      expect(index.byId(entry.id), isNull);
      expect(index.owed, isEmpty);
    });

    test('survives a reload, owed records and cursor included', () {
      write(doc, '☐ Alpha\n☐ Bravo');
      reconcile();
      index.recordCursor(7);
      index.markScanned();
      final again = TaskIndex(store, now: () => clock)..load();
      expect(again.entries.toSet(), index.entries.toSet());
      expect(again.owed.map((o) => o.id).toSet(), index.owed.map((o) => o.id).toSet());
      expect(again.cursor, 7);
      expect(again.scanned, isTrue);
    });
  });

  group('ids minted on this device', () {
    String localId(String anchor) => '${localTaskIdPrefix}x$anchor';

    test('a task under one goes without a stone', () {
      write(doc, '☐ Alpha\n☐ Bravo');
      index.reconcileNote(noteId, doc, idFor: localId);
      write(doc, '☐ Alpha');
      index.reconcileNote(noteId, doc, idFor: localId);

      expect(index.entries.single.id, startsWith(localTaskIdPrefix));
      expect(index.owed.map((o) => o.id), [index.entries.single.id]);
    });

    test('rekeying moves each task onto the account id, state and all, and '
        'owes nothing for the id it leaves', () {
      write(doc, '☐ Alpha\n☐ Bravo');
      index.reconcileNote(noteId, doc, idFor: localId);
      final alpha = entryWhoseLineReads('Alpha');
      clock = clock.add(const Duration(minutes: 1));
      index.update(
        alpha.copyWith(dot: Stamped(true, clock.millisecondsSinceEpoch)),
      );

      index.rekey((noteId, anchor) => idFor(anchor));

      expect(
        {for (final e in index.entries) e.id},
        {for (final e in index.entries) idFor(e.anchor)},
      );
      final moved = index.byId(idFor(alpha.anchor))!;
      expect(moved.dot.v, isTrue);
      expect(moved.addedAt, alpha.addedAt);
      expect(
        index.owed.map((o) => o.id).toSet(),
        {for (final e in index.entries) e.id},
      );
      expect(index.owed.every((o) => o.entry != null), isTrue);
    });
  });
}
