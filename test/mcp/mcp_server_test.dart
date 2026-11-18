import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/mcp/mcp_clients.dart';
import 'package:kapy_notes/mcp/mcp_library.dart';
import 'package:kapy_notes/mcp/mcp_server.dart';
import 'package:kapy_notes/mcp/mcp_service.dart';

import 'mcp_test_helpers.dart';

/// The server end to end, over a real socket on 127.0.0.1.
void main() {
  late McpFixture f;
  late MemorySecrets secrets;
  late McpService service;
  late String token;
  final client = HttpClient();
  tearDownAll(() => client.close(force: true));

  McpService serviceOver(McpFixture fixture) => McpService(
    store: fixture.store,
    secrets: secrets,
    library: fixture.library,
  );

  setUp(() async {
    f = McpFixture();
    secrets = MemorySecrets();
    service = serviceOver(f);
    await service.load();
    await service.setEnabled(true);
    token = await service.connect(McpClientKind.claudeCode);
  });
  tearDown(() => service.dispose());

  int port() => int.parse(service.address!.split(':').last);

  Future<(int, Map<String, Object?>?, HttpHeaders)> send(
    Object? body, {
    String method = 'POST',
    String? bearer,
    bool auth = true,
    String? host,
    String? origin,
    String contentType = 'application/json',
    String path = McpServer.path,
  }) async {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${port()}$path'),
    );
    if (host != null) {
      request.headers
        ..host = host
        ..port = port();
    }
    if (origin != null) request.headers.set('origin', origin);
    if (auth) {
      request.headers.set('authorization', 'Bearer ${bearer ?? token}');
    }
    request.headers.set('content-type', contentType);
    if (body != null) {
      request.add(utf8.encode(body is String ? body : jsonEncode(body)));
    }
    final response = await request.close();
    final text = await utf8.decodeStream(response);
    return (
      response.statusCode,
      text.isEmpty ? null : jsonDecode(text) as Map<String, Object?>,
      response.headers,
    );
  }

  var nextId = 0;
  Future<Map<String, Object?>> rpc(
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    final (status, body, _) = await send({
      'jsonrpc': '2.0',
      'id': ++nextId,
      'method': method,
      'params': params,
    });
    expect(status, 200);
    return body!;
  }

  Future<Map<String, Object?>> call(
    String tool, [
    Map<String, Object?> args = const {},
  ]) async =>
      (await rpc('tools/call', {'name': tool, 'arguments': args}))['result']!
          as Map<String, Object?>;

  Map<String, Object?> output(Map<String, Object?> result) {
    expect(result['isError'], isNot(true), reason: '$result');
    return result['structuredContent']! as Map<String, Object?>;
  }

  String error(Map<String, Object?> result) {
    expect(result['isError'], isTrue);
    return ((result['content']! as List).single as Map)['text'] as String;
  }

  group('switch and address', () {
    test('is off by default, and listens on 127.0.0.1 only when on', () async {
      final fresh = serviceOver(McpFixture());
      await fresh.load();
      expect(fresh.enabled, isFalse);
      expect(fresh.running, isFalse);
      expect(service.address, startsWith('127.0.0.1:'));
    });

    test('nothing on another interface can connect', () async {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      final outside = [
        for (final i in interfaces)
          for (final a in i.addresses)
            if (!a.isLoopback) a,
      ];
      for (final address in outside) {
        await expectLater(
          Socket.connect(address, port(), timeout: const Duration(seconds: 2)),
          throwsA(isA<SocketException>()),
        );
      }
    });

    test('keeps its address across launches, and moves when it is taken', () async {
      final first = port();
      service.dispose();
      // The next launch comes after this one has let go of the port.
      for (var i = 0; i < 40; i++) {
        try {
          await (await ServerSocket.bind(InternetAddress.loopbackIPv4, first)).close();
          break;
        } on SocketException {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      final again = serviceOver(f);
      await again.load();
      expect(again.address, '127.0.0.1:$first');
      expect(again.moved, isFalse);
      again.dispose();

      final squatter = await ServerSocket.bind(InternetAddress.loopbackIPv4, first);
      addTearDown(squatter.close);
      final moved = serviceOver(f);
      await moved.load();
      expect(moved.running, isTrue);
      expect(moved.moved, isTrue);
      expect(moved.address, isNot('127.0.0.1:$first'));
      service = moved;
    });

    test('turning it off closes the port at once', () async {
      final was = port();
      await service.setEnabled(false);
      await expectLater(
        Socket.connect(InternetAddress.loopbackIPv4, was),
        throwsA(isA<SocketException>()),
      );
    });
  });

  group('security', () {
    final ping = {'jsonrpc': '2.0', 'id': 1, 'method': 'ping'};

    test('a token is required, and only a current one works', () async {
      expect((await send(ping, auth: false)).$1, 401);
      expect((await send(ping, bearer: 'kapy_wrong')).$1, 401);
      expect((await send(ping)).$1, 200);
    });

    test('a revoked token is refused on its very next request', () async {
      expect((await send(ping)).$1, 200);
      await service.revoke(McpClientKind.claudeCode);
      expect((await send(ping)).$1, 401);
    });

    test('a new token for the same app retires the old one', () async {
      final fresh = await service.connect(McpClientKind.claudeCode);
      expect((await send(ping)).$1, 401);
      expect((await send(ping, bearer: fresh)).$1, 200);
    });

    test('a wrong Host is refused, against DNS rebinding', () async {
      expect((await send(ping, host: 'evil.example')).$1, 403);
      expect((await send(ping, host: 'localhost')).$1, 200);
    });

    test('a foreign Origin is refused, and no preflight passes', () async {
      expect((await send(ping, origin: 'https://evil.example')).$1, 403);
      expect((await send(ping, origin: 'null')).$1, 403);
      expect((await send(ping, origin: 'http://127.0.0.1:${port()}')).$1, 200);
      final (status, _, headers) = await send(null, method: 'OPTIONS');
      expect(status, 403);
      expect(headers.value('access-control-allow-origin'), isNull);
    });

    test('only POST to /mcp with JSON is answered', () async {
      expect((await send(null, method: 'GET')).$1, 405);
      expect((await send(ping, path: '/')).$1, 404);
      expect((await send(ping, contentType: 'text/plain')).$1, 415);
    });

    test('a body over 1 MiB is refused', () async {
      final big = 'x' * (McpServer.maxBody + 1);
      expect((await send('{"a":"$big"}')).$1, 413);
    });

    test('an app stuck in a loop is slowed down', () async {
      for (var i = 0; i < McpServer.callsPerMinute; i++) {
        expect((await send(ping)).$1, 200);
      }
      final (status, body, _) = await send(ping);
      expect(status, 429);
      expect((body!['error']! as Map)['code'], -32000);
    });

    test('tokens are never stored, only their digests, in the keystore', () async {
      expect(jsonEncode(f.store.data), isNot(contains(token)));
      expect(f.store.data.keys.join(), isNot(contains('clients')));
      final saved = secrets.values['mcp.clients.v1']!;
      expect(saved, isNot(contains(token)));
      expect(saved, contains('"kind":"claudeCode"'));
    });
  });

  group('protocol', () {
    test('initialize names Kapy Notes and offers tools', () async {
      final result = (await rpc('initialize', {
        'protocolVersion': '2025-06-18',
        'capabilities': {},
        'clientInfo': {'name': 'test', 'version': '1'},
      }))['result']! as Map;
      expect(result['protocolVersion'], '2025-06-18');
      expect((result['serverInfo']! as Map)['name'], 'kapy-notes');
      expect((result['serverInfo']! as Map)['version'], isA<String>());
      expect((result['capabilities']! as Map).keys, ['tools']);
      final (status, _, _) = await send({
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      });
      expect(status, 202);
    });

    test('write tools are offered only while changes are allowed', () async {
      List<Object?> names(Map<String, Object?> listed) => [
        for (final tool in (listed['result']! as Map)['tools'] as List)
          (tool as Map)['name'],
      ];
      expect(names(await rpc('tools/list')), [
        'list_notes',
        'read_note',
        'list_tasks',
      ]);
      service.setAllowWrites(true);
      expect(names(await rpc('tools/list')), hasLength(7));
    });

    test('an unknown method is a JSON-RPC error', () async {
      final body = await rpc('resources/list');
      expect((body['error']! as Map)['code'], -32601);
    });
  });

  group('tools', () {
    test('list_notes pages through notes and leaves Hidden out', () async {
      final first = output(await call('list_notes', {'limit': 1}));
      expect((first['notes']! as List), hasLength(1));
      final cursor = first['next_cursor']! as String;
      final rest = output(await call('list_notes', {'cursor': cursor}));
      final ids = [
        for (final page in [first, rest])
          for (final note in page['notes']! as List) (note as Map)['id'],
      ];
      expect(ids, containsAll([f.plain, f.drawing, f.shared]));
      expect(ids, isNot(contains(f.hidden)));
      expect(ids, isNot(contains(f.archived)));
      expect(rest['next_cursor'], isNull);

      final found = output(await call('list_notes', {'query': 'taxi'}));
      final note = (found['notes']! as List).single as Map;
      expect(note['id'], f.plain);
      expect(note['snippet'], '☐ Book taxi');
      expect(note['open_tasks'], 1);
      expect(note['done_tasks'], 1);
    });

    test('read_note returns markdown and results, and continues long notes', () async {
      final read = output(await call('read_note', {'id': f.plain}));
      expect(read['body'], startsWith('Trip budget'));
      expect(read['next_offset'], isNull);
      expect(read['results'], anyElement(equals({'line': 2, 'value': '420'})));

      final long = f.notes.create(
        body: List.filled(9000, 'a line of ten').join('\n'),
      ).id;
      final pages = <String>[];
      int? offset = 0;
      while (offset != null) {
        final page = output(await call('read_note', {'id': long, 'offset': offset}));
        final body = page['body']! as String;
        expect(body.length, lessThanOrEqualTo(McpLibrary.pageSize));
        pages.add(body);
        offset = page['next_offset'] as int?;
      }
      expect(pages.length, greaterThan(1));
      expect(pages.join(), f.notes.byId(long)!.body);
    });

    test('a Hidden id gets the same error as an unknown one', () async {
      final hidden = error(await call('read_note', {'id': f.hidden}));
      final unknown = error(await call('read_note', {'id': 'nope'}));
      expect(hidden, unknown);
      expect(hidden, McpLibrary.notFound);
    });

    test('list_tasks reads open, done or all', () async {
      Future<List<Object?>> texts(String status) async => [
        for (final task in output(await call('list_tasks', {
          'status': status,
          'note_id': f.plain,
        }))['tasks']! as List)
          (task as Map)['text'],
      ];
      expect(await texts('open'), ['Book taxi']);
      expect(await texts('done'), ['Pack bag']);
      expect(await texts('all'), ['Book taxi', 'Pack bag']);
    });

    test('writes are refused while changes are off, and say so', () async {
      final message = error(
        await call('append_to_note', {'id': f.plain, 'text': 'sneaky'}),
      );
      expect(message, contains('Allow changes'));
      expect(f.notes.byId(f.plain)!.body, isNot(contains('sneaky')));
      expect(service.activity.first.refused, isTrue);
    });

    test('every write tool lands in the note as typed', () async {
      service.setAllowWrites(true);
      final created = output(await call('create_note', {
        'title': 'Groceries',
        'body': '☐ Milk',
      }));
      final id = (created['note']! as Map)['id']! as String;
      expect(f.notes.byId(id)!.body, 'Groceries\n☐ Milk');

      output(await call('append_to_note', {'id': id, 'text': 'From the market'}));
      final added = output(await call('add_task', {'note_id': id, 'text': 'Eggs'}));
      final taskId = (added['task']! as Map)['id'];
      final ticked = output(await call('set_task_done', {
        'task_id': taskId,
        'done': true,
      }));
      expect((ticked['task']! as Map)['done'], isTrue);
      expect(
        f.notes.byId(id)!.body,
        'Groceries\n☐ Milk\nFrom the market\n☑ Eggs',
      );
      expect(f.notes.dirtyNotes.map((n) => n.id), contains(id));
    });

    test('Recent activity holds titles, never note text, and clears', () async {
      await call('read_note', {'id': f.plain});
      final entry = service.activity.first;
      expect(entry.client, McpClientKind.claudeCode);
      expect(entry.text, 'Read “Trip budget”');
      expect(jsonEncode(f.store.data['mcp.activity.v1']), isNot(contains('flights')));
      expect(service.connections[McpClientKind.claudeCode]!.lastUsedAt, isNotNull);
      service.clearActivity();
      expect(service.activity, isEmpty);
      expect(f.store.data['mcp.activity.v1'], isEmpty);
    });
  });
}
