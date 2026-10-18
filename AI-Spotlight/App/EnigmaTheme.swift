import AppKit
import SwiftUI

// Color, type, and motion tokens for the UI revamp.
// The spec and the mockups they come from are in docs/design/ui-revamp/.

/// An sRGB color kept as plain numbers so palettes can be compared and tested.
struct EnigmaColor: Equatable, Sendable {
  let red: Double
  let green: Double
  let blue: Double
  let opacity: Double

  init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
    self.red = red
    self.green = green
    self.blue = blue
    self.opacity = opacity
  }

  /// `hex` is `0xRRGGBB`.
  init(hex: UInt32, opacity: Double = 1) {
    self.init(
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255,
      opacity: opacity
    )
  }

  var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity) }
  var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: opacity) }

  /// This color laid over an opaque background.
  func composited(over background: EnigmaColor) -> EnigmaColor {
    EnigmaColor(
      red: red * opacity + background.red * (1 - opacity),
      green: green * opacity + background.green * (1 - opacity),
      blue: blue * opacity + background.blue * (1 - opacity)
    )
  }

  /// WCAG relative luminance of the opaque color.
  var relativeLuminance: Double {
    func linear(_ channel: Double) -> Double {
      channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
  }

  /// WCAG contrast ratio, from 1 to 21. Translucent colors are first composited
  /// over `background`.
  func contrastRatio(on background: EnigmaColor) -> Double {
    let foreground = composited(over: background).relativeLuminance
    let back = background.relativeLuminance
    return (max(foreground, back) + 0.05) / (min(foreground, back) + 0.05)
  }
}

struct EnigmaPalette: Equatable, Sendable {
  let background: EnigmaColor
  let sidebar: EnigmaColor
  let surface: EnigmaColor
  let menu: EnigmaColor
  let userBubble: EnigmaColor
  let textPrimary: EnigmaColor
  let textSecondary: EnigmaColor
  let textTertiary: EnigmaColor
  let hairline: EnigmaColor
  let border: EnigmaColor
  let hover: EnigmaColor
  let accent: EnigmaColor
  let onAccent: EnigmaColor
  let accentText: EnigmaColor
  let characterBody: EnigmaColor
  let characterInk: EnigmaColor
  let warning: EnigmaColor

  static let paper = EnigmaPalette(
    background: EnigmaColor(hex: 0xF3EEE4),
    sidebar: EnigmaColor(hex: 0xE8E1D3),
    surface: EnigmaColor(hex: 0xFCFAF5),
    menu: EnigmaColor(hex: 0xFFFFFF),
    userBubble: EnigmaColor(hex: 0xE6DFD0),
    textPrimary: EnigmaColor(hex: 0x211E19),
    textSecondary: EnigmaColor(hex: 0x5B554A),
    textTertiary: EnigmaColor(hex: 0x827B6D),
    hairline: EnigmaColor(hex: 0x24201A, opacity: 0.10),
    border: EnigmaColor(hex: 0x24201A, opacity: 0.18),
    hover: EnigmaColor(hex: 0x24201A, opacity: 0.05),
    accent: EnigmaColor(hex: 0x3F5A12),
    onAccent: EnigmaColor(hex: 0xF5F8EA),
    accentText: EnigmaColor(hex: 0x4A6A14),
    characterBody: EnigmaColor(hex: 0xC3DE5E),
    characterInk: EnigmaColor(hex: 0x211E19),
    warning: EnigmaColor(hex: 0xE0A33B)
  )

  static let ink = EnigmaPalette(
    background: EnigmaColor(hex: 0x141512),
    sidebar: EnigmaColor(hex: 0x0E0F0D),
    surface: EnigmaColor(hex: 0x1E1F1B),
    menu: EnigmaColor(hex: 0x282923),
    userBubble: EnigmaColor(hex: 0x262721),
    textPrimary: EnigmaColor(hex: 0xEFE8D8),
    textSecondary: EnigmaColor(hex: 0xABA496),
    textTertiary: EnigmaColor(hex: 0x827D70),
    hairline: EnigmaColor(hex: 0xEDE6D6, opacity: 0.08),
    border: EnigmaColor(hex: 0xEDE6D6, opacity: 0.15),
    hover: EnigmaColor(hex: 0xEDE6D6, opacity: 0.05),
    accent: EnigmaColor(hex: 0xCDEB78),
    onAccent: EnigmaColor(hex: 0x1A2306),
    accentText: EnigmaColor(hex: 0xCDEB78),
    characterBody: EnigmaColor(hex: 0xCDEB78),
    characterInk: EnigmaColor(hex: 0xEFE8D8),
    warning: EnigmaColor(hex: 0xE0A33B)
  )
}

enum EnigmaAppearance: String, CaseIterable, Identifiable, Sendable {
  case system
  case paper
  case ink

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system: "System"
    case .paper: "Paper"
    case .ink: "Ink"
    }
  }

  /// The scheme to force on the window, or nil to follow the Mac.
  var colorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .paper: .light
    case .ink: .dark
    }
  }

  func palette(for systemScheme: ColorScheme) -> EnigmaPalette {
    switch colorScheme ?? systemScheme {
    case .dark: .ink
    default: .paper
    }
  }
}

