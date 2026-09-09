import 'package:file_selector/file_selector.dart';
import 'package:image_picker/image_picker.dart' as platform_picker;
import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
import '../data/note_attachment.dart';
import 'camera_capture.dart';
import 'image_codec.dart';
import 'image_ingest.dart';
import '../data/blob_store.dart';

/// Swappable at the UI boundary so launch and editor tests do not need a real
/// camera while still exercising the complete note-insertion path.
typedef ImageFileAcquirer = Future<List<XFile>> Function(BuildContext context);

/// What a batch of files turned into.
class ImageBatch {
  const ImageBatch({required this.images, required this.rejections});

  final List<NoteAttachmentRef> images;

  /// One entry per file that could not be added, named so the message can say
  /// which one and why.
  final List<({String name, ImageRejection reason})> rejections;

  bool get isEmpty => images.isEmpty;
  int get storedBytes => images.fold(0, (sum, ref) => sum + ref.bytes);
}

/// The file types the picker offers. Named rather than left open so the dialog
/// does not invite the user to choose a PDF and then refuse it.
const XTypeGroup imageTypeGroup = XTypeGroup(
  label: 'Images',
  extensions: [
    'png',
    'jpg',
    'jpeg',
    'webp',
    'gif',
    'bmp',
    'tif',
    'tiff',
    'heic',
    'heif',
  ],
  uniformTypeIdentifiers: ['public.image'],
  mimeTypes: ['image/*'],
);

/// Opens the system picker and returns what the user chose, unprocessed.
///
/// Split from [ingestFiles] so the drop target — which is handed files rather
/// than asking for them — can share everything after this point.
Future<List<XFile>> pickImageFiles() async {
  try {
    return await openFiles(acceptedTypeGroups: const [imageTypeGroup]);
  } catch (error) {
    debugPrint('KapyNotes: image picker failed: $error');
    return const [];
  }
}

/// Opens the right image entry point for the device.
///
/// A phone starts with the camera and keeps Photos inside the same surface.
/// Desktop keeps the familiar multi-file dialog because a built-in webcam is
/// neither universal nor usually the source of a picture added to a note.
Future<List<XFile>> acquireNoteImages(
  BuildContext context, {
  ImageLibraryPicker? chooseFromLibrary,
}) {
  if (!AppPlatform.isMobile) return pickImageFiles();
  return showNoteCamera(
    context,
    chooseFromLibrary: chooseFromLibrary ?? pickExistingImageFiles,
  );
}

/// Opens the native photo library and allows a small gallery in one pass.
Future<List<XFile>> pickExistingImageFiles() async {
  try {
    return await platform_picker.ImagePicker().pickMultiImage(
      limit: 20,
      requestFullMetadata: false,
    );
  } catch (error) {
    debugPrint('KapyNotes: photo library failed: $error');
    return const [];
  }
}

/// The result of Android handing a photo-library choice back after recreating
/// the app process.
class LostImageRecovery {
  const LostImageRecovery({this.files = const [], this.error});

  final List<XFile> files;
  final Object? error;
}

typedef LostImageRetriever = Future<LostImageRecovery> Function();

/// Collects a photo-library result whose original Future disappeared when
/// Android reclaimed the activity. Other platforms never need this step.
Future<LostImageRecovery> recoverLostImageFiles() async {
  if (!AppPlatform.isAndroid) return const LostImageRecovery();
  try {
    final response = await platform_picker.ImagePicker().retrieveLostData();
    return LostImageRecovery(
      files: response.files ?? const [],
      error: response.exception,
    );
  } catch (error) {
    debugPrint('KapyNotes: could not recover photo-library result: $error');
    return LostImageRecovery(error: error);
  }
}

/// Compresses and stores every file, keeping the order the user gave them in.
///
/// Order matters: several images added at once become a gallery, and the
/// gallery reads left to right in the order they were selected or dropped.
Future<ImageBatch> ingestFiles(
  List<XFile> files, {
  required BlobStore store,
  int limit = 20,
}) async {
  final images = <NoteAttachmentRef>[];
  final rejections = <({String name, ImageRejection reason})>[];

  for (final file in files.take(limit)) {
    final name = file.name;
    // Judged by what the decoder makes of the bytes, not by the extension —
    // but an obviously wrong extension is worth refusing before reading a
    // whole file into memory.
    final extension = name.contains('.')
        ? name.split('.').last.toLowerCase()
        : '';
    if (extension.isNotEmpty && !supportedImageExtensions.contains(extension)) {
      rejections.add((name: name, reason: ImageRejection.unreadable));
      continue;
    }

    try {
      final bytes = await file.readAsBytes();
      final result = await ingestImage(
        source: bytes,
        sourceMime: file.mimeType ?? mimeForFilename(name),
        store: store,
      );
      if (result.isOk) {
        images.add(result.image!.ref);
      } else {
        rejections.add((name: name, reason: result.rejection!));
      }
    } catch (error) {
      debugPrint('KapyNotes: could not read $name: $error');
      rejections.add((name: name, reason: ImageRejection.unreadable));
    }
  }

  for (final file in files.skip(limit)) {
    rejections.add((name: file.name, reason: ImageRejection.tooLarge));
  }

  return ImageBatch(images: images, rejections: rejections);
}

/// One line explaining why a file did not make it in.
String describeRejection(ImageRejection reason) => switch (reason) {
  ImageRejection.tooLarge => 'is too large to add',
  ImageRejection.unreadable => 'is not an image we can read',
  ImageRejection.empty => 'is empty',
};
