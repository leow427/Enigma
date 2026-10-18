import AppKit
import SwiftUI
import XCTest
@testable import Enigma

final class EnigmaCharacterTests: XCTestCase {
  private typealias Slot = EnigmaCharacterModel.Slot

  private let mainSlot = Slot(center: CGPoint(x: 200, y: 160), size: 92)
  private let replySlot = Slot(center: CGPoint(x: 80, y: 520), size: 30)

  private func makeModel(_ state: EnigmaCharacterState = .idle, seed: UInt64 = 42, reduceMotion: Bool = false,
                         on slot: Slot? = nil) -> EnigmaCharacterModel {
    var model = EnigmaCharacterModel(seed: seed, reduceMotion: reduceMotion)
    model.state = state
    model.place(at: slot ?? mainSlot, instantly: true)
    return model
  }

  // MARK: Shape

  func testOutlineIsClosedAndItsRadiusStaysPositiveAndBounded() {
    for state in EnigmaCharacterState.allCases {
      var model = makeModel(state)
      model.attention = CGPoint(x: 320, y: 230)
      for step in 0..<600 {
        if step % 7 == 0 { model.token() }
        if step % 11 == 0 { model.key(towards: CGPoint(x: 320, y: 230)) }
        if step % 97 == 0 { model.poke() }
        model.step(dt: 1.0 / 120)
        for index in 0..<360 {
          let radius = model.outlineRadius(at: Double(index) / 360 * 2 * .pi)
          XCTAssertGreaterThan(radius, 0.4, "\(state) at step \(step)")
          XCTAssertLessThan(radius, 2, "\(state) at step \(step)")
        }
        let frame = model.frame
        XCTAssertEqual(frame.outline.count, EnigmaCharacterTuning.outlinePoints)
        XCTAssertTrue(frame.outline.allSatisfy { $0.x.isFinite && $0.y.isFinite })
      }
      var lastElement: Path.Element?
      EnigmaCharacterRenderer.outlinePath(model.frame.outline).forEach { lastElement = $0 }
      XCTAssertEqual(lastElement, .closeSubpath, "\(state) outline must be a closed curve")
    }
  }

  func testRestingShapeHasFiveLobes() {
    var model = makeModel()
    for _ in 0..<240 { model.step(dt: 1.0 / 120) }
    XCTAssertEqual(model.lobes, 5)
    XCTAssertEqual(model.lobeMorph, 0)
    // Without the jitter, the outline has exactly five bumps.
    let still = EnigmaCharacterModel.stillFrame(on: mainSlot)
    XCTAssertEqual(peakCount(still.outline, around: mainSlot.center), 5)
  }

  func testThinkingCyclesThroughThreeFourSixAndSevenLobes() {
    var model = makeModel(.thinking)
    var seen = Set<Int>()
    for _ in 0..<(120 * 20) {
      model.step(dt: 1.0 / 120)
      seen.insert(model.lobes)
      seen.insert(model.nextLobes)
    }
    seen.remove(EnigmaCharacterTuning.restingLobes)
    XCTAssertEqual(seen, [3, 4, 6, 7])
    XCTAssertNotEqual(model.lobes, EnigmaCharacterTuning.restingLobes)

    model.state = .idle
    for _ in 0..<(120 * 3) { model.step(dt: 1.0 / 120) }
    XCTAssertEqual(model.lobes, EnigmaCharacterTuning.restingLobes)
  }

  func testThinkingSplitsTheHoleIntoThree() {
    var model = makeModel()
    model.step(dt: 1.0 / 120)
    XCTAssertEqual(model.frame.holes.count, 1)

    model.state = .thinking
    for _ in 0..<(120 * 2) { model.step(dt: 1.0 / 120) }
    let holes = model.frame.holes
    XCTAssertEqual(holes.count, 3)
    XCTAssertEqual(model.holeSplit, 1, accuracy: 0.01)
    for (index, hole) in holes.enumerated() {
      let other = holes[(index + 1) % 3]
      XCTAssertGreaterThan(hypot(hole.center.x - other.center.x, hole.center.y - other.center.y), hole.radius * 2,
                           "The three holes must be apart once split")
    }

    model.state = .idle
    for _ in 0..<(120 * 3) { model.step(dt: 1.0 / 120) }
    XCTAssertEqual(model.frame.holes.count, 1)
  }

