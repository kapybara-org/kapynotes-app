import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/blob_store.dart';
import 'package:kapy_notes/video/video_ingest.dart';

void main() {
  late Directory directory;
  late BlobStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('kapy-video-ingest');
    store = BlobStore(directory: directory);
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Future<XFile> file(String name, List<int> bytes) async {
    final stored = File('${directory.path}/$name');
    await stored.writeAsBytes(bytes);
    return XFile(stored.path);
  }

  test(
    'stores an MP4 and carries native playback metadata into its ref',
    () async {
      final bytes = Uint8List.fromList([0, 1, 2, 3, 4, 5]);
      final batch = await ingestVideoFiles(
        [await file('walkthrough.mp4', bytes)],
        store: store,
        metadataReader: (file) async {
          expect(file.path, endsWith('.mp4'));
          expect(await file.readAsBytes(), bytes);
          return const VideoMetadata(
            width: 1920,
            height: 1080,
            durationMs: 95000,
          );
        },
      );

      expect(batch.rejections, isEmpty);
      expect(batch.videos, hasLength(1));
      final video = batch.videos.single;
      expect(video.hash, BlobStore.hashOf(bytes));
      expect(video.key, hasLength(32));
      expect(video.mime, 'video/mp4');
      expect(video.bytes, bytes.length);
      expect(video.width, 1920);
      expect(video.height, 1080);
      expect(video.duration, const Duration(seconds: 95));
      expect(await store.read(video.hash), bytes);
    },
  );

  test('uses the container extension to preserve QuickTime playback', () async {
    final batch = await ingestVideoFiles(
      [
        await file('clip.MOV', [1]),
      ],
      store: store,
      metadataReader: (_) async =>
          const VideoMetadata(width: 4, height: 3, durationMs: 1000),
    );

    expect(batch.videos.single.mime, 'video/quicktime');
    expect(batch.videos.single.extension, '.mov');
    expect(
      (await store.fileFor(batch.videos.single.hash))!.path,
      endsWith('.mov'),
    );
  });

  test('rejects an unsupported container before opening a decoder', () async {
    var metadataReads = 0;
    final batch = await ingestVideoFiles(
      [
        await file('clip.avi', [1]),
      ],
      store: store,
      metadataReader: (_) async {
        metadataReads++;
        return null;
      },
    );

    expect(batch.videos, isEmpty);
    expect(batch.rejections.single.reason, VideoRejection.unsupported);
    expect(metadataReads, 0);
  });

  test(
    'reports files past the batch limit separately from oversized files',
    () async {
      final files = [
        for (var i = 0; i < 3; i++) await file('$i.mp4', [i + 1]),
      ];
      final batch = await ingestVideoFiles(
        files,
        store: store,
        limit: 2,
        metadataReader: (_) async =>
            const VideoMetadata(width: 4, height: 3, durationMs: 1000),
      );

      expect(batch.videos, hasLength(2));
      expect(batch.rejections.single.reason, VideoRejection.tooMany);
    },
  );
}
