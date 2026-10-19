import CoreGraphics
import Foundation

// The lime character's simulation, ported from the `Glyph` function in
// docs/design/ui-revamp/main-window.html. Everything here is a value type with
// no drawing and no clock reads: the same seed, events, and steps always give
// the same frame. EnigmaCharacterStage.swift draws it and drives it.

/// What the character is doing. Screens set it on `EnigmaCharacterController`.
enum EnigmaCharacterState: String, CaseIterable, Sendable {
  case idle
  case listening
  case thinking
  case answering
  case error

  /// VoiceOver reads the character as one element with this label.
  static let accessibilityLabel = "Enigma"

  /// VoiceOver reads the state as the element's value.
  var accessibilityValue: String {
    switch self {
    case .idle: "Idle"
    case .listening: "Listening"
    case .thinking: "Thinking"
    case .answering: "Answering"
    case .error: "Something went wrong"
    }
  }

  var mode: EnigmaCharacterMode {
    switch self {
    case .idle: .idle
    case .listening: .listening
    case .thinking: .thinking
    case .answering: .answering
    case .error: .error
    }
  }
}

/// How the outline behaves in a state. This is the mockup's mode table.
struct EnigmaCharacterMode: Equatable, Sendable {
  /// Depth of the lobes, as a fraction of the body radius.
  let lobeDepth: Double
  /// How fast the outline turns, in radians per second.
  let spin: Double
  /// 0 for one hole, 1 for three orbiting holes.
  let split: Double
  /// Roughness of the hand-drawn outline, as a fraction of the body radius.
  let jitter: Double
  /// 1 for the error pose and color, 0 otherwise.
  let error: Double

  static let idle = Self(lobeDepth: 0.075, spin: 0.18, split: 0, jitter: 0.014, error: 0)
  static let listening = Self(lobeDepth: 0.06, spin: 0.05, split: 0, jitter: 0.016, error: 0)
  static let thinking = Self(lobeDepth: 0.2, spin: 1.4, split: 1, jitter: 0.018, error: 0)
  static let answering = Self(lobeDepth: 0.09, spin: 0.4, split: 0, jitter: 0.016, error: 0)
  static let error = Self(lobeDepth: 0.035, spin: 0, split: 0, jitter: 0.05, error: 1)
}

/// The character's other numbers. Lengths are in body radii unless they say points.
enum EnigmaCharacterTuning {
  /// The body radius as a fraction of the slot's side.
  static let bodyScale = 0.34
  static let restingLobes = 5
  /// The outline's turn at rest, as in the mockup. A lobe sits just right of
  /// the top, which reads hand-drawn rather than geometric. The character
  /// starts here and turns slowly from it.
  static let restRotation = 0.0
  static let thinkingLobes = [3, 4, 6, 7]
  /// The antenna's spring may stretch it to at most this many resting lengths.
  static let antennaStretchLimit = 1.25
  /// Seconds between lobe changes while thinking.
  static let lobeChangeInterval = 0.45
  static let outlinePoints = 72
  /// The hand-drawn outline is redrawn this many times a second.
  static let jitterRate = 12.0

  /// Pointer and attention targets farther than this, in points, are ignored.
  static let attentionRange = 320.0
  /// The antenna leans fully toward a target this far away, in points.
  static let leanRange = 300.0
  /// Tokens closer together than this, in seconds, share one ripple.
  static let tokenSpacing = 0.045

  static let crouchDuration = 0.13
  static let crouchSquash = 0.28
  /// The slowest hop, in points per second.
  static let minimumHopSpeed = 260.0
  /// The hop speed per point of body radius, in points per second.
  static let hopSpeedPerRadius = 9.0
  /// A slot less than this many points higher still gets a hop and a fall.
  static let glideThreshold = 4.0
  static let puffLifetime = 0.55
  static let impactLineDuration = 0.32
  /// The shadow fades out over this many points of height while falling.
  static let shadowFadeHeight = 260.0

  /// A drag shorter than this, in points, is a click.
  static let pokeDistance = 4.0
  /// Seconds a throw stays on the bouncier `throwRelease` spring.
  static let throwReleaseDuration = 0.9

  /// Without new events, the character is back to its idle loop after this many seconds.
  static let settleTime = 1.0

  // Springs that only the character uses. Position uses `EnigmaMotion.characterFollow`,
  // and squash and stretch use `EnigmaMotion.characterSquash`.
  static let growth = EnigmaSpring(response: 0.5, dampingFraction: 0.95)
  static let lobeDepth = EnigmaSpring(response: 0.5, dampingFraction: 1)
  static let lobeMorph = EnigmaSpring(response: 0.42, dampingFraction: 1)
  static let holeSplit = EnigmaSpring(response: 0.55, dampingFraction: 0.75)
  static let jitter = EnigmaSpring(response: 0.3, dampingFraction: 1)
  static let errorPose = EnigmaSpring(response: 0.5, dampingFraction: 1)
  static let attentionBump = EnigmaSpring(response: 0.3, dampingFraction: 0.6)
  static let gaze = EnigmaSpring(response: 0.4, dampingFraction: 0.8)
  static let antenna = EnigmaSpring(response: 0.36, dampingFraction: 0.42)
  static let tokenPulse = EnigmaSpring(response: 0.3, dampingFraction: 0.4)
  static let throwRelease = EnigmaSpring(response: 0.5, dampingFraction: 0.55)

  /// The error color fades in over this many seconds, once the error pose is half done.
  static let errorTintDuration = 0.4
}

