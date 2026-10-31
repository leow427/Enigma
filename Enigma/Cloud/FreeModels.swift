import Foundation

/// The free cloud models (F34): Gemini's free tier on the user's own key and Apple's model on
/// Private Cloud Compute, ranked by capability.
enum FreeModelCatalog {
  static let applePCC = "apple-pcc"

  /// Most capable first. The Gemini entries follow Google's free tier; recheck with each
  /// catalogue update (Task 7 of the F34 plan checks them live).
  static let ranked = ["gemini-3.8-flash", applePCC, "gemini-3.6-flash", "gemini-3.5-flash-lite"]

  /// Whether Settings and welcome setup mention Apple's model, including the macOS 26 upgrade line.
  /// Off until the Private Cloud Compute entitlement is granted and the client ships.
  static let showsApple = false

  private static let displayNames = [
    "gemini-3.8-flash": "Gemini 3.8 Flash", applePCC: "Apple's cloud model",
    "gemini-3.6-flash": "Gemini 3.6 Flash", "gemini-3.5-flash-lite": "Gemini 3.5 Flash-Lite",
  ]

  static func displayName(_ modelID: String) -> String { displayNames[modelID] ?? modelID }

  static func available(hasGeminiKey: Bool, appleAvailable: Bool) -> [CloudModel] {
    ranked.filter { $0 == applePCC ? appleAvailable : hasGeminiKey }
      .map { CloudModel(id: $0, displayName: displayName($0), provider: .free) }
  }

  /// The provider that answers for a free model ID or its display name: Gemini, or nil for Apple's model.
  static func underlyingProvider(_ model: String) -> CloudProviderID? {
    model == applePCC || model == displayName(applePCC) ? nil : .gemini
  }
}

/// When each free model that ran out comes back. Kept in memory only: a relaunch tries again.
final class FreeModelUsage: @unchecked Sendable {
  static let shared = FreeModelUsage()

  private let lock = NSLock()
  private var resets: [String: Date] = [:]

  /// With no reset time from the provider, the model is skipped for an hour.
  func markExhausted(_ modelID: String, until: Date?, now: Date = Date()) {
    lock.withLock { resets[modelID] = until ?? now.addingTimeInterval(3_600) }
  }

  func isExhausted(_ modelID: String, now: Date) -> Bool {
    lock.withLock { resets[modelID].map { $0 > now } ?? false }
  }

  func resetTime(_ modelID: String) -> Date? {
    lock.withLock { resets[modelID] }
  }

  /// The earliest reset among `modelIDs`, when every one of them is out at `now`.
  func earliestReset(among modelIDs: [String], now: Date) -> Date? {
    guard !modelIDs.isEmpty, modelIDs.allSatisfy({ isExhausted($0, now: now) }) else { return nil }
    return modelIDs.compactMap(resetTime).min()
  }
}
