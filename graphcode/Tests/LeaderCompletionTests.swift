import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

/// A leader is not done while the loops it created are still running (#346).
@Suite
struct LeaderCompletionTests {
  private struct Fanout {
    let store: GraphStore
    let leaderID: UUID
    let childID: UUID
    let nextID: UUID
  }

  private func fanout(verdict: GoalVerdict? = nil) async -> Fanout {
    let store = GraphStore(onReadGoalVerdict: { node, _ in node.title == "Lead" ? verdict : nil })
    await store.handle(
      .createNode(
        NodeDraft(title: "Lead", loopType: .goalBased, goal: GoalSpec(summary: "Merge all fixes"))))
    let leaderID = await store.graph.nodes[0].id
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Fix", loopType: .goalBased, goal: GoalSpec(summary: "Fix item one"),
          createdBy: leaderID)))
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Ship", loopType: .turnBased, checkDescription: "?", firstInstruction: "Work")))
    let nodes = await store.graph.nodes
    let childID = nodes.first { $0.title == "Fix" }!.id
    let nextID = nodes.first { $0.title == "Ship" }!.id
    await store.handle(.createEdge(from: leaderID, to: nextID, spec: EdgeSpec()))
    return Fanout(store: store, leaderID: leaderID, childID: childID, nextID: nextID)
  }

  private func leaderEdgeFireCount(_ fanout: Fanout) async -> Int? {
    await fanout.store.graph.edges.first { $0.from == fanout.leaderID && $0.to == fanout.nextID }?
      .fireCount
  }

  @Test
  func aLeadersReportIsHeldUntilItsWorkerResolves() async {
    let fanout = await fanout()

    await fanout.store.handle(
      .completeNode(fanout.leaderID, result: "merged", from: fanout.leaderID))

    let held = await fanout.store.graph.nodes[id: fanout.leaderID]
    #expect(held?.state == .running)
    #expect(held?.pendingCompletion?.basis == .agentReported)
    #expect(await leaderEdgeFireCount(fanout) == 0)

    await fanout.store.handle(.completeNode(fanout.childID, result: nil, from: fanout.childID))

    let resolved = await fanout.store.graph.nodes[id: fanout.leaderID]
    #expect(resolved?.state == .succeeded)
    #expect(resolved?.resolution?.basis == .agentReported)
    #expect(resolved?.resolution?.detail == "merged")
    #expect(resolved?.pendingCompletion == nil)
    #expect(await leaderEdgeFireCount(fanout) == 1)
  }

  @Test
  func aBackendVerdictIsHeldUntilItsWorkerSucceeds() async {
    let fanout = await fanout(verdict: GoalVerdict(met: true))

    await fanout.store.evaluateGoal(fanout.leaderID)
    await fanout.store.evaluateGoal(fanout.leaderID)
    #expect(await fanout.store.graph.nodes[id: fanout.leaderID]?.state == .running)

    await fanout.store.handle(.completeNode(fanout.childID, result: nil, from: fanout.childID))

    let leader = await fanout.store.graph.nodes[id: fanout.leaderID]
    #expect(leader?.state == .succeeded)
    #expect(leader?.resolution?.basis == .nativeGoal)
    #expect(await leaderEdgeFireCount(fanout) == 1)
  }

  @Test
  func aWorkerThatDidNotSucceedDiscardsTheHeldCompletion() async {
    // Done on top of failed work is not done: the leader must look at the failure and
    // report again, and its earlier verdict no longer counts.
    let fanout = await fanout(verdict: GoalVerdict(met: true))
    await fanout.store.evaluateGoal(fanout.leaderID)

    await fanout.store.handle(.stopNode(fanout.childID))
    await fanout.store.evaluateGoal(fanout.leaderID)

    let leader = await fanout.store.graph.nodes[id: fanout.leaderID]
    #expect(leader?.state == .running)
    #expect(leader?.pendingCompletion == nil)
    #expect(await leaderEdgeFireCount(fanout) == 0)
  }

  @Test
  func aHumanMarkingTheLeaderDoneIsNotHeld() async {
    let fanout = await fanout()

    await fanout.store.handle(.completeNode(fanout.leaderID, result: nil, from: nil))

    #expect(await fanout.store.graph.nodes[id: fanout.leaderID]?.state == .succeeded)
  }

  @Test
  func theCreatorCanMarkItsWorkerDone() async {
    let fanout = await fanout()

    await fanout.store.handle(.completeNode(fanout.childID, result: nil, from: fanout.leaderID))

    #expect(await fanout.store.graph.nodes[id: fanout.childID]?.resolution?.basis == .agentReported)
  }
}