/// A spring-driven value, stepped like the mockup's `sp()`: semi-implicit Euler
/// in 4 ms substeps, snapping to the target once it is close and slow.
struct EnigmaSpringState: Equatable, Sendable {
  var value: Double
  var velocity: Double = 0
  var target: Double
  var spring: EnigmaSpring

  init(_ value: Double, _ spring: EnigmaSpring) {
    self.value = value
    target = value
    self.spring = spring
  }

  var isSettled: Bool { value == target && velocity == 0 }

  mutating func snap(to value: Double) {
    self.value = value
    target = value
    velocity = 0
  }

  mutating func step(_ dt: Double, reduceMotion: Bool) {
    if reduceMotion {
      value = target
      velocity = 0
      return
    }
    guard dt > 0, !isSettled else { return }
    let stiffness = pow(2 * .pi / spring.response, 2)
    let damping = 4 * .pi * spring.dampingFraction / spring.response
    let substeps = max(1, Int((dt / 0.004).rounded(.up)))
    let h = dt / Double(substeps)
    for _ in 0..<substeps {
      velocity += (-stiffness * (value - target) - damping * velocity) * h
      value += velocity * h
    }
    if abs(value - target) < 0.0008, abs(velocity) < 0.008 {
      value = target
      velocity = 0
    }
  }

  /// Adds an event's push without letting a burst of events, for example while
  /// the window is hidden and nothing steps, build up an explosion.
  mutating func kick(_ amount: Double, limit: Double) {
    velocity = min(max(velocity + amount, -limit), limit)
  }
}

/// SplitMix64: small, fast, and the same on every Mac.
struct EnigmaCharacterRandom: RandomNumberGenerator, Sendable {
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  /// A number in 0..<1.
  mutating func unit() -> Double { Double(next() >> 11) * 0x1p-53 }
}

/// Everything the drawing needs for one frame, in the stage's points.
struct EnigmaCharacterFrame: Equatable, Sendable {
  struct Circle: Equatable, Sendable {
    var center: CGPoint
    var radius: Double
  }

  /// A quadratic curve.
  struct Curve: Equatable, Sendable {
    var start: CGPoint
    var control: CGPoint
    var end: CGPoint
  }

  struct Line: Equatable, Sendable {
    var start: CGPoint
    var end: CGPoint
  }

  /// The closed outline, sampled evenly by angle. Drawn as a smooth curve
  /// through the midpoints between neighbors.
  var outline: [CGPoint] = []
  /// One hole, or three while thinking. Drawn even-odd with the outline.
  var holes: [Circle] = []
  var legs: [Curve] = []
  var feet: [Circle] = []
  var antenna = Curve(start: .zero, control: .zero, end: .zero)
  var antennaBall = Circle(center: .zero, radius: 0)
  /// Where the antenna's length is measured from: the top of the body.
  var antennaBase: CGPoint = .zero
  /// The longest the antenna may stretch from its base: 1.25 × its resting length.
  var antennaLimit: Double = 0
  /// The contact shadow's ellipse.
  var shadow: CGRect = .zero
  /// A multiplier on the theme's shadow opacity: lighter while dragged or high in a fall.
  var shadowOpacity: Double = 0
  var puffs: [Circle] = []
  var impactLines: [Line] = []

  var lineWidth: Double = 0
  var legWidth: Double = 0
  var antennaBallLineWidth: Double = 0
  var puffLineWidth: Double = 0
  var impactLineWidth: Double = 0
  /// 0 draws the body in `characterBody`, 1 in `warning`.
  var errorTint: Double = 0

  var isEmpty: Bool { outline.isEmpty }

  /// The box the character's ink covers, strokes included. The shadow and
  /// landing effects are left out.
  var drawnBounds: CGRect {
    guard !isEmpty else { return .null }
    func box(_ points: [CGPoint], inset: Double) -> CGRect {
      guard let first = points.first else { return .null }
      var rect = CGRect(origin: first, size: .zero)
      for point in points.dropFirst() { rect = rect.union(CGRect(origin: point, size: .zero)) }
      return rect.insetBy(dx: -inset, dy: -inset)
    }
    func box(_ circle: Circle, inset: Double) -> CGRect {
      CGRect(x: circle.center.x - circle.radius, y: circle.center.y - circle.radius,
             width: circle.radius * 2, height: circle.radius * 2).insetBy(dx: -inset, dy: -inset)
    }
    func box(_ curve: Curve, inset: Double) -> CGRect {
      // A quadratic curve's box: its ends, plus its turning point on each axis.
      func extreme(_ a: Double, _ b: Double, _ c: Double) -> Double? {
        let denominator = a - 2 * b + c
        guard denominator != 0 else { return nil }
        let t = (a - b) / denominator
        guard t > 0, t < 1 else { return nil }
        return (1 - t) * (1 - t) * a + 2 * t * (1 - t) * b + t * t * c
      }
      var points = [curve.start, curve.end]
      if let x = extreme(curve.start.x, curve.control.x, curve.end.x) {
        points.append(CGPoint(x: x, y: curve.start.y))
      }
      if let y = extreme(curve.start.y, curve.control.y, curve.end.y) {
        points.append(CGPoint(x: curve.start.x, y: y))
      }
      return box(points, inset: inset)
    }
    // The outline curves through the midpoints of its points, so its points bound it.
    var rect = box(outline, inset: lineWidth / 2)
    for leg in legs { rect = rect.union(box(leg, inset: legWidth / 2)) }
    for foot in feet { rect = rect.union(box(foot, inset: 0)) }
    rect = rect.union(box(antenna, inset: lineWidth / 2))
    return rect.union(box(antennaBall, inset: antennaBallLineWidth / 2))
  }

