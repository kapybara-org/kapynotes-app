import 'dart:io';

/// A shell script standing in for the codex or claude binary.
///
/// Every run writes what it was given to its own folder under [log]: its
/// arguments one per NUL, its stdin, the directory it ran in and what that
/// held, and its environment. `login`, `auth`, `debug` and `features` answer
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
    String? beforeReply,
    String? afterReply,
  }) async {
    final root = await Directory.systemTemp.createTemp('fake-cli');
    final cli = FakeCli._(root);
    await cli.log.create();
    File('${cli.log.path}/reply').writeAsStringSync(reply);
    File('${cli.log.path}/signed_in_exit').writeAsStringSync('$signedInExit');
    File(
      '${cli.log.path}/models.json',
    ).writeAsStringSync(models ?? '{"models":[]}');
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

const String _script = r'''#!/bin/sh
LOG="@LOG@"
d="$LOG/run-$$"
mkdir "$d"
printf '%s\0' "$@" > "$d/argv"
pwd -P > "$d/cwd"
ls -A > "$d/cwdlist"
cat > "$d/stdin"
env > "$d/env"
case "$1" in *.js) shift ;; esac
case "$1" in
  login|auth) exit "$(cat "$LOG/signed_in_exit")" ;;
  debug) cat "$LOG/models.json"; exit 0 ;;
  features) cat "$LOG/features"; exit 0 ;;
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
