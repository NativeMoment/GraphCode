import ComposableArchitecture
import Foundation
import Testing

@testable import GraphcodeKit
@testable import graphcode

/// A loop whose backend CLI is not on the launch shell's PATH is stopped with a
/// `LaunchFailure` the app raises as a dialog — instead of a dead session that reads
/// running, or a pane exit that reads SUCCEEDED.
@Suite
struct ProviderNotOnPathTests {
  private static let project = ProjectRef(path: "/tmp/provider-path", name: "provider-path")
  private static let missing = LaunchFailure(
    executable: "pi", backend: .claudeCode, occurredAt: Date(timeIntervalSince1970: 1))

  private func draft() -> NodeDraft {
    NodeDraft(title: "Worker", loopType: .goalBased, goal: GoalSpec(summary: "say hi"))
  }

  private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<300 {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return false
  }

  @Test
  func theProbeAsksTheLaunchShellForAFileOnPath() {
    let invocation = ProviderPath.probeInvocation(for: "pi")
    #expect(Array(invocation.prefix(4)) == ["/bin/zsh", "-i", "-l", "-c"])
    #expect(invocation.last == "whence -p -- 'pi' >/dev/null 2>&1")
  }

  @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/zsh")))
  func theProbeFindsARealExecutableAndMissesAnInventedOne() async {
    #expect(await ProviderPath.isOnPath("ls") == true)
    #expect(await ProviderPath.isOnPath("graphcode-no-such-cli-\(UUID().uuidString)") == false)
  }

  @Test
  func aRemoteProjectIsNeverJudgedByThisMachinesPath() async {
    let node = LoopNode(title: "Remote", backend: .claudeCode)
    let failure = await ProviderPath.missingProvider(
      for: node, projectPath: "ssh://someone@box/~/project")
    #expect(failure == nil)
  }

  @Test
  func theDialogNamesTheExecutableTheBackendAndTheFix() {
    let failure = LaunchFailure(executable: "copilot", backend: .copilotCLI)
    #expect(failure.title == "copilot is not on your PATH")
    #expect(failure.message.contains("Copilot CLI"))
    #expect(failure.message.contains("/bin/zsh -i -l"))
    #expect(failure.message.contains("restart the loop"))
  }

  @Test
  func aLaunchWhoseCLIIsMissingStopsTheLoopAndKillsItsSession() async {
    let killed = LockIsolated<[UUID]>([])
    let memos = LockIsolated<[String]>([])
    let store = GraphStore(
      graph: LoopGraph(project: Self.project),
      onEnsureSession: { _, _ in },
      onFindMissingProvider: { _, _ in Self.missing },
      onTerminateSession: { node, _ in killed.withValue { $0.append(node.id) } },
      onAppendMemory: { _, entry in memos.withValue { $0.append(entry) } })
    await store.handle(.createNode(draft()))
    let id = await store.graph.nodes[0].id

    #expect(await eventually { await store.graph.nodes[id: id]?.state == .stopped })
    #expect(await store.graph.nodes[id: id]?.launchFailure == Self.missing)
    #expect(killed.value.contains(id))
    #expect(memos.value.contains { $0.contains("pi is not on your PATH") })
  }

  @Test
  func aLaunchWhoseCLIIsFoundKeepsRunning() async {
    let probes = LockIsolated(0)
    let store = GraphStore(
      graph: LoopGraph(project: Self.project),
      onEnsureSession: { _, _ in },
      onFindMissingProvider: { _, _ in
        probes.withValue { $0 += 1 }
        return nil
      })
    await store.handle(.createNode(draft()))
    let id = await store.graph.nodes[0].id

    #expect(await eventually { probes.value == 1 })
    await store.handle(.refreshUsage)
    #expect(await store.graph.nodes[id: id]?.state == .running)
    #expect(await store.graph.nodes[id: id]?.launchFailure == nil)
  }

  @Test
  func aPaneExitIsAStopRatherThanASuccessWhenTheCLIIsMissing() async {
    let isMissing = LockIsolated(false)
    let probes = LockIsolated(0)
    let store = GraphStore(
      graph: LoopGraph(project: Self.project),
      onEnsureSession: { _, _ in },
      onFindMissingProvider: { _, _ in
        probes.withValue { $0 += 1 }
        return isMissing.value ? Self.missing : nil
      })
    await store.handle(.createNode(draft()))
    let id = await store.graph.nodes[0].id
    #expect(await eventually { probes.value == 1 })
    isMissing.setValue(true)

    await store.handle(.nodeCheckApproved(id))

    #expect(await store.graph.nodes[id: id]?.state == .stopped)
    #expect(await store.graph.nodes[id: id]?.launchFailure == Self.missing)
  }

