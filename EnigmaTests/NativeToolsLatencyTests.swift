import XCTest
@testable import Enigma

/// F32 CP5's latency gate. Opt-in, with the same `TEST_RUNNER_ENIGMA_F32_EVAL` and
/// `TEST_RUNNER_ENIGMA_F32_REPORT` as the eval. Time to first answer text on a plain question,
/// without and with the tool descriptions a flagged turn carries (web search and Messages).
///
/// Local: one warm `llama-server`. Each condition runs as its own block, one unmeasured request and
/// then five different plain questions (the first is "What is the capital of Australia?"), since
/// with the prompt cache on, the same question again would come back almost entirely from the cache
/// and measure nothing. Conditions: today's plain turn (cache off, no tools), `streamTools` without
/// tools and with them (cache on, as flagged turns send). The gate compares the last two. Three cold
/// conditions stop the server before each of three questions, so their times include loading the
/// model: today's plain turn, a flagged turn, and a flagged turn after `warmTools`.
///
/// Cloud: today's plain client against the flagged turn's tool loop, alternating, one unmeasured
/// pair first. The gate compares the two.
@MainActor
final class NativeToolsLatencyTests: XCTestCase {
  static let questions = ["How many legs does a spider have?", "What is the capital of Australia?",
                          "What is the boiling point of water in Fahrenheit?", "Who wrote Pride and Prejudice?",
                          "What is the largest planet in the solar system?", "What colour do you get mixing blue and yellow?"]
  static let gate = 1.15

  struct Condition: Codable {
    let name: String
    /// The unmeasured first request: on a local server, the first to read this condition's prompt.
    let firstRequest: Double?
    let runs: [Double?]
    let median: Double?
  }

  struct Report: Codable {
    let route: String
    let date: Date
    let conditions: [Condition]
    /// With tools over without: on the same server for local routes, flagged over today for cloud.
    let ratio: Double?
    let passes: Bool
    let toolCalls: [String]
  }

