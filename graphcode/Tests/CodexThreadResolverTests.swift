import Foundation
import SQLite3
import Testing

@testable import GraphcodeKit

/// Codex's `notify` can bank a thread id Codex never persists; the node's real thread is
/// found from Codex's own `threads` table instead (#346).
@Suite
struct CodexThreadResolverTests {
  private func database(_ rows: [(id: String, message: String, createdAt: Int)]) -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("state-\(UUID().uuidString).sqlite")
    var handle: OpaquePointer?
    sqlite3_open(url.path, &handle)
    sqlite3_exec(
      handle,
      "CREATE TABLE threads (id TEXT PRIMARY KEY, first_user_message TEXT, created_at_ms INTEGER)",
      nil, nil, nil)
    for row in rows {
      let message = row.message.replacingOccurrences(of: "'", with: "''")
      sqlite3_exec(
        handle, "INSERT INTO threads VALUES ('\(row.id)', '\(message)', \(row.createdAt))", nil,
        nil, nil)
    }
    sqlite3_close(handle)
    return url
  }

  @Test
  func aBankedIdCodexKnowsIsKept() {
    let node = UUID()
    let url = database([("real", "/goal read /x/\(node.uuidString)/PROMPT.md", 1)])
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(
      CodexThreadResolver.threadID(forNodeID: node, banked: "real", database: url) == "real")
  }

  @Test
  func aBankedIdCodexNeverPersistedResolvesToTheNodesNewestThread() {
    let node = UUID()
    let url = database([
      ("older", "/goal read /x/\(node.uuidString)/PROMPT.md", 1),
      ("newer", "/goal read /x/\(node.uuidString)/PROMPT.md", 2),
      ("other", "/goal read /x/\(UUID().uuidString)/PROMPT.md", 3),
    ])
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(
      CodexThreadResolver.threadID(forNodeID: node, banked: "ephemeral", database: url)
        == "newer")
    #expect(CodexThreadResolver.threadID(forNodeID: node, banked: nil, database: url) == "newer")
  }

  @Test
  func withNothingToGoOnTheBankedIdStands() {
    let url = database([("other", "no node here", 1)])
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(
      CodexThreadResolver.threadID(forNodeID: UUID(), banked: "ephemeral", database: url)
        == "ephemeral")
    #expect(CodexThreadResolver.threadID(forNodeID: UUID(), banked: nil, database: url) == nil)
  }

  @Test
  func theNewestStateDatabaseVersionIsTheOneRead() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for name in ["state_4.sqlite", "state_12.sqlite", "goals_1.sqlite", "state_5.sqlite-wal"] {
      FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: nil)
    }
    let original = CodexThreadResolver.codexDirectory
    CodexThreadResolver.codexDirectory = directory
    defer { CodexThreadResolver.codexDirectory = original }

    #expect(CodexThreadResolver.stateDatabase()?.lastPathComponent == "state_12.sqlite")
  }
}