  static let empty = EnigmaCharacterFrame()
}

struct EnigmaCharacterModel: Sendable {
  /// Where a slot sits, in the stage's points.
  struct Slot: Equatable, Sendable {
    var center: CGPoint
    /// The slot's side. The body radius is `size * EnigmaCharacterTuning.bodyScale`.
    var size: Double
    /// The slot sits in content that scrolls, like a chat reply. When it moves
    /// there, the character moves with it rigidly instead of trailing behind
    /// on `characterFollow`.
    var movesWithContent = false
  }

  enum FallPhase: Sendable { case crouch, air }

  private struct Fall: Sendable {
    var phase: FallPhase = .crouch
    var elapsed: Double = 0
    var y: Double
    var speed: Double = 0
  }

  private struct Drag: Sendable {
    var offset: CGVector
    var distance: Double = 0
  }

  private struct Ripple: Sendable {
    var angle: Double
    var strength: Double
  }

  private struct Puff: Sendable {
    var origin: CGPoint
    var angle: Double
    var speed: Double
    var radius: Double
    var age: Double = 0
  }

  private struct Impact: Sendable {
    var point: CGPoint
    var age: Double = 0
  }

  let seed: UInt64
  var state: EnigmaCharacterState = .idle {
    didSet { if state != oldValue { quietTime = 0 } }
  }
  /// Turns everything into instant moves and a still outline.
  var reduceMotion: Bool {
    didSet { if reduceMotion { fall = nil } }
  }
  /// A point the character pays attention to, like the composer while typing.
  var attention: CGPoint? {
    didSet { if attention != oldValue { quietTime = 0 } }
  }
  /// The pointer, which it leans toward when nothing else has its attention.
  var pointer: CGPoint? {
    didSet {
      guard pointer != oldValue, !reduceMotion, attention == nil, let pointer else { return }
      if distance(from: position, to: pointer) < EnigmaCharacterTuning.attentionRange { quietTime = 0 }
    }
  }
  private(set) var slot: Slot?
  /// Seconds of animation so far. It stands still under Reduce Motion.
  private(set) var time: Double = 0

  private var random: EnigmaCharacterRandom
  private var x = EnigmaSpringState(0, EnigmaMotion.characterFollow)
  private var y = EnigmaSpringState(0, EnigmaMotion.characterFollow)
  private var radius = EnigmaSpringState(10, EnigmaCharacterTuning.growth)
  private var squash = EnigmaSpringState(0, EnigmaMotion.characterSquash)
  private var lobeDepth = EnigmaSpringState(0.2, EnigmaCharacterTuning.lobeDepth)
  private var morph = EnigmaSpringState(0, EnigmaCharacterTuning.lobeMorph)
  private var split = EnigmaSpringState(0, EnigmaCharacterTuning.holeSplit)
  private var jitter = EnigmaSpringState(0.014, EnigmaCharacterTuning.jitter)
  private var error = EnigmaSpringState(0, EnigmaCharacterTuning.errorPose)
  private var bump = EnigmaSpringState(0, EnigmaCharacterTuning.attentionBump)
  private var gazeX = EnigmaSpringState(0, EnigmaCharacterTuning.gaze)
  private var gazeY = EnigmaSpringState(0, EnigmaCharacterTuning.gaze)
  private var tipX = EnigmaSpringState(0, EnigmaCharacterTuning.antenna)
  private var tipY = EnigmaSpringState(0, EnigmaCharacterTuning.antenna)
  private var pulse = EnigmaSpringState(0, EnigmaCharacterTuning.tokenPulse)

  private(set) var lobes = EnigmaCharacterTuning.restingLobes
  private(set) var nextLobes = EnigmaCharacterTuning.restingLobes
  private var lobeTimer: Double = 0
  private var rotation = EnigmaCharacterTuning.restRotation
  private var aim: Double = 0
  private var ripples: [Ripple] = []
  private var puffs: [Puff] = []
  private var impact: Impact?
  private var fall: Fall?
  private var drag: Drag?
  private var throwTimer: Double = 0
  private var errorTint: Double = 0
  private var lastTokenTime = -Double.infinity
  private var quietTime: Double = 0

  init(seed: UInt64, reduceMotion: Bool = false) {
    self.seed = seed
    self.reduceMotion = reduceMotion
    random = EnigmaCharacterRandom(seed: seed ^ 0xC0FF_EE15_E141_6A00)
  }

  // MARK: Reading the model

  var position: CGPoint { CGPoint(x: x.value, y: y.value) }
  var velocity: CGVector { CGVector(dx: x.velocity, dy: y.velocity) }
  /// The body radius in points.
  var bodyRadius: Double { radius.value }
  var isFalling: Bool { fall != nil }
  var fallPhase: FallPhase? { fall?.phase }
  var isDragging: Bool { drag != nil }
  /// How far the lobes have morphed from `lobes` to `nextLobes`, from 0 to 1.
  var lobeMorph: Double { morph.value }
  var holeSplit: Double { split.value }
  var squashAmount: Double { squash.value }
  var landingEffectCount: Int { puffs.count + (impact == nil ? 0 : 1) }

  /// Whether a click or drag at `point` grabs the character.
  func contains(_ point: CGPoint) -> Bool {
    distance(from: position, to: point) < radius.value * 1.25
  }

