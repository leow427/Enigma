import AppKit

@MainActor
final class MenuBarController: NSObject {
  private var statusItem: NSStatusItem?
  private let panelController: SpotlightPanelController
  private let updater: AppUpdater

  private static let pendingUpdateID = NSUserInterfaceItemIdentifier("pendingUpdate")
  private static let checkForUpdatesID = NSUserInterfaceItemIdentifier("checkForUpdates")

  init(panelController: SpotlightPanelController, updater: AppUpdater) {
    self.panelController = panelController
    self.updater = updater
  }

  func install() {
    guard statusItem == nil else { return }

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = item.button {
      button.image = Self.statusImage()
      button.setAccessibilityLabel("Enigma")
      button.toolTip = "Enigma"
    }

    item.menu = makeMenu()
    statusItem = item
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
