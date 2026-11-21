// The phone's Kapy AI page (M04) on a real phone or simulator, before the
// bar that mounts it exists:
//
//   flutter test integration_test/kapy_ai_page_test.dart -d <device> \
//     --dart-define=KAPYNOTES_SYNC=false
//
// At the phone's own size and safe areas, at 1× and 2× text, it checks that
// nothing overflows, that every button is 44 × 44 pt to a finger, and that
// New chat, a chat and a question each reach Kapy AI. Each state is saved as
// a PNG for a person to look at: in --dart-define=KAPY_SHOTS=<folder> when
// given (a simulator can write to its Mac's disk), else in the app's
// documents folder, so pass --no-uninstall to keep them.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/kapy_ai/kapy_ai_page.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import '../test/fake_kapy_ai.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime(2026, 11, 19, 9);
  KapyChat chat(String id, String title, DateTime at) => KapyChat(
    id: id,
    title: title,
    createdAt: at,
    updatedAt: at,
    model: KapyModel.cloud,
    messages: const [],
  );

  for (final scale in [1.0, 2.0]) {
    testWidgets('at ${scale}x text', (tester) async {
      kapyAiAvailable = true;
      final ai = FakeKapyAi(
        pro: true,
        chatList: [
          chat(
            'a',
            'What is left on Call with Arjun',
            DateTime(2026, 11, 19, 8, 58),
          ),
          chat(
            'b',
            'What did I plan for this week?',
            DateTime(2026, 11, 19, 7, 40),
          ),
          chat(
            'c',
            'Find my notes about Lisbon',
            DateTime(2026, 11, 18, 18, 20),
          ),
          chat('d', 'Price of 40 seats a month', DateTime(2026, 11, 17, 10)),
          chat('e', 'Summarise the offsite notes', DateTime(2026, 11, 14, 16)),
        ],
      )..set(model: KapyModel.cloud);
      var opened = 0;
      final frame = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: frame,
          child: MaterialApp(
            theme: KapyTheme.dark(),
            debugShowCheckedModeBanner: false,
            home: Builder(
              builder: (context) {
                final media = MediaQuery.of(context);
                return MediaQuery(
                  data: media.copyWith(textScaler: TextScaler.linear(scale)),
                  child: Scaffold(
                    body: KapyAiPage(
                      kapyAi: ai,
                      onOpenChat: () => opened++,
                      onManageAccounts: () {},
                      account: const SizedBox.square(dimension: 32),
                      // M04's bar: 56 tall, 30 above the screen's edge on an
                      // iPhone with its 34 pt home indicator.
                      barClearance: media.padding.bottom - 4 + 56,
                      now: () => now,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final handle = tester.ensureSemantics();
      for (final finder in [
        find.byKey(const ValueKey('kapy-ai-page-new-chat')),
        find.byKey(const ValueKey('kapy-ai-page-send')),
        find.bySemanticsLabel('Answers with Kapy AI Cloud'),
        find.byKey(const ValueKey('kapy-ai-page-chat-a')),
      ]) {
        final size = tester.getSize(finder);
        expect(
          size.width >= 44 && size.height >= 44,
          isTrue,
          reason: '$finder',
        );
      }
      handle.dispose();

      const shots = String.fromEnvironment('KAPY_SHOTS');
      final folder = shots.isEmpty
          ? (await getApplicationDocumentsDirectory()).path
          : shots;
      Future<void> save(String name) async {
        await tester.pumpAndSettle();
        final boundary =
            frame.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(
          pixelRatio: tester.view.devicePixelRatio,
        );
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '$folder/kapy_ai_page_${scale.toInt()}x_$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
      }

      await save('list');

      await tester.tap(find.byKey(const ValueKey('kapy-ai-page-new-chat')));
      expect(ai.calls.last, 'newChat');

      await tester.tap(find.text('Find my notes about Lisbon'));
      expect(ai.calls.last, 'openChat:c');

      await tester.tap(find.byKey(const ValueKey('kapy-ai-page-field')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('kapy-ai-page-field')),
        'What is due on Friday?',
      );
      await save('typing');
      await tester.tap(find.byKey(const ValueKey('kapy-ai-page-send')));
      await tester.pumpAndSettle();
      expect(ai.calls.last, 'ask:What is due on Friday?:');
      expect(opened, 3);
      expect(tester.takeException(), isNull);

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Answers with Kapy AI Cloud'));
      await save('picker');
      expect(tester.takeException(), isNull);
    });
  }
}