  /// True while something needs every display frame: a fall, a drag, a throw,
  /// ripples, landing effects, thinking, or the settling after an event.
  var needsEveryFrame: Bool {
    if reduceMotion { return false }
    if fall != nil || drag != nil || throwTimer > 0 || !ripples.isEmpty || !puffs.isEmpty || impact != nil {
      return true
    }
    if state == .thinking || morph.target != 0 || quietTime < EnigmaCharacterTuning.settleTime { return true }
    let springs = [x, y, radius, squash, lobeDepth, morph, split, jitter, error, bump, gazeX, gazeY, pulse]
    return !springs.allSatisfy(\.isSettled) || (errorTint != 0 && errorTint != 1)
  }

  /// True when nothing moves at all. Without Reduce Motion, the idle loop
  /// (the slow turn, the bob, and the hand-drawn outline) always runs.
  var isAtRest: Bool { reduceMotion && fall == nil && drag == nil }

  // MARK: Slots

  /// Puts the character on `slot`. Without `instantly`, it glides there.
  mutating func place(at slot: Slot, instantly: Bool) {
    self.slot = slot
    fall = nil
    quietTime = 0
    guard instantly || reduceMotion else { return }
    x.snap(to: slot.center.x)
    y.snap(to: slot.center.y)
    radius.snap(to: slot.size * EnigmaCharacterTuning.bodyScale)
    settleAntenna()
  }

  /// Moves to a new slot: a crouch, hop, and fall if it is lower, or a glide if it is higher.
  /// While it is being dragged, only the slot changes: letting go springs it there.
  mutating func fall(to slot: Slot) {
    let start = y.value
    self.slot = slot
    quietTime = 0
    if drag != nil {
      fall = nil
    } else if reduceMotion {
      place(at: slot, instantly: true)
    } else if slot.center.y < start - EnigmaCharacterTuning.glideThreshold {
      fall = nil
    } else {
      fall = Fall(y: start)
    }
  }

  /// Follows the current slot when layout moves it. A slot that moves with its
  /// content carries the character along by the same distance, so it never
  /// trails a scrolling list; a fall or a drag in progress still finds the slot
  /// on its own.
  mutating func updateSlot(_ slot: Slot) {
    guard slot != self.slot else { return }
    if slot.movesWithContent, let previous = self.slot, fall == nil, drag == nil {
      x.value += slot.center.x - previous.center.x
      y.value += slot.center.y - previous.center.y
      x.target = slot.center.x
      y.target = slot.center.y
    }
    self.slot = slot
    quietTime = 0
  }

  // MARK: Events
  //
  // Each event returns whether it changed anything. Under Reduce Motion the
  // character stays still, so they do nothing and return false.

  /// A typing nudge: a bump toward `point`, a little squash, and a flick of the antenna.
  @discardableResult
  mutating func key(towards point: CGPoint) -> Bool {
    guard !reduceMotion else { return false }
    aim = atan2(point.y - y.value, point.x - x.value)
    bump.kick(3.2, limit: 9.6)
    squash.kick(1.4, limit: 14)
    tipX.kick((random.unit() - 0.5) * 160, limit: 600)
    quietTime = 0
    return true
  }

  /// One ripple and a small bounce per streamed token.
  @discardableResult
  mutating func token() -> Bool {
    guard !reduceMotion, time - lastTokenTime >= EnigmaCharacterTuning.tokenSpacing else { return false }
    lastTokenTime = time
    ripples.append(Ripple(angle: random.unit() * 2 * .pi, strength: 1))
    pulse.kick(3, limit: 9)
    quietTime = 0
    return true
  }

  /// A click: a wobble.
  @discardableResult
  mutating func poke() -> Bool {
    guard !reduceMotion else { return false }
    squash.kick(7, limit: 14)
    tipX.kick((random.unit() - 0.5) * 500, limit: 600)
    tipY.kick(-200, limit: 600)
    jitter.value = 0.06
    quietTime = 0
    return true
  }

  /// Grows the character from nothing, as on the welcome screen.
  @discardableResult
  mutating func assemble() -> Bool {
    guard !reduceMotion else { return false }
    radius.value = 0
    radius.velocity = 0
    squash.value = -0.4
    lobeDepth.value = 0.6
    jitter.value = 0.08
    quietTime = 0
    return true
  }

  mutating func beginDrag(at point: CGPoint) {
    drag = Drag(offset: CGVector(dx: x.value - point.x, dy: y.value - point.y))
    fall = nil
    quietTime = 0
  }

  mutating func moveDrag(to point: CGPoint) {
    guard var drag else { return }
    let next = CGPoint(x: point.x + drag.offset.dx, y: point.y + drag.offset.dy)
    drag.distance += distance(from: position, to: next)
    self.drag = drag
    x.snap(to: next.x)
    y.snap(to: next.y)
    quietTime = 0
  }

  /// Lets go. A short drag is a click; otherwise it flies with `velocity`, in
  /// points per second, and springs back to its slot.
  mutating func endDrag(velocity: CGVector) {
    guard let drag else { return }
    self.drag = nil
    quietTime = 0
    guard drag.distance >= EnigmaCharacterTuning.pokeDistance else {
      poke()
      return
    }
    x.velocity = velocity.dx
    y.velocity = velocity.dy
    if let slot {
      x.target = slot.center.x
      y.target = slot.center.y
    }
    x.spring = EnigmaCharacterTuning.throwRelease
    y.spring = EnigmaCharacterTuning.throwRelease
    throwTimer = EnigmaCharacterTuning.throwReleaseDuration
  }

  // MARK: Stepping

