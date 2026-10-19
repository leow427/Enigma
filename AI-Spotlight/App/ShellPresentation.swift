import Foundation

/// The main window's presentation state: which panels are open, the routing mode,
/// and whether the composer should hold focus. A value type, so every transition
/// can be tested without building the view.
struct ShellPresentation: Equatable {
  /// The compact panel for asking about selected text.
  var isSelectionComposer = false
  /// The window is still sized as the selection panel, even after it expands.
  var isSelectionPresentation = false
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

  /// Double-Option with text selected opens the compact selection panel.
  mutating func beginSelectionComposer(mode: ChatMode, showsSidebar: Bool) {
    isSelectionComposer = true
    isSelectionPresentation = true
    isSelectionDetailsPresented = false
    isModePalettePresented = false
    isHelpPresented = false
    applyStartPreferences(mode: mode, showsSidebar: showsSidebar)
    isSidebarVisible = false
    isComposerFocused = true
  }

  mutating func startNewChat(mode: ChatMode, showsSidebar: Bool) {
    isSelectionComposer = false
    isSelectionPresentation = false
    applyStartPreferences(mode: mode, showsSidebar: showsSidebar)
    isModePalettePresented = false
    isComposerFocused = true
  }

  /// The selection panel grew into the full conversation.
  mutating func leaveSelectionComposer() {
    isSelectionComposer = false
    isSelectionDetailsPresented = false
  }

  /// The panel's chat opened in the main window, by double-tap Control or the
  /// Open in window button: the window's own layout, with the sidebar as the
  /// user's saved preference has it for a new chat.
  mutating func openSelectionChatInWindow(showsSidebar: Bool) {
    isSelectionComposer = false
    isSelectionPresentation = false
    isSelectionDetailsPresented = false
    isModePalettePresented = false
    isSidebarVisible = showsSidebar
    isComposerFocused = true
  }

  mutating func cycleRecentChat() {
    isSelectionComposer = false
    isSelectionPresentation = false
  }

  /// Returns true when the selection panel should be reset, because a saved chat
  /// replaced the temporary one it was showing.
  mutating func sessionChanged(isTemporaryChat: Bool) -> Bool {
    guard isSelectionPresentation, !isTemporaryChat else { return false }
    isSelectionComposer = false
    isSelectionPresentation = false
    return true
  }

  /// The selection panel shows the compact panel: its composer, then the
  /// answer it grows into. Double-tap Control opens its chat in the window
  /// instead (`openSelectionChatInWindow`); a sidebar opened some other way
  /// shows the full layout in the panel.
  var showsCompactPanel: Bool {
    isSelectionPresentation && (isSelectionComposer || !isSidebarVisible)
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
  mutating func requestBusyChanged(_ isBusy: Bool) {
    isComposerFocused = !isBusy
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
