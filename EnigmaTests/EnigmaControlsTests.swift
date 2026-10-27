import AppKit
import SwiftUI
import XCTest
@testable import Enigma

/// The shared controls' states that can be checked as logic, plus a render
/// that shows they draw from the palette.
final class EnigmaControlsTests: XCTestCase {
  private let palettes = [EnigmaPalette.paper, .ink]

  func testOnlyThePrimaryButtonIsFilledWithTheAccent() {
    for palette in palettes {
      XCTAssertEqual(EnigmaButtonKind.primary.fill(in: palette, isHovered: false), palette.accent)
      XCTAssertEqual(EnigmaButtonKind.primary.fill(in: palette, isHovered: true), palette.accent)
      for kind in [EnigmaButtonKind.secondary, .notice, .text] {
        XCTAssertNil(kind.fill(in: palette, isHovered: false), "\(kind) is plain at rest")
        XCTAssertEqual(kind.fill(in: palette, isHovered: true), palette.hover, "\(kind) shows the hover fill")
      }
      XCTAssertEqual(EnigmaButtonKind.secondary.edge, .border)
      XCTAssertEqual(EnigmaButtonKind.notice.edge, .border)
      XCTAssertEqual(EnigmaButtonKind.notice.label(in: palette, isHovered: false), palette.accentText)
      XCTAssertNil(EnigmaButtonKind.primary.edge)
      XCTAssertNil(EnigmaButtonKind.text.edge)
    }
  }

  func testButtonLabelsAreReadableOnTheirBackgrounds() {
    for palette in palettes {
      XCTAssertGreaterThanOrEqual(EnigmaButtonKind.primary.label(in: palette, isHovered: false)
        .contrastRatio(on: palette.accent), 4.5)
      for kind in [EnigmaButtonKind.secondary, .notice, .text] {
        for hovered in [false, true] {
          for surface in [palette.background, palette.surface] {
            let back = hovered ? palette.hover.composited(over: surface) : surface
            XCTAssertGreaterThanOrEqual(kind.label(in: palette, isHovered: hovered).contrastRatio(on: back), 4.5,
                                        "\(kind) hovered \(hovered)")
          }
        }
      }
      XCTAssertEqual(EnigmaButtonKind.text.label(in: palette, isHovered: true), palette.textPrimary,
                     "Text buttons darken on hover")
    }
  }

  func testIncreaseContrastDrawsHairlinesAndBordersAtDoubleBorderOpacity() {
    for palette in palettes {
      XCTAssertEqual(EnigmaEdge.hairline.color(in: palette, increasedContrast: false), palette.hairline)
      XCTAssertEqual(EnigmaEdge.border.color(in: palette, increasedContrast: false), palette.border)
      for edge in [EnigmaEdge.hairline, .border] {
        let strong = edge.color(in: palette, increasedContrast: true)
        XCTAssertEqual(strong.opacity, palette.border.opacity * 2, accuracy: 0.0001)
        XCTAssertEqual(strong.withOpacity(1), palette.border.withOpacity(1))
      }
    }
    XCTAssertEqual(EnigmaColor(hex: 0x000000, opacity: 0.7).withOpacity(1.4).opacity, 1, "Opacity tops out at 1")
  }

  func testControlsShrinkWhilePressedExceptUnderReduceMotion() {
    XCTAssertEqual(EnigmaControlStyle.pressScale(isPressed: true, reduceMotion: false), 0.97)
    XCTAssertEqual(EnigmaControlStyle.pressScale(isPressed: true, reduceMotion: false, amount: 0.99), 0.99)
    XCTAssertEqual(EnigmaControlStyle.pressScale(isPressed: false, reduceMotion: false), 1)
    XCTAssertEqual(EnigmaControlStyle.pressScale(isPressed: true, reduceMotion: true), 1)
    XCTAssertEqual(EnigmaControlStyle.press, EnigmaMotion.menu, "Presses never overshoot")
  }

  func testCommandLinesSetKeySymbolsApartFromTheMonospaceText() {
    func runs(_ text: String) -> [String] {
      EnigmaCommandLine.runs(text).map { ($0.isSymbol ? "S:" : "T:") + $0.text }
    }
    XCTAssertEqual(runs("⌥⌃ in any app"), ["S:⌥⌃", "T: in any app"])
    XCTAssertEqual(runs("select, then ⌥⌥"), ["T:select, then ", "S:⌥⌥"])
    XCTAssertEqual(runs("/screen /search /edit"), ["T:/screen /search /edit"])
    XCTAssertEqual(runs(""), [])
  }

