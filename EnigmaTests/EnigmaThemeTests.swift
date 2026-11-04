import SwiftUI
import XCTest
@testable import Enigma

final class EnigmaThemeTests: XCTestCase {
  private let palettes: [(String, EnigmaPalette)] = [("Paper", .paper), ("Ink", .ink)]

  func testHexColorsParseIntoSRGBComponents() {
    let color = EnigmaColor(hex: 0x3F5A12, opacity: 0.5)
    XCTAssertEqual(color.red, 63.0 / 255, accuracy: 0.0001)
    XCTAssertEqual(color.green, 90.0 / 255, accuracy: 0.0001)
    XCTAssertEqual(color.blue, 18.0 / 255, accuracy: 0.0001)
    XCTAssertEqual(color.opacity, 0.5)
  }

  func testPalettesMatchTheRevampSpecTable() {
    // Mirrors the color table in docs/design/ui-revamp/README.md and UI-Style.md.
    let expected: [(KeyPath<EnigmaPalette, EnigmaColor>, paper: EnigmaColor, ink: EnigmaColor)] = [
      (\.background, EnigmaColor(hex: 0xF3EEE4), EnigmaColor(hex: 0x121411)),
      (\.sidebar, EnigmaColor(hex: 0xE8E1D3), EnigmaColor(hex: 0x0D0F0C)),
      (\.surface, EnigmaColor(hex: 0xFCFAF5), EnigmaColor(hex: 0x1A1D19)),
      (\.menu, EnigmaColor(hex: 0xFFFFFF), EnigmaColor(hex: 0x232721)),
      (\.userBubble, EnigmaColor(hex: 0xE6DFD0), EnigmaColor(hex: 0x21251F)),
      (\.textPrimary, EnigmaColor(hex: 0x211E19), EnigmaColor(hex: 0xC8CCBF)),
      (\.textSecondary, EnigmaColor(hex: 0x5B554A), EnigmaColor(hex: 0x959B8D)),
      (\.textTertiary, EnigmaColor(hex: 0x827B6D), EnigmaColor(hex: 0x737968)),
      (\.hairline, EnigmaColor(hex: 0x24201A, opacity: 0.10), EnigmaColor(hex: 0xC8CCBF, opacity: 0.08)),
      (\.border, EnigmaColor(hex: 0x24201A, opacity: 0.18), EnigmaColor(hex: 0xC8CCBF, opacity: 0.15)),
      (\.hover, EnigmaColor(hex: 0x24201A, opacity: 0.05), EnigmaColor(hex: 0xC8CCBF, opacity: 0.05)),
      (\.accent, EnigmaColor(hex: 0x3F5A12), EnigmaColor(hex: 0x7E9C6B)),
      (\.onAccent, EnigmaColor(hex: 0xF5F8EA), EnigmaColor(hex: 0x0F160B)),
      (\.accentText, EnigmaColor(hex: 0x4A6A14), EnigmaColor(hex: 0x9CB687)),
      (\.characterBody, EnigmaColor(hex: 0xC3DE5E), EnigmaColor(hex: 0x8FAA6A)),
      (\.characterInk, EnigmaColor(hex: 0x211E19), EnigmaColor(hex: 0xBFC3B3)),
      (\.warning, EnigmaColor(hex: 0xE0A33B), EnigmaColor(hex: 0xE0A33B)),
      (\.contextHigh, EnigmaColor(hex: 0xB8800F), EnigmaColor(hex: 0xE0A33B)),
      (\.contextFull, EnigmaColor(hex: 0xB3261E), EnigmaColor(hex: 0xE06C5F)),
      (\.contextTrack, EnigmaColor(hex: 0x24201A, opacity: 0.14), EnigmaColor(hex: 0xC8CCBF, opacity: 0.16)),
      (\.codeKeyword, EnigmaColor(hex: 0x8A3B6E), EnigmaColor(hex: 0xC09AB6)),
      (\.codeString, EnigmaColor(hex: 0x3F6B1A), EnigmaColor(hex: 0xA7BF86)),
      (\.codeNumber, EnigmaColor(hex: 0xA04A12), EnigmaColor(hex: 0xD2A57E)),
      (\.codeComment, EnigmaColor(hex: 0x6E685C), EnigmaColor(hex: 0x828879)),
      (\.codeType, EnigmaColor(hex: 0x1D6375), EnigmaColor(hex: 0x88B8AE)),
      (\.codeVariable, EnigmaColor(hex: 0x3A4FA0), EnigmaColor(hex: 0xA6B0D6)),
    ]
    XCTAssertEqual(expected.count, 26)
    for (token, paper, ink) in expected {
      XCTAssertEqual(EnigmaPalette.paper[keyPath: token], paper, "\(token)")
      XCTAssertEqual(EnigmaPalette.ink[keyPath: token], ink, "\(token)")
    }
  }

