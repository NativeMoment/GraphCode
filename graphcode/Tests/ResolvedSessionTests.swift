import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

/// A resolved loop's session is ended to free the machine; the loop and its transcript
/// stay (#346).
@Suite
struct ResolvedSessionTests {
  private func resolvedStore(
    presence: Presence?, ended: LockIsolated<[UUID]>
  ) async -> (GraphStore, UUID) {
    let readPresence: (@Sendable (LoopNode, String?) async -> PresenceReading)? = presence.map {
      value in { _, _ in PresenceReading(presence: value, confidence: .reported) }
    }
    let store = GraphStore(
      onReadPresence: readPresence,
      onEndSession: { node, _ in
        ended.withValue { $0.append(node.id) }
        return true
      })
    await store.handle(
      .createNode(
        NodeDraft(title: "Docs", loopType: .goalBased, goal: GoalSpec(summary: "Write it"))))
    let id = await store.graph.nodes[0].id
    return (store, id)
  }

  @Test
  func anIdleResolvedSessionIsEnded() async {
    let ended = LockIsolated<[UUID]>([])
    let (store, id) = await resolvedStore(presence: .idle, ended: ended)
    await store.handle(.completeNode(id, result: nil, from: id))

    await store.endResolvedSession(id)

    #expect(ended.value == [id])
    #expect(await store.graph.nodes[id: id]?.state == .succeeded)
  }

  @Test
  func aSessionStillMidTurnIsLeftAlone() async {
    let ended = LockIsolated<[UUID]>([])
    let (store, id) = await resolvedStore(presence: .busy, ended: ended)
    await store.handle(.completeNode(id, result: nil, from: id))

    await store.endResolvedSession(id)

    #expect(ended.value.isEmpty)
  }

  @Test
  func anUnresolvedLoopsSessionIsNeverEnded() async {
    let ended = LockIsolated<[UUID]>([])
    let (store, id) = await resolvedStore(presence: .idle, ended: ended)

    await store.endResolvedSession(id)

    #expect(ended.value.isEmpty)
  }

  @Test
  func aNewGoalReopensAResolvedLoopWithoutRefiringItsEdges() async {
    let ensured = LockIsolated<[LoopNode]>([])
    let store = GraphStore(onEnsureSession: { node, _ in ensured.withValue { $0.append(node) } })
    await store.handle(
      .createNode(
        NodeDraft(title: "Docs", loopType: .goalBased, goal: GoalSpec(summary: "Write it"))))
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Ship", loopType: .turnBased, checkDescription: "?", firstInstruction: "Work")))
    let nodes = await store.graph.nodes
    await store.handle(.createEdge(from: nodes[0].id, to: nodes[1].id, spec: EdgeSpec()))
    await store.handle(.completeNode(nodes[0].id, result: nil, from: nodes[0].id))
    let launchesBefore = ensured.value.count

    await store.handle(.updateNode(nodes[0].id, update: NodeUpdate(goalSummary: "Add examples")))

    let graph = await store.graph
    let reopened = graph.nodes[id: nodes[0].id]
    #expect(reopened?.state == .running)
    #expect(reopened?.resolution == nil)
    #expect(reopened?.goal?.summary == "Add examples")
    #expect(ensured.value.count == launchesBefore + 1)
    #expect(graph.edges[0].fireCount == 1)
  }

  @Test
  func aResolvedLoopCannotHandItselfANewGoal() async {
    let errors = LockIsolated<[String]>([])
    let store = GraphStore(onAnnounceError: { message in errors.withValue { $0.append(message) } })
    await store.handle(
      .createNode(
        NodeDraft(title: "Docs", loopType: .goalBased, goal: GoalSpec(summary: "Write it"))))
    let id = await store.graph.nodes[0].id
    await store.handle(.completeNode(id, result: nil, from: id))

    await store.handle(
      .updateNode(id, update: NodeUpdate(goalSummary: "Do more", updatedBy: id)))

    #expect(await store.graph.nodes[id: id]?.state == .succeeded)
    #expect(errors.value.contains { $0.contains("may not hand itself a new goal") })
  }

  @Test
  func neverIsStoredAsZeroAndSurvivesARoundTrip() throws {
    var settings = GraphcodeSettings()
    #expect(settings.resolvedSessionGrace == .seconds(600))
    settings.endsResolvedSessionsAfterMinutes = 0
    let decoded = try JSONDecoder().decode(
      GraphcodeSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded.endsResolvedSessionsAfterMinutes == 0)
    #expect(decoded.resolvedSessionGrace == nil)
  }
}
