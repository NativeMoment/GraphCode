import Foundation
import Testing

@testable import GraphcodeKit

@testable import graphcode

@Suite
struct CopilotVersionTests {
  private let version = "1.0.84-5"
  private let location = RemoteProjectLocation(
    user: "dev", host: "host", remotePath: "/workspaces/widget")

  private func settings(_ version: String) -> GraphcodeSettings {
    GraphcodeSettings(copilotPreferredVersion: version, briefsSessionsAboutTheGraph: false)
  }

  private func surface(_ backend: CLISessionBackendKind = .copilotCLI) -> GhosttyTerminalView {
    GhosttyTerminalView(
      surfaceID: UUID(),
      sessionName: SurfaceRef(id: UUID(), launchesClaudeCode: true).zmxSessionName,
      launchesClaudeCode: true, backend: backend, initialPrompt: "go",
      workingDirectory: nil, onProcessExited: { _ in })
  }

  @Test(arguments: ["", " \t\n "])
  func blankMeansNoOverride(_ value: String) {
    let settings = settings(value)
    #expect(settings.normalizedCopilotPreferredVersion == nil)
    #expect(settings.copilotInstallCommand == nil)
    #expect(CLISessionBackendKind.copilotCLI.versionArguments(settings).isEmpty)
    #expect(
      !CLISessionBackendKind.copilotCLI.launchArguments(
        prompt: "go", tier: .standard, settings: settings
      ).contains("--prefer-version"))
    #expect(
      surface().agentCommand(settings: settings)?.last?.contains("--prefer-version") == false)
    #expect(
      SummaryModelWriter.invocation(
        forBackend: .copilotCLI, prompt: "go", tier: .standard, settings: settings)
        == ["copilot", "-p", "go"])
    #expect(
      TitleSuggestionClient.invocation(for: .copilotCLI, settings: settings)?.last
        == #"exec copilot -p "$GRAPHCODE_TITLE_PROMPT""#)
  }

  @Test
  func surroundingWhitespaceIsNotPartOfTheVersion() {
    let settings = settings(" \t\(version)\n")
    #expect(settings.normalizedCopilotPreferredVersion == version)
    #expect(
      CLISessionBackendKind.copilotCLI.versionArguments(settings)
        == ["--prefer-version", version])
    #expect(settings.copilotInstallCommand == "npm install -g '@github/copilot@\(version)'")
  }

  @Test
  func nullAndMissingKeysKeepTheDefault() throws {
    for json in ["{}", #"{"copilotPreferredVersion": null}"#] {
      let decoded = try JSONDecoder().decode(GraphcodeSettings.self, from: Data(json.utf8))
      #expect(decoded.copilotPreferredVersion.isEmpty)
    }
  }

  @Test(arguments: CLISessionBackendKind.allCases)
  func versionPreferencesStartAtDefaultForEveryBackend(_ backend: CLISessionBackendKind) {
    #expect(backend.supportsVersionPreference == (backend == .copilotCLI))
    #expect(backend.versionArguments(GraphcodeSettings()).isEmpty)
  }

  @Test(arguments: CLISessionBackendKind.offerableAsDefault)
  func aVersionOverrideDoesNotSelectADifferentBackend(_ backend: CLISessionBackendKind) {
    var settings = GraphcodeSettings(defaultBackend: backend)
    settings.copilotPreferredVersion = version
    #expect(settings.defaultBackend == backend)
    settings.copilotPreferredVersion = ""
    #expect(settings.defaultBackend == backend)
  }

  @Test(arguments: [nil, "", "go", "/loop 1h check CI"] as [String?])
  func everyLaunchShapeGetsTheVersionBeforeOtherFlags(_ prompt: String?) {
    let arguments = CLISessionBackendKind.copilotCLI.launchArguments(
      prompt: prompt, tier: .fast, settings: settings(version), sessionName: "session")
    #expect(Array(arguments.prefix(4)) == ["--prefer-version", version, "--model", "gpt-5.6-luna"])
    #expect(arguments.filter { $0 == "--prefer-version" }.count == 1)
    #expect(arguments.contains("--yolo"))
    #expect(arguments.contains("--name"))
  }

  @Test(arguments: [false, true])
  func daemonLaunchAndResumeHonorThePinLocallyAndRemotely(_ remote: Bool) throws {
    let node = LoopNode(
      title: "Ship", loopType: .goalBased, goal: GoalSpec(summary: "tests pass"),
      backend: .copilotCLI)
    let projectPath = remote ? location.projectPath : nil
    let settings = settings(version)
    let launch = try #require(
      ZmxSessionLauncher.arguments(forNode: node, projectPath: projectPath, settings: settings))
    let resume = try #require(
      ZmxSessionLauncher.resumeArguments(
        forNode: node, sessionID: "saved-session", projectPath: projectPath, settings: settings))
    for arguments in [launch, resume] {
      let index = try #require(arguments.firstIndex(of: "--prefer-version"))
      #expect(arguments[index + 1] == version)
      #expect(arguments.filter { $0 == "--prefer-version" }.count == 1)
      #expect(arguments.contains("--yolo"))
    }
    #expect(resume.suffix(2) == ["--resume", "saved-session"])
    #expect(!resume.contains("--name"))
    if remote {
      let command = try #require(
        ZmxSessionLauncher.remoteEnsureInvocation(forNode: node, at: location, settings: settings)?
          .last)
      #expect(command.contains("--prefer-version"))
      #expect(command.contains(version))
    }
  }

  @Test(arguments: [false, true])
  func appLaunchAndResumeHonorThePinLocallyAndRemotely(_ remote: Bool) throws {
    let surface = surface()
    let settings = settings(version)
    let launch = try #require(surface.agentCommand(settings: settings, isRemote: remote)?.last)
    let resume = try #require(
      surface.resumeCommand(settings: settings, remoteSettingsPath: nil, isRemote: remote)?.last)
    for command in [launch, resume] {
      #expect(command.hasPrefix("exec copilot '--prefer-version' '\(version)' --yolo"))
    }
    #expect(!resume.contains("--name"))
    let resumed = try recordedArguments(resume)
    #expect(resumed == ["--prefer-version", version, "--yolo", "--resume", "saved-session"])
    if remote {
      let command = try #require(surface.remoteCommand(at: location, settings: settings).last)
      #expect(command.contains("--prefer-version"))
      #expect(command.contains(version))
    }
  }

  @Test(arguments: CLISessionBackendKind.allCases.filter { !$0.supportsVersionPreference })
  func otherBackendsAreUnchanged(_ backend: CLISessionBackendKind) {
    let pinned = settings(version)
    let defaults = settings("")
    #expect(
      backend.launchArguments(prompt: "go", tier: .standard, settings: pinned)
        == backend.launchArguments(prompt: "go", tier: .standard, settings: defaults))
    #expect(
      surface(backend).launchPrefix(settings: pinned)
        == surface(backend).launchPrefix(settings: defaults))
    #expect(
      SummaryModelWriter.invocation(forBackend: backend, prompt: "go", settings: pinned)
        == SummaryModelWriter.invocation(forBackend: backend, prompt: "go", settings: defaults))
    #expect(
      TitleSuggestionClient.invocation(for: backend, settings: pinned)
        == TitleSuggestionClient.invocation(for: backend, settings: defaults))
  }

  @Test
  func headlessRequestsUseTheSamePinWithoutAddingPermissions() throws {
    let settings = settings(version)
    #expect(
      SummaryModelWriter.invocation(
        forBackend: .copilotCLI, prompt: "summarise", tier: .standard, settings: settings)
        == ["copilot", "--prefer-version", version, "-p", "summarise"])
    let title = try #require(
      TitleSuggestionClient.invocation(for: .copilotCLI, settings: settings)?.last)
    #expect(try recordedArguments(title) == ["--prefer-version", version, "-p", "name this"])
  }

  @Test(arguments: ["1.0.84-5", "bad' version; $HOME `printf unexpected`"])
  func shellCommandsKeepTheVersionAsOneLiteralArgument(_ value: String) throws {
    let settings = settings(value)
    let launch = try #require(surface().agentCommand(settings: settings)?.last)
    let launched = try recordedArguments(launch)
    #expect(Array(launched.prefix(2)) == ["--prefer-version", value])
    let install = try #require(settings.copilotInstallCommand)
    #expect(
      try recordedArguments(install, executable: "npm")
        == ["install", "-g", "@github/copilot@\(value)"])
    let title = try #require(
      TitleSuggestionClient.invocation(for: .copilotCLI, settings: settings)?.last)
    #expect(try recordedArguments(title) == ["--prefer-version", value, "-p", "name this"])
  }

  private func recordedArguments(
    _ command: String, executable: String = "copilot"
  ) throws -> [String] {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("copilot-version-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let stub = directory.appendingPathComponent(executable)
    try "#!/bin/sh\nprintf '%s\\n' \"$@\"\n".write(to: stub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.environment = [
      "PATH": directory.path + ":/usr/bin:/bin",
      "GRAPHCODE_TRIGGER_PROMPT": "go",
      "GRAPHCODE_TITLE_PROMPT": "name this",
      "GRAPHCODE_RESUME_ID": "saved-session",
    ]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    let recorded = try #require(String(data: data, encoding: .utf8))
    return recorded.split(separator: "\n").map(String.init)
  }
}
