import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ui/note_picks.dart';

void main() {
  const order = ['a', 'b', 'c', 'd', 'e'];

  test('a toggle from rest brings the open note along; after that it only '
      'adds or takes away the one clicked', () {
    final picks = NotePicks();
    picks.toggle('c', open: 'a');
    expect(picks.on, isTrue);
    expect(picks.ids, {'a', 'c'});
    picks.toggle('d', open: 'a');
    picks.toggle('a', open: 'a');
    expect(picks.ids, {'c', 'd'});
  });

  test('letting go of the last pick ends picking, and a toggle of the open '
      'note from rest picks nothing', () {
    final picks = NotePicks()..toggle('c', open: 'a');
    picks.toggle('a');
    picks.toggle('c');
    expect(picks.on, isFalse);
    expect(picks.ids, isEmpty);
    picks.toggle('a', open: 'a');
    expect(picks.on, isFalse);
    expect(picks.ids, isEmpty);
  });

  test('a range runs from the anchor, replaces the range before it and keeps '
      'every other pick', () {
    final picks = NotePicks();
    picks.extendTo(order, 'c', open: 'a');
    expect(picks.ids, {'a', 'b', 'c'});
    picks.extendTo(order, 'b', open: 'a');
    expect(picks.ids, {'a', 'b'});

    picks.toggle('e');
    picks.extendTo(order, 'c');
    expect(picks.ids, {'a', 'b', 'c', 'd', 'e'});
    picks.extendTo(order, 'd');
    expect(picks.ids, {'a', 'b', 'd', 'e'});
  });

  test('from rest with nothing open, a range begins where it is clicked', () {
    final picks = NotePicks()..extendTo(order, 'b');
    expect(picks.ids, {'b'});
  });

  test('a step moves the far end of the range, from the open note at rest, '
      'and stops at either end of the list', () {
    final picks = NotePicks();
    picks.step(order, 1, open: 'c');
    expect(picks.ids, {'c', 'd'});
    picks.step(order, 1, open: 'c');
    picks.step(order, 1, open: 'c');
    expect(picks.ids, {'c', 'd', 'e'});
    picks.step(order, -3, open: 'c');
    expect(picks.ids, {'b', 'c'});
  });

  test('a sweep picks nothing until it leaves the note it began on, then the '
      'run it covers, over what was picked before', () {
    final picks = NotePicks();
    picks.sweepFrom('b');
    picks.sweepTo(order, 'b');
    expect(picks.on, isFalse);
    expect(picks.ids, isEmpty);
    picks.sweepTo(order, 'd');
    expect(picks.ids, {'b', 'c', 'd'});
    picks.sweepTo(order, 'a');
    expect(picks.ids, {'a', 'b'});

    picks.sweepFrom('d');
    picks.sweepTo(order, 'e');
    expect(picks.ids, {'a', 'b', 'd', 'e'});
  });

  test('all picks the whole list; drop lets go of notes that left it, and '
      'ends picking once nothing is left', () {
    final picks = NotePicks()..all(order);
    expect(picks.ids, order.toSet());
    var heard = 0;
    picks.addListener(() => heard++);
    picks.drop(['z']);
    expect(heard, 0);
    picks.drop(['a', 'b', 'c']);
    expect(picks.ids, {'d', 'e'});
    expect(picks.on, isTrue);
    picks.drop(['d', 'e']);
    expect(picks.on, isFalse);
    expect(heard, 2);
  });

  test("start is the archive's Select: on, with nothing picked; clear ends "
      'it', () {
    final picks = NotePicks()..start();
    expect(picks.on, isTrue);
    expect(picks.ids, isEmpty);
    picks
      ..toggle('b')
      ..toggle('b');
    expect(picks.on, isTrue);
    picks.clear();
    expect(picks.on, isFalse);
  });

  test('the press goes the way it has moved furthest, once past the slop', () {
    expect(movesSideways(const Offset(1, 1), 1), isNull);
    expect(movesSideways(const Offset(3, 2), 1), isTrue);
    expect(movesSideways(const Offset(2, 3), 1), isFalse);
    expect(movesSideways(const Offset(2, -2), 1), isFalse);
  });
}
