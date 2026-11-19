import Darwin
import Foundation

/// Runs Codex or Claude Code for the sandboxed app, which cannot run them
/// itself: a sandboxed app's children inherit its sandbox, so they can
/// neither find a tool installed under the home directory nor read its
/// sign-in.
///
/// It is a narrow runner, not a shell. The app names a tool, never a path,
/// and passes the arguments lib/ai/local_tools.dart built; this file finds
/// the program in the usual install locations itself, and runs it only for
/// one of the exact command shapes in `check(_:)`, each with the whole
/// lockdown in `Lockdown`. Every run gets a small environment of its own, a
/// new empty working directory deleted afterwards, a timeout, an output
/// cap, and a process group of its own, which is killed whole when the run
/// ends, however it ends.
///
/// An answer names the version the app vetted at its last check, and the
/// program has to still say that version, and still be the same file, in
/// the same request, right before the answer runs: a tool that updated
/// itself since has not been vetted.
///
/// The helper does not take the app's word for what makes Codex safe. A
/// sandboxed app that was compromised could ask for any version, any model
/// or any feature set, outside the sandbox. So a Codex answer is only run
/// when, in the same request, the helper has itself checked that the version
/// is not newer than `codexTestedUpTo`, that `codex features list`, read
/// with the answer's own switches and a home of its own, shows nothing on
/// that is not in `Lockdown.codexKnownEnabled`, and that the model's entry in
/// `codex debug models` brings no tool of its own. All three mirror
/// lib/ai/local_tools.dart, and test/ai/tool_runner_swift_test.dart keeps
/// the copies the same.
enum ToolRunner {
  enum Tool: String, Decodable {
    case codex
    case claude
  }

  struct Request: Decodable {
    let tool: Tool
    let arguments: [String]
    let stdin: String?
    let timeoutMs: Int
    let maxOutput: Int
    let freshHome: Bool
    let expectedVersion: String?
  }

  /// test/ai/tool_runner_swift_test.dart checks that Dart's `HelperOutcome`
  /// has the same names.
  enum Outcome: String, Encodable {
    case ran
    case refused
    case notInstalled
    case versionChanged
    case timedOut
    case tooLong
    case failed
  }

  struct Response: Encodable {
    let outcome: Outcome
    var exitCode: Int32 = -1
    var stdout = ""
  }

  static let longestRun: TimeInterval = 120
  static let largestOutput = 2 * 1024 * 1024

  /// The newest Codex, as major and minor, that is run; nil while no live
  /// canary has passed, and then no Codex answer is run at all. Mirrors
  /// `CodexCli.testedUpTo`, and is set only with it.
  static let codexTestedUpTo: (major: Int, minor: Int)? = (0, 160)

  /// One request in, one response out, both JSON.
  static func handle(_ data: Data) -> Data {
    let response: Response
    if let request = try? JSONDecoder().decode(Request.self, from: data) {
      response = run(request)
    } else {
      response = Response(outcome: .refused)
    }
    return (try? JSONEncoder().encode(response)) ?? Data("{\"outcome\":\"failed\"}".utf8)
  }

  static func run(
    _ request: Request, home: String = Account.current.home,
    systemDirectories: [String] = systemDirectories,
    codexPin: (major: Int, minor: Int)? = codexTestedUpTo
  ) -> Response {
    guard check(request) else { return Response(outcome: .refused) }
    let path = searchPath(request.tool, home: home, system: systemDirectories)
    guard let program = locate(request.tool, in: path) else {
      return Response(outcome: .notInstalled)
    }
    let timeout = min(max(TimeInterval(request.timeoutMs) / 1000, 0.001), longestRun)
    let cap = min(max(request.maxOutput, 1), largestOutput)

    if let expected = request.expectedVersion {
      guard
        let before = FileIdentity(program),
        let said = try? spawnInScratch(
          program, ["--version"], path: path, home: home, stdin: nil,
          timeout: min(timeout, 20), cap: 4096, freshHome: false),
        said.end == .exited(0),
        String(decoding: said.stdout, as: UTF8.self)
          .trimmingCharacters(in: .whitespacesAndNewlines) == expected,
        FileIdentity(program) == before
      else { return Response(outcome: .versionChanged) }

      if request.tool == .codex {
        guard versionAccepted(expected, pin: codexPin) else { return Response(outcome: .refused) }
        let probe = { (arguments: [String], freshHome: Bool, cap: Int, limit: TimeInterval) in
          try? spawnInScratch(
            program, arguments, path: path, home: home, stdin: nil,
            timeout: min(timeout, limit), cap: cap, freshHome: freshHome)
        }
        guard
          let features = probe(["features", "list"] + Lockdown.codexSwitches, true, 1024 * 1024, 30),
          features.end == .exited(0), featuresAllowed(features.stdout),
          let catalogue = probe(["debug", "models"], false, largestOutput, 30),
          catalogue.end == .exited(0),
          modelAllowed(request.arguments[2], catalogue: catalogue.stdout),
          FileIdentity(program) == before
        else { return Response(outcome: .refused) }
      }
    }

    let result: Spawned
    do {
      result = try spawnInScratch(
        program, request.arguments, path: path, home: home,
        stdin: request.stdin.map { Data($0.utf8) },
        timeout: timeout, cap: cap, freshHome: request.freshHome)
    } catch {
      return Response(outcome: .failed)
    }
    switch result.end {
    case .timedOut:
      return Response(outcome: .timedOut)
    case .tooLong:
      return Response(outcome: .tooLong)
    case .exited(let code):
      return Response(
        outcome: .ran, exitCode: code,
        stdout: String(decoding: result.stdout, as: UTF8.self))
    case .signaled:
      return Response(outcome: .failed)
    }
  }

