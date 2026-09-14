import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/sync/presence.dart';
import 'package:kapy_notes/sync/spaces.dart';
import 'package:kapy_notes/crdt/crdt.dart';
import 'package:kapy_notes/data/attachment_limits.dart';

SpaceMember member(
  String id,
  String email, {
  String name = '',
  SpaceRole role = SpaceRole.member,
  int joined = 1,
}) => SpaceMember(
  userId: id,
  email: email,
  name: name,
  role: role,
  joinedAt: DateTime.utc(2026, 9, joined),
  hasKey: true,
);

SpaceInvite invite(String email, {int day = 1}) => SpaceInvite(
  token: 'token-$email',
  email: email,
  expiresAt: DateTime.utc(2027),
  createdAt: DateTime.utc(2026, 9, day),
);

Space space({
  required String? name,
  List<SpaceMember> members = const [],
  List<SpaceInvite> invites = const [],
  bool hasLink = false,
}) => Space(
  id: 'space-1',
  kind: SpaceKind.team,
  name: name,
  ownerId: 'me',
  role: SpaceRole.owner,
  keyGeneration: 1,
  rotationPending: false,
  spaceKey: null,
  members: members,
  invites: invites,
  liveNotes: 1,
  hasLink: hasLink,
  createdAt: DateTime.utc(2026, 9, 1),
);

final me = member(
  'me',
  'sanjay@example.com',
  name: 'Sanjay Kholiya',
  role: SpaceRole.owner,
);

