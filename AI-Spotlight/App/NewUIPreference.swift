import Combine
import Foundation

/// Turns on the revamped interface while it is being built screen by screen.
/// Off by default, so the current UI ships until the new one reaches parity.
@MainActor
final class NewUIPreference: ObservableObject {
  static let shared = NewUIPreference()
  static let isEnabledKey = "enigma.newUI.isEnabled"
  private let defaults: UserDefaults

  @Published var isEnabled: Bool {
    didSet { defaults.set(isEnabled, forKey: Self.isEnabledKey) }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    isEnabled = defaults.object(forKey: Self.isEnabledKey) as? Bool ?? false
  }
}
