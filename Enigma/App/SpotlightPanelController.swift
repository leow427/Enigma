import AppKit
import Combine
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

/// How the compact panel grows into the full conversation. It keeps its
/// input at the top and opens the answer under it, so the panel grows
/// downward, on the `EnigmaMotion.panelAnswer` spring.
enum SelectionPanelExpansion {
  /// The panel's size when it opens, before its content reports its height.
  static let composerSize = NSSize(width: 720, height: 92)

  /// The expanded panel's frame: its top edge stays where the composer's was.
  static func frame(from composer: NSRect, visible: NSRect) -> NSRect {
    let size = NSSize(width: min(composer.width, visible.width), height: min(600, visible.height))
    let y = composer.maxY - size.height
    return NSRect(x: min(max(composer.minX, visible.minX), visible.maxX - size.width),
      y: min(max(y, visible.minY), visible.maxY - size.height),
      width: size.width, height: size.height)
  }

  /// A spring's progress from 0 to 1 after `time` seconds, starting at rest,
  /// in the response and damping terms SwiftUI uses.
  static func springProgress(at time: Double, spring: EnigmaSpring = EnigmaMotion.panelAnswer) -> Double {
    guard time > 0 else { return 0 }
    let stiffness = 2 * Double.pi / spring.response
    let damping = min(spring.dampingFraction, 0.999)
    let decay = damping * stiffness
    let frequency = stiffness * (1 - damping * damping).squareRoot()
    return 1 - exp(-decay * time) * (cos(frequency * time) + decay / frequency * sin(frequency * time))
  }

  /// How long the spring takes to come within a thousandth of its target.
  static func settlingDuration(_ spring: EnigmaSpring = EnigmaMotion.panelAnswer) -> Double {
    log(1000) / (min(spring.dampingFraction, 0.999) * 2 * Double.pi / spring.response)
  }

