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
  /// The object is a `SelectionReplacementEnd`: whether the paste was
  /// automatic and whether it was sent.
  static let selectionReplacementEnded = Notification.Name("enigma.selectionReplacementEnded")
  static let selectionPanelResetRequested = Notification.Name("enigma.selectionPanelResetRequested")
  /// The panel went back to the window's normal frame without opening its chat there.
  static let selectionPanelRestored = Notification.Name("enigma.selectionPanelRestored")
  /// A question sent from the panel, Command-O, or the panel's Open in window
  /// button: open the panel's chat in the main window.
  static let selectionChatOpenInWindowRequested = Notification.Name("enigma.selectionChatOpenInWindowRequested")
  /// The panel's chat is now the main window's, which moves to its normal size.
  static let selectionChatOpenedInWindow = Notification.Name("enigma.selectionChatOpenedInWindow")
  /// The window finished moving from the panel to its normal frame.
  static let selectionPanelSettled = Notification.Name("enigma.selectionPanelSettled")
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
  static let recentChatCycleRequested = Notification.Name("aiSpotlight.recentChatCycleRequested")
}
