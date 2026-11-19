import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/quick_capture.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note.dart';
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
void stubLaunchIntent(
  String? name, {
  bool respond = true,
  Duration after = Duration.zero,
}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        QuickCapture.channel,
        respond
            ? (call) async {
                if (after > Duration.zero) await Future<void>.delayed(after);
                return name;
              }
            : null,
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

      final filed = QuickCapture.file(
        notes,
        'Call the dentist',
        LaunchIntent.open,
      );

      expect(notes.notes, hasLength(2));
      expect(filed.body, 'Call the dentist');
      expect(notes.notes.last.body, 'Groceries');
    });

    test('every widget action carries on the last note, not a new one', () {
      final existing = notes.create(body: 'Groceries');

      for (final intent in [
        LaunchIntent.continueWriting,
        LaunchIntent.dictate,
        LaunchIntent.capture,
      ]) {
        expect(QuickCapture.file(notes, '', intent).id, existing.id);
      }
      expect(notes.notes, hasLength(1));
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

    test('a widget carries on the fixed startup note when one is selected', () {
      final fixed = notes.create(body: 'Inbox');
      notes.create(body: 'Edited more recently');

      final filed = QuickCapture.file(
        notes,
        'From the widget',
        LaunchIntent.continueWriting,
        target: fixed,
      );

      expect(filed.id, fixed.id);
      expect(filed.body, 'Inbox\n\nFrom the widget');
    });

    test('with nothing typed and nothing to carry on, it starts New Note', () {
      for (final intent in LaunchIntent.values) {
        final filed = QuickCapture.file(NotesStore(_MemoryStore()), '', intent);
        expect(filed.body, Note.blankBody, reason: intent.name);
      }
      final filed = QuickCapture.file(notes, '', LaunchIntent.dictate);
      expect(notes.namesHere(filed.id), isTrue, reason: 'named on this device');
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

      final filed = QuickCapture.file(
        notes,
        'Milk',
        LaunchIntent.continueWriting,
      );

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

    test('reads Dictate and Capture off the same channel', () async {
      stubLaunchIntent('dictate');
      expect(await QuickCapture.launchIntent(), LaunchIntent.dictate);

      stubLaunchIntent('capture');
      expect(await QuickCapture.launchIntent(), LaunchIntent.capture);
    });

    test('an action this version has never heard of opens normally', () async {
      // An app rolled back under a widget that outran it. Opening on the note
      // is the part of every action this version can still honour.
      stubLaunchIntent('teleport');

      expect(await QuickCapture.launchIntent(), LaunchIntent.open);
    });

    test('anything else is an ordinary launch', () async {
      stubLaunchIntent(null);

      expect(await QuickCapture.launchIntent(), LaunchIntent.open);
    });

    test('a host that does not answer is an ordinary launch', () async {
      stubLaunchIntent(null, respond: false);

      expect(await QuickCapture.launchIntent(), LaunchIntent.open);
    });

    test("a cold start's action comes with Dart's arguments", () async {
      stubLaunchIntent('capture');
      QuickCapture.startedWith(['dictate']);

      expect(await QuickCapture.launchIntent(), LaunchIntent.dictate);
      // Collected once: the next question is the channel's again.
      expect(await QuickCapture.launchIntent(), LaunchIntent.capture);
    });

    test(
      'an argument this version has never heard of opens normally',
      () async {
        stubLaunchIntent('capture');
        QuickCapture.startedWith(['teleport']);

        expect(await QuickCapture.launchIntent(), LaunchIntent.open);
        expect(await QuickCapture.launchIntent(), LaunchIntent.capture);
      },
    );

    test('with no arguments the channel is asked', () async {
      stubLaunchIntent('continueWriting');
      QuickCapture.startedWith(const []);

      expect(await QuickCapture.launchIntent(), LaunchIntent.continueWriting);
    });

    test('an answer after the deadline is kept for lateIntent', () async {
      stubLaunchIntent('dictate', after: const Duration(milliseconds: 700));

      expect(await QuickCapture.launchIntent(), LaunchIntent.open);
      expect(await QuickCapture.lateIntent(), LaunchIntent.dictate);
      // Collected once.
      expect(await QuickCapture.lateIntent(), LaunchIntent.open);
    });

    test('an answer on time leaves nothing late', () async {
      stubLaunchIntent('capture');

      expect(await QuickCapture.launchIntent(), LaunchIntent.capture);
      expect(await QuickCapture.lateIntent(), LaunchIntent.open);
    });

    test('a second late ask does not lose the first one\'s action', () async {
      stubLaunchIntent('capture', after: const Duration(milliseconds: 700));
      final first = QuickCapture.launchIntent();
      await Future<void>.delayed(const Duration(milliseconds: 450));
      stubLaunchIntent(null, after: const Duration(milliseconds: 700));

      expect(await first, LaunchIntent.open);
      expect(await QuickCapture.launchIntent(), LaunchIntent.open);
      expect(await QuickCapture.lateIntent(), LaunchIntent.capture);
    });

    test('desktop never asks at all', () async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
      stubLaunchIntent('continueWriting');

      expect(await QuickCapture.launchIntent(), LaunchIntent.open);
    });
  });
}
