import AppKit
import Combine
import SwiftUI

/// The saved System / Paper / Ink choice. System follows the Mac. Every window
/// and sheet root applies it with `.enigmaTheme(_:)`, so a change shows
/// everywhere at once.
@MainActor
final class EnigmaAppearancePreference: ObservableObject {
  static let shared = EnigmaAppearancePreference()
  static let appearanceKey = "enigma.appearance"
  private let defaults: UserDefaults

  @Published var appearance: EnigmaAppearance {
    didSet { defaults.set(appearance.rawValue, forKey: Self.appearanceKey) }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    appearance = defaults.string(forKey: Self.appearanceKey).flatMap(EnigmaAppearance.init(rawValue:)) ?? .system
  }
}

extension EnigmaAppearance {
  /// The AppKit appearance an Enigma window is given: Aqua for Paper,
  /// Dark Aqua for Ink, and none for System, so the window follows the Mac.
  var windowAppearanceName: NSAppearance.Name? {
    switch self {
    case .system: nil
    case .paper: .aqua
    case .ink: .darkAqua
    }
  }

  var windowAppearance: NSAppearance? { windowAppearanceName.flatMap(NSAppearance.init(named:)) }

  /// The palette's `background` as a window color. It resolves against the
  /// window's own appearance, so under System it changes with the Mac.
  @MainActor static let windowBackground = NSColor(name: "EnigmaWindowBackground") { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? EnigmaPalette.ink.background.nsColor : EnigmaPalette.paper.background.nsColor
  }
}
