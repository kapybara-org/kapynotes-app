import Foundation
import Security
import XCTest
import XPC

/// The helper's own rules, run in the xctest process with no app launched:
/// which commands it will run, how it runs them, how it ends them, and who
/// it will talk to.
final class ToolRunnerTests: XCTestCase {
  private var home: URL!
  private var log: URL!

  override func setUpWithError() throws {
    home = FileManager.default.temporaryDirectory
      .appendingPathComponent("kapy-runner-test-\(UUID().uuidString)")
    log = home.appendingPathComponent("log")
    try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: home)
  }

  // MARK: Stand-ins

  /// A stand-in for the tool at the first place the helper looks. It
  /// answers `--version` from log/version, and otherwise records what it
  /// was given and runs [body].
  private func install(_ tool: ToolRunner.Tool, _ body: String = "echo answer") throws {
    let bin = home.appendingPathComponent(".local/bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let file = bin.appendingPathComponent(tool.rawValue)
    let script = """
      #!/bin/sh
      LOG='\(log.path)'
      if [ "$1" = "--version" ]; then
        echo version >> "$LOG/calls"
        /bin/cat "$LOG/version" 2>/dev/null || echo "tool 1.0.0"
        exit 0
      fi
      if [ "$1" = "features" ]; then
        echo features >> "$LOG/calls"
        printf '%s\n' "$@" > "$LOG/argv_features"
        /usr/bin/env > "$LOG/env_features"
        /bin/cat "$LOG/features" 2>/dev/null || printf 'shell_tool  stable  false\nsqlite  stable  true\n'
        exit 0
      fi
      if [ "$1" = "debug" ]; then
        echo models >> "$LOG/calls"
        /bin/cat "$LOG/models" 2>/dev/null || echo '{"models":[{"slug":"gpt-x","display_name":"GPT X","visibility":"list"}]}'
        exit 0
      fi
      echo answer >> "$LOG/calls"
      printf '%s\n' "$@" > "$LOG/argv"
      /usr/bin/env > "$LOG/env"
      /bin/pwd -P > "$LOG/cwd"
      /bin/ls -A > "$LOG/cwdlist"
      /bin/cat > "$LOG/stdin"
      \(body)

      """
    try script.write(to: file, atomically: true, encoding: .utf8)
    chmod(file.path, 0o755)
  }

  private func logged(_ name: String) -> String? {
    try? String(contentsOf: log.appendingPathComponent(name), encoding: .utf8)
  }

  private static let codexAnswer = ["exec", "--model", "gpt-x"] + Lockdown.codexExec + ["-"]
  private static let codexFeatures = ["features", "list"] + Lockdown.codexSwitches
  private static let claudeAnswer =
    ["--print", "--model", "sonnet"] + Lockdown.claude
    + ["--output-format", "json", "--system-prompt", "Answer from the notes."]

  private func request(
    _ tool: ToolRunner.Tool, _ arguments: [String], stdin: String? = nil,
    timeoutMs: Int = 10_000, maxOutput: Int = 64 * 1024, freshHome: Bool = false,
    expectedVersion: String? = nil
  ) -> ToolRunner.Request {
    ToolRunner.Request(
      tool: tool, arguments: arguments, stdin: stdin, timeoutMs: timeoutMs,
      maxOutput: maxOutput, freshHome: freshHome, expectedVersion: expectedVersion)
  }

  /// With a pin that "tool 1.0.0" meets; the helper's own is nil until the
  /// canary has passed.
  private func run(
    _ request: ToolRunner.Request, pin: (major: Int, minor: Int)? = (major: 1, minor: 0)
  ) -> ToolRunner.Response {
    ToolRunner.run(request, home: home.path, systemDirectories: [], codexPin: pin)
  }

  private func write(_ text: String, to name: String) throws {
    try text.write(to: log.appendingPathComponent(name), atomically: true, encoding: .utf8)
  }

  private func calls() -> [String] {
    (logged("calls") ?? "").split(separator: "\n").map(String.init)
  }

  private func survivors(_ pattern: String) -> String {
    let pgrep = Process()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["-f", pattern]
    let out = Pipe()
    pgrep.standardOutput = out
    try? pgrep.run()
    pgrep.waitUntilExit()
    return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: What may run

  func testTheAppsOwnRunsAreAccepted() {
    for accepted in [
      request(.codex, ["--version"]),
      request(.codex, ["login", "status"]),
      request(.codex, ["debug", "models"]),
      request(.codex, Self.codexFeatures, freshHome: true),
      request(.codex, Self.codexAnswer, stdin: "q", expectedVersion: "codex-cli 0.160.0"),
      request(.claude, ["--version"]),
      request(.claude, ["auth", "status"]),
      request(.claude, Self.claudeAnswer, stdin: "q", expectedVersion: "2.1.326 (Claude Code)"),
    ] {
      XCTAssertTrue(ToolRunner.check(accepted), accepted.arguments.joined(separator: " "))
    }
  }

  func testAnythingElseIsRefusedAndNothingRuns() throws {
    try install(.codex)
    try install(.claude)
    var swapped = Self.codexAnswer
    swapped.swapAt(8, 10)
    swapped.swapAt(9, 11)
    var missing = Self.codexAnswer
    missing.removeSubrange(10...11)
    var claudeTools = Self.claudeAnswer
    claudeTools[4] = "default"
    let v = "tool 1.0.0"
    for refused in [
      request(.codex, []),
      request(.codex, ["logout"]),
      request(.codex, ["login"]),
      request(.codex, ["exec", "-"], expectedVersion: v),
      request(.codex, Self.codexAnswer),
      request(.codex, Self.codexAnswer, freshHome: true, expectedVersion: v),
      request(.codex, Array(Self.codexAnswer.dropLast()) + ["--yolo", "-"], expectedVersion: v),
      request(
        .codex,
        Array(Self.codexAnswer.dropLast())
          + ["--sandbox", "danger-full-access", "-"], expectedVersion: v),
      request(.codex, swapped, expectedVersion: v),
      request(.codex, missing, expectedVersion: v),
      request(
        .codex, ["exec", "--model", "--yolo"] + Lockdown.codexExec + ["-"], expectedVersion: v),
      request(.codex, ["exec", "--model", "a b"] + Lockdown.codexExec + ["-"], expectedVersion: v),
      request(.codex, Self.codexFeatures),
      request(.codex, Self.codexFeatures, freshHome: true, expectedVersion: v),
      request(.codex, ["--version"], expectedVersion: v),
      request(.codex, ["--version"], freshHome: true),
      request(.codex, Self.claudeAnswer, expectedVersion: v),
      request(.claude, Self.codexAnswer, expectedVersion: v),
      request(.claude, Self.claudeAnswer),
      request(.claude, Self.claudeAnswer, expectedVersion: ""),
      request(.claude, claudeTools, expectedVersion: v),
      request(
        .claude, Array(Self.claudeAnswer.dropLast()) + ["--dangerously-skip-permissions"],
        expectedVersion: v),
      request(
        .claude, Self.claudeAnswer + ["--dangerously-skip-permissions"], expectedVersion: v),
      request(.claude, ["auth", "login"]),
    ] {
      XCTAssertEqual(
        run(refused).outcome.rawValue, "refused", refused.arguments.joined(separator: " "))
    }
    XCTAssertNil(logged("argv"))
    let garbage = ToolRunner.handle(Data(#"{"tool":"bash","arguments":["-c","id"]}"#.utf8))
    XCTAssertTrue(String(decoding: garbage, as: UTF8.self).contains(#""outcome":"refused""#))
  }

  // MARK: How it runs

  func testAnAnswerRunsInAnEmptyDirectoryWithASmallEnvironment() throws {
    try install(.codex)
    setenv("KAPY_SECRET_PROBE", "leak-1", 1)
    defer { unsetenv("KAPY_SECRET_PROBE") }
    let response = run(
      request(.codex, Self.codexAnswer, stdin: "the notes", expectedVersion: "tool 1.0.0"))

    XCTAssertEqual(response.outcome.rawValue, "ran")
    XCTAssertEqual(response.exitCode, 0)
    XCTAssertEqual(response.stdout, "answer\n")
    XCTAssertEqual(logged("argv"), Self.codexAnswer.joined(separator: "\n") + "\n")
    XCTAssertEqual(logged("stdin"), "the notes")
    let cwd = try XCTUnwrap(logged("cwd")).trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertTrue(cwd.contains("kapy-ai-"), cwd)
    XCTAssertEqual(logged("cwdlist"), "")
    XCTAssertFalse(FileManager.default.fileExists(atPath: cwd))

    let env = try XCTUnwrap(logged("env"))
    XCTAssertFalse(env.contains("KAPY_SECRET_PROBE"))
    XCTAssertFalse(env.contains("leak-1"))
    var keys = Set<String>()
    for line in env.split(separator: "\n") {
      guard let equals = line.firstIndex(of: "=") else { continue }
      keys.insert(String(line[..<equals]))
    }
    let allowed: Set<String> = [
      "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "PWD", "SHLVL", "_",
      "OLDPWD",
    ]
    XCTAssertEqual(keys.filter { !$0.hasPrefix("LC_") }.subtracting(allowed), [])
    XCTAssertTrue(env.contains("HOME=\(home.path)\n"))
    XCTAssertTrue(env.contains("PATH=\(home.path)/.local/bin:"))
    XCTAssertFalse(keys.contains("CODEX_HOME"))
  }

  func testTheFeatureListGetsAHomeOfItsOwn() throws {
    try install(.codex)
    XCTAssertEqual(run(request(.codex, Self.codexFeatures, freshHome: true)).outcome.rawValue, "ran")
    let env = try XCTUnwrap(logged("env_features"))
    let line = try XCTUnwrap(env.split(separator: "\n").first { $0.hasPrefix("CODEX_HOME=") })
    let codexHome = String(line.dropFirst("CODEX_HOME=".count))
    XCTAssertTrue(codexHome.contains("kapy-ai-home-"), codexHome)
    XCTAssertFalse(codexHome.hasPrefix(home.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: codexHome))
  }

  func testTheProgramIsFoundByItsToolsName() throws {
    XCTAssertEqual(run(request(.codex, ["--version"])).outcome.rawValue, "notInstalled")
    try install(.claude)
    XCTAssertEqual(run(request(.codex, ["--version"])).outcome.rawValue, "notInstalled")
    XCTAssertEqual(run(request(.claude, ["--version"])).outcome.rawValue, "ran")
  }

  // MARK: What the helper reads for itself before a Codex answer

  func testWithNoPinOrANewerCodexNoAnswerRunsAndNothingBeyondTheVersionIsStarted() throws {
    try install(.codex)
    XCTAssertEqual(ToolRunner.codexTestedUpTo?.major, 0, "the pin moves with CodexCli.testedUpTo")
    XCTAssertEqual(ToolRunner.codexTestedUpTo?.minor, 160, "the pin moves with CodexCli.testedUpTo")
    let answer = request(.codex, Self.codexAnswer, stdin: "q", expectedVersion: "tool 1.0.0")
    for pin in [nil, ToolRunner.codexTestedUpTo] as [(major: Int, minor: Int)?] {
      XCTAssertEqual(run(answer, pin: pin).outcome.rawValue, "refused")
    }
    XCTAssertEqual(
      ToolRunner.run(answer, home: home.path, systemDirectories: []).outcome.rawValue, "refused")
    XCTAssertEqual(calls(), ["version", "version", "version"])
    XCTAssertNil(logged("argv"))
  }

  func testAVersionAboveThePinIsRefusedAndOnesUpToItRun() throws {
    try install(.codex)
    let pin = (major: 0, minor: 160)
    for (said, runs) in [
      ("codex-cli 0.160.0", true), ("codex-cli 0.159.7", true), ("codex-cli 0.160.12", true),
      ("codex-cli 0.161.0", false), ("codex-cli 0.200.0", false), ("codex-cli 1.0.0", false),
      ("codex-cli beta", false), ("", false),
    ] {
      try write(said + "\n", to: "version")
      try? FileManager.default.removeItem(at: log.appendingPathComponent("argv"))
      let response = run(
        request(.codex, Self.codexAnswer, stdin: "q", expectedVersion: said), pin: pin)
      XCTAssertEqual(response.outcome.rawValue, runs ? "ran" : "refused", said)
      XCTAssertEqual(logged("argv") != nil, runs, said)
    }
  }

  func testTheFeaturesAreReadInTheAnswersOwnRequestBeforeItRuns() throws {
    try install(.codex)
    let response = run(request(.codex, Self.codexAnswer, stdin: "q", expectedVersion: "tool 1.0.0"))
    XCTAssertEqual(response.outcome.rawValue, "ran")
    XCTAssertEqual(calls(), ["version", "features", "models", "answer"])
    XCTAssertEqual(logged("argv_features"), Self.codexFeatures.joined(separator: "\n") + "\n")
    let env = try XCTUnwrap(logged("env_features"))
    let line = try XCTUnwrap(env.split(separator: "\n").first { $0.hasPrefix("CODEX_HOME=") })
    XCTAssertTrue(line.contains("kapy-ai-home-"), String(line))
    XCTAssertFalse(line.contains(home.path))
  }

  func testAFeatureThatWasNotReadStopsTheAnswer() throws {
    try install(.codex)
    let answer = request(.codex, Self.codexAnswer, stdin: "q", expectedVersion: "tool 1.0.0")
    for listing in [
      "sqlite  stable  true\nbrand_new_tool  experimental  true\n",
      "shell_tool  stable  true\n",
      "",
      "nothing to see here\n",
    ] {
      try write(listing, to: "features")
      try? FileManager.default.removeItem(at: log.appendingPathComponent("calls"))
      XCTAssertEqual(run(answer).outcome.rawValue, "refused", listing)
      XCTAssertNil(logged("argv"), listing)
      XCTAssertEqual(calls(), ["version", "features"], listing)
    }
    try write("sqlite  stable  true\nbrand_new_tool  experimental  false\n", to: "features")
    XCTAssertEqual(run(answer).outcome.rawValue, "ran", "off is fine")
  }

  func testAModelThatBringsAToolOfItsOwnIsNotRun() throws {
    try install(.codex)
    let answer = request(.codex, Self.codexAnswer, stdin: "q", expectedVersion: "tool 1.0.0")
    func entry(_ extra: String, slug: String = "gpt-x", visibility: String = "list") -> String {
      #"{"models":[{"slug":"other","display_name":"O","visibility":"list"},{"slug":"\#(slug)","display_name":"X","visibility":"\#(visibility)"\#(extra)}]}"#
    }
    for catalogue in [
      entry(#","experimental_supported_tools":["clock"]"#),
      entry(#","experimental_supported_tools":["send_user_message_async","clock"]"#),
      entry(#","experimental_supported_tools":"clock""#),
      entry("", slug: "gpt-y"),
      entry("", visibility: "hide"),
      "not json",
      #"{"models":"none"}"#,
      #"{"models":[]}"#,
    ] {
      try write(catalogue, to: "models")
      try? FileManager.default.removeItem(at: log.appendingPathComponent("argv"))
      XCTAssertEqual(run(answer).outcome.rawValue, "refused", catalogue)
      XCTAssertNil(logged("argv"), catalogue)
    }
    for catalogue in [
      entry(""), entry(#","experimental_supported_tools":[]"#),
      entry(#","experimental_supported_tools":null"#),
    ] {
      try write(catalogue, to: "models")
      XCTAssertEqual(run(answer).outcome.rawValue, "ran", catalogue)
    }
  }

  func testClaudeCodeHasNoPinAndNoFeatureOrModelListing() throws {
    try install(.claude)
    let response = run(
      request(.claude, Self.claudeAnswer, stdin: "q", expectedVersion: "tool 1.0.0"), pin: nil)
    XCTAssertEqual(response.outcome.rawValue, "ran")
    XCTAssertEqual(calls(), ["version", "answer"])
  }

  // MARK: The version it was vetted at

  func testAnotherVersionThanTheVettedOneIsNotRun() throws {
    try install(.claude)
    try "2.1.400 (Claude Code)\n".write(
      to: log.appendingPathComponent("version"), atomically: true, encoding: .utf8)
    let response = run(
      request(.claude, Self.claudeAnswer, stdin: "q", expectedVersion: "2.1.326 (Claude Code)"))
    XCTAssertEqual(response.outcome.rawValue, "versionChanged")
    XCTAssertNil(logged("argv"))

    let same = run(
      request(.claude, Self.claudeAnswer, stdin: "q", expectedVersion: "2.1.400 (Claude Code)"))
    XCTAssertEqual(same.outcome.rawValue, "ran")
  }

  func testAReplacedProgramIsANewFile() throws {
    try install(.codex)
    let path = home.appendingPathComponent(".local/bin/codex").path
    let before = try XCTUnwrap(ToolRunner.FileIdentity(path))
    XCTAssertEqual(ToolRunner.FileIdentity(path), before)
    try install(.codex, "echo another")
    XCTAssertNotEqual(ToolRunner.FileIdentity(path), before)
  }

  // MARK: How it ends

  func testATimeoutKillsTheWholeGroup() throws {
    try install(.codex, "/bin/sleep 30.171 &\n/bin/sleep 30.172")
    let started = Date()
    let response = run(
      request(.codex, Self.codexAnswer, timeoutMs: 600, expectedVersion: "tool 1.0.0"))
    XCTAssertEqual(response.outcome.rawValue, "timedOut")
    XCTAssertLessThan(Date().timeIntervalSince(started), 8)
    XCTAssertEqual(survivors("sleep 30.17"), "")
  }

  func testAChildThatLeftTheGroupIsKilledToo() throws {
    try install(
      .codex,
      """
      /usr/bin/perl -e 'setpgrp(0, 0); exec "/bin/sleep", "31.171"' &
      /bin/sleep 31.172
      """)
    let response = run(
      request(.codex, Self.codexAnswer, timeoutMs: 800, expectedVersion: "tool 1.0.0"))
    XCTAssertEqual(response.outcome.rawValue, "timedOut")
    XCTAssertEqual(survivors("sleep 31.17"), "")
  }

  func testWhatARunLeavesBehindDiesWithIt() throws {
    try install(.codex, "/bin/sleep 32.171 &\necho answer")
    let response = run(request(.codex, Self.codexAnswer, expectedVersion: "tool 1.0.0"))
    XCTAssertEqual(response.outcome.rawValue, "ran")
    XCTAssertEqual(response.stdout, "answer\n")
    XCTAssertEqual(survivors("sleep 32.171"), "")
  }

  func testTooMuchOutputKillsTheRunAndIsNotRead() throws {
    try install(.codex, "/usr/bin/yes x | /usr/bin/head -c 200000\n/bin/sleep 33.171")
    let response = run(
      request(.codex, Self.codexAnswer, maxOutput: 1000, expectedVersion: "tool 1.0.0"))
    XCTAssertEqual(response.outcome.rawValue, "tooLong")
    XCTAssertEqual(response.stdout, "")
    XCTAssertEqual(survivors("sleep 33.171"), "")
  }

  // MARK: Who it talks to

  func testOnlyOurAppsIdentifierMakesARequirement() {
    XCTAssertEqual(
      Listener.requirement(forApp: "com.kapybara.kapynotes"),
      #"anchor apple generic and certificate leaf[subject.OU] = "96V66447C6" and identifier "com.kapybara.kapynotes""#
    )
    XCTAssertNotNil(Listener.requirement(forApp: "com.kapybara.kapynotes.kapy19"))
    for refused in [
      "com.kapybara.kapynotesevil", "com.example.app", "", "com.kapybara",
      #"com.kapybara.kapynotes" or anchor apple"#, "com.kapybara.kapynotes.a b",
    ] {
      XCTAssertNil(Listener.requirement(forApp: refused), refused)
    }
  }

  func testTheAppIsTheOneTheServiceIsIn() throws {
    let app = home.appendingPathComponent("Kapy Notes.app")
    let service = app.appendingPathComponent("Contents/XPCServices/KapyToolRunner.xpc")
    try FileManager.default.createDirectory(at: service, withIntermediateDirectories: true)
    let info: NSDictionary = ["CFBundleIdentifier": "com.kapybara.kapynotes.kapy19"]
    info.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
    XCTAssertEqual(Listener.containingApp(of: service), "com.kapybara.kapynotes.kapy19")
    XCTAssertNil(Listener.containingApp(of: home.appendingPathComponent("KapyToolRunner.xpc")))
  }

  /// This process's own designated requirement, which it meets.
  private func ownRequirement() throws -> String {
    var code: SecCode?
    XCTAssertEqual(SecCodeCopySelf([], &code), errSecSuccess)
    var staticCode: SecStaticCode?
    XCTAssertEqual(SecCodeCopyStaticCode(try XCTUnwrap(code), [], &staticCode), errSecSuccess)
    var requirement: SecRequirement?
    XCTAssertEqual(
      SecCodeCopyDesignatedRequirement(try XCTUnwrap(staticCode), [], &requirement),
      errSecSuccess)
    var text: CFString?
    XCTAssertEqual(SecRequirementCopyString(try XCTUnwrap(requirement), [], &text), errSecSuccess)
    return try XCTUnwrap(text) as String
  }

  /// A ping and a request through a listener set up as the service sets up
  /// its peers; nil when no reply came.
  private func talk(requirement: String?) -> (pong: Bool, response: String?)? {
    let queue = DispatchQueue(label: "listener")
    let listener = xpc_connection_create(nil, queue)
    xpc_connection_set_event_handler(listener) { peer in
      guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
      Listener.accept(peer, requirement: requirement) { _ in Data("served".utf8) }
    }
    xpc_connection_resume(listener)
    let client = xpc_connection_create_from_endpoint(xpc_endpoint_create(listener))
    xpc_connection_set_event_handler(client) { _ in }
    xpc_connection_resume(client)
    defer {
      xpc_connection_cancel(client)
      xpc_connection_cancel(listener)
    }

    let ping = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_bool(ping, "ping", true)
    let pong = xpc_connection_send_message_with_reply_sync(client, ping)
    guard xpc_get_type(pong) == XPC_TYPE_DICTIONARY else { return nil }

    let message = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_data(message, "request", "{}", 2)
    let reply = xpc_connection_send_message_with_reply_sync(client, message)
    guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY else { return nil }
    var length = 0
    let data = xpc_dictionary_get_data(reply, "response", &length)
    return (
      xpc_dictionary_get_bool(pong, "pong"),
      data.map { String(decoding: Data(bytes: $0, count: length), as: UTF8.self) }
    )
  }

  func testAPeerThatMeetsTheRequirementIsServed() throws {
    let served = try XCTUnwrap(talk(requirement: try ownRequirement()))
    XCTAssertTrue(served.pong)
    XCTAssertEqual(served.response, "served")
  }

  func testAPeerSignedByAnyoneElseIsRefused() {
    XCTAssertNil(talk(requirement: Listener.requirement(forApp: "com.kapybara.kapynotes")))
    XCTAssertNil(talk(requirement: nil))
  }
}
