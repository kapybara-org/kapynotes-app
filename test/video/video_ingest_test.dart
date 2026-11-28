import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/blob_store.dart';
import 'package:kapy_notes/data/attachment_limits.dart';
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

  test('applies the active plan limit before opening a decoder', () async {
    var metadataReads = 0;
    final batch = await ingestVideoFiles(
      [
        await file('clip.mp4', [1, 2, 3]),
      ],
      store: store,
      attachmentMaxBytes: videoSealingOverhead + 2,
      metadataReader: (_) async {
        metadataReads++;
        return null;
      },
    );

    expect(batch.videos, isEmpty);
    expect(batch.rejections.single.reason, VideoRejection.tooLarge);
    expect(metadataReads, 0);
    expect(
      describeVideoRejection(
        VideoRejection.tooLarge,
        name: 'clip.mp4',
        attachmentMaxBytes: proAttachmentMaxBytes,
        bytes: 300 * 1024 * 1024,
      ),
      'clip.mp4 (300 MB) is too big to add. Videos can be up to 100 MB. '
      'Try a shorter clip.',
    );
  });

  test('a refusal says which others were left out with it, and falls back '
      'to "This video" when a picker gave no real name', () {
    expect(
      describeVideoRejection(
        VideoRejection.tooLarge,
        name: 'big.mp4',
        others: 2,
        bytes: 300 * 1024 * 1024,
      ),
      'big.mp4 and 2 others are too big to add. Videos can be up to 25 MB. '
      'Try shorter clips.',
    );
    expect(
      describeVideoRejection(
        VideoRejection.tooLarge,
        name:
            'image_picker_2B55E2FD-4F1A-4C6A-9F05-3D9C5E3C1B1E-1234-'
            '0000A1B2C3D4E5F6',
        bytes: 300 * 1024 * 1024,
      ),
      'This video (300 MB) is too big to add. Videos can be up to 25 MB. '
      'Try a shorter clip.',
    );
    expect(
      describeVideoRejection(VideoRejection.empty, name: 'a.mov', others: 1),
      'a.mov is empty. 1 more could not be added.',
    );
  });

  test('a clip just over the limit never reads as the limit itself', () {
    for (final bytes in [
      maxVideoSourceBytesFor(freeAttachmentMaxBytes) + 1,
      freeAttachmentMaxBytes + 1,
      freeAttachmentMaxBytes + 40000,
    ]) {
      expect(
        describeVideoRejection(
          VideoRejection.tooLarge,
          name: 'a.mp4',
          bytes: bytes,
        ),
        'a.mp4 (25.1 MB) is too big to add. Videos can be up to 25 MB. Try a '
        'shorter clip.',
        reason: '$bytes',
      );
    }
  });

  test('a five-minute clip from the iPhone library is refused by its own '
      'name and size, and never read into memory', () async {
    final pickerDirectory = await Directory.systemTemp.createTemp('picker');
    addTearDown(() => pickerDirectory.delete(recursive: true));
    final clip = File(
      '${pickerDirectory.path}/image_picker_2B55E2FD-4F1A-4C6A-9F05-3D9C5E3C1B1E-'
      '1234-0000A1B2C3D4E5F6IMG_0042.MOV',
    );
    final handle = await clip.open(mode: FileMode.write);
    await handle.truncate(300 * 1024 * 1024);
    await handle.close();
    var metadataReads = 0;

    final batch = await ingestVideoFiles(
      [XFile(clip.path)],
      store: store,
      metadataReader: (_) async {
        metadataReads++;
        return null;
      },
    );

    expect(batch.videos, isEmpty);
    expect(batch.rejections.single, (
      name: 'IMG_0042.MOV',
      reason: VideoRejection.tooLarge,
      bytes: 300 * 1024 * 1024,
    ));
    expect(metadataReads, 0);
    expect(await store.totalBytes(), 0);
    final first = batch.rejections.single;
    expect(
      describeVideoRejection(
        first.reason,
        name: first.name,
        bytes: first.bytes,
      ),
      'IMG_0042.MOV (300 MB) is too big to add. Videos can be up to 25 MB. '
      'Try a shorter clip.',
    );
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