  // MARK: What Codex is read to be

  /// Whether `codex --version` (`codex-cli 0.160.0`) is `pin` or older. With
  /// no pin, or a version that cannot be read, it is not.
  static func versionAccepted(_ output: String, pin: (major: Int, minor: Int)?) -> Bool {
    guard let pin,
      let found = output.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression)
    else { return false }
    let parts = output[found].split(separator: ".").compactMap { Int($0) }
    guard parts.count == 3 else { return false }
    return parts[0] < pin.major || (parts[0] == pin.major && parts[1] <= pin.minor)
  }

  /// Whether `codex features list` shows nothing on that was not read: each
  /// line is a name, then its state, and one that is on has to be in
  /// `Lockdown.codexKnownEnabled`. A listing with no features in it is not
  /// one that was read.
  static func featuresAllowed(_ listing: Data) -> Bool {
    var any = false
    for line in String(decoding: listing, as: UTF8.self).split(separator: "\n") {
      let columns = line.split(whereSeparator: { $0.isWhitespace })
      guard columns.count >= 2, columns.last == "true" || columns.last == "false" else {
        continue
      }
      any = true
      if columns.last == "true", !Lockdown.codexKnownEnabled.contains(String(columns[0])) {
        return false
      }
    }
    return any
  }

  /// Whether `codex debug models` lists `model` for picking, with no tool of
  /// its own that was not reviewed (`Lockdown.codexReviewedTools`, none). A
  /// catalogue that cannot be read, or that does not hold the model, is not
  /// one that was read.
  static func modelAllowed(_ model: String, catalogue: Data) -> Bool {
    guard let root = (try? JSONSerialization.jsonObject(with: catalogue)) as? [String: Any],
      let models = root["models"] as? [Any]
    else { return false }
    return models.contains { raw in
      guard let entry = raw as? [String: Any] else { return false }
      let tools = entry["experimental_supported_tools"]
      let reviewed: Bool
      if tools == nil || tools is NSNull {
        reviewed = true
      } else if let list = tools as? [Any] {
        reviewed = list.allSatisfy { Lockdown.codexReviewedTools.contains($0 as? String ?? "") }
      } else {
        reviewed = false
      }
      return entry["slug"] as? String == model && entry["visibility"] as? String == "list"
        && entry["display_name"] is String && reviewed
    }
  }

  // MARK: What may run

  /// Whether the request is one of the runs the app makes, exactly: nothing
  /// added, nothing left out, nothing reordered. An answer must name the
  /// version it expects and nothing else may; only Codex's feature listing
  /// gets a home of its own, and it always does.
  static func check(_ request: Request) -> Bool {
    let args = request.arguments
    let answers: Bool
    switch request.tool {
    case .codex:
      if args == ["--version"] || args == ["login", "status"] || args == ["debug", "models"] {
        answers = false
      } else if args == ["features", "list"] + Lockdown.codexSwitches {
        return request.freshHome && request.expectedVersion == nil
      } else if args.count == 3 + Lockdown.codexExec.count + 1,
        args.starts(with: ["exec", "--model"]), isModel(args[2]),
        Array(args[3..<(args.count - 1)]) == Lockdown.codexExec, args.last == "-"
      {
        answers = true
      } else {
        return false
      }
    case .claude:
      let tail = ["--output-format", "json", "--system-prompt"]
      let lockdownEnd = 3 + Lockdown.claude.count
      if args == ["--version"] || args == ["auth", "status"] {
        answers = false
      } else if args.count == lockdownEnd + tail.count + 1,
        args.starts(with: ["--print", "--model"]), isModel(args[2]),
        Array(args[3..<lockdownEnd]) == Lockdown.claude,
        Array(args[lockdownEnd..<(args.count - 1)]) == tail,
        isPrompt(args[args.count - 1])
      {
        answers = true
      } else {
        return false
      }
    }
    guard !request.freshHome else { return false }
    return answers ? request.expectedVersion?.isEmpty == false : request.expectedVersion == nil
  }

  /// A model id as the pickers list them ("gpt-5.6-terra", "sonnet"), which
  /// no CLI can read as an option.
  static func isModel(_ text: String) -> Bool {
    text.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:/\[\]-]{0,127}$"#, options: .regularExpression) != nil
  }

  static func isPrompt(_ text: String) -> Bool {
    !text.isEmpty && !text.hasPrefix("-") && text.utf8.count <= 16 * 1024
  }

  // MARK: Where the program is

  static func homeDirectories(_ tool: Tool) -> [String] {
    switch tool {
    case .codex: return [".local/bin", ".codex/bin", ".npm-global/bin"]
    case .claude: return [".local/bin", ".claude/local", ".npm-global/bin"]
    }
  }

  static let systemDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

  /// Where the program is looked for, and the PATH it runs with.
  static func searchPath(_ tool: Tool, home: String, system: [String]) -> [String] {
    homeDirectories(tool).map { "\(home)/\($0)" } + system
  }

  /// The first executable regular file by the tool's name, followed through
  /// its links: what runs, and what the version check pins.
  static func locate(_ tool: Tool, in path: [String]) -> String? {
    for directory in path {
      let path = URL(fileURLWithPath: "\(directory)/\(tool.rawValue)")
        .resolvingSymlinksInPath().path
      var info = stat()
      if stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, access(path, X_OK) == 0 {
        return path
      }
    }
    return nil
  }

  /// The person running the helper, from the user database rather than an
  /// environment the app could have shaped.
  struct Account {
    let home: String
    let user: String
    let shell: String

    static var current: Account {
      guard let entry = getpwuid(getuid()) else {
        return Account(home: NSHomeDirectory(), user: NSUserName(), shell: "/bin/zsh")
      }
      return Account(
        home: String(cString: entry.pointee.pw_dir),
        user: String(cString: entry.pointee.pw_name),
        shell: String(cString: entry.pointee.pw_shell))
    }
  }

  struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modified: Int
    let modifiedNanos: Int

    init?(_ path: String) {
      var info = stat()
      guard stat(path, &info) == 0 else { return nil }
      device = info.st_dev
      inode = info.st_ino
      size = info.st_size
      modified = info.st_mtimespec.tv_sec
      modifiedNanos = info.st_mtimespec.tv_nsec
    }
  }

  // MARK: Running it

  enum End: Equatable {
    case exited(Int32)
    case signaled(Int32)
    case timedOut
    case tooLong
  }

  struct Spawned {
    let end: End
    let stdout: Data
  }

  /// Runs in a new empty directory (and, with `freshHome`, with a new empty
  /// CODEX_HOME), both deleted afterwards whatever happened.
  static func spawnInScratch(
    _ program: String, _ arguments: [String], path: [String], home: String,
    stdin: Data?, timeout: TimeInterval, cap: Int, freshHome: Bool
  ) throws -> Spawned {
    let scratch = try temporaryDirectory("kapy-ai-")
    defer { try? FileManager.default.removeItem(atPath: scratch) }
    let codexHome = freshHome ? try temporaryDirectory("kapy-ai-home-") : nil
    defer { if let codexHome { try? FileManager.default.removeItem(atPath: codexHome) } }
    let account = Account.current
    var environment = [
      "PATH": path.joined(separator: ":"),
      "HOME": home,
      "USER": account.user,
      "LOGNAME": account.user,
      "SHELL": account.shell,
      "TMPDIR": scratch,
      "LANG": ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8",
    ]
    for (key, value) in ProcessInfo.processInfo.environment where key.hasPrefix("LC_") {
      environment[key] = value
    }
    if let codexHome { environment["CODEX_HOME"] = codexHome }
    return try spawn(
      program, arguments, environment: environment, directory: scratch,
      stdin: stdin, timeout: timeout, cap: cap)
  }

  static func temporaryDirectory(_ prefix: String) throws -> String {
    var template = Array("\(NSTemporaryDirectory())\(prefix)XXXXXX".utf8CString)
    guard mkdtemp(&template) != nil else { throw POSIXError(.EIO) }
    return String(cString: template)
  }

  /// Starts the program in a process group of its own, with only stdin and
  /// stdout open to it (stderr goes nowhere), every signal at its default,
  /// and no other descriptor inherited. Waits for it to exit, the timeout,
  /// or the cap, then kills the whole group and every descendant it can
  /// still find, so nothing it started outlives the run.
  static func spawn(
    _ program: String, _ arguments: [String], environment: [String: String],
    directory: String, stdin: Data?, timeout: TimeInterval, cap: Int
  ) throws -> Spawned {
    var input: [Int32] = [-1, -1]
    var output: [Int32] = [-1, -1]
    guard pipe(&input) == 0 else { throw POSIXError(.EMFILE) }
    guard pipe(&output) == 0 else {
      close(input[0])
      close(input[1])
      throw POSIXError(.EMFILE)
    }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, input[0], 0)
    posix_spawn_file_actions_adddup2(&actions, output[1], 1)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addchdir_np(&actions, directory)

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(
      &attributes,
      Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
        | POSIX_SPAWN_SETSIGMASK))
    posix_spawnattr_setpgroup(&attributes, 0)
    var everySignal = sigset_t()
    sigfillset(&everySignal)
    posix_spawnattr_setsigdefault(&attributes, &everySignal)
    var noSignal = sigset_t()
    sigemptyset(&noSignal)
    posix_spawnattr_setsigmask(&attributes, &noSignal)

    let argv = ([program] + arguments).map { strdup($0) } + [nil]
    let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
      for pointer in argv { free(pointer) }
      for pointer in envp { free(pointer) }
    }

    var pid: pid_t = 0
    let started = posix_spawn(&pid, program, &actions, &attributes, argv, envp)
    close(input[0])
    close(output[1])
    guard started == 0 else {
      close(input[1])
      close(output[0])
      throw POSIXError(POSIXErrorCode(rawValue: started) ?? .EIO)
    }

    let writer = input[1]
    let writing = DispatchGroup()
    DispatchQueue.global().async(group: writing) {
      if let stdin {
        stdin.withUnsafeBytes { buffer in
          var offset = 0
          while offset < buffer.count {
            let written = write(writer, buffer.baseAddress! + offset, buffer.count - offset)
            if written < 0 {
              if errno == EINTR { continue }
              break
            }
            offset += written
          }
        }
      }
      close(writer)
    }

    let reader = Reader(fd: output[0], cap: cap) { killTree(pid) }
    let reading = DispatchGroup()
    DispatchQueue.global().async(group: reading) { reader.read() }

    let exited = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      var info = siginfo_t()
      while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) != 0, errno == EINTR {}
      exited.signal()
    }

    var timedOut = false
    if exited.wait(timeout: .now() + timeout) == .timedOut {
      timedOut = true
      killTree(pid)
      exited.wait()
    }
    // The leader stays a zombie until it is reaped below, so its process
    // group id cannot be handed to anyone else before the group is killed.
    killTree(pid)
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0, errno == EINTR {}

    if reading.wait(timeout: .now() + 2) == .timedOut {
      reader.stop()
      reading.wait()
    }
    close(output[0])
    writing.wait()

    if timedOut { return Spawned(end: .timedOut, stdout: Data()) }
    if reader.tooLong { return Spawned(end: .tooLong, stdout: Data()) }
    let signal = status & 0x7f
    return Spawned(
      end: signal == 0 ? .exited((status >> 8) & 0xff) : .signaled(signal),
      stdout: reader.data)
  }

  /// Kills the leader's process group, and every descendant found under it
  /// first: one that moved to a group of its own is still the child of
  /// something in the tree while the tree stands.
  static func killTree(_ leader: pid_t) {
    var tree = [leader]
    var index = 0
    while index < tree.count {
      var children = [pid_t](repeating: 0, count: 1024)
      let count = proc_listchildpids(
        tree[index], &children, Int32(children.count * MemoryLayout<pid_t>.size))
      if count > 0 {
        tree += children.prefix(min(Int(count), children.count)).filter {
          $0 > 1 && !tree.contains($0)
        }
      }
      index += 1
    }
    killpg(leader, SIGKILL)
    for pid in tree.reversed() { kill(pid, SIGKILL) }
  }

  /// Reads a run's stdout until it closes, until it says more than the cap,
  /// which kills the run, or until it is told to stop.
  final class Reader {
    private let fd: Int32
    private let cap: Int
    private let overflow: () -> Void
    private let lock = NSLock()
    private var stopped = false
    private(set) var data = Data()
    private(set) var tooLong = false

    init(fd: Int32, cap: Int, overflow: @escaping () -> Void) {
      self.fd = fd
      self.cap = cap
      self.overflow = overflow
    }

    func stop() {
      lock.lock()
      stopped = true
      lock.unlock()
    }

    private var isStopped: Bool {
      lock.lock()
      defer { lock.unlock() }
      return stopped
    }

    func read() {
      var buffer = [UInt8](repeating: 0, count: 64 * 1024)
      var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      while !isStopped {
        let ready = poll(&poller, 1, 100)
        if ready < 0 && errno != EINTR { return }
        if ready <= 0 { continue }
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count < 0 && errno == EINTR { continue }
        if count <= 0 { return }
        if data.count + count > cap {
          tooLong = true
          overflow()
          return
        }
        data.append(buffer, count: count)
      }
    }
  }
}

