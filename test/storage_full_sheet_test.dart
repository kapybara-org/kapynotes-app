import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/ui/storage_full_sheet.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);
  tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

  final key = Uint8List(32);
  final refs = <String, NoteAttachmentRef>{
    'video': NoteVideoRef(
      offset: 0,
      hash: 'v',
      key: key,
      mime: 'video/mp4',
      bytes: 1,
      width: 1280,
      height: 720,
      durationMs: 42000,
    ),
    'photo': NoteImageRef(
      offset: 0,
      hash: 'p',
      key: key,
      mime: 'image/jpeg',
      bytes: 1,
      width: 64,
      height: 64,
    ),
    'file': NoteFileRef(
      offset: 0,
      hash: 'f',
      key: key,
      mime: 'application/pdf',
      bytes: 1,
      name: 'quote.pdf',
    ),
  };

  /// Opens the sheet for [ref] and answers what it was closed with, once
  /// [close] is tapped.
  Future<bool> open(
    WidgetTester tester,
    NoteAttachmentRef ref, {
    required String close,
    void Function()? check,
  }) async {
    late Future<bool> answer;
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => answer = showStorageFullSheet(context, ref),
              child: const Text('add'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('add'));
    await tester.pumpAndSettle();
    check?.call();
    await tester.tap(find.byKey(ValueKey('storage-full-$close')));
    await tester.pumpAndSettle();
    return answer;
  }

  for (final MapEntry(key: kind, value: ref) in refs.entries) {
    testWidgets('on a phone, the $kind sheet names it and the phone', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
      final saw = await open(
        tester,
        ref,
        close: 'ok',
        check: () {
          expect(find.text("This $kind can't sync yet"), findsOneWidget);
          expect(
            find.text(
              'Your account has reached its storage limit. The $kind stays '
              "in this note on this phone, and goes to your other devices "
              "once there's room.",
            ),
            findsOneWidget,
          );
          expect(find.byType(AlertDialog), findsNothing);
          final see = tester.getRect(find.text('See storage'));
          final ok = tester.getRect(find.text('OK'));
          expect(see.right, lessThan(ok.left), reason: 'See storage first');
        },
      );
      expect(saw, isFalse);
    });
  }

  testWidgets('the middle sentence is the Pro sheet\'s, word for word', (
    tester,
  ) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
    await open(
      tester,
      refs['video']!,
      close: 'ok',
      check: () => expect(
        find.textContaining('Your account has reached its storage limit.'),
        findsOneWidget,
      ),
    );
  });

  testWidgets('See storage answers true', (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
    expect(await open(tester, refs['photo']!, close: 'see'), isTrue);
  });

  testWidgets('on a computer it is the centred alert, about this computer', (
    tester,
  ) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
    final saw = await open(
      tester,
      refs['file']!,
      close: 'see',
      check: () {
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.text("This file can't sync yet"), findsOneWidget);
        expect(find.textContaining('on this computer,'), findsOneWidget);
        expect(find.textContaining('phone'), findsNothing);
      },
    );
    expect(saw, isTrue);
  });
  for (final (name, theme, platform) in [
    ('phone_light', KapyTheme.light, TargetPlatform.iOS),
    ('phone_dark', KapyTheme.dark, TargetPlatform.iOS),
    ('desktop_dark', KapyTheme.dark, TargetPlatform.macOS),
  ]) {
    testWidgets('the storage-full sheet, $name', (tester) async {
      AppPlatform.debugTargetPlatformOverride = platform;
      final phone = platform == TargetPlatform.iOS;
      await tester.binding.setSurfaceSize(
        phone ? const Size(390, 420) : const Size(720, 420),
      );
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () =>
                      showStorageFullSheet(context, refs['video']!),
                  child: const Text('add'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('add'));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/storage_full_$name.png'),
      );
    });
  }
}