  /// Advances the simulation by `dt` seconds.
  mutating func step(dt: Double) {
    let dt = max(0, dt)
    let moving = !reduceMotion
    if moving { time += dt }
    quietTime += dt
    let mode = state.mode
    lobeDepth.target = mode.lobeDepth
    split.target = mode.split
    jitter.target = mode.jitter
    error.target = mode.error
    if moving { rotation += mode.spin * dt }

    stepLobes(dt, moving: moving)

    ripples = ripples.compactMap { ripple in
      let strength = ripple.strength * exp(-dt * 4)
      return strength > 0.03 ? Ripple(angle: ripple.angle + dt * 2, strength: strength) : nil
    }

    stepAttention(dt)
    stepFall(dt)

    stepSprings(dt)

    if throwTimer > 0 {
      throwTimer -= dt
      if throwTimer <= 0 || reduceMotion {
        throwTimer = 0
        x.spring = EnigmaMotion.characterFollow
        y.spring = EnigmaMotion.characterFollow
      }
    }

    let tintTarget: Double = error.value > 0.5 ? 1 : 0
    if reduceMotion {
      errorTint = tintTarget
    } else if errorTint < tintTarget {
      errorTint = min(tintTarget, errorTint + dt / EnigmaCharacterTuning.errorTintDuration)
    } else if errorTint > tintTarget {
      errorTint = max(tintTarget, errorTint - dt / EnigmaCharacterTuning.errorTintDuration)
    }

    for index in puffs.indices { puffs[index].age += dt }
    puffs.removeAll { $0.age >= EnigmaCharacterTuning.puffLifetime }
    if var impact {
      impact.age += dt
      self.impact = impact.age < EnigmaCharacterTuning.impactLineDuration ? impact : nil
    }

    if reduceMotion {
      settleAntenna()
    } else {
      aimAntenna()
    }
  }

  private mutating func stepSprings(_ dt: Double) {
    let still = reduceMotion
    x.step(dt, reduceMotion: still)
    y.step(dt, reduceMotion: still)
    radius.step(dt, reduceMotion: still)
    squash.step(dt, reduceMotion: still)
    lobeDepth.step(dt, reduceMotion: still)
    morph.step(dt, reduceMotion: still)
    split.step(dt, reduceMotion: still)
    jitter.step(dt, reduceMotion: still)
    error.step(dt, reduceMotion: still)
    bump.step(dt, reduceMotion: still)
    gazeX.step(dt, reduceMotion: still)
    gazeY.step(dt, reduceMotion: still)
    tipX.step(dt, reduceMotion: still)
    tipY.step(dt, reduceMotion: still)
    pulse.step(dt, reduceMotion: still)
  }

  private mutating func stepLobes(_ dt: Double, moving: Bool) {
    if morph.target == 1, morph.value > 0.95 {
      lobes = nextLobes
      morph.snap(to: 0)
    }
    if state == .thinking, moving {
      lobeTimer += dt
      if morph.target == 0, lobeTimer > EnigmaCharacterTuning.lobeChangeInterval {
        lobeTimer = 0
        let choices = EnigmaCharacterTuning.thinkingLobes.filter { $0 != lobes }
        nextLobes = choices[Int(random.unit() * Double(choices.count))]
        morph.target = 1
      }
    } else if morph.target == 0, lobes != EnigmaCharacterTuning.restingLobes {
      nextLobes = EnigmaCharacterTuning.restingLobes
      morph.target = 1
    }
  }

  private mutating func stepAttention(_ dt: Double) {
    let focus = attention ?? (reduceMotion ? nil : pointer)
    guard let focus, drag == nil else {
      bump.target = 0
      gazeX.target = 0
      gazeY.target = 0
      return
    }
    let dx = focus.x - x.value
    let dy = focus.y - y.value
    let distance = hypot(dx, dy)
    let range = EnigmaCharacterTuning.attentionRange
    guard distance < range, distance > radius.value * 0.8 else {
      bump.target = 0
      gazeX.target = 0
      gazeY.target = 0
      return
    }
    let direction = atan2(dy, dx)
    aim += reduceMotion ? angleDifference(direction, aim) : angleDifference(direction, aim) * min(1, dt * 8)
    bump.target = attention != nil ? 0.6 : 0.35 * clampUnit(1 - distance / range) + 0.15
    gazeX.target = dx / distance * 0.24
    gazeY.target = dy / distance * 0.24
  }

  private mutating func stepFall(_ dt: Double) {
    guard let slot else { return }
    guard var fall, drag == nil else {
      if drag == nil {
        x.target = slot.center.x
        y.target = slot.center.y
        radius.target = slot.size * EnigmaCharacterTuning.bodyScale
        squash.target = 0
      }
      return
    }
    fall.elapsed += dt
    x.target = slot.center.x
    radius.target = slot.size * EnigmaCharacterTuning.bodyScale
    switch fall.phase {
    case .crouch:
      squash.target = EnigmaCharacterTuning.crouchSquash
      if fall.elapsed > EnigmaCharacterTuning.crouchDuration {
        fall.phase = .air
        fall.speed = -max(EnigmaCharacterTuning.minimumHopSpeed, radius.value * EnigmaCharacterTuning.hopSpeedPerRadius)
        squash.target = 0
        squash.velocity = -5
      }
    case .air:
      fall.speed += EnigmaMotion.characterGravity * dt
      fall.y += fall.speed * dt
      // Stretch with speed in the air, and squash on landing.
      squash.value = -min(0.42, abs(fall.speed) / 2400)
      squash.velocity = 0
      if fall.y >= slot.center.y, fall.speed > 0 {
        land(on: slot, speed: fall.speed)
        return
      }
    }
    y.snap(to: fall.y)
    self.fall = fall
  }

