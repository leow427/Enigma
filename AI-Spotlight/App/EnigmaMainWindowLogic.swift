import CoreGraphics
import Foundation

// Logic the new main window shares with the old one, or that its views would
// otherwise hide inline: the greeting, the route status line and indicator,
// the character's state, the mode and model menu, the slash command examples,
// and how the main page fits a small window. Each is a plain value, so it can
// be tested without building a view.

// MARK: Greeting

enum MainPageGreeting {
  /// A short greeting for the hour, from 0 to 23, as in the mockup.
  static func text(hour: Int) -> String {
    let time = hour < 12 ? "Morning." : hour < 18 ? "Afternoon." : "Evening."
    return time + " What are we poking at?"
  }

  static func text(at date: Date, calendar: Calendar = .current) -> String {
    text(hour: calendar.component(.hour, from: date))
  }
}

// MARK: Route status

/// What the window says about the selected route: a short monospace line, and
/// an action when something is missing. The old window shows the same states
/// next to its composer.
struct ChatRouteStatus: Equatable {
  enum Kind: Equatable {
    /// Ready to answer.
    case ready
    /// Waiting on a model task or a request.
    case busy
    /// Something needed is missing, like a model or a sign-in.
    case missing
    /// The route can't run as chosen, or the last request failed.
    case problem
  }

  enum Action: Equatable {
    /// Import a GGUF model file.
    case chooseModel
    case openSettings
  }

  let kind: Kind
  let text: String
  var action: Action?

  /// A running request: its phase, like `Preparing…`, and its name, like `Local · Qwen`.
  struct Request: Equatable {
    let phase: String
    let name: String
  }

  /// The route's state, from the same values the old status views read.
  struct Context: Equatable {
    var mode: ChatMode
    var state: LocalChatViewModel.State = .idle
    var request: Request?
    var localModelName: String?
    var cloudProvider: CloudProviderID = .chatGPT
    var hasCloudAccess = false
    var isCloudConfigured = false
    var cloudCompatibility: CloudModelCompatibility = .unselected
    var cloudModelID = ""
    var autoDecision: AutoRouter.Decision?
    /// Auto has a configured cloud model to fall back on.
    var hasAutoCloud = false
  }

  static func make(_ context: Context) -> ChatRouteStatus {
    if let request = context.request {
      return ChatRouteStatus(kind: .busy, text: "\(request.phase) · \(request.name)")
    }
    switch context.mode {
    case .local: return local(context)
    case .cloud: return cloud(context)
    case .auto: return auto(context)
    }
  }

  private static func local(_ context: Context) -> ChatRouteStatus {
    switch context.state {
    case .benchmarking: ChatRouteStatus(kind: .busy, text: "Checking model performance…")
    case .installing: ChatRouteStatus(kind: .busy, text: "Installing local model…")
    case .deleting: ChatRouteStatus(kind: .busy, text: "Deleting local model…")
    case .downloading(let progress):
      ChatRouteStatus(kind: .busy, text: "Downloading \(Int((progress.fractionCompleted * 100).rounded()))%")
    case .preparing, .refiningSearch, .searching: ChatRouteStatus(kind: .busy, text: "Loading local model…")
    case .streaming: ChatRouteStatus(kind: .busy, text: "Generating locally")
    case .failed(let message): ChatRouteStatus(kind: .problem, text: message)
    case .idle:
      if let name = context.localModelName {
        ChatRouteStatus(kind: .ready, text: "\(name) is ready · on this Mac")
      } else {
        ChatRouteStatus(kind: .missing, text: "A local GGUF model is required.", action: .chooseModel)
      }
    }
  }

  private static func cloud(_ context: Context) -> ChatRouteStatus {
    let provider = context.cloudProvider
    guard context.hasCloudAccess else {
      let text = switch provider {
      case .chatGPT: "Sign in with ChatGPT to use your Codex allowance."
      case .claudeCode: "Sign in to Claude Code to use your Claude plan."
      default: "Add a \(provider.displayName) API key."
      }
      return ChatRouteStatus(kind: .missing, text: text, action: .openSettings)
    }
    guard context.isCloudConfigured else {
      return ChatRouteStatus(kind: .problem, text: context.cloudCompatibility.message, action: .openSettings)
    }
    switch context.state {
    case .preparing, .refiningSearch, .searching:
      return ChatRouteStatus(kind: .busy, text: "Connecting to \(provider.displayName)…")
    case .streaming:
      return ChatRouteStatus(kind: .busy, text: "Streaming from \(provider.displayName)")
    case .failed(let message):
      return ChatRouteStatus(kind: .problem, text: message)
    case .idle:
      let unverified = context.cloudCompatibility == .unverified ? " · unverified" : ""
      return ChatRouteStatus(kind: .ready, text: "\(provider.displayName) · \(context.cloudModelID)\(unverified) · in the cloud")
    case .installing, .deleting, .downloading, .benchmarking:
      return ChatRouteStatus(kind: .busy, text: "Finish the local model task before using Cloud mode.")
    }
  }

