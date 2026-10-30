import AppKit
import Combine
import Foundation
import Synchronization

@MainActor
final class LocalChatViewModel: ObservableObject {
  static let shared = LocalChatViewModel(engine: LlamaCPPModelEngine(), modelAdvisor: .shared, searchSettings: .shared,
                                         locationProvider: LocationService.shared, nativeToolsEnabled: NativeTools.isEnabled)

  /// The chat's request lifecycle. Model installs report through `modelOperation`.
  enum State: Equatable {
    case idle
    case preparing
    case refiningSearch
    case searching
    case streaming
    case failed(String)
  }

  /// Installing, deleting or measuring a local model, separate from chat.
  enum ModelOperation: Equatable {
    case downloading(ModelDownloadProgress)
    case waitingToInstall
    case installing
    case deleting
    case benchmarking

    /// A download runs beside chat. Committing an install, deleting and the
    /// performance check change or measure the engines, so chat waits for them.
    var blocksChat: Bool {
      switch self {
      case .downloading, .waitingToInstall: false
      case .installing, .deleting, .benchmarking: true
      }
    }
  }

  struct ActiveRequest: Equatable {
    let id: UUID
    let route: Route
    let modelDisplayName: String

    var displayName: String {
      if route.mode == .local { return "Local · \(modelDisplayName)" }
      let provider = CloudProviderID(rawValue: route.providerID)?.displayName ?? route.providerID
      return "Cloud · \(provider) · \(modelDisplayName)"
    }
  }

  typealias Sleep = @Sendable (Duration) async throws -> Void

  @Published private(set) var sessions: [ChatSession]
  @Published private(set) var selectedSessionID: UUID?
  /// The chat whose last accepted request used Messages, typed or recognized. It lets a
  /// follow-up like "send her a message saying …" carry Messages over. In memory only:
  /// cleared by any other accepted request, a new chat, and switching chats.
  @Published private(set) var messagesFollowUpSessionID: UUID?
  var previousTurnUsedMessages: Bool {
    messagesFollowUpSessionID != nil && messagesFollowUpSessionID == selectedSessionID
  }
  @Published private(set) var installedModel: LocalModel?
  @Published private(set) var installedModels: [LocalModel] = []
  @Published private(set) var contextNotice: String?
  @Published private(set) var activity: AssistantActivity?
  private var activityMessageID: UUID?
  @Published private(set) var activeRequest: ActiveRequest? {
    didSet { lastRequestActivityAt = .now }
  }
  @Published private(set) var autoRouteDecision: AutoRouter.Decision?
  @Published private(set) var screenRouteDecision: ScreenRoutingPolicy.Decision?
  @Published private(set) var state: State = .idle {
    didSet { lastRequestActivityAt = .now }
  }
  /// When a request last started, streamed, or ended, failed or not. In
  /// memory only: a failure doesn't move its chat in Recents, but it still
  /// counts as use for the 5-minute return.
  private(set) var lastRequestActivityAt: Date?
  @Published private(set) var modelOperation: ModelOperation?
  /// The last install, delete or model switch failure, apart from the chat's
  /// own `state`. Cleared when the next model operation starts.
  @Published private(set) var modelFailure: String?
  @Published private(set) var benchmarkNotice: String?
  private let modelAdvisor: LocalModelAdvisor?

  @Published private(set) var attachedContexts: [ConversationContext] = []
  @Published private(set) var selectionRevisions: [UUID: SelectionRevision] = [:]
  @Published private(set) var isApplyingSelection = false
  let selectionEditingSettings: SelectionEditingSettings
  /// Pastes a revision: its text, its selection, and whether it's automatic.
  private let replaceSelection: @MainActor (String, UUID, Bool) async -> Bool
  private var selectionEditRequest: (id: UUID, contextID: UUID, automatic: Bool)?
  /// The source material the active request carries, for refining its search query.
  private var requestSource: (contexts: [ConversationContext], draft: String?) = ([], nil)
  private var replacementTask: Task<Void, Never>?
  private var selectionSettingsObservation: AnyCancellable?
  /// The panel's chat while it's still temporary: kept in memory, never saved.
  private var temporarySessionID: UUID?
  /// The chat the attached selection belongs to: the panel's temporary chat,
  /// and the same chat once it opens in the full window, where it's written
  /// once its first question lands, unless it's kept private.
  private var selectionSessionID: UUID?
  var isTemporaryChat: Bool { selectedSessionID != nil && selectedSessionID == temporarySessionID }
  /// The open chat is the one the selection was captured for.
  var isSelectionChat: Bool { selectedSessionID != nil && selectedSessionID == selectionSessionID }
  /// The chat just opened in the window from the panel, which says once
  /// whether it's now saved or stays private.
  struct OpenedSelectionChat: Equatable {
    let id: UUID
    let isPrivate: Bool
  }
  @Published private(set) var openedSelectionChat: OpenedSelectionChat?
  /// The chats Recents lists: every chat but a temporary one and one with no
  /// messages, apart from the selection's chat that just moved to the window.
  var historySessions: [ChatSession] {
    sessions.filter { $0.id != temporarySessionID && (!$0.messages.isEmpty || $0.id == selectionSessionID) }
  }
  var messages: [ChatMessage] { selectedSession?.messages ?? [] }

  private var requestMessages: [ChatMessage] { messages.map { message in
    var copy = message
    // Earlier messages keep the selection they were sent with, so the model
    // can refer back to it, but only while it's still attached: removing it
    // removes it from future requests. Request-only instructions never carry over.
    let contexts = message.contexts?.filter { context in attachedContexts.contains { $0.id == context.id } }
    copy.contexts = contexts?.isEmpty == false ? contexts : nil
    copy.selectionResponseMode = nil
    copy.selectionDraft = nil
    return copy
  } }

  /// The attached contexts the model has seen: carried by an earlier message
  /// that has a reply. Request preparation leaves out a turn whose reply is
  /// empty, failed or stopped before any text, so its selection doesn't count.
  var sentContextIDs: Set<UUID> { Self.sentContextIDs(in: messages) }

  static func sentContextIDs(in messages: [ChatMessage]) -> Set<UUID> {
    var sent = Set<UUID>()
    for (index, message) in messages.enumerated() where message.role == .user && index + 1 < messages.count {
      let reply = messages[index + 1]
      guard let contexts = message.contexts, reply.role == .assistant,
            !message.content.isEmpty, !reply.content.isEmpty else { continue }
      sent.formUnion(contexts.map(\.id))
    }
    return sent
  }

  /// The history Auto estimates a request's size from: what the model will
  /// receive, with the selection an earlier message carried.
  var autoRoutingContextMessages: [ChatMessage] { requestMessages.map(ConversationContextPrompt.expand) }

  /// The latest proposed revision of an attached selection, and the reply it came from.
  private var latestSelectionRevision: (revision: SelectionRevision, message: ChatMessage)? {
    for message in messages.reversed() {
      if let revision = selectionRevisions[message.id], attachedContexts.contains(where: { $0.id == revision.contextID }) {
        return (revision, message)
      }
    }
    return nil
  }

  private var latestSelectionDraft: String? { latestSelectionRevision?.revision.text }

  /// A revision card still waiting to be applied or dismissed, ready or
  /// failed. An automatic revision shows no card, so it never waits.
  var hasPendingSelectionRevision: Bool {
    messages.contains { message in
      guard let revision = selectionRevisions[message.id], !revision.automatic else { return false }
      return (revision.status == .ready || revision.status == .failed)
        && attachedContexts.contains { $0.id == revision.contextID }
    }
  }

  /// The latest draft, when the user changed it by hand: the model hasn't seen
  /// those changes, while its own revision is already in the conversation.
  private var manuallyEditedSelectionDraft: String? {
    guard let latest = latestSelectionRevision,
          latest.revision.text != SelectionRevisionResponse.parse(latest.message.content)?.text else { return nil }
    return latest.revision.text
  }

  /// The user's message with the source material this request needs. The
  /// selection goes with the first message only; later messages are ordinary
  /// turns that can refer back to it in the history. `/edit` is the exception:
  /// it always gets the selection, and the latest draft, to revise. So is a
  /// `/translate` with no text of its own, which translates the selection.
  private func contextualMessage(_ prompt: String, responseInstructions: Bool = true) -> ChatMessage {
    var message = ThinkCommand.message(prompt)
    let mode = SelectionResponseMode(prompt: prompt)
    let contexts = Self.requestContexts(attached: attachedContexts, sent: sentContextIDs,
                                        resendsSelection: SelectionResponseMode.usesSelectionAgain(prompt: prompt))
    message.contexts = contexts.isEmpty ? nil : contexts
    if responseInstructions {
      message.selectionResponseMode = Self.responseMode(mode, attached: attachedContexts, request: contexts)
    }
    message.selectionDraft = mode == .edit ? latestSelectionDraft : manuallyEditedSelectionDraft
    return message
  }

  /// The attached contexts a request carries: those the model hasn't seen,
  /// or all of them for `/edit` and a standalone `/translate`.
  static func requestContexts(attached: [ConversationContext], sent: Set<UUID>,
                              resendsSelection: Bool) -> [ConversationContext] {
    resendsSelection ? attached : attached.filter { !sent.contains($0.id) }
  }

  /// Which Selection Context instructions a request gets: the request's own
  /// command when it carries the selection, the follow-up guidance once the
  /// selection is only in the history, and translation guidance for `/translate`.
  static func responseMode(_ mode: SelectionResponseMode, attached: [ConversationContext],
                           request: [ConversationContext]) -> SelectionResponseMode? {
    if request.contains(where: { $0.kind == .selectedText }) || mode == .translate { return mode }
    return attached.contains { $0.kind == .selectedText } ? .followUp : nil
  }

  func removeContext(id: UUID) {
    replacementTask?.cancel()
    selectionEditRequest = nil
    attachedContexts.removeAll { $0.id == id }
    SelectionContextService.shared.discardTarget()
  }

  func startTemporaryChat(context: ConversationContext?) {
    stopStreaming()
    clearQueue()
    leaveEmptyChat(for: nil)
    discardTemporaryChat()
    files.restoreSelection(nil)
    contextNotice = nil
    autoRouteDecision = nil
    screenRouteDecision = nil
    let session = ChatSession(title: "Temporary chat")
    temporarySessionID = session.id
    selectionSessionID = session.id
    sessions.append(session)
    selectedSessionID = session.id
    messagesFollowUpSessionID = nil
    appleMessages.issue = nil
    files.conversationID = session.id
    attachedContexts = context.map { [$0] } ?? []
    if case .failed = state { state = .idle }
  }

  /// Leaving the selection's chat: the selection and its drafts go, and so
  /// does the chat itself while it's still temporary. A chat that moved to
  /// the window goes too while it's still empty, as when its first question
  /// was stopped or failed before reaching it, so abandoned sends don't fill
  /// Recents with empty chats. An empty one was never written, so the saved
  /// file needs no change.
  private func discardTemporaryChat() {
    replacementTask?.cancel(); replacementTask = nil
    selectionEditRequest = nil
    selectionRevisions = [:]
    if let temporarySessionID {
      sessions.removeAll { $0.id == temporarySessionID }
      endToolSessions([temporarySessionID])
    }
    if let selectionSessionID, selectionSessionID != temporarySessionID,
       sessions.first(where: { $0.id == selectionSessionID })?.messages.isEmpty == true {
      sessions.removeAll { $0.id == selectionSessionID }
      endToolSessions([selectionSessionID])
    }
    temporarySessionID = nil
    selectionSessionID = nil
    openedSelectionChat = nil
    attachedContexts = []
  }

  /// The panel's chat opened in the full window: a request for its first
  /// question started, or ⌘O or Open in window was used before that. By
  /// default it becomes an ordinary chat at the top of Recents, written and
  /// titled from its first question once that lands; until now nothing of it
  /// was written. With "Keep selection chats private" on, read now, it stays
  /// temporary: never saved, out of Recents, and gone with the next chat. The selection stays
  /// attached for /edit and Replace text, in memory only: selected text is
  /// never written to disk.
  func openTemporaryChatInWindow() {
    guard let id = temporarySessionID, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
    guard !selectionEditingSettings.keepsChatsPrivate else {
      openedSelectionChat = OpenedSelectionChat(id: id, isPrivate: true)
      return
    }
    temporarySessionID = nil
    // Titled like any new chat: from its first question once that's in it. A
    // question still being prepared isn't, and may never be, if it fails.
    let question = sessions[index].messages.first { $0.role == .user }?.content
    sessions[index].title = question.map(ChatSession.title(for:)) ?? "New Chat"
    // It goes to the top of Recents, selected.
    sessions[index].lastActivityAt = .now
    openedSelectionChat = OpenedSelectionChat(id: id, isPrivate: false)
    sortAndPersistSessions()
  }

  // Presentation is immediate; persistence still waits for successful preparation.
  @Published private(set) var pendingUserMessage: ChatMessage?
  @Published private(set) var hasReceivedResponse = false
  var presentationMessages: [ChatMessage] {
    guard let pendingUserMessage, !messages.contains(where: { $0.id == pendingUserMessage.id }) else { return messages }
    return messages + [pendingUserMessage]
  }
  var isWaitingForResponse: Bool { activeRequest != nil && !hasReceivedResponse }

  /// Messages typed while a reply ran, for the open chat. Memory only: a
  /// message is saved once it's sent, by the usual path.
  @Published private(set) var messageQueue = MessageQueue()
  /// Sends a queued message on the route selected now, calling the closure
  /// once its request is accepted. AppShellView owns routing and commands.
  var queuedMessageSender: (@MainActor (QueuedMessage, _ onAccepted: @escaping @MainActor () -> Void) -> Void)?
  /// The queued message whose request is running, and whether it reached the chat.
  private var queuedInFlight: (message: QueuedMessage, accepted: Bool)?

  var selectedSession: ChatSession? {
    guard let selectedSessionID else { return nil }
    return sessions.first(where: { $0.id == selectedSessionID })
  }

