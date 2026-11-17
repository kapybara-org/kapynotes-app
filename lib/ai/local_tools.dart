import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/platform.dart';
import 'answer_engine.dart';
import 'kapy_ai.dart';

/// Set by macOS in the environment of a sandboxed app, and only then.
const String appSandboxVariable = 'APP_SANDBOX_CONTAINER_ID';

/// What a check of a local tool found.
typedef LocalToolCheck = ({KapyAccountStatus status, List<KapyModel> models});

/// A coding agent the person installed and signed in to themselves, run on
/// this computer as a subprocess: Codex or Claude Code.
///
/// Kapy never signs in to either, never reads their credentials, and never
/// draws a field for them. It finds the program, asks it whether it is
/// signed in, and hands it a prompt. Desktop only.
///
/// Both are agents, built to run commands and edit files, and the prompt
/// carries notes that anyone could have written: a pasted page, a shared
/// note. So each runs as a writer and nothing more, with every control its
/// own CLI has for that: no tools, no shell, no web, no MCP servers, no
/// project or user configuration, no approvals to ask for, no session kept,
/// in a new empty directory deleted afterwards. The program is started
/// directly with an argument list, never through a shell, and with a small
/// environment of its own rather than the app's. The prompt goes in on
/// stdin, and a run that takes longer than the timeout (120 seconds) or says
/// more than [_maxOutput] is killed with its child processes.
///
/// The macOS app is sandboxed (macos/Runner/*.entitlements), and a sandboxed
/// app's children inherit its sandbox: a tool installed under the home
/// directory is not found, and one found elsewhere cannot read its own
/// sign-in. So `KapyAiController` does not offer either while the app runs
/// sandboxed ([appSandboxVariable] is set).
abstract class LocalTool implements AnswerEngine {
  KapyAccountKind get kind;

  /// Finds the program and asks it whether it is signed in: not connected
  /// when it is not installed, an error when it is signed out.
  Future<LocalToolCheck> check();
}

/// One run of a local tool's program.
typedef _Run = ({int exitCode, String stdout});

abstract class _Cli implements LocalTool {
  _Cli(this._executable, this._timeout, Map<String, String>? environment)
    : _parent = environment ?? Platform.environment;

  /// The program, when the caller already knows where it is; found on PATH
  /// and in the usual install locations otherwise.
  final String? _executable;

  /// A run that takes longer is killed.
  final Duration _timeout;

  /// The app's own environment, which a run is built from but never given.
  final Map<String, String> _parent;
  String? _found;

  String get _name;
  String get _label;

  /// Where installers put it besides PATH, under the home directory.
  List<String> get _homeDirs;

  static const Duration defaultTimeout = Duration(seconds: 120);

  /// An answer is a few paragraphs. Past this the program is doing
  /// something else, and is stopped rather than read.
  static const int _maxOutput = 64 * 1024;

  /// Where the program may be: the app's PATH and the usual install
  /// locations.
  List<String> get _searchDirs {
    final home = _parent['HOME'] ?? _parent['USERPROFILE'];
    return [
      ...?_parent['PATH']?.split(Platform.isWindows ? ';' : ':'),
      if (home != null)
        for (final dir in _homeDirs) '$home/$dir',
      if (!Platform.isWindows) ...[
        '/opt/homebrew/bin',
        '/usr/local/bin',
        '/usr/bin',
        '/bin',
      ],
      if (_parent['APPDATA'] case final appData?) '$appData/npm',
    ].where((dir) => dir.isNotEmpty).toList();
  }

