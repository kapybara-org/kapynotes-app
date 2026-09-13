import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import '../data/blob_store.dart';
import '../data/note_attachment.dart';
import '../sync/aead.dart';
import '../sync/sealed_box.dart';

/// The server's 25 MiB object ceiling minus the framing and authentication
/// bytes added when the local file is sealed.
const int maxVideoBytes =
    25 * 1024 * 1024 - 1 - SealedBox.nonceLength - SealedBox.macLength;

const Set<String> supportedVideoExtensions = {'mp4', 'm4v', 'mov'};

const Set<String> supportedVideoMimes = {
  'video/mp4',
  'video/x-m4v',
  'video/quicktime',
};

enum VideoRejection { tooLarge, tooMany, unsupported, unreadable, empty }

class VideoMetadata {
  const VideoMetadata({
    required this.width,
    required this.height,
    required this.durationMs,
  });

  final int width;
  final int height;
  final int durationMs;
}

typedef VideoMetadataReader = Future<VideoMetadata?> Function(File file);

class VideoBatch {
  const VideoBatch({required this.videos, required this.rejections});

  final List<NoteVideoRef> videos;
  final List<({String name, VideoRejection reason})> rejections;

  bool get isEmpty => videos.isEmpty;
}

/// Reads the dimensions and duration through the same native decoder that
/// will play the attachment. A container the current device cannot open is
/// rejected before it becomes a permanent blank block in the note.
Future<VideoMetadata?> readVideoMetadata(File file) async {
  final controller = VideoPlayerController.file(file);
  try {
    await controller.initialize();
    final value = controller.value;
    final width = value.size.width.round();
    final height = value.size.height.round();
    final durationMs = value.duration.inMilliseconds;
    if (!value.isInitialized ||
        value.hasError ||
        width <= 0 ||
        height <= 0 ||
        durationMs <= 0) {
      return null;
    }
    return VideoMetadata(width: width, height: height, durationMs: durationMs);
  } catch (error) {
    debugPrint('KapyNotes: video metadata could not be read: $error');
    return null;
  } finally {
    await controller.dispose();
  }
}

Future<VideoBatch> ingestVideoFiles(
  List<XFile> files, {
  required BlobStore store,
  VideoMetadataReader metadataReader = readVideoMetadata,
  int limit = 10,
}) async {
  final videos = <NoteVideoRef>[];
  final rejections = <({String name, VideoRejection reason})>[];

  for (final file in files.take(limit)) {
    // Native pickers normally supply a display name, but some document
    // providers expose only a path. The path still carries the container
    // suffix and is safer than rejecting a playable file as nameless.
    final name = _videoFileName(file);
    final extension = extensionForVideoFilename(name);
    if (extension == null) {
      rejections.add((name: name, reason: VideoRejection.unsupported));
      continue;
    }

    try {
      final length = await file.length();
      if (length == 0) {
        rejections.add((name: name, reason: VideoRejection.empty));
        continue;
      }
      if (length > maxVideoBytes) {
        rejections.add((name: name, reason: VideoRejection.tooLarge));
        continue;
      }
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        rejections.add((name: name, reason: VideoRejection.empty));
        continue;
      }
      if (bytes.length > maxVideoBytes) {
        rejections.add((name: name, reason: VideoRejection.tooLarge));
        continue;
      }

      final hash = await store.put(bytes, extension: extension);
      final stored = await store.fileFor(hash);
      final metadata = stored == null ? null : await metadataReader(stored);
      if (metadata == null) {
        rejections.add((name: name, reason: VideoRejection.unreadable));
        continue;
      }

      videos.add(
        NoteVideoRef(
          offset: 0,
          hash: hash,
          key: randomKey(),
          mime: mimeForVideoFilename(name),
          bytes: bytes.length,
          width: metadata.width,
          height: metadata.height,
          durationMs: metadata.durationMs,
        ),
      );
    } catch (error) {
      debugPrint('KapyNotes: could not add video $name: $error');
      rejections.add((name: name, reason: VideoRejection.unreadable));
    }
  }

  for (final file in files.skip(limit)) {
    rejections.add((
      name: _videoFileName(file),
      reason: VideoRejection.tooMany,
    ));
  }
  return VideoBatch(videos: videos, rejections: rejections);
}

String _videoFileName(XFile file) => file.name.isEmpty ? file.path : file.name;

String? extensionForVideoFilename(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return null;
  final extension = name.substring(dot + 1).toLowerCase();
  return supportedVideoExtensions.contains(extension) ? '.$extension' : null;
}

String mimeForVideoFilename(String name) {
  final extension = extensionForVideoFilename(name);
  return switch (extension) {
    '.mov' => 'video/quicktime',
    '.m4v' => 'video/x-m4v',
    _ => 'video/mp4',
  };
}

String describeVideoRejection(VideoRejection reason) => switch (reason) {
  VideoRejection.tooLarge => 'is larger than the 25 MB attachment limit',
  VideoRejection.tooMany => 'is beyond the 10-video selection limit',
  VideoRejection.unsupported => 'is not an MP4, M4V, or MOV video',
  VideoRejection.unreadable => 'is not a video this device can play',
  VideoRejection.empty => 'is empty',
};
