import Foundation

/// Text cleanup shared by the rules, the models and the training script.
/// Depends on Foundation only: the training script compiles this file.
enum IntentText {
  static let modelCharacterLimit = 500

  /// Today's `questionText` without `/think` removal: literal material
  /// (code blocks, backticks, straight and curly double quotes) replaced by
  /// a space, `’` → `'`, lowercased, "whats" → "what's", whitespace runs
  /// collapsed to one space, spaces trimmed.
  static func clean(_ text: String) -> String {
    let literal = literalMaterial.stringByReplacingMatches(in: text,
      range: NSRange(text.startIndex..., in: text),
      withTemplate: " ")
      .replacingOccurrences(of: "’", with: "'")
      .lowercased()
    // "whats" typed without its apostrophe reads as "what's", so every pattern sees one spelling.
    let spelled = whatsWithoutApostrophe.stringByReplacingMatches(in: literal,
      range: NSRange(literal.startIndex..., in: literal), withTemplate: "what's")
    // Collapse whitespace runs to one space. A regex is much faster than splitting
    // and joining, and the composer resolves every draft on each keystroke.
    let collapsed = whitespaceRun.stringByReplacingMatches(in: spelled,
      range: NSRange(spelled.startIndex..., in: spelled), withTemplate: " ")
    return collapsed.trimmingCharacters(in: [" "])
  }

  /// For models only: each four-digit number from 1000 to 2999 becomes
  /// `yearpast`, `yearrecent` or `yearfuture` relative to `now`'s Gregorian
  /// year (≤ year−2, year−1...year+1, ≥ year+2); then, when longer than
  /// 1,000 characters, the first 500 and last 500 joined by one space.
  static func modelInput(_ cleaned: String, now: Date) -> String {
    let year = Calendar(identifier: .gregorian).component(.year, from: now)
    // One forward pass over the unchanged text: editing it in place re-indexes non-ASCII
    // text on every replacement, which is quadratic on a long pasted log.
    var text = ""
    var copied = cleaned.startIndex
    for match in fourDigitNumber.matches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)) {
      guard let range = Range(match.range, in: cleaned), let value = Int(cleaned[range]),
            (1000...2999).contains(value) else { continue }
      text += cleaned[copied..<range.lowerBound]
      text += value <= year - 2 ? "yearpast" : value >= year + 2 ? "yearfuture" : "yearrecent"
      copied = range.upperBound
    }
    text += cleaned[copied...]
    guard text.count > 2 * modelCharacterLimit else { return text }
    // Requests usually sit at the start or the end ("…summarize this").
    return "\(text.prefix(modelCharacterLimit)) \(text.suffix(modelCharacterLimit))"
  }

  private static func expression(_ pattern: String) -> NSRegularExpression {
    // All patterns are fixed, tested source literals, never user-provided regexes.
    try! NSRegularExpression(pattern: pattern)
  }

  private static let whitespaceRun = expression(#"\p{White_Space}+"#)
  private static let whatsWithoutApostrophe = expression(#"\bwhats\b"#)
  // Digit-bounded rather than word-bounded, like the rules' year check, so "v2024" counts too.
  private static let fourDigitNumber = expression(#"(?<![0-9])[0-9]{4}(?![0-9])"#)
  private static let literalMaterial = expression(#"(?s)```.*?(?:```|$)|`[^`]*(?:`|$)|"[^"\n]*(?:"|$)|“[^”]*(?:”|$)"#)
}
