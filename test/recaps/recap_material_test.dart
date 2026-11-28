import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ai/retrieval.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/recaps/recap_material.dart';
import 'package:kapy_notes/recaps/recap_period.dart';

import 'recap_fixtures.dart';

void main() {
  final thursday = dayOf(DateTime(2026, 11, 19));

  ReadNote note(String title, String text) => ReadNote(
    id: title,
    title: title,
    text: text,
    edited: DateTime(2026, 11, 19),
  );

  void expectWithin(List<ReadNote> notes, RetrievalBudget budget) {
    expect(notes.length, lessThanOrEqualTo(budget.notes));
    for (final note in notes) {
      expect(note.text.length, lessThanOrEqualTo(budget.charsPerNote));
      expect(note.title.length, lessThanOrEqualTo(200));
    }
    expect(
      notes.fold(0, (sum, note) => sum + note.text.length),
      lessThanOrEqualTo(budget.chars),
    );
  }

  group('what a day gives', () {
    late RecapWorld world;

    setUp(() async {
      world = RecapWorld();
      world.tick('2026-11-18T08:00:00Z', () {
        world.note('trip', '2026-11-19T08:00:00Z', body: 'Trip\n☐ Book\n☐ Pay');
        world.note(
          'secret',
          '2026-11-19T09:00:00Z',
          body: 'Bank PIN 4321\n☐ Hidden task',
          attachments: [recapVoice(hash: 'hidden-call')],
          hidden: true,
        );
        world.note(
          'standup',
          '2026-11-19T10:00:00Z',
          body: '${NoteAttachmentRef.placeholder}\nStandup',
          attachments: [recapVoice()],
        );
        world.note('other', '2026-11-18T10:00:00Z', body: 'Yesterday');
      });
      world.tick('2026-11-19T12:00:00Z', () {
        world.note('trip', '2026-11-19T08:00:00Z', body: 'Trip\n☑ Book\n☐ Pay');
        world.note(
          'secret',
          '2026-11-19T09:00:00Z',
          body: 'Bank PIN 4321\n☑ Hidden task',
          attachments: [recapVoice(hash: 'hidden-call')],
          hidden: true,
        );
      });
      await world.load();
    });

    test('its visible notes, its tasks and its voice notes, as notes', () {
      final material = world.material(thursday);
      final sent = recapNotesFor(
        material.items,
        world.store,
        today: DateTime(2026, 11, 20),
      );
      expect(sent.map((n) => n.title), [
        'Trip',
        'Standup',
        'Pricing call',
        'Tasks',
      ]);
      final tasks = sent.last;
      expect(tasks.text, 'Done:\n- Book (Thu 19)\nStill open:\n- Pay (Thu 19)');
      final voice = sent[2];
      expect(voice.id, 'standup');
      expect(voice.text, contains('Summary: Pricing call'));
      expect(voice.text, contains('[0:10] We ship the annual plan first.'));
      expect(sent[1].text, 'Standup');
    });

    test('never a hidden note, its tasks or its recordings', () {
      final material = world.material(thursday);
      final sent = recapNotesFor(
        material.items,
        world.store,
        today: DateTime(2026, 11, 20),
      );
      final all = sent.map((n) => '${n.title}\n${n.text}').join('\n');
      expect(all, isNot(contains('PIN')));
      expect(all, isNot(contains('Hidden task')));
      expect(material.items.where((item) => item.note.id == 'secret'), isEmpty);
      expect(material.edited.keys, unorderedEquals(['trip', 'standup']));
    });

    test('and a note hidden after it was read stays on the device', () async {
      final material = world.material(thursday);
      world.note(
        'trip',
        '2026-11-19T08:00:00Z',
        body: 'Trip\n☑ Book\n☐ Pay',
        hidden: true,
      );
      await world.load();
      final sent = recapNotesFor(
        material.items,
        world.store,
        today: DateTime(2026, 11, 20),
      );
      expect(sent.map((n) => n.title), ['Standup', 'Pricing call']);
    });

    test('changes its fingerprint when a note changes', () async {
      final before = world.material(thursday).fingerprint;
      expect(world.material(thursday).fingerprint, before);
      world.note(
        'trip',
        '2026-11-19T11:00:00Z',
        body: 'Trip\n☑ Book\n☐ Pay\nHotel',
      );
      await world.load();
      expect(world.material(thursday).fingerprint, isNot(before));
    });
  });

  group('packing', () {
    const cloud = RetrievalBudget.cloud;

    test('takes the notes past twelve into one, title and opening each', () {
      final notes = [
        for (var i = 0; i < 20; i++)
          note('Note $i', 'Note $i\nOpening $i\nMore $i\n${'x' * (i * 10)}'),
      ];
      final packed = packRecap(notes, cloud);
      expectWithin(packed, cloud);
      expect(packed, hasLength(12));
      expect(packed.last.title, 'More notes');
      for (var i = 0; i < 9; i++) {
        expect(packed.last.text, contains('- Note $i: Opening $i / More $i'));
      }
      expect(packed.take(11).map((n) => n.title), [
        for (var i = 9; i < 20; i++) 'Note $i',
      ]);
    });

    test('cuts a note past 12,000 characters at a line', () {
      final long = note(
        'Long',
        'Long\n${List.filled(4000, 'line six').join('\n')}',
      );
      final packed = packRecap([long], cloud).single;
      expect(packed.text.length, lessThanOrEqualTo(12000));
      expect(packed.text, startsWith('Long\nline six'));
      expect(packed.text, endsWith('line six'));
    });

    test('trims every note to its opening before it leaves one out', () {
      final notes = [
        for (var i = 0; i < 12; i++)
          note('Note $i', 'Note $i\nOpening $i\n${'y' * 11000}'),
      ];
      final packed = packRecap(notes, cloud);
      expectWithin(packed, cloud);
      expect(packed, hasLength(12));
      for (var i = 0; i < 12; i++) {
        expect(packed[i].text, startsWith('Note $i\nOpening $i'));
      }
    });

    test('keeps a long title within the contract', () {
      final packed = recapNote('n', 'T' * 500, 'text', DateTime(2026));
      expect(packed.title.length, 200);
    });

    test("a device's smaller budget is kept too", () {
      final device = RetrievalBudget.device(10000);
      final packed = packRecap([
        for (var i = 0; i < 5; i++) note('Note $i', 'Note $i\n${'z' * 6000}'),
      ], device);
      expectWithin(packed, device);
      expect(packed, hasLength(5));
    });
  });

  test('a note in Recently deleted is no part of a recap', () async {
    final world = RecapWorld();
    world.tick('2026-11-18T08:00:00Z', () {
      world.note('kept', '2026-11-19T08:00:00Z', body: 'Kept\n☐ Book');
      world.note(
        'binned',
        '2026-11-19T09:00:00Z',
        body: 'Binned words\n☐ Gone task',
      );
    });
    final index = world.notes.indexWhere((note) => note.id == 'binned');
    world.notes[index] = world.notes[index].copyWith(
      archivedAt: DateTime.utc(2026, 11, 20),
      trashedAt: DateTime.utc(2026, 11, 20),
    );
    await world.load();
    final week = periodOf(DateTime(2026, 11, 19), RecapKind.week);

    final material = world.material(week);
    expect([
      for (final item in material.items) item.note.id,
    ], isNot(contains('binned')));
    expect(world.digest(week).counts.notes, 1);
  });
}
