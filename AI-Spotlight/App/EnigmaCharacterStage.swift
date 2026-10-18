import AppKit
import Combine
import SwiftUI

// The character's place in a window. Screens mark slots with
// `.enigmaCharacterSlot(id:size:)` and hold an `EnigmaCharacterController`; one
// `.enigmaCharacterStage(_:)` at the window root draws the character at the
// active slot and moves it between slots.

/// Names a place where the character can sit.
struct EnigmaCharacterSlotID: Hashable, Sendable, ExpressibleByStringLiteral {
  let rawValue: String

  init(_ rawValue: String) { self.rawValue = rawValue }
  init(stringLiteral value: String) { rawValue = value }
}

/// Names something the character can pay attention to, like the composer.
struct EnigmaCharacterTargetID: Hashable, Sendable, ExpressibleByStringLiteral {
  let rawValue: String

  init(_ rawValue: String) { self.rawValue = rawValue }
  init(stringLiteral value: String) { rawValue = value }
}

/// How the character gets to a new slot.
enum EnigmaCharacterTransition: Sendable {
  /// A crouch, hop, and fall to a lower slot, or a glide to a higher one.
  case automatic
  /// A glide on `characterFollow`, whichever way.
  case glide
  /// No motion.
  case instant
}

/// How often the stage redraws the character.
enum EnigmaCharacterPacing: Equatable, Sendable {
  case paused
  /// Only the idle loop moves: the slow turn, the bob, and the 12 fps outline.
  case ambient
  /// Every display frame, for falls, drags, ripples, and settling springs.
  case live

  /// The idle loop redraws on twos: 24 fps, twice the outline's 12 fps.
  static let ambientInterval = 1.0 / 24

  static func resolve(windowVisible: Bool, reduceMotion: Bool, isAtRest: Bool, needsEveryFrame: Bool) -> Self {
    if !windowVisible || reduceMotion || isAtRest { return .paused }
    return needsEveryFrame ? .live : .ambient
  }

  /// A window counts as visible when it is on screen and not fully covered.
  @MainActor static func isVisible(_ window: NSWindow) -> Bool {
    window.isVisible && window.occlusionState.contains(.visible)
  }
}

/// The character a window shows. Screens hold it to set the state, move the
/// character between slots, and send events, such as `token()` for each
/// streamed token or `key()` for each keystroke.
@MainActor
final class EnigmaCharacterController: ObservableObject {
  /// What the simulation needs from the stage's timeline.
  enum Activity: Equatable, Sendable {
    case rest
    case ambient
    case live
  }

  @Published var state: EnigmaCharacterState {
    didSet {
      model.state = state
      wake()
    }
  }

  /// What the character pays attention to, like the composer while someone types.
  @Published var attention: EnigmaCharacterTargetID? {
    didSet { wake() }
  }

  /// The slot the character is at or heading to.
  @Published private(set) var activeSlot: EnigmaCharacterSlotID?
  @Published private(set) var activity: Activity = .live

  private(set) var model: EnigmaCharacterModel
  /// Whether the character is drawn: its slot has been laid out and is still there.
  private(set) var isPresent = false
  private var pendingTransition: EnigmaCharacterTransition?
  private var targets: [EnigmaCharacterTargetID: CGPoint] = [:]
  private var lastFrameTime: TimeInterval?
  private var activityRefreshScheduled = false

  init(state: EnigmaCharacterState = .idle, seed: UInt64 = .random(in: .min ... .max)) {
    self.state = state
    model = EnigmaCharacterModel(seed: seed)
    model.state = state
  }

  /// Sends the character to `slot`. It appears there instantly the first time.
  func move(to slot: EnigmaCharacterSlotID, _ transition: EnigmaCharacterTransition = .automatic) {
    activeSlot = slot
    pendingTransition = transition
    wake()
  }

  /// A typing nudge toward `target`, or toward `attention` when `target` is nil.
  func key(towards target: EnigmaCharacterTargetID? = nil) {
    guard let id = target ?? attention, let point = targets[id] else { return }
    if model.key(towards: point) { wake() }
  }

  /// A ripple for a streamed token. Tokens faster than about 22 a second share ripples.
  func token() {
    if model.token() { wake() }
  }

  /// A wobble, as when someone clicks the character.
  func poke() {
    if model.poke() { wake() }
  }

  /// Grows the character from nothing at its slot, as on the welcome screen.
  func assemble() {
    if model.assemble() { wake() }
  }

  // MARK: Stage

