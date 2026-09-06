import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kapy_notes/sync/live_channel.dart';
import 'package:kapy_notes/sync/sync_api.dart';

import 'fake_server.dart';

/// Hands out prepared responses in order, and records what was asked for.
///
/// Once the script runs out it answers 503, so a channel that reconnects when
/// it should not reconnects into a wall instead of replaying a stream that has
/// already been consumed.
class ScriptedClient extends http.BaseClient {
  ScriptedClient(this._script);

  final List<http.StreamedResponse Function()> _script;
  final List<http.BaseRequest> requests = [];
  int _next = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    if (_next >= _script.length) {
      return http.StreamedResponse(const Stream<List<int>>.empty(), 503);
    }
    return _script[_next++]();
  }
}

void main() {
  final url = Uri.parse('https://example.test/sync/live');

  LiveChannel channelOver(
    http.Client client, {
    Future<String?> Function()? token,
  }) => LiveChannel(
    url: url,
    token: token ?? () async => 'token',
    headers: const {deviceHeader: 'device-a'},
    client: client,
    // Short enough that a test can watch a reconnect happen rather than
    // waiting three seconds for one.
    minRetry: const Duration(milliseconds: 5),
    maxRetry: const Duration(milliseconds: 20),
  );

  test('a wake-up frame becomes one signal and a heartbeat becomes none', () async {
    final body = StreamController<List<int>>();
    final client = ScriptedClient([
      () => http.StreamedResponse(body.stream, 200),
    ]);
    final channel = channelOver(client);
    final seen = <LiveSignal>[];
    final listening = channel.signals.listen(seen.add);

    await until(() => seen.contains(LiveSignal.connected));

    body.add(utf8.encode(':\n\n'));
    body.add(utf8.encode(': ping\n\n'));
    body.add(utf8.encode('event: sync\ndata: 1\n\n'));

    await until(() => seen.contains(LiveSignal.wake));
    expect(
      seen.where((signal) => signal == LiveSignal.wake),
      hasLength(1),
      reason: 'a comment is not an event',
    );

    await listening.cancel();
    await channel.dispose();
    await body.close();
  });

  test('a frame split across packets is still one frame', () async {
    final body = StreamController<List<int>>();
    final client = ScriptedClient([
      () => http.StreamedResponse(body.stream, 200),
    ]);
    final channel = channelOver(client);
    final seen = <LiveSignal>[];
    final listening = channel.signals.listen(seen.add);

    await until(() => seen.contains(LiveSignal.connected));

    // Nothing guarantees a frame arrives in one read, and a parser that
    // assumed otherwise would work in every test and fail on a slow network.
    body.add(utf8.encode('event: sy'));
    body.add(utf8.encode('nc\ndata:'));
    body.add(utf8.encode(' 1\n'));
    body.add(utf8.encode('\n'));

    await until(() => seen.contains(LiveSignal.wake));
    expect(seen.where((signal) => signal == LiveSignal.wake), hasLength(1));

    await listening.cancel();
    await channel.dispose();
    await body.close();
  });

  test('the request names the session and the device', () async {
    final body = StreamController<List<int>>();
    final client = ScriptedClient([
      () => http.StreamedResponse(body.stream, 200),
    ]);
    final channel = channelOver(client);
    final listening = channel.signals.listen((_) {});

    await until(() => client.requests.isNotEmpty);

    final request = client.requests.single;
    expect(request.headers['authorization'], 'Bearer token');
    expect(request.headers[deviceHeader], 'device-a');
    expect(request.headers['accept'], 'text/event-stream');

    await listening.cancel();
    await channel.dispose();
    await body.close();
  });

  test('a rejected session is not retried', () async {
    final client = ScriptedClient([
      () => http.StreamedResponse(const Stream<List<int>>.empty(), 401),
    ]);
    final channel = channelOver(client);
    final seen = <LiveSignal>[];
    final listening = channel.signals.listen(seen.add);

    // Several backoffs long. Reconnecting here would hand the same dead token
    // over every few seconds for as long as the app stayed open.
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(client.requests, hasLength(1));
    expect(seen, isEmpty);

    await listening.cancel();
    await channel.dispose();
  });

  test('no session means no connection at all', () async {
    final client = ScriptedClient([]);
    final channel = channelOver(client, token: () async => null);
    final listening = channel.signals.listen((_) {});

    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(client.requests, isEmpty);

    await listening.cancel();
    await channel.dispose();
  });

  test('a dropped stream reconnects and says so', () async {
    final first = StreamController<List<int>>();
    final second = StreamController<List<int>>();
    final client = ScriptedClient([
      () => http.StreamedResponse(first.stream, 200),
      () => http.StreamedResponse(second.stream, 200),
    ]);
    final channel = channelOver(client);
    final seen = <LiveSignal>[];
    final listening = channel.signals.listen(seen.add);

    await until(() => seen.contains(LiveSignal.connected));
    // The network went away without anybody being told.
    await first.close();

    await until(
      () => seen.where((s) => s == LiveSignal.connected).length == 2,
      reason: 'the channel never came back',
    );
    expect(
      seen,
      contains(LiveSignal.disconnected),
      reason: 'a drop has to be announced, or nothing starts polling',
    );

    await listening.cancel();
    await channel.dispose();
    await second.close();
  });

  test('a channel that never connects still says it is down', () async {
    // A proxy that refuses event streams. Without a signal here the service
    // would sit waiting for a wake-up from a channel that has never once been
    // up, and would never fall back to polling either.
    final client = ScriptedClient([]);
    final channel = channelOver(client);
    final seen = <LiveSignal>[];
    final listening = channel.signals.listen(seen.add);

    await until(() => seen.contains(LiveSignal.disconnected));
    expect(seen, isNot(contains(LiveSignal.connected)));

    await listening.cancel();
    await channel.dispose();
  });

  test('pausing and resuming reuses the same channel', () async {
    final first = StreamController<List<int>>();
    final second = StreamController<List<int>>();
    final client = ScriptedClient([
      () => http.StreamedResponse(first.stream, 200),
      () => http.StreamedResponse(second.stream, 200),
    ]);
    final channel = channelOver(client);

    final backgrounded = channel.signals.listen((_) {});
    await until(() => channel.isConnected);
    await backgrounded.cancel();
    await until(() => !channel.isConnected);

    // The api hands out one channel for the life of the session, so coming
    // back to the app listens to a stream that has already been listened to.
    final resumed = channel.signals.listen((_) {});
    await until(() => channel.isConnected);
    expect(client.requests, hasLength(2));

    await resumed.cancel();
    await channel.dispose();
    await first.close();
    await second.close();
  });

  test('cancelling the last listener closes the connection', () async {
    final body = StreamController<List<int>>();
    final client = ScriptedClient([
      () => http.StreamedResponse(body.stream, 200),
    ]);
    final channel = channelOver(client);
    final listening = channel.signals.listen((_) {});

    await until(() => channel.isConnected);
    await listening.cancel();

    // The socket exists only while something is waiting on it, and the
    // reconnect loop has to stop with it rather than dialling forever.
    await until(() => !channel.isConnected);
    final dialled = client.requests.length;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(client.requests, hasLength(dialled));

    await channel.dispose();
    await body.close();
  });
}