  func testAntennaNeverStretchesPastItsLimit() {
    var model = makeModel()
    var checked = 0
    func check() {
      let frame = model.frame
      guard !frame.isEmpty else { return }
      let base = frame.antennaBase
      let tip = frame.antenna.end
      XCTAssertLessThanOrEqual(hypot(tip.x - base.x, tip.y - base.y), frame.antennaLimit + 1e-9)
      XCTAssertEqual(frame.antennaLimit, model.bodyRadius * 0.8 * 1.25, accuracy: 1e-9)
      checked += 1
    }
    for step in 0..<1200 {
      if step % 5 == 0 { model.poke() }
      if step % 3 == 0 { model.key(towards: CGPoint(x: 400, y: 160)) }
      if step == 300 { model.state = .thinking }
      if step == 500 {
        model.beginDrag(at: model.position)
        model.moveDrag(to: CGPoint(x: 420, y: 60))
        model.endDrag(velocity: CGVector(dx: -4000, dy: 3000))
      }
      if step == 800 { model.fall(to: replySlot) }
      if step == 1000 { model.state = .error }
      model.step(dt: 1.0 / 120)
      check()
    }
    XCTAssertEqual(checked, 1200)
  }

  // MARK: Moving between slots

  func testFallToALowerSlotLandsSoonAndSettlesExactlyOnIt() {
    var model = makeModel()
    model.fall(to: replySlot)
    XCTAssertTrue(model.isFalling)
    XCTAssertEqual(model.fallPhase, .crouch)

    var time = 0.0
    var highest = model.position.y
    var landedAt: Double?
    var sawStretch = false
    while time < 3 {
      model.step(dt: 1.0 / 120)
      time += 1.0 / 120
      highest = min(highest, model.position.y)
      if model.fallPhase == .air, model.squashAmount < -0.2 { sawStretch = true }
      if landedAt == nil, !model.isFalling {
        landedAt = time
        XCTAssertGreaterThan(model.squashAmount, 0.3, "It squashes on landing")
        XCTAssertGreaterThan(model.landingEffectCount, 0, "Dust puffs and impact lines appear on landing")
        XCTAssertFalse(model.frame.puffs.isEmpty && model.frame.impactLines.isEmpty)
      }
    }
    let landing = try? XCTUnwrap(landedAt)
    XCTAssertLessThan(landing ?? .infinity, 1.0, "A 360 pt fall lands in well under a second")
    XCTAssertGreaterThan(landing ?? 0, EnigmaCharacterTuning.crouchDuration)
    XCTAssertLessThan(highest, mainSlot.center.y - 1, "It hops before it falls")
    XCTAssertTrue(sawStretch, "It stretches in the air")
    XCTAssertEqual(model.position, replySlot.center)
    XCTAssertEqual(model.bodyRadius, replySlot.size * EnigmaCharacterTuning.bodyScale)
    XCTAssertEqual(model.velocity, .zero)
    XCTAssertEqual(model.landingEffectCount, 0)
  }

  func testMoveToAHigherSlotGlidesInsteadOfFalling() {
    var model = makeModel(on: replySlot)
    model.fall(to: mainSlot)
    XCTAssertFalse(model.isFalling)
    var previousDistance = Double.infinity
    var closer = 0
    for _ in 0..<(120 * 3) {
      model.step(dt: 1.0 / 120)
      XCTAssertFalse(model.isFalling)
      XCTAssertEqual(model.landingEffectCount, 0)
      let distance = hypot(model.position.x - mainSlot.center.x, model.position.y - mainSlot.center.y)
      if distance < previousDistance { closer += 1 }
      previousDistance = distance
    }
    XCTAssertGreaterThan(closer, 30)
    XCTAssertEqual(model.position, mainSlot.center)
    XCTAssertEqual(model.bodyRadius, mainSlot.size * EnigmaCharacterTuning.bodyScale)
  }

  func testThrowCarriesItsReleaseVelocityAndSpringsBack() {
    var model = makeModel()
    model.beginDrag(at: CGPoint(x: 210, y: 150))
    model.moveDrag(to: CGPoint(x: 260, y: 120))
    XCTAssertTrue(model.isDragging)
    XCTAssertEqual(model.position, CGPoint(x: 250, y: 130), "It follows the pointer from where it was grabbed")
    model.endDrag(velocity: CGVector(dx: 900, dy: -400))
    XCTAssertFalse(model.isDragging)
    XCTAssertEqual(model.velocity, CGVector(dx: 900, dy: -400))

    model.step(dt: 1.0 / 120)
    XCTAssertGreaterThan(model.position.x, 250, "The throw keeps moving the way it was thrown")
    XCTAssertLessThan(model.position.y, 130)
    for _ in 0..<(120 * 4) { model.step(dt: 1.0 / 120) }
    XCTAssertEqual(model.position, mainSlot.center)
  }