  /// Brings the simulation up to `time` with the current layout, and returns what to draw.
  func frame(at time: TimeInterval, slots: [EnigmaCharacterSlotID: EnigmaCharacterModel.Slot],
             targets: [EnigmaCharacterTargetID: CGPoint], reduceMotion: Bool) -> EnigmaCharacterFrame {
    model.reduceMotion = reduceMotion
    self.targets = targets
    model.attention = attention.flatMap { targets[$0] }
    sync(slots)
    // Long gaps, like a paused timeline resuming, advance at most one 20 fps frame.
    let dt = lastFrameTime.map { min(0.05, max(0, time - $0)) } ?? 0
    lastFrameTime = time
    model.step(dt: dt)
    refreshActivityLater()
    return isPresent ? model.frame : .empty
  }

  func pointerMoved(to point: CGPoint?) {
    model.pointer = point
    if model.needsEveryFrame { wake() }
  }

  func contains(_ point: CGPoint) -> Bool { isPresent && model.contains(point) }

  func beginDrag(at point: CGPoint) {
    model.beginDrag(at: point)
    wake()
  }

  func moveDrag(to point: CGPoint) { model.moveDrag(to: point) }

  func endDrag(velocity: CGVector) {
    model.endDrag(velocity: velocity)
    wake()
  }

  private func sync(_ slots: [EnigmaCharacterSlotID: EnigmaCharacterModel.Slot]) {
    guard let id = activeSlot, let slot = slots[id] else {
      // A slot that's gone, like a reply scrolled out of a lazy list, hides the
      // character until it returns. A pending move waits for its slot instead.
      if pendingTransition == nil { isPresent = false }
      return
    }
    if !isPresent {
      model.place(at: slot, instantly: true)
    } else if let transition = pendingTransition {
      switch transition {
      case .automatic: model.fall(to: slot)
      case .glide: model.place(at: slot, instantly: false)
      case .instant: model.place(at: slot, instantly: true)
      }
    } else {
      model.updateSlot(slot)
    }
    pendingTransition = nil
    isPresent = true
  }

  /// What the timeline should do after the latest frame. With nothing drawn,
  /// because no slot is chosen or it has left the layout, it rests: a slot
  /// coming back changes the anchors, which draws a frame and wakes it.
  var neededActivity: Activity {
    if !isPresent || model.isAtRest { return .rest }
    return model.needsEveryFrame ? .live : .ambient
  }

  private func wake() {
    if activity != .live { activity = .live }
  }

  /// Frames are built while SwiftUI renders, where publishing isn't allowed, so
  /// the timeline slows down or pauses on the next turn of the main loop.
  private func refreshActivityLater() {
    guard neededActivity != activity, !activityRefreshScheduled else { return }
    activityRefreshScheduled = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      activityRefreshScheduled = false
      let needed = neededActivity
      if needed != activity { activity = needed }
    }
  }
}

// MARK: Slots and targets

struct EnigmaCharacterAnchor {
  enum Role {
    case slot(EnigmaCharacterSlotID, size: CGFloat)
    case target(EnigmaCharacterTargetID, point: UnitPoint)
  }

  let role: Role
  let bounds: Anchor<CGRect>
}

struct EnigmaCharacterAnchorKey: PreferenceKey {
  static var defaultValue: [EnigmaCharacterAnchor] { [] }

  static func reduce(value: inout [EnigmaCharacterAnchor], nextValue: () -> [EnigmaCharacterAnchor]) {
    value.append(contentsOf: nextValue())
  }
}

/// Slots and targets resolved into the stage's points.
struct EnigmaCharacterPlaces: Equatable {
  var slots: [EnigmaCharacterSlotID: EnigmaCharacterModel.Slot] = [:]
  var targets: [EnigmaCharacterTargetID: CGPoint] = [:]

  init(slots: [EnigmaCharacterSlotID: EnigmaCharacterModel.Slot] = [:],
       targets: [EnigmaCharacterTargetID: CGPoint] = [:]) {
    self.slots = slots
    self.targets = targets
  }

  init(_ anchors: [EnigmaCharacterAnchor], in proxy: GeometryProxy) {
    for anchor in anchors {
      let rect = proxy[anchor.bounds]
      switch anchor.role {
      case let .slot(id, size):
        slots[id] = .init(center: CGPoint(x: rect.midX, y: rect.midY), size: size)
      case let .target(id, point):
        targets[id] = CGPoint(x: rect.minX + rect.width * point.x, y: rect.minY + rect.height * point.y)
      }
    }
  }
}

extension View {
  /// Reserves a `size` × `size` square where the character can sit. The
  /// character's scale follows `size`: 150 on the welcome screen, 92 on the main
  /// page, 40 in the compact panel, and 30 beside a chat reply.
  func enigmaCharacterSlot(id: EnigmaCharacterSlotID, size: CGFloat) -> some View {
    frame(width: size, height: size)
      .anchorPreference(key: EnigmaCharacterAnchorKey.self, value: .bounds) {
        [EnigmaCharacterAnchor(role: .slot(id, size: size), bounds: $0)]
      }
  }