  func testContrastRatioMatchesWCAGExtremes() {
    let black = EnigmaColor(hex: 0x000000)
    let white = EnigmaColor(hex: 0xFFFFFF)
    XCTAssertEqual(black.contrastRatio(on: white), 21, accuracy: 0.01)
    XCTAssertEqual(white.contrastRatio(on: white), 1, accuracy: 0.01)
  }

  func testTextIsReadableOnEverySurfaceItAppearsOn() {
    for (name, palette) in palettes {
      for surface in [palette.background, palette.sidebar, palette.surface, palette.menu, palette.userBubble] {
        XCTAssertGreaterThanOrEqual(palette.textPrimary.contrastRatio(on: surface), 7, name)
      }
      for surface in [palette.background, palette.sidebar, palette.surface, palette.menu, palette.userBubble] {
        XCTAssertGreaterThanOrEqual(palette.textSecondary.contrastRatio(on: surface), 4.5, name)
        // Tertiary text is only for timestamps, hints, and placeholders.
        XCTAssertGreaterThanOrEqual(palette.textTertiary.contrastRatio(on: surface), 3, name)
      }
      for surface in [palette.background, palette.sidebar, palette.surface, palette.menu] {
        XCTAssertGreaterThanOrEqual(palette.accentText.contrastRatio(on: surface), 4.5, name)
      }
      XCTAssertGreaterThanOrEqual(palette.onAccent.contrastRatio(on: palette.accent), 4.5, name)
      // Code blocks sit on `surface`.
      for syntax in [palette.codeKeyword, palette.codeString, palette.codeNumber,
                     palette.codeComment, palette.codeType, palette.codeVariable] {
        XCTAssertGreaterThanOrEqual(syntax.contrastRatio(on: palette.surface), 4.5, name)
      }
    }
  }

  func testMenusAndSurfacesAreOpaque() {
    for (name, palette) in palettes {
      for color in [palette.background, palette.sidebar, palette.surface, palette.menu, palette.userBubble] {
        XCTAssertEqual(color.opacity, 1, name)
      }
    }
  }

  func testCharacterOutlineStandsOutOnEveryCanvas() {
    // The outline, legs, and antenna carry the silhouette; the body fill may be close to the page.
    for (name, palette) in palettes {
      for canvas in [palette.background, palette.surface] {
        XCTAssertGreaterThanOrEqual(palette.characterInk.contrastRatio(on: canvas), 3, name)
      }
    }
  }

  func testAppearanceFollowsTheMacOnlyInSystemMode() {
    XCTAssertEqual(EnigmaAppearance.system.palette(for: .light), .paper)
    XCTAssertEqual(EnigmaAppearance.system.palette(for: .dark), .ink)
    XCTAssertEqual(EnigmaAppearance.paper.palette(for: .dark), .paper)
    XCTAssertEqual(EnigmaAppearance.ink.palette(for: .light), .ink)
    XCTAssertNil(EnigmaAppearance.system.colorScheme)
    XCTAssertEqual(EnigmaAppearance.paper.colorScheme, .light)
    XCTAssertEqual(EnigmaAppearance.ink.colorScheme, .dark)
  }

