import Foundation
import SQLite3
import Testing

@testable import GraphcodeKit

@Suite
struct GoalVerdictTests {
  private func lines(_ records: [String]) -> [Substring] {
    records.joined(separator: "\n").split(separator: "\n")
  }

  @Test
  func claudeCountsOnlyAnEvaluatorVerdictOnThisLoopsGoal() {
    func status(_ fields: String) -> String {
      #"{"attachment":{"type":"goal_status","condition":"say hi","# + fields + "}}"
    }
    let set = status(#""met":false,"sentinel":true"#)
    let met = status(#""met":true,"reason":"said Hi!""#)
    let cleared = status(#""met":true,"sentinel":true"#)
    let notYet = status(#""met":false"#)

    #expect(
      GoalVerdictReader.claudeVerdict(lines: lines([set, met]), goalSummary: "say hi")
        == GoalVerdict(met: true, detail: "said Hi!"))
    #expect(GoalVerdictReader.claudeVerdict(lines: lines([set]), goalSummary: "say hi") == nil)
    #expect(
      GoalVerdictReader.claudeVerdict(lines: lines([set, met, cleared]), goalSummary: "say hi")
        == nil)
    #expect(
      GoalVerdictReader.claudeVerdict(lines: lines([set, notYet]), goalSummary: "say hi")
        == GoalVerdict(met: false))
    #expect(
      GoalVerdictReader.claudeVerdict(lines: lines([set, met]), goalSummary: "write docs") == nil)
  }

  @Test
  func aConditionCarryingTheLaunchsAppendedSentencesStillNamesTheGoal() {
    #expect(
      GoalVerdictReader.conditionNamesGoal(
        "Fix  the\nlogin bug. The goal counts as met when this command exits 0: make test",
        goalSummary: "Fix the login bug."))
    #expect(!GoalVerdictReader.conditionNamesGoal("anything", goalSummary: "   "))
  }

  @Test
  func copilotFollowsTheNewestObjectiveStatus() {
    func event(_ status: String) -> String {
      #"{"type":"session.autopilot_objective_changed","data":{"status":""#
        + status + #""}}"#
    }
    let turnEnd = #"{"type":"assistant.turn_end","data":{}}"#
    let completedThenTurnEnd = lines([event("active"), event("completed"), turnEnd])
    #expect(
      GoalVerdictReader.copilotVerdict(lines: completedThenTurnEnd) == GoalVerdict(met: true))
    #expect(
      GoalVerdictReader.copilotVerdict(lines: lines([event("completed"), event("active")]))
        == GoalVerdict(met: false))
    #expect(GoalVerdictReader.copilotVerdict(lines: lines([turnEnd])) == nil)
  }

  @Test
  func codexReadsTheThreadsGoalStatus() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("goals-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    var handle: OpaquePointer?
    #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
    let schema = """
      CREATE TABLE thread_goals (
        thread_id TEXT PRIMARY KEY, status TEXT NOT NULL, updated_at_ms INTEGER NOT NULL);
      INSERT INTO thread_goals VALUES
        ('done-thread', 'complete', 1789325210264), ('busy-thread', 'active', 1789329177000);
      """
    #expect(sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(handle)

    #expect(
      GoalVerdictReader.codexVerdict(threadID: "done-thread", database: url)
        == GoalVerdict(met: true, recordedAt: Date(timeIntervalSince1970: 1_789_325_210.264)))
    #expect(
      GoalVerdictReader.codexVerdict(threadID: "busy-thread", database: url)?.met == false)
    #expect(GoalVerdictReader.codexVerdict(threadID: "unknown", database: url) == nil)
  }

  @Test
  func recordsCarryTheirTimeSoAnEarlierGoalsVerdictIsRecognised() {
    let line =
      #"{"timestamp":"2026-09-05T18:19:20.490Z","attachment":{"type":"goal_status","#
      + #""met":true,"condition":"say hi"}}"#
    let verdict = GoalVerdictReader.claudeVerdict(lines: lines([line]), goalSummary: "say hi")
    let recorded = Date(timeIntervalSince1970: 1_788_632_360.490)
    #expect(verdict?.recordedAt.map { abs($0.timeIntervalSince(recorded)) < 0.001 } == true)

    var node = LoopNode(title: "a", loopType: .goalBased, createdAt: recorded.addingTimeInterval(-60))
    #expect(GraphStore.verdict(GoalVerdict(met: true, recordedAt: recorded), isCurrentFor: node))
    #expect(GraphStore.verdict(GoalVerdict(met: true), isCurrentFor: node))

    node.goalSetAt = recorded.addingTimeInterval(1)
    #expect(!GraphStore.verdict(GoalVerdict(met: true, recordedAt: recorded), isCurrentFor: node))
    #expect(!GraphStore.verdict(GoalVerdict(met: true), isCurrentFor: node))
  }

  @Test
  func aMetVerdictResolvesAPredicateLessGoalAndFiresItsEdges() async {
    let store = GraphStore(onReadGoalVerdict: { _, _ in GoalVerdict(met: true, detail: "done") })
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Docs", loopType: .goalBased, goal: GoalSpec(summary: "The doc reads well"))))
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Ship", loopType: .turnBased, checkDescription: "?", firstInstruction: "Work")))
    let nodes = await store.graph.nodes
    await store.handle(.createEdge(from: nodes[0].id, to: nodes[1].id, spec: EdgeSpec()))

    await store.evaluateGoal(nodes[0].id)
    await store.evaluateGoal(nodes[0].id)

    let graph = await store.graph
    #expect(graph.nodes[id: nodes[0].id]?.state == .succeeded)
    #expect(graph.nodes[id: nodes[0].id]?.resolution?.basis == .nativeGoal)
    #expect(graph.nodes[id: nodes[0].id]?.resolution?.detail == "done")
    #expect(graph.edges[0].fireCount == 1)
  }

  @Test
  func anUnmetOrMissingVerdictLeavesTheGoalRunning() async {
    for verdict in [GoalVerdict(met: false), nil] {
      let store = GraphStore(onReadGoalVerdict: { _, _ in verdict })
      await store.handle(
        .createNode(
          NodeDraft(
            title: "Docs", loopType: .goalBased, goal: GoalSpec(summary: "The doc reads well"))))
      let nodeID = await store.graph.nodes[0].id

      await store.evaluateGoal(nodeID)

      #expect(await store.graph.nodes[id: nodeID]?.state == .running)
    }
  }

  @Test
  func aPredicateStillDecidesWhenTheGoalHasOne() async {
    let store = GraphStore(
      onEvaluatePredicate: { _ in false },
      onReadGoalVerdict: { _, _ in GoalVerdict(met: true) })
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Green", loopType: .goalBased,
          goal: GoalSpec(summary: "CI passes", predicate: "make test"))))
    let nodeID = await store.graph.nodes[0].id

    await store.evaluateGoal(nodeID)

    #expect(await store.graph.nodes[id: nodeID]?.state == .running)
  }
}
