import CryptoKit
import Foundation
#if canImport(Enigma)
@testable import Enigma
#endif

// Shared by EnigmaTests and scripts/train-intent-models.sh, which compiles this file
// with IntentText.swift and IntentSkill.swift. Foundation and CryptoKit only.

struct IntentExample: Codable, Equatable, Sendable {
  var text: String
  var label: String
  var nearMiss: Bool? = nil
  /// Must-pass only: why it must pass.
  var why: String? = nil
}

struct IntentExampleFileError: Error, CustomStringConvertible, LocalizedError {
  let line: Int
  let reason: String
  var description: String { "line \(line): \(reason)" }
  var errorDescription: String? { description }
}

struct IntentExampleFile: Equatable, Sendable {
  /// First line: {"asOf": "YYYY-MM-DD"}, read as noon UTC that day.
  var asOf: Date
  /// One JSON object per following line.
  var examples: [IntentExample]

  /// Throws an error naming the 1-based line on bad JSON, a missing `asOf`
  /// line, a label not in `skill.labels`, or a typed `/think`. Blank lines are skipped.
  static func parse(_ data: Data, skill: IntentSkill) throws -> IntentExampleFile {
    guard let text = String(data: data, encoding: .utf8) else {
      throw IntentExampleFileError(line: 1, reason: "not UTF-8")
    }
    var asOf: Date?
    var examples: [IntentExample] = []
    let decoder = JSONDecoder()
    // Only \n (or \r\n) ends a line: JSON strings may hold a raw U+2028 or U+0085.
    // "\r\n" is one Character in Swift, so split the scalars, not the characters.
    for (index, scalars) in text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
      let number = index + 1
      var line = String(String.UnicodeScalarView(scalars))
      if line.hasSuffix("\r") { line.removeLast() }
      guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
      let lineData = Data(line.utf8)
      if asOf == nil {
        guard let header = try? decoder.decode(AsOfLine.self, from: lineData), let date = Self.date(header.asOf) else {
          throw IntentExampleFileError(line: number, reason: #"expected {"asOf": "YYYY-MM-DD"}"#)
        }
        asOf = date
        continue
      }
      let example: IntentExample
      do {
        example = try decoder.decode(IntentExample.self, from: lineData)
      } catch {
        throw IntentExampleFileError(line: number, reason: "bad example JSON")
      }
      guard skill.labels.contains(example.label) else {
        throw IntentExampleFileError(line: number, reason: "label \"\(example.label)\" is not one of \(skill.labels)")
      }
      guard typedThink.firstMatch(in: example.text, range: NSRange(example.text.startIndex..., in: example.text)) == nil else {
        throw IntentExampleFileError(line: number, reason: "remove the typed /think; the app removes it before the model reads the draft")
      }
      examples.append(example)
    }
    guard let asOf else { throw IntentExampleFileError(line: 1, reason: #"expected {"asOf": "YYYY-MM-DD"}"#) }
    return IntentExampleFile(asOf: asOf, examples: examples)
  }

  private struct AsOfLine: Decodable { let asOf: String }

  /// A typed `/think`, matched as `SlashCommand` tokens are (quoted ones included, to be safe).
  private static let typedThink = try! NSRegularExpression(pattern: #"(?i)(?<!\S)/think(?=$|\s|[.,!?;:])"#)

  private static func date(_ day: String) -> Date? {
    let parts = day.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3, day.count == 10 else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let components = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)
    guard components.isValidDate(in: calendar) else { return nil }
    return calendar.date(from: components)
  }
}

struct IntentScore: Codable, Equatable, Sendable {
  var total: Int
  var correct: Int
  /// Answers other than the negative label.
  var yesCount: Int
  /// Yes answers that don't equal the expected label.
  var wrongYes: Int

  var accuracy: Double { total == 0 ? 0 : Double(correct) / Double(total) }
  var wrongYesShare: Double { yesCount == 0 ? 0 : Double(wrongYes) / Double(yesCount) }

  init(answers: [(expected: String, actual: String)], negativeLabel: String) {
    total = answers.count
    correct = answers.filter { $0.expected == $0.actual }.count
    let yeses = answers.filter { $0.actual != negativeLabel }
    yesCount = yeses.count
    wrongYes = yeses.filter { $0.expected != $0.actual }.count
  }
}

enum IntentTrainingSupport {
  /// 0.05...0.95 in steps of 0.01, computed from integers so each is the nearest Double.
  static let cutoffCandidates: [Double] = (5...95).map { Double($0) / 100 }

  /// About 20% of examples, chosen by text so the split never changes between runs:
  /// SHA-256 of `IntentText.clean(text)`, first byte divisible by 5.
  static func isValidation(_ text: String) -> Bool {
    let firstByte = Array(SHA256.hash(data: Data(IntentText.clean(text).utf8)))[0]
    return firstByte % 5 == 0
  }

  /// Lean none: highest accuracy, ties to the candidate nearest 0.5.
  /// Lean off: most correct yeses with wrongYesShare ≤ 0.02, ties to the
  /// higher cut-off; nil when no candidate qualifies. A cut-off that says yes
  /// to nothing doesn't qualify.
  static func chooseCutoff(for skill: IntentSkill,
                           validation: [(expected: String, probabilities: [String: Double])]) -> Double? {
    let scored = cutoffCandidates.map { cutoff -> CutoffScore in
      let answers: [(expected: String, actual: String)] = validation.map {
        (expected: $0.expected, actual: skill.answer(probabilities: $0.probabilities, cutoff: cutoff))
      }
      let correctYes = answers.filter { $0.actual != skill.negativeLabel && $0.actual == $0.expected }.count
      return CutoffScore(cutoff: cutoff, score: IntentScore(answers: answers, negativeLabel: skill.negativeLabel),
                         correctYes: correctYes)
    }
    switch skill.lean {
    case .none:
      // Candidates are ascending, so on equal accuracy and distance the lower one wins.
      return scored.min { a, b in
        if a.score.correct != b.score.correct { return a.score.correct > b.score.correct }
        return abs(a.cutoff - 0.5) < abs(b.cutoff - 0.5)
      }?.cutoff
    case .off:
      let qualifying = scored.filter {
        $0.correctYes > 0 && $0.score.wrongYesShare <= IntentSkill.maximumWrongYesShare
      }
      return qualifying.max { a, b in
        a.correctYes != b.correctYes ? a.correctYes < b.correctYes : a.cutoff < b.cutoff
      }?.cutoff
    }
  }

  private struct CutoffScore {
    let cutoff: Double
    let score: IntentScore
    let correctYes: Int
  }

  /// Cleaned texts that appear in both lists.
  static func overlaps(_ first: [IntentExample], _ second: [IntentExample]) -> [String] {
    let cleaned = Set(first.map { IntentText.clean($0.text) })
    return Set(second.map { IntentText.clean($0.text) }).intersection(cleaned).sorted()
  }

  /// Lowercase hex SHA-256.
  static func fingerprint(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