  func testStatusLinesUseGlyphsAndReadableColors() {
    typealias Status = EnigmaStatusLine.Status
    XCTAssertEqual([Status.on, .off, .busy, .problem].map(\.glyph), ["●", "○", "◌", "!"])
    for palette in palettes {
      XCTAssertEqual(Status.on.color(in: palette), palette.accentText)
      XCTAssertEqual(Status.off.color(in: palette), palette.textSecondary)
      XCTAssertEqual(Status.problem.color(in: palette), palette.textPrimary)
      for status in [Status.on, .off, .busy, .problem] {
        for surface in [palette.background, palette.surface] {
          XCTAssertGreaterThanOrEqual(status.color(in: palette).contrastRatio(on: surface), 4.5, "\(status)")
        }
      }
    }
  }

  func testChoiceRowTitleIsDarkerWhenSelected() {
    typealias Row = EnigmaRow<EmptyView, EmptyView>
    for palette in palettes {
      XCTAssertEqual(Row.titleColor(selection: true, in: palette), palette.textPrimary)
      XCTAssertEqual(Row.titleColor(selection: false, in: palette), palette.textSecondary)
      XCTAssertEqual(Row.titleColor(selection: nil, in: palette), palette.textPrimary, "Plain rows aren't choices")
    }
  }

  @MainActor
  func testControlsDrawFromThePalette() throws {
    for (appearance, palette) in [(EnigmaAppearance.paper, EnigmaPalette.paper), (.ink, .ink)] {
      let image = try EnigmaSnapshot.render(ControlsHarness().enigmaTheme(appearance),
                                            size: CGSize(width: 240, height: 160))
      // The primary button spans x 22...218 and y 11...69; its padding is accent.
      try assertPixel(image, at: CGPoint(x: 30, y: 40), is: palette.accent, "\(appearance) primary")
      // The text field below fills with surface.
      try assertPixel(image, at: CGPoint(x: 212, y: 114), is: palette.surface, "\(appearance) field")
      try assertPixel(image, at: CGPoint(x: 4, y: 150), is: palette.background, "\(appearance) canvas")
    }
  }

  /// The button's `@FocusState` (bound by `.enigmaButtonStyle`) drives the
  /// `accent` ring, drawn with a gap so it shows around an `accent` fill.
  @MainActor
  func testFocusedButtonDrawsTheAccentRing() throws {
    for (appearance, palette) in [(EnigmaAppearance.paper, EnigmaPalette.paper), (.ink, .ink)] {
      for focused in [false, true] {
        let image = try EnigmaSnapshot.render(FocusHarness(focused: focused).enigmaTheme(appearance),
                                              size: CGSize(width: 240, height: 120))
        // The button spans x 22...218 and y 31...89; the ring sits 1 to 3 points outside it.
        let ring = try EnigmaSnapshot.pixel(image, at: CGPoint(x: 120, y: 29))
        XCTAssertTrue(EnigmaSnapshot.matches(ring, focused ? palette.accent : palette.background),
                      "\(appearance), focused \(focused): \(ring)")
        let gap = try EnigmaSnapshot.pixel(image, at: CGPoint(x: 120, y: 30.5))
        XCTAssertTrue(EnigmaSnapshot.matches(gap, palette.background), "A gap separates ring and fill: \(gap)")
      }
    }
  }

  private func assertPixel(_ image: NSBitmapImageRep, at point: CGPoint, is expected: EnigmaColor, _ message: String,
                           file: StaticString = #filePath, line: UInt = #line) throws {
    let color = try EnigmaSnapshot.pixel(image, at: point)
    XCTAssertTrue(EnigmaSnapshot.matches(color, expected), "\(message): \(color) at \(point)", file: file, line: line)
  }
}

private struct ControlsHarness: View {
  @Environment(\.enigmaPalette) private var palette
  @State private var text = ""

  var body: some View {
    VStack(spacing: 0) {
      Button {} label: { Color.clear.frame(width: 160, height: 40) }
        .enigmaButtonStyle(.primary)
        .padding(.top, 11)
      EnigmaTextField("Key", text: $text)
        .frame(width: 200)
        .padding(.top, 30)
      Spacer(minLength: 0)
    }
    .frame(width: 240, height: 160)
    .background(palette.background.color)
  }
}

private struct FocusHarness: View {
  let focused: Bool
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    Button {} label: { Color.clear.frame(width: 160, height: 40) }
      .buttonStyle(EnigmaButtonStyle(kind: .primary, isFocused: focused))
      .frame(width: 240, height: 120)
      .background(palette.background.color)
  }
}

// MARK: Settings controls

