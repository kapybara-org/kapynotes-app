// What phone_sharing_test.dart and sharing_mac_test.dart share: the people
// on the fake sync server, the waits sharing work needs, and how a test reads
// the colour a person sees. Not a test file itself, so neither workflow runs
// it on its own.
//
// Every person here is a fake account on test/sync/fake_server.dart's
// server, so nothing signs in to a real account or reaches the network.
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/sync/sharing.dart';
import 'package:material_ui/material_ui.dart';

import '../test/sync/fake_server.dart' show FakeServer;
import 'screenshot.dart';

/// Sam is the person under test; Priya and Carol share with him. Each has a
/// whole name, so a question that names someone in full can be checked.
void namePeople(FakeServer server) {
  server.user('user-1')
    ..name = 'Sam Rivera'
    ..email = 'sam.rivera@example.com';
  server.user('user-2')
    ..name = 'Priya Nair'
    ..email = 'priya.nair@example.com';
  server.user('user-3')
    ..name = 'Carol Diaz'
    ..email = 'carol.diaz@example.com';
}

/// The newest invitation the fake server mailed to [email].
String tokenFor(FakeServer server, String email) =>
    server.outbox.lastWhere((sent) => sent.to == email).token;

/// Accepts the newest invitation to [email] on [sharing].
Future<void> accept(FakeServer server, Sharing sharing, String email) =>
    sharing.acceptInvite(tokenFor(server, email));

/// Lets what a tap opened arrive on the real clock, then settles.
Future<void> settleOnClock(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pumpAndSettle();
}

/// Taps [target] and lets the sharing work it starts finish on the real
/// clock, then settles.
Future<void> tapAndSettle(
  WidgetTester tester,
  Finder target, {
  int milliseconds = 400,
}) async {
  await tester.runAsync(() async {
    await tester.tap(target);
    await Future<void>.delayed(Duration(milliseconds: milliseconds));
  });
  await tester.pumpAndSettle();
}

/// Pumps on the real clock until [done], for at most four seconds.
///
/// Unlike pumpAndSettle, this leaves a toast up. On a device a toast's
/// lifetime is an animation (lib/core/toast.dart holds it still only under
/// flutter test), so pumpAndSettle runs it to the end and the toast is gone.
/// Wait for a toast, and for anything after it that has to find it, with
/// this.
Future<void> pumpUntil(WidgetTester tester, bool Function() done) async {
  for (var pass = 0; pass < 40 && !done(); pass++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
  }
}

/// Takes [name]'s screenshot once the frame has caught up with the last tap:
/// the live binding's marker where the test pressed has faded, and a toast
/// the tap brought up has finished fading in.
Future<void> settledShot(
  WidgetTester tester,
  String name, {
  bool device = false,
}) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 300)),
  );
  for (var frame = 0; frame < 3; frame++) {
    await tester.pump();
  }
  await screenshot(name, device: device);
}

/// Taps [target], then pumps on the real clock until [done], leaving any
/// toast the tap brings up on screen.
Future<void> tapUntil(
  WidgetTester tester,
  Finder target,
  bool Function() done,
) async {
  await tester.tap(target);
  await pumpUntil(tester, done);
}

/// An item of one of the sharing sheet's menus.
Finder menuItem(String label) => find.descendant(
  of: find.byType(PopupMenuItem<String>),
  matching: find.text(label),
);

/// A person's row in People with access, and the menu beside it.
Finder memberRow(String userId) => find.byKey(ValueKey('member-row-$userId'));
Finder memberMenu(String userId) => find.byKey(ValueKey('member-menu-$userId'));

/// The ask's answers.
final askOk = find.byKey(const ValueKey('sharing-ask-ok'));
final askCancel = find.byKey(const ValueKey('sharing-ask-cancel'));

/// The colour [target]'s words are drawn in, as laid out.
Color? inkOf(WidgetTester tester, Finder target) {
  final text = find
      .descendant(of: target, matching: find.byType(Text), matchRoot: true)
      .first;
  return tester
      .renderObject<RenderParagraph>(
        find.descendant(of: text, matching: find.byType(RichText)).first,
      )
      .text
      .style
      ?.color;
}

/// The app's warning colour.
Color warningColour(WidgetTester tester, Finder within) =>
    Theme.of(tester.element(within.first)).colorScheme.error;

/// Expects [target] on screen with its words out of the warning colour.
void expectNeutral(WidgetTester tester, Finder target, String what) {
  expect(target, findsOneWidget, reason: what);
  expect(
    inkOf(tester, target),
    isNot(warningColour(tester, target)),
    reason: '$what stays out of the warning colour',
  );
}
