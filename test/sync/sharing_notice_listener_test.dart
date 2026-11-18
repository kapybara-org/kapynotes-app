import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/sharing_notice_listener.dart';
import 'package:material_ui/material_ui.dart';

import 'fake_server.dart';
import 'sharing_pane_test.dart' show build;

void main() {
  testWidgets(
    'a note shared on its own is said in a toast that offers to leave',
    (tester) async {
      final server = FakeServer();
      final alice = build(server, userId: 'user-1');
      final bob = build(server, userId: 'user-2');
      final bobEmail = server.user('user-2').email;
      await tester.runAsync(() async {
        for (final (person, email) in [(alice, 'a@b.co'), (bob, 'b@b.co')]) {
          await person.notes.load();
          await person.account.restore();
          await person.account.signIn(email: email, password: 'x');
          await person.account.createPassphrase('a good passphrase $email');
        }
        final one = alice.notes.create(body: 'One');
        await alice.account.sync!.syncNow();
        await alice.account.sharing!.shareNoteWith(one.id, email: bobEmail);
        await bob.account.sharing!.acceptInvite(server.outbox.last.token);
        await alice.account.sync!.syncNow();
        await bob.account.sync!.syncNow();
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: KapyTheme.dark(),
          home: SharingNoticeListener(
            account: bob.account,
            child: const Scaffold(),
          ),
        ),
      );

      final heard = <String>[];
      bob.account.sharing!.notices.listen((n) => heard.add(n.message));
      await tester.runAsync(() async {
        final two = alice.notes.create(body: 'Two');
        await alice.account.sync!.syncNow();
        await alice.account.sharing!.shareNoteWith(two.id, email: bobEmail);
        await bob.account.sharing!.refresh();
        await until(
          () => bob.account.sharing!.invites.isEmpty,
          reason: 'the invitation was not accepted on its own',
        );
        await alice.account.sync!.syncNow();
        await bob.account.sync!.syncNow();
        await settle(server);
      });
      await tester.pump();
      // ignore: avoid_print
      print('DBGN heard=$heard bob=${bob.notes.notes.map((n) => '${n.body}@${n.spaceId}').toList()} teams=${bob.account.sharing!.teams.map((s) => s.id).toList()} alice=${alice.notes.notes.map((n) => '${n.body}@${n.spaceId}').toList()}');

      expect(find.text('Someone shared "Two" with you'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('Leave'));
        await until(
          () => bob.account.sharing!.teams.length == 1,
          reason: 'never left',
        );
      });
      await tester.pump();
      expect(find.text('Left. Your copy stays in your notes'), findsOneWidget);
      expect(bob.notes.notes.map((n) => n.body), containsAll(['One', 'Two']));

      alice.account.dispose();
      bob.account.dispose();
      await tester.pumpAndSettle(const Duration(seconds: 10));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