void main() {
  group('a member', () {
    test('goes by the name they chose, and by their address only without', () {
      final named = member('u', 'priya.s@example.com', name: 'Priya Shah');
      expect(named.displayName, 'Priya Shah');
      expect(named.firstName, 'Priya');
      expect(named.hasName, isTrue);

      // An account that never chose a name carries its address as one.
      final unnamed = member(
        'u',
        'priya.s@example.com',
        name: 'priya.s@example.com',
      );
      expect(unnamed.displayName, 'priya.s');
      expect(unnamed.hasName, isFalse);
      expect(member('u', 'x@example.com').displayName, 'x');
    });
  });

  group('a space', () {
    test('carries the owner-paid attachment ceiling through its cache', () {
      final encoded = space(name: 'Family').toJson()
        ..['attachmentMaxBytes'] = proAttachmentMaxBytes;

      expect(
        Space.fromJson(encoded)?.attachmentMaxBytes,
        proAttachmentMaxBytes,
      );
    });

    test('is called by its people, never by its placeholder', () {
      final bob = member('bob', 'bob@example.com', name: 'Bob Stone');
      final pair = space(name: 'With bob', members: [me, bob]);
      expect(pair.hasGeneratedName, isTrue);
      expect(pair.chosenName, isNull);
      expect(pair.titleFor('me'), 'Shared with Bob');
      // And to Bob, whose own address the placeholder was made from, it is
      // clear who owns and shared the space rather than naming Bob himself.
      expect(pair.titleFor('bob'), 'Shared by Sanjay');
    });

    test('counts everyone after the first as others', () {
      final people = [
        for (var i = 0; i < 6; i++)
          member(
            'u$i',
            'u$i@example.com',
            name: 'Person$i Surname',
            joined: i + 2,
          ),
      ];
      // The placeholder names the first invitee's address.
      expect(
        space(name: 'With u0', members: [me, ...people.take(2)]).titleFor('me'),
        'Shared with Person0 and Person1',
      );
      expect(
        space(name: 'With u0', members: [me, ...people]).titleFor('me'),
        'Shared with Person0 and 5 others',
      );
    });

    test('keeps a name somebody chose', () {
      final family = space(
        name: 'Family',
        members: [
          me,
          member('bob', 'bob@example.com', name: 'Bob'),
        ],
      );
      expect(family.hasGeneratedName, isFalse);
      expect(family.titleFor('me'), 'Family');
      expect(family.titleFor('bob'), 'Family');
      // A name of the placeholder's shape that names nobody in it was chosen.
      expect(
        space(name: 'With the team', members: [me]).titleFor('me'),
        'With the team',
      );
    });

    test('names an invitation by its address until it is accepted', () {
      final pending = space(
        name: 'With carol',
        members: [me],
        invites: [invite('carol@example.com')],
      );
      expect(pending.titleFor('me'), 'Shared with carol');
      expect(pending.peopleExcept('me').single.isInvited, isTrue);
      expect(space(name: null, members: [me]).titleFor('me'), 'Only you');
    });

    test(
      'made for a link, goes by the link until it has people, then by them',
      () {
        final waiting = space(
          name: kLinkSpaceName,
          members: [me],
          hasLink: true,
        );
        expect(waiting.hasGeneratedName, isTrue);
        expect(waiting.chosenName, isNull);
        expect(waiting.titleFor('me'), 'Anyone with the link');

        final bob = member('bob', 'bob@example.com', name: 'Bob Stone');
        final joined = space(
          name: kLinkSpaceName,
          members: [me, bob],
          hasLink: true,
        );
        expect(joined.titleFor('me'), 'Shared with Bob');
        expect(joined.titleFor('bob'), 'Shared by Sanjay');
      },
    );

    test('is not owed a trip home while a link could still bring people', () {
      // Its owner, a note, and nobody else yet.
      expect(
        space(name: kLinkSpaceName, members: [me], hasLink: true).owedTripHome,
        isFalse,
      );
      // With the link off, that is a space everyone has left.
      expect(space(name: kLinkSpaceName, members: [me]).owedTripHome, isTrue);
    });

    test('keeps knowing about its link through the cache', () {
      final cached = Space.fromJson(
        space(name: 'Family', hasLink: true).toJson(),
      );
      expect(cached?.hasLink, isTrue);
      // A server from before links kept spaces says nothing: no link.
      final old = space(name: 'Family', hasLink: true).toJson()
        ..remove('hasLink');
      expect(Space.fromJson(old)?.hasLink, isFalse);
    });

    test(
      'leads with its owner, and members join in order before invitations',
      () {
        final owner = member(
          'owner',
          'o@example.com',
          name: 'Olive',
          role: SpaceRole.owner,
          joined: 9,
        );
        final early = member('early', 'e@example.com', name: 'Eve', joined: 2);
        final late = member('late', 'l@example.com', name: 'Lee', joined: 5);
        final mixed = space(
          name: 'Team',
          members: [late, me, early, owner],
          invites: [invite('zed@example.com')],
        );
        expect(
          [for (final person in mixed.peopleExcept('me')) person.name],
          ['Olive', 'Eve', 'Lee', 'zed'],
        );
      },
    );

    test('tells two people with one first name apart', () {
      final alexA = member('a', 'a@example.com', name: 'Alex Park');
      final alexB = member('b', 'b@example.com', name: 'Alex Moss');
      final both = space(name: 'With a', members: [me, alexA, alexB]);
      expect(both.shortNameOf('a'), 'Alex Park');
      expect(both.shortNameOf('b'), 'Alex Moss');
      expect(both.shortNameOf('me'), 'Sanjay');
      expect(both.titleFor('me'), 'Shared with Alex Park and Alex Moss');
    });
  });

  group('an invitation received', () {
    PendingInvite pending({String? byName, String spaceName = 'With me'}) =>
        PendingInvite.fromJson({
          'token': 't',
          'spaceId': 'space-1',
          'spaceName': spaceName,
          'invitedBy': 'priya@example.com',
          'invitedByName': ?byName,
          'role': 'member',
          'expiresAt': '2027-01-01T00:00:00.000Z',
        })!;

    test('says who it is from by name where the server sent one', () {
      expect(pending(byName: 'Priya Shah').inviterDisplayName, 'Priya Shah');
      expect(pending().inviterDisplayName, 'priya@example.com');
      // A name that is only the address again is no name.
      expect(pending(byName: 'Priya@Example.com').invitedByName, isNull);
    });

    test('leaves out a placeholder space name, but not a chosen one', () {
      expect(pending().hasGeneratedSpaceName, isTrue);
      expect(pending(spaceName: kLinkSpaceName).hasGeneratedSpaceName, isTrue);
      expect(pending(spaceName: 'Family').hasGeneratedSpaceName, isFalse);
    });
  });

  group('a caret on the wire', () {
    test('round-trips as two anchors, and refuses anything malformed', () {
      const selection = AnchoredSelection(
        Anchor.start,
        Anchor(NodeId('device-a', 41)),
      );
      final json = selection.toJson();
      expect(json, [
        null,
        ['device-a', 41],
      ]);
      expect(AnchoredSelection.fromJson(json), selection);
      expect(AnchoredSelection.fromJson('nonsense'), isNull);
      expect(
        AnchoredSelection.fromJson([
          ['device-a', -1],
          null,
        ]),
        isNull,
      );
      expect(
        AnchoredSelection.fromJson([
          ['', 3],
          null,
        ]),
        isNull,
      );
    });
  });
}
