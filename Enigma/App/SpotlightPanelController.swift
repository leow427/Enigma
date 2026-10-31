import AppKit
import Combine
import QuartzCore
import SwiftUI

struct PanelSizeStore {
  static let defaultSize = NSSize(width: 1200, height: 780)
  static let minimumSize = NSSize(width: 640, height: 420)

  private enum Key {
    static let width = "aiSpotlight.panel.width"
    static let height = "aiSpotlight.panel.height"
  }

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func load() -> NSSize {
    let width = defaults.double(forKey: Key.width)
    let height = defaults.double(forKey: Key.height)
    guard width.isFinite,
          height.isFinite,
          width >= Self.minimumSize.width,
          height >= Self.minimumSize.height else {
      return Self.defaultSize
    }
    return NSSize(width: width, height: height)
  }

  func save(_ size: NSSize) {
    guard size.width.isFinite, size.height.isFinite else { return }
    defaults.set(max(size.width, Self.minimumSize.width), forKey: Key.width)
    defaults.set(max(size.height, Self.minimumSize.height), forKey: Key.height)
  }

  static func centeredFrame(size: NSSize, in visibleFrame: NSRect) -> NSRect {
    let fittedSize = NSSize(
      width: min(size.width, visibleFrame.width),
      height: min(size.height, visibleFrame.height)
    )
    return NSRect(
      x: visibleFrame.midX - fittedSize.width / 2,
      y: visibleFrame.midY - fittedSize.height / 2,
      width: fittedSize.width,
      height: fittedSize.height
    )
  }
}

/// How the compact panel moves into the window once its chat opens there:
/// from wherever the panel is to the window's normal frame, on the
/// `EnigmaMotion.screenChange` spring.
enum SelectionPanelMotion {
  /// The panel's size when it opens, before its content reports its height.
  static let composerSize = NSSize(width: 720, height: 92)

  /// A spring's progress from 0 to 1 after `time` seconds, starting at rest,
  /// in the response and damping terms SwiftUI uses.
  static func springProgress(at time: Double, spring: EnigmaSpring = EnigmaMotion.screenChange) -> Double {
    guard time > 0 else { return 0 }
    let stiffness = 2 * Double.pi / spring.response
    let damping = min(spring.dampingFraction, 0.999)
    let decay = damping * stiffness
    let frequency = stiffness * (1 - damping * damping).squareRoot()
    return 1 - exp(-decay * time) * (cos(frequency * time) + decay / frequency * sin(frequency * time))
  }

  /// How long the spring takes to come, and stay, within a thousandth of
  /// its target, so the jump to the target at the end can't be seen.
  static func settlingDuration(_ spring: EnigmaSpring = EnigmaMotion.screenChange) -> Double {
    let step = 0.001
    var time = 0.0
    var settled = 0.0
    // Past 5 seconds no spring Enigma uses is still moving.
    while time < 5 {
      time += step
      if abs(1 - springProgress(at: time, spring: spring)) >= 0.001 { settled = time }
    }
    return settled + step
  }

  /// The panel's frame part of the way, `progress`, from `start` to `target`:
  /// its position and size move together.
  static func frame(at progress: Double, from start: NSRect, to target: NSRect) -> NSRect {
    func mix(_ from: CGFloat, _ to: CGFloat) -> CGFloat { from + (to - from) * progress }
    return NSRect(x: mix(start.minX, target.minX), y: mix(start.minY, target.minY),
                  width: mix(start.width, target.width), height: mix(start.height, target.height))
  }
}

/// What the compact panel's content reports about its composer: how tall it
/// is, how tall it is at rest, without an open list, menu, or details, and how
/// much of its height is room above the input for a list or menu that opens
/// upward, so the input stays where it was.
struct SelectionComposerReport: Equatable, Sendable {
  var height: CGFloat
  var restingHeight: CGFloat
  var roomAbove: CGFloat

  init(height: CGFloat, restingHeight: CGFloat? = nil, roomAbove: CGFloat = 0) {
    self.height = height
    self.restingHeight = restingHeight ?? height
    self.roomAbove = roomAbove
  }
}

