import Foundation

/// Why the daemon stopped a loop whose backend CLI the launch shell could not find —
/// carried on the node (`LoopNode.launchFailure`) so every client can say so, and so
/// `GraphStore.restartNode` knows this stop is one the human is allowed to undo.
public struct LaunchFailure: Codable, Equatable, Sendable {
  public var executable: String
  public var backend: CLISessionBackendKind
  public var occurredAt: Date

  public init(executable: String, backend: CLISessionBackendKind, occurredAt: Date = Date()) {
    self.executable = executable
    self.backend = backend
    self.occurredAt = occurredAt
  }

  public var title: String { "\(executable) is not on your PATH" }

  public var message: String {
    "GraphCode couldn't find \(executable), the \(backend.displayName) command-line tool, so "
      + "the loop was stopped instead of left running without an agent. Loops start their "
      + "agent from a login shell (/bin/zsh -i -l): install \(backend.displayName), or add "
      + "the folder containing \(executable) to PATH in ~/.zshrc or ~/.zprofile, then "
      + "restart the loop."
  }
}

/// Whether a backend's CLI resolves the way a session launch resolves it. Without this a
/// missing CLI produced a session whose shell exited 127 at once while the graph went on
/// reporting the loop as running — or, reported by its pane, as SUCCEEDED.
public enum ProviderPath {
  /// What zsh exits with for a command it cannot find.
  public static let commandNotFoundStatus = 127

  /// The same `-i -l` shell the launches use (`ZmxSessionLauncher.loginShellInvocation`,
  /// `GhosttyTerminalView.interactiveLoginShell`), since a developer's PATH usually comes
  /// from `~/.zshrc`. `whence -p` rather than `command -v`: the launch `exec`s the agent,
  /// which only a file on PATH satisfies, so an alias of the same name must not count.
  public static func probeInvocation(for executable: String) -> [String] {
    [
      "/bin/zsh", "-i", "-l", "-c",
      "whence -p -- \(RemoteProjectLocation.shellQuoted(executable)) >/dev/null 2>&1",
    ]
  }

  /// `nil` when the shell did not answer in time: a slow `~/.zshrc` says nothing about
  /// PATH, and must never be what stops a loop.
  public static func isOnPath(_ executable: String, deadline: Duration = .seconds(15)) async
    -> Bool?
  {
    if await FoundCache.shared.isFresh(executable) { return true }
    let invocation = probeInvocation(for: executable)
    guard
      let shell = invocation.first,
      let session = try? PTYProcessSession(
        executable: shell, arguments: Array(invocation.dropFirst()))
    else { return nil }
    guard let found = await withDeadline(deadline, { await session.waitUntilFinished() }) else {
      session.terminate()
      return nil
    }
    if found { await FoundCache.shared.record(executable) }
    return found
  }

  /// The failure launching `node` would hit, or `nil`. Always `nil` for a remote project:
  /// its PATH belongs to another machine, which this shell cannot see.
  public static func missingProvider(for node: LoopNode, projectPath: String?) async
    -> LaunchFailure?
  {
    if let projectPath, RemoteProjectLocation.parse(projectPath: projectPath) != nil {
      return nil
    }
    guard let executable = node.backend.executableName else { return nil }
    guard await isOnPath(executable) == false else { return nil }
    return LaunchFailure(executable: executable, backend: node.backend)
  }

  /// Found answers only, and briefly: a daemon loading a graph ensures every unattended
  /// loop at once, and one login shell per loop for the same answer is waste. A missing
  /// CLI is never cached, so the check after a fix sees the fix.
  private actor FoundCache {
    static let shared = FoundCache()
    private static let lifetime: TimeInterval = 300
    private var foundAt: [String: Date] = [:]

    func isFresh(_ executable: String) -> Bool {
      guard let found = foundAt[executable] else { return false }
      return Date().timeIntervalSince(found) < Self.lifetime
    }

    func record(_ executable: String) { foundAt[executable] = Date() }
  }
}
