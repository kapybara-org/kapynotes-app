import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

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
  _Cli(
    this._executable,
    this._timeout,
    Map<String, String>? environment,
    bool? windows,
  ) : _parent = environment ?? Platform.environment,
      _windows = windows ?? Platform.isWindows;

  /// The program, when the caller already knows where it is; found on PATH
  /// and in the usual install locations otherwise.
  final String? _executable;

  /// A run that takes longer is killed.
  final Duration _timeout;

  /// The app's own environment, which a run is built from but never given.
  final Map<String, String> _parent;

  /// Whether to look for and start the program the way Windows does. Only
  /// tests set it.
  final bool _windows;
  String? _found;

  String get _name;
  String get _label;

  /// Where installers put it besides PATH, under the home directory.
  List<String> get _homeDirs;

  static const Duration defaultTimeout = Duration(seconds: 120);

  /// An answer is a few paragraphs. Past this the program is doing
  /// something else, and is stopped rather than read.
  static const int _maxOutput = 64 * 1024;

  /// Codex's model catalogue carries each model's full instructions: 260 KB
  /// in 0.160.
  static const int _maxCatalogue = 2 * 1024 * 1024;

  /// Where the program may be: the app's PATH and the usual install
  /// locations.
  List<String> get _searchDirs {
    final home = _parent['HOME'] ?? _parent['USERPROFILE'];
    return [
      ...?_parent['PATH']?.split(_windows ? ';' : ':'),
      if (home != null)
        for (final dir in _homeDirs) '$home/$dir',
      if (!_windows) ...[
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
  Map<String, String> _childEnvironment(
    Directory scratch,
    Map<String, String> overrides,
  ) {
    final windows = _windows;
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
      ...overrides,
    };
  }

  Future<String?> _find() async {
    if (_executable != null) {
      return _found = await File(_executable).exists() ? _executable : null;
    }
    final names = _windows ? ['$_name.exe', '$_name.cmd'] : [_name];
    for (final dir in _searchDirs) {
      for (final name in names) {
        final path = '$dir${_windows ? '\\' : '/'}$name';
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

  /// What to start to run the program with [arguments].
  ///
  /// A Windows `.cmd` or `.bat` shim, which is how npm installs these tools,
  /// is started through cmd.exe, and cmd.exe reads the arguments a second
  /// time: `&`, `|`, `^`, `%`, `!` and quotes in them mean something to it,
  /// and an empty argument can vanish. So the shim is read for the script it
  /// runs, and node runs that script directly, with the arguments as they
  /// are. A shim that is not that, or no node to run it with, is a program
  /// that cannot be run safely.
  @visibleForTesting
  Future<({String program, List<String> arguments})> launch(
    List<String> arguments,
  ) async {
    final program = _found ?? await _find();
    if (program == null) throw AnswerAccountRejected(kind);
    final lower = program.toLowerCase();
    if (!_windows || !(lower.endsWith('.cmd') || lower.endsWith('.bat'))) {
      return (program: program, arguments: arguments);
    }
    final directory = File(program).parent.path;
    final shim = await File(program).readAsString().catchError((_) => '');
    final relative = RegExp(
      r'"%dp0%\\([^"%]+\.(?:js|mjs|cjs))"',
      caseSensitive: false,
    ).firstMatch(shim)?[1];
    if (relative == null) throw AnswerAccountRejected(kind);
    final script = '$directory/${relative.replaceAll('\\', '/')}';
    if (!await File(script).exists()) throw AnswerAccountRejected(kind);
    for (final dir in [directory, ..._searchDirs]) {
      final node = '$dir/node.exe';
      if (await File(node).exists()) {
        return (program: node, arguments: [script, ...arguments]);
      }
    }
    throw AnswerAccountRejected(kind);
  }

  /// Runs the program once in a new empty directory, which is deleted
  /// afterwards whatever happened.
  Future<_Run> _run(
    List<String> arguments, {
    String? stdin,
    int maxOutput = _maxOutput,
    Map<String, String> environment = const {},
  }) async {
    final launch = await this.launch(arguments);
    final scratch = await Directory.systemTemp.createTemp('kapy-ai-');
    try {
      final Process process;
      try {
        process = await Process.start(
          launch.program,
          launch.arguments,
          workingDirectory: scratch.path,
          environment: _childEnvironment(scratch, environment),
          includeParentEnvironment: false,
        );
      } on ProcessException {
        throw AnswerAccountRejected(kind);
      }
      final out = BytesBuilder(copy: false);
      var tooLong = false;
      final reading = process.stdout.listen((chunk) {
        if (out.length + chunk.length > maxOutput) {
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
  /// Each process is stopped (SIGSTOP) before its children are read, so a
  /// program that is still starting children cannot start one between the
  /// walk and the kill. Only once the whole tree is stopped is it killed. A
  /// process that exits by itself before the walk reaches it still hands its
  /// children to launchd, out of reach; only a process group closes that gap,
  /// as the helper does.
  Future<void> _kill(Process process) async {
    if (Platform.isWindows) {
      await Process.run('taskkill', ['/T', '/F', '/PID', '${process.pid}']);
      process.kill();
      return;
    }
    final tree = <int>[process.pid];
    try {
      for (var i = 0; i < tree.length; i++) {
        Process.killPid(tree[i], ProcessSignal.sigstop);
        final children = await Process.run('pgrep', ['-P', '${tree[i]}']);
        tree.addAll([
          for (final line in '${children.stdout}'.split('\n'))
            ?int.tryParse(line.trim()),
        ]);
      }
    } finally {
      for (final pid in tree.reversed) {
        Process.killPid(pid, ProcessSignal.sigkill);
      }
    }
    await process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () => -1,
    );
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
    @visibleForTesting bool? windows,
    @visibleForTesting (int, int)? pin = testedUpTo,
  }) : _pin = pin,
       super(executable, timeout, environment, windows);

  final (int, int)? _pin;

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

  /// The account's own catalogue, as Codex's model picker lists it, less the
  /// models that bring a tool of their own.
  ///
  /// Some tools come from the catalogue rather than from a feature: in 0.160
  /// a model's `experimental_supported_tools` (`send_user_message_async` and
  /// `clock` on one of today's). A model is offered only when that list is
  /// empty or holds only tools in [_reviewedTools]. A catalogue that cannot
  /// be read, or that leaves nothing to offer, makes Codex unavailable: there
  /// is no "default model" to fall back to, because nobody has read it.
  @override
  Future<List<KapyModel>> _models() async {
    final run = await _run(const [
      'debug',
      'models',
    ], maxOutput: _Cli._maxCatalogue);
    if (run.exitCode != 0) throw AnswerAccountRejected(kind);
    final catalogue = jsonDecode(run.stdout);
    final models = [
      for (final raw
          in (catalogue is Map ? catalogue['models'] : null) as List? ??
              const [])
        if (raw is Map &&
            raw['visibility'] == 'list' &&
            raw['slug'] is String &&
            raw['display_name'] is String &&
            _toolsReviewed(raw['experimental_supported_tools']))
          KapyModel(
            kind: KapyModelKind.codex,
            id: raw['slug'] as String,
            label: raw['display_name'] as String,
          ),
    ];
    if (models.isEmpty) throw AnswerAccountRejected(kind);
    return models;
  }

  /// The tools a catalogue entry may bring and still be offered. Empty: none
  /// has been shown to be harmless, and one that reaches a person, a clock
  /// or anything else is not assumed to be.
  static const Set<String> _reviewedTools = {};

  static bool _toolsReviewed(Object? tools) =>
      tools == null ||
      tools is List && tools.every((tool) => _reviewedTools.contains(tool));

  /// What turns Codex from an agent into a writer, checked against
  /// `codex exec --help` and `codex features list` (0.160).
  ///
  /// The shell tool off removes command execution altogether; the read-only
  /// sandbox and an approval policy of never are what is left if a newer
  /// Codex brings one back. Web search, MCP servers, apps, plugins, browser
  /// and computer use, image tools, sub-agents, memories, hooks, background
  /// automation and the rest of [_disabled] are off, and the person's own
  /// config and rules are not loaded, so nothing there can turn any of it
  /// back on. Sign-in still comes from Codex's home.
  static final List<String> lockedDown = [
    '--sandbox',
    'read-only',
    ..._switches,
    '--ignore-user-config',
    '--ignore-rules',
    '--skip-git-repo-check',
    '--ephemeral',
    '--color',
    'never',
  ];

  static const List<String> _settings = [
    '--config',
    'approval_policy="never"',
    '--config',
    'web_search="disabled"',
    '--config',
    'mcp_servers={}',
  ];

  static const List<String> _disabled = [
    'shell_tool',
    'unified_exec',
    'unified_exec_tty',
    'unified_exec_zsh_fork',
    'write_stdin_approval',
    'sleep_tool',
    'worktrees',
    'workspace_dependencies',
    'in_app_local_automation',
    'daemon_auto_start',
    'skill_mcp_dependency_install',
    'apps',
    'plugins',
    'plugin_sharing',
    'remote_plugin',
    'goals',
    'browser_use',
    'browser_use_external',
    'browser_use_full_cdp_access',
    'in_app_browser',
    'computer_use',
    'code_mode_host',
    'image_generation',
    'view_image',
    'multi_agent',
    'memories',
    'hooks',
    'skill_search',
    'tool_suggest',
  ];

  static final List<String> _features = [
    for (final feature in _disabled) ...['--disable', feature],
  ];

  /// Every `--config` and `--disable` an answer runs with, and the same ones
  /// `features list` is read with: one list, so the gate cannot be shown a
  /// different Codex from the one that answers.
  static final List<String> _switches = [..._settings, ..._features];

  /// The newest Codex, as major and minor, that the app will run; null while
  /// no live canary has passed, and then no Codex is run and no model called.
  ///
  /// It is set to the canary's version (0.160 is the one everything here was
  /// read against) only once the one canary after 19 Nov has passed for
  /// every model family the picker offers: an injected note in an empty
  /// directory, and no file made, no secret read, no tool run. After that it
  /// rises only the same way, because a newer Codex can bring tools,
  /// features and models nobody has read.
  static const (int, int)? testedUpTo = null;

  /// Whether `codex --version` (`codex-cli 0.160.0`) is [pin] or older. With
  /// no pin, or a version that cannot be read, it is not.
  static bool versionAccepted(String output, (int, int)? pin) {
    final match = RegExp(r'(\d+)\.(\d+)\.\d+').firstMatch(output);
    if (pin == null || match == null) return false;
    final version = (int.parse(match[1]!), int.parse(match[2]!));
    return version.$1 < pin.$1 || version.$1 == pin.$1 && version.$2 <= pin.$2;
  }

  /// What `codex features list` may still show as on once [lockedDown] has
  /// been applied, each read in 0.160 and none of them able to run a command,
  /// reach a file, the web or a server, or talk to anyone: the app's own
  /// screens, request and transcript handling, sign-in prompts, voice, and
  /// approvals that `never` has already made moot. `unified_exec` is the
  /// one that is not obviously so: it is how a shell tool runs, Codex ignores
  /// `--disable` for it, and with `shell_tool` off there is no tool left to
  /// run, under a read-only sandbox that asks nothing.
  ///
  /// A feature on that is not here, a newer one or one that would not turn
  /// off, has not been read, and Codex is reported unavailable until it is.
  static const Set<String> _knownEnabled = {
    'auth_elicitation',
    'collaboration_modes',
    'compaction_image_budget',
    'content_item_kinds',
    'enable_request_compression',
    'fast_mode',
    'guardian_approval',
    'guardian_reuse_parent_compaction',
    'in_app_chat',
    'in_app_dictation',
    'in_app_updates',
    'item_ids',
    'mentions_v2',
    'realtime_conversation',
    'resize_all_images',
    'shell_snapshot',
    'sqlite',
    'steer',
    'system_proxy_fallback',
    'terminal_resize_reflow',
    'tool_call_mcp_elicitation',
    'tool_search_always_defer_mcp_tools',
    'tui_app_server',
    'unbounded_connection_retries',
    'unified_exec',
  };

  Future<bool>? _vetted;

  /// Whether this Codex is one the app has read: not newer than
  /// [testedUpTo] (and none at all while that is null), and with every feature it has on under [lockedDown] one
  /// that was read. Asked once per [check], from Codex itself, and a Codex
  /// that cannot say is not vetted.
  ///
  /// `features list` reads `config.toml` from Codex's home and cannot be told
  /// to ignore it, while an answer does ignore it (`--ignore-user-config`).
  /// So it runs with a home of its own, new and empty, and sees what an
  /// answer sees; only an answer gets the real one, for its sign-in.
  Future<bool> _isVetted() => _vetted ??= () async {
    final version = await _run(const ['--version']);
    if (version.exitCode != 0 || !versionAccepted(version.stdout, _pin)) {
      return false;
    }
    final home = await Directory.systemTemp.createTemp('kapy-ai-home-');
    final _Run run;
    try {
      run = await _run(
        ['features', 'list', ..._switches],
        environment: {'CODEX_HOME': home.path},
      );
    } finally {
      await home.delete(recursive: true).catchError((_) => home);
    }
    if (run.exitCode != 0) return false;
    final lines = run.stdout
        .split('\n')
        .map((line) => line.trim().split(RegExp(r'\s+')));
    var any = false;
    for (final columns in lines) {
      if (columns.length < 2 || !{'true', 'false'}.contains(columns.last)) {
        continue;
      }
      any = true;
      if (columns.last == 'true' && !_knownEnabled.contains(columns.first)) {
        return false;
      }
    }
    return any;
  }();

  @override
  Future<LocalToolCheck> check() {
    _vetted = null;
    return super.check();
  }

  /// Exits 0 only when signed in, and not at all when Codex is not vetted.
  @override
  Future<bool> _signedIn() async =>
      await _isVetted() &&
      (await _run(const ['login', 'status'])).exitCode == 0;

  /// The prompt goes in on stdin (`-`); Codex prints its progress on stderr
  /// and only the final message on stdout.
  @override
  Future<String?> _answer(KapyModel model, AnswerRequest request) async {
    if (model.id.isEmpty || !await _isVetted()) {
      throw AnswerAccountRejected(kind);
    }
    final run = await _run(
      ['exec', '--model', model.id, ...lockedDown, '-'],
      stdin:
          '${answerInstructions(request.today)}\n\n'
          '${answerPrompt(request)}',
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
    @visibleForTesting bool? windows,
  }) : super(executable, timeout, environment, windows);

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

  /// What turns Claude Code from an agent into a writer, every flag read in
  /// Claude Code's CLI reference and in `claude --help`, and each old enough
  /// for a 2.1.229 install.
  ///
  /// No built-in tools, none allowed, the dangerous ones denied by name as
  /// well, and a permission mode that refuses whatever was not allowed
  /// rather than asking. Safe mode (2.1.169) drops CLAUDE.md, skills,
  /// plugins, hooks and MCP servers; an empty, strict MCP config makes sure
  /// of the last. Sign-in is untouched. `--restricted` is left out: it is
  /// documented, but only from 2.1.248, and everything it does here is done
  /// by the flags above it.
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
    ], stdin: answerPrompt(request));
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
