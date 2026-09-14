import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/deep_links.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/sync/joining.dart';
import 'package:kapy_notes/sync/sharing.dart';
import 'package:kapy_notes/sync/space_keyring.dart';
import 'package:kapy_notes/sync/spaces.dart';
import 'package:kapy_notes/sync/sync_api.dart';
import 'package:kapy_notes/sync/sync_service.dart';
import 'package:kapy_notes/sync/sync_state.dart';
import 'package:kapy_notes/sync/trust.dart';
import 'package:kapy_notes/ui/join/join_link_listener.dart';
import 'package:kapy_notes/ui/join/join_link_sheet.dart';
import 'package:kapy_notes/ui/join/join_requests_panel.dart';
import 'package:kapy_notes/ui/join/joining_ui.dart';
import 'package:kapy_notes/ui/join/space_link_panel.dart';
import 'package:kapy_notes/ui/share_dialog.dart';
import 'package:material_ui/material_ui.dart';

import 'sync/fake_server.dart';

const token = 'AbCdEfGhIjKlMnOpQrStUv';

class MemoryStore extends LocalStore {
  MemoryStore() : super(fileName: 'joining-ui-test.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
  @override
  void putNow(String key, Object? value) => data[key] = value;
}

/// One unlocked account against the fake server, as the share sheet's own
/// tests build it.
class Device {
  Device(this.server, {required this.userId, required this.device}) {
    server.seedBundle(userId);
    store = MemoryStore();
    notes = NotesStore(store);
    final api = FakeApi(server, device: device, userId: userId);
    final vault = vaultFor(userId);
    keyring = SpaceKeyring(
      userId: userId,
      store: store,
      trust: TrustStore(store),
    );
    sync = SyncService(
      notes: notes,
      state: SyncState(store),
      api: api,
      keyring: keyring,
      docs: DocStore(MemoryDocStorage(), replica: device),
      vault: vault,
      sendDelay: const Duration(hours: 1),
    );
    sharing = Sharing(
      api: api,
      vault: vault,
      keyring: keyring,
      notes: notes,
      sync: sync,
    );
  }

  final FakeServer server;
  final String userId;
  final String device;
  late final MemoryStore store;
  late final NotesStore notes;
  late final SpaceKeyring keyring;
  late final SyncService sync;
  late final Sharing sharing;

  String get email => server.user(userId).email;

  Future<void> boot() async {
    await notes.load();
    await sync.syncNow();
  }

  void dispose() {
    sharing.dispose();
    sync.dispose();
  }
}

/// The joining endpoints, which the fake server does not know: every call is
/// recorded, and answered from [answers] or else by [fallback].
class FakeSend {
  final calls = <(String, String, Map<String, Object?>?)>[];
  final answers = <String, Object>{};
  Object? Function(String method, String path, Map<String, Object?>? payload)?
  fallback;

  Future<Map<String, Object?>> call(
    String method,
    String path, {
    Map<String, Object?>? payload,
  }) async {
    calls.add((method, path, payload));
    final answer =
        answers['$method $path'] ?? fallback?.call(method, path, payload);
    if (answer is Exception) throw answer;
    return (answer as Map<String, Object?>?) ?? const {};
  }

  bool sawPath(String method, String path) =>
      calls.any((c) => c.$1 == method && c.$2 == path);
}

Joining joiningOver(FakeSend send, {Future<void> Function()? refresh}) =>
    Joining(
      send: send.call,
      refreshSpaces: refresh ?? () async {},
      requestSync: () {},
    );

Map<String, Object?> preview({String status = 'none', String? invite}) => {
  'spaceId': 's1',
  'spaceName': 'Family',
  'ownerEmail': 'priya@example.com',
  'ownerName': 'Priya',
  'role': 'member',
  'status': status,
  'inviteToken': invite,
};

Widget app(Widget home, {Joining? joining}) => JoiningScope.value(
  joining: joining,
  child: MaterialApp(
    theme: KapyTheme.dark(),
    home: Scaffold(body: home),
  ),
);

Widget button(String label, void Function(BuildContext) onPressed) => Builder(
  builder: (context) =>
      TextButton(onPressed: () => onPressed(context), child: Text(label)),
);

/// The dialog's own run, minus progress and terms: enough to drive a panel.
Future<void> plainRun(
  Future<void> Function() action, {
  String waiting = '',
  String? done,
  String? success,
}) => action();

/// Everything put on the clipboard for the rest of the test.
List<String> captureClipboard(WidgetTester tester) {
  final copied = <String>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      copied.add((call.arguments as Map)['text'] as String);
    }
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
  return copied;
}