  /// Whether the composer and chat controls must wait. A model download does not count.
  var isBusy: Bool { isChatActive || modelOperation?.blocksChat == true }

  /// A request, or other chat work, is running.
  private var isChatActive: Bool {
    if isApplyingSelection || activeRequest != nil || generationTask != nil || files.isWorking || files.isPicking { return true }
    switch state {
    case .preparing, .refiningSearch, .searching, .streaming: return true
    case .idle, .failed: return false
    }
  }

  /// A model install, delete or performance check is running, until it acknowledges cancellation.
  var isManagingModels: Bool { installationTask != nil || modelOperation != nil }

  /// Installing, selecting, deleting, importing and measuring models wait for
  /// any model operation and for the current request.
  var canChangeModels: Bool { !isBusy && !isManagingModels }

  let files: FileModeCoordinator
  let appleMessages: MessagesCoordinator
  /// The open permission card for tools a capable model calls on its own (F32).
  let toolPermissions: ToolPermissionCoordinator
  /// F32's switch for this chat: flagged routes take `submitNative` only while it's on.
  let nativeToolsEnabled: Bool
  private var warmUpTask: Task<Void, Never>?
  /// When the last warm-up started, and the typed commands it read. Other commands change the
  /// prefix, so they warm again at once.
  private var lastWarmUp: (at: ContinuousClock.Instant, commands: Set<SlashCommand>)?
  /// A model whose warm-up failed isn't loaded in the background again until the next send.
  private var unwarmableModelID: String?
  /// The latest draft change while a warm-up ran, looked at again once it ends.
  private var draftDuringWarmUp: (draft: String, mode: ChatMode, hasScreenshot: Bool)?
  var isWarmingUp: Bool { warmUpTask != nil }
  /// What the selection tools proposed during the running flagged request, for its reply.
  private var nativeProposals: NativeProposals?
  /// The providers whose own web search flagged cloud turns may use (F30). Tests pin either backend.
  private let nativeWebSearchProviders: Set<CloudProviderID>
  /// Providers and models whose search was unavailable this run. Never saved.
  private var nativeWebSearchAvailability = NativeWebSearchAvailability()
  typealias MessagesToolboxFactory = @MainActor (@escaping @Sendable (MessagesSendApproval) async -> Bool) -> any AgentToolbox
  private let makeMessagesToolbox: MessagesToolboxFactory
  private let messagesAccess: @Sendable () throws -> Void
  private let localToolRuntime: @Sendable (LocalModel) -> Bool
  private let fileInference: any LocalToolInference
  private let fileCodex: CodexSubscriptionClient
  private let fileCloudAvailability: WorkspaceWritePolicy.CloudCheck
  private let engine: any LocalModelEngine
  private let visionEngine: any LocalVisionServing
  private let searchSettings: WebSearchSettings?
  private let locationProvider: (any LocationProviding)?
  private var requestLocationContext: String?
  private let webSearch: any WebSearchProvider
  private let cloudProviders: CloudProviderRegistry
  let sessionWriter: ChatSessionWriter
  private let idleUnloadDelay: Duration
  private let sleep: Sleep
  private var generationTask: Task<Void, Never>?
  private var installationTask: Task<Void, Never>?
  private var idleUnloadTask: Task<Void, Never>?

  init(
    engine: any LocalModelEngine,
    selectionEditingSettings: SelectionEditingSettings = .shared,
    replaceSelection: @escaping @MainActor (String, UUID, Bool) async -> Bool = {
      await SelectionContextService.shared.replace(with: $0, contextID: $1, automatic: $2)
    },
    files: FileModeCoordinator? = nil,
    appleMessages: MessagesCoordinator? = nil,
    toolPermissions: ToolPermissionCoordinator? = nil,
    messagesToolbox: MessagesToolboxFactory? = nil,
    messagesAccess: (@Sendable () throws -> Void)? = nil,
    localToolRuntime: (@Sendable (LocalModel) -> Bool)? = nil,
    fileInference: (any LocalToolInference)? = nil,
    fileCodex: CodexSubscriptionClient = .fileMode,
    fileCloudAvailability: WorkspaceWritePolicy.CloudCheck? = nil,
    visionEngine: any LocalVisionServing = LlamaServerVisionEngine(),
    modelAdvisor: LocalModelAdvisor? = nil,
    cloudProviders: CloudProviderRegistry = .live,
    webSearch: any WebSearchProvider = BraveSearchClient(),
    searchSettings: WebSearchSettings? = nil,
    locationProvider: (any LocationProviding)? = nil,
    sessionStore: ChatSessionStore = ChatSessionStore(),
    sessionWriter: ChatSessionWriter? = nil,
    idleUnloadDelay: Duration = LocalModelIdlePolicy.unloadDelay,
    sleep: @escaping Sleep = { duration in try await Task.sleep(for: duration) },
    nativeToolsEnabled: Bool = NativeTools.isEnabled,
    nativeWebSearchProviders: Set<CloudProviderID> = CloudProviderID.nativeWebSearchProviders
  ) {
    self.selectionEditingSettings = selectionEditingSettings
    self.replaceSelection = replaceSelection
    self.engine = engine
    self.files = files ?? FileModeCoordinator()
    self.appleMessages = appleMessages ?? MessagesCoordinator()
    self.toolPermissions = toolPermissions ?? ToolPermissionCoordinator(store: .shared)
    self.nativeToolsEnabled = nativeToolsEnabled
    self.nativeWebSearchProviders = nativeWebSearchProviders
    makeMessagesToolbox = messagesToolbox ?? { confirm in MessagesTools(confirmSend: confirm) }
    self.messagesAccess = messagesAccess ?? { try MessagesDatabase().checkAccess() }
    self.localToolRuntime = localToolRuntime ?? { LocalFileRuntime.executable(for: $0) != nil }
    self.fileInference = fileInference ?? (visionEngine as? any LocalToolInference) ?? LlamaServerVisionEngine()
    self.fileCodex = fileCodex
    self.fileCloudAvailability = fileCloudAvailability ?? {
      if await ScreenConnectivity.shared.isOffline { return .unavailable(reason: "This Mac is offline.") }
      guard CodexRuntimeConfiguration.executableURL() != nil else { return .unavailable(reason: "Sign in to ChatGPT in Settings → Cloud and search to use Codex.") }
      return await fileCodex.fileEditingAvailability(preferredModelID: CloudPreferencesStore().chosenModel(for: .chatGPT))
    }
    self.visionEngine = visionEngine
    self.modelAdvisor = modelAdvisor
    self.webSearch = webSearch
    self.searchSettings = searchSettings
    self.locationProvider = locationProvider
    self.cloudProviders = cloudProviders
    self.sessionWriter = sessionWriter ?? ChatSessionWriter { try sessionStore.save($0) }
    self.idleUnloadDelay = idleUnloadDelay
    self.sleep = sleep
    // Launch opens a new chat: saved chats stay in Recents, and the new one
    // is made, and written, only once something needs it.
    // A chat with no messages is never saved; one left by an older version goes.
    sessions = sessionStore.load().filter { !$0.messages.isEmpty }
    // Gate 3 keeps asking in a chat that held message text before a relaunch.
    for session in sessions where session.holdsMessageText == true {
      self.toolPermissions.store.markMessageText(session: session.id)
    }
    self.files.onSelectionChange = { [weak self] selection in
      guard let self else { return }
      let sessionID = self.ensureSelectedSession()
      self.files.conversationID = sessionID
      guard let index = self.sessions.firstIndex(where: { $0.id == sessionID }) else { return }
      self.sessions[index].workspace = selection
      // Files on a chat with no messages are held in memory only.
      if !self.isUnsaved(self.sessions[index]) { self.persistSessions() }
    }
    selectionSettingsObservation = selectionEditingSettings.$automaticallyReplace.dropFirst().sink { [weak self] enabled in
      guard !enabled, let self else { return }
      self.replacementTask?.cancel()
      for id in Array(self.selectionRevisions.keys) where self.selectionRevisions[id]?.status != .sent {
        self.selectionRevisions[id]?.automatic = false
      }
    }
  }

  func refreshInstalledModel() async {
    installedModel = await engine.installedModel()
    installedModels = await engine.installedModels()
  }

  /// Importing copies and commits in one step, so it holds chat like a commit.
  func installModel(from sourceURL: URL, vision: LocalVisionConfiguration? = nil) {
    guard canChangeModels else { return }
    cancelIdleUnload()
    clearModelFailure()
    modelOperation = .installing
    let didAccessSecurityScope = sourceURL.startAccessingSecurityScopedResource()
    let modelName = sourceURL.deletingPathExtension().lastPathComponent
    let accessedProjector = vision?.projectorURL.startAccessingSecurityScopedResource() ?? false
    let model = LocalModel(id: modelName.lowercased() + (vision == nil ? "" : ":vision"), displayName: modelName, fileURL: sourceURL, visionConfiguration: vision)

    installationTask = Task { [weak self, engine] in
      defer {
        if didAccessSecurityScope { sourceURL.stopAccessingSecurityScopedResource() }
        if accessedProjector { vision?.projectorURL.stopAccessingSecurityScopedResource() }
      }
      do {
        await self?.visionEngine.unload()
        try await engine.install(model)
        guard let self else { return }
        await self.refreshInstalledModel()
        try Task.checkCancellation()
        if vision == nil { await self.benchmarkInstalledModel(prediction: nil) }
        self.finishInstallation()
      } catch is CancellationError {
        self?.finishInstallation()
      } catch {
        self?.failInstallation(error)
      }
    }
  }

  /// Chat keeps working while the package downloads, verifies and unpacks.
  /// Only the commit, which may select the new model, and the performance
  /// check wait for the current request to end and hold chat while they run.
  /// `checkPerformance: false` installs without the check, for setup's later installs.
  func downloadModel(_ descriptor: LocalModelDescriptor, checkPerformance: Bool = true) {
    guard canChangeModels else { return }
    clearModelFailure()
    modelOperation = .downloading(ModelDownloadProgress(receivedByteCount: 0, expectedByteCount: descriptor.downloadByteCount))
    installationTask = Task { [weak self, engine] in
      do {
        let prediction = try await self?.modelAdvisor?.confirmDownload(descriptor, installedModels: self?.installedModels ?? [])
        try Task.checkCancellation()
        _ = try await engine.download(descriptor, beforeCommit: { @MainActor [weak self] in
          try await self?.holdChatForModelCommit()
        }, progress: { [weak self] progress in
          await self?.updateDownloadProgress(progress)
        })
        guard let self else { return }
        await self.refreshInstalledModel()
        // An engine without a commit hook has installed already; still measure only an idle chat.
        try await self.holdChatForModelCommit()
        if !checkPerformance {
          self.benchmarkNotice = nil
        } else if prediction?.permitsMemoryOverride == true {
          self.benchmarkNotice = "Installed. Memory use may be high; choose Check Performance when you are ready to test it."
        } else {
          await self.benchmarkInstalledModel(prediction: prediction)
        }
        self.finishInstallation()
      } catch is CancellationError {
        self?.finishInstallation()
      } catch {
        self?.failInstallation(error)
      }
    }
  }

  func cancelInstallation() {
    // Keep submission blocked until the downloader/benchmark acknowledges cancellation.
    installationTask?.cancel()
  }

  func runModelBenchmark() {
    guard canChangeModels, let installedModel else { return }
    cancelIdleUnload()
    clearModelFailure()
    modelOperation = .benchmarking
    installationTask = Task { [weak self] in
      guard let self else { return }
      await modelAdvisor?.detectHardware()
      let prediction = modelAdvisor?.recommendations(installedModels: installedModels)
        .assessments.first { $0.id == installedModel.id }
      await benchmarkInstalledModel(prediction: prediction)
      finishInstallation()
    }
  }

  private func benchmarkInstalledModel(prediction: LocalModelAssessment?) async {
    guard let modelAdvisor, let model = installedModel else { return }
    modelOperation = .benchmarking
    benchmarkNotice = nil
    do {
      try Task.checkCancellation()
      if modelAdvisor.hardware == nil { await modelAdvisor.detectHardware() }
      let measured = model.supportsVision ? try await visionEngine.benchmark(model: model) : try await engine.benchmark()
      if let metrics = measured {
        try Task.checkCancellation()
        modelAdvisor.record(metrics, model: model, prediction: prediction)
        benchmarkNotice = "Performance check complete. Results are saved on this Mac."
      }
    } catch is CancellationError {
      benchmarkNotice = "Performance check cancelled. The installed model is ready to use."
    } catch {
      // An optional benchmark failure must not undo a verified installation.
      benchmarkNotice = "Model installed. Performance check: \(error.localizedDescription)"
    }
  }

  func selectModel(id: String) {
    guard canChangeModels else { return }
    cancelIdleUnload()
    clearModelFailure()
    // Keep submission blocked until the engine and the displayed selection agree.
    state = .preparing
    Task { [weak self, engine] in
      do {
        await self?.visionEngine.unload()
        try await engine.selectModel(id: id)
        guard let self else { return }
        await self.refreshInstalledModel()
        self.state = .idle
        self.scheduleIdleUnload()
      } catch {
        self?.state = .idle
        self?.modelFailure = error.localizedDescription
        self?.scheduleIdleUnload()
      }
    }
  }

  func deleteModel(id: String) {
    guard canChangeModels, installedModels.contains(where: { $0.id == id }) else { return }
    cancelIdleUnload()
    benchmarkNotice = nil
    clearModelFailure()
    modelOperation = .deleting
    installationTask = Task { [weak self, engine] in
      do {
        await self?.visionEngine.unload()
        await engine.unload()
        try await engine.deleteModel(id: id)
        guard let self else { return }
        await self.refreshInstalledModel()
        self.finishInstallation()
      } catch {
        self?.failInstallation(error)
      }
    }
  }

