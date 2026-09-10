import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/file_export.dart';

void answerWith(Future<Object?> Function(MethodCall) handler) {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(FileExport.channel, handler);
  addTearDown(
    () => messenger.setMockMethodCallHandler(FileExport.channel, null),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a name back means it was saved', () async {
    late MethodCall seen;
    answerWith((call) async {
      seen = call;
      return 'Weekly notes.zip';
    });

    final result = await FileExport.save(
      path: '/tmp/a.zip',
      suggestedName: 'a.zip',
      mimeType: 'application/zip',
    );

    expect(result.outcome, FileExportOutcome.saved);
    expect(result.name, 'Weekly notes.zip');
    expect(seen.method, 'save');
    expect((seen.arguments as Map)['path'], '/tmp/a.zip');
    expect((seen.arguments as Map)['suggestedName'], 'a.zip');
    expect((seen.arguments as Map)['mimeType'], 'application/zip');
  });

  test('nothing back means the picker was dismissed', () async {
    answerWith((call) async => null);
    final result = await FileExport.save(path: '/tmp/a.zip', suggestedName: 'a');
    expect(result.outcome, FileExportOutcome.cancelled);
  });

  test('a platform that tried and could not is a failure', () async {
    answerWith((call) async => throw PlatformException(code: 'write-failed'));
    final result = await FileExport.save(path: '/tmp/a.zip', suggestedName: 'a');
    expect(result.outcome, FileExportOutcome.failed);
  });

  test('no handler at all is unsupported, not a failure', () async {
    // The distinction the caller acts on: a platform this was never wired for
    // still gets its export, in a folder the app picks.
    final result = await FileExport.save(path: '/tmp/a.zip', suggestedName: 'a');
    expect(result.outcome, FileExportOutcome.unsupported);
  });
}