  func testSlotChangeDuringADragKeepsTheThrow() {
    var model = makeModel()
    model.beginDrag(at: mainSlot.center)
    model.moveDrag(to: CGPoint(x: 260, y: 300))
    model.fall(to: replySlot)
    XCTAssertFalse(model.isFalling, "A dragged character doesn't start a fall")
    model.moveDrag(to: CGPoint(x: 280, y: 320))
    XCTAssertEqual(model.position, CGPoint(x: 280, y: 320), "It stays under the pointer")
    model.endDrag(velocity: CGVector(dx: -700, dy: 500))
    XCTAssertEqual(model.velocity, CGVector(dx: -700, dy: 500))
    model.step(dt: 1.0 / 120)
    XCTAssertLessThan(model.position.x, 280, "The throw isn't dropped")
    XCTAssertGreaterThan(model.position.y, 320, "It isn't snapped back to where the drag began")
    for _ in 0..<(120 * 4) { model.step(dt: 1.0 / 120) }
    XCTAssertEqual(model.position, replySlot.center, "It springs to the new slot")
    XCTAssertEqual(model.bodyRadius, replySlot.size * EnigmaCharacterTuning.bodyScale)
  }

  func testShortDragIsAPokeNotAThrow() {
    var model = makeModel()
    model.step(dt: 1.0 / 120)
    let before = model.frame.outline
    model.beginDrag(at: CGPoint(x: 200, y: 160))
    model.moveDrag(to: CGPoint(x: 201, y: 161))
    model.endDrag(velocity: CGVector(dx: 2000, dy: 0))
    XCTAssertEqual(model.velocity, .zero)
    model.step(dt: 1.0 / 60)
    XCTAssertNotEqual(model.frame.outline, before, "A poke wobbles the body")
    XCTAssertNotEqual(model.squashAmount, 0)
  }

  // MARK: Reduce Motion

  func testReduceMotionMovesInstantlyAndFreezesTheOutline() {
    var model = makeModel(reduceMotion: true)
    model.step(dt: 1.0 / 60)
    let still = model.frame

    model.token()
    model.poke()
    model.key(towards: CGPoint(x: 400, y: 200))
    model.pointer = CGPoint(x: 260, y: 200)
    for _ in 0..<300 { model.step(dt: 1.0 / 60) }
    XCTAssertEqual(model.frame, still, "Nothing moves under Reduce Motion")
    XCTAssertTrue(model.isAtRest)
    XCTAssertFalse(model.needsEveryFrame)

    model.fall(to: replySlot)
    XCTAssertFalse(model.isFalling)
    XCTAssertEqual(model.position, replySlot.center)
    XCTAssertEqual(model.bodyRadius, replySlot.size * EnigmaCharacterTuning.bodyScale)

    // States still read through the hole and the color.
    model.state = .thinking
    model.step(dt: 1.0 / 60)
    XCTAssertEqual(model.frame.holes.count, 3)
    model.state = .error
    model.step(dt: 1.0 / 60)
    XCTAssertEqual(model.frame.errorTint, 1)
  }

  // MARK: Determinism

  func testSameSeedAndTimeGiveTheSameOutline() {
    func run(seed: UInt64) -> [EnigmaCharacterFrame] {
      var model = makeModel(.answering, seed: seed)
      var frames: [EnigmaCharacterFrame] = []
      for step in 0..<240 {
        if step % 9 == 0 { model.token() }
        if step == 100 { model.poke() }
        model.step(dt: 1.0 / 120)
        frames.append(model.frame)
      }
      return frames
    }
    XCTAssertEqual(run(seed: 7), run(seed: 7))
    XCTAssertNotEqual(run(seed: 7), run(seed: 8))

    // The jitter changes 12 times a second and is keyed on the frame index.
    let first = EnigmaCharacterModel.wobble(seed: 7, frame: 3)
    let again = EnigmaCharacterModel.wobble(seed: 7, frame: 3)
    let next = EnigmaCharacterModel.wobble(seed: 7, frame: 4)
    XCTAssertEqual(first.phase, again.phase)
    XCTAssertEqual(first.weight, again.weight)
    XCTAssertNotEqual(first.phase, next.phase)

    var a = makeModel(seed: 7)
    var b = makeModel(seed: 7)
    for _ in 0..<12 { a.step(dt: 1.0 / 120) }
    for _ in 0..<2 { b.step(dt: 0.05) }
    XCTAssertEqual(a.time, b.time, accuracy: 1e-12)
    XCTAssertEqual(a.outlineRadius(at: 1), b.outlineRadius(at: 1), accuracy: 0.005,
                   "The same time draws the same outline, whatever the frame rate")
  }

  // MARK: Color and accessibility

