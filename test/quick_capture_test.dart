import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/quick_capture.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note_format.dart';
import 'package:kapy_notes/data/notes_store.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'quick-capture-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

/// Answers the platform channel with [name], or with nothing at all when it
/// is null, the way a host with no handler registered does.
void stubLaunchIntent(String? name, {bool respond = true}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        QuickCapture.channel,
        respond ? (call) async => name : null,
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('filing a launch draft', () {
    late NotesStore notes;

    setUp(() {
      notes = NotesStore(_MemoryStore());
    });

    test('an ordinary launch turns the draft into a note of its own', () {
      notes.create(body: 'Groceries');

      final filed = QuickCapture.file(notes, 'Call the dentist', LaunchIntent.open);

      expect(notes.notes, hasLength(2));
      expect(filed.body, 'Call the dentist');
      expect(notes.notes.last.body, 'Groceries');
    });

    test('the Write widget carries the draft into the last note', () {
      final existing = notes.create(body: 'Groceries');

      final filed = QuickCapture.file(
        notes,
        'Call the dentist',
        LaunchIntent.continueWriting,
      );

      expect(notes.notes, hasLength(1));
      expect(filed.id, existing.id);
      // One blank line below what was there, exactly where opening the note
      // by hand would have put the caret.
      expect(filed.body, 'Groceries\n\nCall the dentist');
    });

    test('an empty draft leaves the last note exactly as it was', () {
      final existing = notes.create(body: 'Groceries');

      final filed = QuickCapture.file(notes, '', LaunchIntent.continueWriting);

      expect(notes.notes, hasLength(1));
      expect(filed.id, existing.id);
      expect(filed.body, 'Groceries');
      expect(filed.updatedAt, existing.updatedAt);
    });

    test('with nothing to carry on, it starts the first note', () {
      final filed = QuickCapture.file(
        notes,
        'Call the dentist',
        LaunchIntent.continueWriting,
      );

      expect(notes.notes, hasLength(1));
      expect(filed.body, 'Call the dentist');
    });

    test('carrying on keeps the formatting already in the note', () {
      final existing = notes.create(body: 'Groceries');
      notes.updateDocument(existing.id, 'Groceries', const [
        NoteFormatRange(start: 0, end: 9, format: NoteFormat.heading),
      ]);

      final filed = QuickCapture.file(notes, 'Milk', LaunchIntent.continueWriting);

      expect(filed.body, 'Groceries\n\nMilk');
      expect(filed.formats, const [
        NoteFormatRange(start: 0, end: 9, format: NoteFormat.heading),
      ]);
    });
  });

  group('asking the platform why the app is open', () {
    setUp(() {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
    });

    tearDown(() {
      AppPlatform.debugTargetPlatformOverride = null;
      stubLaunchIntent(null, respond: false);
    });

    test('reads a widget launch off the channel', () async {
      stubLaunchIntent('continueWriting');

      expect(await QuickCapture.launchIntent(), LaunchIntent.continueWriting);
    });

    test('anything else is an ordinary launch', () async {
      stubLaunchIntent(null);

      expect(await QuickCapture.launchIntent(), LaunchIntent.open);
    });

    test('a host that does not answer is an ordinary launch', () async {
      stubLaunchIntent(null, respond: false);

      expect(await QuickCapture.launchIntent(), LaunchIntent.open);
    });

    test('desktop never asks at all', () async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
      stubLaunchIntent('continueWriting');

      expect(await QuickCapture.launchIntent(), LaunchIntent.open);
    });
  });
}