  /// Marks something the character can turn toward, at `point` within this view.
  func enigmaCharacterTarget(_ id: EnigmaCharacterTargetID, at point: UnitPoint = .center) -> some View {
    anchorPreference(key: EnigmaCharacterAnchorKey.self, value: .bounds) {
      [EnigmaCharacterAnchor(role: .target(id, point: point), bounds: $0)]
    }
  }

  /// Draws `controller`'s character over this view at its active slot. Apply it
  /// once, at the window root, inside `.enigmaTheme(_:)`.
  func enigmaCharacterStage(_ controller: EnigmaCharacterController) -> some View {
    modifier(EnigmaCharacterStage(controller: controller))
  }
}

// MARK: Stage

/// The overlay that draws a window's character, moves it between slots, and
/// lets people drag, throw, and poke it.
struct EnigmaCharacterStage: ViewModifier {
  static let coordinateSpace = "EnigmaCharacterStage"

  @ObservedObject var controller: EnigmaCharacterController
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isWindowVisible = true

  func body(content: Content) -> some View {
    let pacing = EnigmaCharacterPacing.resolve(
      windowVisible: isWindowVisible, reduceMotion: reduceMotion,
      isAtRest: controller.activity == .rest, needsEveryFrame: controller.activity == .live)
    content
      .onContinuousHover(coordinateSpace: .local) { phase in
        switch phase {
        case let .active(location): controller.pointerMoved(to: location)
        case .ended: controller.pointerMoved(to: nil)
        }
      }
      .overlayPreferenceValue(EnigmaCharacterAnchorKey.self) { anchors in
        GeometryReader { proxy in
          EnigmaCharacterLayer(controller: controller, places: EnigmaCharacterPlaces(anchors, in: proxy),
                               palette: palette, reduceMotion: reduceMotion, pacing: pacing)
        }
      }
      .background(EnigmaWindowVisibilityReader { isWindowVisible = $0 })
  }
}

private struct EnigmaCharacterLayer: View {
  /// Observed here too: while the timeline is paused, as under Reduce Motion,
  /// only a published change (a new state or slot) redraws the character.
  @ObservedObject var controller: EnigmaCharacterController
  let places: EnigmaCharacterPlaces
  let palette: EnigmaPalette
  let reduceMotion: Bool
  let pacing: EnigmaCharacterPacing

  var body: some View {
    TimelineView(.animation(minimumInterval: pacing == .ambient ? EnigmaCharacterPacing.ambientInterval : nil,
                            paused: pacing == .paused)) { timeline in
      let frame = controller.frame(at: timeline.date.timeIntervalSinceReferenceDate, slots: places.slots,
                                   targets: places.targets, reduceMotion: reduceMotion)
      ZStack(alignment: .topLeading) {
        Canvas { context, _ in
          EnigmaCharacterRenderer.draw(frame, palette: palette, in: &context)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        if !frame.isEmpty {
          handle
        }
      }
      .coordinateSpace(.named(EnigmaCharacterStage.coordinateSpace))
    }
  }

  /// The character's hit area and its single accessibility element.
  private var handle: some View {
    let side = max(controller.model.bodyRadius * 2.5, 12)
    return Color.clear
      .frame(width: side, height: side)
      .contentShape(Circle())
      .gesture(drag, including: reduceMotion ? .none : .all)
      .pointerStyle(reduceMotion ? nil : (controller.model.isDragging ? .grabActive : .grabIdle))
      .accessibilityElement()
      .accessibilityLabel(EnigmaCharacterState.accessibilityLabel)
      .accessibilityValue(controller.state.accessibilityValue)
      .accessibilityAddTraits(.isImage)
      .position(controller.model.position)
  }

  private var drag: some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .named(EnigmaCharacterStage.coordinateSpace))
      .onChanged { value in
        if controller.model.isDragging {
          controller.moveDrag(to: value.location)
        } else {
          controller.beginDrag(at: value.startLocation)
          controller.moveDrag(to: value.location)
        }
      }
      .onEnded { value in
        controller.moveDrag(to: value.location)
        controller.endDrag(velocity: CGVector(dx: value.velocity.width, dy: value.velocity.height))
      }
  }
}

/// Reports whether the window is on screen and not fully covered, so the
/// stage can pause its timeline.
private struct EnigmaWindowVisibilityReader: NSViewRepresentable {
  let onChange: @MainActor (Bool) -> Void

  func makeNSView(context: Context) -> ReaderView {
    let view = ReaderView()
    view.onChange = onChange
    return view
  }

  func updateNSView(_ view: ReaderView, context: Context) { view.onChange = onChange }