  func testErrorStateUsesWarning() {
    var model = makeModel()
    model.step(dt: 1.0 / 60)
    for palette in [EnigmaPalette.paper, .ink] {
      XCTAssertEqual(EnigmaCharacterRenderer.bodyColor(for: model.frame, palette: palette), palette.characterBody)
    }
    model.state = .error
    for _ in 0..<(60 * 2) { model.step(dt: 1.0 / 60) }
    XCTAssertEqual(model.frame.errorTint, 1)
    for palette in [EnigmaPalette.paper, .ink] {
      XCTAssertEqual(EnigmaCharacterRenderer.bodyColor(for: model.frame, palette: palette), palette.warning)
    }
    model.state = .idle
    for _ in 0..<(60 * 2) { model.step(dt: 1.0 / 60) }
    XCTAssertEqual(model.frame.errorTint, 0)
  }

  func testAccessibilityLabelAndValues() {
    XCTAssertEqual(EnigmaCharacterState.accessibilityLabel, "Enigma")
    XCTAssertEqual(EnigmaCharacterState.allCases.map(\.accessibilityValue),
                   ["Idle", "Listening", "Thinking", "Answering", "Something went wrong"])
  }

  @MainActor
  func testCanvasDrawsBodyHoleAndWarningInThePalettesColors() throws {
    for (appearance, palette) in [(EnigmaAppearance.paper, EnigmaPalette.paper), (.ink, .ink)] {
      for state in [EnigmaCharacterState.idle, .error] {
        var model = makeModel(state, on: Slot(center: CGPoint(x: 70, y: 80), size: 92))
        for _ in 0..<(60 * 2) { model.step(dt: 1.0 / 60) }
        let frame = model.frame
        let image = try EnigmaSnapshot.render(
          CharacterFramesView(frames: [frame]).background(palette.background.color).enigmaTheme(appearance),
          size: CGSize(width: 140, height: 160))
        let hole = try XCTUnwrap(frame.holes.first)
        let left = frame.outline[EnigmaCharacterTuning.outlinePoints / 2]
        let inBody = CGPoint(x: (hole.center.x - hole.radius + left.x) / 2, y: (hole.center.y + left.y) / 2)
        try assertPixel(image, at: hole.center, is: palette.background, "\(appearance) \(state) hole")
        try assertPixel(image, at: inBody, is: state == .error ? palette.warning : palette.characterBody,
                        "\(appearance) \(state) body")
      }
    }
  }

  @MainActor
  func testEnigmaThemeResolvesPaperInkAndSystem() throws {
    let cases: [(EnigmaAppearance, system: ColorScheme, EnigmaPalette, ColorScheme)] = [
      (.paper, .dark, .paper, .light),
      (.paper, .light, .paper, .light),
      (.ink, .light, .ink, .dark),
      (.ink, .dark, .ink, .dark),
      (.system, .light, .paper, .light),
      (.system, .dark, .ink, .dark),
    ]
    for (appearance, system, palette, scheme) in cases {
      let probe = ThemeProbe.Box()
      _ = try EnigmaSnapshot.render(
        ThemeProbe(box: probe).enigmaTheme(appearance).environment(\.colorScheme, system),
        size: CGSize(width: 10, height: 10), scale: 1)
      XCTAssertEqual(probe.palette, palette, "\(appearance) on a \(system) Mac")
      XCTAssertEqual(probe.colorScheme, scheme, "\(appearance) on a \(system) Mac")
    }
    XCTAssertEqual(EnigmaAppearance.paper.colorScheme, .light)
    XCTAssertEqual(EnigmaAppearance.ink.colorScheme, .dark)
    XCTAssertNil(EnigmaAppearance.system.colorScheme)
  }

  // MARK: Mark

  func testMarkFitsItsFrameAndIsTheStillPose() {
    for style in [EnigmaMark.Style.outline, .filled] {
      for side in [14.0, 18, 23, 24, 30, 40, 92, 1024] {
        let rect = CGRect(x: 3, y: 5, width: side, height: side)
        let frame = EnigmaMark.pose(style, in: rect)
        let bounds = frame.drawnBounds
        XCTAssertTrue(rect.insetBy(dx: -0.01 * side, dy: -0.01 * side).contains(bounds), "\(side) pt \(style) mark fits")
        XCTAssertEqual(max(bounds.width, bounds.height), side, accuracy: 0.02 * side, "\(side) pt mark fills its frame")
        XCTAssertEqual(bounds.midX, rect.midX, accuracy: 0.01 * side)
        XCTAssertEqual(bounds.midY, rect.midY, accuracy: 0.01 * side)
        XCTAssertEqual(frame.legs.isEmpty, side < EnigmaMark.legsMinimumSide(for: style), "\(side) pt \(style) legs")
        XCTAssertEqual(frame.feet.count, frame.legs.count)
        XCTAssertEqual(frame.shadowOpacity, 0)
        // The still pose: one hole, the antenna standing straight up, and the
        // five resting lobes with no jitter.
        XCTAssertEqual(frame.holes.count, 1)
        XCTAssertEqual(frame.antenna.end.x, frame.antennaBase.x, accuracy: 1e-9)
        XCTAssertLessThan(frame.antenna.end.y, frame.antennaBase.y)
        XCTAssertEqual(peakCount(frame.outline, around: frame.holes[0].center), 5)
      }
    }
    XCTAssertEqual(EnigmaCharacterModel.stillFrame(on: mainSlot), EnigmaCharacterModel.stillFrame(on: mainSlot))
    XCTAssertEqual(EnigmaMark.outlineOpacity(increasedContrast: true),
                   min(1, 2 * EnigmaMark.outlineOpacity(increasedContrast: false)))
  }