  private mutating func land(on slot: Slot, speed: Double) {
    squash.value = min(0.55, speed / 1500)
    squash.velocity = 0
    let size = radius.target
    let ground = CGPoint(x: x.value, y: slot.center.y + size * 1.18)
    impact = Impact(point: ground)
    for index in 0..<6 {
      let left = index < 3
      let angle = (left ? Double.pi : 0) + (left ? -1 : 1) * (0.05 + Double(index % 3) * 0.22)
      puffs.append(Puff(
        origin: CGPoint(x: ground.x + cos(angle) * size * 0.9, y: ground.y - 2),
        angle: angle,
        speed: size * (3.2 + Double(index % 3)),
        radius: size * (0.18 + Double(index % 3) * 0.06)
      ))
    }
    fall = nil
    y.snap(to: slot.center.y)
  }

  /// Puts the antenna straight where it wants to be, with no spring.
  private mutating func settleAntenna() {
    aimAntenna()
    tipX.snap(to: tipX.target)
    tipY.snap(to: tipY.target)
  }

  /// Points the antenna's spring at where the antenna wants to be this frame.
  private mutating func aimAntenna() {
    guard radius.value >= 1 else { return }
    let outline = OutlineShape(self)
    let pose = Pose(self, outline: outline)
    let ang = antennaAngle(centerX: pose.centerX)
    tipX.target = pose.centerX + cos(ang) * pose.antennaLength
    tipY.target = pose.antennaBaseY + sin(ang) * pose.antennaLength
  }

  private func antennaAngle(centerX: Double) -> Double {
    var lean = 0.0
    if let focus = attention ?? (reduceMotion ? nil : pointer), drag == nil {
      let offset = focus.x - centerX
      lean = clampUnit(abs(offset) / EnigmaCharacterTuning.leanRange) * (offset < 0 ? -1 : 1) * 0.45
    }
    let wiggle = state == .thinking && !reduceMotion ? sin(time * 6) * 0.35 : 0
    return -.pi / 2 + lean + error.value * 1.9 + wiggle
  }

  // MARK: Frame

  /// The geometry to draw for the current state.
  var frame: EnigmaCharacterFrame {
    let s = radius.value
    guard s >= 1 else { return .empty }
    let outline = OutlineShape(self)
    let pose = Pose(self, outline: outline)
    var frame = EnigmaCharacterFrame()

    let count = EnigmaCharacterTuning.outlinePoints
    frame.outline.reserveCapacity(count)
    for index in 0..<count {
      let angle = Double(index) / Double(count) * 2 * .pi
      frame.outline.append(pose.point(at: angle, radius: outline.radius(at: angle) * s))
    }

    let holeCenter = CGPoint(x: pose.centerX + gazeX.value * s, y: pose.centerY + pose.lift + gazeY.value * s)
    let holeRadius = s * (0.2 - 0.05 * error.value) * (1 + pulse.value * 0.15) * pose.holeScale
    let k = split.value
    if k == 0 {
      frame.holes = [.init(center: holeCenter, radius: holeRadius)]
    } else {
      // Three orbiting holes. Where two overlap, the even-odd fill closes them again.
      for index in 0..<3 {
        let angle = -time * 2.4 + Double(index) * 2 * .pi / 3
        let orbit = s * 0.36 * k
        frame.holes.append(.init(
          center: CGPoint(x: holeCenter.x + cos(angle) * orbit, y: holeCenter.y + sin(angle) * orbit * pose.scaleY),
          radius: holeRadius * (1 - 0.42 * k)
        ))
      }
    }

    frame.lineWidth = pose.lineWidth
    frame.legWidth = pose.lineWidth * 0.85
    frame.antennaBallLineWidth = pose.lineWidth * 0.9
    frame.puffLineWidth = max(1.3 * pose.thinning, s * 0.05)
    frame.impactLineWidth = max(1.4 * pose.thinning, s * 0.06)
    frame.errorTint = errorTint

    let airborne = fall?.phase == .air || drag != nil
    let landing = fall?.phase == .air ? slot : nil
    let groundY = landing.map { $0.center.y + radius.target * 1.18 } ?? (y.value + s * 1.18)
    for (index, side) in [-1.0, 0, 1].enumerated() {
      let hipAngle = Double.pi / 2 + side * 0.62
      let hip = pose.point(at: hipAngle, radius: outline.radius(at: hipAngle) * s * 0.8)
      var foot = CGPoint(x: pose.centerX + side * s * (0.78 + 0.35 * max(0, pose.squash)), y: groundY)
      if airborne {
        foot = CGPoint(x: hip.x + side * s * 0.2, y: hip.y + s * (0.48 + 0.1 * abs(side)))
      } else if !reduceMotion {
        if state == .thinking, Int(time * 7) % 3 == index { foot.y -= s * 0.16 }
        if state == .answering { foot.y -= pulse.value * s * 0.25 * (index == 1 ? 1 : 0.3) }
      }
      let control = CGPoint(x: (hip.x + foot.x) / 2 + side * s * 0.28, y: (hip.y + foot.y) / 2 - s * 0.05)
      frame.legs.append(.init(start: hip, control: control, end: foot))
      frame.feet.append(.init(center: CGPoint(x: foot.x + side * s * 0.04, y: foot.y),
                              radius: max(1.3 * pose.thinning, s * 0.07)))
    }

    let base = CGPoint(x: pose.centerX, y: pose.antennaBaseY)
    let dx = tipX.value - base.x
    let dy = tipY.value - base.y
    let length = hypot(dx, dy)
    frame.antennaBase = base
    frame.antennaLimit = pose.antennaLength * EnigmaCharacterTuning.antennaStretchLimit
    // The antenna's spring may overshoot; its length is capped so a throw can't stretch it.
    let reach = length > 0 ? min(length, frame.antennaLimit) / length : 0
    let tip = CGPoint(x: base.x + dx * reach, y: base.y + dy * reach)
    frame.antenna = .init(start: CGPoint(x: base.x, y: base.y + pose.lineWidth),
                          control: CGPoint(x: base.x, y: base.y - pose.antennaLength * 0.45), end: tip)
    frame.antennaBall = .init(center: tip, radius: s * 0.15 * (1 + pulse.value * 0.3))

    let shadowFade = landing.map { clampUnit(1 - ($0.center.y - y.value) / EnigmaCharacterTuning.shadowFadeHeight) } ?? 1
    let shadowScale = landing != nil ? 0.4 + 0.6 * shadowFade : 1 - pose.bob / (s * 0.4) * 0.15
    let shadowCenter = CGPoint(x: landing.map { Double($0.center.x) } ?? pose.centerX, y: groundY + s * 0.02)
    let shadowWidth = s * 0.95 * shadowScale * pose.scaleX
    let shadowHeight = s * 0.16 * shadowScale
    frame.shadow = CGRect(x: shadowCenter.x - shadowWidth, y: shadowCenter.y - shadowHeight,
                          width: shadowWidth * 2, height: shadowHeight * 2)
    frame.shadowOpacity = drag != nil ? 0.05 / 0.13 : (landing != nil ? shadowFade : 1)

    for puff in puffs {
      let progress = clampUnit(puff.age / EnigmaCharacterTuning.puffLifetime)
      let eased = 1 - pow(1 - progress, 3)
      let radius = puff.radius * sin(.pi * progress)
      guard radius > 0.4 else { continue }
      frame.puffs.append(.init(center: CGPoint(x: puff.origin.x + cos(puff.angle) * puff.speed * 0.35 * eased,
                                               y: puff.origin.y - s * 0.3 * eased),
                               radius: radius))
    }

    if let impact {
      let progress = impact.age / EnigmaCharacterTuning.impactLineDuration
      let offset = s * (1.25 + progress * 0.5)
      let length = s * 0.38 * (1 - progress)
      for side in [-1.0, 1] {
        for rise in [-0.35, 0.15] {
          let start = CGPoint(x: impact.point.x + side * offset, y: impact.point.y - s * 0.25 + rise * s)
          frame.impactLines.append(.init(start: start, end: CGPoint(x: start.x + side * length,
                                                                     y: start.y + rise * length * 0.8 - length * 0.2)))
        }
      }
    }
    return frame
  }

