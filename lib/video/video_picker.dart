import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart' as platform_picker;

import '../core/platform.dart';

typedef VideoFileAcquirer = Future<List<XFile>> Function();

const XTypeGroup videoTypeGroup = XTypeGroup(
  label: 'Videos',
  extensions: ['mp4', 'm4v', 'mov'],
  uniformTypeIdentifiers: ['public.movie'],
  mimeTypes: ['video/mp4', 'video/x-m4v', 'video/quicktime'],
);

/// Opens the platform's familiar video chooser. Phones use the photo library;
/// desktop keeps a multi-file open panel so several clips can be dropped into
/// the same note in one pass.
Future<List<XFile>> acquireNoteVideos() async {
  try {
    if (AppPlatform.isMobile) {
      final video = await platform_picker.ImagePicker().pickVideo(
        source: platform_picker.ImageSource.gallery,
      );
      return video == null ? const [] : [video];
    }
    return await openFiles(acceptedTypeGroups: const [videoTypeGroup]);
  } catch (error) {
    debugPrint('KapyNotes: video picker failed: $error');
    return const [];
  }
}
