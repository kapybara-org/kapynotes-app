import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/sync/spaces.dart';
import 'package:kapy_notes/ui/join/joining_ui.dart';
import 'package:material_ui/material_ui.dart';

import 'support/sharing_devices.dart'
    show Device, FakeSend, joiningOver, opener;
import 'sync/fake_server.dart';
import 'test_fonts.dart';

/// The share sheets as the sharing boards draw them, dark: the owner's in
/// P09's state and a viewer's in P16's, as a sheet on an iPhone 15 and as the
/// Mac's dialog (S02) in a desktop window.
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

  Future<void> showSheet(
    WidgetTester tester,
    Note note,
    Device device, {
    required Size size,
    required TargetPlatform platform,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    AppPlatform.debugTargetPlatformOverride = platform;
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

  for (final (surface, device, size, platform) in const [
    ('sheet', 'phone', Size(393, 852), TargetPlatform.iOS),
    ('dialog', 'mac', Size(1100, 720), TargetPlatform.macOS),
  ]) {
    testWidgets('the owner’s $surface: one person typing, one invited, link '
        'off, on a $device', (tester) async {
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
      await showSheet(tester, note, sanjay, size: size, platform: platform);
      expect(find.text('Typing…'), findsOneWidget);
      expect(find.text('Invited'), findsOneWidget);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/share_${surface}_owner_${device}_dark.png'),
      );
    });

    testWidgets('a viewer’s $surface on a $device', (tester) async {
      late Note note;
      await tester.runAsync(() async {
        note = await share(SpaceRole.viewer);
      });
      await showSheet(tester, note, priya, size: size, platform: platform);
      expect(find.text('You can only view this note'), findsOneWidget);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/share_${surface}_viewer_${device}_dark.png'),
      );
    });
  }
}
