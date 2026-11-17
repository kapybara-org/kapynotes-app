import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ai/retrieval.dart';

import 'ai_fakes.dart';

void main() {
  const budget = RetrievalBudget.cloud;

  test('reads matching notes, best first, and counts them', () async {
    final store = await notesWith([
      noteJson('body', 'Groceries\nLisbon tram tickets'),
      noteJson('title', 'Lisbon trip\nflights and hotel'),
      noteJson('other', 'Berlin'),
      noteJson(
        'old',
        'Lisbon',
        updated: testNow.subtract(const Duration(days: 9)),
      ),
    ]);
    final result = retrieve(
      store: store,
      question: 'What did I plan for Lisbon?',
      budget: budget,
    );
    expect(result.notes.map((note) => note.id), ['title', 'old', 'body']);
    expect(result.matching, 3);
  });

  test('drops stop words and punctuation', () {
    expect(questionTerms('What did I plan for the trip to Lisbon?'), [
      'plan',
      'trip',
      'lisbon',
    ]);
    expect(questionTerms("Find my notes about Sam's party"), ['sam', 'party']);
  });

  test('a question of only stop words matches nothing', () async {
    final store = await notesWith([noteJson('a', 'What is this')]);
    final result = retrieve(
      store: store,
      question: 'what is it?',
      budget: budget,
    );
    expect(result.notes, isEmpty);
    expect(result.matching, 0);
  });

  test('reads yesterday\'s notes for "yesterday"', () async {
    final store = await notesWith([
      noteJson(
        'y',
        'Standup',
        updated: testNow.subtract(const Duration(days: 1)),
      ),
      noteJson('t', 'Standup two'),
    ]);
    final result = retrieve(
      store: store,
      question: 'Summarise what I wrote yesterday',
      budget: budget,
    );
    expect(result.notes.map((note) => note.id), ['y']);
  });

  test('reads archived notes and never hidden ones', () async {
    final store = await notesWith([
      noteJson('archived', 'Lisbon archive', archived: true),
      noteJson('hidden', 'Lisbon secret', hidden: true),
      noteJson('both', 'Lisbon both', hidden: true, archived: true),
    ]);
    final result = retrieve(store: store, question: 'Lisbon', budget: budget);
    expect(result.notes.map((note) => note.id), ['archived']);
    expect(result.matching, 1);
  });

  test('the chip note is read first, even without a hit', () async {
    final store = await notesWith([
      noteJson('lisbon', 'Lisbon'),
      noteJson('chip', 'Groceries'),
    ]);
    final withHits = retrieve(
      store: store,
      question: 'Lisbon',
      budget: budget,
      noteId: 'chip',
    );
    expect(withHits.notes.map((note) => note.id), ['chip', 'lisbon']);
    expect(withHits.matching, 2);

    final alone = retrieve(
      store: store,
      question: 'summarise this',
      budget: budget,
      noteId: 'chip',
    );
    expect(alone.notes.map((note) => note.id), ['chip']);
    expect(alone.matching, 1);
  });

  test('a hidden chip note is never read', () async {
    final store = await notesWith([noteJson('chip', 'Lisbon', hidden: true)]);
    final result = retrieve(
      store: store,
      question: 'Lisbon',
      budget: budget,
      noteId: 'chip',
    );
    expect(result.notes, isEmpty);
    expect(result.matching, 0);
  });

  test('keeps to the budget', () async {
    final long = 'Lisbon ${'x' * 20000}';
    final store = await notesWith([
      for (var i = 0; i < 15; i++) noteJson('n$i', long),
    ]);
    final cloud = retrieve(store: store, question: 'Lisbon', budget: budget);
    expect(cloud.notes, hasLength(4));
    expect(cloud.notes.every((note) => note.text.length <= 12000), isTrue);
    expect(
      cloud.notes.fold<int>(0, (sum, note) => sum + note.text.length),
      lessThanOrEqualTo(48000),
    );
    expect(cloud.matching, 15);

    final short = await notesWith([
      for (var i = 0; i < 15; i++) noteJson('n$i', 'Lisbon'),
    ]);
    expect(
      retrieve(store: short, question: 'Lisbon', budget: budget).notes,
      hasLength(12),
    );

    final device = retrieve(
      store: store,
      question: 'Lisbon',
      budget: RetrievalBudget.device(5000),
    );
    expect(device.notes, hasLength(1));
    expect(device.notes.single.text.length, 5000);
  });

  test('readableNotes drops a note hidden after it was read', () async {
    final store = await notesWith([
      noteJson('a', 'Lisbon'),
      noteJson('b', 'Lisbon two'),
    ]);
    final read = retrieve(
      store: store,
      question: 'Lisbon',
      budget: budget,
    ).notes;
    store.hide('a');
    expect(readableNotes(store, read).map((note) => note.id), ['b']);
  });
}
