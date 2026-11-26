// Kapy AI Cloud's card when it won't answer, on the Mac and on a real phone
// or simulator: the panel on its own, over a Kapy AI that answers from the
// test and never from a model or the network.
//
//   flutter drive --driver test_driver/integration_test.dart \
//     --target integration_test/kapy_ai_notice_test.dart -d <device> \
//     --dart-define=KAPYNOTES_SYNC=false
//
// Signed out, signed in without Pro, and offline, each in the panel a Mac
// docks beside the note or the sheet a phone pulls up over it. It checks
// that nothing overflows, that each card offers what fits the person, and
// that only the offline one offers Try again. Each is a screenshot in
// build/screenshots, for a person to look at.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/kapy_ai/kapy_ai_panel.dart';
import 'package:material_ui/material_ui.dart';

import '../test/fake_kapy_ai.dart';
import 'screenshot.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final asked = DateTime(2026, 11, 26, 9, 41);
  const question = 'What is left on Call with Arjun?';

  for (final (name, pending, offers) in [
    (
      'signed-out',
      const KapyCloudLocked(signIn: true, upgrade: true),
      ['Sign in', 'Upgrade', 'Use your own account'],
    ),
    (
      'no-pro',
      const KapyCloudLocked(signIn: false, upgrade: true),
      ['Upgrade', 'Use your own account'],
    ),
    ('offline', const KapyOffline(), ['Try again']),
  ]) {
    testWidgets('Kapy AI Cloud, $name', (tester) async {
      kapyAiAvailable = true;
      final phone = AppPlatform.isMobile;
      final device = phone && AppPlatform.isAndroid
          ? FakeKapyAi.gemma
          : FakeKapyAi.appleIntelligence;
      final ai =
          FakeKapyAi(
            pro: pending is KapyOffline,
            deviceState: DeviceModelState(
              status: DeviceModelStatus.ready,
              model: device,
            ),
          )..set(
            model: KapyModel.cloud,
            current: KapyChat(
              id: 'c',
              title: question,
              createdAt: asked,
              updatedAt: asked,
              model: KapyModel.cloud,
              messages: [
                KapyMessage(
                  id: 'q',
                  role: KapyRole.user,
                  text: question,
                  at: asked,
                ),
              ],
            ),
            pending: switch (pending) {
              KapyCloudLocked(:final signIn, :final upgrade) => KapyCloudLocked(
                signIn: signIn,
                upgrade: upgrade,
                fallbacks: [device],
              ),
              _ => KapyOffline(fallback: device),
            },
          );
      final tapped = <String>[];
      final controller = KapyAiPanelController()..open();
      addTearDown(controller.dispose);
      final panel = KapyAiPanel(
        kapyAi: ai,
        controller: controller,
        compact: phone,
        inSheet: phone,
        noteTitle: (_) => 'Call with Arjun',
        onOpenNote: (_) {},
        onManageAccounts: () => tapped.add('Use your own account'),
        onSignIn: () => tapped.add('Sign in'),
        onUpgrade: () => tapped.add('Upgrade'),
        onClose: () {},
        now: () => asked,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: KapyTheme.dark(),
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            body: phone
                ? SafeArea(child: panel)
                : Align(
                    alignment: Alignment.centerRight,
                    child: SizedBox(width: 380, child: panel),
                  ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final notice = find.byKey(const ValueKey('kapy-ai-notice'));
      expect(notice, findsOneWidget);
      for (final label in ['Sign in', 'Upgrade', 'Use your own account']) {
        expect(
          find.descendant(of: notice, matching: find.text(label)),
          offers.contains(label) ? findsOneWidget : findsNothing,
          reason: label,
        );
      }
      expect(
        find.descendant(of: notice, matching: find.text('Try again')),
        pending is KapyOffline ? findsOneWidget : findsNothing,
      );
      await screenshot('kapy-ai-notice-$name-dark');

      for (final label in offers.where((label) => label != 'Try again')) {
        await tester.tap(
          find.descendant(of: notice, matching: find.text(label)),
        );
      }
      expect(tapped, offers.where((label) => label != 'Try again'));
    });
  }
}
