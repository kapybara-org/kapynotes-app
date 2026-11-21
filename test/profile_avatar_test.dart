import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/sync/auth_api.dart';
import 'package:kapy_notes/ui/member_avatars.dart';
import 'package:kapy_notes/ui/profile_avatar.dart';
import 'package:kapy_notes/ui/spaces_rail.dart';
import 'package:material_ui/material_ui.dart';

const _photo =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

Widget _harness(Widget child) => MaterialApp(
  theme: KapyTheme.light(),
  home: Material(child: Center(child: child)),
);

Future<void> _pumpFace(WidgetTester tester, String name, {String? image}) =>
    tester.pumpWidget(
      _harness(ProfileAvatar(name: name, image: image, extent: 40)),
    );

String _shown(WidgetTester tester) => tester
    .widget<Text>(
      find.descendant(
        of: find.byType(ProfileAvatar),
        matching: find.byType(Text),
      ),
    )
    .data!;

void main() {
  testWidgets('a default face shows the first letter of the name', (
    tester,
  ) async {
    await _pumpFace(tester, 'Sam Rivera');
    expect(_shown(tester), 'S');
  });

  testWidgets('extra whitespace around and inside the name is skipped', (
    tester,
  ) async {
    await _pumpFace(tester, '  \n ada   lovelace ');
    expect(_shown(tester), 'A');
  });

  testWidgets('an empty name shows a neutral glyph', (tester) async {
    await _pumpFace(tester, '');
    expect(_shown(tester), '?');

    await _pumpFace(tester, ' \n\t ');
    expect(_shown(tester), '?');
  });

  testWidgets('somebody known only by email shows its first letter', (
    tester,
  ) async {
    await _pumpFace(tester, 'sam.rivera@example.com');
    expect(_shown(tester), 'S');

    // What displayName gives for them: the address before the @.
    const user = AccountUser(
      id: 'u1',
      email: 'jo@example.com',
      emailVerified: true,
    );
    await _pumpFace(tester, user.displayName);
    expect(_shown(tester), 'J');
  });

  test('the initial is a whole character from any script', () {
    expect(avatarInitial('🦫 Kapy'), '🦫');
    expect(avatarInitial('👩🏽‍💻 Dev'), '👩🏽‍💻');
    expect(avatarInitial('Ζωή Ν'), 'Ζ');
    expect(avatarInitial('李小龙'), '李');
    expect(avatarInitial('ßtraße'), 'ß');
  });

  test('words that open with punctuation are passed over', () {
    expect(avatarInitial('Ana (she/her)'), 'A');
    expect(avatarInitial('"Kapy" Notes'), 'N');
    expect(avatarInitial('(Ana) Silva'), 'S');
    expect(avatarInitial('- -'), '?');
  });

  testWidgets('no avatar asks a server for a face', (tester) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _harness(
        Row(
          children: [
            SizedBox(
              height: 760,
              child: SpacesRail(
                space: LibrarySpace.notes,
                onSelected: (_) {},
                onSettingsPressed: () {},
                onAccountPressed: () {},
                user: const AccountUser(
                  id: 'u1',
                  email: 'sam@example.com',
                  emailVerified: true,
                  name: 'Sam Rivera',
                ),
              ),
            ),
            const ProfileAvatar(name: 'Sam Rivera', extent: 32),
            const ProfileAvatar(name: '', extent: 32),
            const ProfileAvatar(name: 'Photo', image: _photo, extent: 32),
            const ProfileAvatar(
              name: 'Linked Photo',
              image: 'https://example.com/face.png',
              extent: 32,
            ),
            const AvatarStack(
              extent: 24,
              avatars: [
                StackedAvatar(id: 'a', name: 'Sam Rivera'),
                StackedAvatar(id: 'b', name: 'priya@example.com'),
              ],
            ),
          ],
        ),
      ),
    );

    final images = tester.widgetList<Image>(find.byType(Image));
    expect(images, hasLength(1));
    for (final image in images) {
      expect(image.image, isNot(isA<NetworkImage>()));
      expect(image.image, isA<MemoryImage>());
    }
    expect(find.text('S'), findsNWidgets(3));
    for (final text in ['?', 'L', 'P']) {
      expect(find.text(text), findsWidgets, reason: text);
    }
  });

  testWidgets('an uploaded photo is drawn instead of the initials', (
    tester,
  ) async {
    await _pumpFace(tester, 'Sam Rivera', image: _photo);
    final image = tester.widget<Image>(
      find.descendant(
        of: find.byType(ProfileAvatar),
        matching: find.byType(Image),
      ),
    );
    expect(image.image, isA<MemoryImage>());
    expect(find.text('S'), findsNothing);
  });
}