  private static func auto(_ context: Context) -> ChatRouteStatus {
    if case .failed(let message) = context.state { return ChatRouteStatus(kind: .problem, text: message) }
    if let decision = context.autoDecision {
      if let route = decision.route {
        let working = context.state == .preparing || context.state == .streaming
        return ChatRouteStatus(kind: working ? .busy : .ready,
                               text: "Auto · \(route.mode.displayName) · \(decision.modelDisplayName ?? route.modelID)")
      }
      if let limitation = decision.limitation {
        return ChatRouteStatus(kind: .problem, text: limitation.message)
      }
    }
    if let name = context.localModelName, !context.hasAutoCloud {
      return ChatRouteStatus(kind: .ready, text: "Cloud isn’t connected; Auto stays local · \(name)")
    }
    if context.localModelName != nil || context.hasAutoCloud {
      return ChatRouteStatus(kind: .ready, text: "Auto chooses the lowest-latency capable model.")
    }
    return ChatRouteStatus(kind: .missing, text: "Choose a local model or connect Cloud to use Auto.")
  }

  var lineStatus: EnigmaStatusLine.Status {
    switch kind {
    case .ready: .on
    case .busy: .busy
    case .missing: .off
    case .problem: .problem
    }
  }

  var actionTitle: String? {
    switch action {
    case .chooseModel: "Choose a GGUF model…"
    case .openSettings: "Open Settings"
    case nil: nil
    }
  }
}

// MARK: Route indicator

/// The composer's `● local` or `○ cloud`: where the next request runs.
enum ComposerRouteIndicator: Equatable {
  case local
  case cloud

  /// The running request's route wins. Auto shows its latest decision, then
  /// whichever route it can use. Nil when no route can run.
  static func make(mode: ChatMode, requestMode: ChatMode?, autoDecisionMode: ChatMode?,
                   hasLocalModel: Bool, hasAutoCloud: Bool) -> ComposerRouteIndicator? {
    if let requestMode { return requestMode == .cloud ? .cloud : .local }
    switch mode {
    case .local: return .local
    case .cloud: return .cloud
    case .auto:
      if let autoDecisionMode { return autoDecisionMode == .cloud ? .cloud : .local }
      if hasLocalModel { return .local }
      return hasAutoCloud ? .cloud : nil
    }
  }

  var text: String { self == .local ? "● local" : "○ cloud" }
  var accessibilityLabel: String { self == .local ? "Runs on this Mac" : "Runs in the cloud" }
}

// MARK: Character

/// What the window's character does outside the welcome.
enum MainWindowCharacter {
  /// The main page's 92 pt slot.
  static let mainSlot: EnigmaCharacterSlotID = "main.hero"
  static let mainSlotSize: CGFloat = 92
  /// The composer, which the character turns toward while someone types.
  static let composerTarget: EnigmaCharacterTargetID = "main.composer"

  struct Inputs: Equatable {
    /// A request is preparing or searching, or a capture, file pick, or model task is running.
    var isWorking = false
    var isStreaming = false
    /// The route can't run as chosen: something is missing or broken.
    var routeCanRun = true
    var hasProblem = false
    /// The composer has focus and holds a draft.
    var isTyping = false
  }

  /// It answers while a reply streams, thinks while work is underway, shows
  /// the error state when the route can't run, and listens while someone types.
  static func state(_ inputs: Inputs) -> EnigmaCharacterState {
    if inputs.isStreaming { return .answering }
    if inputs.isWorking { return .thinking }
    if inputs.hasProblem || !inputs.routeCanRun { return .error }
    if inputs.isTyping { return .listening }
    return .idle
  }
}

// MARK: Mode and model menu

