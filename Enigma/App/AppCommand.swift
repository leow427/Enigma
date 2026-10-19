import Foundation

enum AppCommand: String, CaseIterable {
  case open = "Open"
  case newChat = "New Chat"
  case privacyHide = "Privacy Hide"
  case restartToUpdate = "Restart to Update"
  case checkForUpdates = "Check for Updates…"
  case settings = "Settings"
  case quit = "Quit"
}

extension Notification.Name {
  static let selectionReplacementBegan = Notification.Name("enigma.selectionReplacementBegan")
  static let selectionReplacementEnded = Notification.Name("enigma.selectionReplacementEnded")
  static let selectionPanelExpandRequested = Notification.Name("enigma.selectionPanelExpandRequested")
  static let selectionPanelResetRequested = Notification.Name("enigma.selectionPanelResetRequested")
  static let selectionPanelExpanded = Notification.Name("enigma.selectionPanelExpanded")
  /// Double-tap Control or the panel's Open in window button: open the panel's chat in the main window.
  static let selectionChatOpenInWindowRequested = Notification.Name("enigma.selectionChatOpenInWindowRequested")
  /// The panel's chat is now the main window's, at the window's normal size.
  static let selectionChatOpenedInWindow = Notification.Name("enigma.selectionChatOpenedInWindow")
  static let selectionComposerHeightChanged = Notification.Name("enigma.selectionComposerHeightChanged")
  /// The compact panel was placed; the object is the room under it on screen.
  static let selectionPanelPlaced = Notification.Name("enigma.selectionPanelPlaced")
  static let selectionContextRequested = Notification.Name("enigma.selectionContextRequested")
  static let sidebarToggleRequested = Notification.Name("aiSpotlight.sidebarToggleRequested")
  static let fileModeRequested = Notification.Name("aiSpotlight.fileModeRequested")
  static let settingsRequested = Notification.Name("aiSpotlight.settingsRequested")
  static let settingsDestinationRequested = Notification.Name("enigma.settingsDestinationRequested")
  static let newChatRequested = Notification.Name("aiSpotlight.newChatRequested")
  static let modePaletteRequested = Notification.Name("aiSpotlight.modePaletteRequested")
  static let panelHidden = Notification.Name("aiSpotlight.panelHidden")
  static let panelPresented = Notification.Name("aiSpotlight.panelPresented")
  static let stopStreamingRequested = Notification.Name("aiSpotlight.stopStreamingRequested")
  static let hideInactiveToolsRequested = Notification.Name("aiSpotlight.hideInactiveToolsRequested")
  static let recentChatCycleRequested = Notification.Name("aiSpotlight.recentChatCycleRequested")
}
