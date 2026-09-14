import GraphcodeKit
import SwiftUI

struct PreferredVersionsSettingsSection: View {
  @Binding var settings: GraphcodeSettings
  @State private var isEnteringCopilotVersion = false

  var body: some View {
    Section {
      ForEach(CLISessionBackendKind.offerableAsDefault, id: \.self) { backend in
        Picker(
          backend.displayName,
          selection: backend.supportsVersionPreference ? copilotSelection : .constant(false)
        ) {
          Text("Default").tag(false)
          if backend.supportsVersionPreference {
            Text("Specific version").tag(true)
          }
        }
        .disabled(!backend.supportsVersionPreference)

        if backend == .copilotCLI, copilotSelection.wrappedValue {
          copilotVersionEditor
        }
      }
    } header: {
      Text("Preferred versions")
    } footer: {
      Text(
        "Default leaves version selection to each CLI; it does not install the latest release. "
          + "Only Copilot currently supports an override. These settings do not change "
          + "which backend new loops or chats use."
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
  }

  private var copilotSelection: Binding<Bool> {
    Binding(
      get: { isEnteringCopilotVersion || settings.normalizedCopilotPreferredVersion != nil },
      set: { usesSpecificVersion in
        isEnteringCopilotVersion = usesSpecificVersion
        if !usesSpecificVersion { settings.copilotPreferredVersion = "" }
      })
  }

  private var copilotVersionEditor: some View {
    Group {
      TextField("Copilot version", text: $settings.copilotPreferredVersion, prompt: Text("Version"))
      Text(
        "Install and verify the chosen version on each machine before setting it here. "
          + "Changes apply immediately to new and resumed sessions and to title and summary "
          + "requests. Running sessions are unchanged. Installation is not automatic."
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      if let command = settings.copilotInstallCommand {
        HStack {
          Text(command)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
          Spacer()
          Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
          }
          .help("Copy the npm install command")
        }
      }
    }
  }
}