  static func dismantleNSView(_ view: ReaderView, coordinator: ()) { view.stopObserving() }

  final class ReaderView: NSView {
    var onChange: (@MainActor (Bool) -> Void)?
    private var observer: NSObjectProtocol?
    private var reported: Bool?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stopObserving()
      if let window {
        observer = NotificationCenter.default.addObserver(
          forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.report() }
        }
      }
      report()
    }

    func stopObserving() {
      if let observer { NotificationCenter.default.removeObserver(observer) }
      observer = nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    private func report() {
      let visible = window.map(EnigmaCharacterPacing.isVisible) ?? false
      guard visible != reported else { return }
      reported = visible
      // This can run while SwiftUI updates its views, so report on the next turn.
      Task { @MainActor [weak self] in self?.onChange?(visible) }
    }
  }
}

// MARK: Previews

#if DEBUG
private struct EnigmaCharacterPreview: View {
  @StateObject private var character: EnigmaCharacterController
  @Environment(\.enigmaPalette) private var palette
  private let size: CGFloat

  init(_ state: EnigmaCharacterState, size: CGFloat = 92) {
    _character = StateObject(wrappedValue: EnigmaCharacterController(state: state, seed: 7))
    self.size = size
  }

  var body: some View {
    VStack(spacing: 22) {
      Color.clear.enigmaCharacterSlot(id: "preview", size: size)
      Text(character.state.accessibilityValue.lowercased())
        .font(EnigmaTypography.mono(11))
        .foregroundStyle(palette.textTertiary.color)
        .enigmaCharacterTarget("label")
    }
    .padding(.horizontal, 60)
    .padding(.top, size * 0.6)
    .padding(.bottom, 24)
    .background(palette.background.color)
    .enigmaCharacterStage(character)
    .task {
      character.move(to: "preview", .instant)
      if character.state == .listening { character.attention = "label" }
      while !Task.isCancelled {
        switch character.state {
        case .answering:
          character.token()
          try? await Task.sleep(for: .milliseconds(45))
        case .listening:
          character.key()
          try? await Task.sleep(for: .milliseconds(Int.random(in: 90...260)))
        default:
          try? await Task.sleep(for: .seconds(1))
        }
      }
    }
  }
}

private struct EnigmaCharacterFallPreview: View {
  @StateObject private var character = EnigmaCharacterController(seed: 11)
  @Environment(\.enigmaPalette) private var palette
  @State private var isDown = false

  var body: some View {
    VStack(spacing: 0) {
      Color.clear.enigmaCharacterSlot(id: "main", size: 92)
        .padding(.top, 60)
      Spacer(minLength: 120)
      HStack(alignment: .top, spacing: 10) {
        Color.clear.enigmaCharacterSlot(id: "reply", size: 30)
        Text("Replies sit beside the character.")
          .font(EnigmaTypography.reply)
          .foregroundStyle(palette.textPrimary.color)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 26)
      .padding(.bottom, 40)
    }
    .frame(width: 420, height: 420)
    .background(palette.background.color)
    .enigmaCharacterStage(character)
    .onTapGesture {
      isDown.toggle()
      character.move(to: isDown ? "reply" : "main")
    }
    .task {
      character.move(to: "main", .instant)
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(2.5))
        isDown.toggle()
        character.move(to: isDown ? "reply" : "main")
      }
    }
  }
}

private struct EnigmaMarkPreview: View {
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    HStack(alignment: .bottom, spacing: 18) {
      ForEach([14.0, 18, 24, 30], id: \.self) { side in
        VStack(spacing: 8) {
          EnigmaMark(style: .outline).frame(width: side, height: side)
          EnigmaMark(style: .filled).frame(width: side, height: side)
        }
      }
      EnigmaMark(style: .filled).frame(width: 96, height: 96)
    }
    .padding(24)
    .background(palette.background.color)
  }
}

#Preview("Idle") { EnigmaCharacterPreview(.idle).enigmaTheme(.system) }
#Preview("Listening") { EnigmaCharacterPreview(.listening).enigmaTheme(.system) }
#Preview("Thinking") { EnigmaCharacterPreview(.thinking).enigmaTheme(.system) }
#Preview("Answering") { EnigmaCharacterPreview(.answering).enigmaTheme(.system) }
#Preview("Error") { EnigmaCharacterPreview(.error).enigmaTheme(.system) }
#Preview("Chat size") { EnigmaCharacterPreview(.thinking, size: 30).enigmaTheme(.system) }
#Preview("Fall between slots") { EnigmaCharacterFallPreview().enigmaTheme(.system) }
#Preview("Mark") { EnigmaMarkPreview().enigmaTheme(.system) }
#endif
