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
    // Mirrors the color table in docs/design/ui-revamp/README.md.
    let expected: [(KeyPath<EnigmaPalette, EnigmaColor>, paper: EnigmaColor, ink: EnigmaColor)] = [
      (\.background, EnigmaColor(hex: 0xF3EEE4), EnigmaColor(hex: 0x141512)),
      (\.sidebar, EnigmaColor(hex: 0xE8E1D3), EnigmaColor(hex: 0x0E0F0D)),
      (\.surface, EnigmaColor(hex: 0xFCFAF5), EnigmaColor(hex: 0x1E1F1B)),
      (\.menu, EnigmaColor(hex: 0xFFFFFF), EnigmaColor(hex: 0x282923)),
      (\.userBubble, EnigmaColor(hex: 0xE6DFD0), EnigmaColor(hex: 0x262721)),
      (\.textPrimary, EnigmaColor(hex: 0x211E19), EnigmaColor(hex: 0xEFE8D8)),
      (\.textSecondary, EnigmaColor(hex: 0x5B554A), EnigmaColor(hex: 0xABA496)),
      (\.textTertiary, EnigmaColor(hex: 0x827B6D), EnigmaColor(hex: 0x827D70)),
      (\.hairline, EnigmaColor(hex: 0x24201A, opacity: 0.10), EnigmaColor(hex: 0xEDE6D6, opacity: 0.08)),
      (\.border, EnigmaColor(hex: 0x24201A, opacity: 0.18), EnigmaColor(hex: 0xEDE6D6, opacity: 0.15)),
      (\.hover, EnigmaColor(hex: 0x24201A, opacity: 0.05), EnigmaColor(hex: 0xEDE6D6, opacity: 0.05)),
      (\.accent, EnigmaColor(hex: 0x3F5A12), EnigmaColor(hex: 0xCDEB78)),
      (\.onAccent, EnigmaColor(hex: 0xF5F8EA), EnigmaColor(hex: 0x1A2306)),
      (\.accentText, EnigmaColor(hex: 0x4A6A14), EnigmaColor(hex: 0xCDEB78)),
      (\.characterBody, EnigmaColor(hex: 0xC3DE5E), EnigmaColor(hex: 0xC3DE5E)),
      (\.characterInk, EnigmaColor(hex: 0x211E19), EnigmaColor(hex: 0xD9D1BF)),
      (\.warning, EnigmaColor(hex: 0xE0A33B), EnigmaColor(hex: 0xE0A33B)),
    ]
    XCTAssertEqual(expected.count, 17)
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
