import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ai/local_tools.dart';
import 'package:kapy_notes/ai/tool_helper.dart';

/// The helper keeps its own copy of the lockdown and refuses any run that
/// differs from it (macos/KapyToolRunner/ToolRunner.swift). These read that
/// file, so the two copies cannot drift apart unnoticed.
void main() {
  final swift = File(
    'macos/KapyToolRunner/ToolRunner.swift',
  ).readAsStringSync();

  List<String> strings(String source) => [
    for (final match in RegExp(r'"((?:[^"\\]|\\.)*)"').allMatches(source))
      match[1]!.replaceAllMapped(RegExp(r'\\(.)'), (m) => m[1]!),
  ];

  List<String> list(String name) {
    final match = RegExp(
      'static let $name: \\[String\\] = \\[([\\s\\S]*?)\\]\\s*\\n',
    ).firstMatch(swift);
    expect(match, isNotNull, reason: name);
    return strings(match![1]!);
  }

  test("Codex's switches are the helper's", () {
    expect(list('codexSwitches'), CodexCli.switches);
  });

  test("Codex's answer lockdown is the helper's, in order", () {
    expect([
      ...list('codexExecHead'),
      ...list('codexSwitches'),
      ...list('codexExecTail'),
    ], CodexCli.lockedDown);
    expect(swift, contains('codexExecHead + codexSwitches + codexExecTail'));
  });

  test("Claude Code's lockdown is the helper's", () {
    expect(list('claude'), ClaudeCodeCli.lockedDown);
  });

  test("Codex's pin is the helper's, nil while Dart's is null", () {
    final match = RegExp(
      r'static let codexTestedUpTo: \(major: Int, minor: Int\)\? = (nil|\((\d+), (\d+)\))',
    ).firstMatch(swift);
    expect(match, isNotNull);
    final pin = CodexCli.testedUpTo;
    if (pin == null) {
      expect(match![1], 'nil');
    } else {
      expect([match![2], match[3]], ['${pin.$1}', '${pin.$2}']);
    }
  });

  test('the features Codex may show as on are the helper\'s', () {
    expect(list('codexKnownEnabled').toSet(), CodexCli.knownEnabled);
    expect(list('codexKnownEnabled'), hasLength(CodexCli.knownEnabled.length));
  });

  test('the tools a catalogue entry may bring are the helper\'s', () {
    expect(list('codexReviewedTools').toSet(), CodexCli.reviewedTools);
  });

  test('the helper runs the same three checks before a Codex answer', () {
    expect(swift, contains('versionAccepted(expected, pin: codexPin)'));
    expect(swift, contains('["features", "list"] + Lockdown.codexSwitches'));
    expect(swift, contains('["debug", "models"]'));
    expect(swift, contains('experimental_supported_tools'));
  });

  test(
    'the app only talks to a service named under its own bundle id and a dot',
    () {
      final client = File(
        'macos/Runner/ToolRunnerClient.swift',
      ).readAsStringSync();
      expect(
        client,
        contains('identifier.hasPrefix("com.kapybara.kapynotes."),'),
      );
      expect(client, isNot(contains('hasPrefix("com.kapybara.kapynotes")')));
    },
  );

  test('the outcomes have the same names on both sides', () {
    final body = RegExp(
      r'enum Outcome: String, Encodable \{([\s\S]*?)\}',
    ).firstMatch(swift)![1]!;
    expect([
      for (final m in RegExp(r'case (\w+)').allMatches(body)) m[1],
    ], HelperOutcome.values.map((o) => o.name));
  });

  test('a request has the fields the helper reads', () {
    final body = RegExp(
      r'struct Request: Decodable \{([\s\S]*?)\}',
    ).firstMatch(swift)![1]!;
    final fields = {
      for (final m in RegExp(r'let (\w+):').allMatches(body)) m[1],
    };
    final sent = const HelperRequest(
      tool: 'codex',
      arguments: [],
      timeout: Duration.zero,
      maxOutput: 0,
    ).toJson().keys.toSet();
    expect(sent, fields);
  });
}
