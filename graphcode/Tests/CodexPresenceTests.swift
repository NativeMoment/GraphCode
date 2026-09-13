import Foundation
import Testing

@testable import GraphcodeKit

/// Codex's presence, which is the awkward one of the three.
///
/// **What was verified against the real CLI, offline:** `codex --strict-config` rejects an
/// invented config field outright ("unknown configuration field `totally`") and accepts
/// `notify=[…]`, so the override this builds is a real key and not a guess. `-c/--config`
/// is documented in `codex --help`, and `agent-turn-complete` is the event `notify` fires
/// on.
///
/// **What could not be verified, and why:** the installed Codex is logged out (its refresh
/// token is spent), so no session could be run to watch `notify` actually fire. A
/// hand-built `hooks.json` under `hooks.managed_dir` was tried as the richer alternative
/// and did *not* fire, which is exactly why this uses `notify` and not that: the hook
/// file's schema is undocumented, and `BackendCapabilities` is explicit that a capability
/// claimed on a hunch is what `isSpiked` exists to prevent.
@Suite
struct CodexPresenceTests {
  private let zmx = "/Users/someone/.graphcode/bin/zmx"

  @Test
  func theTurnEndIsReportedThroughTheOneChannelCodexHas() {
    let script = PresenceHooks.codexNotifyScript(zmxPath: zmx)

    #expect(script.contains("presence=idle"))
    // Same session-owned label store the other two backends report into, so one reader
    // serves all three.
    #expect(script.contains(#"$ZMX_SESSION"#))
    #expect(script.contains("thread-id"))
    #expect(script.contains(".history"))
    #expect(script.contains(".id"))
    #expect(script.contains("'\(zmx)'"))
  }

  @Test
  func theOverrideIsValidTOMLForAnAwkwardPath() {
    // The value is TOML parsed out of one argv element, so a quote in the script's path
    // has to survive as an escape rather than closing the string early.
    let override = PresenceHooks.codexNotifyOverride(scriptPath: #"/Users/o"brien/codex-notify.sh"#)

    #expect(override == #"notify=["/bin/sh","/Users/o\"brien/codex-notify.sh"]"#)
    // The remote form's `$HOME` and `$0` stay escaped for the shell on the host to expand.
    #expect(
      PresenceHooks.remoteCodexNotifyOverride
        == #"notify=["/bin/sh","-c","exec /bin/sh \"$HOME/.graphcode/hooks/codex-notify.sh\" \"$0\""]"#
    )
    #expect(PresenceHooks.codexNotifyScript(zmxPath: "/Users/o'brien/zmx").contains(#"o'\''brien"#))
  }