/// The rows of the composer's mode and model menu, which is also the mode
/// palette that ⌘K opens. Mode rows choose where requests run. Model rows
/// choose the local or cloud model that the mode uses.
struct ModeAndModelMenu {
  struct LocalChoice: Equatable {
    let id: String
    let name: String
    let supportsVision: Bool
  }

  struct CloudChoice: Equatable {
    let id: String
    let name: String
    let supportsVision: Bool
  }

  struct Actions {
    var chooseMode: (ChatMode) -> Void
    var selectLocalModel: (String) -> Void
    var selectCloudModel: (String) -> Void
    var findModel: () -> Void
    var importModel: () -> Void
    var openSettings: () -> Void
  }

  var mode: ChatMode
  var isBusy: Bool
  /// The request in flight keeps its route; a new choice applies to the next one.
  var hasActiveRequest: Bool
  var localModels: [LocalChoice]
  var selectedLocalID: String?
  var cloudProvider: CloudProviderID
  var cloudModels: [CloudChoice]
  var selectedCloudID: String

  static func modeDetail(_ mode: ChatMode, provider: CloudProviderID) -> String {
    switch mode {
    case .auto: "on this Mac, cloud only when needed"
    case .local: "stays on this Mac"
    case .cloud: "sent to \(provider.displayName)"
    }
  }

  /// What the trigger shows: the mode, or the model a fixed mode uses.
  var label: String {
    switch mode {
    case .auto: return "Auto"
    case .local: return localModels.first { $0.id == selectedLocalID }?.name ?? "Choose model"
    case .cloud: return selectedCloudID.isEmpty ? "Choose cloud model" : selectedCloudID
    }
  }

  var modeSectionTitle: String { hasActiveRequest ? "Next request" : "Mode" }

  func sections(_ actions: Actions) -> [EnigmaMenuSection] {
    var sections = [EnigmaMenuSection(modeSectionTitle, items: ChatMode.allCases.map { option in
      EnigmaMenuItem(id: AnyHashable("mode.\(option.rawValue)"), title: option.displayName,
                     detail: Self.modeDetail(option, provider: cloudProvider), isSelected: option == mode) {
        actions.chooseMode(option)
      }
    })]
    if mode != .cloud {
      let items = localModels.isEmpty
        ? [EnigmaMenuItem(id: AnyHashable("local.none"), title: "No installed models", isEnabled: false) {}]
        : localModels.map { model in
          EnigmaMenuItem(id: AnyHashable("local.\(model.id)"), title: model.name,
                         detail: model.supportsVision ? "text + images" : "text only",
                         isSelected: model.id == selectedLocalID, isEnabled: !isBusy) {
            actions.selectLocalModel(model.id)
          }
        }
      sections.append(EnigmaMenuSection("On this Mac", items: items))
    }
    if mode != .local {
      let items = cloudModels.isEmpty
        ? [EnigmaMenuItem(id: AnyHashable("cloud.none"), title: "No discovered models", isEnabled: false) {}]
        : cloudModels.map { model in
          EnigmaMenuItem(id: AnyHashable("cloud.\(model.id)"), title: model.name,
                         detail: model.supportsVision ? "text + images" : "text only",
                         isSelected: model.id == selectedCloudID, isEnabled: !isBusy) {
            actions.selectCloudModel(model.id)
          }
        }
      sections.append(EnigmaMenuSection(cloudProvider.displayName, items: items))
    }
    var more: [EnigmaMenuItem] = []
    if mode != .cloud {
      more.append(EnigmaMenuItem(id: AnyHashable("action.find"), title: "Find a model for this Mac…",
                                 isEnabled: !isBusy, action: actions.findModel))
      more.append(EnigmaMenuItem(id: AnyHashable("action.import"), title: "Import a text GGUF…",
                                 isEnabled: !isBusy, action: actions.importModel))
    }
    more.append(EnigmaMenuItem(id: AnyHashable("action.settings"),
                               title: mode == .cloud ? "Advanced settings…" : "Manage models in Settings…",
                               isEnabled: !isBusy, action: actions.openSettings))
    sections.append(EnigmaMenuSection(items: more))
    return sections
  }
}

// MARK: Slash command examples

/// A command written as an example line on the main page, like
/// `› /translate "Bạn khỏe không?" ⟶ "How are you?"`.
struct SlashCommandExample: Equatable, Identifiable {
  let command: SlashCommand
  /// What follows the command, like a quoted question. Nil for a bare command.
  let argument: String?
  /// What comes back.
  let result: String