  /// What a run is given instead of the app's environment: enough to find
  /// the program's own sign-in and to run, and nothing the app may hold
  /// (keys, tokens, anything a build or a shell put there). [scratch] is its
  /// temporary directory.
  Map<String, String> _childEnvironment(Directory scratch) {
    final windows = Platform.isWindows;
    final keep = {
      'HOME',
      'USER',
      'LOGNAME',
      'LANG',
      'SHELL',
      'CODEX_HOME',
      'CLAUDE_CONFIG_DIR',
      if (windows) ...[
        'SystemRoot',
        'USERPROFILE',
        'APPDATA',
        'LOCALAPPDATA',
        'PATHEXT',
        'ComSpec',
      ],
    };
    return {
      for (final entry in _parent.entries)
        if (keep.contains(entry.key) || entry.key.startsWith('LC_'))
          entry.key: entry.value,
      'PATH': _searchDirs.join(windows ? ';' : ':'),
      if (windows) ...{'TEMP': scratch.path, 'TMP': scratch.path},
      if (!windows) 'TMPDIR': scratch.path,
    };
  }

  Future<String?> _find() async {
    if (_executable != null) {
      return _found = await File(_executable).exists() ? _executable : null;
    }
    final names = Platform.isWindows ? ['$_name.exe', '$_name.cmd'] : [_name];
    for (final dir in _searchDirs) {
      for (final name in names) {
        final path = '$dir${Platform.pathSeparator}$name';
        if (await File(path).exists()) return _found = path;
      }
    }
    return _found = null;
  }

  @override
  Future<LocalToolCheck> check() async {
    const none = <KapyModel>[];
    if (!AppPlatform.isDesktop || await _find() == null) {
      return (status: KapyAccountStatus.notConnected, models: none);
    }
    try {
      if (!await _signedIn()) {
        return (status: KapyAccountStatus.error, models: none);
      }
      return (status: KapyAccountStatus.connected, models: await _models());
    } on Exception {
      return (status: KapyAccountStatus.error, models: none);
    }
  }

  Future<bool> _signedIn();
  Future<List<KapyModel>> _models();

  /// Runs the program once in a new empty directory, which is deleted
  /// afterwards whatever happened.
  Future<_Run> _run(List<String> arguments, {String? stdin}) async {
    final program = _found ?? await _find();
    if (program == null) throw AnswerAccountRejected(kind);
    final scratch = await Directory.systemTemp.createTemp('kapy-ai-');
    try {
      final Process process;
      try {
        process = await Process.start(
          program,
          arguments,
          workingDirectory: scratch.path,
          environment: _childEnvironment(scratch),
          includeParentEnvironment: false,
        );
      } on ProcessException {
        throw AnswerAccountRejected(kind);
      }
      final out = BytesBuilder(copy: false);
      var tooLong = false;
      final reading = process.stdout.listen((chunk) {
        if (out.length + chunk.length > _maxOutput) {
          tooLong = true;
          unawaited(_kill(process));
          return;
        }
        out.add(chunk);
      });
      final draining = process.stderr.drain<void>();
      // A program that exits before reading its prompt closes the pipe; that
      // is its answer, not an error here.
      unawaited(process.stdin.done.catchError((_) {}));
      try {
        if (stdin != null) process.stdin.add(utf8.encode(stdin));
        await process.stdin.close();
      } on Object {
        // Read below, from what the program said.
      }
      final int code;
      try {
        code = await process.exitCode.timeout(_timeout);
      } on TimeoutException {
        await _kill(process);
        throw AnswerFailed('$_label took too long to answer.');
      } finally {
        await reading.cancel();
        unawaited(draining.catchError((_) {}));
      }
      if (tooLong) throw AnswerFailed('$_label wrote more than an answer.');
      return (
        exitCode: code,
        stdout: utf8.decode(out.takeBytes(), allowMalformed: true),
      );
    } finally {
      await scratch.delete(recursive: true).catchError((_) => scratch);
    }
  }