enum EnigmaTypography {
  /// Chrome, labels, and headings use the system font.
  static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight)
  }

  /// Only assistant replies are set in the serif.
  static let reply = Font.system(size: 15, design: .serif)

  /// The reply serif at another size or weight, for headings and tables inside a reply.
  static func reply(size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .serif)
  }

  /// Commands, metadata, hints, and stats.
  static func mono(_ size: CGFloat = 11.5, weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .monospaced)
  }

  // MARK: SF Symbols

  /// An SF Symbol, always at `.regular`: the weight whose line matches the
  /// tool icons' 1.75 stroke on a 24 pt grid, so glyphs from every screen
  /// draw one line.
  static func symbol(_ size: CGFloat) -> Font { .system(size: size, weight: .regular) }

  /// A glyph in a 30 × 28 icon button, like Attach or the sidebar toggle.
  static let iconButtonSymbol = symbol(15)
  /// A glyph in a 24 × 22 icon button, like Remove on a card or the compact
  /// panel's status button.
  static let smallIconButtonSymbol = symbol(12)
  /// A navigation row's glyph, in the sidebar and in Settings.
  static let navigationSymbol = symbol(14)
  /// A disclosure chevron beside text. A regular chevron thins to a hairline
  /// at 9 pt, so this one is semibold, which draws about the same line as
  /// the regular glyphs around it.
  static let disclosureSymbol = Font.system(size: 9, weight: .semibold)
}

/// A spring in Apple's response and damping terms, matching the mockups.
struct EnigmaSpring: Equatable, Sendable {
  let response: Double
  let dampingFraction: Double

  var animation: Animation { .spring(response: response, dampingFraction: dampingFraction) }
}

enum EnigmaMotion {
  static let screenChange = EnigmaSpring(response: 0.5, dampingFraction: 1)
  static let composerDock = EnigmaSpring(response: 0.5, dampingFraction: 0.86)
  static let menu = EnigmaSpring(response: 0.28, dampingFraction: 1)
  static let pageChange = EnigmaSpring(response: 0.3, dampingFraction: 1)
  static let rowEnter = EnigmaSpring(response: 0.42, dampingFraction: 0.9)
  static let panelAnswer = EnigmaSpring(response: 0.45, dampingFraction: 0.9)
  static let switchKnob = EnigmaSpring(response: 0.32, dampingFraction: 0.62)
  static let characterFollow = EnigmaSpring(response: 0.5, dampingFraction: 0.8)
  static let characterSquash = EnigmaSpring(response: 0.34, dampingFraction: 0.32)

  /// The character's fall, in points per second squared.
  static let characterGravity: Double = 2600
}

extension EnvironmentValues {
  /// The palette new views draw with. Set it at the window root with `.enigmaTheme(_:)`.
  @Entry var enigmaPalette: EnigmaPalette = .paper
  /// The appearance the palette came from, so a sheet can apply the same one.
  @Entry var enigmaAppearance: EnigmaAppearance = .system
}

extension View {
  /// Applies an appearance to a window's content: the palette, and the matching
  /// color scheme so native text and menus agree with it.
  func enigmaTheme(_ appearance: EnigmaAppearance) -> some View {
    modifier(EnigmaThemeModifier(appearance: appearance))
  }
}

private struct EnigmaThemeModifier: ViewModifier {
  let appearance: EnigmaAppearance
  @Environment(\.colorScheme) private var systemScheme

  func body(content: Content) -> some View {
    let scheme = appearance.colorScheme ?? systemScheme
    content
      .environment(\.enigmaPalette, appearance.palette(for: scheme))
      .environment(\.enigmaAppearance, appearance)
      .environment(\.colorScheme, scheme)
      .preferredColorScheme(appearance.colorScheme)
  }
}

// MARK: New screens inside old windows

/// The Mac's own light or dark setting. Unlike a view's `colorScheme`, it
/// ignores a scheme that a window forces, such as the old UI's dark mode.
@MainActor
final class EnigmaSystemAppearance: ObservableObject {
  static let shared = EnigmaSystemAppearance()

  @Published private(set) var colorScheme: ColorScheme
  private var observation: NSKeyValueObservation?

  /// Follows the app's effective appearance, which windows don't change.
  init(application: NSApplication = .shared) {
    colorScheme = Self.scheme(of: application.effectiveAppearance)
    observation = application.observe(\.effectiveAppearance) { [weak self] _, _ in
      Task { @MainActor in
        guard let self else { return }
        let scheme = Self.scheme(of: application.effectiveAppearance)
        if scheme != self.colorScheme { self.colorScheme = scheme }
      }
    }
  }

  /// A fixed setting, for tests and previews.
  init(colorScheme: ColorScheme) {
    self.colorScheme = colorScheme
  }

  static func scheme(of appearance: NSAppearance) -> ColorScheme {
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
  }
}

extension View {
  /// Applies an appearance to a new screen shown inside a window that the old
  /// UI still owns. System follows the Mac's own setting rather than the
  /// window's forced dark scheme, and the window's scheme is left alone, so the
  /// old screens around it don't change.
  func enigmaEmbeddedTheme(_ appearance: EnigmaAppearance,
                           system: EnigmaSystemAppearance = .shared) -> some View {
    modifier(EnigmaEmbeddedThemeModifier(appearance: appearance, system: system))
  }
}

private struct EnigmaEmbeddedThemeModifier: ViewModifier {
  let appearance: EnigmaAppearance
  @ObservedObject var system: EnigmaSystemAppearance

  func body(content: Content) -> some View {
    let scheme = appearance.colorScheme ?? system.colorScheme
    content
      .environment(\.enigmaPalette, appearance.palette(for: scheme))
      .environment(\.enigmaAppearance, appearance)
      .environment(\.colorScheme, scheme)
  }
}
