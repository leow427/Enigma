import Foundation

/// The main window's presentation state: which panels are open, the routing mode,
/// and whether the composer should hold focus. A value type, so every transition
/// can be tested without building the view.
struct ShellPresentation: Equatable {
  /// The compact panel for asking about selected text. It lasts until its
  /// chat moves to the window's own layout: by sending a question, ⌘O, or
  /// Open in window.
  var isSelectionComposer = false
  /// The window is still moving from the panel to its normal frame, so its
  /// layout mustn't hold it to the window's minimum height on the way.
  var isSettlingIntoWindow = false
  var isSelectionDetailsPresented = false
  var isSidebarVisible: Bool
  var selectedMode: ChatMode
  var isModePalettePresented = false
  var isHelpPresented = false
  var isComposerFocused = false
  var expandedActivities: Set<UUID> = []

  init(mode: ChatMode, showsSidebar: Bool) {
    selectedMode = mode
    isSidebarVisible = showsSidebar
  }

  mutating func applyStartPreferences(mode: ChatMode, showsSidebar: Bool) {
    selectedMode = mode
    isSidebarVisible = showsSidebar
  }

  /// The selection shortcut (a double tap, or ⇧⌥Space) opens the compact selection
  /// panel.
  mutating func beginSelectionComposer(mode: ChatMode, showsSidebar: Bool) {
    isSelectionComposer = true
    isSelectionDetailsPresented = false
    isModePalettePresented = false
    isHelpPresented = false
    applyStartPreferences(mode: mode, showsSidebar: showsSidebar)
    isSidebarVisible = false
    isComposerFocused = true
  }

  mutating func startNewChat(mode: ChatMode, showsSidebar: Bool) {
    isSelectionComposer = false
    applyStartPreferences(mode: mode, showsSidebar: showsSidebar)
    isModePalettePresented = false
    isComposerFocused = true
  }

  /// The window went back to its normal frame without opening the panel's
  /// chat in it, as a new chat or another chat does: its own layout.
  mutating func leaveSelectionPanel() {
    isSelectionComposer = false
    isSelectionDetailsPresented = false
  }

  /// The panel's chat opened in the main window, by sending a question,
  /// Command-O, or the Open in window button: the window's own layout, with
  /// the sidebar as the user's saved preference has it for a new chat.
  mutating func openSelectionChatInWindow(showsSidebar: Bool) {
    isSelectionComposer = false
    isSettlingIntoWindow = true
    isSelectionDetailsPresented = false
    isModePalettePresented = false
    isSidebarVisible = showsSidebar
    isComposerFocused = true
  }

  mutating func cycleRecentChat() {
    isSelectionComposer = false
  }

  /// Returns true when the selection panel should be reset, because a saved chat
  /// replaced the temporary one it was showing.
  mutating func sessionChanged(isTemporaryChat: Bool) -> Bool {
    guard isSelectionComposer, !isTemporaryChat else { return false }
    isSelectionComposer = false
    return true
  }

  /// Errors are hidden behind the selection panel's status button, so open it.
  mutating func revealSelectionProblem() {
    if isSelectionComposer { isSelectionDetailsPresented = true }
  }

  mutating func chooseMode(_ mode: ChatMode) {
    selectedMode = mode
    isModePalettePresented = false
    isComposerFocused = true
  }

  mutating func dismissModePalette() {
    isModePalettePresented = false
    isComposerFocused = true
  }

  /// Settings opens in its own window, which takes focus.
  mutating func prepareForSettings() {
    isModePalettePresented = false
    isComposerFocused = false
  }

  /// A disabled editor can't take focus, so focus returns only once the request ends.
  /// One that stays editable while the chat is busy, as during a reply, takes it
  /// at once, so the next message can be typed even after clicking Send.
  mutating func requestBusyChanged(_ isBusy: Bool, composerStaysEditable: Bool = false) {
    isComposerFocused = !isBusy || composerStaysEditable
  }

  mutating func welcomeChanged(isPresented: Bool, isTourActive: Bool) {
    isComposerFocused = !isPresented && !isTourActive
    if !isPresented { selectedMode = .auto }
    if isPresented {
      isModePalettePresented = false
      isHelpPresented = false
    }
  }

  mutating func tourChanged(isActive: Bool, isWelcomePresented: Bool) {
    isComposerFocused = !isActive && !isWelcomePresented
  }

  func isActivityExpanded(_ id: UUID) -> Bool {
    expandedActivities.contains(id)
  }

  mutating func setActivity(_ id: UUID, expanded: Bool) {
    if expanded { expandedActivities.insert(id) } else { expandedActivities.remove(id) }
  }
}
