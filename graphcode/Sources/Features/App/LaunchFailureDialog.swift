import ComposableArchitecture
import Foundation
import GraphcodeKit
import SwiftUI

/// The alert for `SessionRestart.launchFailureNotice`.
struct LaunchFailureDialog: ViewModifier {
  let store: StoreOf<AppFeature>

  func body(content: Content) -> some View {
    content
      .alert(
        store.sessionRestart.launchFailureNotice?.title ?? "",
        isPresented: Binding(
          get: { store.sessionRestart.launchFailureNotice != nil },
          set: { if !$0 { store.send(.sessionRestart(.launchFailureNoticeDismissed)) } }
        )
      ) {
        Button("OK") { store.send(.sessionRestart(.launchFailureNoticeDismissed)) }
      } message: {
        Text(store.sessionRestart.launchFailureNotice?.message ?? "")
      }
  }
}

extension AppFeature {
  /// The deletion a key on a dead agent pane stands for (`.primaryExitAcknowledged`) —
  /// except for a loop stopped for a missing CLI, which is waiting for the restart its
  /// dialog asked for. The key only puts that pane away.
  func deleteAcknowledgedLoop(_ id: UUID, in projectPath: String, _ state: State)
    -> Effect<Action>
  {
    guard state.projects[id: projectPath]?.graph.nodes[id: id]?.launchFailure == nil else {
      return .none
    }
    return .run { _ in
      try? await orchestratorClient.send(
        .graphCommand(projectPath: projectPath, command: .deleteNode(id)))
    }
  }
}
