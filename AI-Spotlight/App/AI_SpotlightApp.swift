import AppKit
import Combine
import SwiftUI

@main
struct EnigmaApp: App {
  @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate

  var body: some Scene {
    Settings {
      SettingsWindowContent(newUI: .shared, appearance: .shared)
    }
    .commands {
      CommandGroup(replacing: .appSettings) {
        Button("Settings…") {
          NotificationCenter.default.post(name: .settingsRequested, object: nil)
        }
        .keyboardShortcut(",", modifiers: .command)
      }
    }
  }
}

/// How the Settings window itself looks. The old design forces dark mode on
/// the forest color. The new one follows the appearance setting, draws the
/// palette's background, and lets its backgrounds run under the title bar.
struct SettingsWindowChrome: Equatable {
  let appearanceName: NSAppearance.Name?
  /// Backgrounds run under the transparent title bar, and the title is hidden.
  /// The content still lays out below it, so the window keeps its size.
  let extendsUnderTitleBar: Bool
  let usesPaletteBackground: Bool

  static func chrome(newUI: Bool, appearance: EnigmaAppearance) -> SettingsWindowChrome {
    newUI
      ? SettingsWindowChrome(appearanceName: appearance.windowAppearanceName, extendsUnderTitleBar: true,
                             usesPaletteBackground: true)
      : SettingsWindowChrome(appearanceName: .darkAqua, extendsUnderTitleBar: false, usesPaletteBackground: false)
  }

  @MainActor var backgroundColor: NSColor {
    usesPaletteBackground ? EnigmaAppearance.windowBackground : NSColor(NatureGlass.forestTop)
  }
}

/// The Settings window keeps the appearance its controller gives it. The
/// SwiftUI content's color-scheme preference also sets the window's
/// appearance, but a step behind the flag, so it's ignored once locked.
final class SettingsWindow: NSWindow {
  private var isAppearanceLocked = false
  private var lockedAppearance: NSAppearance?

  func lockAppearance(_ appearance: NSAppearance?) {
    lockedAppearance = appearance
    isAppearanceLocked = true
    super.appearance = appearance
  }

  override var appearance: NSAppearance? {
    get { super.appearance }
    set { super.appearance = isAppearanceLocked ? lockedAppearance : newValue }
  }
}

@MainActor
final class SettingsWindowController: NSWindowController {
  static let contentSize = NSSize(width: 820, height: 680)
  private let newUI: NewUIPreference
  private let appearance: EnigmaAppearancePreference
  private var observations: Set<AnyCancellable> = []

  convenience init() {
    self.init(contentView: Self.hostingView(SettingsWindowContent(newUI: .shared, appearance: .shared)))
  }

  static func hostingView<Content: View>(_ content: Content) -> NSView {
    NSHostingView(rootView: content)
  }

  /// The window's look follows `newUI` and `appearance` while it's open.
  init(contentView: NSView, newUI: NewUIPreference = .shared, appearance: EnigmaAppearancePreference = .shared) {
    self.newUI = newUI
    self.appearance = appearance
    let window = SettingsWindow(
      contentRect: NSRect(origin: .zero, size: Self.contentSize),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Enigma Settings"
    window.titlebarAppearsTransparent = true
    // Apply the same best-effort capture exclusion as the chat panel.
    window.sharingType = .none
    // Match the chat panel's level so Settings can appear in front without hiding it.
    window.level = .floating
    window.isReleasedWhenClosed = false
    window.contentView = contentView
    super.init(window: window)
    apply(.chrome(newUI: newUI.isEnabled, appearance: appearance.appearance))
    window.center()
    // Published values arrive before they're stored; apply them once they are,
    // on the next turn of the main queue, so SwiftUI sees the change first.
    newUI.$isEnabled.dropFirst().removeDuplicates().map { _ in () }
      .merge(with: appearance.$appearance.dropFirst().removeDuplicates().map { _ in () })
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in
        guard let self else { return }
        apply(.chrome(newUI: self.newUI.isEnabled, appearance: self.appearance.appearance))
      }
      .store(in: &observations)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func apply(_ chrome: SettingsWindowChrome) {
    guard let window = window as? SettingsWindow else { return }
    window.lockAppearance(chrome.appearanceName.flatMap(NSAppearance.init(named:)))
    window.backgroundColor = chrome.backgroundColor
    window.titleVisibility = chrome.extendsUnderTitleBar ? .hidden : .visible
    guard window.styleMask.contains(.fullSizeContentView) != chrome.extendsUnderTitleBar else { return }
    // The frame stays put: SwiftUI lays the content out below the title bar
    // either way, so the area under it stays 820 × 680. Changing the style
    // resizes the window, so put the frame back.
    let frame = window.frame
    if chrome.extendsUnderTitleBar {
      window.styleMask.insert(.fullSizeContentView)
    } else {
      window.styleMask.remove(.fullSizeContentView)
    }
    window.setFrame(frame, display: window.isVisible)
  }

  func showSettings(destination: SettingsView.SettingsDestination? = nil) {
    // The chat's standalone NSHostingView has no SwiftUI settings-scene action.
    NSApp.unhide(nil)
    NSApp.activate(ignoringOtherApps: true)
    window?.deminiaturize(nil)
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    if let destination {
      window?.contentView?.layoutSubtreeIfNeeded()
      NotificationCenter.default.post(name: .settingsDestinationRequested, object: destination)
    }
  }
}
