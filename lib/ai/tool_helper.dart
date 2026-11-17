import 'dart:convert';

import 'package:flutter/services.dart';

/// How a run through the helper ended. The names are the helper's own
/// (`ToolRunner.Outcome` in macos/KapyToolRunner/ToolRunner.swift), and
/// test/ai/tool_runner_swift_test.dart keeps the two the same.
enum HelperOutcome {
  ran,
  refused,
  notInstalled,
  versionChanged,
  timedOut,
  tooLong,
  failed,
}

/// One run, as the helper takes it: a tool by name, never a path, and the
/// arguments local_tools.dart built, which the helper checks against its own
/// copy of the lockdown before it runs anything.
class HelperRequest {
  const HelperRequest({
    required this.tool,
    required this.arguments,
    this.stdin,
    required this.timeout,
    required this.maxOutput,
    this.freshHome = false,
    this.expectedVersion,
  });

  /// `codex` or `claude`.
  final String tool;
  final List<String> arguments;
  final String? stdin;
  final Duration timeout;
  final int maxOutput;

  /// Run with a new, empty CODEX_HOME: Codex's feature listing.
  final bool freshHome;

  /// What `--version` said when the tool was vetted. The helper runs the
  /// answer only if the program still says exactly this.
  final String? expectedVersion;

  Map<String, Object?> toJson() => {
    'tool': tool,
    'arguments': arguments,
    'stdin': stdin,
    'timeoutMs': timeout.inMilliseconds,
    'maxOutput': maxOutput,
    'freshHome': freshHome,
    'expectedVersion': expectedVersion,
  };
}

typedef HelperResult = ({HelperOutcome outcome, int exitCode, String stdout});

/// What runs Codex and Claude Code for an app that is sandboxed and so
/// cannot run them itself.
abstract interface class ToolHelper {
  /// Whether the helper is there and answers: false in a build without one
  /// (the Mac App Store build) or when either side fails the other's
  /// code-signing check.
  Future<bool> available();

  Future<HelperResult> run(HelperRequest request);
}

/// KapyToolRunner.xpc, through the `kapynotes/tool_runner` channel
/// (macos/Runner/ToolRunnerClient.swift).
class MacToolHelper implements ToolHelper {
  const MacToolHelper([this._channel = const MethodChannel(channelName)]);

  static const String channelName = 'kapynotes/tool_runner';
  final MethodChannel _channel;

  static const HelperResult _failed = (
    outcome: HelperOutcome.failed,
    exitCode: -1,
    stdout: '',
  );

  @override
  Future<bool> available() async {
    try {
      return await _channel.invokeMethod<bool>('ping') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<HelperResult> run(HelperRequest request) async {
    final String? reply;
    try {
      reply = await _channel.invokeMethod<String>(
        'run',
        jsonEncode(request.toJson()),
      );
    } on PlatformException {
      return _failed;
    } on MissingPluginException {
      return _failed;
    }
    try {
      final body = jsonDecode(reply ?? '');
      if (body is! Map) return _failed;
      final outcome = HelperOutcome.values.asNameMap()[body['outcome']];
      if (outcome == null) return _failed;
      return (
        outcome: outcome,
        exitCode: body['exitCode'] is int ? body['exitCode'] as int : -1,
        stdout: body['stdout'] is String ? body['stdout'] as String : '',
      );
    } on FormatException {
      return _failed;
    }
  }
}
