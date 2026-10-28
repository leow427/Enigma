import Foundation

/// Fixed overrides that force a skill's answer for wording a model gets wrong.
/// One is added only when a must-pass example fails and more training examples
/// don't fix it; more than `maximumPerSkill` means the examples need work.
struct IntentPins: Sendable {
  static let maximumPerSkill = 20

  /// The app's pins; empty until a must-pass example needs one.
  static let shipped = IntentPins([:])

  private let table: [IntentSkill: [Pin]]

  /// Patterns are fixed source literals, matched against cleaned text, in order.
  init(_ table: [IntentSkill: [(pattern: String, label: String)]]) {
    self.table = table.mapValues { pins in
      pins.map { pin in
        // All patterns are fixed, tested source literals, never user-provided regexes.
        Pin(expression: try! NSRegularExpression(pattern: pin.pattern), label: pin.label)
      }
    }
    for (skill, pins) in self.table {
      precondition(pins.allSatisfy { skill.labels.contains($0.label) }, "A \(skill) pin has an unknown label")
    }
  }

  /// The first matching pin's label, or nil when none matches.
  func answer(_ skill: IntentSkill, cleaned: String) -> String? {
    let range = NSRange(cleaned.startIndex..., in: cleaned)
    return table[skill]?.first { $0.expression.firstMatch(in: cleaned, range: range) != nil }?.label
  }

  func count(_ skill: IntentSkill) -> Int {
    table[skill]?.count ?? 0
  }

  private struct Pin: @unchecked Sendable {
    // NSRegularExpression is immutable once made, so sharing it across threads is safe.
    let expression: NSRegularExpression
    let label: String
  }
}
