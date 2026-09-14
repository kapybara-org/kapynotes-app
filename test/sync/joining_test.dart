import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/sync/joining.dart';
import 'package:kapy_notes/sync/spaces.dart';
import 'package:kapy_notes/sync/sync_api.dart';

const token = 'AbCdEfGhIjKlMnOpQrStUv';

/// A `send` that records every call and answers from a script.
class FakeSend {
  final calls = <(String, String, Map<String, Object?>?)>[];
  final answers = <String, Object>{};

  Future<Map<String, Object?>> call(
    String method,
    String path, {
    Map<String, Object?>? payload,
  }) async {
    calls.add((method, path, payload));
    final answer = answers['$method $path'];
    if (answer is Exception) throw answer;
    return (answer as Map<String, Object?>?) ?? const {};
  }
}

void main() {
  group('reading a link', () {
    test('the site links, both kinds', () {
      expect(
        parseJoinTarget('https://kapynotes.com/join/$token'),
        const InviteTarget(token),
      );
      expect(
        parseJoinTarget('https://kapynotes.com/space/$token'),
        const SpaceLinkTarget(token),
      );
      expect(
        parseJoinTarget('https://www.kapynotes.com/space/$token/'),
        const SpaceLinkTarget(token),
      );
    });

    test("the app's own scheme, which is what the page's button opens", () {
      expect(
        parseJoinTarget('kapynotes://join/$token'),
        const InviteTarget(token),
      );
      expect(
        parseJoinTarget('kapynotes://space/$token'),
        const SpaceLinkTarget(token),
      );
    });

    test(
      'a bare token is an invitation, as the paste box has always taken it',
      () {
        expect(parseJoinTarget('  $token  '), const InviteTarget(token));
      },
    );

    test('anything else is nothing', () {
      for (final input in [
        '',
        'hello',
        'https://evil.example/space/$token',
        'https://kapynotes.com/space/$token/more',
        'https://kapynotes.com/pricing',
        'https://kapynotes.com/space/short',
        'kapynotes://space/$token"><script>',
        'kapynotes://settings/$token',
        'ftp://kapynotes.com/join/$token',
      ]) {
        expect(parseJoinTarget(input), isNull, reason: input);
      }
    });
  });

  group('splitting typed addresses', () {
    test('commas, semicolons, spaces and lines all separate', () {
      expect(splitAddresses('a@x.com, b@x.com;c@x.com\nd@x.com   e@x.com'), [
        'a@x.com',
        'b@x.com',
        'c@x.com',
        'd@x.com',
        'e@x.com',
      ]);
    });

    test('a list copied out of a mail client reads as its addresses', () {
      expect(splitAddresses('Priya Shah <priya@x.com>, "Arun" <arun@x.com>'), [
        'priya@x.com',
        'arun@x.com',
      ]);
    });

    test('a forgotten domain is kept, so the server can say it is invalid', () {
      expect(splitAddresses('priya@x.com arun'), ['priya@x.com', 'arun']);
    });

    test('the same address twice, in any case, is one', () {
      expect(splitAddresses('a@x.com A@X.com a@x.com'), ['a@x.com']);
    });
  });

  group('the service', () {
    late FakeSend send;
    late int refreshed;
    late int synced;
    late Joining joining;

    setUp(() {
      send = FakeSend();
      refreshed = 0;
      synced = 0;
      joining = Joining(
        send: send.call,
        refreshSpaces: () async => refreshed++,
        requestSync: () => synced++,
      );
    });

    test(
      'inviting several says what happened to each, and refreshes when anything went',
      () async {
        send.answers['POST spaces/s1/invites/batch'] = {
          'results': [
            {
              'email': 'a@x.com',
              'outcome': 'invited',
              'invite': {'token': 't1', 'emailed': true},
            },
            {'email': 'b@x.com', 'outcome': 'already-member'},
            {'email': 'nope', 'outcome': 'invalid'},
          ],
        };
        final results = await joining.inviteMany('s1', [
          'a@x.com',
          'b@x.com',
          'nope',
        ], role: SpaceRole.viewer);
        expect(results.map((r) => r.outcome), [
          BatchInviteOutcome.invited,
          BatchInviteOutcome.alreadyMember,
          BatchInviteOutcome.invalid,
        ]);
        expect(results.first.emailed, isTrue);
        expect(send.calls.single.$3, {
          'emails': ['a@x.com', 'b@x.com', 'nope'],
          'role': 'viewer',
        });
        expect(refreshed, 1);
      },
    );

    test(
      'a batch refused whole comes back as the limit, with the room left',
      () async {
        send.answers['POST spaces/s1/invites/batch'] =
            const SyncRefusedException(409, 'too many pending invitations', {
              'error': 'too many pending invitations',
              'room': 3,
            });
        await expectLater(
          joining.inviteMany('s1', ['a@x.com']),
          throwsA(
            isA<InviteLimitException>()
                .having((e) => e.reason, 'reason', InviteLimitReason.pending)
                .having((e) => e.room, 'room', 3),
          ),
        );
        expect(refreshed, 0);
      },
    );

    test(
      'a link is loaded, made, changed and turned off, and the service remembers which',
      () async {
        expect(joining.knowsLinkOf('s1'), isFalse);
        send.answers['GET spaces/s1/link'] = {'link': null};
        expect(await joining.loadLink('s1'), isNull);
        expect(joining.knowsLinkOf('s1'), isTrue);

        send.answers['PUT spaces/s1/link'] = {
          'token': token,
          'url': 'https://kapynotes.com/space/$token',
          'role': 'member',
          'approval': false,
          'expiresAt': null,
        };
        final link = await joining.makeLink('s1', approval: false);
        expect(link.approval, isFalse);
        expect(link.expiresAt, isNull);
        expect(joining.linkOf('s1')?.token, token);
        expect(send.calls.last.$3, {'role': 'member', 'approval': false});

        send.answers['PATCH spaces/s1/link'] = {
          'token': token,
          'url': 'https://kapynotes.com/space/$token',
          'role': 'viewer',
          'approval': false,
          'expiresAt': null,
        };
        final changed = await joining.changeLink('s1', role: SpaceRole.viewer);
        expect(changed.role, SpaceRole.viewer);
        expect(joining.linkOf('s1')?.role, SpaceRole.viewer);
        // Only what changes is sent: the address, and everything else, stays.
        expect(send.calls.last.$3, {'role': 'viewer'});

        await joining.turnOffLink('s1');
        expect(joining.linkOf('s1'), isNull);
      },
    );

    test(
      'a link from a server that predates open links asks, and says when it ends',
      () {
        final link = JoinLink.fromJson({
          'token': token,
          'url': 'https://kapynotes.com/space/$token',
          'role': 'member',
          'expiresAt': '2030-01-01T00:00:00.000Z',
        })!;
        expect(link.approval, isTrue);
        expect(link.expiresAt, isNotNull);
      },
    );

    test(
      'letting people in refreshes, and asks for the sync that hands them the key',
      () async {
        send.answers['GET spaces/s1/requests'] = {
          'requests': [
            {
              'userId': 'u1',
              'email': 'a@x.com',
              'name': 'Arun',
              'role': 'member',
              'requestedAt': '2030-01-01T00:00:00Z',
            },
            {
              'userId': 'u2',
              'email': 'b@x.com',
              'name': null,
              'role': 'member',
              'requestedAt': '2030-01-01T00:00:00Z',
            },
          ],
        };
        await joining.loadRequests('s1');
        expect(joining.waitingCount, 2);
        expect(joining.requestsOf('s1').first.name, 'Arun');
        expect(joining.requestsOf('s1').last.name, isNull);

        send.answers['POST spaces/s1/requests/approve'] = {
          'approved': ['u1'],
        };
        expect(await joining.approve('s1', ['u1']), ['u1']);
        expect(joining.requestsOf('s1').map((r) => r.userId), ['u2']);
        expect(refreshed, 1);
        expect(synced, 1);

        await joining.decline('s1', 'u2');
        expect(joining.waitingCount, 0);
        expect(send.calls.last.$1, 'DELETE');
      },
    );

    test('approving nobody asks the server nothing', () async {
      expect(await joining.approve('s1', const []), isEmpty);
      expect(send.calls, isEmpty);
    });

    test('the person holding a link previews, then asks', () async {
      final described = {
        'spaceId': 's1',
        'spaceName': 'Family',
        'ownerEmail': 'priya@x.com',
        'ownerName': 'Priya',
        'role': 'member',
        'status': 'none',
        'inviteToken': null,
      };
      send.answers['GET links/$token'] = described;
      send.answers['POST links/$token/request'] = {
        ...described,
        'status': 'pending',
      };
      final before = await joining.preview(token);
      expect(before.ownerLabel, 'Priya (priya@x.com)');
      expect(before.status, JoinStatus.none);
      expect(before.approval, isTrue);
      expect((await joining.ask(token)).status, JoinStatus.pending);
      // Asking changes nobody's spaces yet.
      expect(refreshed, 0);
    });

    test(
      'joining through a link that needs no asking fetches the spaces again, and asks for the sync that brings the key',
      () async {
        final described = {
          'spaceId': 's1',
          'spaceName': 'Family',
          'ownerEmail': 'priya@x.com',
          'ownerName': 'Priya',
          'role': 'member',
          'approval': false,
          'status': 'none',
          'inviteToken': null,
        };
        send.answers['GET links/$token'] = described;
        send.answers['POST links/$token/request'] = {
          ...described,
          'status': 'member',
        };
        expect((await joining.preview(token)).approval, isFalse);
        expect((await joining.ask(token)).status, JoinStatus.member);
        expect(refreshed, 1);
        expect(synced, 1);
      },
    );
  });
}
