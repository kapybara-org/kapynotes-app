import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/images/image_picker.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// A phone's photo library, recording what it was asked for.
class _Library extends ImagePickerPlatform with MockPlatformInterfaceMixin {
  final asked = <String>[];
  MediaOptions? media;
  MultiImagePickerOptions? images;
  Object? failure;

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async {
    asked.add('images');
    images = options;
    if (failure case final error?) throw error;
    return [XFile('/library/one.jpg')];
  }

  @override
  Future<List<XFile>> getMedia({required MediaOptions options}) async {
    asked.add('media');
    media = options;
    if (failure case final error?) throw error;
    return [XFile('/library/one.jpg'), XFile('/library/clip.mov')];
  }
}

void main() {
  late _Library library;

  setUp(() {
    library = _Library();
    final platform = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = library;
    addTearDown(() {
      ImagePickerPlatform.instance = platform;
      AppPlatform.debugTargetPlatformOverride = null;
    });
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    test('on ${platform.name} a picture is chosen from the library, with no '
        'question first', () async {
      AppPlatform.debugTargetPlatformOverride = platform;

      final files = await pickNoteImages();

      expect(files.map((file) => file.name), ['one.jpg']);
      expect(library.asked, ['images']);
      expect(library.images!.limit, 20);
    });
  }

  test('photos and videos come from one library screen, up to 20', () async {
    final files = await pickExistingMedia();

    expect(files.map((file) => file.name), ['one.jpg', 'clip.mov']);
    expect(library.asked, ['media']);
    expect(library.media!.allowMultiple, isTrue);
    expect(library.media!.limit, 20);
  });

  test('a library that fails gives back nothing', () async {
    library.failure = StateError('no library');

    expect(await pickExistingMedia(), isEmpty);
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    expect(await pickNoteImages(), isEmpty);
  });
}
