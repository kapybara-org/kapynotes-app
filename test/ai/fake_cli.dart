import 'dart:io';

import 'package:kapy_notes/ai/local_tools.dart';
import 'package:kapy_notes/ai/tool_helper.dart';

/// A Codex the app will run: pinned at 0.160, which is what the stand-in
/// reports. The real pin is null until a canary has passed.
CodexCli codexCli({
  String? executable,
  Duration timeout = const Duration(seconds: 120),
  Map<String, String>? environment,
  bool? windows,
  (int, int)? pin = (0, 160),
  ToolHelper? helper,
}) => CodexCli(
  executable: executable,
  timeout: timeout,
  environment: environment,
  windows: windows,
  pin: pin,
  helper: helper,
);

/// A shell script standing in for the codex or claude binary.
///
/// Every run writes what it was given to its own folder under [log]: its
/// arguments one per NUL, its stdin, the directory it ran in and what that
/// held, and its environment. It fills the folder in beside [log] and moves it
/// in only when it is complete, so [runs] never reads a run that a status
/// check in the background is still writing. `login`, `auth`, `debug` and `features` answer
/// like the real ones; anything else is an answer and prints the `reply`
/// file. A first argument that is a `.js` file is a script run by node, and
/// is skipped: the stand-in is then the `node.exe` of a Windows shim.
class FakeCli {
  FakeCli._(this.root);

  final Directory root;
  Directory get log => Directory('${root.path}/log');
  String get path => '${root.path}/bin';

  static Future<FakeCli> create({
    String reply = 'the answer',
    int signedInExit = 0,
    String? models,
    String? features,
    String? featuresWithConfig,
    String version = 'codex-cli 0.160.0',
    String? beforeReply,
    String? afterReply,
  }) async {
    final root = await Directory.systemTemp.createTemp('fake-cli');
    final cli = FakeCli._(root);
    await cli.log.create();
    File('${cli.log.path}/reply').writeAsStringSync(reply);
    File('${cli.log.path}/signed_in_exit').writeAsStringSync('$signedInExit');
    File('${cli.log.path}/models.json').writeAsStringSync(models ?? _catalogue);
    File('${cli.log.path}/version').writeAsStringSync(version);
    File(
      '${cli.log.path}/features_with_config',
    ).writeAsStringSync(featuresWithConfig ?? knownFeatures);
    File(
      '${cli.log.path}/features',
    ).writeAsStringSync(features ?? knownFeatures);
    File(cli.path).writeAsStringSync(
      _script
          .replaceAll('@LOG@', cli.log.path)
          .replaceAll('@BEFORE@', beforeReply ?? '')
          .replaceAll('@AFTER@', afterReply ?? ''),
    );
    await Process.run('chmod', ['+x', cli.path]);
    return cli;
  }

  /// The runs that were an answer rather than a status check.
  List<CliRun> answers() => [
    for (final run in runs())
      if (run.argv.contains('exec') || run.argv.contains('--print')) run,
  ];

  List<CliRun> runs() => [
    for (final dir in log.listSync().whereType<Directory>())
      CliRun(
        argv: (File('${dir.path}/argv').readAsStringSync().split('\u0000')
          ..removeLast()),
        stdin: File('${dir.path}/stdin').readAsStringSync(),
        cwd: File('${dir.path}/cwd').readAsStringSync().trim(),
        cwdList: File('${dir.path}/cwdlist').readAsStringSync().trim(),
        env: File('${dir.path}/env').readAsStringSync(),
      ),
  ];

  /// A status check the controller started in the background may still be
  /// writing; the temp folder is the system's to clean up if it is.
  void dispose() {
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      return;
    }
  }
}

/// `codex features list` as 0.160 prints it once the lockdown is applied:
/// name, stage, and whether it is on. Every feature that is on is one the app
/// has read.
const String knownFeatures = '''
shell_tool                         stable             false
unified_exec                       stable             true
unified_exec_tty                   stable             false
steer                              removed            true
fast_mode                          stable             true
tool_call_mcp_elicitation          stable             true
code_mode                          under development  false
''';

/// The macOS helper, standing in for KapyToolRunner.xpc: records every
/// request and answers it as the real tools would, unless [reply] says
/// otherwise.
class FakeToolHelper implements ToolHelper {
  FakeToolHelper({this.answers = true, this.reply});

  bool answers;
  int pings = 0;
  HelperResult? Function(HelperRequest request)? reply;
  final List<HelperRequest> requests = [];

  @override
  Future<bool> available() async {
    pings++;
    return answers;
  }

  @override
  Future<HelperResult> run(HelperRequest request) async {
    requests.add(request);
    if (reply?.call(request) case final result?) return result;
    HelperResult ran(String stdout) =>
        (outcome: HelperOutcome.ran, exitCode: 0, stdout: stdout);
    return switch (request.arguments.first) {
      '--version' => ran(
        request.tool == 'codex'
            ? 'codex-cli 0.160.0\n'
            : '2.1.326 (Claude Code)\n',
      ),
      'features' => ran(knownFeatures),
      'debug' => ran(_catalogue),
      'exec' => ran('helper answer\n'),
      '--print' => ran('{"result":"helper answer"}'),
      _ => ran(''),
    };
  }
}

const String _catalogue =
    '{"models":[{"slug":"gpt-x","display_name":"GPT X","visibility":"list",'
    '"experimental_supported_tools":[]}]}';

const String _script = r'''#!/bin/sh
LOG="@LOG@"
d="$LOG.partial/run-$$"
mkdir -p "$d"
printf '%s\0' "$@" > "$d/argv"
pwd -P > "$d/cwd"
ls -A > "$d/cwdlist"
cat > "$d/stdin"
env > "$d/env"
mv "$d" "$LOG/"
case "$1" in *.js) shift ;; esac
case "$1" in
  login|auth) exit "$(cat "$LOG/signed_in_exit")" ;;
  debug) cat "$LOG/models.json"; exit 0 ;;
  --version) cat "$LOG/version"; exit 0 ;;
  features)
    if [ -f "${CODEX_HOME:-/nonexistent}/config.toml" ]; then
      cat "$LOG/features_with_config"
    else
      cat "$LOG/features"
    fi
    exit 0 ;;
esac
@BEFORE@
cat "$LOG/reply"
@AFTER@
exit "$(cat "$LOG/signed_in_exit")"
''';

class CliRun {
  const CliRun({
    required this.argv,
    required this.stdin,
    required this.cwd,
    required this.cwdList,
    required this.env,
  });

  final List<String> argv;
  final String stdin;
  final String cwd;
  final String cwdList;
  final String env;

  /// The argument after [flag].
  String after(String flag) => argv[argv.indexOf(flag) + 1];

  /// Every argument after [flag] while the flag repeats, in order.
  List<String> allAfter(String flag) => [
    for (var i = 0; i < argv.length - 1; i++)
      if (argv[i] == flag) argv[i + 1],
  ];
}
