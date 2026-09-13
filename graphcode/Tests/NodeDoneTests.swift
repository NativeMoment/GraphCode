import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

/// `graphcode node done` — the completion report every backend can send (#346).
@Suite
struct NodeDoneTests {
  private struct Fixture {
    let store: GraphStore
    let goalID: UUID
    let peerID: UUID
  }

  private func goalStore(
    backend: CLISessionBackendKind? = nil, predicate: String? = nil,
    predicatePasses: Bool = false, errors: LockIsolated<[String]> = LockIsolated([])
  ) async -> Fixture {
    let store = GraphStore(
      onEvaluatePredicate: { _ in predicatePasses },
      onAnnounceError: { message in errors.withValue { $0.append(message) } })
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Docs", loopType: .goalBased,
          goal: GoalSpec(summary: "The doc reads well", predicate: predicate),
          backend: backend)))
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Ship", loopType: .turnBased, checkDescription: "?", firstInstruction: "Work")))
    let nodes = await store.graph.nodes
    await store.handle(.createEdge(from: nodes[0].id, to: nodes[1].id, spec: EdgeSpec()))
    return Fixture(store: store, goalID: nodes[0].id, peerID: nodes[1].id)
  }

  @Test
  func theLoopReportingItselfDoneResolvesItOnceWithItsResult() async {
    let fixture = await goalStore()

    await fixture.store.handle(
      .completeNode(fixture.goalID, result: "PR #12 merged", from: fixture.goalID))
    await fixture.store.handle(.completeNode(fixture.goalID, result: "again", from: fixture.goalID))

    let graph = await fixture.store.graph
    #expect(graph.nodes[id: fixture.goalID]?.state == .succeeded)
    #expect(graph.nodes[id: fixture.goalID]?.resolution?.basis == .agentReported)
    #expect(graph.nodes[id: fixture.goalID]?.resolution?.detail == "PR #12 merged")
    #expect(graph.edges[0].fireCount == 1)
  }

  @Test
  func aPiLoopWithNoVerdictOfItsOwnResolvesByReportingDone() async {
    // pi has no `/goal`, so nothing in its session records a verdict: the report is the
    // only way its predicate-less goal can resolve.
    let fixture = await goalStore(backend: .pi)
    let node = await fixture.store.graph.nodes[id: fixture.goalID]
    #expect(node?.backend == .pi)
    #expect(node.flatMap { GoalVerdictReader.verdict(of: $0, projectPath: nil) } == nil)

    await fixture.store.handle(.completeNode(fixture.goalID, result: nil, from: fixture.goalID))

    #expect(await fixture.store.graph.nodes[id: fixture.goalID]?.resolution?.basis == .agentReported)
  }

  @Test
  func aHumanAtTheShellMarksItDone() async {
    let fixture = await goalStore()

    await fixture.store.handle(.completeNode(fixture.goalID, result: nil, from: nil))

    #expect(await fixture.store.graph.nodes[id: fixture.goalID]?.resolution?.basis == .human)
  }

  @Test
  func anUnrelatedPeerCannotReportAnotherLoopDone() async {
    let errors = LockIsolated<[String]>([])
    let fixture = await goalStore(errors: errors)

    await fixture.store.handle(.completeNode(fixture.goalID, result: nil, from: fixture.peerID))

    #expect(await fixture.store.graph.nodes[id: fixture.goalID]?.state == .running)
    #expect(errors.value.contains { $0.hasPrefix("done refused:") })
  }

  @Test
  func aFailingPredicateOutranksTheReport() async {
    let checked = LockIsolated(0)
    let store = GraphStore(onEvaluatePredicate: { _ in
      checked.withValue { $0 += 1 }
      return false
    })
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Docs", loopType: .goalBased,
          goal: GoalSpec(summary: "The doc reads well", predicate: "make test"))))
    let goalID = await store.graph.nodes[0].id

    await store.handle(.completeNode(goalID, result: nil, from: goalID))

    #expect(await eventually { checked.value > 0 })
    #expect(await store.graph.nodes[id: goalID]?.state == .running)
  }

  @Test
  func aPassingPredicateResolvesOnTheReportAsThePredicate() async {
    let fixture = await goalStore(predicate: "make test", predicatePasses: true)

    await fixture.store.handle(.completeNode(fixture.goalID, result: nil, from: fixture.goalID))

    #expect(
      await eventually {
        await fixture.store.graph.nodes[id: fixture.goalID]?.resolution?.basis == .predicate
      })
  }

  private func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<300 {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return false
  }

  @Test
  func onlyAGoalLoopCanBeReportedDone() async {
    let errors = LockIsolated<[String]>([])
    let fixture = await goalStore(errors: errors)

    await fixture.store.handle(.completeNode(fixture.peerID, result: nil, from: nil))

    #expect(await fixture.store.graph.nodes[id: fixture.peerID]?.state != .succeeded)
    #expect(errors.value.contains { $0.contains("is not a goal loop") })
  }

  @Test
  func theVerbTakesTrailingWordsAsTheResult() throws {
    let id = UUID()
    #expect(
      try GraphcodeCommand.parse(["node", "done", "/p", id.uuidString, "merged", "#12"])
        == .completeNode(projectPath: "/p", nodeID: id, result: "merged #12"))
    #expect(
      try GraphcodeCommand.parse(["node", "done", "/p", id.uuidString])
        == .completeNode(projectPath: "/p", nodeID: id, result: nil))
  }
}