  @Test
  func restartingAfterTheFixClearsTheFailureAndLaunchesAgain() async {
    let isMissing = LockIsolated(true)
    let ensured = LockIsolated(0)
    let store = GraphStore(
      graph: LoopGraph(project: Self.project),
      onEnsureSession: { _, _ in ensured.withValue { $0 += 1 } },
      onFindMissingProvider: { _, _ in isMissing.value ? Self.missing : nil })
    await store.handle(.createNode(draft()))
    let id = await store.graph.nodes[0].id
    #expect(await eventually { await store.graph.nodes[id: id]?.state == .stopped })
    isMissing.setValue(false)

    await store.handle(.restartNode(id))

    let node = await store.graph.nodes[id: id]
    #expect(node?.state == .running)
    #expect(node?.launchFailure == nil)
    #expect(node?.sessionRestarts == 1)
    #expect(ensured.value == 2)
  }

  @Test
  func aDaemonRestartDoesNotRelaunchALoopStoppedForAMissingCLI() async {
    var stopped = LoopNode(
      title: "Stopped", loopType: .timeBased, triggerPrompt: "/loop 1h check", state: .stopped)
    stopped.launchFailure = Self.missing
    let control = LoopNode(title: "Control", loopType: .timeBased, triggerPrompt: "/loop 1h check")
    var graph = LoopGraph(project: Self.project)
    graph.nodes.append(stopped)
    graph.nodes.append(control)
    let ensured = LockIsolated<[UUID]>([])
    let store = GraphStore(
      graph: graph, onEnsureSession: { node, _ in ensured.withValue { $0.append(node.id) } })

    await store.ensureUnattendedSessions()

    #expect(ensured.value == [control.id])
  }

  @Test
  func theFailureSurvivesTheWireAndAnOlderSnapshotDecodesWithoutIt() throws {
    var node = LoopNode(title: "Worker")
    node.launchFailure = Self.missing
    let decoded = try JSONDecoder().decode(LoopNode.self, from: JSONEncoder().encode(node))
    #expect(decoded.launchFailure == Self.missing)

    let legacy = try JSONDecoder().decode(
      LoopNode.self, from: Data(#"{"id":"\#(UUID().uuidString)","title":"Old"}"#.utf8))
    #expect(legacy.launchFailure == nil)
  }

  @Test
  @MainActor
  func theAppRaisesANewFailureOnceAndNotTheOnesAProjectOpenedWith() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.orchestratorClient.send = { _ in }
    }
    store.exhaustivity = .off

    var old = LoopNode(title: "Old", state: .stopped)
    old.launchFailure = Self.missing
    var graph = LoopGraph(project: Self.project)
    graph.nodes.append(old)
    await store.send(.daemonEvent(.graphChanged(graph)))
    #expect(store.state.sessionRestart.launchFailureNotice == nil)

    var fresh = LoopNode(title: "Fresh", state: .stopped)
    fresh.launchFailure = LaunchFailure(executable: "codex", backend: .codex)
    graph.nodes.append(fresh)
    await store.send(.daemonEvent(.graphChanged(graph)))
    #expect(store.state.sessionRestart.launchFailureNotice?.title == "codex is not on your PATH")
    #expect(store.state.sessionRestart.launchFailureNotice?.message.contains("“Fresh”") == true)

    await store.send(.sessionRestart(.launchFailureNoticeDismissed))
    await store.send(.daemonEvent(.graphChanged(graph)))
    #expect(store.state.sessionRestart.launchFailureNotice == nil)
  }

  @Test
  @MainActor
  func aKeyOnTheDeadPaneOfAStoppedForMissingCLILoopDoesNotDeleteIt() async {
    let sent = LockIsolated<[DaemonCommand]>([])
    var node = LoopNode(title: "Worker", state: .stopped)
    node.launchFailure = Self.missing
    var graph = LoopGraph(project: Self.project)
    graph.nodes.append(node)
    var initial = AppFeature.State()
    initial.projects.append(ProjectFeature.State(graph: ProjectFeature.holding(graph)))
    initial.openLoop = LoopWorkspaceFeature.State(
      node: node, graph: graph, layout: TerminalLayout.opening(forNode: node.id, saved: nil),
      projectPath: Self.project.path, projectName: Self.project.name)
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.orchestratorClient.send = { command in sent.withValue { $0.append(command) } }
    }
    store.exhaustivity = .off

    await store.send(.openLoop(.primaryExitAcknowledged))
    await store.finish()

    #expect(store.state.openLoop == nil)
    #expect(sent.value.isEmpty)
  }
}
