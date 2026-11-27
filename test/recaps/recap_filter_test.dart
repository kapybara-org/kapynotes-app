import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/recaps/recap_filter.dart';

import 'recap_fixtures.dart';

void main() {
  RecapFilter? back(RecapFilter filter, {bool whole = false}) =>
      RecapFilter.fromJson(
        filter.count,
        filter.m,
        filter.toBase64(),
        whole: whole,
      );

  test('its sets never change: records keep them', () {
    // FNV-1a of "a" is 0xe40c292c.
    expect([recapSlotOf('a', 2, 1024), recapSlotOf('b', 2, 1024)], [212, 1046]);
    expect(recapRiceBits(RecapFilter.roomyM), 9);
    final filter = RecapFilter.of(['a', 'b']).sized(300);
    expect((filter.count, filter.m), (2, RecapFilter.roomyM));
    expect(filter.toBase64(), '2VI1Khf/');
    expect(filter.mayHold('a'), isTrue);
    expect(filter.mayHold('b'), isTrue);
    expect(filter.mayHold('c'), isFalse);
    expect(filter.mayHold('trip'), isFalse);
    expect(filter.falseRate, 2 / 2048);
  });

  test('a whole recap\'s filter has a set of its own', () {
    expect(
      [
        recapSlotOf('a', 2, 1024, whole: true),
        recapSlotOf('b', 2, 1024, whole: true),
      ],
      [843, 1946],
    );
    final whole = RecapFilter.union([
      RecapFilter.of(['a']),
      RecapFilter.of(['b']),
    ])!.sized(300);
    expect(whole.toBase64(), '0e2peJ//');
    expect(['a', 'b'].every(whole.mayHold), isTrue);
    expect(whole.mayHold('c'), isFalse);
    final read = back(whole, whole: true)!;
    expect(['a', 'b'].every(read.mayHold), isTrue);
    expect(read.mayHold('c'), isFalse);
    expect(
      RecapFilter.union([
        RecapFilter.of(['a']).sized(300),
      ]),
      isNull,
      reason: 'a sized filter no longer knows its ids',
    );
  });

  test('holds the ids as they are until it is sized', () {
    final filter = RecapFilter.of(['a', 'b']);
    expect((filter.count, filter.m), (2, 0));
    expect(filter.mayHold('a'), isTrue);
    expect(filter.mayHold('c'), isFalse);
    expect(filter.falseRate, 0);
    expect(RecapFilter.of([for (var i = 0; i < 300; i++) '$i']).bytes, 435);
  });

  test('a set says what its coding, written out again, says', () {
    final ids = [for (var i = 0; i < 200; i++) 'note-$i'];
    for (final size in [1000, 200, 120]) {
      final filter = back(RecapFilter.of(ids).sized(size))!;
      final slots = {
        for (final id in ids) recapSlotOf(id, ids.length, filter.m),
      };
      expect(ids.every(filter.mayHold), isTrue, reason: '$size bytes');
      for (var i = 0; i < 5000; i++) {
        final id = 'other-$i';
        expect(
          filter.mayHold(id),
          slots.contains(recapSlotOf(id, ids.length, filter.m)),
          reason: '$size bytes: $id',
        );
      }
      expect(filter.falseRate, slots.length / (ids.length * filter.m));
    }
  });

  test('in less room, fewer slots a note, never a miss, and past that it '
      'holds every note', () {
    final ids = [for (var i = 0; i < 500; i++) 'note-$i'];
    var last = RecapFilter.roomyM;
    for (final size in [3000, 600, 300, 150]) {
      final filter = RecapFilter.of(ids).sized(size);
      expect(filter.bytes, lessThanOrEqualTo(size));
      expect(filter.m, lessThanOrEqualTo(last));
      last = filter.m;
      expect(ids.every(back(filter)!.mayHold), isTrue, reason: '$size bytes');
    }
    final none = RecapFilter.of(ids).sized(40);
    expect(none.falseRate, 1);
    expect(none.mayHold('anything'), isTrue);
    expect(none.toBase64(), '');
    expect(back(none), isNull, reason: 'a record reads it as no filter');
  });

  test('the first and the last slot, two notes in one slot and a gap of '
      'exactly 2^k all read back', () {
    const m = RecapFilter.roomyM;
    String find(bool Function(int slot) wanted, {String not = ''}) {
      for (var i = 0; ; i++) {
        final id = 'edge-$i';
        if (id != not && wanted(recapSlotOf(id, 2, m))) return id;
      }
    }

    final first = find((slot) => slot == 0);
    final last = find((slot) => slot == 2 * m - 1);
    final bySlot = <int, String>{};
    (String, String)? same;
    (String, String)? apart;
    for (var i = 0; same == null || apart == null; i++) {
      final id = 'pair-$i';
      final slot = recapSlotOf(id, 2, m);
      final other = bySlot[slot];
      if (same == null && other != null) same = (other, id);
      final before = bySlot[slot - (1 << recapRiceBits(m))];
      if (apart == null && before != null) apart = (before, id);
      bySlot[slot] = id;
    }
    for (final (a, b, how) in [
      (first, last, 'the first and the last slot'),
      (same.$1, same.$2, 'two notes in one slot'),
      (apart.$1, apart.$2, 'a gap of 2^k'),
    ]) {
      final filter = back(RecapFilter.of([a, b]).sized(300))!;
      expect(filter.m, m, reason: how);
      expect([a, b].every(filter.mayHold), isTrue, reason: how);
    }
    expect(
      back(RecapFilter.of([same.$1, same.$2]).sized(300))!.falseRate,
      1 / (2 * m),
      reason: 'two notes, one slot taken',
    );
  });

  test('holds no note where it read none', () {
    final empty = RecapFilter.of(const []).sized(300);
    expect(empty.count, 0);
    final read = back(empty)!;
    expect(read.mayHold('a'), isFalse);
    expect(empty.toBase64(), isNotEmpty, reason: 'its check bytes');
  });

  test('a set that does not read back exactly is no filter at all, never an '
      'empty one', () {
    final ids = [for (var i = 0; i < 30; i++) 'note-$i'];
    final filter = RecapFilter.of(ids).sized(300);
    final count = filter.count;
    final m = filter.m;
    final bits = filter.toBase64();
    final bytes = base64Decode(bits);
    String changed(void Function(Uint8List bytes) change) =>
        base64Encode(Uint8List.fromList(bytes)..apply(change));
    expect(ids.every(RecapFilter.fromJson(count, m, bits)!.mayHold), isTrue);
    for (final (what, c, k, b) in [
      ('a count that is not a number', '30', m, bits),
      ('a count below none', -1, m, bits),
      ('no slots a note', count, 0, bits),
      ('too many slots a note', count, RecapFilter.mMax + 1, bits),
      ('more slots than the coding reaches', 1 << 20, 1 << 12, bits),
      ('bits that are not text', count, m, 3),
      ('bits that are not base64', count, m, 'not base64!'),
      ('no bits', count, m, ''),
      ('one note more', count + 1, m, bits),
      ('one note fewer', count - 1, m, bits),
      ('twice the slots', count, m * 2, bits),
      ('half the slots', count, m ~/ 2, bits),
      ('cut short', count, m, base64Encode(bytes.sublist(0, bytes.length - 3))),
      ('run on', count, m, base64Encode([...bytes, 0xff, 0xff, 0xff])),
      ('a wrong check', count, m, changed((it) => it[0] ^= 1)),
      ('a changed gap', count, m, changed((it) => it[5] ^= 0x10)),
      ('padding that is not ones', count, m, changed((it) => it.last ^= 1)),
    ]) {
      expect(RecapFilter.fromJson(c, k, b), isNull, reason: what);
    }
  });
}

extension on Uint8List {
  void apply(void Function(Uint8List bytes) change) => change(this);
}
