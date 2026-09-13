import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

/// A resolved loop's session is ended to free the machine; the loop and its transcript
/// stay, and opening it brings the conversation back (#346).
@Suite
struct ResolvedSessionTests {
  private struct Harness {
    let store: GraphStore
    let id: UUID
    let ended: LockIsolated<[UUID]>
  }

  private func resolved(
    presence: PresenceReading?, clients: Int? = 0, grace: Duration? = nil
  ) async -> Harness {
    let ended = LockIsolated<[UUID]>([])
    let readPresence: (@Sendable (LoopNode, String?) async -> PresenceReading)? =
      presence.map { reading in { _, _ in reading } }
    let store = GraphStore(
      onReadPresence: readPresence,
      onEndSession: { node, _ in
        ended.withValue { $0.append(node.id) }
        return true
      },
      onAttachedClients: { _, _ in clients },
      onResolvedSessionGrace: { grace })
    await store.handle(
      .createNode(
        NodeDraft(title: "Docs", loopType: .goalBased, goal: GoalSpec(summary: "Write it"))))
    let id = await store.graph.nodes[0].id
    await store.handle(.completeNode(id, result: nil, from: id))
    return Harness(store: store, id: id, ended: ended)
  }

  private let idle = PresenceReading(presence: .idle, confidence: .reported)

  private func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<300 {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return false
  }

  @Test
  func aQuietSessionIsEndedOnlyWhenItIsStillQuietTheSecondTime() async {
    let harness = await resolved(presence: idle)

    await harness.store.endResolvedSession(harness.id)
    #expect(harness.ended.value.isEmpty)

    await harness.store.endResolvedSession(harness.id)
    #expect(harness.ended.value == [harness.id])
    #expect(await harness.store.graph.nodes[id: harness.id]?.state == .succeeded)
  }

  @Test
  func theScheduledEndActuallyRuns() async {
    let harness = await resolved(presence: idle, grace: .milliseconds(10))

    #expect(await eventually { harness.ended.value == [harness.id] })
  }

  @Test
  func aSessionThatIsBusyUnknownGuessedOrAttachedIsLeftAlone() async {
    let readings: [(PresenceReading?, Int?)] = [
      (PresenceReading(presence: .busy, confidence: .reported), 0),
      (PresenceReading(presence: .awaitingInput, confidence: .reported), 0),
      (.unknown, 0),
      (PresenceReading(presence: .idle, confidence: .heuristic), 0),
      (idle, 1),
      (idle, nil),
      (nil, 0),
    ]
    for (presence, clients) in readings {
      let harness = await resolved(presence: presence, clients: clients)
      await harness.store.endResolvedSession(harness.id)
      await harness.store.endResolvedSession(harness.id)
      #expect(harness.ended.value.isEmpty)
    }
  }

  @Test
  func anUnresolvedLoopsSessionIsNeverEnded() async {
    let ended = LockIsolated<[UUID]>([])
    let store = GraphStore(
      onReadPresence: { _, _ in PresenceReading(presence: .idle, confidence: .reported) },
      onEndSession: { node, _ in
        ended.withValue { $0.append(node.id) }
        return true
      })
    await store.handle(
      .createNode(
        NodeDraft(title: "Docs", loopType: .goalBased, goal: GoalSpec(summary: "Write it"))))
    let id = await store.graph.nodes[0].id

    await store.endResolvedSession(id)
    await store.endResolvedSession(id)

    #expect(ended.value.isEmpty)
  }

  @Test
  func openingAResolvedLoopWithNoSessionResumesItWithoutTheMetGoal() async {
    let resumed = LockIsolated<[LoopNode]>([])
    let store = GraphStore(
      onSessionAlive: { _, _ in false },
      onResumeSession: { node, _ in
        resumed.withValue { $0.append(node) }
        return true
      })
    await store.handle(
      .createNode(
        NodeDraft(title: "Docs", loopType: .goalBased, goal: GoalSpec(summary: "Write it"))))
    let id = await store.graph.nodes[0].id

    await store.handle(.resumeSession(id))
    #expect(resumed.value.isEmpty)

    await store.handle(.completeNode(id, result: nil, from: id))
    await store.handle(.resumeSession(id))

    #expect(resumed.value.map(\.id) == [id])
    #expect(resumed.value.first?.sessionPrompt?.contains("Write it") == false)
    #expect(await store.graph.nodes[id: id]?.state == .succeeded)
  }

  @Test
  func aNewGoalReopensAResolvedLoopWithoutRefiringItsEdges() async {
    let resumed = LockIsolated<[LoopNode]>([])
    let store = GraphStore(
      onSessionAlive: { _, _ in false },
      onResumeSession: { node, _ in
        resumed.withValue { $0.append(node) }
        return false
      })
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

    await store.handle(.updateNode(nodes[0].id, update: NodeUpdate(goalSummary: "Add examples")))

    let graph = await store.graph
    let reopened = graph.nodes[id: nodes[0].id]
    #expect(reopened?.state == .running)
    #expect(reopened?.resolution == nil)
    #expect(reopened?.goal?.summary == "Add examples")
    #expect(reopened?.goalSetAt != nil)
    #expect(
      await eventually { resumed.value.first?.sessionPrompt?.contains("Add examples") == true })
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
