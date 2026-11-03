import Foundation
import Synchronization

enum ToolStepDecision: Equatable, Sendable { case proceed, shrinkEarlierResults, answerWithoutTools }

/// Shared by one tool loop and the tools it runs, for one turn (F35). The loop measures the
/// request before each step; `web_search` sizes its result to the room left.
final class ToolStepBudget: Sendable {
  /// The plan's smallest `web_search` result.
  static let smallestResult = 256
  static let answerInstruction = "You can't call any more tools in this turn. Answer now from the results you already have, and say if something you needed is missing."
  static let removedExcerpt = "(excerpt removed to save space)"
  /// The largest `web_search` result on a local route; cloud routes use `WebSearchLimits.evidenceTokens`.
  static let localEvidenceTokens = 2_048

  /// What a tool turn's history leaves free: one full-size result and the room the next step needs.
  static func reserve(cap: Int) -> Int { cap + 2 * smallestResult }

  private let state = Mutex<(budget: ContextBudget, used: Int)?>(nil)

  /// Records the request as it stands: `usedTokens` of `budget`'s input.
  func measure(_ budget: ContextBudget, usedTokens: Int) {
    state.withLock { $0 = (budget, usedTokens) }
  }

  /// Counts a result returned to a CLI's own tool loop, whose requests Enigma never sees.
  func add(_ tokens: Int) {
    state.withLock { $0?.used += tokens }
  }

  /// Tokens left for the next tool result and the model's next step; unlimited before a measurement.
  var roomLeft: Int {
    state.withLock { $0.map { $0.budget.availableInputTokens - $0.used } ?? .max }
  }

  /// min(cap, roomLeft / 2), or nil when that is below the smallest result.
  func evidenceTokens(cap: Int) -> Int? {
    let tokens = min(cap, roomLeft / 2)
    return tokens < Self.smallestResult ? nil : tokens
  }

  /// The usage of the request as it stands, for the ring (CP5); nil before a measurement.
  var usage: ContextUsage? {
    state.withLock { state in
      state.map { ContextUsage(usedTokens: $0.used + $0.budget.promptTokens,
                               limitTokens: $0.budget.availableInputTokens + $0.budget.promptTokens) }
    }
  }

  /// Before a step that follows tool results: proceed while a smallest result would still fit;
  /// otherwise `shrink` rewrites this turn's earlier results and returns the new count, and when
  /// even that leaves no room the step is sent without tools. A request still over the budget
  /// shrinks the newest results too (`includingNewest`), rather than go out known not to fit.
  func decide(usedTokens: Int, budget: ContextBudget, shrink: (_ includingNewest: Bool) -> Int) -> ToolStepDecision {
    measure(budget, usedTokens: usedTokens)
    if evidenceTokens(cap: .max) != nil { return .proceed }
    measure(budget, usedTokens: shrink(false))
    if evidenceTokens(cap: .max) != nil { return .shrinkEarlierResults }
    if roomLeft < 0 { measure(budget, usedTokens: shrink(true)) }
    return .answerWithoutTools
  }

  /// A `web_search` result with each source's excerpt text replaced, keeping its title, site and
  /// URL. Reads the local loop's `{"result":…}` wrapper too. Anything else comes back unchanged,
  /// and so does a result shrunk before.
  static func shrunkSearchResult(_ text: String) -> String {
    func shrunk(_ value: Any) -> Any? {
      guard var object = value as? [String: Any] else { return nil }
      if let results = object["results"] as? [[String: Any]] {
        guard results.contains(where: { $0["url"] != nil && $0["text"] as? String != removedExcerpt }) else { return nil }
        object["results"] = results.map { result in
          var result = result
          if result["url"] != nil { result["text"] = removedExcerpt }
          return result
        }
        return object
      }
      guard let inner = object["result"].flatMap(shrunk) else { return nil }
      object["result"] = inner
      return object
    }
    guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)), let result = shrunk(parsed),
          let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
    else { return text }
    return String(decoding: data, as: UTF8.self)
  }
}