  /// The panel's frame part of the way, `progress`, from `start` to `target`,
  /// keeping its top edge in place.
  static func frame(at progress: Double, from start: NSRect, to target: NSRect, visible: NSRect) -> NSRect {
    let height = min(visible.height, start.height + (target.height - start.height) * progress)
    let y = start.maxY + (target.maxY - start.maxY) * min(1, progress) - height
    return NSRect(x: target.minX, y: min(visible.maxY - height, max(visible.minY, y)), width: target.width, height: height)
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
  private var expansionTask: Task<Void, Never>?
  private var expansionTarget: NSRect?

  private(set) var isCapturingScreen = false
  private var captureHiddenWindows: [NSWindow] = []
  var isVisible: Bool { panel.isVisible && !isCapturingScreen }

  init(
    sizeStore: PanelSizeStore = PanelSizeStore(),
    contentView: NSView? = nil,
    welcomeSetup: WelcomeSetup? = nil,
    reduceMotion: @escaping @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
    visibleFrame: @escaping @MainActor (NSWindow) -> NSRect? = { $0.screen?.visibleFrame }
  ) {
    self.sizeStore = sizeStore
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
      rootView: AppShellView()
    )

    NotificationCenter.default.addObserver(self, selector: #selector(beginScreenCapture), name: .screenCaptureBegan, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(endScreenCapture), name: .screenCaptureEnded, object: nil)

    NotificationCenter.default.addObserver(self, selector: #selector(beginSelectionReplacement), name: .selectionReplacementBegan, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(endSelectionReplacement), name: .selectionReplacementEnded, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(expandSelectionPanel), name: .selectionPanelExpandRequested, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(openSelectionChatInWindow), name: .selectionChatOpenInWindowRequested, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(userDragBegan(_:)), name: .enigmaWindowDragBegan, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(userDragEnded(_:)), name: .enigmaWindowDragEnded, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(resizeSelectionComposer(_:)), name: .selectionComposerHeightChanged, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(restoreNormalPanel), name: .newChatRequested, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(restoreNormalPanel), name: .recentChatCycleRequested, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(restoreNormalPanel), name: .selectionPanelResetRequested, object: nil)
    if let welcomeSetup {
      welcomeObservation = welcomeSetup.$isPresented.combineLatest(welcomeSetup.$tour)
        .map { $0 || $1 != nil }.removeDuplicates()
        // @Published emits before storing the new value. Resizing synchronously
        // can lay out the hosting view with stale welcome/disabled state.
        .receive(on: DispatchQueue.main)
        .sink { [weak self] active in self?.setWelcomeSizing(active) }
    }
    panel.onHide = { [weak self] in
      self?.hide()
    }
    panel.onShortcut = { [weak self] shortcut in
      self?.perform(shortcut) ?? false
    }
  }

  @objc private func beginSelectionReplacement() {
    finishExpansion()
    // A nonactivating panel can own keyboard focus while the source is already
    // frontmost. Activating that app alone does not release the panel's focus.
    panel.orderOut(nil)
  }

  @objc private func endSelectionReplacement() {
    panel.orderFrontRegardless()
    panel.makeKey()
    NotificationCenter.default.post(name: .panelPresented, object: nil)
  }

  private var selectionInvocation: Task<Void, Never>?

  func summonSelectionContext() {
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
    guard normalSize == nil else { return }
    finishExpansion()
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
    panel.orderFrontRegardless()
    panel.makeKey()
    NotificationCenter.default.post(name: .panelPresented, object: nil)
  }

  /// The panel opens at its last reported resting height, so it doesn't jump
  /// on arrival, or at its first size before anything has been reported.
  private var composerSize: NSSize {
    guard let report = selectionComposer, report.height > 0 else {
      return SelectionPanelExpansion.composerSize
    }
    return NSSize(width: SelectionPanelExpansion.composerSize.width, height: max(72, report.restingHeight))
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

  @objc func expandSelectionPanel() {
    guard isSelectionComposer else { return }
    isSelectionComposer = false
    let start = panel.frame
    let visible = visibleFrame(panel) ?? start
    let target = SelectionPanelExpansion.frame(from: start, visible: visible)
    NotificationCenter.default.post(name: .selectionPanelExpanded, object: nil)
    guard !reduceMotion(), panel.isVisible else {
      panel.setFrame(target, display: true)
      panel.minSize = PanelSizeStore.minimumSize
      return
    }
    expansionTarget = target
    let duration = SelectionPanelExpansion.settlingDuration()
    expansionTask = Task { [weak self] in
      let began = ContinuousClock.now
      while !Task.isCancelled {
        guard let self else { return }
        let elapsed = began.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let fraction = min(1, seconds / duration)
        let progress = fraction >= 1 ? 1 : SelectionPanelExpansion.springProgress(at: seconds)
        self.panel.setFrame(SelectionPanelExpansion.frame(at: progress, from: start, to: target, visible: visible),
                            display: true)
        if fraction >= 1 { self.finishExpansion(); return }
        try? await Task.sleep(for: .milliseconds(16))
      }
    }
  }

  private func finishExpansion() {
    expansionTask?.cancel()
    expansionTask = nil
    if let target = expansionTarget {
      panel.setFrame(target, display: true)
      panel.minSize = PanelSizeStore.minimumSize
    }
    expansionTarget = nil
  }

  /// Double-tap Control or the Open in window button, at any point in the
  /// panel: its chat becomes the main window's, at the window's normal size,
  /// centered on the screen the panel is on, as the window opens.
  @objc func openSelectionChatInWindow() {
    finishExpansion()
    guard let normal = selectionNormalFrame else { return }
    selectionNormalFrame = nil
    isSelectionComposer = false
    selectionRestingTop = nil
    selectionAppliedFrame = nil
    panel.minSize = PanelSizeStore.minimumSize
    let frame = visibleFrame(panel).map { PanelSizeStore.centeredFrame(size: normal.size, in: $0) } ?? normal
    panel.setFrame(frame, display: true)
    NotificationCenter.default.post(name: .selectionChatOpenedInWindow, object: nil)
  }

  /// The user started dragging the panel: a running expansion jumps to its
  /// end, so the drag moves the panel at its final size.
  @objc private func userDragBegan(_ notification: Notification) {
    guard notification.object as? NSWindow === panel else { return }
    finishExpansion()
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

  @objc private func restoreNormalPanel() {
    finishExpansion()
    guard let frame = selectionNormalFrame else { return }
    selectionNormalFrame = nil
    isSelectionComposer = false
    panel.minSize = PanelSizeStore.minimumSize
    panel.setFrame(frame, display: true)
    NotificationCenter.default.post(name: .selectionPanelExpanded, object: nil)
  }

  func show() {
    guard !isCapturingScreen else { return }
    centerOnActiveDisplay()
    panel.orderFrontRegardless()
    panel.makeKey()
    NotificationCenter.default.post(name: .panelPresented, object: nil)
  }

  @objc private func beginScreenCapture() {
    guard !isCapturingScreen else { return }
    finishExpansion()
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
    panel.orderFrontRegardless()
    panel.makeKey()
    panel.contentView?.needsLayout = true
    panel.contentView?.needsDisplay = true
    NotificationCenter.default.post(name: .panelPresented, object: nil)
  }

  func hide() {
    finishExpansion()
    panel.orderOut(nil)
    NotificationCenter.default.post(name: .panelHidden, object: nil)
  }

  func toggle() {
    guard !isCapturingScreen else { return }
    panel.isVisible ? hide() : show()
  }

  func windowDidEndLiveResize(_ notification: Notification) {
    guard normalSize == nil, selectionNormalFrame == nil else { return }
    sizeStore.save(panel.frame.size)
  }

  private func setWelcomeSizing(_ active: Bool) {
    let size: NSSize
    if active {
      guard normalSize == nil else { return }
      normalSize = panel.frame.size
      size = NSSize(width: max(1280, panel.frame.width), height: max(860, panel.frame.height))
    } else {
      guard let previous = normalSize else { return }
      size = previous
      normalSize = nil
    }
    let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
    let frame = visible.map { PanelSizeStore.centeredFrame(size: size, in: $0) }
      ?? NSRect(origin: panel.frame.origin, size: size)
    panel.setFrame(frame, display: true)
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
      // the shortcut does nothing there.
      if selectionNormalFrame == nil {
        NotificationCenter.default.post(name: .sidebarToggleRequested, object: nil)
      }
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
