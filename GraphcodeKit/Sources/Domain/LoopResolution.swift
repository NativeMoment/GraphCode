import Foundation

/// How a loop reached `.succeeded` or `.failed` — the evidence behind the word on its card.
///
/// A SUCCEEDED that a predicate proved and one an agent claimed are not the same claim,
/// and a human deciding whether to trust a result has to be able to tell them apart
/// without opening the loop's memory (issue #346).
public struct LoopResolution: Codable, Equatable, Sendable {
  public enum Basis: String, Codable, Equatable, Sendable, CaseIterable {
    /// The goal's `--predicate` exited 0.
    case predicate
    /// The backend recorded its own `/goal` as met (`GoalVerdictReader`).
    case nativeGoal
    /// The loop itself, or the loop that created it, ran `graphcode node done`.
    case agentReported
    /// Someone at the Mac's own shell ran `graphcode node done`.
    case human
    /// The pane watching the session saw its process finish.
    case sessionExited
    /// A composite's workers rolled up to a terminal state.
    case workers

    /// A judgement on the goal itself, as opposed to a surface reporting that something
    /// ended — which a human's repeated check approval legitimately does more than once.
    public var isVerdict: Bool {
      switch self {
      case .predicate, .nativeGoal, .agentReported, .human: return true
      case .sessionExited, .workers: return false
      }
    }
  }

  public var basis: Basis
  /// What the resolver had to say about it, when it said anything.
  public var detail: String?
  public var resolvedAt: Date

  public init(basis: Basis, detail: String? = nil, resolvedAt: Date = Date()) {
    self.basis = basis
    self.detail = detail
    self.resolvedAt = resolvedAt
  }

  /// The card's line for a resolved loop: the basis, then the resolver's own words.
  public var displayLine: String {
    let phrase: String
    switch basis {
    case .predicate: phrase = "predicate passed"
    case .nativeGoal: phrase = "goal met"
    case .agentReported: phrase = "reported done"
    case .human: phrase = "marked done"
    case .sessionExited: phrase = "session exited"
    case .workers: phrase = "workers rolled up"
    }
    guard let detail, !detail.isEmpty else { return phrase }
    return "\(phrase) · \(detail)"
  }
}
