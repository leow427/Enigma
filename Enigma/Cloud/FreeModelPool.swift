import Foundation

extension Notification.Name {
  /// Posted with the new model ID when the free pool switches models for a daily limit (F34).
  static let freeModelSwitched = Notification.Name("FreeModelPool.switched")
}

/// The Free models provider (F34): runs the chosen free model and, when one runs out before its
/// reply starts, retries the same request on the next ranked model.
struct FreeModelPool: ChatProvider, ToolCallingChatProvider {
  let gemini: any ChatProvider
  let apple: (any ChatProvider)?
  var usage: FreeModelUsage = .shared
  /// The free model IDs set up on this Mac, most capable first.
  let models: @Sendable () -> [String]
  let allowsGeminiInAuto: @Sendable () -> Bool
  let onSwitch: @Sendable (String) -> Void
  var now: @Sendable () -> Date = Date.init

  /// The pool the app uses: models from the saved Gemini key, the Auto toggle from preferences,
  /// and switches announced to `CloudSettingsModel`.
  static func live(gemini: any ChatProvider, credentialStore: any CloudCredentialStore) -> FreeModelPool {
    FreeModelPool(
      gemini: gemini, apple: nil,
      models: {
        let hasKey = (try? credentialStore.containsAPIKey(for: .gemini)) ?? false
        return FreeModelCatalog.available(hasGeminiKey: hasKey, appleAvailable: false).map(\.id)
      },
      allowsGeminiInAuto: { CloudPreferencesStore().autoMayUseFreeGemini() },
      onSwitch: { NotificationCenter.default.post(name: .freeModelSwitched, object: $0) })
  }

  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    run(request) { provider, request in provider.stream(request) }
  }

  func stream(_ request: ChatRequest, toolbox: any AgentToolbox) -> AsyncThrowingStream<ChatEvent, Error> {
    run(request) { provider, request in
      guard let tools = provider as? any ToolCallingChatProvider else {
        return AsyncThrowingStream { $0.finish(throwing: CloudProviderError.invalidResponse) }
      }
      return tools.stream(request, toolbox: toolbox)
    }
  }

  private func run(
    _ request: ChatRequest,
    start: @escaping @Sendable (any ChatProvider, ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>
  ) -> AsyncThrowingStream<ChatEvent, Error> {
    CloudToolLoop.stream { continuation in
      let chosen = request.route.modelID
      let available = models().filter { id in
        !request.route.isAuto || FreeModelCatalog.underlyingProvider(id) == nil || allowsGeminiInAuto()
      }
      guard !available.isEmpty else { throw CloudProviderError.missingAPIKey(.gemini) }
      // A choice that isn't set up never reaches here from Settings; Auto's pick may be left out.
      let order = (available.contains(chosen) ? [chosen] : []) + available.filter { $0 != chosen }
      // The model the user chose and why the pool left it, for the notice.
      var left: (model: String, daily: Bool)?
      for id in order {
        try Task.checkCancellation()
        if usage.isExhausted(id, now: now()) {
          left = left ?? (id, true)
          continue
        }
        guard let provider = FreeModelCatalog.underlyingProvider(id) == nil ? apple : gemini else { continue }
        let route = FreeModelCatalog.underlyingProvider(id).map {
          Route(mode: request.route.mode, providerID: $0.rawValue, modelID: id, usesNetwork: request.route.usesNetwork)
        } ?? Route(mode: request.route.mode, providerID: CloudProviderID.free.rawValue, modelID: id,
                   usesNetwork: request.route.usesNetwork)
        let attempt = ChatRequest(sessionID: request.sessionID, messages: request.messages, route: route,
                              image: request.image, allowsCloudImages: request.allowsCloudImages,
                              providerSearch: request.providerSearch)
        if let left { continuation.yield(.activity(.notice(notice(switchedTo: id, left: left)))) }
        if id != chosen { continuation.yield(.activity(.answeredBy(FreeModelCatalog.displayName(id)))) }
        var started = false
        do {
          for try await event in start(provider, attempt) {
            // A daily limit moves the user's choice; a busy model, or Auto's pick, only this request.
            if !started, left?.daily == true, !request.route.isAuto { onSwitch(id) }
            started = true
            continuation.yield(event)
          }
          return
        } catch let error as CloudProviderError where !started {
          switch error {
          case .quotaExhausted(_, let resetsAt):
            usage.markExhausted(id, until: resetsAt, now: now())
            left = left ?? (id, true)
          case .rateLimited:
            left = left ?? (id, false)
          default:
            throw error
          }
        }
      }
      throw CloudProviderError.quotaExhausted(.free, resetsAt: usage.earliestReset(among: available, now: now()))
    }
  }

  private func notice(switchedTo id: String, left: (model: String, daily: Bool)) -> String {
    let next = FreeModelCatalog.displayName(id), previous = FreeModelCatalog.displayName(left.model)
    guard left.daily else { return "Answered with \(next): \(previous) is busy right now." }
    let reset = usage.resetTime(left.model).map { " (resets \($0.formatted(date: .omitted, time: .shortened)))" } ?? ""
    return "Switched to \(next): \(previous) reached its free daily limit\(reset)."
  }
}
