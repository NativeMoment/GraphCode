import Foundation
import Testing

@testable import GraphcodeKit

/// pi as a real backend, spiked against 0.85.1.
///
/// Flags read off the installed `pi --help`, extension events off a probe extension run
/// against the real binary. The shape that matters: `pi` takes its prompt positionally,
/// resumes with `--session <id>`, loads its reporter with `-e <path>`, and has no goal or
/// loop directive of its own.
@Suite
struct PiBackendTests {
  private func node(_ loopType: LoopType = .goalBased) -> LoopNode {
    LoopNode(
      title: "Ship it", loopType: loopType, goal: GoalSpec(summary: "Tests pass"), backend: .pi)
  }

  @Test
  func theSessionRunsPiNotClaude() {
    let arguments = ZmxSessionLauncher.arguments(forNode: node()) ?? []

    #expect(arguments.contains(where: { $0.hasSuffix(#"pi "$@""#) }))
    #expect(!arguments.contains(where: { $0.contains("claude ") }))
  }

  @Test
  func thePromptIsPositionalAndLast() {
    let arguments = CLISessionBackendKind.pi.launchArguments(
      prompt: "go", tier: .standard, settings: GraphcodeSettings())

    #expect(arguments.last == "go")
    #expect(CLISessionBackendKind.pi.promptFlag == nil)
  }

  @Test
  func aGoalRidesAsProseBecausePiHasNoGoalDirective() {
    #expect(CLISessionBackendKind.pi.capabilities.goalDirective == nil)
    let prompt = node().sessionPrompt ?? ""
    #expect(prompt.hasPrefix("Work toward this goal until it is met: Tests pass"))
    #expect(!prompt.contains("/goal"))
  }

  @Test
  func theUnattendedDefaultTrustsTheProject() {
    // pi asks nothing per tool; its one startup dialog is project trust.
    let arguments = CLISessionBackendKind.pi.launchArguments(
      prompt: "go", tier: .standard, settings: GraphcodeSettings())
    #expect(arguments.contains("--approve"))

    let asking = CLISessionBackendKind.pi.launchArguments(
      prompt: "go", tier: .standard, settings: GraphcodeSettings(piProjectTrust: .ask))
    #expect(!asking.contains("--approve"))
  }

  @Test
  func noTierNamesAModelBecauseTheProviderIsTheUsers() {
    for tier in ModelTier.allCases {
      #expect(CLISessionBackendKind.pi.modelArguments(for: tier).isEmpty)
    }
  }

  @Test
  func theBriefingIsAPointerInThePromptAndNeedsNoDirectoryGrant() {
    let arguments = CLISessionBackendKind.pi.launchArguments(
      prompt: "go", tier: .standard, briefingPath: "/Users/x/.graphcode/briefings/b.md",
      workspacePaths: ["/work"])

    #expect(!arguments.contains("--add-dir"))
    #expect(arguments.last?.contains("/Users/x/.graphcode/briefings/b.md") == true)
    #expect(arguments.last?.hasSuffix(" go") == true)
    #expect(!CLISessionBackendKind.pi.briefingNeedsDirectoryGrant)
  }

  @Test
  func theExtensionLoadsByPathOnTheArgv() {
    let file = URL(fileURLWithPath: "/Users/x/.graphcode/hooks/pi-presence.js")

    #expect(CLISessionBackendKind.pi.presenceArguments(hooksFile: file) == ["-e", file.path])
    #expect(CLISessionBackendKind.pi.presenceArguments(hooksFile: nil).isEmpty)
    #expect(CLISessionBackendKind.pi.presenceEnvironment(hooksFile: file).isEmpty)
  }

  @Test
  func resumeNamesTheExactSession() {
    // `--continue` would pick the project's most recent session, which with several loops
    // in one folder is somebody else's.
    #expect(CLISessionBackendKind.pi.supportsResume)
    #expect(CLISessionBackendKind.pi.resumeArguments(sessionID: "abc") == ["--session", "abc"])
  }