void main() {
  late FakeServer server;
  late Device alice;

  setUp(() {
    server = FakeServer();
    alice = Device(server, userId: 'user-1', device: 'a');
  });
  tearDown(() => alice.dispose());

  // ---------------------------------------------------------------------------
  group('links that open the app', () {
    test('a way into a space is kept until taken, and taken once', () {
      final links = DeepLinks(const Stream.empty());
      links.offer(Uri.parse('kapynotes://space/$token'));
      expect(links.pending, const SpaceLinkTarget(token));
      expect(links.take(), const SpaceLinkTarget(token));
      expect(links.pending, isNull);
      links.dispose();
    });

    test('anything else, Quick Capture included, is left alone', () {
      final links = DeepLinks(const Stream.empty());
      var told = 0;
      links.addListener(() => told++);
      links.offer(Uri.parse('kapynotes://write'));
      links.offer(Uri.parse('https://example.com/space/$token'));
      expect(links.pending, isNull);
      expect(told, 0);
      links.dispose();
    });

    test('the same link handed over twice at launch is one link', () {
      final links = DeepLinks(const Stream.empty());
      var told = 0;
      links.addListener(() => told++);
      links.offer(Uri.parse('https://kapynotes.com/join/$token'));
      links.offer(Uri.parse('https://kapynotes.com/join/$token'));
      expect(told, 1);
      links.dispose();
    });

    test('links arrive from the stream they are given', () async {
      final controller = StreamController<Uri>();
      final links = DeepLinks(controller.stream);
      controller.add(Uri.parse('kapynotes://join/$token'));
      await Future<void>.delayed(Duration.zero);
      expect(links.pending, const InviteTarget(token));
      links.dispose();
      await controller.close();
    });
  });

  // ---------------------------------------------------------------------------
  group('the sheet a link opens', () {
    Future<void> open(WidgetTester tester, FakeSend send) async {
      final joining = joiningOver(send);
      await tester.pumpWidget(
        app(
          button(
            'open',
            (context) => showJoinLinkSheet(
              context,
              token: token,
              joining: joining,
              sharing: alice.sharing,
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('says what the space is before anything is asked, then asks', (
      tester,
    ) async {
      final send = FakeSend()
        ..answers['GET links/$token'] = preview()
        ..answers['POST links/$token/request'] = preview(status: 'pending');
      await open(tester, send);

      expect(
        find.textContaining('Priya (priya@example.com) shared “Family”'),
        findsOneWidget,
      );
      expect(find.textContaining('view and edit notes'), findsOneWidget);
      expect(send.sawPath('POST', 'links/$token/request'), isFalse);

      await tester.tap(find.byKey(const ValueKey('join-link-ask')));
      await tester.pumpAndSettle();
      expect(send.sawPath('POST', 'links/$token/request'), isTrue);
      expect(
        find.textContaining('request to join “Family” is pending'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('join-link-ask')), findsNothing);
    });

    testWidgets('a dead link says so', (tester) async {
      final send = FakeSend()
        ..answers['GET links/$token'] = const SyncRefusedException(
          404,
          'no such link',
          {'error': 'no such link'},
        );
      await open(tester, send);
      expect(find.text('That link expired or was disabled.'), findsOneWidget);
      expect(find.byKey(const ValueKey('join-link-ask')), findsNothing);
    });

    testWidgets('somebody already invited is offered the invitation instead', (
      tester,
    ) async {
      final send = FakeSend()
        ..answers['GET links/$token'] = preview(
          status: 'invited',
          invite: 'inv-1',
        );
      await open(tester, send);
      expect(
        find.textContaining('already invited you to “Family” by email'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('join-link-accept')), findsOneWidget);
      expect(find.byKey(const ValueKey('join-link-ask')), findsNothing);
    });

    testWidgets(
      "a refusal for the owner's plan is not put to the joiner as theirs",
      (tester) async {
        final send = FakeSend()
          ..answers['GET links/$token'] = preview()
          ..answers['POST links/$token/request'] = const SyncRefusedException(
            402,
            'pro-required',
            {'error': 'pro-required'},
          );
        await open(tester, send);
        await tester.tap(find.byKey(const ValueKey('join-link-ask')));
        await tester.pumpAndSettle();
        expect(
          find.text("The owner's plan does not cover new people right now."),
          findsOneWidget,
        );
      },
    );

    testWidgets('a link that needs no asking says so, and joins in one tap', (
      tester,
    ) async {
      final send = FakeSend()
        ..answers['GET links/$token'] = {...preview(), 'approval': false}
        ..answers['POST links/$token/request'] = {
          ...preview(status: 'member'),
          'approval': false,
        };
      await open(tester, send);

      expect(
        find.textContaining('shares “Family” with anyone who has this link'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('join-link-ask')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('join-link-join')));
      await tester.pumpAndSettle();
      expect(send.sawPath('POST', 'links/$token/request'), isTrue);
      expect(find.text('You are in “Family”.'), findsOneWidget);
      expect(
        find.text(
          'The notes arrive the next time Priya or another member is online.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('join-link-join')), findsNothing);
    });

    testWidgets('a note shared by link is not called by its placeholder', (
      tester,
    ) async {
      final send = FakeSend()
        ..answers['GET links/$token'] = {
          ...preview(),
          'spaceName': kLinkSpaceName,
          'approval': false,
        };
      await open(tester, send);
      expect(find.textContaining(kLinkSpaceName), findsNothing);
      expect(
        find.textContaining('shares these notes with anyone who has this link'),
        findsOneWidget,
      );
    });
  });

  // ---------------------------------------------------------------------------
  group("the owner's link", () {
    Map<String, Object?> linkJson({
      String role = 'member',
      bool approval = false,
      String? expiresAt,
      String address = token,
    }) => {
      'token': address,
      'url': 'https://kapynotes.com/space/$address',
      'role': role,
      'approval': approval,
      'expiresAt': expiresAt,
    };

    Future<void> choose(WidgetTester tester, LinkAccess access) async {
      await tester.tap(find.byKey(const ValueKey('link-access')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('link-access-${access.name}')));
      await tester.pumpAndSettle();
    }

    Widget panel(FakeSend send) => app(
      SpaceLinkPanel(spaceId: 's1', joining: joiningOver(send), run: plainRun),
    );

    testWidgets(
      'choosing who it lets in makes a link that needs no asking, and copies it',
      (tester) async {
        final copied = captureClipboard(tester);
        final send = FakeSend()
          ..answers['GET spaces/s1/link'] = {'link': null}
          ..answers['PUT spaces/s1/link'] = linkJson();
        await tester.pumpWidget(panel(send));
        await tester.pumpAndSettle();
        expect(find.text('Only people you invite'), findsOneWidget);

        await choose(tester, LinkAccess.anyoneCanEdit);
        expect(send.calls.last.$1, 'PUT');
        expect(send.calls.last.$3, {'role': 'member', 'approval': false});
        expect(copied, ['https://kapynotes.com/space/$token']);
        expect(find.text('Anyone with the link can edit'), findsOneWidget);
        expect(find.textContaining('can edit straight away'), findsOneWidget);
      },
    );

    testWidgets(
      'view and edit keep the address, approving first is a switch, and the first choice turns it off',
      (tester) async {
        var role = 'member';
        var approval = false;
        final send = FakeSend()
          ..answers['GET spaces/s1/link'] = {'link': linkJson()}
          ..fallback = (method, path, payload) {
            if (method != 'PATCH') return null;
            role = payload?['role'] as String? ?? role;
            approval = payload?['approval'] as bool? ?? approval;
            return linkJson(role: role, approval: approval);
          };
        await tester.pumpWidget(panel(send));
        await tester.pumpAndSettle();
        expect(find.text('Anyone with the link can edit'), findsOneWidget);

        await choose(tester, LinkAccess.anyoneCanView);
        expect(send.calls.last.$1, 'PATCH');
        expect(send.calls.last.$3, {'role': 'viewer'});
        expect(find.text('Anyone with the link can view'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('link-approval')));
        await tester.pumpAndSettle();
        expect(send.calls.last.$3, {'approval': true});
        expect(find.textContaining('you let each one in'), findsOneWidget);
        expect(send.sawPath('PUT', 'spaces/s1/link'), isFalse);

        await choose(tester, LinkAccess.invitedOnly);
        expect(send.sawPath('DELETE', 'spaces/s1/link'), isTrue);
        expect(find.text('Only people you invite'), findsOneWidget);
        expect(find.byKey(const ValueKey('link-approval')), findsNothing);
      },
    );

    testWidgets(
      'with no link yet, Copy link asks which link to make instead of guessing',
      (tester) async {
        final send = FakeSend()..answers['GET spaces/s1/link'] = {'link': null};
        await tester.pumpWidget(panel(send));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('link-copy')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('link-access-anyoneCanView')),
          findsOneWidget,
        );
        expect(send.sawPath('PUT', 'spaces/s1/link'), isFalse);
      },
    );

    testWidgets(
      'a link made to end says when, and replacing it copies the new address',
      (tester) async {
        final copied = captureClipboard(tester);
        const fresh = 'ZyXwVuTsRqPoNmLkJiHgFe';
        final send = FakeSend()
          ..answers['GET spaces/s1/link'] = {
            'link': linkJson(
              approval: true,
              expiresAt: '2030-01-08T00:00:00.000Z',
            ),
          }
          ..answers['PUT spaces/s1/link'] = linkJson(
            approval: true,
            address: fresh,
          );
        await tester.pumpWidget(panel(send));
        await tester.pumpAndSettle();
        expect(find.textContaining('It works until'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('link-replace')));
        await tester.pumpAndSettle();
        expect(send.calls.last.$3, {'role': 'member', 'approval': true});
        expect(copied, ['https://kapynotes.com/space/$fresh']);
        expect(find.textContaining('It works until'), findsNothing);
      },
    );
  });

  // ---------------------------------------------------------------------------
  group('who is waiting', () {
    Map<String, Object?> waiting(List<(String, String, String?)> people) => {
      'requests': [
        for (final (id, email, name) in people)
          {
            'userId': id,
            'email': email,
            'name': name,
            'role': 'member',
            'requestedAt': '2030-01-01T00:00:00Z',
          },
      ],
    };

    testWidgets('nothing is drawn while nobody is waiting', (tester) async {
      final send = FakeSend()
        ..answers['GET spaces/s1/requests'] = waiting(const []);
      await tester.pumpWidget(
        app(
          JoinRequestsPanel(
            spaceId: 's1',
            joining: joiningOver(send),
            run: plainRun,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('join-requests')), findsNothing);
    });

    testWidgets(
      'each person by the name they chose and the address that is theirs',
      (tester) async {
        final send = FakeSend()
          ..answers['GET spaces/s1/requests'] = waiting(const [
            ('u1', 'arun@example.com', 'Arun'),
            ('u2', 'plain@example.com', null),
          ])
          ..answers['POST spaces/s1/requests/approve'] = {
            'approved': ['u1'],
          };
        await tester.pumpWidget(
          app(
            JoinRequestsPanel(
              spaceId: 's1',
              joining: joiningOver(send),
              run: plainRun,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Waiting to join (2)'), findsOneWidget);
        expect(find.text('Arun'), findsOneWidget);
        expect(find.text('arun@example.com'), findsOneWidget);
        expect(find.text('plain@example.com'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('join-requests-approve-all')),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const ValueKey('join-request-approve-u1')));
        await tester.pumpAndSettle();
        expect(send.calls.last.$3, {
          'userIds': ['u1'],
        });
        expect(find.text('Arun'), findsNothing);
        expect(find.text('Waiting to join (1)'), findsOneWidget);
      },
    );

    testWidgets('not letting somebody in is asked about first', (tester) async {
      final send = FakeSend()
        ..answers['GET spaces/s1/requests'] = waiting(const [
          ('u1', 'arun@example.com', 'Arun'),
        ]);
      await tester.pumpWidget(
        app(
          JoinRequestsPanel(
            spaceId: 's1',
            joining: joiningOver(send),
            run: plainRun,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('join-request-decline-u1')));
      await tester.pumpAndSettle();
      expect(find.textContaining('cannot use this link again'), findsOneWidget);
      expect(send.sawPath('DELETE', 'spaces/s1/requests/u1'), isFalse);

      await tester.tap(
        find.byKey(const ValueKey('join-request-decline-confirm')),
      );
      await tester.pumpAndSettle();
      expect(send.sawPath('DELETE', 'spaces/s1/requests/u1'), isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  group('the share sheet, with several addresses', () {
    /// What the real server does with a batch: an invitation written for
    /// every address, on the server. Answering without writing them would
    /// leave the fake server a space with nobody else in it, which the
    /// owner's device then ends — not what happens in production.
    Map<String, Object?> allInvited(
      String path,
      Map<String, Object?>? payload,
    ) {
      final spaceId = path.split('/')[1];
      return {
        'results': [
          for (final e
              in (payload?['emails'] as List? ?? const []).cast<String>())
            () {
              final invite = server.invite('user-1', spaceId, e);
              return {
                'email': e,
                'outcome': 'invited',
                'invite': {'token': invite.token, 'emailed': true},
              };
            }(),
        ],
      };
    }

    testWidgets('to a space already shared, they go in one batch', (
      tester,
    ) async {
      late Space space;
      await tester.runAsync(() async {
        await alice.boot();
        space = await alice.sharing.createSpace('Family');
      });
      final send = FakeSend()
        ..fallback = (method, path, payload) =>
            path.endsWith('/invites/batch') ? allInvited(path, payload) : null;
      final joining = joiningOver(send);

      await tester.pumpWidget(
        app(
          button(
            'open',
            (context) => showSpaceDialog(
              context,
              spaceId: space.id,
              sharing: alice.sharing,
            ),
          ),
          joining: joining,
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('share-email')),
        'a@example.com, b@example.com',
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('share-submit-Invite')));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();

      final batch = send.calls
          .where((c) => c.$2 == 'spaces/${space.id}/invites/batch')
          .single;
      expect(batch.$3, {
        'emails': ['a@example.com', 'b@example.com'],
        'role': 'member',
      });
      expect(find.text('Invited 2 people.'), findsOneWidget);
      // The link and the waiting list sit under the field for the owner.
      expect(find.byKey(const ValueKey('space-link-panel')), findsOneWidget);
    });

    testWidgets(
      'for a note not yet shared, they get a new space: never the one already shared with one of them',
      (tester) async {
        final bob = Device(server, userId: 'user-2', device: 'b');
        addTearDown(bob.dispose);
        late Note first;
        late Note second;
        late Space pair;
        await tester.runAsync(() async {
          await alice.boot();
          await bob.boot();
          first = alice.notes.create(body: 'Only for Bob');
          pair = await alice.sharing.shareNoteWith(first.id, email: bob.email);
          second = alice.notes.create(body: 'For a group');
        });
        final send = FakeSend()
          ..fallback = (method, path, payload) =>
              path.endsWith('/invites/batch')
              ? allInvited(path, payload)
              : null;

        await tester.pumpWidget(
          app(
            button(
              'open',
              (context) => showShareDialog(
                context,
                note: second,
                sharing: alice.sharing,
              ),
            ),
            joining: joiningOver(send),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const ValueKey('share-email')),
          '${bob.email} carol@example.com',
        );
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const ValueKey('share-submit-Share')));
          await Future<void>.delayed(const Duration(milliseconds: 200));
        });
        await tester.pumpAndSettle();

        final batch = send.calls
            .where((c) => c.$2.endsWith('/invites/batch'))
            .single;
        final used = batch.$2.split('/')[1];
        // Adding Carol to the space shared with Bob would show her every note
        // shared with Bob before. The batch has to go somewhere new.
        expect(used, isNot(pair.id));
        final moved = alice.notes.byId(second.id)!;
        expect(moved.spaceId, used);
        expect(alice.notes.byId(first.id)!.spaceId, pair.id);
        expect(alice.sharing.spaceById(used)?.name, startsWith('With '));
      },
    );
  });

  // ---------------------------------------------------------------------------
  group('the share sheet, by link', () {
    /// What the real server does when a link is made: the space has one, and
    /// its listing says so. That is what keeps the owner's own device from
    /// ending a space that holds a note and nobody else yet.
    Object? linkMade(
      String method,
      String path,
      Map<String, Object?>? payload,
    ) {
      if (method != 'PUT' || !path.endsWith('/link')) return null;
      server.spaces[path.split('/')[1]]!.hasLink = true;
      return {
        'token': token,
        'url': 'https://kapynotes.com/space/$token',
        'role': payload?['role'],
        'approval': payload?['approval'],
        'expiresAt': null,
      };
    }

    Future<void> openFor(WidgetTester tester, Note note, FakeSend send) async {
      await tester.pumpWidget(
        app(
          button(
            'open',
            (context) =>
                showShareDialog(context, note: note, sharing: alice.sharing),
          ),
          joining: joiningOver(send, refresh: alice.sharing.refresh),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    /// Opens the menu on the real clock, not the test's fake one: the menu
    /// hands its answer back in the zone that opened it, and the sharing that
    /// answer starts needs real time to get anywhere.
    Future<void> choose(WidgetTester tester, LinkAccess access) async {
      await tester.runAsync(
        () => tester.tap(find.byKey(const ValueKey('link-access'))),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(ValueKey('link-access-${access.name}')));
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pumpAndSettle();
    }

    testWidgets(
      'a private note gets a space of its own and a link that lets people straight in, copied',
      (tester) async {
        final copied = captureClipboard(tester);
        late Note note;
        await tester.runAsync(() async {
          await alice.boot();
          note = alice.notes.create(body: 'Trip plan');
          await alice.sync.syncNow();
        });
        final send = FakeSend()..fallback = linkMade;
        await openFor(tester, note, send);

        await choose(tester, LinkAccess.anyoneCanEdit);

        final made = send.calls.singleWhere((c) => c.$1 == 'PUT');
        expect(made.$3, {'role': 'member', 'approval': false});
        final spaceId = made.$2.split('/')[1];
        expect(alice.sharing.spaceById(spaceId)?.name, kLinkSpaceName);
        expect(alice.notes.byId(note.id)!.spaceId, spaceId);
        expect(copied, ['https://kapynotes.com/space/$token']);
        expect(
          find.text('Shared with anyone who has the link'),
          findsOneWidget,
        );

        // Another pass, and it stays shared: nobody has joined yet, and the
        // link is what keeps the owner's device from bringing it home.
        await tester.runAsync(() => alice.sync.syncNow());
        await tester.pumpAndSettle();
        expect(alice.notes.byId(note.id)!.spaceId, spaceId);
        expect(server.calls, isNot(contains('stop')));
        expect(find.text('Anyone with the link can edit'), findsOneWidget);
      },
    );

    testWidgets(
      'a link the server will not make leaves the note private, and the space made for it ended',
      (tester) async {
        late Note note;
        await tester.runAsync(() async {
          await alice.boot();
          note = alice.notes.create(body: 'Trip plan');
        });
        final send = FakeSend()
          ..fallback = (method, path, payload) => method == 'PUT'
              ? const SyncRefusedException(409, 'too many requests', {
                  'error': 'too many requests',
                })
              : null;
        await openFor(tester, note, send);

        await choose(tester, LinkAccess.anyoneCanView);

        expect(send.calls.where((c) => c.$1 == 'PUT'), hasLength(1));
        expect(alice.notes.byId(note.id)!.spaceId, isNull);
        expect(server.calls, contains('stop'));
        expect(alice.sharing.teams, isEmpty);
      },
    );

    testWidgets(
      'inside a note whose space holds others, the owner is told the link opens those too',
      (tester) async {
        final bob = Device(server, userId: 'user-2', device: 'b');
        addTearDown(bob.dispose);
        late Note first;
        late String pair;
        await tester.runAsync(() async {
          await alice.boot();
          await bob.boot();
          first = alice.notes.create(body: 'One');
          await alice.sharing.shareNoteWith(first.id, email: bob.email);
          pair = alice.notes.byId(first.id)!.spaceId!;
          // The space's notes as the server holds them. Only the count reaches
          // the sheet, and this device's own note does not reach the fake
          // server over its socket inside a widget test, so both are put
          // there directly.
          for (final id in ['shared-first', 'shared-second']) {
            server.spaces[pair]!.notes[id] = FakeNoteRow(
              id: id,
              spaceId: pair,
              userId: 'user-1',
              updatedAt: DateTime.utc(2026, 9, 1),
            );
          }
          await alice.sharing.refresh();
        });
        expect(alice.sharing.spaceById(pair)!.liveNotes, 2);

        final send = FakeSend()
          ..fallback = (method, path, payload) =>
              path.endsWith('/link') ? {'link': null} : null;
        await openFor(tester, first, send);

        expect(
          find.textContaining('It opens all 2 notes shared'),
          findsOneWidget,
        );
      },
    );
  });

  // ---------------------------------------------------------------------------
  group('the share sheet never makes a space for nobody', () {
    Future<Note> openFor(WidgetTester tester, FakeSend send) async {
      late Note note;
      await tester.runAsync(() async {
        await alice.boot();
        note = alice.notes.create(body: 'For a group');
      });
      await tester.pumpWidget(
        app(
          button(
            'open',
            (context) =>
                showShareDialog(context, note: note, sharing: alice.sharing),
          ),
          joining: joiningOver(send),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return note;
    }

    Future<void> submit(WidgetTester tester, String typed) async {
      await tester.enterText(find.byKey(const ValueKey('share-email')), typed);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('share-submit-Share')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
    }

    testWidgets('addresses that could be nobody make nothing at all', (
      tester,
    ) async {
      final send = FakeSend();
      final note = await openFor(tester, send);
      final before = server.calls.where((c) => c == 'createSpace').length;
      await submit(tester, 'arun, not-an-address');
      expect(
        find.text('None of those look like email addresses.'),
        findsOneWidget,
      );
      expect(server.calls.where((c) => c == 'createSpace').length, before);
      expect(send.calls, isEmpty);
      expect(alice.notes.byId(note.id)!.spaceId, isNull);
    });

    testWidgets(
      'a batch the server turns entirely away leaves the note where it was, and the space ended',
      (tester) async {
        final send = FakeSend()
          ..fallback = (method, path, payload) =>
              path.endsWith('/invites/batch')
              ? {
                  'results': [
                    for (final e in (payload?['emails'] as List).cast<String>())
                      {'email': e, 'outcome': 'already-member'},
                  ],
                }
              : null;
        final note = await openFor(tester, send);
        await submit(
          tester,
          '${alice.email} ${alice.email.toUpperCase()}x@example.com',
        );

        expect(
          send.calls.where((c) => c.$2.endsWith('/invites/batch')),
          hasLength(1),
        );
        // The note never went in, so nothing could be brought home or lost.
        expect(alice.notes.byId(note.id)!.spaceId, isNull);
        // And the space made for them is gone, not left for the trip home.
        expect(server.calls, contains('stop'));
        expect(alice.sharing.teams, isEmpty);
      },
    );
  });

  // ---------------------------------------------------------------------------
  group('the listener', () {
    testWidgets(
      'a link that arrives signed out is kept, and the person told once',
      (tester) async {
        final links = DeepLinks(const Stream.empty());
        addTearDown(links.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: KapyTheme.dark(),
            home: JoinLinkListener(
              links: links,
              account: null,
              child: const Scaffold(),
            ),
          ),
        );
        links.offer(Uri.parse('kapynotes://space/$token'));
        await tester.pump();
        expect(find.text('Sign in to open that link.'), findsOneWidget);
        expect(links.pending, const SpaceLinkTarget(token));
        await tester.pumpAndSettle(const Duration(seconds: 5));
      },
    );
  });
}
