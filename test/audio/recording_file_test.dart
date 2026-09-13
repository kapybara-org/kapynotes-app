import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/audio/recording_file.dart';
import 'package:kapy_notes/data/blob_store.dart';
import 'package:kapy_notes/data/note_attachment.dart';

/// Bytes standing in for a recording. What is under test is where they end
/// up, not whether anything could decode them.
Uint8List audio(int seed) =>
    Uint8List.fromList(List.generate(2048, (i) => (i * 7 + seed) & 0xFF));

void main() {
  late Directory dir;
  late BlobStore blobs;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('kapy-recording-file');
    blobs = BlobStore(directory: dir);
  });

  tearDown(() => dir.delete(recursive: true));

  test('a recording already here opens without asking anyone', () async {
    final hash = await blobs.put(
      audio(1),
      extension: NoteVoiceRef.voiceExtension,
    );
    var fetches = 0;

    final file = await openRecording(
      hash,
      blobs: blobs,
      fetch: (_) async {
        fetches++;
        return null;
      },
    );

    expect(file!.path, endsWith('$hash.m4a'));
    expect(fetches, 0);
  });

  test('one from another device is fetched once and kept as .m4a', () async {
    // The extension is not decoration: iOS picks its decoder from it, so a
    // recording kept as a bare hash is a file that exists and stays silent.
    final bytes = audio(2);
    final hash = BlobStore.hashOf(bytes);
    var fetches = 0;
    Future<Uint8List?> fetch(String wanted) async {
      fetches++;
      return wanted == hash ? bytes : null;
    }

    final file = await openRecording(hash, blobs: blobs, fetch: fetch);
    expect(file!.path, endsWith('$hash.m4a'));
    expect(await file.readAsBytes(), bytes);

    await openRecording(hash, blobs: blobs, fetch: fetch);
    expect(fetches, 1, reason: 'the second press is a disk read');
  });

  test('with no account, or nothing fetched, there is no file', () async {
    final hash = BlobStore.hashOf(audio(3));
    expect(await openRecording(hash, blobs: blobs), isNull);
    expect(
      await openRecording(hash, blobs: blobs, fetch: (_) async => null),
      isNull,
    );
  });

  test('bytes that are not the recording asked for are not kept', () async {
    final hash = BlobStore.hashOf(audio(4));
    final file = await openRecording(
      hash,
      blobs: blobs,
      fetch: (_) async => audio(5),
    );
    expect(file, isNull);
    expect(await blobs.totalBytes(), 0);
  });
}