/// The arguments every run must carry, as lib/ai/local_tools.dart builds
/// them. test/ai/tool_runner_swift_test.dart reads these lists from this
/// file and fails when they differ from Dart's, order included.
enum Lockdown {
  static let codexSwitches: [String] = [
    "--config", "approval_policy=\"never\"",
    "--config", "web_search=\"disabled\"",
    "--config", "mcp_servers={}",
    "--disable", "shell_tool",
    "--disable", "unified_exec",
    "--disable", "unified_exec_tty",
    "--disable", "unified_exec_zsh_fork",
    "--disable", "write_stdin_approval",
    "--disable", "sleep_tool",
    "--disable", "worktrees",
    "--disable", "workspace_dependencies",
    "--disable", "in_app_local_automation",
    "--disable", "daemon_auto_start",
    "--disable", "skill_mcp_dependency_install",
    "--disable", "apps",
    "--disable", "plugins",
    "--disable", "plugin_sharing",
    "--disable", "remote_plugin",
    "--disable", "goals",
    "--disable", "browser_use",
    "--disable", "browser_use_external",
    "--disable", "browser_use_full_cdp_access",
    "--disable", "in_app_browser",
    "--disable", "computer_use",
    "--disable", "code_mode_host",
    "--disable", "image_generation",
    "--disable", "view_image",
    "--disable", "multi_agent",
    "--disable", "memories",
    "--disable", "hooks",
    "--disable", "skill_search",
    "--disable", "tool_suggest",
  ]