  /// Stops the program and everything it started, to the last descendant.
  ///
  /// The tree is read before anything is killed: a parent that dies first
  /// leaves its children to be adopted by init, out of reach of the walk.
  Future<void> _kill(Process process) async {
    if (Platform.isWindows) {
      await Process.run('taskkill', ['/T', '/F', '/PID', '${process.pid}']);
      process.kill();
      return;
    }
    final tree = <int>[process.pid];
    for (var i = 0; i < tree.length; i++) {
      final children = await Process.run('pgrep', ['-P', '${tree[i]}']);
      tree.addAll([
        for (final line in '${children.stdout}'.split('\n'))
          ?int.tryParse(line.trim()),
      ]);
    }
    for (final pid in tree.reversed) {
      Process.killPid(pid, ProcessSignal.sigkill);
    }
  }

  @override
  Future<String> answer(KapyModel model, AnswerRequest request) async {
    final text = await _answer(model, request);
    if (text != null && text.isNotEmpty) return text;
    if (!await _signedIn()) throw AnswerAccountRejected(kind);
    throw AnswerFailed("$_label couldn't answer. Try again.");
  }

  /// The answer, or null when the program gave none.
  Future<String?> _answer(KapyModel model, AnswerRequest request);
}

/// OpenAI's Codex CLI, signed in with the person's ChatGPT plan or key.
class CodexCli extends _Cli {
  CodexCli({
    String? executable,
    Duration timeout = _Cli.defaultTimeout,
    Map<String, String>? environment,
  }) : super(executable, timeout, environment);

  @override
  KapyAccountKind get kind => KapyAccountKind.codex;

  @override
  String get _name => 'codex';

  @override
  String get _label => 'Codex';

  @override
  List<String> get _homeDirs => const [
    '.local/bin',
    '.codex/bin',
    '.npm-global/bin',
  ];

  /// Exits 0 only when signed in.
  @override
  Future<bool> _signedIn() async =>
      (await _run(const ['login', 'status'])).exitCode == 0;

  /// The account's own catalogue, as Codex's model picker lists it.
  @override
  Future<List<KapyModel>> _models() async {
    final run = await _run(const ['debug', 'models']);
    if (run.exitCode != 0) return const [_fallback];
    final catalogue = jsonDecode(run.stdout);
    final models = [
      for (final raw
          in (catalogue is Map ? catalogue['models'] : null) as List? ??
              const [])
        if (raw is Map &&
            raw['visibility'] == 'list' &&
            raw['slug'] is String &&
            raw['display_name'] is String)
          KapyModel(
            kind: KapyModelKind.codex,
            id: raw['slug'] as String,
            label: raw['display_name'] as String,
          ),
    ];
    return models.isEmpty ? const [_fallback] : models;
  }

  /// Whatever Codex is set to use, for a Codex whose catalogue could not be
  /// read. Sent without `--model`.
  static const KapyModel _fallback = KapyModel(
    kind: KapyModelKind.codex,
    id: '',
    label: 'Codex default',
  );

  /// What turns Codex from an agent into a writer, checked against
  /// `codex exec --help` and `codex features list` (0.160).
  ///
  /// The shell tool off removes command execution altogether; the read-only
  /// sandbox and an approval policy of never are what is left if a newer
  /// Codex brings one back. Web search, MCP servers, apps, plugins, browser
  /// and computer use, image tools, sub-agents, memories and hooks are off,
  /// and the person's own config and rules are not loaded, so nothing there
  /// can turn any of it back on. Sign-in still comes from Codex's home.
  static const List<String> lockedDown = [
    '--sandbox',
    'read-only',
    '--config',
    'approval_policy="never"',
    '--config',
    'web_search="disabled"',
    '--config',
    'mcp_servers={}',
    '--disable',
    'shell_tool',
    '--disable',
    'apps',
    '--disable',
    'plugins',
    '--disable',
    'browser_use',
    '--disable',
    'browser_use_external',
    '--disable',
    'in_app_browser',
    '--disable',
    'computer_use',
    '--disable',
    'code_mode_host',
    '--disable',
    'image_generation',
    '--disable',
    'view_image',
    '--disable',
    'multi_agent',
    '--disable',
    'memories',
    '--disable',
    'hooks',
    '--disable',
    'skill_search',
    '--disable',
    'tool_suggest',
    '--ignore-user-config',
    '--ignore-rules',
    '--skip-git-repo-check',
    '--ephemeral',
    '--color',
    'never',
  ];

