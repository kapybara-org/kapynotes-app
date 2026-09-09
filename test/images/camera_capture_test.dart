import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/images/camera_capture.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('camera failure keeps Photos available and can retry', (
    tester,
  ) async {
    var cameraLoads = 0;
    var libraryOpens = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CameraCapturePage(
          loadCameras: () async {
            cameraLoads++;
            return const [];
          },
          chooseFromLibrary: () async {
            libraryOpens++;
            return const [];
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No camera was found on this device.'), findsOneWidget);
    expect(find.byKey(const ValueKey('camera-library')), findsOneWidget);
    expect(find.byKey(const ValueKey('camera-shutter')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('camera-library')));
    await tester.pumpAndSettle();
    expect(libraryOpens, 1);
    expect(find.text('No camera was found on this device.'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('camera-retry')));
    await tester.pumpAndSettle();
    expect(cameraLoads, 2);
  });

  testWidgets('Photos returns its selected files through the camera route', (
    tester,
  ) async {
    List<XFile>? selected;
    final existing = XFile.fromData(
      Uint8List.fromList([1, 2, 3]),
      name: 'existing.png',
      mimeType: 'image/png',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async {
                selected = await showNoteCamera(
                  context,
                  loadCameras: () async => const [],
                  chooseFromLibrary: () async => [existing],
                );
              },
              child: const Text('Open camera'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open camera'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('camera-library')));
    await tester.pumpAndSettle();

    expect(selected, hasLength(1));
    expect(selected!.single, same(existing));
    expect(find.byType(CameraCapturePage), findsNothing);
  });
}
