import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/sync/spaces.dart';
import 'package:kapy_notes/ui/join/joining_ui.dart';
import 'package:material_ui/material_ui.dart';

import 'share_dialog_test.dart' show Device, FakeSend, joiningOver, opener;
import 'sync/fake_server.dart';
import 'test_fonts.dart';

/// The phone share sheets as the sharing boards draw them, dark, on an
/// iPhone 15: the owner's sheet in P09's state and a viewer's in P16's.
void main() {
  late FakeServer server;
  late Device sanjay;
  late Device priya;

  setUpAll(loadTestFonts);

  setUp(() {
    server = FakeServer();
    sanjay = Device(server, userId: 'user-1', device: 'a');
    priya = Device(server, userId: 'user-2', device: 'b');
    server.user(sanjay.userId).name = 'Sanjay Rao';
    server.user(priya.userId).name = 'Priya Nair';
  });

  tearDown(() {
    sanjay.dispose();
    priya.dispose();
  });

  Future<Note> share(SpaceRole role) async {
    late Note note;
    await sanjay.boot();
    await priya.boot();
    note = sanjay.notes.create(body: 'Call with Arjun\nAgenda and follow-ups');
    await sanjay.sync.syncNow();
    await sanjay.sharing.shareNoteWithPeople(note.id, {priya.email: role});
    await priya.sharing.acceptInvite(server.outbox.single.token);
    await sanjay.sync.syncNow();
    await priya.sync.syncNow();
    return note;
  }

  Future<void> showSheet(WidgetTester tester, Note note, Device device) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    await tester.pumpWidget(
      JoiningScope.value(
        joining: joiningOver(FakeSend()),
        child: opener(device.notes.byId(note.id)!, device.sharing),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the owner’s sheet: one person typing, one invited, link off', (
    tester,
  ) async {
    late Note note;
    await tester.runAsync(() async {
      note = await share(SpaceRole.member);
      await sanjay.sharing.addPerson(
        note.id,
        'luca@example.com',
        role: SpaceRole.viewer,
      );
      sanjay.sync.resume();
      priya.sync.resume();
      await settle(server);
      priya.sync.reportTyping(note.id);
      await settle(server);
    });
    await showSheet(tester, note, sanjay);
    expect(find.text('Typing…'), findsOneWidget);
    expect(find.text('Invited'), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/share_sheet_owner_phone_dark.png'),
    );
  });

  testWidgets('a viewer’s sheet', (tester) async {
    late Note note;
    await tester.runAsync(() async {
      note = await share(SpaceRole.viewer);
    });
    await showSheet(tester, note, priya);
    expect(find.text('You can only view this note'), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/share_sheet_viewer_phone_dark.png'),
    );
  });
}