/// Carries the compact panel's composer report up to the window, which
/// posts it to the controller. The tallest report wins.
struct SelectionComposerHeight: PreferenceKey {
  static let defaultValue = SelectionComposerReport(height: 0)
  static func reduce(value: inout SelectionComposerReport, nextValue: () -> SelectionComposerReport) {
    let next = nextValue()
    if next.height > value.height { value = next }
  }
}

/// What summoning Enigma could leave behind: the open chat, as plain values.
struct ChatReturnState: Equatable {
  /// The open chat's last use: its last activity, or a request starting,
  /// streaming or ending, failed or not. Nil when no chat with messages is
  /// open: then there's nothing to leave.
  var lastUsedAt: Date?
  /// Unsent text, a screenshot, or files in the composer, queued messages,
  /// a selection revision not yet applied or dismissed, or a File Mode edit
  /// waiting on "Use Codex".
  var hasUnsentWork = false
  /// A reply, file work, or a model operation holding the chat.
  var isBusy = false
}

extension ChatReturnState {
  @MainActor init(chat: LocalChatViewModel, screen: ScreenComposerCoordinator?) {
    if let session = chat.selectedSession, !session.messages.isEmpty {
      lastUsedAt = max(session.lastActivityAt, chat.lastRequestActivityAt ?? .distantPast)
    }
    let hasDraft = screen.map { !$0.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.attachment != nil } ?? false
    var awaitsCodex = false
    if case .cloudRequired = chat.files.protectedWrite { awaitsCodex = true }
    hasUnsentWork = hasDraft || !chat.messageQueue.isEmpty || chat.files.selection != nil
      || chat.hasPendingSelectionRevision || awaitsCodex
    isBusy = chat.isBusy
  }
}

/// When summoning Enigma opens a new chat instead of the one the user left:
/// once it has been neither shown nor used for more than `awayLimit`. Only
/// time hidden counts, so a window left open behind other apps comes back to
/// the same chat. A chat with nothing in it, unsent work, or a running reply
/// is never left.
enum ChatReturnPolicy {
  static let awayLimit: TimeInterval = 5 * 60

  /// `chat` is read only once the panel has been hidden long enough.
  static func startsNewChat(hiddenAt: Date?, now: Date, chat: @autoclosure () -> ChatReturnState) -> Bool {
    guard let hiddenAt, now.timeIntervalSince(hiddenAt) > awayLimit else { return false }
    let chat = chat()
    guard let lastUsedAt = chat.lastUsedAt, !chat.hasUnsentWork, !chat.isBusy else { return false }
    return now.timeIntervalSince(max(hiddenAt, lastUsedAt)) > awayLimit
  }
}

@MainActor
final class SpotlightPanelController: NSObject, NSWindowDelegate {
  private let panel: SpotlightPanel
  private let sizeStore: PanelSizeStore
  private let reduceMotion: @MainActor () -> Bool
  /// The visible part of the screen the panel is on. Tests set their own geometry.
  private let visibleFrame: @MainActor (NSWindow) -> NSRect?
  private var welcomeObservation: AnyCancellable?
  private var normalSize: NSSize?
  private var selectionNormalFrame: NSRect?
  private(set) var isSelectionComposer = false
  /// The latest composer the content reported.
  private(set) var selectionComposer: SelectionComposerReport?
  /// The panel's top edge at rest, where it was placed: an open list, menu,
  /// or details grows the panel from here, and closing it returns here.
  private var selectionRestingTop: CGFloat?
  /// The frame the latest report set, to tell when someone has moved the panel.
  private var selectionAppliedFrame: NSRect?
  /// A move on the window's spring, stepped on the display's refresh so
  /// each frame lands on time.
  private var moveLink: CADisplayLink?
  /// Ends a move on time when the display isn't refreshing, asleep or locked.
  private var moveDeadline: Task<Void, Never>?
  private var moveStart = NSRect.zero
  private var moveBegan: CFTimeInterval = 0
  private var moveDuration: Double = 0
  private var moveTarget: NSRect?
  /// Runs once the current move reaches its target.
  private var moveCompletion: (() -> Void)?
  /// F14 spike: counts the tour's fades, so a finished fade-out can't hide a window shown again since.
  private var fadeGeneration = 0

