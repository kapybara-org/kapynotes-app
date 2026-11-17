import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ai/tool_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(MacToolHelper.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  const request = HelperRequest(
    tool: 'claude',
    arguments: ['--print', '--model', 'sonnet'],
    stdin: 'the notes',
    timeout: Duration(seconds: 120),
    maxOutput: 65536,
    expectedVersion: '2.1.326 (Claude Code)',
  );

  test('available only when the helper answers the ping', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'ping');
      return true;
    });
    expect(await const MacToolHelper().available(), isTrue);

    messenger.setMockMethodCallHandler(channel, (_) async => false);
    expect(await const MacToolHelper().available(), isFalse);

    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'unavailable'),
    );
    expect(await const MacToolHelper().available(), isFalse);

    messenger.setMockMethodCallHandler(channel, null);
    expect(await const MacToolHelper().available(), isFalse);
  });

  test('a run goes as one JSON request and comes back read', () async {
    Object? sent;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'run');
      sent = jsonDecode(call.arguments as String);
      return '{"outcome":"ran","exitCode":0,"stdout":"the answer"}';
    });
    final result = await const MacToolHelper().run(request);
    expect(result.outcome, HelperOutcome.ran);
    expect(result.exitCode, 0);
    expect(result.stdout, 'the answer');
    expect(sent, {
      'tool': 'claude',
      'arguments': ['--print', '--model', 'sonnet'],
      'stdin': 'the notes',
      'timeoutMs': 120000,
      'maxOutput': 65536,
      'freshHome': false,
      'expectedVersion': '2.1.326 (Claude Code)',
    });
  });

  test('every outcome name is read', () async {
    for (final outcome in HelperOutcome.values) {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => jsonEncode({'outcome': outcome.name}),
      );
      expect((await const MacToolHelper().run(request)).outcome, outcome);
    }
  });

  test('anything unreadable, or no helper, is a failed run', () async {
    for (final reply in [
      'not json',
      '[]',
      '{"outcome":"ranAway"}',
      '{}',
      null,
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async => reply);
      final result = await const MacToolHelper().run(request);
      expect(result.outcome, HelperOutcome.failed, reason: reply);
      expect(result.stdout, '');
    }
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'unavailable'),
    );
    expect(
      (await const MacToolHelper().run(request)).outcome,
      HelperOutcome.failed,
    );
    messenger.setMockMethodCallHandler(channel, null);
    expect(
      (await const MacToolHelper().run(request)).outcome,
      HelperOutcome.failed,
    );
  });
}