  @Test
  func theNotifyScriptBanksTheThreadAndReportsIdleWhenCodexRunsIt() async throws {
    // Run the way Codex runs it: the script by path, the event JSON appended as one more
    // argument — then again through the remote form's `$HOME` hop.
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-notify-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let hooks = root.appendingPathComponent(".graphcode/hooks", isDirectory: true)
    try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
    let calls = root.appendingPathComponent("zmx-calls")
    let fakeZmx = root.appendingPathComponent("zmx")
    try "#!/bin/sh\necho \"$@\" >> '\(calls.path)'\n".write(
      to: fakeZmx, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeZmx.path)
    let sessions = root.appendingPathComponent("sessions", isDirectory: true)
    let script = hooks.appendingPathComponent("codex-notify.sh")
    try PresenceHooks.codexNotifyScript(
      zmxPath: fakeZmx.path, sessionsDirectory: PresenceHooks.singleQuoted(sessions.path)
    ).write(to: script, atomically: true, encoding: .utf8)
    let nodeID = UUID().uuidString
    let event = #"{"type":"agent-turn-complete","thread-id":"t-42"}"#
    let environment = ["HOME": root.path, "ZMX_SESSION": "graphcode-\(nodeID)"]

    #expect(try await run(["/bin/sh", script.path, event], environment: environment) == 0)
    #expect(
      try String(contentsOf: sessions.appendingPathComponent("\(nodeID).id"), encoding: .utf8)
        == "t-42")
    #expect(
      try await run(
        ["/bin/sh", "-c", PresenceHooks.remoteCodexNotifyCommand, event], environment: environment)
        == 0)
    let reports = try String(contentsOf: calls, encoding: .utf8)
    #expect(reports == String(repeating: "set graphcode-\(nodeID) presence=idle\n", count: 2))
  }

  private func run(_ argv: [String], environment: [String: String]) async throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: argv[0])
    process.arguments = Array(argv.dropFirst())
    process.environment = environment
    return try await withCheckedThrowingContinuation { continuation in
      process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
      do { try process.run() } catch { continuation.resume(throwing: error) }
    }
  }

  @Test
  func codexTakesTheFlagAndNothingMeantForTheOthers() {
    let arguments = CLISessionBackendKind.codex.presenceArguments(
      hooksFile: URL(fileURLWithPath: "/tmp/codex-notify.sh"),
      sessionName: "graphcode-A", zmxPath: zmx)

    #expect(arguments == ["-c", #"notify=["/bin/sh","/tmp/codex-notify.sh"]"#])
    // Codex has no `--settings` to layer hooks into and no `--name` to label a session.
    #expect(!arguments.contains("--settings"))
    #expect(!arguments.contains("--name"))
  }

  @Test
  func nowhereToReportMeansNoFlagRatherThanABrokenOne() {
    // A machine with no zmx writes no script, and a local launch must not fall back to
    // naming the remote one.
    #expect(
      CLISessionBackendKind.codex.presenceArguments(
        hooksFile: nil, sessionName: "graphcode-A", zmxPath: nil) == [])
    #expect(
      CLISessionBackendKind.codex.presenceArguments(
        hooksFile: nil, sessionName: "graphcode-A", zmxPath: zmx) == [])
  }

  @Test
  func aRemoteOverrideUsesTheRemoteBinaryAndSessionBank() throws {
    let node = LoopNode(
      title: "Ship it", loopType: .goalBased, goal: GoalSpec(summary: "Tests pass"),
      backend: .codex, state: .running)
    let location = RemoteProjectLocation(
      user: "dev", host: "build-box", remotePath: "/home/dev/widget")
    let invocation = try #require(
      ZmxSessionLauncher.remoteEnsureInvocation(forNode: node, at: location))
    let command = try #require(invocation.last)

    #expect(command.contains("notify="))
    #expect(command.contains("thread-id"))
    #expect(command.contains("$HOME/.graphcode/sessions"))
    #expect(command.contains("codex-notify.sh"))
    #expect(!command.contains(ZmxLocator.binaryURL.path))
  }

  @Test
  func eachBackendGetsOnlyItsOwnMechanism() {
    // One function, a different answer per CLI — the point being that they genuinely differ
    // here and the code should not pretend otherwise. OpenCode's answer is the environment.
    let file = URL(fileURLWithPath: "/tmp/hooks.json")
    let all = CLISessionBackendKind.allCases.map {
      $0.presenceArguments(hooksFile: file, sessionName: "graphcode-A", zmxPath: zmx).first
    }

    #expect(Set(all.compactMap { $0 }) == ["--settings", "--name", "-c", "-e"])
  }

  @Test
  func theOverrideRidesOnARealLaunch() throws {
    let node = LoopNode(
      title: "Ship it", loopType: .goalBased, goal: GoalSpec(summary: "Tests pass"),
      backend: .codex, state: .running)
    let arguments = try #require(ZmxSessionLauncher.arguments(forNode: node))

    // Only meaningful on a machine that has zmx to report into — which is every machine
    // that can run a loop at all, since the session itself is a zmx session.
    if ZmxLocator.isInstalled {
      #expect(arguments.contains { $0.hasPrefix("notify=[") })
    }
    #expect(arguments.contains(#"exec codex "$@""#))
  }

  @Test
  func theLaunchStillFitsInATypedCommandLine() throws {
    // `zmx` types the launch command into a tty that discards everything past MAX_CANON,
    // and this override is the longest single argument graphcode adds to a Codex launch.
    let node = LoopNode(
      title: "Ship it", loopType: .goalBased,
      goal: GoalSpec(summary: "Tests pass"), backend: .codex, state: .running)
    let arguments = try #require(ZmxSessionLauncher.arguments(forNode: node))

    #expect(ZmxSessionLauncher.fitsInATypedCommandLine(arguments))
  }
}