  // MARK: Still pose

  /// The character at rest on `slot`: upright, with no jitter, bob,
  /// attention, or motion. `EnigmaMark` and the app icon draw this pose.
  static func stillFrame(on slot: Slot) -> EnigmaCharacterFrame {
    var model = EnigmaCharacterModel(seed: 0, reduceMotion: true)
    model.place(at: slot, instantly: true)
    model.lobeDepth.snap(to: EnigmaCharacterMode.idle.lobeDepth)
    model.jitter.snap(to: 0)
    model.settleAntenna()
    return model.frame
  }

  /// The still pose, scaled and centered so its drawn bounds just fit `rect`.
  /// Without legs, the body grows to use the room they took, which reads
  /// better at mark sizes. `lineWidth` sets the outline's width instead of the
  /// size-based one, with the legs and antenna ball in proportion, for icons
  /// whose strokes must match their neighbors'. The porthole grows by the
  /// extra width, so its opening stays the same size.
  static func stillFrame(fitting rect: CGRect, legs: Bool = true, lineWidth: Double? = nil) -> EnigmaCharacterFrame {
    guard rect.width > 0, rect.height > 0 else { return .empty }
    func pose(_ slot: Slot) -> EnigmaCharacterFrame {
      var frame = stillFrame(on: slot)
      frame.shadowOpacity = 0
      if !legs {
        frame.legs = []
        frame.feet = []
      }
      if let lineWidth, frame.lineWidth > 0 {
        let scale = lineWidth / frame.lineWidth
        for index in frame.holes.indices { frame.holes[index].radius += (lineWidth - frame.lineWidth) / 2 }
        frame.lineWidth = lineWidth
        frame.legWidth *= scale
        frame.antennaBallLineWidth *= scale
      }
      return frame
    }
    var slot = Slot(center: CGPoint(x: rect.midX, y: rect.midY), size: min(rect.width, rect.height))
    // Line widths don't scale linearly with size, so fit twice.
    for _ in 0..<2 {
      let bounds = pose(slot).drawnBounds
      guard bounds.width > 0, bounds.height > 0 else { return .empty }
      let scale = min(rect.width / bounds.width, rect.height / bounds.height)
      let offset = CGVector(dx: slot.center.x - bounds.midX, dy: slot.center.y - bounds.midY)
      slot = Slot(center: CGPoint(x: rect.midX + offset.dx * scale, y: rect.midY + offset.dy * scale),
                  size: slot.size * scale)
    }
    return pose(slot)
  }

  /// The radius of the outline at `angle`, in body radii. Exposed for tests.
  func outlineRadius(at angle: Double) -> Double { OutlineShape(self).radius(at: angle) }

