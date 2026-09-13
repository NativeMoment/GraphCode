import Foundation

/// A backend's own answer to "is this session's goal met?", read out of what the backend
/// records — never inferred from a turn ending. A turn ends while a loop waits on mail,
/// CI or its children; only a goal-specific record says the condition holds (#346).
public struct GoalVerdict: Equatable, Sendable {
  public var met: Bool
  /// The backend's stated reason, when it gives one — Claude Code's evaluator does.
  public var detail: String?

  public init(met: Bool, detail: String? = nil) {
    self.met = met
    self.detail = detail
  }
}
