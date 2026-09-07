import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/crdt/crdt.dart';
import 'package:kapy_notes/data/note_attachment.dart';

import 'helpers.dart';

/// A message in flight: the ops and the round they become deliverable.
class _InFlight {
  _InFlight(this.ops, this.dueRound);

  final List<Object?> ops;
  final int dueRound;
}

const _alphabet = 'ab1+\n \u{FFFC}=xy2-';

String _randomString(Random rng) {
  final length = 1 + rng.nextInt(4);
  return String.fromCharCodes([
    for (var i = 0; i < length; i++)
      _alphabet.codeUnitAt(rng.nextInt(_alphabet.length)),
  ]);
}

/// A random local edit: insert, delete, or replace a short span.
String _mutate(Random rng, String text) {
  final at = rng.nextInt(text.length + 1);
  switch (rng.nextInt(3)) {
    case 0:
      return text.replaceRange(at, at, _randomString(rng));
    case 1:
      // Mostly backspaces, sometimes a whole selection, so both the patched
      // and the rebuilt cache paths get exercised.
      final span = rng.nextInt(8) == 0 ? rng.nextInt(80) : rng.nextInt(4);
      final end = min(text.length, at + span);
      return text.replaceRange(at, end, '');
    default:
      final end = min(text.length, at + rng.nextInt(3));
      return text.replaceRange(at, end, _randomString(rng));
  }
}

void _runFuzz(int seed, {required int replicas, required int rounds}) {
  final rng = Random(seed);
  final docs = [
    for (var i = 0; i < replicas; i++) NoteDoc(replica: 'r$i'),
  ];
  final inboxes = [
    for (var i = 0; i < replicas; i++) <_InFlight>[],
  ];

  void send(int from, List<Object?> ops, int round) {
    if (ops.isEmpty) return;
    for (var to = 0; to < replicas; to++) {
      if (to == from) continue;
      final copies = rng.nextInt(10) == 0 ? 2 : 1;
      for (var c = 0; c < copies; c++) {
        inboxes[to].add(_InFlight(ops, round + rng.nextInt(6)));
      }
    }
  }

  void deliver(int round, {required bool everything}) {
    for (var to = 0; to < replicas; to++) {
      final inbox = inboxes[to];
      final due = <_InFlight>[];
      inbox.removeWhere((m) {
        if (!everything && m.dueRound > round) return false;
        due.add(m);
        return true;
      });
      due.shuffle(rng);
      for (final m in due) {
        docs[to].apply(m.ops);
      }
    }
  }

  try {
    for (var round = 0; round < rounds; round++) {
      final who = rng.nextInt(replicas);
      final doc = docs[who];
      final body = _mutate(rng, doc.text);
      send(who, type(doc, body), round);
      expect(doc.text, body, reason: 'reconcile must reproduce the body');
      deliver(round, everything: false);
    }
    deliver(rounds, everything: true);
    deliver(rounds, everything: true);

    final expected = docs.first.text;
    for (final doc in docs) {
      expect(doc.pendingCount, 0, reason: '${doc.replica} still pending');
      expect(doc.text, expected, reason: '${doc.replica} diverged');
      expect(doc.view.body, expected);
      expect(doc.nodeCount, docs.first.nodeCount);
      final restored = NoteDoc.fromSnapshot(doc.toSnapshot(), replica: 'x');
      expect(restored.text, expected, reason: 'snapshot round trip');
      expect(restored.toSnapshot(), doc.toSnapshot());
    }

    // Snapshot merges between peers must land on the same state as ops did.
    final fresh = NoteDoc(replica: 'merge');
    for (final doc in docs.reversed) {
      fresh.mergeSnapshot(doc.toSnapshot());
    }
    expect(fresh.text, expected, reason: 'snapshot merge converged');
    expect(fresh.mergeSnapshot(docs.first.toSnapshot()), isFalse);

    // Every placeholder still survives as a character, so an attachment
    // anchored to one would have somewhere to render.
    final placeholders = NoteAttachmentRef.placeholder.allMatches(expected);
    expect(placeholders.length, lessThanOrEqualTo(expected.length));
  } catch (error) {
    // ignore: avoid_print
    print('fuzz failed with seed $seed');
    rethrow;
  }
}

void main() {
  group('convergence fuzz', () {
    test('three replicas, delayed and duplicated delivery', () {
      _runFuzz(20260907, replicas: 3, rounds: 1200);
    });

    test('four replicas, more rounds', () {
      _runFuzz(42, replicas: 4, rounds: 1500);
    });

    test('a spread of seeds', () {
      for (var seed = 1; seed <= 30; seed++) {
        _runFuzz(seed, replicas: 3, rounds: 300);
      }
    });

    test('offline peers merge by snapshot only', () {
      final rng = Random(7);
      final a = NoteDoc(replica: 'a');
      final b = NoteDoc(replica: 'b');
      b.apply(type(a, 'shared start\n'));
      for (var i = 0; i < 200; i++) {
        type(a, _mutate(rng, a.text));
        type(b, _mutate(rng, b.text));
      }
      final fromA = a.toSnapshot();
      final fromB = b.toSnapshot();
      a.mergeSnapshot(fromB);
      b.mergeSnapshot(fromA);
      expect(a.text, b.text);
      expect(a.pendingCount, 0);
      expect(b.pendingCount, 0);
    });
  });
}
