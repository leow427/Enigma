import CoreML
import CreateML
import Foundation
import NaturalLanguage
import TabularData

// Trains Enigma's intent models. Run through scripts/train-intent-models.sh, which compiles
// this file with IntentTrainingSupport.swift, IntentText.swift and IntentSkill.swift, so the
// models see text cleaned exactly as the app cleans it.

@main
struct IntentTrainer {
  static let chipBudgetMilliseconds = 5.0
  static let sendBudgetMilliseconds = 20.0
  static let timedPredictions = 1_000

  enum Kind: String, CaseIterable { case maxEnt, bert }

  static let appModels = URL(fileURLWithPath: "Enigma/Resources/IntentModels")
  static let appExamples = URL(fileURLWithPath: "IntentTraining")

  struct Options {
    var data = appExamples
    var out = appModels
    var dataGiven = false
    var outGiven = false
    var check = false
    var kind: Kind?
    var skills: [IntentSkill] = []
  }

  struct Config: Decodable { let allowsBERT: Bool }

  struct Report: Encodable {
    let kind: String
    let cutoff: Double
    let validation: IntentScore
    let p95Milliseconds: Double
    let fingerprint: String
    let trainingCount: Int
    let validationCount: Int
  }

  /// A trained model waiting to be written once every skill in the run passes.
  struct Trained {
    let skill: IntentSkill
    let classifier: MLTextClassifier
    let report: Report
    let asOf: String
  }

  struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
  }

  /// Holds the run's compiled models; removed when the run ends, however it ends.
  static let workFolder = FileManager.default.temporaryDirectory.appending(path: "IntentTrainer-\(UUID().uuidString)")

  static func main() {
    do {
      try run(parse(Array(CommandLine.arguments.dropFirst())))
      try? FileManager.default.removeItem(at: workFolder)
    } catch {
      try? FileManager.default.removeItem(at: workFolder)
      FileHandle.standardError.write(Data("train-intent-models: \(error)\n".utf8))
      exit(1)
    }
  }

  static func parse(_ arguments: [String]) throws -> Options {
    var options = Options()
    var remaining = arguments[...]
    while let argument = remaining.popFirst() {
      switch argument {
      case "--data", "--out", "--kind":
        guard let value = remaining.popFirst() else { throw Failure("\(argument) needs a value") }
        if argument == "--data" { options.data = URL(fileURLWithPath: value); options.dataGiven = true }
        if argument == "--out" { options.out = URL(fileURLWithPath: value); options.outGiven = true }
        if argument == "--kind" {
          guard let kind = Kind(rawValue: value) else { throw Failure("--kind is maxEnt or bert") }
          options.kind = kind
        }
      case "--check":
        options.check = true
      default:
        guard let skill = IntentSkill(rawValue: argument) else { throw Failure("unknown skill or option \(argument)") }
        options.skills.append(skill)
      }
    }
    guard !options.skills.isEmpty else {
      throw Failure("usage: train-intent-models.sh [--data <dir>] [--out <dir>] [--check] [--kind maxEnt|bert] <skill>...")
    }
    // A forced type skips the BERT gate and the speed limits, so it must never reach the app's
    // models or overwrite the real reports.
    if options.kind != nil && !options.check {
      guard options.dataGiven, options.outGiven, !samePlace(options.out, appModels),
            !samePlace(options.data, appExamples) else {
        throw Failure("--kind is for fixtures and probes: give --data and --out other than "
          + "\(appExamples.relativePath) and \(appModels.relativePath)")
      }
    }
    return options
  }

  /// Whether two folder paths name the same place, however they're spelled: symlinks
  /// such as /tmp → /private/tmp are resolved, and APFS ignores case.
  static func samePlace(_ first: URL, _ second: URL) -> Bool {
    canonicalPath(first) == canonicalPath(second)
  }

  /// `realpath` of the deepest folder that exists, with the rest of the path appended, lowercased.
  static func canonicalPath(_ url: URL) -> String {
    var existing = url.standardizedFileURL
    var rest: [String] = []
    while existing.path != "/", realpath(existing.path, nil) == nil {
      rest.insert(existing.lastPathComponent, at: 0)
      existing.deleteLastPathComponent()
    }
    let resolved = realpath(existing.path, nil).map { pointer in
      defer { free(pointer) }
      return String(cString: pointer)
    } ?? existing.path
    return ([resolved] + rest).joined(separator: "/").lowercased()
  }

  static func run(_ options: Options) throws {
    let config = try JSONDecoder().decode(Config.self,
      from: Data(contentsOf: URL(fileURLWithPath: "IntentTraining/config.json")))
    let kinds = options.kind.map { [$0] } ?? (config.allowsBERT ? Kind.allCases : [.maxEnt])

    var trained: [Trained] = []
    for skill in options.skills {
      let folder = options.data.appending(path: skill.rawValue)
      let trainData = try Data(contentsOf: folder.appending(path: "train.jsonl"))
      let training = try parseFile(trainData, skill: skill, name: "\(skill.rawValue)/train.jsonl")
      for other in ["test.jsonl", "must-pass.jsonl"] {
        guard let data = try? Data(contentsOf: folder.appending(path: other)) else { continue }
        let file = try parseFile(data, skill: skill, name: "\(skill.rawValue)/\(other)")
        let overlaps = IntentTrainingSupport.overlaps(training.examples, file.examples)
        guard overlaps.isEmpty else {
          throw Failure("\(skill.rawValue): train.jsonl overlaps \(other): \(overlaps.joined(separator: " | "))")
        }
      }
      if options.check {
        print("\(skill.rawValue): \(training.examples.count) training examples, no overlaps")
        continue
      }
      trained.append(try train(skill, training: training, fingerprint: IntentTrainingSupport.fingerprint(trainData),
                               kinds: kinds, enforced: options.kind == nil))
    }
    guard !options.check else { return }

    // A forced type is for fixtures and probes, never the app's models: its speed is reported, not enforced.
    try checkChipBudget(trained, out: options.out, enforced: options.kind == nil)

    try FileManager.default.createDirectory(at: options.out, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    for model in trained {
      let metadata = MLModelMetadata(author: "Enigma", shortDescription: "Recognizes the \(model.skill.rawValue) intent.",
        version: "1", additional: [
          "enigma.cutoff": String(format: "%.2f", model.report.cutoff),
          "enigma.kind": model.report.kind,
          "enigma.fingerprint": model.report.fingerprint,
          "enigma.asOf": model.asOf,
        ])
      let destination = options.out.appending(path: "\(model.skill.modelName).mlmodel")
      try? FileManager.default.removeItem(at: destination)
      try model.classifier.write(to: destination, metadata: metadata)
      try (encoder.encode(model.report) + Data("\n".utf8))
        .write(to: options.data.appending(path: model.skill.rawValue).appending(path: "report.json"))
      print("wrote \(destination.path)")
    }
  }

  static func parseFile(_ data: Data, skill: IntentSkill, name: String) throws -> IntentExampleFile {
    do {
      return try IntentExampleFile.parse(data, skill: skill)
    } catch {
      throw Failure("\(name): \(error)")
    }
  }

  /// Trains each type and keeps the one with the best validation accuracy among those
  /// within the skill's own speed limit (spec §3); ties go to maxEnt, which `kinds` lists first.
  static func train(_ skill: IntentSkill, training: IntentExampleFile, fingerprint: String,
                    kinds: [Kind], enforced: Bool) throws -> Trained {
    let input = { (text: String) in IntentText.modelInput(IntentText.clean(text), now: training.asOf) }
    let validation = training.examples.filter { IntentTrainingSupport.isValidation($0.text) }
    let fitting = training.examples.filter { !IntentTrainingSupport.isValidation($0.text) }
    var frame = DataFrame()
    frame.append(column: Column(name: "text", contents: fitting.map { input($0.text) }))
    frame.append(column: Column(name: "label", contents: fitting.map(\.label)))

    let drafts = training.examples.map { input($0.text) }
    let limit = skill.isChip ? chipBudgetMilliseconds : sendBudgetMilliseconds
    var best: (kind: Kind, classifier: MLTextClassifier, cutoff: Double, score: IntentScore, p95: Double)?
    for kind in kinds {
      let algorithm: MLTextClassifier.ModelAlgorithmType = switch kind {
      case .maxEnt: .maxEnt(revision: nil)
      case .bert: .transferLearning(.bertEmbedding, revision: nil)
      }
      let classifier = try MLTextClassifier(trainingData: frame, textColumn: "text", labelColumn: "label",
        parameters: .init(validation: .none, algorithm: algorithm, language: .english))
      let model = try compiled(classifier)
      let predictions = validation.map {
        (expected: $0.label, probabilities: model.predictedLabelHypotheses(for: input($0.text), maximumCount: skill.labels.count))
      }
      guard let cutoff = IntentTrainingSupport.chooseCutoff(for: skill, validation: predictions) else {
        print("\(skill.rawValue) \(kind.rawValue): no cut-off qualifies")
        continue
      }
      let answers = predictions.map { (expected: $0.expected, actual: skill.answer(probabilities: $0.probabilities, cutoff: cutoff)) }
      let score = IntentScore(answers: answers, negativeLabel: skill.negativeLabel)
      let p95 = p95Milliseconds(model, drafts: drafts)
      print("\(skill.rawValue) \(kind.rawValue): cut-off \(String(format: "%.2f", cutoff)), validation accuracy "
        + "\(String(format: "%.3f", score.accuracy)), wrong yeses \(String(format: "%.3f", score.wrongYesShare)), "
        + "p95 \(String(format: "%.3f", p95)) ms")
      if enforced && p95 > limit {
        print("\(skill.rawValue) \(kind.rawValue): over its \(limit) ms limit, not kept")
        continue
      }
      if best == nil || score.accuracy > best!.score.accuracy {
        best = (kind, classifier, cutoff, score, p95)
      }
    }
    guard let best else {
      throw Failure("\(skill.rawValue): no model type has a qualifying cut-off within \(limit) ms")
    }

    print("\(skill.rawValue): kept \(best.kind.rawValue)")
    let report = Report(kind: best.kind.rawValue, cutoff: best.cutoff, validation: best.score, p95Milliseconds: best.p95,
                        fingerprint: fingerprint, trainingCount: fitting.count, validationCount: validation.count)
    return Trained(skill: skill, classifier: best.classifier, report: report, asOf: day(training.asOf))
  }

  /// Chip models share one budget while typing, so the run fails when the chip models in `out`,
  /// with this run's replacing theirs, are over it together. Auto's limits are checked in `train`.
  static func checkChipBudget(_ trained: [Trained], out: URL, enforced: Bool) throws {
    guard enforced else {
      print("speed limits not enforced: --kind is for fixtures and probes")
      return
    }
    guard trained.contains(where: \.skill.isChip) else { return }
    let drafts = speedDrafts()
    var chipTotal = 0.0
    for skill in IntentSkill.allCases where skill.isChip {
      if let model = trained.first(where: { $0.skill == skill }) {
        chipTotal += model.report.p95Milliseconds
      } else {
        let existing = out.appending(path: "\(skill.modelName).mlmodel")
        guard FileManager.default.fileExists(atPath: existing.path) else { continue }
        // A model that won't load can't be timed, and counting it as free would hide it from the budget.
        chipTotal += p95Milliseconds(try compiled(at: existing), drafts: drafts)
      }
    }
    print("chip models together: p95 \(String(format: "%.3f", chipTotal)) ms")
    guard chipTotal <= chipBudgetMilliseconds else {
      throw Failure("chip models take \(String(format: "%.3f", chipTotal)) ms together, over \(chipBudgetMilliseconds) ms")
    }
  }

  static func compiled(_ classifier: MLTextClassifier) throws -> NLModel {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appending(path: "Model.mlmodel")
    try classifier.write(to: source)
    return try compiled(at: source)
  }

  /// Compiles into `workFolder`, which outlives every model loaded from it this run.
  static func compiled(at source: URL) throws -> NLModel {
    try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
    let destination = workFolder.appending(path: "\(UUID().uuidString).mlmodelc")
    try FileManager.default.moveItem(at: MLModel.compileModel(at: source), to: destination)
    return try NLModel(contentsOf: destination)
  }

  /// p95 of `timedPredictions` predictions over drafts cycled from `drafts`, after a warm-up.
  static func p95Milliseconds(_ model: NLModel, drafts: [String]) -> Double {
    let pool = drafts.isEmpty ? speedDrafts() : drafts
    _ = model.predictedLabelHypotheses(for: pool[0], maximumCount: 3)
    var times: [Double] = []
    for index in 0..<timedPredictions {
      let start = DispatchTime.now().uptimeNanoseconds
      _ = model.predictedLabelHypotheses(for: pool[index % pool.count], maximumCount: 3)
      times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }
    times.sort()
    return times[times.count * 95 / 100]
  }

  /// Invented drafts of 5–60 words for timing models that aren't being trained.
  static func speedDrafts() -> [String] {
    let words = ["what", "is", "the", "latest", "news", "about", "write", "a", "poem", "weather", "today", "explain",
                 "how", "this", "code", "works", "price", "my", "please", "and", "for", "think", "carefully", "text"]
    return (0..<200).map { draft in
      (0..<(5 + draft % 56)).map { words[($0 * 7 + draft * 13) % words.count] }.joined(separator: " ")
    }
  }

  static func day(_ date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
  }
}