  var id: SlashCommand { command }

  /// The order the main page lists commands in, most useful first.
  static let order: [SlashCommand] = [.screen, .search, .edit, .translate, .think, .snapshot, .messages]

  static func example(for command: SlashCommand) -> SlashCommandExample {
    switch command {
    case .screen: SlashCommandExample(command: command, argument: nil, result: "ask about what’s on screen")
    case .snapshot: SlashCommandExample(command: command, argument: nil, result: "ask about part of the screen")
    case .search: SlashCommandExample(command: command, argument: "\"macos 26.1 date\"", result: "an answer with sources")
    case .think: SlashCommandExample(command: command, argument: "a hard question", result: "a more careful answer")
    case .edit: SlashCommandExample(command: command, argument: "[selection]", result: "a tighter draft")
    case .translate: SlashCommandExample(command: command, argument: "\"Bạn khỏe không?\"", result: "\"How are you?\"")
    case .messages: SlashCommandExample(command: command, argument: "\"what did Sam say?\"", result: "from your Messages")
    }
  }

  /// Examples for the commands that are available, in `order`, at most `limit`.
  static func examples(available: [SlashCommand], limit: Int = 4) -> [SlashCommandExample] {
    Array(order.filter(available.contains).prefix(max(0, limit)).map(example(for:)))
  }
}

// MARK: Layout

/// How the main page fits its window: the sidebar's width, and how much of the
/// empty page's header and how many example lines fit above and below the
/// composer. Heights are in points.
struct MainPageLayout: Equatable {
  enum Header: Equatable {
    /// The character's slot, the greeting, the status line, and the controls.
    case full
    /// Everything but the character.
    case compact
    /// Nothing: the composer needs the room.
    case hidden
  }

  /// Above the slot, where the antenna reaches.
  static let slotTopPadding: CGFloat = 34
  /// The slot and the space under it.
  static let slotBlock: CGFloat = MainWindowCharacter.mainSlotSize + 14
  static let compactTopPadding: CGFloat = 24
  static let headerGap: CGFloat = 18
  /// Between the accessories and the composer.
  static let accessoriesSpacing: CGFloat = 8
  static let exampleLineHeight: CGFloat = 26
  static let examplesTopPadding: CGFloat = 12
  static let bottomPadding: CGFloat = 16
  static let maximumExamples = 4

  let header: Header
  let exampleCount: Int
  /// The tallest the accessories above the composer may be before they scroll.
  let accessoriesLimit: CGFloat

  /// `info` is the measured greeting, status, and controls; `composer` and
  /// `accessories` are measured too, and `topBar` is the hidden sidebar's bar.
  /// The greeting and status come before the character, and both before the
  /// example lines.
  init(height: CGFloat, topBar: CGFloat, info: CGFloat, composer: CGFloat, accessories: CGFloat,
       availableExamples: Int) {
    let room = max(0, height - topBar - composer - Self.accessoriesSpacing - Self.bottomPadding)
    accessoriesLimit = max(0, room - 40)
    let available = room - min(accessories, accessoriesLimit)
    let full = Self.headerHeight(.full, info: info)
    let compact = Self.headerHeight(.compact, info: info)
    header = available >= full ? .full : available >= compact ? .compact : .hidden
    let left = available - Self.headerHeight(header, info: info) - Self.examplesTopPadding
    let fitting = header != .full || left < Self.exampleLineHeight
      ? 0 : Int((left / Self.exampleLineHeight).rounded(.down))
    exampleCount = min(fitting, availableExamples, Self.maximumExamples)
  }

  /// The header's height in each style, with the gap under it.
  static func headerHeight(_ header: Header, info: CGFloat) -> CGFloat {
    switch header {
    case .full: slotTopPadding + slotBlock + info + headerGap
    case .compact: compactTopPadding + info + headerGap
    case .hidden: 0
    }
  }

  /// The sidebar takes about a fifth of the window, within readable bounds.
  static func sidebarWidth(for windowWidth: CGFloat) -> CGFloat {
    min(240, max(190, (windowWidth * 0.2).rounded()))
  }

  /// The empty page's column, so lines stay readable in a wide window.
  static let columnMaximumWidth: CGFloat = 680
}

// MARK: Help

/// The shortcuts Help lists. The old and new Help both read them, so they
/// can't drift apart.
enum KeyboardShortcutsHelp {
  struct Shortcut: Equatable, Hashable {
    let title: String
    let keys: String