  // MARK: Controller and pacing

  @MainActor
  func testControllerPlacesThenFallsBetweenSlots() {
    let controller = EnigmaCharacterController(seed: 3)
    let slots: [EnigmaCharacterSlotID: Slot] = ["main": mainSlot, "reply": replySlot]
    var time = 100.0
    func frame(_ slots: [EnigmaCharacterSlotID: Slot] = slots, reduceMotion: Bool = false) -> EnigmaCharacterFrame {
      time += 1.0 / 120
      return controller.frame(at: time, slots: slots, targets: [:], reduceMotion: reduceMotion)
    }

    XCTAssertTrue(frame().isEmpty, "Nothing is drawn before a slot is chosen")
    controller.move(to: "main")
    XCTAssertFalse(frame().isEmpty)
    XCTAssertEqual(controller.model.position, mainSlot.center, "The first slot is taken instantly")

    controller.move(to: "reply")
    _ = frame()
    XCTAssertTrue(controller.model.isFalling)
    for _ in 0..<(120 * 3) { _ = frame() }
    XCTAssertEqual(controller.model.position, replySlot.center)

    // A slot that leaves the layout hides the character until it returns.
    XCTAssertTrue(frame(["main": mainSlot]).isEmpty)
    XCTAssertFalse(frame().isEmpty)

    controller.move(to: "main")
    _ = frame(reduceMotion: true)
    XCTAssertEqual(controller.model.position, mainSlot.center, "Reduce Motion moves instantly")
  }

  @MainActor
  func testStageDrawsTheCharacterAtItsSlot() throws {
    for (appearance, palette) in [(EnigmaAppearance.paper, EnigmaPalette.paper), (.ink, .ink)] {
      let controller = EnigmaCharacterController(seed: 9)
      controller.move(to: "main")
      let image = try EnigmaSnapshot.render(StageHarness(controller: controller).enigmaTheme(appearance),
                                            size: CGSize(width: 220, height: 240))
      // The slot's center is (110, 46 + 50): the hole. Left of it is the body.
      XCTAssertEqual(controller.model.position, CGPoint(x: 110, y: 96))
      try assertPixel(image, at: CGPoint(x: 110, y: 96), is: palette.background, "\(appearance) hole")
      try assertPixel(image, at: CGPoint(x: 110 - 92 * 0.34 * 0.6, y: 96), is: palette.characterBody,
                      "\(appearance) body")
      try assertPixel(image, at: CGPoint(x: 20, y: 220), is: palette.background, "\(appearance) canvas")
    }
  }

  @MainActor
  func testTimelineRestsWhileNothingIsDrawn() async throws {
    let controller = EnigmaCharacterController(seed: 4)
    var time = 50.0
    func frame(_ slots: [EnigmaCharacterSlotID: Slot]) -> EnigmaCharacterFrame {
      time += 1.0 / 60
      return controller.frame(at: time, slots: slots, targets: [:], reduceMotion: false)
    }

    XCTAssertTrue(frame([:]).isEmpty)
    XCTAssertEqual(controller.neededActivity, .rest, "No slot chosen")
    try await waitForUI("the timeline to rest with no slot") { controller.activity == .rest }

    controller.move(to: "main")
    XCTAssertEqual(controller.activity, .live, "Choosing a slot wakes the timeline")
    XCTAssertTrue(frame([:]).isEmpty, "The slot isn't laid out yet")
    XCTAssertEqual(controller.neededActivity, .rest)
    XCTAssertFalse(frame(["main": mainSlot]).isEmpty)
    XCTAssertNotEqual(controller.neededActivity, .rest, "The slot arriving brings it back")
    try await waitForUI("the timeline to run") { controller.activity != .rest }

    XCTAssertTrue(frame([:]).isEmpty, "The slot left the layout")
    XCTAssertEqual(controller.neededActivity, .rest)
    try await waitForUI("the timeline to rest after the slot left") { controller.activity == .rest }
    XCTAssertEqual(EnigmaCharacterPacing.resolve(windowVisible: true, reduceMotion: false,
                                                 isAtRest: controller.activity == .rest, needsEveryFrame: false), .paused)

    XCTAssertFalse(frame(["main": mainSlot]).isEmpty)
    XCTAssertNotEqual(controller.neededActivity, .rest)
    try await waitForUI("the timeline to run again") { controller.activity != .rest }
  }

