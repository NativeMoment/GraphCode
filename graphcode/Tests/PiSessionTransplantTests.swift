import Foundation
import Testing

@testable import GraphcodeKit

/// pi resumes `--session <id>` only when the file sits under the working directory's own
/// slug and its header names that id; found under another slug it stops at an interactive
/// "fork into current directory?" prompt, and the header's cwd is where pi reopens it.
@Suite
struct PiSessionTransplantTests {
  private let session = Data(
    """
    {"type":"session","version":3,"id":"old-id","timestamp":"2026-09-12T22:30:30.343Z","cwd":"/Users/someone/src"}
    {"type":"model_change","id":"856c8497","parentId":null}
    {"type":"message","id":"a1","parentId":"856c8497","note":"resumed old-id"}

    """.utf8)

  @Test
  func headerTakesTheFreshIDAndTheTargetWorkingDirectory() throws {
    let rewritten = try #require(
      SessionTransplant.rewritingPiSession(
        session, replacing: "old-id", with: "fresh-id", workingDirectory: "/srv/widget"))
    let lines = try #require(String(data: rewritten, encoding: .utf8))
      .split(separator: "\n", omittingEmptySubsequences: false)

    let header = try #require(
      try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
    #expect(header["type"] as? String == "session")
    #expect(header["id"] as? String == "fresh-id")
    #expect(header["cwd"] as? String == "/srv/widget")
    #expect(header["version"] as? Int == 3)
    #expect(lines[0].contains("\"cwd\":\"/srv/widget\""))
    #expect(lines[1] == #"{"type":"model_change","id":"856c8497","parentId":null}"#)
    #expect(lines[2].contains("resumed fresh-id"))
    #expect(lines.count == 4)
  }

  @Test
  func aFileThatDoesNotOpenWithASessionHeaderIsRefused() {
    #expect(
      SessionTransplant.rewritingPiSession(
        Data("{\"type\":\"message\"}\n".utf8), replacing: "a", with: "b", workingDirectory: "/")
        == nil)
    #expect(
      SessionTransplant.rewritingPiSession(
        Data("not json".utf8), replacing: "a", with: "b", workingDirectory: "/") == nil)
  }

  @Test
  func slugMatchesPisOwnEncodingOfTheResolvedPath() {
    #expect(
      SessionTransplant.piSessionSlug(forWorkingDirectory: "/Volumes/SCG/wd/graphcode")
        == "--Volumes-SCG-wd-graphcode--")
    #expect(
      SessionTransplant.piSessionSlug(forWorkingDirectory: "/no-such/dir.d/x:y")
        == "--no-such-dir.d-x-y--")
    #expect(SessionTransplant.piSessionSlug(forWorkingDirectory: "/tmp") == "--private-tmp--")
  }

  @Test
  func fileNameCarriesPisTimestampShapeAndTheID() {
    let name = SessionTransplant.piSessionFileName(
      id: "fresh-id", at: Date(timeIntervalSince1970: 1_789_338_630.343))
    #expect(name.hasSuffix("_fresh-id.jsonl"))
    let shape = #"^\d{4}-\d\d-\d\dT\d\d-\d\d-\d\d-\d{3}Z_"#
    #expect(name.range(of: shape, options: .regularExpression) != nil)
  }

  @Test
  func remoteInstallLandsWhereTheSwiftSlugSaysAndBanksTheID() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("pi-transplant-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let repo = root.appendingPathComponent("repo:x", isDirectory: true)
    let staging = root.appendingPathComponent("staging", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let fileName = SessionTransplant.piSessionFileName(id: "fresh-id")
    try session.write(to: staging.appendingPathComponent(fileName))

    let nodeID = UUID()
    let location = RemoteProjectLocation(user: "dev", host: "box", remotePath: repo.path)
    let artifact = SessionTransplant.Artifact(
      backend: .pi, sessionID: "old-id", sourceWorkingDirectory: nil,
      files: ["session.jsonl": session])
    let script = try #require(
      SessionTransplant.remoteInstallScript(
        for: artifact, freshID: "fresh-id", nodeID: nodeID, at: location))

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
      "-c",
      "tar -C \(RemoteProjectLocation.shellQuoted(staging.path)) -cf - . | /bin/sh -c "
        + RemoteProjectLocation.shellQuoted(script),
    ]
    process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
    let status: Int32 = try await withCheckedThrowingContinuation { continuation in
      process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
      do {
        try process.run()
      } catch {
        process.terminationHandler = nil
        continuation.resume(throwing: error)
      }
    }
    #expect(status == 0)

    let installed = home.appendingPathComponent(".pi/agent/sessions")
      .appendingPathComponent(SessionTransplant.piSessionSlug(forWorkingDirectory: repo.path))
      .appendingPathComponent(fileName)
    #expect(FileManager.default.fileExists(atPath: installed.path))
    let banked = try String(
      contentsOf: home.appendingPathComponent(".graphcode/sessions/\(nodeID.uuidString).id"),
      encoding: .utf8)
    #expect(banked == "fresh-id")
  }
}