  private(set) var isCapturingScreen = false
  private var captureHiddenWindows: [NSWindow] = []
  private let now: @MainActor () -> Date
  private let chatState: @MainActor () -> ChatReturnState
  /// When the user last hid the panel, for `ChatReturnPolicy`; nil while it's shown.
  private(set) var hiddenAt: Date?
  var isVisible: Bool { panel.isVisible && !isCapturingScreen }

  init(
    sizeStore: PanelSizeStore = PanelSizeStore(),
    contentView: NSView? = nil,
    welcomeSetup: WelcomeSetup? = nil,
    reduceMotion: @escaping @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
    visibleFrame: @escaping @MainActor (NSWindow) -> NSRect? = { $0.screen?.visibleFrame },
    now: @escaping @MainActor () -> Date = { .now },
    chatState: (@MainActor () -> ChatReturnState)? = nil
  ) {
    self.sizeStore = sizeStore
    self.now = now
    // The window's own composer, so its unsent draft counts. Content given
    // by a test brings its own state.
    let screen = contentView == nil ? ScreenComposerCoordinator() : nil
    self.chatState = chatState ?? { ChatReturnState(chat: .shared, screen: screen) }
    self.reduceMotion = reduceMotion
    self.visibleFrame = visibleFrame
    panel = SpotlightPanel(
      contentRect: NSRect(origin: .zero, size: sizeStore.load()),
      styleMask: [.borderless, .nonactivatingPanel, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    super.init()

    panel.delegate = self
    panel.title = "Enigma"
    // Best-effort exclusion for capture clients that honor the legacy window flag.
    // ScreenCaptureKit may still include this window; keep it visible locally.
    panel.sharingType = .none
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    panel.animationBehavior = .utilityWindow
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.isMovableByWindowBackground = true
    panel.minSize = PanelSizeStore.minimumSize
    panel.contentView = contentView ?? NSHostingView(
      rootView: AppShellView(screen: screen ?? ScreenComposerCoordinator())
    )

    NotificationCenter.default.addObserver(self, selector: #selector(beginScreenCapture), name: .screenCaptureBegan, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(endScreenCapture), name: .screenCaptureEnded, object: nil)

    NotificationCenter.default.addObserver(self, selector: #selector(beginSelectionReplacement), name: .selectionReplacementBegan, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(endSelectionReplacement(_:)), name: .selectionReplacementEnded, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(openSelectionChatInWindow), name: .selectionChatOpenInWindowRequested, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(userDragBegan(_:)), name: .enigmaWindowDragBegan, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(userDragEnded(_:)), name: .enigmaWindowDragEnded, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(resizeSelectionComposer(_:)), name: .selectionComposerHeightChanged, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(restoreNormalPanel), name: .newChatRequested, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(restoreNormalPanel), name: .selectionPanelResetRequested, object: nil)
    // F14 spike: the tour's selection stop uses the real panel over a pretend document.
    NotificationCenter.default.addObserver(self, selector: #selector(tourStepAside), name: .guidedTourStepAside, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(tourComeBack), name: .guidedTourComeBack, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(tourSummon(_:)), name: .guidedTourSummon, object: nil)
    if let welcomeSetup {
      // F14 spike: the hands-on tour grows the window by its rail.
      welcomeObservation = welcomeSetup.$isPresented.combineLatest(welcomeSetup.$tour, GuidedTour.shared.$stop)
        .map { presented, tour, guided -> WelcomeSizing in
          guided != nil ? .tour : presented || tour != nil ? .welcome : .normal
        }
        .removeDuplicates()
        // The page keeps the window's width from the moment the tour starts,
        // so its rail never squeezes it before the window has grown.
        .handleEvents(receiveOutput: { [weak self] sizing in
          guard let self, sizing == .tour, GuidedTour.shared.pageWidth == nil else { return }
          GuidedTour.shared.pageWidth = self.panel.frame.width
        })
        // @Published emits before storing the new value. Resizing synchronously
        // can lay out the hosting view with stale welcome/disabled state.
        .receive(on: DispatchQueue.main)
        .sink { [weak self] sizing in self?.setWelcomeSizing(sizing) }
    }
    panel.onHide = { [weak self] in
      self?.hide()
    }
    panel.onShortcut = { [weak self] shortcut in
      self?.perform(shortcut) ?? false
    }
  }

  @objc private func beginSelectionReplacement() {
    finishMove()
    // F14 spike: the tour's pretend paste needs no focus handed back, so the
    // window fades aside for it.
    if GuidedTour.shared.stop == .selection { fadeOut(); return }
    // A nonactivating panel can own keyboard focus while the source is already
    // frontmost. Activating that app alone does not release the panel's focus.
    panel.orderOut(nil)
  }

  @objc private func endSelectionReplacement(_ notification: Notification) {
    // After an automatic paste the window stays hidden, the same as Escape
    // hides it: summoning Enigma again shows the same chat. The start of the
    // paste ordered it out, so a visible window here was summoned again
    // during the paste, and stays.
    if (notification.object as? SelectionReplacementEnd)?.keepsWindowHidden == true {
      if !panel.isVisible { hide() }
      return
    }
    if GuidedTour.shared.stop == .selection {
      fadeIn()
    } else {
      hiddenAt = nil
      panel.orderFrontRegardless()
      panel.makeKey()
    }
    NotificationCenter.default.post(name: .panelPresented, object: nil)
  }

  private var selectionInvocation: Task<Void, Never>?

  func summonSelectionContext() {
    // F14 spike: during the tour's selection stop, ⌥⌥ takes its step instead of reading another app.
    if GuidedTour.shared.stop == .selection { GuidedTour.shared.shortcutPressed(); return }
    guard !isCapturingScreen, selectionInvocation == nil else { return }
    let cursor = NSEvent.mouseLocation
    let visible = (NSScreen.screens.first { NSMouseInRect(cursor, $0.frame, false) } ?? NSScreen.main)?.visibleFrame
    selectionInvocation = Task { [weak self] in
      let service = SelectionContextService.shared
      let context = await service.capture()
      guard let self else { return }
      defer { self.selectionInvocation = nil }
      guard !self.isCapturingScreen else { service.discardTarget(); return }
      self.presentSelectionContext(context, cursor: cursor, selection: service.selectionBounds(), visible: visible)
    }
  }

  func presentSelectionContext(_ context: ConversationContext?, cursor: NSPoint, selection: NSRect?, visible: NSRect?) {
    // The tour's selection stop opens it while the tour has the window enlarged.
    guard normalSize == nil || GuidedTour.shared.stop == .selection else { return }
    finishMove()
    if selectionNormalFrame == nil { selectionNormalFrame = panel.frame }
    isSelectionComposer = true
    panel.minSize = NSSize(width: 640, height: 72)
    let visible = visible ?? panel.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    panel.setFrame(SelectionPanelPlacement.frame(size: composerSize,
      cursor: cursor, selection: selection, visible: visible), display: true)
    selectionRestingTop = panel.frame.maxY
    selectionAppliedFrame = panel.frame
    NotificationCenter.default.post(name: .selectionPanelPlaced, object: panel.frame.minY - visible.minY)
    NotificationCenter.default.post(name: .selectionContextRequested, object: context)
    hiddenAt = nil
    cancelFade()
    panel.orderFrontRegardless()
    panel.makeKey()
    NotificationCenter.default.post(name: .panelPresented, object: nil)
  }

  /// The panel opens at its last reported resting height, so it doesn't jump
  /// on arrival, or at its first size before anything has been reported.
  private var composerSize: NSSize {
    guard let report = selectionComposer, report.height > 0 else {
      return SelectionPanelMotion.composerSize
    }
    return NSSize(width: SelectionPanelMotion.composerSize.width, height: max(72, report.restingHeight))
  }

  /// The content reports its composer's height.
  @objc private func resizeSelectionComposer(_ notification: Notification) {
    guard let report = notification.object as? SelectionComposerReport,
          isSelectionComposer, report.height.isFinite else { return }
    let previous = selectionComposer
    selectionComposer = report
    guard let visible = visibleFrame(panel) else { return }
    var frame = panel.frame
    frame.size.height = min(max(72, report.height), visible.height)
    // Someone moved the panel: where it is now is its new resting place.
    if let applied = selectionAppliedFrame, panel.frame != applied {
      selectionRestingTop = panel.frame.maxY - (previous?.roomAbove ?? 0)
    }
    // The input stays in place: the panel grows down from its resting top, or
    // up by the room a list or menu needs above the input. Pushed up
    // to fit the screen, it comes back once the list closes. Wherever the
    // user has moved it, it stays on the visible screen.
    let top = (selectionRestingTop ?? panel.frame.maxY) + report.roomAbove
    frame.origin.y = min(max(top - frame.height, visible.minY), visible.maxY - frame.height)
    frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
    if abs(frame.height - panel.frame.height) > 1 || abs(frame.minY - panel.frame.minY) > 1
        || abs(frame.minX - panel.frame.minX) > 1 {
      panel.setFrame(frame, display: true)
    }
    selectionAppliedFrame = panel.frame
  }

  /// Moves the panel to `target`: on the spring while it's on screen, or at
  /// once with Reduce Motion. The window's minimum size applies once it's
  /// there, and the content hears that it has settled.
  private func move(to target: NSRect, completion: (() -> Void)? = nil) {
    guard !reduceMotion(), panel.isVisible else {
      panel.setFrame(target, display: true)
      panel.minSize = PanelSizeStore.minimumSize
      NotificationCenter.default.post(name: .selectionPanelSettled, object: nil)
      completion?()
      return
    }
    // A new move starts from wherever the last one had reached.
    moveLink?.invalidate()
    moveDeadline?.cancel()
    moveCompletion = completion
    moveStart = panel.frame
    moveTarget = target
    moveBegan = CACurrentMediaTime()
    moveDuration = SelectionPanelMotion.settlingDuration()
    let link = panel.displayLink(target: self, selector: #selector(stepMove(_:)))
    link.add(to: .main, forMode: .common)
    moveLink = link
    moveDeadline = Task { [weak self, duration = moveDuration] in
      try? await Task.sleep(for: .seconds(duration + 0.25))
      guard !Task.isCancelled else { return }
      self?.finishMove()
    }
  }

  /// One step of the move, at the time the frame will reach the screen.
  @objc private func stepMove(_ link: CADisplayLink) {
    guard let target = moveTarget else { link.invalidate(); return }
    let seconds = link.targetTimestamp - moveBegan
    guard seconds < moveDuration else { finishMove(); return }
    let progress = SelectionPanelMotion.springProgress(at: seconds)
    panel.setFrame(SelectionPanelMotion.frame(at: progress, from: moveStart, to: target), display: true)
  }

  /// A running move jumps to its end.
  private func finishMove() {
    moveLink?.invalidate()
    moveLink = nil
    moveDeadline?.cancel()
    moveDeadline = nil
    guard let target = moveTarget else { return }
    moveTarget = nil
    panel.setFrame(target, display: true)
    panel.minSize = PanelSizeStore.minimumSize
    NotificationCenter.default.post(name: .selectionPanelSettled, object: nil)
    let completion = moveCompletion
    moveCompletion = nil
    completion?()
  }

  /// Sending a question, ⌘O, or the Open in window button, at any point in
  /// the panel: its chat becomes the main window's, which moves to the
  /// window's normal size, centered on the screen the panel is on.
  @objc func openSelectionChatInWindow() {
    finishMove()
    guard let normal = selectionNormalFrame else { return }
    selectionNormalFrame = nil
    isSelectionComposer = false
    selectionRestingTop = nil
    selectionAppliedFrame = nil
    let frame = visibleFrame(panel).map { PanelSizeStore.centeredFrame(size: normal.size, in: $0) } ?? normal
    NotificationCenter.default.post(name: .selectionChatOpenedInWindow, object: nil)
    move(to: frame)
    // F14 spike: a click on the pretend document's card leaves Return with
    // the document. The chat in the window takes it back.
    if GuidedTour.shared.stop == .selection { panel.makeKey() }
  }

  /// The user started dragging the panel: a running move into the window
  /// jumps to its end, so the drag moves the window at its final size.
  @objc private func userDragBegan(_ notification: Notification) {
    guard notification.object as? NSWindow === panel else { return }
    finishMove()
  }

  /// The user moved the panel. Where it is now is its new resting place, so
  /// later resizing grows from here, and lists open above or below for
  /// the room it has here.
  @objc private func userDragEnded(_ notification: Notification) {
    guard notification.object as? NSWindow === panel, selectionNormalFrame != nil else { return }
    selectionRestingTop = panel.frame.maxY - (isSelectionComposer ? selectionComposer?.roomAbove ?? 0 : 0)
    selectionAppliedFrame = panel.frame
    guard isSelectionComposer, let visible = visibleFrame(panel) else { return }
    NotificationCenter.default.post(name: .selectionPanelPlaced, object: panel.frame.minY - visible.minY)
  }

  /// F14 spike: the window fades aside for the tour's pretend document,
  /// which rises in its place.
  @objc private func tourStepAside() {
    finishMove()
    fadeOut()
  }

  /// F14 spike: back as the window, wherever the tour left it.
  @objc private func tourComeBack() {
    if selectionNormalFrame != nil { restoreNormalPanel() }
    fadeIn()
  }

  /// F14 spike: fades the window out, then takes it off the screen.
  private func fadeOut(duration: Double = 0.22) {
    fadeGeneration += 1
    let generation = fadeGeneration
    guard !reduceMotion(), panel.isVisible else { orderOutQuietly(); return }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = duration
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      panel.animator().alphaValue = 0
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        guard let self, generation == self.fadeGeneration else { return }
        self.orderOutQuietly()
      }
    }
  }

  /// F14 spike: brings the window back, fading in if it was away.
  private func fadeIn(duration: Double = 0.28) {
    fadeGeneration += 1
    let reduce = reduceMotion()
    if !panel.isVisible { panel.alphaValue = reduce ? 1 : 0 }
    hiddenAt = nil
    let behavior = panel.animationBehavior
    panel.animationBehavior = .none
    panel.orderFrontRegardless()
    panel.animationBehavior = behavior
    panel.makeKey()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = reduce ? 0 : duration
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().alphaValue = 1
    }
  }

  /// F14 spike: a fade-out still running can't take a window shown again away.
  private func cancelFade() {
    fadeGeneration += 1
    guard panel.alphaValue < 1 else { return }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0
      panel.animator().alphaValue = 1
    }
  }

  /// Off the screen without the system's own animation, back at full opacity for next time.
  private func orderOutQuietly() {
    let behavior = panel.animationBehavior
    panel.animationBehavior = .none
    panel.orderOut(nil)
    panel.animationBehavior = behavior
    panel.alphaValue = 1
  }

  /// F14 spike: the real panel, under the pretend document's selected line.
  @objc private func tourSummon(_ notification: Notification) {
    guard let selection = (notification.object as? NSValue)?.rectValue else { return }
    let screen = NSScreen.screens.first { $0.frame.intersects(selection) } ?? NSScreen.main
    presentSelectionContext(TourScene.context, cursor: NSPoint(x: selection.minX, y: selection.minY),
                            selection: selection, visible: screen?.visibleFrame)
  }

  @objc private func restoreNormalPanel() {
    finishMove()
    guard let frame = selectionNormalFrame else { return }
    selectionNormalFrame = nil
    isSelectionComposer = false
    panel.minSize = PanelSizeStore.minimumSize
    panel.setFrame(frame, display: true)
    NotificationCenter.default.post(name: .selectionPanelRestored, object: nil)
  }

  func show() {
    guard !isCapturingScreen else { return }
    // Back after more than five minutes away: a new chat, through the same
    // path as ⌘N, so a compact panel returns to the window too. Applied and
    // laid out before the panel is ordered front, so it opens on the new chat.
    if !panel.isVisible, ChatReturnPolicy.startsNewChat(hiddenAt: hiddenAt, now: now(), chat: chatState()) {
      NotificationCenter.default.post(name: .newChatRequested, object: nil)
      panel.contentView?.layoutSubtreeIfNeeded()
    }
    hiddenAt = nil
    cancelFade()
    centerOnActiveDisplay()
    panel.orderFrontRegardless()
    panel.makeKey()
    NotificationCenter.default.post(name: .panelPresented, object: nil)
  }

  @objc private func beginScreenCapture() {
    guard !isCapturingScreen else { return }
    finishMove()
    isCapturingScreen = true
    captureHiddenWindows = NSApp.windows.filter { $0 !== panel && $0.isVisible }
    captureHiddenWindows.forEach { $0.orderOut(nil) }
    // Removing the panel from the window server avoids capturing it and gives
    // SwiftUI a fresh compositor surface when the panel is restored. Keeping an
    // ordered window at zero alpha can leave that surface transparent after the
    // system screenshot picker disconnects on macOS 26.
    panel.orderOut(nil)
  }

  @objc private func endScreenCapture() {
    guard isCapturingScreen else { return }
    captureHiddenWindows.forEach { $0.orderFrontRegardless() }
    captureHiddenWindows = []
    isCapturingScreen = false
    hiddenAt = nil
    panel.orderFrontRegardless()
    panel.makeKey()
    panel.contentView?.needsLayout = true
    panel.contentView?.needsDisplay = true
    NotificationCenter.default.post(name: .panelPresented, object: nil)
  }

  func hide() {
    finishMove()
    // Hiding an already hidden panel keeps the time it was first hidden.
    hiddenAt = hiddenAt ?? now()
    panel.orderOut(nil)
    NotificationCenter.default.post(name: .panelHidden, object: nil)
  }

  func toggle() {
    guard !isCapturingScreen else { return }
    panel.isVisible ? hide() : show()
  }

  /// A resize started while the panel moves into the window starts from the
  /// window's final frame, as a drag does.
  func windowWillStartLiveResize(_ notification: Notification) {
    finishMove()
  }

  func windowDidEndLiveResize(_ notification: Notification) {
    guard normalSize == nil, selectionNormalFrame == nil else { return }
    sizeStore.save(panel.frame.size)
  }

  private enum WelcomeSizing { case normal, welcome, tour }

  /// The welcome is at least 1280 by 860; the tour adds its rail on the right,
  /// so the page keeps its width. Back to the saved size after both.
  private func setWelcomeSizing(_ sizing: WelcomeSizing) {
    let size: NSSize
    let animates: Bool
    switch sizing {
    case .normal:
      guard let previous = normalSize else { return }
      size = previous
      normalSize = nil
      animates = true
    case .welcome, .tour:
      let base = normalSize ?? panel.frame.size
      animates = normalSize != nil
      normalSize = base
      let width = max(1280, base.width) + (sizing == .tour ? GuidedTourPlacement.railWidth : 0)
      size = NSSize(width: width, height: max(860, base.height))
    }
    let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
    let frame = visible.map { PanelSizeStore.centeredFrame(size: size, in: $0) }
      ?? NSRect(origin: panel.frame.origin, size: size)
    // The page keeps its width while the window grows by the tour's rail,
    // which the window's edge uncovers, and while it shrinks back, until the
    // window is narrower than the page. Nothing in the page reflows for it.
    let tour = GuidedTour.shared
    switch sizing {
    case .tour:
      let page = frame.width - GuidedTourPlacement.railWidth
      // On a screen too narrow for the page and its rail, the page narrows
      // on the window's spring instead of at once.
      if animates, let current = tour.pageWidth, abs(current - page) > 0.5 {
        withAnimation(EnigmaMotion.screenChange.animation) { tour.pageWidth = page }
      } else {
        tour.pageWidth = page
      }
    case .normal: tour.pageWidth = tour.pageWidth.map { max($0, frame.width) }
    case .welcome: tour.pageWidth = nil
    }
    let settled: (() -> Void)? = sizing == .normal ? { GuidedTour.shared.pageWidth = nil } : nil
    // Growing for the tour and settling back afterwards move on the window's
    // spring; the welcome opens at its size.
    if animates {
      move(to: frame, completion: settled)
    } else {
      panel.setFrame(frame, display: true)
      settled?()
    }
  }

  /// F14 spike: resized by hand during the tour, the page takes the new
  /// width beside its rail.
  func windowDidResize(_ notification: Notification) {
    guard moveTarget == nil, !isSelectionComposer, GuidedTour.shared.isActive,
          GuidedTour.shared.pageWidth != nil else { return }
    GuidedTour.shared.pageWidth = panel.frame.width - GuidedTourPlacement.railWidth
  }

  private func centerOnActiveDisplay() {
    let mouseLocation = NSEvent.mouseLocation
    let activeScreen = NSScreen.screens.first { screen in
      NSMouseInRect(mouseLocation, screen.frame, false)
    } ?? NSScreen.main
    guard let visibleFrame = activeScreen?.visibleFrame else { return }

    let centeredFrame = PanelSizeStore.centeredFrame(
      size: panel.frame.size,
      in: visibleFrame
    )
    panel.setFrame(centeredFrame, display: true)
  }

  /// Returns false for a shortcut that does nothing here, so it is not consumed.
  private func perform(_ shortcut: PanelShortcut) -> Bool {
    let name: Notification.Name
    switch shortcut {
    case .toggleSidebar:
      // The history belongs to the window; the selection panel has none, and
      // the shortcut is left unhandled there.
      guard selectionNormalFrame == nil else { return false }
      NotificationCenter.default.post(name: .sidebarToggleRequested, object: nil)
      return true
    case .openInWindow:
      // Only the selection panel's chat opens in the window; elsewhere the key
      // is left unhandled rather than swallowed.
      guard selectionNormalFrame != nil else { return false }
      openSelectionChatInWindow()
      return true
    case .fileMode: name = .fileModeRequested
    case .newChat: name = .newChatRequested
    case .modePalette: name = .modePaletteRequested
    case .stopStreaming: name = .stopStreamingRequested
    case .cycleRecentChat: name = .recentChatCycleRequested
    case .settings: name = .settingsRequested
    }
    NotificationCenter.default.post(name: name, object: nil)
    return true
  }
}

private final class SpotlightPanel: NSPanel {
  var onHide: (() -> Void)?
  /// Returns whether the shortcut was handled; an unhandled one goes on down the responder chain.
  var onShortcut: ((PanelShortcut) -> Bool)?

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func keyDown(with event: NSEvent) {
    guard event.keyCode != 53 else {
      if EnigmaMenuPresenter.dismissOpenMenu(in: self) { return }
      if EnigmaEscapeDismissal.dismiss(in: self) { return }
      onHide?()
      return
    }
    super.keyDown(with: event)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if event.keyCode == 53 {
      if let editor = firstResponder as? SlashCommandTextView, editor.completion?.dismiss() == true { return true }
      // An open menu closes first, as the command list does.
      if EnigmaMenuPresenter.dismissOpenMenu(in: self) { return true }
      // So do the compact panel's details.
      if EnigmaEscapeDismissal.dismiss(in: self) { return true }
      onHide?()
      return true
    }
    if let shortcut = PanelShortcut.resolve(
      characters: event.charactersIgnoringModifiers,
      modifiers: event.modifierFlags,
      keyCode: event.keyCode
    ) {
      if onShortcut?(shortcut) == true { return true }
    }
    return super.performKeyEquivalent(with: event)
  }
}
