import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:kapy_notes/data/blob_store.dart';
import 'package:kapy_notes/images/note_image_provider.dart';
import 'package:material_ui/material_ui.dart';

late Directory dir;
late BlobStore store;
late String hash;

/// Resolves one note image to completion, the way a real frame would.
///
/// Lives here rather than in the app because only a test needs it: outside
/// `runAsync` there is no way to drive an image that touches the disk.
Future<ui.Image> warmNoteImage(String hash, BlobStore store) {
  final completer = Completer<ui.Image>();
  final stream = NoteImageProvider(
    hash: hash,
    store: store,
  ).resolve(ImageConfiguration.empty);
  late ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      stream.removeListener(listener);
      if (!completer.isCompleted) completer.complete(info.image);
    },
    onError: (error, stack) {
      stream.removeListener(listener);
      if (!completer.isCompleted) completer.completeError(error, stack);
    },
  );
  stream.addListener(listener);
  return completer.future;
}

void main() {
  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('kapy-provider');
    store = BlobStore(directory: dir);
    final image = img.Image(width: 40, height: 30, numChannels: 3);
    img.fill(image, color: img.ColorRgb8(10, 120, 200));
    hash = await store.put(Uint8List.fromList(img.encodePng(image)));
  });

  tearDownAll(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  testWidgets('decodes bytes the store already holds', (tester) async {
    // Warmed before anything is built. An `ImageProvider` that reads a real
    // file can only finish under `runAsync`; resolved from an ordinary pump it
    // waits on I/O the fake clock never delivers, and the stalled entry is
    // what the cache then hands to everyone else. This is a property of the
    // test binding, not of the provider: the app has no fake clock.
    late final ui.Image decoded;
    await tester.runAsync(() async {
      decoded = await warmNoteImage(hash, store);
    });
    expect(decoded.width, 40);
    expect(decoded.height, 30);

    await tester.pumpWidget(
      MaterialApp(
        home: Image(image: NoteImageProvider(hash: hash, store: store)),
      ),
    );
    await tester.pump();
    expect(tester.widget<Image>(find.byType(Image)).image, isA<NoteImageProvider>());
  });

  testWidgets('reports a miss rather than hanging', (tester) async {
    Object? failure;
    await tester.runAsync(() async {
      try {
        await warmNoteImage('f' * 64, store);
      } catch (error) {
        failure = error;
      }
    });
    expect(failure, isNotNull);
  });
}
