// The phone's Kapy AI page (M04) on a real phone or simulator:
//
//   flutter drive --driver test_driver/integration_test.dart \
//     --target integration_test/kapy_ai_page_test.dart -d <device> \
//     --dart-define=KAPYNOTES_SYNC=false
//
// At the phone's own size and safe areas, in light and dark, at 1× and 2×
// text, with past chats and with none, it checks that nothing overflows,
// that every target is 44 × 44 pt to a finger, and that a chat and a
// question to start from each reach Kapy AI. Each state is a screenshot in
// build/screenshots, for a person to look at.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/kapy_ai/kapy_ai_page.dart';
import 'package:material_ui/material_ui.dart';

import '../test/fake_kapy_ai.dart';
import 'screenshot.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime(2026, 11, 19, 9);
  KapyMessage said(KapyRole role, String text) =>
      KapyMessage(id: '$role-$text', role: role, text: text, at: now);
  KapyChat chat(String id, String title, DateTime at, [String? answer]) =>
      KapyChat(
        id: id,
        title: title,
        createdAt: at,
        updatedAt: at,
        model: KapyModel.cloud,
        messages: [
          said(KapyRole.user, title),
          if (answer != null) said(KapyRole.assistant, answer),
        ],
      );
  final chats = [
    chat(
      'a',
      'What is left on Call with Arjun',
      DateTime(2026, 11, 19, 8, 58),
      'Send the deck and book the room for Thursday.',
    ),
    chat(
      'b',
      'What did I plan for this week?',
      DateTime(2026, 11, 19, 7, 40),
      'Three things: the offsite agenda, groceries and the Lisbon trip.',
    ),
    chat(
      'c',
      'Find my notes about Lisbon',
      DateTime(2026, 11, 18, 18, 20),
      '**Lisbon trip**: four days in May, with the hotel and the flights.',
    ),
    chat('d', 'Price of 40 seats a month', DateTime(2026, 11, 17, 10)),
    chat(
      'e',
      'Summarise the offsite notes',
      DateTime(2026, 11, 14, 16),
      'Room, lunch and the deck are booked.',
    ),
  ];

  for (final dark in [true, false]) {
    final mode = dark ? 'dark' : 'light';
    for (final scale in [1.0, 2.0]) {
      for (final empty in [false, true]) {
        final state = empty ? 'empty' : 'list';
        testWidgets('$state, $mode, at ${scale}x text', (tester) async {
          kapyAiAvailable = true;
          final ai = FakeKapyAi(
            pro: true,
            deviceState: AppPlatform.isAndroid
                ? const DeviceModelState(
                    status: DeviceModelStatus.ready,
                    model: FakeKapyAi.gemma,
                  )
                : const DeviceModelState(
                    status: DeviceModelStatus.builtIn,
                    model: FakeKapyAi.appleIntelligence,
                  ),
            chatList: empty ? const [] : chats,
          )..set(model: KapyModel.cloud);
          var opened = 0;
          await tester.pumpWidget(
            MaterialApp(
              theme: dark ? KapyTheme.dark() : KapyTheme.light(),
              debugShowCheckedModeBanner: false,
              home: Builder(
                builder: (context) {
                  final media = MediaQuery.of(context);
                  return MediaQuery(
                    data: media.copyWith(textScaler: TextScaler.linear(scale)),
                    child: Scaffold(
                      extendBody: true,
                      body: KapyAiPage(
                        kapyAi: ai,
                        onOpenChat: () => opened++,
                        account: const SizedBox.square(dimension: 32),
                        now: () => now,
                      ),
                      // M04's bar: 56 tall, 30 above the screen's edge on an
                      // iPhone with its 34 pt home indicator.
                      bottomNavigationBar: SizedBox(
                        height: media.padding.bottom - 4 + 56,
                      ),
                    ),
                  );
                },
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          final targets = [
            find.byKey(const ValueKey('sidebar-search-box')),
            if (empty)
              for (var i = 0; i < 3; i++)
                find.byKey(ValueKey('kapy-ai-page-example-$i'))
            else
              find.byKey(const ValueKey('kapy-ai-page-chat-a')),
          ];
          for (final finder in targets) {
            await tester.ensureVisible(finder);
            await tester.pumpAndSettle();
            final size = tester.getSize(finder);
            expect(
              size.width >= 44 && size.height >= 44,
              isTrue,
              reason: '$finder',
            );
          }
          await tester.drag(
            find.byKey(const ValueKey('kapy-ai-page-chats')),
            const Offset(0, 600),
          );
          await tester.pumpAndSettle();
          await screenshot('kapy-ai-page-${scale.toInt()}x-$state-$mode');

          if (empty) {
            await tester.tap(
              find.byKey(const ValueKey('kapy-ai-page-example-0')),
            );
            expect(ai.calls, [
              'newChat',
              'ask:What did I plan for this week?:',
            ]);
          } else {
            await tester.tap(find.text('Find my notes about Lisbon'));
            expect(ai.calls.last, 'openChat:c');
          }
          expect(opened, 1);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
