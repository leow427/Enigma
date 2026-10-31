import Foundation

/// The chat's loaded local model, for the search's two short helper calls on the small-model path:
/// the query rewrite and the "enough?" check (D104, D107, D108). Never loads a model of its own.
protocol SearchModelAssistant: Sendable {
  /// The model's whole reply to one user message, at temperature 0, within `maximumTokens`.
  func complete(_ prompt: String, maximumTokens: Int) async throws -> String
}

/// The helper calls' limits, for the evaluation to measure and change (D107, D108).
enum SearchAssistTuning {
  static let rewriteTokens = 64
  static let rewriteTimeout: Duration = .milliseconds(2_500)
  /// Queries the model may write; at most `maximumSiteQueries` of them go to DuckDuckGo.
  static let maximumQueries = 3
  static let maximumSiteQueries = 2
  static let maximumQueryWords = 10
  static let maximumQueryCharacters = 80
  static let checkTokens = 24
  static let checkTimeout: Duration = .milliseconds(2_500)
  /// Words of passages the check sees, best passages first.
  static let checkWords = 350
  static let maximumMissingWords = 6
  /// The retry's own reading window.
  static let retryReadingWindow: Duration = .milliseconds(1_500)
}

/// What the search sends: one to `maximumSiteQueries` keyword queries, and the entity Wikidata
/// looks up when the model named one.
struct SearchQueryPlan: Equatable, Sendable {
  var queries: [String]
  var entity: String?
  /// "model", "fallback", "timeout", "junk", "failed" or "asWritten", for the trace.
  var outcome: String
}

/// The typed question as keyword queries (D107): the local model's, or a code-only clean-up.
enum SearchQueryRewrite {
  static func prompt(question: String, today: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return """
      Turn the question into web search keywords. Today is \(formatter.string(from: today)).
      Write 1 to 3 lines that start with "query:", each a short keyword query of 2 to 6 words, \
      with no question words, in the question's language. Most questions need one query; add a \
      second or third only when the answer could take a different form. Then write one line "entity:" with the main person, \
      place, organization, product or prize the question is about, named as Wikipedia titles it, \
      or "entity: none". Write nothing else.

      Question: which Python release came out most recently?
      query: python newest release
      entity: Python (programming language)

      Question: Who won the Nobel Prize in Literature this year?
      query: nobel prize literature winner
      entity: Nobel Prize in Literature

      Question: how far away is Mars right now
      query: mars distance from earth today
      query: mars earth average distance km
      entity: Mars

      Question: ideas for a rainy weekend with small kids
      query: rainy weekend activities kids
      entity: none

      Question: \(question)
      """
  }

  /// The model's queries and entity, or nil when the reply isn't in the format (junk).
  static func parse(_ output: String) -> (queries: [String], entity: String?)? {
    var queries: [String] = []
    var entity: String?
    var seen = Set<String>()
    for rawLine in stripThinking(output).split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
        .trimmingCharacters(in: CharacterSet(charactersIn: "-*•`"))
        .trimmingCharacters(in: .whitespaces)
      guard let colon = line.firstIndex(of: ":") else { continue }
      let label = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        .trimmingCharacters(in: .whitespaces)
      switch label {
      case "query":
        guard let query = validQuery(value), seen.insert(query.lowercased()).inserted,
              queries.count < SearchAssistTuning.maximumQueries else { continue }
        queries.append(query)
      case "entity":
        let name = value.trimmingCharacters(in: CharacterSet(charactersIn: ".")).trimmingCharacters(in: .whitespaces)
        if entity == nil, !name.isEmpty, name.lowercased() != "none", name.count <= 80,
           name.split(whereSeparator: \.isWhitespace).count <= 8, !looksLikeURL(name) {
          entity = name
        }
      default:
        continue
      }
    }
    return queries.isEmpty ? nil : (queries, entity)
  }

  private static func validQuery(_ value: String) -> String? {
    let words = value.split(whereSeparator: \.isWhitespace)
    let query = words.joined(separator: " ")
    guard !words.isEmpty, words.count <= SearchAssistTuning.maximumQueryWords,
          query.count <= SearchAssistTuning.maximumQueryCharacters, !looksLikeURL(query),
          query.rangeOfCharacter(from: .controlCharacters) == nil,
          query.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
    return query
  }

  /// A URL, a `www.` name or a word ending in a common top-level domain ("example.com"); not
  /// version numbers or names such as "3.12" or "node.js" (D126).
  static func looksLikeURL(_ text: String) -> Bool {
    let lowered = text.lowercased()
    if lowered.contains("://") { return true }
    return lowered.split(whereSeparator: \.isWhitespace).contains { word in
      word.hasPrefix("www.") || word.firstMatch(of: domainEnding) != nil
    }
  }

  nonisolated(unsafe) private static let domainEnding =
    /[a-z0-9-]\.(?:com|org|net|edu|gov|io|co|uk|de|fr|info|biz|ai|app|dev|me|tv|ly|us|ca|au)(?:\/|[.,;:!?)]*$)/

  /// A reasoning model's `<think>…</think>` block, if any, removed.
  static func stripThinking(_ output: String) -> String {
    guard let end = output.range(of: "</think>") else { return output }
    return String(output[end.upperBound...])
  }

  // MARK: The code-only clean-up

  /// English question words, auxiliaries, pronouns, politeness and filler. Entities, numbers,
  /// years and qualifiers ("latest", "current", "best") stay.
  static let dropped: Set<String> = [
    "what", "what's", "whats", "which", "who", "who's", "whom", "whose", "when", "when's", "where", "where's",
    "why", "how", "how's", "is", "are", "was", "were", "be", "been", "being", "am", "do", "does", "did",
    "can", "could", "would", "should", "will", "shall", "may", "might", "must", "please", "pls", "kindly",
    "tell", "me", "us", "i", "i'm", "im", "you", "your", "my", "we", "our", "a", "an", "the", "of", "to",
    "about", "there", "it", "it's", "its", "that", "this", "these", "those", "any", "some", "know", "find",
    "out", "give", "show", "explain", "describe", "let", "hey", "hi", "thanks", "thank", "actually", "exactly",
    "really", "just", "so", "currently", "right", "anyone", "someone", "has", "have", "had", "and",
  ]

  /// A stop-word goes when lowercase, and when capitalized only as the first word, so names stay
  /// ("Theresa May", "The Who"); "Will" or "May" before a capitalized word is a name ("Will
  /// Smith"); "I" stays after a capitalized word ("World War I"); "how to" stays (D126).
  private static func keeps(_ words: [String], at index: Int) -> Bool {
    let word = words[index], lowered = word.lowercased()
    guard dropped.contains(lowered) else { return true }
    if lowered == "how", index + 1 < words.count, words[index + 1].lowercased() == "to" { return true }
    if lowered == "to", index > 0, words[index - 1].lowercased() == "how" { return true }
    let capitalized = word.first?.isUppercase == true
    let nextCapitalized = index + 1 < words.count && words[index + 1].first?.isUppercase == true
    // "World War I", not "Can I": the word before is a kept capitalized word.
    if word == "I" { return index > 0 && words[index - 1].first?.isUppercase == true && keeps(words, at: index - 1) }
    guard capitalized else { return false }
    if index == 0 { return ["will", "may"].contains(lowered) && nextCapitalized }
    return true
  }

  /// The typed question with its question words, filler and punctuation dropped (D107).
  /// Falls back to the question itself when nothing would be left.
  static func keywords(_ question: String) -> String {
    let edgePunctuation = CharacterSet.punctuationCharacters.union(.symbols)
      .subtracting(CharacterSet(charactersIn: "+#$%€£"))
    let words = question.replacingOccurrences(of: "’", with: "'")
      .split(whereSeparator: { $0.isWhitespace })
      .map { $0.trimmingCharacters(in: edgePunctuation) }
      .filter { !$0.isEmpty }
    let kept = words.indices.filter { keeps(words, at: $0) }.map { words[$0] }
    let text = (kept.isEmpty ? words : kept).joined(separator: " ")
    return text.isEmpty ? question : text
  }
}