  /// File Mode has its own explicit route. Auto stays local; a write request never causes upload.
  func submitFiles(_ prompt: String, mode: ChatMode, cloudProvider: CloudProviderID,
                   cloudModelID: String, onAccepted: @escaping @MainActor () -> Void = {}) {
    guard !isBusy, !files.isWorking, !ThinkCommand.message(prompt).content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          files.selection != nil else { return }
    let local = mode != .cloud
    if local && installedModel == nil {
      files.error = "Choose a local model, or choose Use Codex to work with these files in the cloud. Auto keeps File Mode on this Mac."
      return
    }
    if !local && cloudProvider != .chatGPT {
      files.error = "Cloud File Mode uses Codex. Choose Use Codex to continue; relevant file contents may be sent to the cloud."
      return
    }
    let model = installedModel
    let route = Route(mode: local ? .local : .cloud,
      providerID: local ? "llama.cpp" : CloudProviderID.chatGPT.rawValue,
      modelID: local ? model!.id : cloudModelID, usesNetwork: !local)
    guard messageTextMayGo(to: route) else {
      files.error = NativeToolsError.messageTextStays.localizedDescription
      return
    }
    let level: FileAccessLevel = SelectionResponseMode(prompt: prompt) == .translate ? .readOnly
      : local ? model.map { LocalFileCapabilities.production.access(for: $0) } ?? .readOnly : .readWrite
    let fileTools: AgentFileTools
    do { fileTools = try files.begin(access: level, isLocal: local, prompt: prompt, cloudAvailability: fileCloudAvailability) }
    catch { files.error = error.localizedDescription; return }
    var userMessage = contextualMessage(prompt)
    userMessage.attachments = files.selection?.attachments.map { MessageAttachment(name: $0.name, isDirectory: $0.isDirectory) }
    let history = requestMessages + [userMessage]
    let active = beginGeneration(route: route, modelDisplayName: local ? model!.displayName : cloudModelID, userMessage: userMessage)
    let sessionID = ensureSelectedSession()
    let responseID = UUID()
    state = .preparing
    contextNotice = nil
    autoRouteDecision = nil
    screenRouteDecision = nil
    append(history.last!, to: sessionID)
    files.consumeSelection(for: fileTools.workspace)
    append(ChatMessage(id: responseID, role: .assistant, content: ""), to: sessionID)
    generationTask = Task { [weak self, fileInference, fileCodex, engine, files] in
      var failure: Error?
      do {
        try Task.checkCancellation()
        self?.receiveActivity(.phase(.thinking), requestID: active.id)
        if local, let model {
          // The inference-only bridge releases its model before the tool-capable runtime loads it.
          await engine.unload()
          let owner = self
          try await LocalFileAgent(inference: fileInference).run(messages: history.map(ConversationContextPrompt.expand), model: model, tools: fileTools) { text in
            await owner?.appendFileText(text, messageID: responseID, sessionID: sessionID, requestID: active.id)
          }
        } else {
          let request = ChatRequest(sessionID: sessionID, messages: history.map(ConversationContextPrompt.expand), route: route)
          for try await event in fileCodex.stream(request, fileTools: fileTools) {
            try Task.checkCancellation()
            if case .activity(let update) = event { self?.receiveActivity(update, requestID: active.id) }
            if case .token(let text) = event {
              self?.appendFileText(text, messageID: responseID, sessionID: sessionID, requestID: active.id)
            }
          }
        }
        try Task.checkCancellation()
      } catch is CancellationError { }
      catch { failure = error }
      // Finish closes the authority before enabling the composer, including Stop and late events.
      if local { await fileInference.unload() }
      await files.finish(workspace: fileTools.workspace)
      if let failure, self?.activeRequest?.id == active.id { files.error = failure.localizedDescription }
      await self?.finishGeneration(id: active.id, error: failure)
    }
    messagesFollowUpSessionID = nil
    onAccepted()
  }