extension EnigmaControlsTests {
  func testSwitchTrackAndKnobFollowThePaletteAndStayVisible() {
    for palette in [EnigmaPalette.paper, .ink] {
      XCTAssertEqual(EnigmaSwitch.trackColor(isOn: true, in: palette, increasedContrast: false), palette.accent)
      XCTAssertEqual(EnigmaSwitch.trackColor(isOn: false, in: palette, increasedContrast: false), palette.border)
      XCTAssertEqual(EnigmaSwitch.trackColor(isOn: false, in: palette, increasedContrast: true).opacity,
                     palette.border.opacity * 2, accuracy: 0.0001, "Increase Contrast doubles the track")
      XCTAssertEqual(EnigmaSwitch.knobColor(isOn: true, in: palette), palette.onAccent)
      // The knob stands out from its track in both states.
      XCTAssertGreaterThanOrEqual(EnigmaSwitch.knobColor(isOn: true, in: palette).contrastRatio(on: palette.accent), 3)
      let offTrack = palette.border.composited(over: palette.background)
      XCTAssertGreaterThanOrEqual(EnigmaSwitch.knobColor(isOn: false, in: palette).contrastRatio(on: offTrack), 1.3)
    }
    XCTAssertEqual(EnigmaSwitch.knobColor(isOn: false, in: .paper), EnigmaPalette.paper.menu, "White, as in the mockup")
    XCTAssertEqual(EnigmaSwitch.knobColor(isOn: false, in: .ink), EnigmaPalette.ink.textPrimary)
  }

  func testSwitchKnobSpringsAcrossTheTrackExceptUnderReduceMotion() {
    XCTAssertEqual(EnigmaSwitch.knobTravel, 13, "As in the mockup")
    XCTAssertEqual(EnigmaSwitch.knobOffset(isOn: false), 0)
    XCTAssertEqual(EnigmaSwitch.knobOffset(isOn: true), 13)
    XCTAssertNil(EnigmaSwitch.knobAnimation(reduceMotion: true))
    XCTAssertNotNil(EnigmaSwitch.knobAnimation(reduceMotion: false))
    XCTAssertLessThan(EnigmaMotion.switchKnob.dampingFraction, 0.85, "A switch is allowed a real bounce")
  }

  func testSegmentTitlesAreAllReadable() {
    for palette in [EnigmaPalette.paper, .ink] {
      for selected in [false, true] {
        XCTAssertGreaterThanOrEqual(EnigmaSegmentStyle.titleColor(isSelected: selected, isHovered: false, in: palette)
          .contrastRatio(on: palette.background), 4.5)
      }
      XCTAssertEqual(EnigmaSegmentStyle.titleColor(isSelected: true, isHovered: false, in: palette), palette.textPrimary)
      XCTAssertEqual(EnigmaSegmentStyle.titleColor(isSelected: false, isHovered: true, in: palette), palette.textPrimary)
    }
  }

  func testMenusOpenBelowOrAboveAndStayInTheWindow() {
    let container = CGSize(width: 800, height: 600)
    let rightTop = EnigmaMenuPlacement(anchor: CGRect(x: 600, y: 100, width: 120, height: 26), container: container)
    XCTAssertFalse(rightTop.opensUpward)
    XCTAssertTrue(rightTop.alignsTrailing)
    XCTAssertEqual(rightTop.alignment, .topTrailing)
    XCTAssertEqual(rightTop.offset, CGSize(width: -80, height: 130))
    XCTAssertEqual(rightTop.maximumHeight, 600 - 126 - 4 - 8)

    let leftBottom = EnigmaMenuPlacement(anchor: CGRect(x: 40, y: 540, width: 120, height: 26), container: container)
    XCTAssertTrue(leftBottom.opensUpward)
    XCTAssertFalse(leftBottom.alignsTrailing)
    XCTAssertEqual(leftBottom.alignment, .bottomLeading)
    XCTAssertEqual(leftBottom.offset, CGSize(width: 40, height: -(600 - 540 + 4)))
    XCTAssertEqual(leftBottom.maximumHeight, 540 - 4 - 8)
    XCTAssertEqual(leftBottom.scaleAnchor.x, 40 / 800, accuracy: 0.0001)
    XCTAssertEqual(leftBottom.scaleAnchor.y, 536 / 600.0, accuracy: 0.0001)
    XCTAssertEqual(EnigmaMotion.menu.dampingFraction, 1, "Menus never overshoot")
  }

  @MainActor
  func testMenuChoicesMarkTheSelectionAndSetIt() {
    var value = "b"
    let binding = Binding(get: { value }, set: { value = $0 })
    let section = EnigmaMenuSection.choosing([EnigmaOption("a", "A"), EnigmaOption("b", "B"),
                                              EnigmaOption("c", "C", isEnabled: false)], selection: binding)
    XCTAssertEqual(section.items.map(\.isSelected), [false, true, false])
    XCTAssertEqual(section.items.map(\.isEnabled), [true, true, false])
    section.items[0].action()
    XCTAssertEqual(value, "a")

    let presenter = EnigmaMenuPresenter()
    let first = UUID()
    presenter.present(.init(id: first, label: "Menu", anchor: .zero, minimumWidth: 160, sections: [section]))
    presenter.dismiss(UUID())
    XCTAssertEqual(presenter.presentation?.id, first, "Another menu's dismissal leaves this one open")
    presenter.dismiss(first)
    XCTAssertNil(presenter.presentation)
  }
}