/// The "enough?" check (D108): do the picked passages answer the question?
enum SearchSufficiencyCheck {
  enum Verdict: Equatable, Sendable {
    case enough
    /// The words to add to the first query for the one retry.
    case missing(String)
  }

  static func prompt(question: String, sources: [(title: String, text: String)]) -> String {
    var budget = SearchAssistTuning.checkWords
    var lines: [String] = []
    for (index, source) in sources.enumerated() where budget > 0 {
      let words = source.text.split(whereSeparator: \.isWhitespace)
      let taken = words.prefix(budget)
      budget -= taken.count
      lines.append("[\(index + 1)] \(source.title): \(taken.joined(separator: " "))")
    }
    return """
      Question: \(question)

      Sources:
      \(lines.joined(separator: "\n"))

      Do these sources contain the answer to the question? Reply with exactly one line: "yes" \
      if they do, or "no: " followed by 2 to 5 search words for the missing fact if they don't.
      """
  }

  /// nil for junk, which never retries.
  static func parse(_ output: String) -> Verdict? {
    let text = SearchQueryRewrite.stripThinking(output).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = text.split(whereSeparator: \.isNewline).first else { return nil }
    let line = first.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*"))
    let lowered = line.lowercased()
    if lowered == "yes" || lowered.hasPrefix("yes.") || lowered.hasPrefix("yes,") || lowered.hasPrefix("yes ") {
      return .enough
    }
    guard lowered.hasPrefix("no") else { return nil }
    var rest = line.dropFirst(2)
    guard rest.isEmpty || rest.first == ":" || rest.first == "," || rest.first == "." || rest.first == " " else { return nil }
    rest = rest.drop(while: { $0 == ":" || $0 == "," || $0 == "." || $0 == " " || $0 == "-" })
    let words = SearchQueryRewrite.keywords(String(rest)).split(whereSeparator: \.isWhitespace)
    guard !words.isEmpty, words.count <= SearchAssistTuning.maximumMissingWords,
          !SearchQueryRewrite.looksLikeURL(String(rest)) else { return nil }
    return .missing(words.joined(separator: " "))
  }
}

/// Runs one helper call within its time limit; nil on a timeout or a failure.
enum SearchAssistCall {
  enum Outcome<T: Sendable>: Sendable {
    case value(T)
    case timeout
    case failed
  }

  static func run(_ assistant: any SearchModelAssistant, prompt: String, maximumTokens: Int, timeout: Duration,
                  clock: any Clock<Duration>) async -> Outcome<String> {
    await withTaskGroup(of: Outcome<String>?.self) { group in
      group.addTask {
        do { return .value(try await assistant.complete(prompt, maximumTokens: maximumTokens)) } catch { return .failed }
      }
      group.addTask {
        do { try await clock.sleep(for: timeout) } catch { return nil }
        return .timeout
      }
      var result: Outcome<String> = .failed
      while let next = await group.next() {
        if let next { result = next; break }
      }
      group.cancelAll()
      return result
    }
  }
}