  /// The prompt goes in on stdin (`-`); Codex prints its progress on stderr
  /// and only the final message on stdout.
  @override
  Future<String?> _answer(KapyModel model, AnswerRequest request) async {
    final run = await _run(
      [
        'exec',
        if (model.id.isNotEmpty) ...['--model', model.id],
        ...lockedDown,
        '-',
      ],
      stdin:
          '${answerInstructions(request.today)}\n\n'
          '${answerPromptWithHistory(request)}',
    );
    return run.exitCode == 0 ? run.stdout.trim() : null;
  }
}

/// Anthropic's Claude Code, signed in with the person's Claude plan or key.
class ClaudeCodeCli extends _Cli {
  ClaudeCodeCli({
    String? executable,
    Duration timeout = _Cli.defaultTimeout,
    Map<String, String>? environment,
  }) : super(executable, timeout, environment);

  @override
  KapyAccountKind get kind => KapyAccountKind.claudeCode;

  @override
  String get _name => 'claude';

  @override
  String get _label => 'Claude Code';

  @override
  List<String> get _homeDirs => const [
    '.local/bin',
    '.claude/local',
    '.npm-global/bin',
  ];

  /// `claude auth status` exits 0 only when signed in.
  @override
  Future<bool> _signedIn() async =>
      (await _run(const ['auth', 'status'])).exitCode == 0;

  /// Claude Code takes aliases that follow Anthropic's newest models, so the
  /// list is the two it offers by name.
  @override
  Future<List<KapyModel>> _models() async => const [
    KapyModel(
      kind: KapyModelKind.claudeCode,
      id: 'sonnet',
      label: 'Claude Sonnet 5.5',
    ),
    KapyModel(
      kind: KapyModelKind.claudeCode,
      id: 'opus',
      label: 'Claude Opus 5.5',
    ),
  ];

  /// What turns Claude Code from an agent into a writer, checked against
  /// `claude --help` (2.1).
  ///
  /// No built-in tools, none allowed, the dangerous ones denied by name as
  /// well, and a permission mode that refuses whatever was not allowed
  /// rather than asking. Restricted mode drops the command-running tools and
  /// the person's settings files; safe mode drops CLAUDE.md, skills,
  /// plugins, hooks and MCP servers; an empty, strict MCP config makes sure
  /// of the last. Sign-in is untouched.
  static const List<String> lockedDown = [
    '--tools',
    '',
    '--allowedTools',
    '',
    '--disallowedTools',
    'Bash,PowerShell,Read,Write,Edit,MultiEdit,NotebookEdit,Glob,Grep,LS,'
        'WebFetch,WebSearch,Task,Agent,Skill,TodoWrite',
    '--permission-mode',
    'dontAsk',
    '--restricted',
    '--safe-mode',
    '--strict-mcp-config',
    '--mcp-config',
    '{"mcpServers":{}}',
    '--disable-slash-commands',
    '--no-session-persistence',
  ];

  /// Print mode, one prompt in on stdin and one answer out, as JSON so the
  /// answer is told apart from an error.
  @override
  Future<String?> _answer(KapyModel model, AnswerRequest request) async {
    final run = await _run([
      '--print',
      '--model',
      model.id,
      ...lockedDown,
      '--output-format',
      'json',
      '--system-prompt',
      answerInstructions(request.today),
    ], stdin: answerPromptWithHistory(request));
    try {
      final body = jsonDecode(run.stdout);
      if (body is Map && body['is_error'] != true && body['result'] is String) {
        return (body['result'] as String).trim();
      }
    } on FormatException {
      // No JSON: nothing to read an answer from.
    }
    return null;
  }
}