  // MARK: Shape

  /// The outline's radius by angle, with this frame's values captured once.
  private struct OutlineShape {
    let lobeDepth: Double
    let morph: Double
    let lobes: Double
    let nextLobes: Double
    let rotation: Double
    let bump: Double
    let aim: Double
    let ripples: [Ripple]
    let jitter: Double
    let wobble: (phase: SIMD3<Double>, weight: SIMD3<Double>)
    let pulse: Double

    init(_ model: EnigmaCharacterModel) {
      lobeDepth = model.lobeDepth.value
      morph = model.morph.value
      lobes = Double(model.lobes)
      nextLobes = Double(model.nextLobes)
      rotation = model.rotation
      bump = model.bump.value
      aim = model.aim
      ripples = model.ripples
      jitter = model.jitter.value * EnigmaCharacterModel.jitterScale(forRadius: model.radius.value)
      wobble = EnigmaCharacterModel.wobble(seed: model.seed, frame: Int((model.time * EnigmaCharacterTuning.jitterRate).rounded(.down)))
      pulse = model.pulse.value
    }

    func radius(at angle: Double) -> Double {
      var r = 1 + lobeDepth * ((1 - morph) * cos(lobes * (angle - rotation)) + morph * cos(nextLobes * (angle - rotation)))
      if bump != 0 {
        let d = angleDifference(angle, aim)
        r += bump * 0.22 * exp(-d * d / 0.18)
      }
      for ripple in ripples {
        let d = angleDifference(angle, ripple.angle)
        r += 0.09 * ripple.strength * exp(-d * d / 0.05)
      }
      if jitter != 0 {
        r += jitter * (sin(angle * 3 + wobble.phase.x) * wobble.weight.x
          + sin(angle * 5 + wobble.phase.y) * wobble.weight.y
          + sin(angle * 8 + wobble.phase.z) * wobble.weight.z)
      }
      return r * (1 + pulse * 0.05)
    }
  }

  /// The hand-drawn wobble for one jitter frame. Keyed on the frame index, so a
  /// given time always draws the same outline.
  static func wobble(seed: UInt64, frame: Int) -> (phase: SIMD3<Double>, weight: SIMD3<Double>) {
    var random = EnigmaCharacterRandom(seed: seed ^ (UInt64(bitPattern: Int64(frame)) &* 0xD1B5_4A32_D192_ED03))
    let phase = SIMD3(random.unit(), random.unit(), random.unit()) * (2 * .pi)
    let weight = SIMD3(0.6 + random.unit() * 0.6, 0.4 + random.unit() * 0.6, 0.2 + random.unit() * 0.4)
    return (phase, weight)
  }

  /// At chat size, a full-strength wobble reads as noise, so it fades out
  /// below a 46 pt slot, to 60% at 30 pt.
  static func jitterScale(forRadius radius: Double) -> Double {
    0.6 + 0.4 * clampUnit((radius - 10) / 5.6)
  }

  /// Where the body sits this frame, after the bob and the squash.
  private struct Pose {
    let centerX: Double
    let centerY: Double
    let scaleX: Double
    let scaleY: Double
    /// Squashing lowers the body so it stays on its feet.
    let lift: Double
    let bob: Double
    let squash: Double
    let lineWidth: Double
    /// `lineWidth` over the mockup's width. Below 1 only at small sizes.
    let thinning: Double
    /// Holes open a little wider at small sizes, so they don't close up.
    let holeScale: Double
    let antennaBaseY: Double
    let antennaLength: Double

    init(_ model: EnigmaCharacterModel, outline: OutlineShape) {
      let s = model.radius.value
      let error = model.error.value
      let breathing = model.reduceMotion ? 0 : sin(model.time * 1.7) * s * 0.05 * (1 - error)
      bob = model.fall != nil || model.drag != nil ? 0 : breathing - error * s * 0.06
      // Limit the squash so stacked pokes can't turn the body inside out.
      squash = min(max(model.squash.value, -0.6), 0.75)
      centerX = model.x.value
      centerY = model.y.value + bob
      scaleX = 1 + squash * 0.55
      scaleY = 1 - squash * 0.55
      lift = (1 - scaleY) * s * 0.9
      let width = EnigmaCharacterModel.lineWidth(forRadius: s)
      lineWidth = width
      thinning = width / max(1.6, s * 0.075)
      holeScale = 1 + (1 - thinning) * 0.8
      antennaBaseY = centerY - outline.radius(at: -.pi / 2) * s * scaleY + lift + width * 0.3
      antennaLength = s * 0.8
    }

    func point(at angle: Double, radius: Double) -> CGPoint {
      CGPoint(x: centerX + cos(angle) * radius * scaleX, y: centerY + sin(angle) * radius * scaleY + lift)
    }
  }

  /// The outline's width. The mockup's 1.6 pt minimum turns a 30 pt character
  /// into a blob, so small sizes thin out toward 1.2 pt at 30 pt.
  static func lineWidth(forRadius radius: Double) -> Double {
    max(radius * 0.075, min(1.6, 0.6 + radius * 0.06))
  }
}

/// The signed difference between two angles, in -π...π.
func angleDifference(_ a: Double, _ b: Double) -> Double {
  (a - b).remainder(dividingBy: 2 * .pi)
}

private func clampUnit(_ value: Double) -> Double { min(max(value, 0), 1) }

private func distance(from a: CGPoint, to b: CGPoint) -> Double { hypot(b.x - a.x, b.y - a.y) }
