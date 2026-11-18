import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/auto_titles.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/data/note_format.dart';
import 'package:kapy_notes/data/notes_store.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'auto-titles-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;

  @override
  void putNow(String key, Object? value) => data[key] = value;
}

/// A model that answers what a test tells it to, when the test says so.
class FakeTitleModel implements TitleModel {
  String? reason;
  final List<String> prompts = [];
  Completer<String>? pending;

  @override
  Future<String?> unavailableReason() async => reason;

  @override
  Future<String> name({required String instructions, required String prompt}) {
    prompts.add(prompt);
    return (pending = Completer<String>()).future;
  }

  void answer(String text) => pending!.complete(text);
}

const String _trip =
    'Flights to Lisbon are 900 for two, the hotel near Alfama is 120 a night, '
    'and the train to Sintra is cheap';

void main() {
  group('cleanTitle', () {
    test('keeps a plain title, with a capital first', () {
      expect(cleanTitle('trip budget'), 'Trip budget');
      expect(cleanTitle('Gym plan'), 'Gym plan');
    });

    test('takes quotes, emoji, markdown and closing punctuation off', () {
      expect(cleanTitle('"Trip budget."'), 'Trip budget');
      expect(cleanTitle('“Lisbon trip” ✈️'), 'Lisbon trip');
      expect(cleanTitle('**Gym plan**!'), 'Gym plan');
      expect(cleanTitle('# Groceries:'), 'Groceries');
      expect(cleanTitle('Title: Weekly review'), 'Weekly review');
    });

    test('keeps an apostrophe inside a word', () {
      expect(cleanTitle("Mum's birthday"), "Mum's birthday");
    });

    test('at most six words and 48 characters', () {
      expect(
        cleanTitle('One two three four five six seven eight'),
        'One two three four five six',
      );
      final long = cleanTitle(
        'Extraordinarily comprehensive quarterly infrastructure modernisation',
      )!;
      expect(long.length, lessThanOrEqualTo(48));
      expect(long, isNot(endsWith(' ')));
    });

    test('the first line only, in the note’s own language', () {
      expect(cleanTitle('\nViaje a Lisboa\nMore text'), 'Viaje a Lisboa');
      expect(cleanTitle('東京の旅行'), '東京の旅行');
    });

    test('nothing for an empty answer, a refusal or New Note', () {
      expect(cleanTitle('  \n '), isNull);
      expect(cleanTitle("I'm sorry, I can't help with that."), isNull);
      expect(cleanTitle('I cannot name this note'), isNull);
      expect(cleanTitle('New note'), isNull);
      expect(cleanTitle('“…”'), isNull);
      expect(cleanTitle('x' * 200), isNull);
    });
  });

  group('when a note has enough to name', () {
    test('about fifteen words', () {
      expect(enoughToName(List.filled(14, 'word').join(' ')), isFalse);
      expect(enoughToName(List.filled(15, 'word').join(' ')), isTrue);
    });

    test('a heading with a line under it', () {
      expect(enoughToName('# Groceries\nmilk'), isTrue);
      expect(enoughToName('# Groceries'), isFalse);
      expect(enoughToName('milk\n# Groceries'), isFalse);
    });

    test('a lot of change is fewer than half the words in common', () {
      expect(changedALot(_trip, '$_trip and a day in Cascais'), isFalse);
      expect(
        changedALot(_trip, 'Squats, deadlifts and a long run on Sunday'),
        isTrue,
      );
    });

    test('the words come from under the title, without pictures', () {
      final note = Note(
        id: 'n',
        body: 'New Note\n\uFFFC$_trip',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      expect(textToName(note), _trip);
    });
  });

  group('a new note', () {
    test('is titled New Note on a line of its own, and counts as empty', () {
      final note = Note(
        id: 'n',
        body: Note.blankBody,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      expect(note.title, 'New Note');
      expect(note.hasDefaultTitle, isTrue);
      expect(note.isEmpty, isTrue);
      expect(note.copyWith(body: '${Note.blankBody}milk').isEmpty, isFalse);
      expect(note.copyWith(body: 'Trip\nmilk').hasDefaultTitle, isFalse);
    });

    test('turned into a drawing drops New Note', () {
      final notes = NotesStore(_MemoryStore());
      final note = notes.create(body: Note.blankBody, authored: false);
      expect(notes.setDrawingMode(note.id, drawing: true), isTrue);
      expect(notes.byId(note.id)!.body, '');
      expect(notes.byId(note.id)!.title, 'Drawing');
    });
  });

  test('retitle moves the formats and attachments after the title', () {
    final notes = NotesStore(_MemoryStore());
    final note = notes.create(body: 'New Note\nbold \uFFFC');
    notes.updateDocument(
      note.id,
      note.body,
      const [NoteFormatRange(start: 9, end: 13, format: NoteFormat.bold)],
      [
        NoteImageRef(
          offset: 14,
          hash: 'abc',
          key: Uint8List(32),
          mime: 'image/png',
          width: 1,
          height: 1,
          bytes: 1,
        ),
      ],
    );
    expect(notes.retitle(note.id, 'Trip'), isTrue);
    final named = notes.byId(note.id)!;
    expect(named.body, 'Trip\nbold \uFFFC');
    expect(named.title, 'Trip');
    expect(named.formats.single.start, 5);
    expect(named.formats.single.end, 9);
    expect(named.attachments.single.offset, 10);
    expect(notes.retitle(note.id, 'Trip'), isFalse);
  });

  group('NoteNamer', () {
    late NotesStore notes;
    late LayoutPrefs prefs;
    late FakeTitleModel model;
    late NoteNamer namer;
    var mayName = true;

    void start(FakeAsync async) {
      final store = _MemoryStore();
      notes = NotesStore(store);
      prefs = LayoutPrefs(store)..load();
      model = FakeTitleModel();
      mayName = true;
      namer = NoteNamer(
        notes: notes,
        prefs: prefs,
        model: model,
        mayName: (_) => mayName,
      );
      async.flushMicrotasks();
    }

    Note write(String words, {String title = 'New Note'}) {
      final note = notes.create(body: Note.blankBody, authored: false);
      notes.updateBody(note.id, '$title\n$words');
      namer.typed(note.id);
      return notes.byId(note.id)!;
    }

    test('names a new note after a pause in typing', () {
      fakeAsync((async) {
        start(async);
        final note = write(_trip);
        async.elapse(const Duration(seconds: 2));
        expect(model.prompts, isEmpty);
        async.elapse(const Duration(seconds: 2));
        expect(model.prompts, [_trip]);
        model.answer('"Lisbon trip budget."');
        async.flushMicrotasks();
        expect(notes.byId(note.id)!.title, 'Lisbon trip budget');
        expect(notes.byId(note.id)!.body, 'Lisbon trip budget\n$_trip');
      });
    });

    test('typing again restarts the pause', () {
      fakeAsync((async) {
        start(async);
        final note = write(_trip);
        async.elapse(const Duration(seconds: 2));
        namer.typed(note.id);
        async.elapse(const Duration(seconds: 2));
        expect(model.prompts, isEmpty);
        async.elapse(const Duration(seconds: 2));
        expect(model.prompts, hasLength(1));
      });
    });

    test('waits for enough to name', () {
      fakeAsync((async) {
        start(async);
        final note = write('milk and eggs');
        async.elapse(const Duration(seconds: 5));
        namer.left(note.id);
        expect(model.prompts, isEmpty);
      });
    });

    test('names a note on leaving it, without waiting', () {
      fakeAsync((async) {
        start(async);
        final note = write(_trip);
        namer.left(note.id);
        expect(model.prompts, [_trip]);
        async.elapse(const Duration(seconds: 5));
        expect(model.prompts, hasLength(1));
        model.answer('Lisbon trip');
        async.flushMicrotasks();
        expect(notes.byId(note.id)!.title, 'Lisbon trip');
      });
    });

    test('never replaces a title the person wrote', () {
      fakeAsync((async) {
        start(async);
        final note = write(_trip, title: 'My trip');
        async.elapse(const Duration(seconds: 5));
        namer.left(note.id);
        expect(model.prompts, isEmpty);
        expect(notes.byId(note.id)!.title, 'My trip');
      });
    });

    test('drops its answer when the person typed a title meanwhile', () {
      fakeAsync((async) {
        start(async);
        final note = write(_trip);
        namer.left(note.id);
        notes.updateBody(note.id, 'Our holiday\n$_trip');
        model.answer('Lisbon trip');
        async.flushMicrotasks();
        expect(notes.byId(note.id)!.title, 'Our holiday');
      });
    });

    test('never names a Hidden note', () {
      fakeAsync((async) {
        start(async);
        final note = write(_trip);
        notes.hide(note.id);
        namer.typed(note.id);
        async.elapse(const Duration(seconds: 5));
        namer.left(note.id);
        expect(model.prompts, isEmpty);
      });
    });

    test('never names a note this device may not write, or someone is in', () {
      fakeAsync((async) {
        start(async);
        mayName = false;
        final note = write(_trip);
        async.elapse(const Duration(seconds: 5));
        namer.left(note.id);
        expect(model.prompts, isEmpty);
      });
    });

    test('names only notes typed in here, so one device names each note', () {
      fakeAsync((async) {
        start(async);
        final synced = notes.create(body: 'New Note\n$_trip');
        namer.left(synced.id);
        async.elapse(const Duration(seconds: 5));
        expect(model.prompts, isEmpty);
      });
    });

    test('a failed, refused or slow model leaves New Note, silently', () {
      fakeAsync((async) {
        start(async);
        final note = write(_trip);
        namer.left(note.id);
        model.pending!.completeError(StateError('the model failed'));
        async.flushMicrotasks();
        expect(notes.byId(note.id)!.title, 'New Note');

        namer.left(note.id);
        model.answer("I'm sorry, I can't help with that.");
        async.flushMicrotasks();
        expect(notes.byId(note.id)!.title, 'New Note');

        namer.left(note.id);
        async.elapse(const Duration(seconds: 21));
        model.answer('Too late');
        async.flushMicrotasks();
        expect(notes.byId(note.id)!.title, 'New Note');
      });
    });

    test('one request at a time; the next note waits its turn', () {
      fakeAsync((async) {
        start(async);
        final first = write(_trip);
        final second = write('# Gym\nsquats on Monday');
        namer.left(first.id);
        namer.left(second.id);
        expect(model.prompts, hasLength(1));
        model.answer('Lisbon trip');
        async.flushMicrotasks();
        expect(model.prompts, hasLength(2));
        model.answer('Gym plan');
        async.flushMicrotasks();
        expect(notes.byId(first.id)!.title, 'Lisbon trip');
        expect(notes.byId(second.id)!.title, 'Gym plan');
      });
    });

    test('refreshes its own title once, on leaving, after a big change', () {
      fakeAsync((async) {
        start(async);
        final note = write(_trip);
        namer.left(note.id);
        model.answer('Lisbon trip');
        async.flushMicrotasks();

        const gym =
            'Squats and deadlifts on Monday, a long run on Wednesday, swimming '
            'on Friday and rest at the weekend';
        notes.updateBody(note.id, 'Lisbon trip\n$gym');
        namer.typed(note.id);
        async.elapse(const Duration(seconds: 5));
        expect(model.prompts, hasLength(1), reason: 'never while typing');

        namer.left(note.id);
        expect(model.prompts, hasLength(2));
        model.answer('Weekly gym plan');
        async.flushMicrotasks();
        expect(notes.byId(note.id)!.title, 'Weekly gym plan');

        notes.updateBody(note.id, 'Weekly gym plan\n$_trip');
        namer.typed(note.id);
        namer.left(note.id);
        expect(model.prompts, hasLength(2), reason: 'only once');
      });
    });

    test('a title the person edits is theirs from then on', () {
      fakeAsync((async) {
        start(async);
        final note = write(_trip);
        namer.left(note.id);
        model.answer('Lisbon trip');
        async.flushMicrotasks();
        notes.updateBody(note.id, 'Lisbon in May\nSquats on Monday and a run');
        namer.typed(note.id);
        namer.left(note.id);
        expect(model.prompts, hasLength(1));
      });
    });

    test('the setting off names nothing; on is the default', () {
      fakeAsync((async) {
        start(async);
        expect(prefs.autoTitlesEnabled, isTrue);
        expect(namer.isOn, isTrue);
        prefs.autoTitlesEnabled = false;
        expect(namer.isOn, isFalse);
        final note = write(_trip);
        async.elapse(const Duration(seconds: 5));
        namer.left(note.id);
        expect(model.prompts, isEmpty);
      });
    });

    test('without a model it is off, and says why', () {
      fakeAsync((async) {
        start(async);
        model.reason =
            'Turn on Apple Intelligence in System Settings to use this';
        unawaited(namer.check());
        async.flushMicrotasks();
        expect(namer.available, isFalse);
        expect(namer.isOn, isFalse);
        expect(namer.unavailableReason, model.reason);
        final note = write(_trip);
        namer.left(note.id);
        expect(model.prompts, isEmpty);

        model.reason = null;
        unawaited(namer.check());
        async.flushMicrotasks();
        expect(namer.isOn, isTrue);
      });
    });
  });

  test('a platform with no built-in model says so', () async {
    const none = NoTitleModel('Needs a built-in on-device model');
    expect(await none.unavailableReason(), 'Needs a built-in on-device model');
  });
}