  /// `/messages` gives the model the Messages tools for this request only. Auto stays on this
  /// Mac; only an explicitly selected cloud model receives what the tools return.
  func submitMessages(_ prompt: String, mode: ChatMode, cloudProvider: CloudProviderID,
                      cloudModelID: String, onAccepted: @escaping @MainActor () -> Void = {}) {
    guard !isBusy, !files.isWorking,
          !ThinkCommand.message(prompt).content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    appleMessages.issue = nil
    do { try messagesAccess() } catch {
      appleMessages.report(error)
      return
    }
    let local = mode != .cloud
    let model = installedModel
    var provider: (any ToolCallingChatProvider)?
    if local {
      guard let model else {
        appleMessages.report(mode == .auto
          ? "Messages in Auto stays on this Mac, so it needs a local model. Choose a local model, or choose Cloud to use your cloud model."
          : "Choose a local model to use Messages, or choose Cloud.")
        return
      }
      guard localToolRuntime(model) else {
        appleMessages.report("Messages with a local model needs llama-server. Open Settings → Local models → Local file tools → Install, or choose Cloud.")
        return
      }
    } else {
      guard !cloudModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        appleMessages.report("Choose a cloud model in Settings to use Messages in the cloud.")
        return
      }
      provider = cloudProvider == .chatGPT ? fileCodex : cloudProviders.provider(for: cloudProvider) as? any ToolCallingChatProvider
      guard provider != nil else {
        appleMessages.report("\(cloudProvider.displayName) can't use Messages tools. Choose another provider or a local model.")
        return
      }
    }
    let route = Route(mode: local ? .local : .cloud, providerID: local ? "llama.cpp" : cloudProvider.rawValue,
      modelID: local ? model!.id : cloudModelID, usesNetwork: !local)
    guard messageTextMayGo(to: route) else {
      appleMessages.report(NativeToolsError.messageTextStays.localizedDescription)
      return
    }
    let userMessage = contextualMessage(prompt)
    let history = (requestMessages + [userMessage]).map(ConversationContextPrompt.expand)
    let toolbox = makeMessagesToolbox { [weak appleMessages] approval in await appleMessages?.confirm(approval) ?? false }
    let active = beginGeneration(route: route, modelDisplayName: local ? model!.displayName : cloudModelID, userMessage: userMessage)
    let sessionID = ensureSelectedSession()
    let responseID = UUID()
    state = .preparing
    contextNotice = nil
    autoRouteDecision = nil
    screenRouteDecision = nil
    // A typed /messages reads freely, so later searches by a capable model ask first (gate 3).
    markMessageText(in: sessionID, destination: ToolDestination(route: route) ?? .thisMac)
    append(userMessage, to: sessionID)
    append(ChatMessage(id: responseID, role: .assistant, content: ""), to: sessionID)
    generationTask = Task { [weak self, fileInference, engine] in
      var failure: Error?
      do {
        try Task.checkCancellation()
        self?.receiveActivity(.phase(.thinking), requestID: active.id)
        if local, let model {
          // The inference-only bridge releases its model before the tool-capable runtime loads it.
          await engine.unload()
          let owner = self
          try await LocalToolAgent(inference: fileInference).run(messages: history, model: model, toolbox: toolbox,
            onActivity: { event in await owner?.receiveActivity(event, requestID: active.id) }) { text in
            await owner?.appendFileText(text, messageID: responseID, sessionID: sessionID, requestID: active.id)
          }
        } else if let provider {
          let request = ChatRequest(sessionID: sessionID, messages: history, route: route)
          for try await event in provider.stream(request, toolbox: toolbox) {
            try Task.checkCancellation()
            switch event {
            case .activity(let update): self?.receiveActivity(update, requestID: active.id)
            case .token(let text): self?.appendFileText(text, messageID: responseID, sessionID: sessionID, requestID: active.id)
            case .completed: break
            }
          }
        }
        try Task.checkCancellation()
      } catch is CancellationError { }
      catch { failure = error }
      if local { await fileInference.unload() }
      // A request that ends while an approval is open never sends.
      self?.appleMessages.answer(false)
      // A permission macOS withheld mid-request gets the card with its settings button, which
      // says everything the status line would; the reply still reads Request failed.
      let settingsError = (failure as? MessagesError).flatMap { $0.privacyPane == nil ? nil : $0 }
      if let settingsError, self?.activeRequest?.id == active.id { self?.appleMessages.report(settingsError) }
      await self?.finishGeneration(id: active.id, error: failure, showsProblem: settingsError == nil)
    }
    messagesFollowUpSessionID = sessionID
    onAccepted()
  }

  // MARK: Native tool calling (F32)

  /// The commands and attachments a flagged turn's tools follow, with this Mac's settings.
  func nativeToolPlan(for typed: ComposerCommands, hasFiles: Bool = false, hasScreenshot: Bool = false) -> NativeToolPlan {
    guard !hasFiles, !hasScreenshot else { return .empty }
    return NativeToolPlan.make(.init(typed: typed, hasSelection: attachedContexts.contains { $0.kind == .selectedText },
      hasFiles: false, hasScreenshot: false, searchesAutomatically: searchSettings?.automaticallySearch ?? false,
      hasSearchKey: searchSettings?.hasAPIKey ?? false, hasFullDiskAccess: (try? messagesAccess()) != nil))
  }

  /// How often typing may warm the local model. Well inside the minute after which an idle
  /// server unloads, so it stays loaded while the user types.
  static let warmUpInterval: Duration = .seconds(10)

  /// Warms a flagged local model while the user types (F32): starts its server and reads the next
  /// turn's system prompt, tools and earlier messages into the prompt cache, so the reply after a
  /// pause doesn't wait for them. Only where a flagged local turn would run: Local, and Auto, which
  /// starts local. The draft is read for its typed commands only, which shape that prompt; its text
  /// is never sent, as it may never be. Returns whether a warm-up started.
  @discardableResult
  func warmNativeTurn(draft: String, mode: ChatMode, hasScreenshot: Bool) -> Bool {
    guard nativeToolsEnabled else { return false }
    guard warmUpTask == nil else {
      draftDuringWarmUp = (draft, mode, hasScreenshot)
      return false
    }
    guard mode != .cloud, !hasScreenshot, !isBusy, !files.isWorking, files.selection == nil,
          !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !Self.endsInPartialCommand(draft),
          let model = installedModel, model.id != unwarmableModelID else { return false }
    let route = Route(mode: .local, providerID: "local", modelID: model.id, usesNetwork: false)
    let typed = ComposerCommands(draft)
    guard NativeTools.isCapable(route: route, localModel: model), !typed.screen,
          let destination = ToolDestination(route: route) else { return false }
    let commands = Set(SlashCommand.tokens(in: draft).map(\.command))
    if let lastWarmUp, lastWarmUp.commands == commands, lastWarmUp.at.duration(to: .now) < Self.warmUpInterval {
      return false
    }
    // Built as the turn builds it; its tools never run.
    let toolbox = nativeToolbox(plan: nativeToolPlan(for: typed), destination: destination, sessionID: UUID(),
                                responseID: UUID(), requestID: UUID(), evidenceTokens: 2_048)
    // A stand-in prompt, removed again after trimming: the preparer needs one, and the draft is
    // never read. Whatever the preparer puts before it, such as /think's guidance, stays.
    let standIn = "."
    var message = ThinkCommand.message(draft)
    message.content = standIn
    guard !toolbox.definitions.isEmpty,
          var messages = try? LocalToolAgent.prepare(requestMessages.map(ConversationContextPrompt.expand) + [message],
                                                     model: model, toolbox: toolbox).messages,
          let last = messages.indices.last, messages[last].content.hasSuffix(standIn) else { return false }
    messages[last].content.removeLast(standIn.count)
    lastWarmUp = (.now, commands)
    warmUpTask = Task { [weak self, fileInference] in
      let ready = await LocalToolAgent(inference: fileInference).warm(messages: messages, model: model, toolbox: toolbox)
      guard let self else { return }
      warmUpTask = nil
      if !ready { unwarmableModelID = model.id }
      // The user may have typed a command meanwhile, which needs another prefix.
      if let later = draftDuringWarmUp {
        draftDuringWarmUp = nil
        warmNativeTurn(draft: later.draft, mode: later.mode, hasScreenshot: later.hasScreenshot)
      }
    }
    return true
  }

  /// Whether the draft ends in a command still being typed, such as "/thi": the finished one may
  /// change the prefix, so warming waits for it.
  static func endsInPartialCommand(_ draft: String) -> Bool {
    guard let character = draft.last, !character.isWhitespace,
          let word = draft.split(whereSeparator: \.isWhitespace).last, word.hasPrefix("/") else { return false }
    return SlashCommand(rawValue: String(word.dropFirst()).lowercased()) == nil
  }

  /// A flagged route: the model gets the plan's tools on the route's streaming tool loop and
  /// decides itself when to search, read Messages or propose a selection edit. Cards gate message
  /// text, and searches once a chat holds it. A local turn keeps the server, and its prompt
  /// cache, for the next turn.
  func submitNative(_ prompt: String, route: Route, plan: NativeToolPlan,
                    onAccepted: @escaping @MainActor () -> Void = {}) {
    let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !isBusy, !files.isWorking, !ThinkCommand.message(prompt).content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    appleMessages.issue = nil
    screenRouteDecision = nil
    if plan.messagesRequested {
      do { try messagesAccess() } catch {
        appleMessages.report(error)
        return
      }
    }
    let local = route.mode == .local
    let model = installedModel
    // Sending tries a model whose warm-up failed again; its error, if any, now shows.
    if local { unwarmableModelID = nil }
    var provider: (any ToolCallingChatProvider)?
    guard let destination = ToolDestination(route: route) else {
      state = .failed(CloudProviderError.invalidResponse.localizedDescription)
      return
    }
    if local {
      guard let model, model.id == route.modelID else {
        state = .failed(LocalInferenceError.noModelInstalled.localizedDescription)
        return
      }
    } else {
      guard let providerID = CloudProviderID(rawValue: route.providerID) else {
        state = .failed(CloudProviderError.invalidResponse.localizedDescription)
        return
      }
      provider = providerID == .chatGPT ? fileCodex : cloudProviders.provider(for: providerID) as? any ToolCallingChatProvider
      guard provider != nil else {
        state = .failed("\(providerID.displayName) can't use tools. Choose another provider or a local model.")
        return
      }
    }
    // The selection tools replace the revision-block instructions a typed /edit gets today. The
    // latest draft still goes along, since it can hold the user's own changes to the card.
    let selection = plan.parts.contains(.selection) ? attachedContexts.first { $0.kind == .selectedText } : nil
    let userMessage = contextualMessage(prompt, responseInstructions: selection == nil)
    var requestMessage = ConversationContextPrompt.expand(userMessage)
    if selection != nil, let draft = userMessage.selectionDraft, let note = ConversationContextPrompt.draftNote(draft) {
      requestMessage.content += note
    }
    let history = requestMessages.map(ConversationContextPrompt.expand) + [requestMessage]
    let active = beginGeneration(route: route, modelDisplayName: local ? model!.displayName : route.modelID, userMessage: userMessage)
    let sessionID = ensureSelectedSession()
    let responseID = UUID()
    let plan = local ? plan : plan.remade(providerSearch: providerSearchAllowed(route: route))
    if let selection {
      nativeProposals = NativeProposals(requestID: active.id, messageID: responseID, sessionID: sessionID,
                                        contextID: selection.id, editRequested: plan.editRequested)
    }
    let evidenceTokens = local ? 2_048 : BraveSearchClient.evidenceTokens
    // Shared by every run of this turn, so a run that starts again can't send the same text twice.
    let sendLedger = MessagesSendLedger()
    let toolbox = nativeToolbox(plan: plan, destination: destination, sessionID: sessionID, responseID: responseID,
                                requestID: active.id, evidenceTokens: evidenceTokens, sendLedger: sendLedger)
    let toolNames = toolbox.definitions.map(\.name).joined(separator: ",")
    NativeTools.logger.info("Native turn: \(route.mode.rawValue, privacy: .public) \(route.providerID, privacy: .public); tools \(toolNames, privacy: .public); required \(toolbox.offeredRequiredTool ?? "none", privacy: .public); provider search \(plan.searchBackend == .provider, privacy: .public)")
    state = .preparing
    contextNotice = nil
    // Shown at once; it lands in the chat, and the draft clears, only once the request is under
    // way, as on plain turns. A failure before that keeps the draft.
    pendingUserMessage = userMessage
    generationTask = Task { [weak self, fileInference, engine] in
      var failure: Error?
      do {
        try Task.checkCancellation()
        self?.receiveActivity(.phase(.thinking), requestID: active.id)
        let owner = self
        let accept = { @MainActor in
          owner?.acceptNative(userMessage, responseID: responseID, sessionID: sessionID, requestID: active.id,
                              onAccepted: onAccepted)
        }
        if local, let model {
          let prepared = try LocalToolAgent.prepare(history, model: model, toolbox: toolbox)
          owner?.contextNotice = prepared.notice
          // The inference-only bridge lets go of its model; the server plain turns use stays loaded.
          await engine.unload()
          // A local request is under way at the model's first text or tool call.
          try await LocalToolAgent(inference: fileInference).runStreaming(messages: prepared.messages, model: model,
            toolbox: toolbox, onActivity: { event in
              await accept()
              await owner?.receiveActivity(event, requestID: active.id)
            }) { text in
            await accept()
            await owner?.appendFileText(text, messageID: responseID, sessionID: sessionID, requestID: active.id)
          }
        } else if let provider {
          // A chat whose message text was allowed somewhere else asks before it goes to this company.
          guard let permissions = owner?.toolPermissions else { throw CancellationError() }
          if !permissions.store.messageTextAllowed(session: sessionID, destination: destination) {
            let allowed = await permissions.authorize(.shareMessageText, destination: destination, session: sessionID)
            try Task.checkCancellation()
            guard allowed else { throw NativeToolsError.messageTextStays }
          }
          var plan = plan, toolbox = toolbox
          // In a chat holding message text, or on a typed /messages turn, the provider's search runs
          // only once the user allows it for this provider; declined, the turn doesn't search
          // (owner, 2026-10-29). Allowed, a Messages read no longer restarts the request.
          var searchApproved = false, asked = false
          if plan.searchBackend == .provider, let owner {
            if plan.messagesRequested || owner.chatHoldsMessageText(sessionID) {
              asked = true
              searchApproved = try await owner.allowsProviderSearch(route: route, destination: destination,
                                                                    sessionID: sessionID)
              if !searchApproved {
                plan = plan.withoutSearch()
                NativeTools.logger.info("Provider search declined: \(route.providerID, privacy: .public)")
              }
            } else {
              // A grant already given lets a read partway through go to the provider, with no card.
              searchApproved = owner.providerSearchGranted(route: route, destination: destination, sessionID: sessionID)
            }
          }
          // F30, spec §2a: a nearby question asks, per provider, before the area goes to its search.
          let location = plan.searchBackend == .provider
            ? try await owner?.providerSearchLocation(for: prompt, route: route, destination: destination, sessionID: sessionID)
            : nil
          if location != nil || asked || searchApproved, let owner {
            toolbox = owner.nativeToolbox(plan: plan, destination: destination, sessionID: sessionID, responseID: responseID,
                                          requestID: active.id, evidenceTokens: evidenceTokens, location: location,
                                          providerSearchApproved: searchApproved, sendLedger: sendLedger)
          }
          // A turn runs again at most once for each reason (F30): its provider search was
          // unavailable before the reply started (made again with Enigma's search), or message text
          // was about to enter its request (made again after asking whether the provider may search).
          var fellBack = false, restarted = false
          while true {
            let providerSearch = plan.searchBackend == .provider ? ProviderSearch(location: location) : nil
            // Codex, Claude Code and Anthropic with /think can't force a tool, so the request also
            // asks in words. The local server adds the same line itself. On provider search,
            // `web_search` names the provider's own tool, which isn't among the definitions.
            var history = history
            if let required = toolbox.offeredRequiredTool ?? (providerSearch == nil ? nil : toolbox.requiredTool) {
              history[history.count - 1].content += "\n\n" + LlamaServerVisionEngine.requiredToolInstruction(required)
            }
            let prepared = try CloudContext.prepare(ChatRequest(sessionID: sessionID, messages: history, route: route))
            owner?.contextNotice = prepared.notice
            // As on plain cloud turns, a prepared request is under way.
            accept()
            owner?.recordReplySearch(provider: providerSearch != nil, messageID: responseID, sessionID: sessionID,
                                     requestID: active.id)
            var request = ChatRequest(sessionID: sessionID, messages: prepared.messages, route: route)
            request.providerSearch = providerSearch
            // The reply starts at its first text or tool call; only before that may it fall back.
            let started = NativeReplyStart()
            toolbox.onCall = started.mark
            do {
              for try await event in provider.stream(request, toolbox: toolbox) {
                try Task.checkCancellation()
                switch event {
                case .activity(.sourcesSelected(let sources)) where providerSearch != nil:
                  owner?.addNativeSources(sources, messageID: responseID, sessionID: sessionID, requestID: active.id,
                                          limit: NativeWebSearch.maximumSources)
                case .activity(let update): owner?.receiveActivity(update, requestID: active.id)
                case .token(let text):
                  started.mark()
                  owner?.appendFileText(text, messageID: responseID, sessionID: sessionID, requestID: active.id)
                case .completed: break
                }
              }
              break
            } catch {
              try Task.checkCancellation()
              guard providerSearch != nil, let providerID = CloudProviderID(rawValue: route.providerID) else { throw error }
              let unavailable = if case CloudProviderError.webSearchUnavailable = error { true } else { false }
              // Remembered either way, so later turns skip it; only a reply not yet started falls back.
              if unavailable { owner?.nativeWebSearchAvailability.markUnavailable(providerID, modelID: route.modelID) }
              let restarting: Bool
              if unavailable, !fellBack, !started.isStarted {
                fellBack = true
                restarting = false
                NativeTools.logger.info("Provider search unavailable: \(providerID.rawValue, privacy: .public); falling back")
              } else if error is ProviderSearchRestart, !restarted {
                restarted = true
                restarting = true
                NativeTools.logger.info("Provider search restart: \(providerID.rawValue, privacy: .public)")
              } else {
                throw error
              }
              owner?.restartNativeReply(messageID: responseID, sessionID: sessionID, requestID: active.id)
              try Task.checkCancellation()
              guard let owner else { throw CancellationError() }
              if restarting {
                // The chat now holds message text: the provider searches again only if allowed.
                searchApproved = try await owner.allowsProviderSearch(route: route, destination: destination,
                                                                      sessionID: sessionID)
                if !searchApproved { plan = plan.withoutSearch() }
              } else {
                plan = plan.remade(providerSearch: false)
              }
            }
            toolbox = owner?.nativeToolbox(plan: plan, destination: destination, sessionID: sessionID,
                                           responseID: responseID, requestID: active.id, evidenceTokens: evidenceTokens,
                                           location: plan.searchBackend == .provider ? location : nil,
                                           providerSearchApproved: searchApproved, sendLedger: sendLedger) ?? toolbox
          }
        }
        try Task.checkCancellation()
      } catch is CancellationError { }
      catch { failure = error }
      // A request that ends while a send approval is open never sends.
      self?.appleMessages.answer(false)
      let settingsError = (failure as? MessagesError).flatMap { $0.privacyPane == nil ? nil : $0 }
      if let settingsError, self?.activeRequest?.id == active.id { self?.appleMessages.report(settingsError) }
      await self?.finishGeneration(id: active.id, error: failure, showsProblem: settingsError == nil)
    }
  }

  /// The question and an empty reply land in the chat, once per request.
  private func acceptNative(_ userMessage: ChatMessage, responseID: UUID, sessionID: UUID, requestID: UUID,
                            onAccepted: @MainActor () -> Void) {
    guard activeRequest?.id == requestID,
          sessions.first(where: { $0.id == sessionID })?.messages.contains(where: { $0.id == responseID }) == false else { return }
    append(userMessage, to: sessionID)
    append(ChatMessage(id: responseID, role: .assistant, content: ""), to: sessionID)
    messagesFollowUpSessionID = nil
    onAccepted()
  }

  /// The plan's parts, in a fixed order so a chat's tool prefix stays the same turn after turn.
  private func nativeToolbox(plan: NativeToolPlan, destination: ToolDestination, sessionID: UUID, responseID: UUID,
                             requestID: UUID, evidenceTokens: Int,
                             location: ProviderSearchLocation? = nil, providerSearchApproved: Bool = false,
                             sendLedger: MessagesSendLedger? = nil) -> AssistantToolbox {
    let coordinator = toolPermissions
    var parts: [any AgentToolbox] = []
    if plan.parts.contains(.search(.provider)) { parts.append(ProviderSearchPart(location: location)) }
    if plan.parts.contains(.search(.enigma)) {
      parts.append(WebSearchTool(
        search: { [weak self] query in
          guard let self else { throw CancellationError() }
          return try await self.search(query, writtenQuery: query, maximumTokens: evidenceTokens,
                                       requestID: requestID, refinesQuery: false)
        },
        mayQuery: { query in
          guard await coordinator.store.hasMessageText(session: sessionID) else { return true }
          return await coordinator.authorize(.searchAfterMessages(query: query), destination: destination, session: sessionID)
        },
        onSources: { [weak self] sources in
          await self?.addNativeSources(sources, messageID: responseID, sessionID: sessionID, requestID: requestID)
        }))
    }
    if plan.parts.contains(.messages),
       var messages = makeMessagesToolbox({ [weak appleMessages] approval in await appleMessages?.confirm(approval) ?? false })
         as? MessagesTools {
      // Flagged routes always gate message text; a toolbox that can't take the gate isn't offered.
      messages.gate = SavingMessagesGate(gate: CoordinatorMessagesGate(coordinator: coordinator, destination: destination,
                                                                      session: sessionID),
                                         restartsProviderSearch: plan.searchBackend == .provider && !providerSearchApproved) {
        [weak self] in
        await self?.saveMessageTextMark(sessionID)
      }
      if let sendLedger { messages.ledger = sendLedger }
      parts.append(messages)
    }
    if plan.parts.contains(.selection) {
      parts.append(SelectionTools(allowsEdit: plan.selectionAllowsEdit) { [weak self] proposal in
        await self?.receiveNativeProposal(proposal, requestID: requestID)
      })
    }
    return AssistantToolbox(parts: parts, requiredTool: plan.requiredTool, extraInstructions: plan.extraInstructions)
  }

  /// Merges a search's sources onto the reply and saves them; a provider's are capped at `limit` (F30).
  private func addNativeSources(_ sources: [WebSearchSource], messageID: UUID, sessionID: UUID, requestID: UUID,
                                limit: Int? = nil) {
    guard activeRequest?.id == requestID, let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
          let messageIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == messageID }) else { return }
    var all = sessions[sessionIndex].messages[messageIndex].searchSources ?? []
    for source in sources where !all.contains(where: { $0.url == source.url }) { all.append(source) }
    if let limit { all = Array(all.prefix(limit)) }
    sessions[sessionIndex].messages[messageIndex].searchSources = all
    receiveActivity(.sourcesSelected(all), requestID: requestID)
    persistSessions(immediately: false)
  }

  /// The area a provider-search turn may send, looked up on the Mac (F30, spec §2a): only for a nearby
  /// question in the user's own words, with Location on and an area found, once this provider is
  /// allowed on its card. Nil otherwise, and the instruction says to ask which city. Stop ends the turn.
  private func providerSearchLocation(for prompt: String, route: Route, destination: ToolDestination,
                                      sessionID: UUID) async throws -> ProviderSearchLocation? {
    guard let provider = CloudProviderID(rawValue: route.providerID), let locationProvider,
          LocationIntent.needsLocation(ScreenSearchContext.question(prompt)) else { return nil }
    let found: ApproximateLocation
    do {
      found = try await locationProvider.currentLocation()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return nil
    }
    try Task.checkCancellation()
    let location = found.providerSearchLocation
    guard !location.displayName.isEmpty else { return nil }
    let allowed = await toolPermissions.authorize(.shareLocation(provider: provider, area: location.displayName),
                                                  destination: destination, session: sessionID)
    try Task.checkCancellation()
    return allowed ? location : nil
  }

  /// Whether a flagged cloud turn may use its provider's own web search (F30). In a chat holding
  /// message text, `allowsProviderSearch` asks first.
  private func providerSearchAllowed(route: Route) -> Bool {
    guard route.mode == .cloud, let provider = CloudProviderID(rawValue: route.providerID) else { return false }
    return NativeWebSearch.isAllowed(provider: provider, modelID: route.modelID,
                                     enabledProviders: nativeWebSearchProviders, availability: nativeWebSearchAvailability)
  }

  private func chatHoldsMessageText(_ sessionID: UUID) -> Bool {
    toolPermissions.store.hasMessageText(session: sessionID) || sessions.first { $0.id == sessionID }?.holdsMessageText == true
  }

  /// The provider-search card (owner, 2026-10-29): the provider's queries run on its servers, where
  /// no card can ask, so in a chat with message text the user allows the search itself, per
  /// provider. A grant answers without a card; Stop while it shows ends the turn.
  private func allowsProviderSearch(route: Route, destination: ToolDestination, sessionID: UUID) async throws -> Bool {
    guard let provider = CloudProviderID(rawValue: route.providerID) else { return false }
    let allowed = await toolPermissions.authorize(.providerSearchAfterMessages(provider: provider),
                                                  destination: destination, session: sessionID)
    try Task.checkCancellation()
    return allowed
  }

  private func providerSearchGranted(route: Route, destination: ToolDestination, sessionID: UUID) -> Bool {
    guard let provider = CloudProviderID(rawValue: route.providerID) else { return false }
    return toolPermissions.store.isGranted(.providerSearchAfterMessages(provider: provider), destination: destination,
                                           session: sessionID)
  }

  /// Which search the reply's footer names (F30): the provider's own, or Brave.
  private func recordReplySearch(provider: Bool, messageID: UUID, sessionID: UUID, requestID: UUID) {
    guard activeRequest?.id == requestID, let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
          let messageIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == messageID }) else { return }
    sessions[sessionIndex].messages[messageIndex].origin?.providerSearch = provider
  }

  /// Clears a reply whose request runs again (F30): its text, sources, proposals and activity
  /// belong to the request that stopped.
  private func restartNativeReply(messageID: UUID, sessionID: UUID, requestID: UUID) {
    guard activeRequest?.id == requestID else { return }
    if let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
       let messageIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == messageID }) {
      sessions[sessionIndex].messages[messageIndex].content = ""
      sessions[sessionIndex].messages[messageIndex].searchSources = nil
      persistSessions(immediately: false)
    }
    if nativeProposals?.requestID == requestID {
      nativeProposals?.edit = nil
      nativeProposals?.translations = []
    }
    hasReceivedResponse = false
    state = .preparing
    activity = AssistantActivity(id: requestID)
    receiveActivity(.phase(.thinking), requestID: requestID)
  }

  private func receiveNativeProposal(_ proposal: SelectionProposal, requestID: UUID) {
    guard activeRequest?.id == requestID, nativeProposals?.requestID == requestID else { return }
    if proposal.language == nil {
      nativeProposals?.edit = proposal.text
    } else {
      nativeProposals?.translations.append(proposal.text)
    }
  }

  /// Puts a finished flagged request's proposals in its reply: a translation as text after it,
  /// and an edit as today's revision block, so the card, the saved chat and later edits read it
  /// as they read a typed /edit's revision. Replacing the selection still takes a click, or
  /// the automatic-replace setting.
  private func applyNativeProposals(requestID: UUID) {
    guard let proposals = nativeProposals, proposals.requestID == requestID,
          let sessionIndex = sessions.firstIndex(where: { $0.id == proposals.sessionID }),
          let messageIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == proposals.messageID }) else { return }
    var content = sessions[sessionIndex].messages[messageIndex].content.trimmingCharacters(in: .whitespacesAndNewlines)
    for translation in proposals.translations { content += (content.isEmpty ? "" : "\n\n") + translation }
    if let edit = proposals.edit, attachedContexts.contains(where: { $0.id == proposals.contextID }) {
      let acknowledgement = content.isEmpty || content.contains("```") || content.contains("<enigma-") ? "Revision ready." : content
      content = SelectionRevisionResponse(acknowledgement: acknowledgement, text: edit).formatted
      // Only a typed /edit pastes on its own; a proposal the model made unasked waits for a click.
      let automatic = proposals.editRequested && selectionEditingSettings.automaticallyReplace
      selectionRevisions[proposals.messageID] = SelectionRevision(id: proposals.messageID, contextID: proposals.contextID,
                                                                  text: edit, automatic: automatic)
      if automatic {
        replacementTask = Task { [weak self] in await self?.applySelectionRevision(messageID: proposals.messageID) }
      }
    }
    guard content != sessions[sessionIndex].messages[messageIndex].content else { return }
    sessions[sessionIndex].messages[messageIndex].content = content
    persistSessions(immediately: false)
  }

  /// F32: whether the selected chat's history may go to `route`. A chat holding message text
  /// goes only to a company all of that text was allowed for, and never to one Enigma can't name.
  func messageTextMayGo(to route: Route) -> Bool {
    guard nativeToolsEnabled, route.mode == .cloud, let session = selectedSessionID else { return true }
    guard let destination = ToolDestination(route: route) else {
      return !toolPermissions.store.hasMessageText(session: session)
    }
    return toolPermissions.store.messageTextAllowed(session: session, destination: destination)
  }

  /// Marks that a chat holds message text allowed for `destination`, in memory and with the saved chat.
  private func markMessageText(in sessionID: UUID, destination: ToolDestination) {
    toolPermissions.store.markMessageText(session: sessionID, destination: destination)
    if let index = sessions.firstIndex(where: { $0.id == sessionID }) { sessions[index].holdsMessageText = true }
  }

  /// Saves that a chat holds message text as soon as a tool returns some, before any reply can
  /// quote it, so gate 3 still asks after a relaunch.
  private func saveMessageTextMark(_ sessionID: UUID) {
    guard toolPermissions.store.hasMessageText(session: sessionID),
          let index = sessions.firstIndex(where: { $0.id == sessionID }), sessions[index].holdsMessageText != true else { return }
    sessions[index].holdsMessageText = true
    if !isUnsaved(sessions[index]) { persistSessions() }
  }

  /// Ends what the permission cards granted for chats that are gone.
  private func endToolSessions(_ ids: [UUID]) {
    for id in ids { toolPermissions.store.endSession(id) }
  }

  private func appendFileText(_ text: String, messageID: UUID, sessionID: UUID, requestID: UUID) {
    guard activeRequest?.id == requestID else { return }
    state = .streaming
    append(text, to: messageID, in: sessionID)
  }

  /// `allowsAutomaticSearch` is false when the caller already decided, as the composer does
  /// from its resolved draft: a dismissed search chip must stay off.
  func shouldSearch(_ prompt: String, explicitlyEnabled: Bool, allowsAutomaticSearch: Bool = true) -> Bool {
    // Source material may refine an authorized query, but cannot authorize network access.
    explicitlyEnabled || (allowsAutomaticSearch && searchSettings?.canSearchAutomatically == true
      && WebSearchPolicy.needsFreshInformation(prompt))
  }

  func submit(_ prompt: String, searchEnabled: Bool = false, allowsAutomaticSearch: Bool = true,
              onAccepted: @escaping @MainActor () -> Void = {}) {
    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !ThinkCommand.message(trimmedPrompt).content.isEmpty, !isBusy else { return }
    let searchEnabled = shouldSearch(trimmedPrompt, explicitlyEnabled: searchEnabled,
                                     allowsAutomaticSearch: allowsAutomaticSearch)
    if let model = installedModel, model.supportsVision {
      submitScreen(trimmedPrompt, attachment: nil, decision: .text(model.screenModel), selectedMode: .local,
                   searchEnabled: searchEnabled, allowsAutomaticSearch: false, cloudUploadAllowed: { false },
                   onAccepted: onAccepted)
      return
    }
    screenRouteDecision = nil
    let responseID = UUID()
    let userMessage = contextualMessage(trimmedPrompt)
    let request = LocalModelRequest(messages: requestMessages + [userMessage])
    let active = beginGeneration(
      route: Route(mode: .local, providerID: "local", modelID: installedModel?.id ?? "", usesNetwork: searchEnabled),
      modelDisplayName: installedModel?.displayName ?? "Local model", userMessage: userMessage
    )
    contextNotice = nil
    state = .preparing
    pendingUserMessage = userMessage

    generationTask = Task { [weak self, engine] in
      do {
        try Task.checkCancellation()
        let model = await engine.installedModel()
        try Task.checkCancellation()
        guard let owner = self, owner.activeRequest?.id == active.id else { return }
        guard let model else { throw LocalInferenceError.noModelInstalled }
        // Resolve the engine's selection before preparation, including when the
        // initial model-library refresh has not finished yet.
        owner.activeRequest = ActiveRequest(
          id: active.id,
          route: Route(mode: .local, providerID: "local", modelID: model.id, usesNetwork: searchEnabled),
          modelDisplayName: model.displayName
        )
        var prepared = try await engine.prepare(request)
        var sources: [WebSearchSource]?
        if searchEnabled {
          try Task.checkCancellation()
          guard owner.activeRequest?.id == active.id else { return }
          owner.state = .searching
          let results = try await owner.search(trimmedPrompt, maximumTokens: WebSearchLimits.evidenceTokens, requestID: active.id)
          try Task.checkCancellation()
          guard owner.activeRequest?.id == active.id else { return }
          owner.state = .preparing
          let grounded = try await WebSearchContext.prepare(messages: owner.locationGrounded(request.messages), results: results) {
            try await engine.prepare(LocalModelRequest(messages: $0))
          }
          prepared = grounded.prepared
          sources = grounded.sources
          owner.receiveActivity(.sourcesSelected(grounded.sources), requestID: active.id)
        }
        try Task.checkCancellation()
        guard owner.activeRequest?.id == active.id else { return }
        let sessionID = owner.ensureSelectedSession()
        owner.contextNotice = prepared.notice
        owner.append(userMessage, to: sessionID)
        owner.append(ChatMessage(id: responseID, role: .assistant, content: "", searchSources: sources), to: sessionID)
        owner.messagesFollowUpSessionID = nil
        onAccepted()
        try Task.checkCancellation()
        guard owner.activeRequest?.id == active.id else { return }
        let boundedRequest = LocalModelRequest(
          messages: prepared.messages,
          maximumTokenCount: request.maximumTokenCount,
          temperature: request.temperature
        )
        owner.receiveActivity(.phase(.thinking), requestID: active.id)
        for try await fragment in engine.stream(boundedRequest) {
          try Task.checkCancellation()
          guard let self, self.activeRequest?.id == active.id else { return }
          self.state = .streaming
          self.append(fragment, to: responseID, in: sessionID)
        }
        try Task.checkCancellation()
        await self?.finishGeneration(id: active.id)
      } catch is CancellationError {
        await self?.finishGeneration(id: active.id)
      } catch {
        await self?.finishGeneration(id: active.id, error: error)
      }
    }
  }

  func submitScreen(
    _ prompt: String,
    attachment: ScreenAttachment?,
    decision: ScreenRoutingPolicy.Decision,
    selectedMode: ChatMode,
    searchEnabled: Bool = false,
    allowsAutomaticSearch: Bool = true,
    cloudUploadAllowed: @escaping @MainActor () -> Bool,
    onAccepted: @escaping @MainActor () -> Void = {}
  ) {
    let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !ThinkCommand.message(prompt).content.isEmpty, !isBusy, let model = decision.model else { return }
    let searchEnabled = shouldSearch(prompt, explicitlyEnabled: searchEnabled, allowsAutomaticSearch: allowsAutomaticSearch)
    guard selectedMode != .local || model.isLocal else {
      state = .failed(ScreenRequestError.cloudUploadNotAllowed.localizedDescription)
      return
    }
    if decision.sendsImage && !model.canUseVision {
      state = .failed(ScreenRequestError.textOnlyModel.localizedDescription)
      return
    }
    if !messageTextMayGo(to: model.route) {
      state = .failed(NativeToolsError.messageTextStays.localizedDescription)
      return
    }
    let userMessage = contextualMessage(prompt)
    let preferOCR = attachment.map {
      ScreenRoutingPolicy.hasConfidentTextForLookup(prompt: prompt,
        ocr: ScreenOCRResult(text: $0.ocrText, confidence: $0.ocrConfidence))
    } ?? false
    let requestText = attachment.map { ScreenPromptContext.text(userPrompt: userMessage.content, ocr: $0.ocrText, preferOCR: preferOCR) } ?? userMessage.content
    var current = userMessage
    current.content = requestText
    let history = requestMessages + [current]
    let pixels = decision.sendsImage ? attachment?.originalImage.cgImage(forProposedRect: nil, context: nil, hints: nil) : nil
    if decision.sendsImage && pixels == nil { state = .failed(ScreenCaptureError.invalidImage.localizedDescription); return }
    let active = beginGeneration(route: model.route(searchEnabled: searchEnabled), modelDisplayName: model.id, userMessage: userMessage)
    state = .preparing
    contextNotice = nil
    screenRouteDecision = attachment == nil ? nil : decision
    var pending = userMessage
    pending.imagePreview = attachment?.makeMessagePreview()
    pendingUserMessage = pending
    generationTask = Task { [weak self, engine] in
      guard let owner = self else { return }
      var acceptedSession: UUID?
      let responseID = UUID()
      do {
        let image: PreparedScreenImage?
        if let pixels {
          image = try await Task.detached(priority: .userInitiated) { try ScreenImagePreprocessor.prepare(pixels) }.value
        } else { image = nil }
        try Task.checkCancellation()
        guard owner.activeRequest?.id == active.id else { return }
        var target = model
        let requestImage = image
        var requestHistory = history
        var searchQuery: String?
        // Reuse retrieved evidence if an offline cloud attempt falls back to local vision.
        var searchResults: [WebSearchResult]?
        while true {
          do {
            let route = target.route(searchEnabled: searchEnabled)
            let prepare: ([ChatMessage], PreparedScreenImage?) async throws -> PreparedConversation
            let localModel: LocalModel?
            if target.isLocal {
              let installed = await engine.installedModels()
              try Task.checkCancellation()
              guard let installedModel = installed.first(where: { $0.id == target.id }) else { throw LocalInferenceError.noModelInstalled }
              guard await engine.installedModel()?.id == target.id else {
                throw LocalInferenceError.bridgeFailure("The selected local model changed. Please send your draft again.")
              }
              localModel = installedModel
              if installedModel.supportsVision {
                try LocalVisionModelValidation.validate(installedModel)
                await engine.unload()
                try Task.checkCancellation()
                guard owner.activeRequest?.id == active.id else { return }
                prepare = { try await owner.visionEngine.prepare(messages: $0, image: $1, model: installedModel) }
              } else {
                guard requestImage == nil else { throw ScreenRequestError.textOnlyModel }
                guard await engine.installedModel()?.id == target.id else {
                  throw LocalInferenceError.bridgeFailure("The selected local model changed. Please send your draft again.")
                }
                prepare = { messages, _ in try await engine.prepare(LocalModelRequest(messages: messages)) }
              }
            } else {
              localModel = nil
              guard CloudProviderID(rawValue: target.provider) != nil else { throw CloudProviderError.invalidResponse }
              let request = ChatRequest(sessionID: owner.selectedSessionID ?? UUID(), messages: history,
                                        route: route, image: requestImage, allowsCloudImages: requestImage != nil && cloudUploadAllowed())
              try ScreenRequestGuard.validateCloud(request)
              prepare = { messages, image in
                try CloudContext.prepare(ChatRequest(sessionID: request.sessionID, messages: messages,
                  route: route, image: image, allowsCloudImages: request.allowsCloudImages))
              }
            }
            // Validate the full question and screenshot budget before contacting Brave.
            var prepared = try await prepare(requestHistory, requestImage)
            var sources: [WebSearchSource]?
            if searchEnabled {
              try Task.checkCancellation()
              guard owner.activeRequest?.id == active.id else { return }
              if searchResults == nil {
                if let attachment, searchQuery == nil {
                  owner.activeRequest = ActiveRequest(id: active.id, route: route, modelDisplayName: target.id)
                  owner.state = .refiningSearch
                  owner.receiveActivity(.phase(.refiningSearch), requestID: active.id)
                  let queryRequest = [ChatMessage(role: .user, content:
                    ScreenSearchContext.queryPrompt(question: ScreenSearchContext.question(prompt), material: .screen(ocr: attachment.ocrText)))]
                  let queryContext = try await prepare(queryRequest, requestImage)
                  let queryStream = try await owner.screenOutput(queryContext, image: requestImage,
                    target: target, localModel: localModel, activeID: active.id, cloudUploadAllowed: cloudUploadAllowed,
                    temperature: 0)
                  searchQuery = try ScreenSearchContext.query(from:
                    await ScreenSearchContext.collect(queryStream, maximumBytes: 1_024))
                }
                try Task.checkCancellation()
                guard owner.activeRequest?.id == active.id else { return }
                if requestImage != nil && !target.isLocal && !cloudUploadAllowed() {
                  throw ScreenRequestError.cloudUploadNotAllowed
                }
                owner.state = .searching
                // Screen queries resolve the user's references with relevant observed facts.
                // Pixels, raw OCR, and conversation history are never attached to Brave.
                searchResults = try await owner.search(prompt, writtenQuery: searchQuery, maximumTokens: WebSearchLimits.evidenceTokens, requestID: active.id)
              }
              try Task.checkCancellation()
              guard owner.activeRequest?.id == active.id else { return }
              owner.state = .preparing
              if let attachment, let searchQuery {
                requestHistory[requestHistory.count - 1].content = ScreenPromptContext.text(userPrompt: prompt,
                  ocr: attachment.ocrText, preferOCR: preferOCR)
                  + "\n\nSearch query used to retrieve the evidence: " + searchQuery
              }
              let grounded = try await WebSearchContext.prepare(messages: owner.locationGrounded(requestHistory), results: searchResults!) {
                try await prepare($0, requestImage)
              }
              prepared = grounded.prepared
              sources = grounded.sources
              owner.receiveActivity(.sourcesSelected(grounded.sources), requestID: active.id)
            }
            try Task.checkCancellation()
            guard owner.activeRequest?.id == active.id else { return }
            owner.receiveActivity(.phase(.thinking), requestID: active.id)
            let output = try await owner.screenOutput(prepared, image: requestImage, target: target,
              localModel: localModel, activeID: active.id, cloudUploadAllowed: cloudUploadAllowed,
              temperature: searchEnabled ? 0.2 : 0.7)
            owner.contextNotice = prepared.notice
            owner.activeRequest = ActiveRequest(id: active.id, route: route, modelDisplayName: target.id)
            for try await fragment in output {
              try Task.checkCancellation()
              guard owner.activeRequest?.id == active.id else { return }
              guard !fragment.isEmpty else { continue }
              if acceptedSession == nil {
                let session = owner.ensureSelectedSession()
                acceptedSession = session
                // The preview is UI-only; persistence still saves just the user's question.
                var displayedMessage = userMessage
                displayedMessage.imagePreview = attachment?.makeMessagePreview()
                owner.append(displayedMessage, to: session)
                owner.append(ChatMessage(id: responseID, role: .assistant, content: "", searchSources: sources), to: session)
                owner.messagesFollowUpSessionID = nil
                onAccepted()
                try Task.checkCancellation()
                guard owner.activeRequest?.id == active.id else { return }
              }
              owner.state = .streaming
              owner.append(fragment, to: responseID, in: acceptedSession!)
            }
            guard acceptedSession != nil else { throw CloudProviderError.streamEndedUnexpectedly }
            break
          } catch {
            // A genuinely offline cloud attempt can fall back before any reply is accepted.
            if !target.isLocal, requestImage != nil, acceptedSession == nil,
               normalizedCloudError(error) as? CloudProviderError == .offline,
               let fallback = await engine.installedModel(), fallback.supportsVision, selectedMode == .auto {
              try Task.checkCancellation()
              target = fallback.screenModel
              owner.screenRouteDecision = .vision(target)
              continue
            }
            throw error
          }
        }
        await owner.finishGeneration(id: active.id)
      } catch is CancellationError {
        await owner.finishGeneration(id: active.id)
      } catch {
        await owner.finishGeneration(id: active.id, error: error)
      }
    }
  }

  private func screenOutput(
    _ prepared: PreparedConversation, image: PreparedScreenImage?, target: ScreenModel,
    localModel: LocalModel?, activeID: UUID, cloudUploadAllowed: @MainActor () -> Bool,
    temperature: Float = 0.7
  ) async throws -> AsyncThrowingStream<String, Error> {
    try Task.checkCancellation()
    guard activeRequest?.id == activeID else { throw CancellationError() }
    if let localModel {
      if localModel.supportsVision {
        // The embedded engine was released before loading the tokenizer for preparation.
        return visionEngine.stream(messages: prepared.messages, image: image, model: localModel, temperature: temperature)
      }
      guard await engine.installedModel()?.id == target.id else {
        throw LocalInferenceError.bridgeFailure("The selected local model changed. Please send your draft again.")
      }
      try Task.checkCancellation()
      guard activeRequest?.id == activeID else { throw CancellationError() }
      return engine.stream(LocalModelRequest(messages: prepared.messages, temperature: temperature))
    }
    guard let providerID = CloudProviderID(rawValue: target.provider) else { throw CloudProviderError.invalidResponse }
    let request = ChatRequest(sessionID: selectedSessionID ?? UUID(), messages: prepared.messages,
      route: target.route, image: image, allowsCloudImages: image != nil && cloudUploadAllowed())
    // Recheck consent at every image-bearing stage, including after search.
    try ScreenRequestGuard.validateCloud(request)
    return cloudProviders.provider(for: providerID).textStream(request) { [weak self] event in
      await self?.receiveActivity(event, requestID: activeID)
    }
  }

  func submitCloud(
    _ prompt: String,
    provider providerID: CloudProviderID,
    modelID: String,
    searchEnabled: Bool = false,
    allowsAutomaticSearch: Bool = true,
    onAccepted: @escaping @MainActor () -> Void = {}
  ) {
    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    let searchEnabled = shouldSearch(trimmedPrompt, explicitlyEnabled: searchEnabled,
                                     allowsAutomaticSearch: allowsAutomaticSearch)
    screenRouteDecision = nil
    guard !ThinkCommand.message(trimmedPrompt).content.isEmpty, !trimmedModelID.isEmpty, !isBusy else { return }
    let route = Route(
      mode: .cloud,
      providerID: providerID.rawValue,
      modelID: trimmedModelID,
      usesNetwork: true
    )
    // F32: a cloud model without native tools can't show the card, so it doesn't take a chat whose
    // message text wasn't allowed for its company.
    if !messageTextMayGo(to: route) {
      state = .failed(NativeToolsError.messageTextStays.localizedDescription)
      return
    }
    let userMessage = contextualMessage(trimmedPrompt)
    let prepared: PreparedConversation
    contextNotice = nil
    do {
      prepared = try CloudContext.prepare(ChatRequest(
        sessionID: selectedSessionID ?? UUID(), messages: requestMessages + [userMessage], route: route
      ))
    } catch {
      state = .failed(error.localizedDescription)
      return
    }
    if searchEnabled {
      submitCloudWithSearch(
        userMessage, route: route, onAccepted: onAccepted
      )
      return
    }
    let sessionID = ensureSelectedSession()
    let responseID = UUID()
    let active = beginGeneration(route: route, modelDisplayName: trimmedModelID, userMessage: userMessage)
    append(userMessage, to: sessionID)
    append(ChatMessage(id: responseID, role: .assistant, content: ""), to: sessionID)
    contextNotice = prepared.notice
    state = .preparing
    let provider = cloudProviders.provider(for: providerID)
    let request = ChatRequest(sessionID: sessionID, messages: prepared.messages, route: route)
    generationTask = Task { [weak self] in
      do {
        try Task.checkCancellation()
        guard self?.activeRequest?.id == active.id else { return }
        self?.receiveActivity(.phase(.thinking), requestID: active.id)
        for try await event in provider.stream(request) {
          try Task.checkCancellation()
          guard let self, self.activeRequest?.id == active.id else { return }
          switch event {
          case .activity(let update):
            self.receiveActivity(update, requestID: active.id)
          case .token(let fragment):
            self.state = .streaming
            self.append(fragment, to: responseID, in: sessionID)
          case .completed:
            break
          }
        }
        try Task.checkCancellation()
        await self?.finishGeneration(id: active.id)
      } catch is CancellationError {
        await self?.finishGeneration(id: active.id)
      } catch {
        await self?.finishGeneration(id: active.id, error: error)
      }
    }
    // Install the handle before calling out: acceptance may synchronously Stop or start a new chat.
    messagesFollowUpSessionID = nil
    onAccepted()
  }

  private func submitCloudWithSearch(
    _ userMessage: ChatMessage, route: Route, onAccepted: @escaping @MainActor () -> Void
  ) {
    let history = requestMessages + [userMessage]
    let active = beginGeneration(route: route, modelDisplayName: route.modelID, userMessage: userMessage)
    state = .searching
    pendingUserMessage = userMessage
    generationTask = Task { [weak self] in
      do {
        try Task.checkCancellation()
        guard let owner = self, owner.activeRequest?.id == active.id else { return }
        let results = try await owner.search(userMessage.content, maximumTokens: WebSearchLimits.evidenceTokens, requestID: active.id)
        try Task.checkCancellation()
        guard owner.activeRequest?.id == active.id else { return }
        let grounded = try await WebSearchContext.prepare(messages: owner.locationGrounded(history), results: results) {
          try CloudContext.prepare(ChatRequest(sessionID: UUID(), messages: $0, route: route))
        }
        try Task.checkCancellation()
        guard owner.activeRequest?.id == active.id,
              let providerID = CloudProviderID(rawValue: route.providerID) else { return }
        let sessionID = owner.ensureSelectedSession()
        let responseID = UUID()
        owner.receiveActivity(.sourcesSelected(grounded.sources), requestID: active.id)
        owner.contextNotice = grounded.prepared.notice
        owner.state = .preparing
        owner.append(userMessage, to: sessionID)
        owner.append(ChatMessage(id: responseID, role: .assistant, content: "", searchSources: grounded.sources), to: sessionID)
        owner.messagesFollowUpSessionID = nil
        onAccepted()
        try Task.checkCancellation()
        guard owner.activeRequest?.id == active.id else { return }
        let request = ChatRequest(sessionID: sessionID, messages: grounded.prepared.messages, route: route)
        let provider = owner.cloudProviders.provider(for: providerID)
        self?.receiveActivity(.phase(.thinking), requestID: active.id)
        for try await event in provider.stream(request) {
          try Task.checkCancellation()
          guard owner.activeRequest?.id == active.id else { return }
          if case .activity(let update) = event { owner.receiveActivity(update, requestID: active.id) }
          if case .token(let fragment) = event {
            owner.state = .streaming
            owner.append(fragment, to: responseID, in: sessionID)
          }
        }
        try Task.checkCancellation()
        await owner.finishGeneration(id: active.id)
      } catch is CancellationError {
        await self?.finishGeneration(id: active.id)
      } catch {
        await self?.finishGeneration(id: active.id, error: error)
      }
    }
  }

  func submitAuto(
    _ prompt: String,
    cloud: AutoRouter.CloudConfiguration?,
    searchEnabled: Bool = false,
    allowsAutomaticSearch: Bool = true,
    onAccepted: @escaping @MainActor () -> Void = {}
  ) {
    guard !isBusy, !ThinkCommand.message(prompt).content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    state = .idle
    contextNotice = nil
    // Auto starts local: with a flagged local model, its own tools decide about search.
    let localFlagged = nativeToolsEnabled && installedModel.map {
      NativeTools.isCapable(route: Route(mode: .local, providerID: "local", modelID: $0.id, usesNetwork: false), localModel: $0)
    } == true
    let searchEnabled = localFlagged ? searchEnabled
      : shouldSearch(prompt, explicitlyEnabled: searchEnabled, allowsAutomaticSearch: allowsAutomaticSearch)
    var decision = (searchEnabled || AutoRouter.shouldRun(for: .auto, cloud: cloud))
      ? AutoRouter.decide(AutoRouter.Request(
        selectedMode: .auto, webSearchEnabled: searchEnabled,
        prompt: ConversationContextPrompt.expand(contextualMessage(prompt, responseInstructions: false)).content,
        webSearchPrompt: prompt, contextMessages: autoRoutingContextMessages,
        localModel: installedModel, cloud: cloud, modelChoosesSearch: localFlagged
      ))
      : AutoRouter.localFallback(localModel: installedModel)
    // A chat holding message text stays where that text was allowed, as Auto /messages stays on this Mac.
    if let route = decision.route, !messageTextMayGo(to: route) {
      decision = AutoRouter.localFallback(localModel: installedModel)
    }
    autoRouteDecision = decision
    guard let route = decision.route else { return }
    if nativeToolsEnabled, NativeTools.isCapable(route: route, localModel: installedModel) {
      // A search chip shown for an unflagged local model counts as a typed /search here.
      let typed = ComposerCommands((searchEnabled ? "/search " : "") + prompt)
      submitNative(prompt, route: route, plan: nativeToolPlan(for: typed), onAccepted: onAccepted)
      return
    }
    switch route.mode {
    // The search decision is made; the route it picked must not make it again.
    case .local:
      submit(prompt, searchEnabled: searchEnabled, allowsAutomaticSearch: false, onAccepted: onAccepted)
    case .cloud:
      guard let provider = CloudProviderID(rawValue: route.providerID) else { return }
      submitCloud(prompt, provider: provider, modelID: route.modelID, searchEnabled: searchEnabled,
                  allowsAutomaticSearch: false, onAccepted: onAccepted)
    case .auto:
      break
    }
  }

  func clearAutoRouteDecision() {
    autoRouteDecision = nil
  }

  /// Stops the running request and holds the message queue. The returned
  /// consumer task can be awaited to observe its shutdown.
  @discardableResult
  func stopStreaming() -> Task<Void, Never>? {
    guard let task = generationTask else { return nil }
    files.revoke()
    holdQueue()
    if let id = activeRequest?.id { receiveActivity(.phase(.cancelled), requestID: id) }
    // Revoke ownership before cancellation can release any queued events or cleanup.
    activeRequest = nil
    activity = nil
    activityMessageID = nil
    pendingUserMessage = nil
    generationTask = nil
    state = .idle
    task.cancel()
    sessionWriter.flush()
    scheduleIdleUnload()
    return task
  }

  /// Opens a fresh chat: no chat selected, as at launch. Nothing is written
  /// for it; `ensureSelectedSession()` makes it once it's used.
  func newChat() {
    // Stopping first: a question still being prepared never reached its
    // chat, so a chat it was the first of is left empty and goes.
    stopStreaming()
    clearQueue()
    leaveEmptyChat(for: nil)
    discardTemporaryChat()
    SelectionContextService.shared.discardTarget()
    files.restoreSelection(nil)
    contextNotice = nil
    appleMessages.issue = nil
    autoRouteDecision = nil
    screenRouteDecision = nil
    messagesFollowUpSessionID = nil
    if case .failed = state { state = .idle }
    selectedSessionID = nil
    files.conversationID = nil
  }

  /// Leaving the open chat for `next`, or for a new chat: a chat that never
  /// got a message, as one that only had files attached, goes. It was never
  /// written. Temporary and selection chats go through `discardTemporaryChat()`.
  private func leaveEmptyChat(for next: UUID?) {
    guard let id = selectedSessionID, id != next, id != temporarySessionID, id != selectionSessionID,
          let index = sessions.firstIndex(where: { $0.id == id }), sessions[index].messages.isEmpty else { return }
    sessions.remove(at: index)
    endToolSessions([id])
  }

  func selectSession(id: UUID) {
    guard sessions.contains(where: { $0.id == id }), !isBusy else { return }
    leaveEmptyChat(for: id)
    if id != selectionSessionID { discardTemporaryChat(); SelectionContextService.shared.discardTarget() }
    if id != selectedSessionID { messagesFollowUpSessionID = nil; appleMessages.issue = nil; clearQueue() }
    selectedSessionID = id
    files.restoreSelection(selectedSession?.workspace)
    files.conversationID = selectedSessionID
    contextNotice = nil
  }

  /// Returns whether another chat is open now.
  @discardableResult
  func cycleRecentChat() -> Bool {
    let order = historySessions
    guard !isBusy, !order.isEmpty else { return false }
    contextNotice = nil
    let selectedIndex = selectedSessionID.flatMap { id in order.firstIndex(where: { $0.id == id }) }
    let nextID = order[selectedIndex.map { ($0 + 1) % order.count } ?? 0].id
    let changes = nextID != selectedSessionID
    leaveEmptyChat(for: nextID)
    if nextID != selectionSessionID { discardTemporaryChat(); SelectionContextService.shared.discardTarget() }
    if nextID != selectedSessionID { messagesFollowUpSessionID = nil; appleMessages.issue = nil; clearQueue() }
    selectedSessionID = nextID
    files.restoreSelection(selectedSession?.workspace)
    files.conversationID = selectedSessionID
    return changes
  }

  func applicationBecameActive() {
    scheduleIdleUnload()
  }

  func applicationBecameInactive() {
    sessionWriter.flush()
    scheduleIdleUnload()
  }

  private func cancelIdleUnload() {
    idleUnloadTask?.cancel()
    idleUnloadTask = nil
  }

  private func scheduleIdleUnload() {
    // Focus changes and reading an open chat do not extend the model's lifetime.
    // File picking and applying a finished selection also do not use inference.
    // A download doesn't use the engine, so it doesn't keep the model loaded.
    guard idleUnloadTask == nil, activeRequest == nil, generationTask == nil, modelOperation?.blocksChat != true else { return }
    switch state {
    case .idle, .failed: break
    default: return
    }
    idleUnloadTask = Task { [weak self, engine, idleUnloadDelay, sleep] in
      do {
        try await sleep(idleUnloadDelay)
        try Task.checkCancellation()
        guard let self else { return }
        self.idleUnloadTask = nil
        guard self.activeRequest == nil, self.generationTask == nil, self.modelOperation?.blocksChat != true else { return }
        // The server manages its own idle timer on its actor, where it can check
        // active inference atomically. A UI timer must not terminate a new request.
        await engine.unload()
      } catch {
        // A new request or model operation superseded this idle period.
      }
    }
  }

  private func ensureSelectedSession() -> UUID {
    if let selectedSessionID { return selectedSessionID }
    // Not written until its first message lands; it goes to the top of
    // Recents then, by its activity.
    let session = ChatSession()
    sessions.insert(session, at: 0)
    selectedSessionID = session.id
    files.conversationID = session.id
    return session.id
  }

  private func append(_ message: ChatMessage, to sessionID: UUID) {
    guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
    var message = message
    if message.role == .assistant, let activeRequest {
      activityMessageID = message.id
      message.activity = activity
      message.origin = ReplyOrigin(mode: activeRequest.route.mode, providerID: activeRequest.route.providerID,
                                   modelName: activeRequest.modelDisplayName)
    }
    sessions[index].append(message)
    if pendingUserMessage?.id == message.id { pendingUserMessage = nil }
    sortAndPersistSessions()
  }

  private func append(_ fragment: String, to messageID: UUID, in sessionID: UUID) {
    guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
          let messageIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == messageID }) else { return }
    if !fragment.isEmpty {
      hasReceivedResponse = true
      if let id = activeRequest?.id { receiveActivity(.phase(.generating), requestID: id) }
    }
    sessions[sessionIndex].messages[messageIndex].content.append(fragment)
    sessions[sessionIndex].lastActivityAt = .now
    // Appending the assistant message already put this session first and applied retention.
    persistSessions(immediately: false)
  }

  /// A chat kept out of retention and of the saved file: the temporary chat,
  /// and any chat with no messages yet, such as a new one with files
  /// attached, or the selection's chat after moving to the window, which is
  /// in Recents straight away. It's written once its first question lands,
  /// so an empty or abandoned chat never costs an older saved chat.
  private func isUnsaved(_ session: ChatSession) -> Bool {
    session.id == temporarySessionID || session.messages.isEmpty
  }

  private func sortAndPersistSessions() {
    sessions.sort { $0.lastActivityAt > $1.lastActivityAt }
    let retained = Set(sessions.filter { !isUnsaved($0) }
      .prefix(ChatSessionStore.maximumRetainedSessions).map(\.id))
    let evicted = sessions.filter { !isUnsaved($0) && !retained.contains($0.id) }.map(\.id)
    sessions.removeAll { !isUnsaved($0) && !retained.contains($0.id) }
    endToolSessions(evicted)
    persistSessions()
  }

  private func persistSessions(immediately: Bool = true) {
    guard !isTemporaryChat else { return }
    sessionWriter.schedule(immediately: immediately) { [weak self] in
      guard let self else { return nil }
      return self.sessions.filter { !self.isUnsaved($0) }
    }
  }

  private func finishInstallation() {
    modelOperation = nil
    installationTask = nil
    scheduleIdleUnload()
    drainQueueSoon()
  }

  private func updateDownloadProgress(_ progress: ModelDownloadProgress) {
    guard !Task.isCancelled, case .downloading = modelOperation else { return }
    modelOperation = .downloading(progress)
  }

  /// Waits for the current request to end, then holds chat for the commit
  /// and the performance check. The wait ends with cancellation.
  private func holdChatForModelCommit() async throws {
    while isChatActive {
      if case .downloading = modelOperation { modelOperation = .waitingToInstall }
      try await Task.sleep(for: .milliseconds(100))
    }
    try Task.checkCancellation()
    cancelIdleUnload()
    guard modelOperation?.blocksChat != true else { return }
    modelOperation = .installing
    // The old model leaves memory before the new package is installed and measured.
    await engine.unload()
    await visionEngine.unload()
    try Task.checkCancellation()
  }

  private func failInstallation(_ error: Error) {
    if Task.isCancelled { finishInstallation(); return }
    modelFailure = error.localizedDescription
    modelOperation = nil
    installationTask = nil
    scheduleIdleUnload()
    drainQueueSoon()
  }

  private func clearModelFailure() {
    modelFailure = nil
  }

  /// `prompt` is the user's text; `writtenQuery`, a query the screen path's model already wrote from it.
  /// `refinesQuery` is false for a query a capable model wrote with its tools: it's searched as written.
  private func search(_ prompt: String, writtenQuery: String? = nil, maximumTokens: Int,
                      requestID: UUID, refinesQuery: Bool = true) async throws -> [WebSearchResult] {
    receiveActivity(.phase(.searching), requestID: requestID)
    // The user's text loses its slash commands here on every route, before refining, routing
    // and the provider. A model-written query is used as written.
    let question = writtenQuery ?? ScreenSearchContext.question(prompt)
    var contextualQuery = question
    // Only the source material this request carries refines its query.
    let source = requestSource
    if refinesQuery, !source.contexts.isEmpty || source.draft != nil, let active = activeRequest, active.id == requestID {
      state = .refiningSearch
      receiveActivity(.phase(.refiningSearch), requestID: requestID)
      var contexts = source.contexts
      if let draft = source.draft {
        contexts.append(ConversationContext(sourceName: "Proposed revision", text: draft))
      }
      let message = ChatMessage(role: .user, content: ScreenSearchContext.queryPrompt(question: question, material: .attachedText(contexts)))
      let prepared: PreparedConversation
      let stream: AsyncThrowingStream<String, Error>
      if active.route.mode == .local {
        guard let model = await engine.installedModel() else { throw LocalInferenceError.noModelInstalled }
        if model.supportsVision {
          prepared = try await visionEngine.prepare(messages: [message], image: nil, model: model)
          stream = visionEngine.stream(messages: prepared.messages, image: nil, model: model, temperature: 0)
        } else {
          prepared = try await engine.prepare(LocalModelRequest(messages: [message]))
          stream = engine.stream(LocalModelRequest(messages: prepared.messages, maximumTokenCount: 128, temperature: 0))
        }
      } else {
        guard let providerID = CloudProviderID(rawValue: active.route.providerID) else { throw CloudProviderError.invalidResponse }
        prepared = try CloudContext.prepare(ChatRequest(sessionID: selectedSessionID ?? UUID(), messages: [message], route: active.route))
        stream = cloudProviders.provider(for: providerID).textStream(ChatRequest(
          sessionID: selectedSessionID ?? UUID(), messages: prepared.messages, route: active.route))
      }
      do {
        contextualQuery = try ScreenSearchContext.query(from:
          await ScreenSearchContext.collect(stream, maximumBytes: 1_024), source: .attachedText)
      } catch ScreenSearchError.outputTooLong {
        throw ScreenSearchError.outputTooLong(.attachedText)
      }
      try Task.checkCancellation()
      guard activeRequest?.id == requestID else { throw CancellationError() }
      state = .searching
      receiveActivity(.phase(.searching), requestID: requestID)
    }
    guard !contextualQuery.isEmpty else { throw WebSearchError.emptyQuery }
    // The route, location and recency come from the typed question, never from a written query.
    let typedQuestion = ScreenSearchContext.question(prompt)
    let decision = SearchRouting.decide(question: typedQuestion)
    var request = WebSearchRequest(query: contextualQuery, route: decision.route, namedPlace: decision.namedPlace,
      recency: WebSearchPolicy.recency(typedQuestion), maximumTokens: maximumTokens)
    if decision.needsCurrentLocation, let locationProvider {
      let location = try await locationProvider.currentLocation()
      try Task.checkCancellation()
      guard activeRequest?.id == requestID else { throw CancellationError() }
      requestLocationContext = location.searchContext
      request.city = location.searchCity
      request.coordinate = location.coordinate
    }
    let results = try await webSearch.search(request) { [weak self] event in
      // Retrieval candidates are not citation sources until context fitting selects them.
      if case .sourcesDiscovered = event {
        await self?.receiveActivity(.phase(.readingSources), requestID: requestID)
      }
    }
    try Task.checkCancellation()
    receiveActivity(.phase(.readingSources), requestID: requestID)
    return results
  }

  private func receiveActivity(_ event: AssistantActivityEvent, requestID: UUID) {
    guard activeRequest?.id == requestID, var updated = activity else { return }
    updated.apply(event)
    guard updated != activity else { return }
    activity = updated
    guard activeRequest?.id == requestID, let messageID = activityMessageID,
          let sessionIndex = sessions.firstIndex(where: { $0.messages.contains(where: { $0.id == messageID }) }),
          let messageIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == messageID }) else { return }
    sessions[sessionIndex].messages[messageIndex].activity = updated
  }

  private func locationGrounded(_ messages: [ChatMessage]) -> [ChatMessage] {
    guard let context = requestLocationContext, !messages.isEmpty else { return messages }
    var result = messages
    result[result.count - 1].content += "\n\n" + context + "\nUse this area for this question only; mention the area in your answer."
    return result
  }

  private func beginGeneration(route: Route, modelDisplayName: String, userMessage: ChatMessage) -> ActiveRequest {
    cancelIdleUnload()
    requestLocationContext = nil
    let request = ActiveRequest(id: UUID(), route: route, modelDisplayName: modelDisplayName)
    pendingUserMessage = nil
    hasReceivedResponse = false
    activeRequest = request
    requestSource = (userMessage.contexts ?? [], userMessage.selectionDraft)
    nativeProposals = nil
    // The note that a chat opened in the window is saved, or private, is said
    // once, under its first exchange: the next message ends it.
    if messages.contains(where: { $0.role == .user }) { openedSelectionChat = nil }
    selectionEditRequest = nil
    if userMessage.selectionResponseMode == .edit,
       let context = userMessage.contexts?.first(where: { $0.kind == .selectedText }) {
      selectionEditRequest = (request.id, context.id, selectionEditingSettings.automaticallyReplace)
    }
    activityMessageID = nil
    activity = AssistantActivity(id: request.id)
    return request
  }

  func selectionDisplayMessage(_ message: ChatMessage) -> ChatMessage {
    guard message.role == .assistant else { return message }
    guard isSelectionChat else {
      // A kept selection chat, reopened once its selection has gone: show the
      // revised text as text, without the card's protocol.
      guard let response = SelectionRevisionResponse.parse(message.content) else { return message }
      var copy = message
      copy.content = response.acknowledgement + "\n\n" + response.text
        .split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
      return copy
    }
    let request = messages.prefix { $0.id != message.id }.last { $0.role == .user }
    guard request?.selectionResponseMode == .edit || selectionRevisions[message.id] != nil else { return message }
    var copy = message
    copy.content = SelectionRevisionResponse.visibleText(message.content, streaming: activeRequest != nil)
    return copy
  }

  func updateSelectionRevision(messageID: UUID, text: String) {
    guard selectionRevisions[messageID]?.status == .ready || selectionRevisions[messageID]?.status == .failed else { return }
    selectionRevisions[messageID]?.text = text
  }

  func applySelectionRevision(messageID: UUID) async {
    guard !Task.isCancelled, activeRequest == nil, !isApplyingSelection, let revision = selectionRevisions[messageID],
          revision.status == .ready || revision.status == .failed,
          attachedContexts.contains(where: { $0.id == revision.contextID }), !revision.text.isEmpty else { return }
    if revision.automatic && !selectionEditingSettings.automaticallyReplace { return }
    isApplyingSelection = true
    selectionRevisions[messageID]?.status = .applying
    defer { isApplyingSelection = false; drainQueueSoon() }
    let sent = await replaceSelection(revision.text, revision.contextID, revision.automatic)
    guard selectionRevisions[messageID]?.contextID == revision.contextID else { return }
    selectionRevisions[messageID]?.status = sent ? .sent : .failed
    if !sent && revision.automatic { contextNotice = "Automatic replacement was not sent. Select the source text again and retry." }
  }

  private func recoverSelectionResponse(active: ActiveRequest) async throws -> SelectionRevisionResponse.Recovery? {
    // One bounded model recovery, using the same provider and context. Never retry a paste.
    // Recovery belongs to the current /edit request, so it has the selection and the latest draft.
    var instruction = ThinkCommand.message(SelectionRevisionResponse.recoveryInstructions)
    var contexts = attachedContexts
    if let draft = latestSelectionDraft {
      contexts.append(ConversationContext(kind: .file, sourceName: "Latest proposed revision", text: draft))
    }
    instruction.contexts = contexts.isEmpty ? nil : contexts
    let history = requestMessages + [instruction]
    let stream: AsyncThrowingStream<String, Error>
    if active.route.mode == .local {
      guard let model = await engine.installedModel(), model.id == active.route.modelID else {
        throw LocalInferenceError.noModelInstalled
      }
      if model.supportsVision {
        let prepared = try await visionEngine.prepare(messages: history, image: nil, model: model)
        stream = visionEngine.stream(messages: prepared.messages, image: nil, model: model, temperature: 0)
      } else {
        let prepared = try await engine.prepare(LocalModelRequest(messages: history))
        stream = engine.stream(LocalModelRequest(messages: prepared.messages, temperature: 0))
      }
    } else {
      guard let providerID = CloudProviderID(rawValue: active.route.providerID) else { throw CloudProviderError.invalidResponse }
      let prepared = try CloudContext.prepare(ChatRequest(sessionID: selectedSessionID ?? UUID(), messages: history, route: active.route))
      stream = cloudProviders.provider(for: providerID).textStream(ChatRequest(
        sessionID: selectedSessionID ?? UUID(), messages: prepared.messages, route: active.route))
    }
    return SelectionRevisionResponse.recover(try await ScreenSearchContext.collect(stream, maximumBytes: 300_000))
  }

  /// `showsProblem` is false when a card already explains the error.
  private func finishGeneration(id: UUID, error: Error? = nil, showsProblem: Bool = true) async {
    // Also after Stop, which returns early below: File Mode's workspace and
    // the replaced request's cleanup have let go only now.
    defer { drainQueueSoon() }
    if error == nil, !Task.isCancelled, let active = activeRequest, active.id == id,
       let editing = selectionEditRequest, editing.id == id,
       attachedContexts.contains(where: { $0.id == editing.contextID }),
       let message = messages.last, message.role == .assistant, !message.content.isEmpty,
       !message.content.contains(SelectionRevisionResponse.opening) {
      do {
        let recovery = try await recoverSelectionResponse(active: active)
        try Task.checkCancellation()
        guard activeRequest?.id == id else { return }
        if selectionEditRequest?.id == id, attachedContexts.contains(where: { $0.id == editing.contextID }) {
          switch recovery {
          case .revision(let response):
            if let sessionIndex = sessions.firstIndex(where: { $0.id == selectedSessionID }),
               let index = sessions[sessionIndex].messages.firstIndex(where: { $0.id == message.id }) {
              sessions[sessionIndex].messages[index].content = response.formatted
            }
          case .answer: break
          case nil: contextNotice = "The model could not prepare a revised-text card. Ask it to try again."
          }
        }
      } catch {
        if !Task.isCancelled, activeRequest?.id == id, selectionEditRequest?.id == id {
          contextNotice = "The revised-text card could not be prepared. Please try again."
        }
      }
    }
    guard activeRequest?.id == id else { return }
    if error == nil, !Task.isCancelled { applyNativeProposals(requestID: id) }
    nativeProposals = nil
    if error == nil, !Task.isCancelled, let editing = selectionEditRequest, editing.id == id,
       attachedContexts.contains(where: { $0.id == editing.contextID }), let message = messages.last, message.role == .assistant {
      if let response = SelectionRevisionResponse.parse(message.content) {
        let automatic = editing.automatic && selectionEditingSettings.automaticallyReplace
        selectionRevisions[message.id] = SelectionRevision(id: message.id, contextID: editing.contextID,
          text: response.text, automatic: automatic)
        if automatic {
          replacementTask = Task { [weak self] in await self?.applySelectionRevision(messageID: message.id) }
        }
      } else if message.content.contains(SelectionRevisionResponse.opening) {
        contextNotice = "The model did not return a complete revision. Ask it to try again."
      }
    }
    selectionEditRequest = nil
    receiveActivity(.phase(error == nil ? .completed : .failed), requestID: id)
    activeRequest = nil
    activity = nil
    activityMessageID = nil
    pendingUserMessage = nil
    generationTask = nil
    state = showsProblem ? (error.map { .failed($0.localizedDescription) } ?? .idle) : .idle
    sessionWriter.flush()
    scheduleIdleUnload()
    if error == nil, !Task.isCancelled { queuedInFlight = nil } else { holdQueue() }
  }

  // MARK: Message queue

  /// Adds a message to the end of the queue. It sends at once if nothing
  /// holds the chat and the queue isn't held. Returns false for blank text or
  /// at the cap.
  @discardableResult
  func queueMessage(_ text: String, dismissed: Set<SlashCommand> = []) -> Bool {
    guard messageQueue.enqueue(text, dismissed: dismissed) != nil else { return false }
    drainQueue()
    return true
  }

  func cancelQueuedMessage(id: UUID) {
    messageQueue.cancel(id: id)
  }

  /// Stops the running reply, if any, and sends this message at once, ahead
  /// of the others, which then drain after it.
  func sendQueuedMessageNow(id: UUID) {
    guard let message = messageQueue.take(id: id) else { return }
    stopStreaming()
    messageQueue.resume()
    guard !isBusy else {
      // Something else still holds the chat, such as File Mode closing its
      // workspace after Stop or a performance check: it goes first once
      // that ends, which drains the queue.
      messageQueue.returnToHead(message)
      return
    }
    send(message)
  }

  /// Sends the next queued message if nothing holds the chat. Safe to call any time.
  func drainQueue() {
    guard !isBusy, queuedMessageSender != nil, let message = messageQueue.popNext() else { return }
    send(message)
  }

  /// Drains on a fresh turn, once whatever just ended has let go of the chat.
  private func drainQueueSoon() {
    guard !messageQueue.isEmpty else { return }
    Task { @MainActor [weak self] in self?.drainQueue() }
  }

  private func send(_ message: QueuedMessage) {
    guard let sender = queuedMessageSender else {
      messageQueue.returnToHead(message)
      return
    }
    queuedInFlight = (message, false)
    sender(message) { [weak self] in
      guard let self, self.queuedInFlight?.message.id == message.id else { return }
      self.queuedInFlight?.accepted = true
    }
    // Nothing started, as when no model is ready or a check failed at once:
    // it goes back in front, and the queue waits.
    if !isChatActive, queuedInFlight?.message.id == message.id {
      queuedInFlight = nil
      messageQueue.returnToHead(message)
      messageQueue.hold()
    }
  }

  /// A reply failed or was stopped. A queued message that never reached the
  /// chat goes back in front; nothing else sends until Send now.
  private func holdQueue() {
    if let inFlight = queuedInFlight, !inFlight.accepted { messageQueue.returnToHead(inFlight.message) }
    queuedInFlight = nil
    messageQueue.hold()
  }

  private func clearQueue() {
    messageQueue.clear()
    queuedInFlight = nil
  }
}

