import ComposableArchitecture
import Foundation
import Testing

@testable import GraphcodeKit

/// The failures the independent review of #346 reproduced against the first cut, kept as
/// regressions: each one failed there.
@Suite
struct GoalResolutionReviewTests {
  @Test
  func aVerdictReadInFlightMustNotResolveAReplacementGoal() async {
    let entered = AsyncStream<Void>.makeStream()
    let resume = AsyncStream<Void>.makeStream()
    let store = GraphStore(onReadGoalVerdict: { _, _ in
      entered.continuation.yield(())
      for await _ in resume.stream { break }
      return GoalVerdict(met: true)
    })
    await store.handle(
      .createNode(
        NodeDraft(title: "Review", loopType: .goalBased, goal: GoalSpec(summary: "Old goal"))))
    let id = await store.graph.nodes[0].id
    let poll = Task { await store.evaluateGoal(id) }
    for await _ in entered.stream { break }
    await store.handle(.updateNode(id, update: NodeUpdate(goalSummary: "Replacement goal")))
    resume.continuation.yield(())
    await poll.value
    #expect(await store.graph.nodes[id: id]?.state == .running)
  }

  @Test
  func unknownPresenceMustNotEndAHumansSession() async {
    let ended = LockIsolated(false)
    let store = GraphStore(
      onReadPresence: { _, _ in .unknown },
      onEndSession: { _, _ in
        ended.setValue(true)
        return true
      })
    await store.handle(
      .createNode(
        NodeDraft(title: "Review", loopType: .goalBased, goal: GoalSpec(summary: "Review it"))))
    let id = await store.graph.nodes[0].id
    await store.handle(.completeNode(id, result: nil, from: id))
    await store.endResolvedSession(id)
    await store.endResolvedSession(id)
    #expect(!ended.value)
  }

  @Test
  func reopeningMustNotAcceptThePreviousBackendCompletion() async {
    let store = GraphStore(
      onReadPresence: { _, _ in PresenceReading(presence: .busy, confidence: .reported) },
      onReadGoalVerdict: { _, _ in GoalVerdict(met: true) })
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Docs", loopType: .goalBased, goal: GoalSpec(summary: "Write docs"),
          backend: .codex)))
    let id = await store.graph.nodes[0].id
    await store.evaluateGoal(id)
    await store.handle(.updateNode(id, update: NodeUpdate(goalSummary: "Implement login")))
    await store.evaluateGoal(id)
    #expect(await store.graph.nodes[id: id]?.state == .running)
  }

  @Test
  func replacingAHeldGoalMustDiscardItsOldCompletion() async {
    let store = GraphStore()
    await store.handle(
      .createNode(
        NodeDraft(title: "Lead", loopType: .goalBased, goal: GoalSpec(summary: "Old task"))))
    let leader = await store.graph.nodes[0].id
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Child", loopType: .goalBased, goal: GoalSpec(summary: "Child task"),
          createdBy: leader)))
    let child = await store.graph.nodes[1].id
    await store.handle(.completeNode(leader, result: "Old task done", from: leader))
    await store.handle(.updateNode(leader, update: NodeUpdate(goalSummary: "Different task")))
    await store.handle(.completeNode(child, result: nil, from: child))
    #expect(await store.graph.nodes[id: leader]?.state == .running)
  }

  @Test
  func aDoneSentBeforeTheNewGoalLandsIsAboutTheOldGoal() async {
    // pi's only verdict is `node done`: a late report from the old goal must not succeed the
    // new one while that goal is still queued for the session.
    let errors = LockIsolated<[String]>([])
    let store = GraphStore(
      onSessionAlive: { _, _ in true },
      onAnnounceError: { message in errors.withValue { $0.append(message) } })
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Docs", loopType: .goalBased, goal: GoalSpec(summary: "Write docs"),
          backend: .pi)))
    let id = await store.graph.nodes[0].id
    await store.handle(.completeNode(id, result: nil, from: id))
    await store.handle(.updateNode(id, update: NodeUpdate(goalSummary: "Add examples")))

    await store.handle(.completeNode(id, result: "old goal done", from: id))

    #expect(await store.graph.nodes[id: id]?.state == .running)
    #expect(errors.value.contains { $0.contains("has not reached its session yet") })
  }

  @Test
  func aFreshLaunchAlreadyCarriesTheNewGoalSoDoneIsAccepted() async {
    let store = GraphStore(
      onSessionAlive: { _, _ in false },
      onResumeSession: { _, _ in false })
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Docs", loopType: .goalBased, goal: GoalSpec(summary: "Write docs"),
          backend: .pi)))
    let id = await store.graph.nodes[0].id
    await store.handle(.completeNode(id, result: nil, from: id))
    await store.handle(.updateNode(id, update: NodeUpdate(goalSummary: "Add examples")))

    for _ in 0..<300 {
      await store.handle(.completeNode(id, result: "examples added", from: id))
      if await store.graph.nodes[id: id]?.state == .succeeded { break }
      try? await Task.sleep(for: .milliseconds(10))
    }

    #expect(await store.graph.nodes[id: id]?.resolution?.detail == "examples added")
  }

  @Test
  func addingAFailingPredicateMustInvalidateHeldCompletion() async {
    let store = GraphStore(onEvaluatePredicate: { _ in false })
    await store.handle(
      .createNode(
        NodeDraft(title: "Lead", loopType: .goalBased, goal: GoalSpec(summary: "Old task"))))
    let leader = await store.graph.nodes[0].id
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Child", loopType: .goalBased, goal: GoalSpec(summary: "Child task"),
          createdBy: leader)))
    let child = await store.graph.nodes[1].id
    await store.handle(.completeNode(leader, result: nil, from: leader))
    await store.handle(.updateNode(leader, update: NodeUpdate(goalPredicate: "false")))
    await store.handle(.completeNode(child, result: nil, from: child))
    #expect(await store.graph.nodes[id: leader]?.state == .running)
  }
}