    init(_ title: String, _ keys: String) {
      self.title = title
      self.keys = keys
    }

    /// The keys as the new design writes them: modifier symbols run together
    /// with a single following key, like `⌘N` and `⌥⌃`, while words keep
    /// their spaces, like `⌃ Tab`.
    var compactKeys: String {
      let modifiers: Set<Character> = ["⌘", "⌥", "⌃", "⇧"]
      let parts = keys.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
      var result = ""
      for (index, part) in parts.enumerated() {
        if index > 0 {
          let previous = parts[index - 1]
          let joins = previous.count == 1 && previous.first.map(modifiers.contains) == true && part.count == 1
          result += joins ? "" : " "
        }
        result += part
      }
      return result
    }
  }

  static func selectionChat(modifier: SelectionModifier) -> Shortcut {
    Shortcut("New temporary chat with selection", "\(modifier.symbol) twice")
  }

  static let selectionBackup = Shortcut("Selection Context backup", "⇧ ⌥ Space")
  static let selectionNote = "Highlight text in another app, then tap the chosen key twice by itself (Option by default). Context stays in a temporary chat and follows your selected model and Web Search settings. Use /edit with your instructions to get a revised-text card with Edit and Replace text. Questions stay read-only. Use /translate to translate to English, or name another language. Settings → Selection Context offers automatic replacement without a preview. Replacement pastes into the selection currently active in the source app. Your clipboard is preserved. Password fields are excluded."

  static func accessibilityNote(appName: String) -> String {
    "System Settings → Privacy & Security → Accessibility. Enable \(appName) (Enigma). If it is missing, use + to add the app you are running."
  }

  static let showOrHide = Shortcut("Show or hide Enigma", "⌥ ⌃")
  static let showOrHideNote = "Press Option and Control together. Accessibility permission lets this shortcut work while another app is active."
  static let advancedSettings = Shortcut("Open Advanced Settings", "⌥ S")

  static let panel: [Shortcut] = [
    Shortcut("Hide the panel", "Esc"),
    Shortcut("New chat", "⌘ N"),
    Shortcut("Open or close Mode & Model", "⌘ K"),
    Shortcut("Stop the response", "⌘ ."),
    Shortcut("Next recent chat", "⌃ Tab"),
    Shortcut("Show or hide chat history", "⌃ twice"),
    Shortcut("Open Settings", "⌘ ,"),
    Shortcut("Send from the message field", "Return"),
    Shortcut("Complete a slash command", "Tab / Return"),
    Shortcut("Choose a command suggestion", "↑ / ↓"),
    Shortcut("Dismiss command suggestions", "Esc"),
    Shortcut("Insert a new line", "⇧ Return"),
    Shortcut("Hide inactive tools", "⇧ ⌘ H"),
  ]

  static let search = Shortcut("Search for this message only", "/search")
  static let searchNote = "/search applies to one answer. Delete it before sending to cancel explicit search. Automatic search is controlled in Settings → Cloud & Search → Web Search · Brave."

  static let commands: [Shortcut] = [
    Shortcut("Capture the full desktop", "/screen"),
    Shortcut("Capture a screen region", "/snapshot"),
    Shortcut("Think harder for this answer", "/think"),
    Shortcut("Attach files or a folder", "⇧ ⌥ F"),
  ]

  /// The old design colors commands blue; the new one in `accentText`.
  static func commandsNote(newDesign: Bool = false) -> String {
    "/screen captures all displays; /snapshot selects a region. Add a question to capture and send, or use the command alone to attach. /think applies to one answer. Commands can appear anywhere in your message and remain \(newDesign ? "highlighted" : "blue") in the input. Put literal command examples in quotes or backticks."
  }

  static let editing: [Shortcut] = [
    Shortcut("Select all", "⌘ A"),
    Shortcut("Copy", "⌘ C"),
    Shortcut("Cut", "⌘ X"),
    Shortcut("Paste", "⌘ V"),
    Shortcut("Undo", "⌘ Z"),
    Shortcut("Redo", "⇧ ⌘ Z"),
  ]

  static let legend = "⌘ Command · ⌥ Option · ⌃ Control · ⇧ Shift"

  /// The double-tap speeds, with the seconds they allow between taps.
  static let intervals: [(title: String, seconds: Double)] = [("Fast", 0.25), ("Normal", 0.35), ("Relaxed", 0.5)]
}
