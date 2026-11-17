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
