import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/sync/spaces.dart';
import 'package:kapy_notes/ui/sharing_notice_listener.dart';
import 'package:material_ui/material_ui.dart';

import 'fake_server.dart';
import 'sharing_test.dart' show Person, now;

void main() {
  late FakeServer server;
  late Person alice;
  late Person bob;

  setUp(() {
    now = DateTime.utc(2026, 9, 1);
    server = FakeServer()..now = () => now;
    alice = Person(server, userId: 'user-1', device: 'alice-mac');
    bob = Person(server, userId: 'user-2', device: 'bob-phone');
  });

  tearDown(() {
    alice.dispose();
    bob.dispose();
  });

  Future<void> share(String body, {SpaceRole role = SpaceRole.member}) async {
    final note = alice.notes.create(body: body);
    await alice.sync.syncNow();
    alice.tick();
    await alice.sharing.shareNoteWith(note.id, email: bob.email, role: role);
  }

  Widget app() => MaterialApp(
    theme: KapyTheme.dark(),
    home: SharingNotices(sharing: bob.sharing, child: const Scaffold()),
  );

  testWidgets('a share accepted on its own is said, and Leave leaves it', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await alice.boot();
      await bob.boot();
      await share('One');
      await bob.sharing.acceptInvite(server.outbox.last.token);
      await alice.sync.syncNow();
      await bob.syncAndSettle();
    });
    await tester.pumpWidget(app());

    await tester.runAsync(() async {
      // View only, so it can't join One's space: a new invitation, which
      // Bob's device accepts on its own because he is already in Alice's.
      await share('Two', role: SpaceRole.viewer);
      await bob.sharing.refresh();
      await until(() => bob.sharing.invites.isEmpty);
      await alice.sync.syncNow();
      await bob.syncAndSettle();
    });
    await tester.pump();
    expect(find.text('Someone shared "Two" with you'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.text('Leave'));
      await until(() => bob.sharing.teams.length == 1, reason: 'never left');
      await bob.syncAndSettle();
    });
    await tester.pump();
    expect(find.text('Left. Your copy stays in your notes'), findsOneWidget);
    expect(bob.bodies, ['One', 'Two']);
    await tester.pumpAndSettle(const Duration(seconds: 10));
  });

  testWidgets('a share Bob accepted himself offers nothing to undo', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await alice.boot();
      await bob.boot();
    });
    await tester.pumpWidget(app());
    await tester.runAsync(() async {
      await share('One');
      await bob.sharing.acceptInvite(server.outbox.last.token);
      await alice.sync.syncNow();
      await bob.syncAndSettle();
    });
    await tester.pump();
    expect(find.text('Someone shared "One" with you'), findsOneWidget);
    expect(find.text('Leave'), findsNothing);
    await tester.pumpAndSettle(const Duration(seconds: 10));
  });
}