  func testSpringsMatchTheirRoleInTheSpec() {
    let calm = [EnigmaMotion.screenChange, EnigmaMotion.menu, EnigmaMotion.pageChange]
    let settling = [EnigmaMotion.composerDock, EnigmaMotion.rowEnter]
    let physical = [EnigmaMotion.switchKnob, EnigmaMotion.characterFollow, EnigmaMotion.characterSquash]
    for spring in calm + settling + physical {
      XCTAssertGreaterThan(spring.response, 0)
    }
    for spring in calm {
      XCTAssertEqual(spring.dampingFraction, 1)
    }
    for spring in settling {
      XCTAssertGreaterThanOrEqual(spring.dampingFraction, 0.85)
      XCTAssertLessThan(spring.dampingFraction, 1)
    }
    for spring in physical {
      XCTAssertGreaterThan(spring.dampingFraction, 0)
      XCTAssertLessThan(spring.dampingFraction, 0.85)
    }
  }
}

/// The composer's context ring (F35 CP5).
final class ContextRingTests: XCTestCase {
  private func usage(_ fraction: Double) -> ContextUsage {
    ContextUsage(usedTokens: Int((fraction * 10_000).rounded()), limitTokens: 10_000)
  }

  func testRingLevelColours() {
    for palette in [EnigmaPalette.paper, .ink] {
      XCTAssertEqual(ContextRing.color(for: usage(0.699).level, palette: palette), palette.accent)
      XCTAssertEqual(ContextRing.color(for: usage(0.70).level, palette: palette), palette.contextHigh)
      XCTAssertEqual(ContextRing.color(for: usage(0.899).level, palette: palette), palette.contextHigh)
      XCTAssertEqual(ContextRing.color(for: usage(0.90).level, palette: palette), palette.contextFull)
    }
  }

  func testRingFillIsExactFraction() {
    XCTAssertEqual(ContextUsage(usedTokens: 1_234, limitTokens: 3_328).fraction, 1_234.0 / 3_328, accuracy: 1e-12)
  }

  func testNewTokensMeetContrast() {
    // Non-text graphics: 3:1 against the composer's surface.
    for (name, palette) in [("paper", EnigmaPalette.paper), ("ink", .ink)] {
      for color in [palette.accent, palette.contextHigh, palette.contextFull] {
        XCTAssertGreaterThanOrEqual(color.contrastRatio(on: palette.surface), 3, name)
      }
    }
  }

  func testRingHelpText() {
    XCTAssertEqual(ContextRing.help(ContextUsage(usedTokens: 714, limitTokens: 1_000)), "28% of context left")
    XCTAssertEqual(ContextRing.help(ContextUsage(usedTokens: 92, limitTokens: 100)),
                   "8% of context left. Earlier messages will be summarized.")
  }

  func testRingTokenLineFormatsThousands() {
    XCTAssertEqual(ContextRing.tokenLine(ContextUsage(usedTokens: 640, limitTokens: 8_192)), "640 of 8.2K tokens used")
    XCTAssertEqual(ContextRing.tokenLine(ContextUsage(usedTokens: 12_345, limitTokens: 65_536)), "12K of 66K tokens used")
    XCTAssertEqual(ContextRing.tokens(9_999), "10K")
    XCTAssertEqual(ContextRing.tokens(9_949), "9.9K")
    XCTAssertEqual(ContextRing.tokens(1_250), "1.3K")
    XCTAssertEqual(ContextRing.tokens(999), "999")
  }

  func testRingVoiceOverValue() {
    XCTAssertEqual(ContextRing.accessibilityValue(ContextUsage(usedTokens: 640, limitTokens: 8_192)),
                   "640 of 8.2K tokens used\n92% of context left")
    XCTAssertEqual(ContextRing.accessibilityValue(ContextUsage(usedTokens: 92, limitTokens: 100)),
                   "92 of 100 tokens used\n8% of context left. Earlier messages will be summarized.")
  }
}