  /// What `codex features list` may still show as on under `codexSwitches`:
  /// `CodexCli.knownEnabled`, read in 0.160. A feature on that is not here
  /// has not been read, and no answer is run until it is.
  static let codexKnownEnabled: [String] = [
    "auth_elicitation",
    "collaboration_modes",
    "compaction_image_budget",
    "content_item_kinds",
    "enable_request_compression",
    "fast_mode",
    "guardian_approval",
    "guardian_reuse_parent_compaction",
    "in_app_chat",
    "in_app_dictation",
    "in_app_updates",
    "item_ids",
    "mentions_v2",
    "realtime_conversation",
    "resize_all_images",
    "shell_snapshot",
    "sqlite",
    "steer",
    "system_proxy_fallback",
    "terminal_resize_reflow",
    "tool_call_mcp_elicitation",
    "tool_search_always_defer_mcp_tools",
    "tui_app_server",
    "unbounded_connection_retries",
    "unified_exec",
  ]

  /// The tools a model's catalogue entry may bring and still be run:
  /// `CodexCli.reviewedTools`. None has been shown to be harmless.
  static let codexReviewedTools: [String] = [
  ]

  static let codexExecHead: [String] = ["--sandbox", "read-only"]

  static let codexExecTail: [String] = [
    "--ignore-user-config",
    "--ignore-rules",
    "--skip-git-repo-check",
    "--ephemeral",
    "--color", "never",
  ]

  static let codexExec = codexExecHead + codexSwitches + codexExecTail

  static let claude: [String] = [
    "--tools", "",
    "--allowedTools", "",
    "--disallowedTools",
    "Bash,PowerShell,Read,Write,Edit,MultiEdit,NotebookEdit,Glob,Grep,LS,WebFetch,WebSearch,Task,Agent,Skill,TodoWrite",
    "--permission-mode", "dontAsk",
    "--safe-mode",
    "--strict-mcp-config",
    "--mcp-config", "{\"mcpServers\":{}}",
    "--disable-slash-commands",
    "--no-session-persistence",
  ]
}