  @MainActor
  func testStageDrawsAgainWhenItsSlotReturnsWhilePaused() async throws {
    let controller = EnigmaCharacterController(seed: 6)
    controller.move(to: "main")
    let layout = SlotToggle()
    let host = NSHostingView(rootView: ToggledStageHarness(controller: controller, layout: layout).enigmaTheme(.paper))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 240), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.contentView = host
    host.frame = window.contentLayoutRect
    // The window is never shown, so the stage's timeline is paused throughout.
    try await waitForUI("the character at its slot", in: host) { controller.isPresent }

    layout.showsSlot = false
    try await waitForUI("the character to hide and the timeline to rest", in: host) {
      !controller.isPresent && controller.activity == .rest
    }
    layout.showsSlot = true
    try await waitForUI("the character to come back with its slot", in: host) {
      controller.isPresent && controller.activity != .rest
    }
    XCTAssertEqual(controller.model.position, CGPoint(x: 110, y: 96))
  }

  @MainActor
  func testIgnoredEventsDoNotWakeTheTimeline() async throws {
    var still = makeModel(reduceMotion: true)
    XCTAssertFalse(still.token())
    XCTAssertFalse(still.poke())
    XCTAssertFalse(still.assemble())
    XCTAssertFalse(still.key(towards: CGPoint(x: 400, y: 160)))
    var moving = makeModel()
    XCTAssertTrue(moving.token())
    XCTAssertFalse(moving.token(), "A token right after another shares its ripple")
    XCTAssertTrue(moving.poke())

    let controller = EnigmaCharacterController(seed: 8)
    controller.attention = "composer"
    controller.move(to: "main")
    _ = controller.frame(at: 10, slots: ["main": mainSlot], targets: ["composer": CGPoint(x: 320, y: 230)],
                         reduceMotion: true)
    try await waitForUI("the timeline to rest under Reduce Motion") { controller.activity == .rest }
    controller.token()
    controller.poke()
    controller.assemble()
    controller.key()
    XCTAssertEqual(controller.activity, .rest, "Events Reduce Motion ignores don't wake the timeline")
  }

  func testTimelinePausesWhenHiddenStillOrAtRest() {
    typealias Pacing = EnigmaCharacterPacing
    XCTAssertEqual(Pacing.resolve(windowVisible: false, reduceMotion: false, isAtRest: false, needsEveryFrame: true), .paused)
    XCTAssertEqual(Pacing.resolve(windowVisible: true, reduceMotion: true, isAtRest: false, needsEveryFrame: true), .paused)
    XCTAssertEqual(Pacing.resolve(windowVisible: true, reduceMotion: false, isAtRest: true, needsEveryFrame: false), .paused)
    XCTAssertEqual(Pacing.resolve(windowVisible: true, reduceMotion: false, isAtRest: false, needsEveryFrame: true), .live)
    XCTAssertEqual(Pacing.resolve(windowVisible: true, reduceMotion: false, isAtRest: false, needsEveryFrame: false), .ambient)

    // The model asks for every frame only while something is happening.
    var model = makeModel()
    for _ in 0..<(120 * 3) { model.step(dt: 1.0 / 120) }
    XCTAssertFalse(model.needsEveryFrame, "A settled idle character only needs the ambient loop")
    XCTAssertFalse(model.isAtRest, "The idle loop keeps moving without Reduce Motion")
    model.token()
    XCTAssertTrue(model.needsEveryFrame)
    model.state = .thinking
    for _ in 0..<(120 * 3) { model.step(dt: 1.0 / 120) }
    XCTAssertTrue(model.needsEveryFrame)
  }

  @MainActor
  func testHiddenWindowCountsAsNotVisible() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    XCTAssertFalse(EnigmaCharacterPacing.isVisible(window), "A window that was never shown is hidden")
  }

  // MARK: CPU

  func testOneFrameCostsWellUnderAMillisecond() {
    var model = makeModel(.thinking)
    model.pointer = CGPoint(x: 300, y: 220)
    let frames = 3000
    var drawn = 0
    let elapsed = ContinuousClock().measure {
      for step in 0..<frames {
        if step % 4 == 0 { model.token() }
        model.step(dt: 1.0 / 120)
        let paths = EnigmaCharacterRenderer.paths(for: model.frame)
        if !paths.body.isEmpty { drawn += 1 }
      }
    }
    XCTAssertEqual(drawn, frames)
    let perFrame = elapsed / frames
    let microseconds = Double(perFrame.components.attoseconds) / 1e12 + Double(perFrame.components.seconds) * 1e6
    print(String(format: "Enigma character: one step plus paths takes %.1f µs", microseconds))
    XCTAssertLessThan(perFrame, .milliseconds(1))
  }

  // MARK: Screenshots

  @MainActor
  func testSaveCharacterScreenshots() throws {
    _ = try EnigmaSnapshot.directory()

    // Every state at the main page's 92 pt.
    let cell = 150.0
    let states = EnigmaCharacterState.allCases.enumerated().map { index, state in
      pose(state, on: Slot(center: CGPoint(x: cell * (Double(index) + 0.5), y: 112), size: 92))
    }
    try EnigmaSnapshot.save("states", size: CGSize(width: cell * 5, height: 210)) {
      LabeledFrames(frames: states, labels: EnigmaCharacterState.allCases.map { $0.rawValue }, cell: cell)
    }

    // Every slot size, feet on one line.
    let sizes: [(Double, Double)] = [(150, 100), (92, 255), (40, 365), (30, 435)]
    let sized = sizes.map { side, x in pose(.idle, on: Slot(center: CGPoint(x: x, y: 196 - side * 0.4), size: side)) }
    try EnigmaSnapshot.save("sizes", size: CGSize(width: 480, height: 240)) {
      ZStack(alignment: .topLeading) {
        CharacterFramesView(frames: sized)
        ForEach(Array(sizes.enumerated()), id: \.offset) { _, size in
          SnapshotLabel(text: "\(Int(size.0)) pt").position(x: size.1, y: 222)
        }
      }
    }

    // The fall and a throw, frame by frame.
    let motion = motionFrames(cell: cell)
    try EnigmaSnapshot.save("motion", size: CGSize(width: cell * Double(motion.count), height: 340)) {
      LabeledFrames(frames: motion.map(\.frame), labels: motion.map(\.label), cell: cell)
    }

    // The mark at chat sizes, in both styles, and large as for the icon.
    try EnigmaSnapshot.save("mark", size: CGSize(width: 420, height: 170)) {
      HStack(alignment: .center, spacing: 26) {
        ForEach([14.0, 18, 24, 30], id: \.self) { side in
          VStack(spacing: 14) {
            EnigmaMark(style: .outline).frame(width: side, height: side)
            EnigmaMark(style: .filled).frame(width: side, height: side)
            SnapshotLabel(text: "\(Int(side))")
          }
        }
        EnigmaMark(style: .filled).frame(width: 120, height: 120)
      }
    }
  }

  /// A character in `state` after a short run with the events that state gets.
  private func pose(_ state: EnigmaCharacterState, on slot: Slot) -> EnigmaCharacterFrame {
    var model = makeModel(state, seed: 5, on: slot)
    let composer = CGPoint(x: slot.center.x + slot.size, y: slot.center.y + slot.size * 0.9)
    if state == .listening { model.attention = composer }
    let steps: Int = switch state {
    case .thinking: 162
    case .answering: 150
    default: 190
    }
    for step in 0..<steps {
      if state == .answering, step % 7 == 0 { model.token() }
      if state == .listening, step % 20 == 0 { model.key(towards: composer) }
      model.step(dt: 1.0 / 120)
    }
    return model.frame
  }

  private func motionFrames(cell: Double) -> [(label: String, frame: EnigmaCharacterFrame)] {
    func column(_ index: Int, _ y: Double) -> CGPoint { CGPoint(x: cell * (Double(index) + 0.5), y: y) }
    func fall(column index: Int, until stop: (EnigmaCharacterModel, Double) -> Bool) -> EnigmaCharacterFrame {
      var model = makeModel(seed: 5, on: Slot(center: column(index, 120), size: 92))
      for _ in 0..<120 { model.step(dt: 1.0 / 120) }
      model.fall(to: Slot(center: column(index, 240), size: 92))
      var time = 0.0
      while !stop(model, time), time < 2 {
        model.step(dt: 1.0 / 240)
        time += 1.0 / 240
      }
      return model.frame
    }
    var landedAt: Double?
    let landing = fall(column: 3) { model, time in
      if landedAt == nil, !model.isFalling, time > 0.2 { landedAt = time }
      return landedAt.map { time >= $0 + 0.11 } ?? false
    }
    var dragged = makeModel(seed: 5, on: Slot(center: column(4, 240), size: 92))
    for _ in 0..<120 { dragged.step(dt: 1.0 / 120) }
    dragged.beginDrag(at: column(4, 240))
    dragged.moveDrag(to: column(4, 170))
    for _ in 0..<30 { dragged.step(dt: 1.0 / 120) }
    var poked = makeModel(seed: 5, on: Slot(center: column(5, 240), size: 92))
    for _ in 0..<120 { poked.step(dt: 1.0 / 120) }
    poked.poke()
    for _ in 0..<7 { poked.step(dt: 1.0 / 120) }
    return [
      ("crouch", fall(column: 0) { _, time in time >= 0.1 }),
      ("hop", fall(column: 1) { model, time in model.fallPhase == .air && time >= 0.2 }),
      ("falling", fall(column: 2) { model, _ in model.fallPhase == .air && model.position.y > 205 }),
      ("landing", landing),
      ("dragged", dragged.frame),
      ("poked", poked.frame),
    ]
  }

  // MARK: Helpers

  /// Counts the outline's bumps: points farther from `center` than both neighbors.
  private func peakCount(_ points: [CGPoint], around center: CGPoint) -> Int {
    let distances = points.map { hypot($0.x - center.x, $0.y - center.y) }
    return distances.indices.filter { index in
      let previous = distances[(index + distances.count - 1) % distances.count]
      let next = distances[(index + 1) % distances.count]
      return distances[index] > previous && distances[index] >= next
    }.count
  }

  private func assertPixel(_ image: NSBitmapImageRep, at point: CGPoint, is expected: EnigmaColor, _ message: String,
                           file: StaticString = #filePath, line: UInt = #line) throws {
    // The bitmap is sRGB, the palette's space, so its bytes compare directly.
    // (`colorAt` would label them Generic RGB.)
    let scale = Double(image.pixelsWide) / image.size.width
    let data = try XCTUnwrap(image.bitmapData, file: file, line: line)
    let offset = Int(point.y * scale) * image.bytesPerRow + Int(point.x * scale) * image.bitsPerPixel / 8
    let channels = (0..<3).map { Double(data[offset + $0]) / 255 }
    XCTAssertEqual(channels[0], expected.red, accuracy: 0.02, message, file: file, line: line)
    XCTAssertEqual(channels[1], expected.green, accuracy: 0.02, message, file: file, line: line)
    XCTAssertEqual(channels[2], expected.blue, accuracy: 0.02, message, file: file, line: line)
  }
}