  func testFirstToken() async throws {
    let run = try NativeToolsEval.Run.fromEnvironment()
    let messages = try NativeToolsEval.MessagesWorld()
    let suite = "NativeToolsLatency-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let coordinator = ToolPermissionCoordinator(store: ToolGrantStore(defaults: defaults))
    let destination = try XCTUnwrap(ToolDestination(route: run.route))
    let log = NativeToolsEval.CallLog()
    let toolbox = NativeToolsEval.RecordingToolbox(base: NativeToolsEval.toolbox(searchResult: nil, selection: false,
      messages: messages, coordinator: coordinator, destination: destination, session: UUID()), log: log)

    let conditions: [Condition]
    switch run.target {
    case .local(let model):
      let engine = LlamaServerVisionEngine()
      let toolSystem = ChatResponseStyle.instructions + "\n" + toolbox.instructions + "\n" + LocalToolAgent.localInstructions
      func block(_ name: String, _ first: @escaping (String) async throws -> Double?) async throws -> Condition {
        let firstRequest = try await first(Self.questions[0])
        var runs: [Double?] = []
        for question in Self.questions.dropFirst() { runs.append(try await first(question)) }
        return Condition(name: name, firstRequest: firstRequest, runs: runs, median: median(runs))
      }
      // The answer is read to the end each time: a plain turn stopped early unloads the server.
      let today = try await block("today: plain turn, cache off, no tools") { question in
        let prepared = try await engine.prepare(messages: [ChatMessage(role: .user, content: question)], image: nil, model: model)
        return try await firstText(engine.stream(messages: prepared.messages, image: nil, model: model))
      }
      func streamed(system: String, tools: [AgentToolDefinition]) -> (String) async throws -> Double? {
        { question in
          let start = ContinuousClock.now
          var first: Double?
          for try await event in engine.streamTools(messages: [AgentInferenceMessage(role: "system", content: system),
            AgentInferenceMessage(role: "user", content: question)], tools: tools, model: model, requiredTool: nil) {
            switch event {
            case .text: if first == nil { first = start.duration(to: .now).evalSeconds }
            case .message(let message):
              if let name = message.toolCalls?.first?.function.name { log.append(.init(name: name, arguments: "")) }
            }
          }
          return first
        }
      }
      let without = try await block("streamTools without tools, cache on",
                                    streamed(system: ChatResponseStyle.instructions, tools: []))
      let with = try await block("streamTools with \(toolbox.definitions.count) tools, cache on",
                                 streamed(system: toolSystem, tools: toolbox.definitions))
      // After a pause the server has stopped. Each run stops it first, so its time includes
      // loading the model: today's plain turn, a flagged turn, and a flagged turn the user's
      // typing warmed first (the warm-up's own time is reported beside it).
      func cold(_ name: String, _ first: @escaping (String) async throws -> Double?) async throws -> Condition {
        var runs: [Double?] = []
        for question in Self.questions.prefix(3) {
          await engine.unload()
          runs.append(try await first(question))
        }
        return Condition(name: name, firstRequest: nil, runs: runs, median: median(runs))
      }
      let todayCold = try await cold("cold: today's plain turn, loading the model") { question in
        let start = ContinuousClock.now
        let prepared = try await engine.prepare(messages: [ChatMessage(role: .user, content: question)], image: nil, model: model)
        let loaded = start.duration(to: .now).evalSeconds
        return try await firstText(engine.stream(messages: prepared.messages, image: nil, model: model)).map { loaded + $0 }
      }
      let flaggedCold = try await cold("cold: flagged turn, loading the model",
                                       streamed(system: toolSystem, tools: toolbox.definitions))
      var warmUps: [Double?] = []
      let warmedCold = try await cold("cold: flagged turn after a warm-up while typing") { question in
        let start = ContinuousClock.now
        await engine.warmTools(messages: [AgentInferenceMessage(role: "system", content: toolSystem),
                                          AgentInferenceMessage(role: "user", content: "")],
                               tools: toolbox.definitions, model: model)
        warmUps.append(start.duration(to: .now).evalSeconds)
        return try await streamed(system: toolSystem, tools: toolbox.definitions)(question)
      }
      let warmUp = Condition(name: "the warm-up itself: loading and reading the tools", firstRequest: nil,
                             runs: warmUps, median: median(warmUps))
      await engine.unload()
      conditions = [today, todayCold, flaggedCold, warmUp, warmedCold, without, with]
    case .cloud(let provider, _):
      let plain = run.providers.provider(for: provider)
      let tools = try run.toolProvider()
      var plainRuns: [Double?] = [], toolRuns: [Double?] = []
      var firstPlain: Double?, firstTools: Double?
      for (index, question) in Self.questions.enumerated() {
        let request = ChatRequest(sessionID: UUID(), messages: [ChatMessage(role: .user, content: question)], route: run.route)
        let plainTime = try await firstText(plain.stream(request))
        let toolTime = try await firstText(tools.stream(request, toolbox: toolbox))
        if index == 0 {
          firstPlain = plainTime
          firstTools = toolTime
        } else {
          plainRuns.append(plainTime)
          toolRuns.append(toolTime)
        }
      }
      conditions = [Condition(name: "today: plain client", firstRequest: firstPlain, runs: plainRuns, median: median(plainRuns)),
                    Condition(name: "flagged: tool loop with \(toolbox.definitions.count) tools", firstRequest: firstTools,
                              runs: toolRuns, median: median(toolRuns))]
    }
    let base = conditions[conditions.count - 2].median, flagged = conditions[conditions.count - 1].median
    let ratio = base.flatMap { base in flagged.map { $0 / base } }
    let report = Report(route: run.label, date: Date(), conditions: conditions, ratio: ratio,
                        passes: ratio.map { $0 <= Self.gate } ?? false, toolCalls: log.calls.map(\.name))
    try run.write(report, to: "latency.json")
    print("F32 latency \(run.label): ratio \(ratio.map { String(format: "%.2f", $0) } ?? "-") (gate ≤ \(Self.gate))")
  }
}

// MARK: - Helpers

/// Seconds to the first non-empty text, reading the stream to its end.
private func firstText(_ stream: AsyncThrowingStream<String, Error>) async throws -> Double? {
  let start = ContinuousClock.now
  var first: Double?
  for try await text in stream where first == nil && !text.isEmpty { first = start.duration(to: .now).evalSeconds }
  return first
}

private func firstText(_ stream: AsyncThrowingStream<ChatEvent, Error>) async throws -> Double? {
  let start = ContinuousClock.now
  var first: Double?
  for try await event in stream {
    if case .token(let text) = event, first == nil, !text.isEmpty { first = start.duration(to: .now).evalSeconds }
  }
  return first
}

private func median(_ values: [Double?]) -> Double? {
  let sorted = values.compactMap { $0 }.sorted()
  guard !sorted.isEmpty else { return nil }
  return sorted.count.isMultiple(of: 2) ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2 : sorted[sorted.count / 2]
}
