import Foundation

/// The guesses a trained model can make from a draft's wording.
/// Depends on Foundation only: the training script compiles this file.
enum IntentSkill: String, CaseIterable, Sendable {
  case search, messages, think, selection, coding, reasoning

  /// Which way a skill's cut-off leans. `off` skills pick the cut-off with the most
  /// correct yeses while at most `maximumWrongYesShare` of their yeses are wrong,
  /// since a wrong yes reads messages, changes a selection or leaves the Mac.
  enum Lean: Sendable { case none, off }

  static let maximumWrongYesShare = 0.02

  var labels: [String] {
    self == .selection ? ["edit", "translate", "none"] : ["yes", "no"]
  }

  var negativeLabel: String {
    self == .selection ? "none" : "no"
  }

  var lean: Lean {
    switch self {
    case .search, .think: .none
    case .messages, .selection, .coding, .reasoning: .off
    }
  }

  var modelName: String {
    "Intent" + rawValue.prefix(1).uppercased() + rawValue.dropFirst()
  }

  /// Chip skills run while typing and share one speed budget; the others run at send.
  var isChip: Bool {
    switch self {
    case .search, .messages, .think, .selection: true
    case .coding, .reasoning: false
    }
  }

  /// Binary: "yes" when probabilities["yes"] ≥ cutoff, else "no".
  /// Selection: "translate" when its probability ≥ cutoff, else "edit" when
  /// its probability ≥ cutoff, else "none" (translation wins).
  func answer(probabilities: [String: Double], cutoff: Double) -> String {
    guard self == .selection else {
      return (probabilities["yes"] ?? 0) >= cutoff ? "yes" : "no"
    }
    if (probabilities["translate"] ?? 0) >= cutoff { return "translate" }
    if (probabilities["edit"] ?? 0) >= cutoff { return "edit" }
    return "none"
  }
}
