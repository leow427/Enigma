import CoreML
import Foundation
import NaturalLanguage
import os
import Synchronization

/// What the training script recorded in a model's metadata.
struct IntentModelInfo: Equatable, Sendable {
  let cutoff: Double
  let kind: String              // "maxEnt" or "bert"
  let trainingFingerprint: String
  let asOf: String
}

extension IntentModelInfo {
  /// Nil unless every key the training script writes is there and the cut-off is a number from 0 to 1.
  init?(metadata: [String: String]) {
    guard let cutoff = metadata["enigma.cutoff"].flatMap(Double.init), (0...1).contains(cutoff),
          let kind = metadata["enigma.kind"],
          let fingerprint = metadata["enigma.fingerprint"], let asOf = metadata["enigma.asOf"] else { return nil }
    self.init(cutoff: cutoff, kind: kind, trainingFingerprint: fingerprint, asOf: asOf)
  }
}

/// The bundled intent models, one per skill. Each loads lazily, once, and answers
/// with the skill's pins first, then the model at its cut-off. It knows nothing
/// about chips, routing or privacy: callers run their rules before asking.
final class IntentModels: Sendable {
  static let shared = IntentModels(bundle: .main)

  private let modelURL: @Sendable (String) -> URL?
  private let pins: IntentPins
  /// One lock per skill, so a slow load or prediction for one skill never holds up another.
  private let slots: [IntentSkill: Slot] = Dictionary(uniqueKeysWithValues: IntentSkill.allCases.map { ($0, Slot()) })

  private final class Slot: Sendable {
    let state = Mutex(State())
  }

  private struct State {
    var loaded: Loaded?
    var loadAttempts = 0
  }

  private enum Loaded {
    case ready(NLModel, IntentModelInfo)
    case unavailable
  }

  /// Looks up `<modelName>.mlmodelc` in the bundle.
  init(bundle: Bundle, pins: IntentPins = .shipped) {
    modelURL = { bundle.url(forResource: $0, withExtension: "mlmodelc") }
    self.pins = pins
  }

  /// Looks up `<modelName>.mlmodelc` in a folder of compiled models (tests).
  init(compiledModelsIn directory: URL, pins: IntentPins = .shipped) {
    modelURL = { name in
      let url = directory.appending(path: "\(name).mlmodelc")
      return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    self.pins = pins
  }

  func info(_ skill: IntentSkill) -> IntentModelInfo? {
    withModel(skill) { _, info in info }
  }

  func probabilities(_ skill: IntentSkill, for modelInput: String) -> [String: Double]? {
    withModel(skill) { model, _ in
      let hypotheses = model.predictedLabelHypotheses(for: modelInput, maximumCount: skill.labels.count)
      return hypotheses.isEmpty ? nil : hypotheses
    } ?? nil
  }

  /// Empty text: the negative label, without loading a model. Otherwise the
  /// pins, then the model at its cut-off. A missing or damaged model gives
  /// the negative label and logs the skill's name once. A draft the model has
  /// no opinion on (every label equally likely) gives the negative label too.
  func answer(_ skill: IntentSkill, cleaned: String, now: Date = Date()) -> String {
    guard !cleaned.isEmpty else { return skill.negativeLabel }
    if let pinned = pins.answer(skill, cleaned: cleaned) { return pinned }
    let input = IntentText.modelInput(cleaned, now: now)
    let answer = withModel(skill) { model, info -> String? in
      Self.answer(skill, hypotheses: model.predictedLabelHypotheses(for: input, maximumCount: skill.labels.count),
                  cutoff: info.cutoff)
    } ?? nil
    return answer ?? skill.negativeLabel
  }

  /// The skill's answer for a prediction, or nil when there's none to give: no hypotheses, or every
  /// label equally likely. A model that knows no word of the draft ("👍", another language) gives
  /// that tie, and it's no opinion at all, not a yes at a cut-off of 0.5.
  static func answer(_ skill: IntentSkill, hypotheses: [String: Double], cutoff: Double) -> String? {
    guard let high = hypotheses.values.max(), let low = hypotheses.values.min(), high - low > 1e-9 else { return nil }
    return skill.answer(probabilities: hypotheses, cutoff: cutoff)
  }

  /// How many times the skill's model has been loaded; at most once (tests).
  func loadAttempts(_ skill: IntentSkill) -> Int {
    slots[skill]!.state.withLock { $0.loadAttempts }
  }

  /// Runs `body` with the skill's model under the skill's lock, loading it the first time.
  /// NLModel isn't documented as thread-safe, so predictions stay under the lock too.
  private func withModel<T: Sendable>(_ skill: IntentSkill, _ body: (NLModel, IntentModelInfo) -> T) -> T? {
    let (result, failedToLoad) = slots[skill]!.state.withLock { state -> (T?, Bool) in
      var failedToLoad = false
      if state.loaded == nil {
        state.loadAttempts += 1
        let loaded = load(skill)
        if case .unavailable = loaded { failedToLoad = true }
        state.loaded = loaded
      }
      guard case .ready(let model, let info) = state.loaded else { return (nil, failedToLoad) }
      return (body(model, info), failedToLoad)
    }
    if failedToLoad {
      Self.logger.error("Intent model unavailable: \(skill.rawValue, privacy: .public)")
    }
    return result
  }

  private func load(_ skill: IntentSkill) -> Loaded {
    guard let url = modelURL(skill.modelName),
          let mlModel = try? MLModel(contentsOf: url),
          let metadata = mlModel.modelDescription.metadata[.creatorDefinedKey] as? [String: String],
          let info = IntentModelInfo(metadata: metadata),
          let model = try? NLModel(mlModel: mlModel) else {
      return .unavailable
    }
    return .ready(model, info)
  }

  private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Enigma", category: "IntentModels")
}
