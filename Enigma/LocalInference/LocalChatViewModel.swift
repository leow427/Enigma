import AppKit
import Combine
import Foundation

@MainActor
final class LocalChatViewModel: ObservableObject {
  static let shared = LocalChatViewModel(engine: LlamaCPPModelEngine(), modelAdvisor: .shared, searchSettings: .shared, locationProvider: LocationService.shared)

  enum State: Equatable {
    case idle
    case installing
    case deleting
    case benchmarking
    case downloading(ModelDownloadProgress)
    case preparing
    case refiningSearch
    case searching
    case streaming
    case failed(String)
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
  @Published private(set) var activeRequest: ActiveRequest?
  @Published private(set) var autoRouteDecision: AutoRouter.Decision?
  @Published private(set) var screenRouteDecision: ScreenRoutingPolicy.Decision?
  @Published private(set) var state: State = .idle
  @Published private(set) var benchmarkNotice: String?
  private let modelAdvisor: LocalModelAdvisor?

  @Published private(set) var attachedContexts: [ConversationContext] = []
  @Published private(set) var selectionRevisions: [UUID: SelectionRevision] = [:]
  @Published private(set) var isApplyingSelection = false
  let selectionEditingSettings: SelectionEditingSettings
  private let replaceSelection: @MainActor (String, UUID) async -> Bool
  private var selectionEditRequest: (id: UUID, contextID: UUID, automatic: Bool)?
  /// The source material the active request carries, for refining its search query.
  private var requestSource: (contexts: [ConversationContext], draft: String?) = ([], nil)
  private var replacementTask: Task<Void, Never>?
  private var selectionSettingsObservation: AnyCancellable?
  /// The panel's chat while it's still temporary: kept in memory, never saved.
  private var temporarySessionID: UUID?
  /// The chat the attached selection belongs to: the panel's temporary chat,
  /// and the same chat once it opens in the full window and is saved.
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
  /// The chats Recents lists: every chat but a temporary one.
  var historySessions: [ChatSession] { sessions.filter { $0.id != temporarySessionID } }
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
    files.conversationID = session.id
    attachedContexts = context.map { [$0] } ?? []
    if case .failed = state { state = .idle }
  }

  /// Leaving the selection's chat: the selection and its drafts go, and so
  /// does the chat itself while it's still temporary.
  private func discardTemporaryChat() {
    replacementTask?.cancel(); replacementTask = nil
    selectionEditRequest = nil
    selectionRevisions = [:]
    if let temporarySessionID { sessions.removeAll { $0.id == temporarySessionID } }
    temporarySessionID = nil
    selectionSessionID = nil
    openedSelectionChat = nil
    attachedContexts = []
  }