  @Test
  func theExtensionReportsEveryEdgeTheGraphReads() {
    let source = PiPresenceExtension.source(
      zmxPath: "/Users/o'brien/bin/zmx", sessionsDirectory: "/Users/o'brien/.graphcode/sessions")

    #expect(source.contains(#"const ZMX = "/Users/o'brien/bin/zmx""#))
    #expect(source.contains("export default function (pi)"))
    #expect(source.contains("process.env.ZMX_SESSION"))
    for event in [
      "session_start", "agent_start", "agent_settled", "tool_call", "ui_prompt_start",
      "ui_prompt_end",
    ] {
      #expect(source.contains("\"\(event)\""), "\(event) is not reported")
    }
    for label in ["presence=busy", "presence=idle", "presence=awaitingInput", "usage=input."] {
      #expect(source.contains(label), "\(label) is never written")
    }
    // `agent_end` can be followed by a retry or a queued follow-up; idle there would lie.
    #expect(!source.contains("agent_end"))
    #expect(source.contains(".history"))
  }

  @Test
  func anIDIsBankedOnlyOnceItsSessionFileExists() throws {
    // pi writes nothing until the first assistant message, and `--session <id>` exits 1 on
    // an id with no file: banked at startup, a quit-before-reply session left a dead id.
    let source = PiPresenceExtension.source(zmxPath: "/bin/zmx", sessionsDirectory: "/s")
    let bank = try #require(source.range(of: "const bank = (ctx) => {"))
    let write = try #require(source.range(of: "writeFileSync(join(SESSIONS"))
    let body = source[bank.upperBound..<write.lowerBound]

    #expect(body.contains("existsSync(file)"))
    for event in ["tool_call", "agent_settled"] {
      let handler = try #require(source.range(of: "pi.on(\"\(event)\""))
      let next = source[handler.upperBound...].range(of: "pi.on(")?.lowerBound ?? source.endIndex
      #expect(source[handler.upperBound..<next].contains("bank(ctx)"), "\(event) never banks")
    }
  }

  @Test
  func aRemoteLaunchWritesAndLoadsItsExtension() throws {
    let remoteNode = LoopNode(
      title: "Ship it", loopType: .goalBased, goal: GoalSpec(summary: "Tests pass"),
      backend: .pi, state: .running)
    let location = RemoteProjectLocation(
      user: "dev", host: "build-box", remotePath: "/home/dev/widget")
    let invocation = try #require(
      ZmxSessionLauncher.remoteEnsureInvocation(forNode: remoteNode, at: location))
    let command = try #require(invocation.last)

    #expect(command.contains("pi-presence.js"))
    #expect(command.contains("-e"))
    #expect(command.contains("process.env.HOME"))
  }

  @Test
  func itHostsEveryLoopTypeButComposite() {
    #expect(CLISessionBackendKind.pi.canHost(.goalBased))
    #expect(CLISessionBackendKind.pi.canHost(.turnBased))
    #expect(CLISessionBackendKind.pi.canHost(.sketch))
    #expect(CLISessionBackendKind.pi.canHost(.timeBased))
    #expect(!CLISessionBackendKind.pi.canHost(.composite))
    #expect(CLISessionBackendKind.offerableAsDefault.contains(.pi))
  }

  @Test
  func settingsRoundTripAndDefaultToApprove() throws {
    let decoded = try JSONDecoder().decode(GraphcodeSettings.self, from: Data("{}".utf8))
    #expect(decoded.piProjectTrust == .approve)

    var settings = GraphcodeSettings()
    settings.piProjectTrust = .ask
    let data = try JSONEncoder().encode(settings)
    let back = try JSONDecoder().decode(GraphcodeSettings.self, from: data)
    #expect(back.piProjectTrust == .ask)
  }

  @Test
  func theHeadlessInvocationCannotRunTools() {
    #expect(
      SummaryModelWriter.invocation(forBackend: .pi, prompt: "say hi")
        == ["pi", "-p", "--no-tools", "--no-session", "say hi"])
  }
}