/// A window with one character slot, as a screen would mark it.
private struct StageHarness: View {
  let controller: EnigmaCharacterController
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    VStack(spacing: 0) {
      Color.clear.frame(height: 50)
      Color.clear.enigmaCharacterSlot(id: "main", size: 92)
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(palette.background.color)
    .enigmaCharacterStage(controller)
  }
}

@MainActor
private final class SlotToggle: ObservableObject {
  @Published var showsSlot = true
}

/// `StageHarness`, with a slot that can leave the layout.
private struct ToggledStageHarness: View {
  let controller: EnigmaCharacterController
  @ObservedObject var layout: SlotToggle
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    VStack(spacing: 0) {
      Color.clear.frame(height: 50)
      if layout.showsSlot {
        Color.clear.enigmaCharacterSlot(id: "main", size: 92)
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(palette.background.color)
    .enigmaCharacterStage(controller)
  }
}

/// Draws finished frames, in the environment's palette.
private struct CharacterFramesView: View {
  let frames: [EnigmaCharacterFrame]
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    Canvas { context, _ in
      for frame in frames { EnigmaCharacterRenderer.draw(frame, palette: palette, in: &context) }
    }
  }
}

private struct LabeledFrames: View {
  let frames: [EnigmaCharacterFrame]
  let labels: [String]
  let cell: Double

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .topLeading) {
        CharacterFramesView(frames: frames)
        ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
          SnapshotLabel(text: label).position(x: cell * (Double(index) + 0.5), y: proxy.size.height - 18)
        }
      }
    }
  }
}

private struct SnapshotLabel: View {
  let text: String
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    Text(text).font(EnigmaTypography.mono(11)).foregroundStyle(palette.textTertiary.color)
  }
}

private struct ThemeProbe: View {
  final class Box {
    var palette: EnigmaPalette?
    var colorScheme: ColorScheme?
  }

  let box: Box
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    box.palette = palette
    box.colorScheme = colorScheme
    return Color.clear
  }
}