  /// The panel's chat opened in the full window. By default it becomes an
  /// ordinary chat, saved to history from now on; until now nothing of it was
  /// written. With "Keep selection chats private" on, read now, it stays
  /// temporary: never saved, out of Recents, and gone with the next chat. The
  /// selection stays attached for /edit and Replace text, in memory only:
  /// selected text is never written to disk.
  func openTemporaryChatInWindow() {
    guard let id = temporarySessionID, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
    guard !selectionEditingSettings.keepsChatsPrivate else {
      openedSelectionChat = OpenedSelectionChat(id: id, isPrivate: true)
      return
    }
    temporarySessionID = nil
    let question = sessions[index].messages.first { $0.role == .user }?.content
      ?? pendingUserMessage.map(\.content)
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

  var selectedSession: ChatSession? {
    guard let selectedSessionID else { return nil }
    return sessions.first(where: { $0.id == selectedSessionID })
  }

  var isBusy: Bool {
    if isApplyingSelection || activeRequest != nil || generationTask != nil || installationTask != nil || files.isWorking || files.isPicking { return true }
    switch state {
    case .installing, .deleting, .downloading, .benchmarking, .preparing, .refiningSearch, .searching, .streaming: return true
    case .idle, .failed: return false
    }
  }

  let files: FileModeCoordinator
  let appleMessages: MessagesCoordinator
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
    replaceSelection: @escaping @MainActor (String, UUID) async -> Bool = { await SelectionContextService.shared.replace(with: $0, contextID: $1) },
    files: FileModeCoordinator? = nil,
    appleMessages: MessagesCoordinator? = nil,
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
    sleep: @escaping Sleep = { duration in try await Task.sleep(for: duration) }
  ) {
    self.selectionEditingSettings = selectionEditingSettings
    self.replaceSelection = replaceSelection
    self.engine = engine
    self.files = files ?? FileModeCoordinator()
    self.appleMessages = appleMessages ?? MessagesCoordinator()
    makeMessagesToolbox = messagesToolbox ?? { confirm in MessagesTools(confirmSend: confirm) }
    self.messagesAccess = messagesAccess ?? { try MessagesDatabase().checkAccess() }
    self.localToolRuntime = localToolRuntime ?? { LocalFileRuntime.executable(for: $0) != nil }
    self.fileInference = fileInference ?? (visionEngine as? any LocalToolInference) ?? LlamaServerVisionEngine()
    self.fileCodex = fileCodex
    self.fileCloudAvailability = fileCloudAvailability ?? {
      if await ScreenConnectivity.shared.isOffline { return .unavailable(reason: "This Mac is offline.") }
      guard CodexRuntimeConfiguration.executableURL() != nil else { return .unavailable(reason: "Codex is not installed.") }
      return await fileCodex.fileEditingAvailability(preferredModelID: CloudPreferencesStore().preferredModel(for: .chatGPT))
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
    sessions = sessionStore.load()
    selectedSessionID = sessions.first?.id
    self.files.restoreSelection(selectedSession?.workspace)
    self.files.conversationID = selectedSessionID
    self.files.onSelectionChange = { [weak self] selection in
      guard let self else { return }
      let sessionID = self.ensureSelectedSession()
      self.files.conversationID = sessionID
      guard let index = self.sessions.firstIndex(where: { $0.id == sessionID }) else { return }
      self.sessions[index].workspace = selection
      self.persistSessions()
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

  func installModel(from sourceURL: URL, vision: LocalVisionConfiguration? = nil) {
    guard !isBusy else { return }
    stopStreaming()
    installationTask?.cancel()
    cancelIdleUnload()
    state = .installing
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

  func downloadModel(_ descriptor: LocalModelDescriptor) {
    guard !isBusy else { return }
    stopStreaming()
    installationTask?.cancel()
    cancelIdleUnload()
    state = .downloading(ModelDownloadProgress(receivedByteCount: 0, expectedByteCount: descriptor.downloadByteCount))
    installationTask = Task { [weak self, engine] in
      do {
        let prediction = try await self?.modelAdvisor?.confirmDownload(descriptor, installedModels: self?.installedModels ?? [])
        try Task.checkCancellation()
        await self?.visionEngine.unload()
        _ = try await engine.download(descriptor) { [weak self] progress in
          await self?.updateDownloadProgress(progress)
        }
        guard let self else { return }
        await self.refreshInstalledModel()
        try Task.checkCancellation()
        if prediction?.permitsMemoryOverride == true {
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
    guard !isBusy, let installedModel else { return }
    cancelIdleUnload()
    state = .benchmarking
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
    state = .benchmarking
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
    guard !isBusy else { return }
    cancelIdleUnload()
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
        self?.state = .failed(error.localizedDescription)
        self?.scheduleIdleUnload()
      }
    }
  }

  func deleteModel(id: String) {
    guard !isBusy, installedModels.contains(where: { $0.id == id }) else { return }
    stopStreaming()
    cancelIdleUnload()
    benchmarkNotice = nil
    state = .deleting
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
    let level: FileAccessLevel = SelectionResponseMode(prompt: prompt) == .translate ? .readOnly
      : local ? model.map { LocalFileCapabilities.production.access(for: $0) } ?? .readOnly : .readWrite
    let fileTools: AgentFileTools
    do { fileTools = try files.begin(access: level, isLocal: local, prompt: prompt, cloudAvailability: fileCloudAvailability) }
    catch { files.error = error.localizedDescription; return }
    let route = Route(mode: local ? .local : .cloud,
      providerID: local ? "llama.cpp" : CloudProviderID.chatGPT.rawValue,
      modelID: local ? model!.id : cloudModelID, usesNetwork: !local)
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
      await self?.finishGeneration(id: active.id, error: failure)
    }
    messagesFollowUpSessionID = sessionID
    onAccepted()
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
          let results = try await owner.search(trimmedPrompt, maximumTokens: BraveSearchClient.evidenceTokens, requestID: active.id)
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
                    ScreenSearchContext.queryPrompt(question: prompt, facts: "", ocr: attachment.ocrText))]
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
                searchResults = try await owner.search(searchQuery ?? prompt, locationPrompt: prompt, maximumTokens: BraveSearchClient.evidenceTokens, requestID: active.id)
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
        let results = try await owner.search(userMessage.content, maximumTokens: BraveSearchClient.evidenceTokens, requestID: active.id)
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
    let searchEnabled = shouldSearch(prompt, explicitlyEnabled: searchEnabled, allowsAutomaticSearch: allowsAutomaticSearch)
    let decision = (searchEnabled || AutoRouter.shouldRun(for: .auto, cloud: cloud))
      ? AutoRouter.decide(AutoRouter.Request(
        selectedMode: .auto, webSearchEnabled: searchEnabled,
        prompt: ConversationContextPrompt.expand(contextualMessage(prompt, responseInstructions: false)).content,
        webSearchPrompt: prompt, contextMessages: autoRoutingContextMessages,
        localModel: installedModel, cloud: cloud
      ))
      : AutoRouter.localFallback(localModel: installedModel)
    autoRouteDecision = decision
    guard let route = decision.route else { return }
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

  /// The returned consumer task can be awaited to observe its shutdown.
  @discardableResult
  func stopStreaming() -> Task<Void, Never>? {
    guard let task = generationTask else { return nil }
    files.revoke()
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

  func newChat() {
    stopStreaming()
    discardTemporaryChat()
    SelectionContextService.shared.discardTarget()
    files.restoreSelection(nil)
    contextNotice = nil
    autoRouteDecision = nil
    screenRouteDecision = nil
    let session = ChatSession()
    sessions.append(session)
    selectedSessionID = session.id
    messagesFollowUpSessionID = nil
    files.conversationID = session.id
    sortAndPersistSessions()
    if case .failed = state { state = .idle }
  }

  func selectSession(id: UUID) {
    guard sessions.contains(where: { $0.id == id }), !isBusy else { return }
    if id != selectionSessionID { discardTemporaryChat(); SelectionContextService.shared.discardTarget() }
    if id != selectedSessionID { messagesFollowUpSessionID = nil }
    selectedSessionID = id
    files.restoreSelection(selectedSession?.workspace)
    files.conversationID = selectedSessionID
    contextNotice = nil
  }

  func cycleRecentChat() {
    guard !isBusy, !sessions.isEmpty else { return }
    contextNotice = nil
    let selectedIndex = selectedSessionID.flatMap { id in sessions.firstIndex(where: { $0.id == id }) }
    let nextID = sessions[selectedIndex.map { ($0 + 1) % sessions.count } ?? 0].id
    if nextID != selectionSessionID { discardTemporaryChat(); SelectionContextService.shared.discardTarget() }
    if nextID != selectedSessionID { messagesFollowUpSessionID = nil }
    selectedSessionID = nextID
    files.restoreSelection(selectedSession?.workspace)
    files.conversationID = selectedSessionID
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
    guard idleUnloadTask == nil, activeRequest == nil, generationTask == nil, installationTask == nil else { return }
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
        guard self.activeRequest == nil, self.generationTask == nil, self.installationTask == nil else { return }
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
    let session = ChatSession()
    sessions.append(session)
    selectedSessionID = session.id
    persistSessions()
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

  private func sortAndPersistSessions() {
    sessions.sort { $0.lastActivityAt > $1.lastActivityAt }
    let retained = Set(sessions.filter { $0.id != temporarySessionID }
      .prefix(ChatSessionStore.maximumRetainedSessions).map(\.id))
    sessions.removeAll { $0.id != temporarySessionID && !retained.contains($0.id) }
    persistSessions()
  }

  private func persistSessions(immediately: Bool = true) {
    guard !isTemporaryChat else { return }
    sessionWriter.schedule(immediately: immediately) { [weak self] in
      guard let self else { return nil }
      return self.sessions.filter { $0.id != self.temporarySessionID }
    }
  }

  private func finishInstallation() {
    state = .idle
    installationTask = nil
    scheduleIdleUnload()
  }

  private func updateDownloadProgress(_ progress: ModelDownloadProgress) {
    guard !Task.isCancelled else { return }
    state = .downloading(progress)
  }

  private func failInstallation(_ error: Error) {
    if Task.isCancelled { finishInstallation(); return }
    state = .failed(error.localizedDescription)
    installationTask = nil
    scheduleIdleUnload()
  }

  private func search(_ query: String, locationPrompt: String? = nil, maximumTokens: Int, requestID: UUID) async throws -> [WebSearchResult] {
    receiveActivity(.phase(.searching), requestID: requestID)
    var contextualQuery = query
    // Only the source material this request carries refines its query.
    let source = requestSource
    if !source.contexts.isEmpty || source.draft != nil, let active = activeRequest, active.id == requestID {
      state = .refiningSearch
      receiveActivity(.phase(.refiningSearch), requestID: requestID)
      var message = ChatMessage(role: .user, content:
        "Create one concise web search query that helps answer the user's question about the attached context. "
        + "Return only the query, without quotes or commentary. Question: " + query)
      var contexts = source.contexts
      if let draft = source.draft {
        contexts.append(ConversationContext(sourceName: "Proposed revision", text: draft))
      }
      message.contexts = contexts
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
      contextualQuery = try ScreenSearchContext.query(from:
        await ScreenSearchContext.collect(stream, maximumBytes: 1_024))
      try Task.checkCancellation()
      guard activeRequest?.id == requestID else { throw CancellationError() }
      state = .searching
      receiveActivity(.phase(.searching), requestID: requestID)
    }
    if LocationIntent.needsLocation(locationPrompt ?? query), let locationProvider {
      let location = try await locationProvider.currentLocation()
      try Task.checkCancellation()
      guard activeRequest?.id == requestID else { throw CancellationError() }
      requestLocationContext = location.searchContext
      contextualQuery += "\n" + location.searchContext
    }
    let results = try await webSearch.search(contextualQuery, maximumTokens: maximumTokens) { [weak self] event in
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
    // The note that a chat opened in the window is saved, or private, is said once.
    openedSelectionChat = nil
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
    defer { isApplyingSelection = false }
    let sent = await replaceSelection(revision.text, revision.contextID)
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

  private func finishGeneration(id: UUID, error: Error? = nil) async {
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
    state = error.map { .failed($0.localizedDescription) } ?? .idle
    sessionWriter.flush()
    scheduleIdleUnload()
  }
}
