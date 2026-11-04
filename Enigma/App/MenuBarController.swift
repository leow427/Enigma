import AppKit
import Combine

@MainActor
final class MenuBarController: NSObject {
  private var statusItem: NSStatusItem?
  private let panelController: SpotlightPanelController
  private let updater: AppUpdater
  private var pendingUpdateObservation: AnyCancellable?

  private static let pendingUpdateID = NSUserInterfaceItemIdentifier("pendingUpdate")
  private static let checkForUpdatesID = NSUserInterfaceItemIdentifier("checkForUpdates")

  init(panelController: SpotlightPanelController, updater: AppUpdater) {
    self.panelController = panelController
    self.updater = updater
  }

  func install() {
    guard statusItem == nil else { return }

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.menu = makeMenu()
    statusItem = item
    if let button = item.button { followPendingUpdate(on: button) }
  }

  /// The icon carries a dot while an update waits, and loses it once the update goes (F33).
  func followPendingUpdate(on button: NSButton) {
    pendingUpdateObservation = updater.$pendingUpdate.sink { [weak button] pending in
      if let button { Self.showStatus(on: button, updateAvailable: pending != nil) }
    }
  }

  static let updateAvailableLabel = "Enigma, update available"

  /// The status button's icon, tooltip and VoiceOver label, with or without a pending update.
  static func showStatus(on button: NSButton, updateAvailable: Bool) {
    button.image = updateAvailable ? statusImageWithBadge() : statusImage()
    let label = updateAvailable ? updateAvailableLabel : "Enigma"
    button.setAccessibilityLabel(label)
    button.toolTip = label
  }

  /// The status image with a small dot in its top-right corner, drawn into the template, so it
  /// follows the menu bar's light and dark appearance like the mark itself.
  static func statusImageWithBadge() -> NSImage? {
    guard let mark = statusImage() else { return nil }
    let image = NSImage(size: mark.size, flipped: false) { rect in
      mark.draw(in: rect)
      let side = rect.width * 0.36
      // A clear ring keeps the dot apart from the mark beneath it.
      let ring = NSRect(x: rect.maxX - side - 1, y: rect.maxY - side - 1, width: side + 2, height: side + 2)
      NSGraphicsContext.current?.compositingOperation = .clear
      NSBezierPath(ovalIn: ring).fill()
      NSGraphicsContext.current?.compositingOperation = .sourceOver
      NSColor.black.setFill()
      NSBezierPath(ovalIn: ring.insetBy(dx: 1, dy: 1)).fill()
      return true
    }
    image.isTemplate = true
    return image
  }

  func makeMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.delegate = self
    menu.addItem(makeItem(.open, action: #selector(openApp)))
    menu.addItem(makeItem(.newChat, action: #selector(startNewChat)))
    menu.addItem(makeItem(.privacyHide, action: #selector(hideApp)))
    menu.addItem(.separator())
    let pendingUpdate = makeItem(.restartToUpdate, action: #selector(performPendingUpdate))
    pendingUpdate.identifier = Self.pendingUpdateID
    pendingUpdate.isHidden = true
    menu.addItem(pendingUpdate)
    let checkForUpdates = makeItem(.checkForUpdates, action: #selector(checkForUpdates))
    checkForUpdates.identifier = Self.checkForUpdatesID
    menu.addItem(checkForUpdates)
    menu.addItem(makeItem(.reportBug, action: #selector(reportBug)))
    menu.addItem(makeItem(.settings, action: #selector(openSettings)))
    menu.addItem(.separator())
    menu.addItem(makeItem(.quit, action: #selector(quitApp)))
    menuNeedsUpdate(menu)
    return menu
  }

  /// The status item's image: the character's monochrome template, drawn from
  /// its still pose (see `EnigmaAppIcon`), at the menu bar's 18 pt. A copy, so
  /// resizing it leaves the asset's other uses alone.
  static func statusImage() -> NSImage? {
    let logo = NSImage(named: "EnigmaMenuBarMark")?.copy() as? NSImage
    logo?.size = NSSize(width: EnigmaAppIcon.menuBarSide, height: EnigmaAppIcon.menuBarSide)
    logo?.isTemplate = true
    return logo
  }

  private func makeItem(_ command: AppCommand, action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: command.rawValue, action: action, keyEquivalent: "")
    item.target = self
    return item
  }

  @objc private func openApp() {
    panelController.show()
  }

  @objc private func startNewChat() {
    panelController.show()
    NotificationCenter.default.post(name: .newChatRequested, object: nil)
  }

  @objc private func hideApp() {
    panelController.hide()
  }

  @objc private func openSettings() {
    NotificationCenter.default.post(name: .settingsRequested, object: nil)
  }

  @objc private func reportBug() {
    NotificationCenter.default.post(name: .bugReportRequested, object: nil)
  }

  @objc private func quitApp() {
    NSApp.terminate(nil)
  }

  @objc private func performPendingUpdate() {
    updater.performPendingUpdate()
  }

  @objc private func checkForUpdates() {
    updater.checkForUpdates()
  }
}

extension MenuBarController: NSMenuDelegate {
  func menuNeedsUpdate(_ menu: NSMenu) {
    for item in menu.items {
      switch item.identifier {
      case Self.pendingUpdateID:
        item.isHidden = updater.pendingUpdate == nil
        item.title = updater.pendingUpdate?.menuTitle ?? AppCommand.restartToUpdate.rawValue
      case Self.checkForUpdatesID:
        item.isEnabled = updater.canCheckForUpdates
      default:
        break
      }
    }
  }
}