/// A flagged request's selection proposals, applied to its reply when it finishes.
private struct NativeProposals {
  let requestID: UUID
  let messageID: UUID
  let sessionID: UUID
  let contextID: UUID
  let editRequested: Bool
  var edit: String?
  var translations: [String] = []
}

enum NativeToolsError: LocalizedError, Equatable {
  /// The user kept a chat's message text from a company its text wasn't allowed for.
  case messageTextStays

  var errorDescription: String? {
    "This chat includes text from your messages, so it wasn't sent. Continue it with Local, or start a new chat."
  }
}

/// Whether a flagged reply has started: its first text or tool call (F30).
private final class NativeReplyStart: Sendable {
  private let started = Mutex(false)
  var isStarted: Bool { started.withLock { $0 } }
  @Sendable func mark() { started.withLock { $0 = true } }
}

/// Saves the chat's message-text mark as soon as a tool returns message text. On a provider-search
/// request the user hasn't allowed, it then holds the text back and restarts the turn (F30, spec §2):
/// the provider's search runs on its servers, where no card can ask for each query.
private struct SavingMessagesGate: MessagesAccessGate {
  let gate: CoordinatorMessagesGate
  let restartsProviderSearch: Bool
  let onMessageText: @Sendable () async -> Void

  func mayRead(chatGUID: String, name: String) async -> Bool { await gate.mayRead(chatGUID: chatGUID, name: name) }
  func maySearch(query: String) async -> Bool { await gate.maySearch(query: query) }
  func isAllowed(chatGUID: String) async -> Bool { await gate.isAllowed(chatGUID: chatGUID) }
  func didReturnMessageText() async throws {
    await gate.didReturnMessageText()
    await onMessageText()
    if restartsProviderSearch { throw ProviderSearchRestart() }
  }
}
