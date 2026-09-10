import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/file_export.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/export/archive.dart';
import 'package:kapy_notes/export/archive_service.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Hands out a directory under the system temp, so the service writes real
/// files and the test can look at them.
class _FakePaths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _FakePaths(this.root);

  final Directory root;

  @override
  Future<String?> getTemporaryPath() async => Directory(
    '${root.path}/cache',
  ).create(recursive: true).then((d) => d.path);

  @override
  Future<String?> getApplicationDocumentsPath() async => Directory(
    '${root.path}/docs',
  ).create(recursive: true).then((d) => d.path);
}

/// Every call the picker channel was asked to make, and what it answers.
class _Picker {
  _Picker({this.answer, this.throws = false});

  /// The name the system reports, or null for a dismissal.
  final String? answer;
  final bool throws;

  final List<Map<Object?, Object?>> calls = [];

  /// Whether the file the picker was pointed at was actually there when it
  /// was asked — the whole reason the archive is written before the question.
  bool sourceExisted = false;

  void install() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(FileExport.channel, (call) async {
      final arguments = (call.arguments as Map).cast<Object?, Object?>();
      calls.add(arguments);
      sourceExisted = File(arguments['path']! as String).existsSync();
      if (throws) {
        throw PlatformException(code: 'write-failed', message: 'nope');
      }
      return answer;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(FileExport.channel, null),
    );
  }
}

Note _note(String id, String body) => Note(
  id: id,
  body: body,
  createdAt: DateTime.utc(2026, 8, 1),
  updatedAt: DateTime.utc(2026, 9, 1),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('kapy-export-test');
    PathProviderPlatform.instance = _FakePaths(root);
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() {
    AppPlatform.debugTargetPlatformOverride = null;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Directory cache() => Directory('${root.path}/cache');
  Directory documents() => Directory('${root.path}/docs');

  test(
    'a phone is asked where the export goes, and told nothing else',
    () async {
      final picker = _Picker(answer: 'Notes.zip')..install();

      final result = await NoteArchiveService(
        now: () => DateTime.utc(2026, 9, 11, 8),
      ).exportNotes([_note('a1', 'One'), _note('b2', 'Two')]);

      expect(result.status, ExportStatus.written);
      expect(result.noteCount, 2);
      // The message afterwards says how many notes, not where they went: the
      // person exporting chose that themselves.
      expect(result.chosenByUser, isTrue);

      expect(picker.calls, hasLength(1));
      expect(
        picker.calls.single['suggestedName'],
        'KapyNotes-export-2026-09-11.zip',
      );
      expect(picker.calls.single['mimeType'], 'application/zip');
      // The archive has to exist before the question can be asked — iOS copies
      // the file it is given, Android fills a stream from one.
      expect(picker.sourceExisted, isTrue);
    },
  );

  test('the temporary copy does not outlive the export', () async {
    _Picker(answer: 'Notes.zip').install();

    await NoteArchiveService().exportNotes([_note('a1', 'One')]);

    expect(cache().listSync(), isEmpty);
  });

  test('backing out of the picker leaves nothing behind', () async {
    _Picker(answer: null).install();

    final result = await NoteArchiveService().exportNotes([_note('a1', 'One')]);

    expect(result.status, ExportStatus.cancelled);
    expect(cache().listSync(), isEmpty);
    expect(
      documents().existsSync() ? documents().listSync() : const [],
      isEmpty,
    );
  });

  test(
    'a picker that could not write says so rather than claiming success',
    () async {
      _Picker(throws: true).install();

      final result = await NoteArchiveService().exportNotes([
        _note('a1', 'One'),
      ]);

      expect(result.status, ExportStatus.failed);
      expect(cache().listSync(), isEmpty);
    },
  );

  test('a build with no picker behind the channel still exports', () async {
    // No handler at all, which is what a platform this has not been wired for
    // looks like. Losing the export would be worse than choosing the folder,
    // so it goes to the documents folder and the caller is told to say where.
    final result = await NoteArchiveService(
      now: () => DateTime.utc(2026, 9, 11, 8),
    ).exportNotes([_note('a1', 'One')]);

    expect(result.status, ExportStatus.written);
    expect(result.chosenByUser, isFalse);
    expect(result.path, endsWith('KapyNotes-export-2026-09-11.zip'));
    expect(File(result.path!).existsSync(), isTrue);
    // Still cleaned up: the copy in the cache was only ever the offer.
    expect(cache().listSync(), isEmpty);
  });

  test('what it writes is a readable Kapy Notes archive', () async {
    late String saved;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(FileExport.channel, (call) async {
      final path = (call.arguments as Map)['path'] as String;
      // What the picker does with it: copy the bytes somewhere of its own.
      saved = '${root.path}/picked.zip';
      File(path).copySync(saved);
      return 'picked.zip';
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(FileExport.channel, null),
    );

    await NoteArchiveService().exportNotes([_note('a1', 'Weekly review')]);

    final contents = readExportArchiveFromBytes(File(saved).readAsBytesSync());
    expect(contents.isReadable, isTrue);
    expect(contents.markdown, hasLength(1));
    expect(contents.markdown.values.single, contains('Weekly review'));
  });
}
