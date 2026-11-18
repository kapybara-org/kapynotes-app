import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
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

    test('takes invisible and direction characters out', () {
      expect(cleanTitle('Trip\u202Egpj.exe'), 'Tripgpj.exe');
      expect(cleanTitle('\u2066Lisbon\u2069 trip\u200F'), 'Lisbon trip');
      expect(cleanTitle('Lis\u200Bbon\u200C trip\uFEFF\u2060'), 'Lisbon trip');
      expect(cleanTitle('Gym\tplan\u0000\u0007'), 'Gym plan');
      expect(cleanTitle('Gym \u202A\u202B\u202C\u202D   plan'), 'Gym plan');
      expect(cleanTitle('\u200B\u202E\u2067'), isNull);
    });

    test('nothing for a link, an address or markdown link syntax', () {
      for (final hostile in [
        'https://evil.example/login',
        'Read this http://evil.example',
        'Visit www.evil.example now',
        'Click [here](https://evil.example)',
        '[Lisbon trip] (https://evil.example)',
        'Lisbon trip](javascript:alert(1))',
        'ftp://files.example/notes',
        'mailto:someone',
        'Write to someone@evil.example',
        'Trip ht\u200Btps://evil.example',
        'Trip w\u200Bww.evil.example',
        '<https://evil.example>',
      ]) {
        expect(cleanTitle(hostile), isNull, reason: hostile);
      }
      expect(cleanTitle('Meeting with @sam'), 'Meeting with @sam');
    });

    test('nothing for a bare domain or an address the note would link', () {
      for (final hostile in [
        'evil.com',
        'Sign in at evil.com',
        'Lisbon trip evil.io/login',
        'Paypal.com account',
        'Server 10.0.0.1',
        'Router at 192.168.1.1 admin',
        'Trip evil\u200B.com',
        'Trip evil\u200C.com',
        'Trip ev\u200Dil.com',
        'Trip evil.\u2060com',
        'Trip **evil**.com',
        'Trip evil.com!',
      ]) {
        expect(cleanTitle(hostile), isNull, reason: hostile);
      }
      expect(
        cleanTitle('Notes on Node.js'),
        isNull,
        reason: 'a note draws Node.js as a link, so a title would too',
      );
      expect(cleanTitle('Release 2.0 plan'), 'Release 2.0 plan');
      expect(cleanTitle('Budget for 2026'), 'Budget for 2026');
    });

    test('keeps the joiners a script or an emoji spells with', () {
      expect(cleanTitle('برنامه\u200Cی سفر'), 'برنامه\u200Cی سفر');
      expect(cleanTitle('क्\u200Dष योजना'), 'क्\u200Dष योजना');
      expect(cleanTitle('👩\u200D💻 Coding notes'), 'Coding notes');
      expect(cleanTitle('Family 👨\u200D👩\u200D👧 trip'), 'Family trip');
      expect(cleanTitle('\u200CTrip\u200D plan'), 'Trip plan');
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

  test(
    'which notes this device may name is kept here, across launches',
    () async {
      final store = _MemoryStore();
      final notes = NotesStore(store);
      await notes.load();
      final made = notes.create(body: Note.blankBody, authored: false);
      final named = notes.create(body: Note.blankBody, authored: false);
      notes.stopNamingHere(named.id);
      final gone = notes.create(body: Note.blankBody, authored: false);
      notes.delete(gone.id);

      final again = NotesStore(store);
      await again.load();
      expect(again.namesHere(made.id), isTrue);
      expect(again.namesHere(named.id), isFalse);
      expect(again.namesHere(gone.id), isFalse);
      expect(store.data['notes.v2'].toString(), isNot(contains('nameHere')));
    },
  );

  test('a blank from an older build starts as New Note when reused', () {
    final notes = NotesStore(_MemoryStore());
    final old = notes.create(body: '\n');
    notes.startAsNew(old.id);
    expect(notes.byId(old.id)!.body, Note.blankBody);
    expect(notes.takeEdit(old.id), (start: 0, oldEnd: 1, newEnd: 9));

    final written = notes.create(body: 'Groceries');
    notes.startAsNew(written.id);
    expect(notes.byId(written.id)!.body, 'Groceries');
    final fresh = notes.create(body: Note.blankBody, authored: false);
    final before = notes.byId(fresh.id);
    notes.startAsNew(fresh.id);
    expect(notes.byId(fresh.id), same(before));
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

    test('names a note only on the device that made it', () {
      fakeAsync((async) {
        start(async);
        final at = DateTime(2026, 11, 18);
        notes.applyDoc(
          Note(
            id: 'from-the-phone',
            body: 'New Note\n$_trip',
            createdAt: at,
            updatedAt: at,
          ),
        );
        final synced = notes.byId('from-the-phone')!;
        expect(namer.willName(synced), isFalse);
        namer.typed(synced.id);
        async.elapse(const Duration(seconds: 5));
        namer.left(synced.id);
        expect(model.prompts, isEmpty);
        expect(notes.byId(synced.id)!.title, 'New Note');

        final mine = write(_trip);
        expect(namer.willName(mine), isTrue);
        namer.left(mine.id);
        expect(model.prompts, [_trip]);
      });
    });

    test('the person in the title names it, for good', () {
      fakeAsync((async) {
        start(async);
        final note = write(_trip);
        namer.left(note.id);
        expect(model.prompts, hasLength(1));
        namer.personNaming(note.id);
        model.answer('Lisbon trip');
        async.flushMicrotasks();
        expect(notes.byId(note.id)!.title, 'New Note');
        expect(namer.willName(note), isFalse);

        namer.typed(note.id);
        async.elapse(const Duration(seconds: 5));
        namer.left(note.id);
        expect(model.prompts, hasLength(1));
      });
    });

    test(
      'a pause running out while the person is in the title names nothing',
      () {
        fakeAsync((async) {
          start(async);
          final note = write(_trip);
          async.elapse(const Duration(seconds: 2));
          namer.personNaming(note.id);
          async.elapse(const Duration(seconds: 5));
          expect(model.prompts, isEmpty);
          expect(notes.byId(note.id)!.title, 'New Note');
        });
      },
    );

    test('never writes a title while it may not, even with one ready', () {
      fakeAsync((async) {
        start(async);
        final note = write(_trip);
        namer.left(note.id);
        mayName = false;
        model.answer('Lisbon trip');
        async.flushMicrotasks();
        expect(notes.byId(note.id)!.title, 'New Note');

        mayName = true;
        namer.left(note.id);
        model.answer('Lisbon trip');
        async.flushMicrotasks();
        expect(notes.byId(note.id)!.title, 'Lisbon trip');
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

    test(
      'says which new notes it will name, so the rest open on the title',
      () {
        fakeAsync((async) {
          start(async);
          final plain = notes.create(body: Note.blankBody, authored: false);
          final hidden = notes.create(body: Note.blankBody, hidden: true);
          final drawing = notes.create(body: Note.blankBody, authored: false);
          notes.setDrawingMode(drawing.id, drawing: true);
          expect(namer.willName(plain), isTrue);
          expect(namer.willName(hidden), isFalse);
          expect(namer.willName(notes.byId(drawing.id)!), isFalse);

          prefs.autoTitlesEnabled = false;
          expect(namer.willName(plain), isFalse);
          prefs.autoTitlesEnabled = true;

          model.reason = 'Needs a built-in on-device model';
          unawaited(namer.check());
          async.flushMicrotasks();
          expect(namer.willName(plain), isFalse);
        });
      },
    );

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

    test('off by default on Android, and can be turned on', () {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
      fakeAsync((async) {
        start(async);
        expect(prefs.autoTitlesEnabled, isFalse);
        expect(namer.isOn, isFalse);
        final note = write(_trip);
        expect(namer.willName(note), isFalse);
        namer.left(note.id);
        expect(model.prompts, isEmpty);

        prefs.autoTitlesEnabled = true;
        namer.left(note.id);
        expect(model.prompts, [_trip]);
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
