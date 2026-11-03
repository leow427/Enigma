import Foundation

/// The context size picked under Settings → On this Mac → › Advanced (F35). Saved in UserDefaults.
enum LocalContextWindowPreference: String, CaseIterable, Sendable {
  case smaller, automatic, larger, maximum

  static let key = "localContextWindowPreference"

  var title: String {
    switch self {
    case .smaller: "Smaller (4K)"
    case .automatic: "Automatic"
    case .larger: "Larger (16K)"
    case .maximum: "Max (32K)"
    }
  }

  var accessibilityLabel: String {
    switch self {
    case .smaller: "Smaller, 4,096 tokens"
    case .automatic: "Automatic"
    case .larger: "Larger, 16,384 tokens"
    case .maximum: "Max, 32,768 tokens"
    }
  }

  /// The size this preference asks for; nil for Automatic.
  var fixedSize: Int? {
    switch self {
    case .smaller: 4_096
    case .automatic: nil
    case .larger: 16_384
    case .maximum: 32_768
    }
  }

  static func saved(in defaults: UserDefaults) -> Self {
    defaults.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .automatic
  }

  /// The models whose warning for a preset was answered Use It, one `id=preset` per line. The
  /// preset is global, so a model selected later is asked again before it runs over the line.
  static let acceptedKey = "localContextWindowAccepted"

  static func isAccepted(_ preference: Self, modelID: String, in accepted: String) -> Bool {
    accepted.split(separator: "\n").contains { $0 == "\(modelID)=\(preference.rawValue)" }
  }

  static func accepting(_ preference: Self, modelID: String, in accepted: String) -> String {
    let entry = "\(modelID)=\(preference.rawValue)"
    return isAccepted(preference, modelID: modelID, in: accepted) ? accepted
      : accepted.isEmpty ? entry : accepted + "\n" + entry
  }
}

/// The window a local model runs at (F35): a runtime choice that reaches llama-server's
/// `--ctx-size`, the embedded engine and `LocalModel.contextWindow`. It is never written into
/// `visionConfiguration`, so it never trips the package's Update check.
enum LocalContextWindowChoice {
  static let sizes = [8_192, 16_384, 32_768]

  /// The trained maximum, or 8,192 when the package doesn't say. Installed records keep the
  /// descriptor they were installed with, so one saved before the field reads it from the bundled
  /// catalogue's same package.
  static func trainedMaximum(_ descriptor: LocalModelDescriptor) -> Int {
    descriptor.trainedContextLength
      ?? BundledLocalModels.models.first { $0.id == descriptor.id && $0.checksumSHA256 == descriptor.checksumSHA256 }?
        .trainedContextLength
      ?? 8_192
  }

  /// The memory estimate at `size`, from the package's profile; nil without one.
  static func memory(_ descriptor: LocalModelDescriptor, size: Int) -> Int64? {
    descriptor.resolvedProfile?.memory(weights: descriptor.expectedByteCount,
                                       projector: descriptor.projector?.expectedByteCount ?? 0, context: size)
  }

  /// Within the "comfortable" line: 4/5 of the inference budget.
  static func fitsComfortably(_ memory: Int64, hardware: LocalHardwareProfile) -> Bool {
    memory <= hardware.inferenceMemoryBudget * 4 / 5
  }

  /// The largest size ≤ trained maximum (8,192 when unknown) whose memory estimate fits
  /// comfortably (4/5 of `hardware.inferenceMemoryBudget`), never below 8,192.
  static func automatic(for descriptor: LocalModelDescriptor, hardware: LocalHardwareProfile) -> Int {
    sizes.last { size in
      size == sizes[0] || (size <= trainedMaximum(descriptor)
        && memory(descriptor, size: size).map { fitsComfortably($0, hardware: hardware) } == true)
    } ?? sizes[0]
  }

  /// The size the runtime uses for this preference; nil for a preference the model or memory
  /// rules out (the settings row disables it).
  static func size(for preference: LocalContextWindowPreference, descriptor: LocalModelDescriptor,
                   hardware: LocalHardwareProfile) -> Int? {
    guard let size = preference.fixedSize else { return automatic(for: descriptor, hardware: hardware) }
    // 4K is too small for a screenshot's image tokens, so vision packages don't offer it.
    guard size >= sizes[0] ? size <= trainedMaximum(descriptor) : !descriptor.supportsVision else { return nil }
    if let memory = memory(descriptor, size: size), memory > hardware.inferenceMemoryBudget { return nil }
    return size
  }

  /// As above for an installed model. One with no catalogue descriptor keeps its own window
  /// under Automatic, and the other presets are ruled out.
  static func size(for preference: LocalContextWindowPreference, model: LocalModel,
                   hardware: LocalHardwareProfile) -> Int? {
    guard let descriptor = model.catalogDescriptor else {
      return preference == .automatic ? model.packageContextWindow : nil
    }
    return size(for: preference, descriptor: descriptor, hardware: hardware)
  }

  /// The preference's size may not fit comfortably: the warning shows before applying it. A size
  /// no larger than Automatic's never warns, even for a model that is over the line already.
  static func needsWarning(_ preference: LocalContextWindowPreference, model: LocalModel,
                           hardware: LocalHardwareProfile) -> Bool {
    model.catalogDescriptor.map { needsWarning(preference, descriptor: $0, hardware: hardware) } ?? false
  }

  static func needsWarning(_ preference: LocalContextWindowPreference, descriptor: LocalModelDescriptor,
                           hardware: LocalHardwareProfile) -> Bool {
    guard preference != .automatic,
          let size = size(for: preference, descriptor: descriptor, hardware: hardware),
          size > automatic(for: descriptor, hardware: hardware),
          let memory = memory(descriptor, size: size) else { return false }
    return !fitsComfortably(memory, hardware: hardware)
  }

  /// The size a package runs at: the preference, or Automatic when the preference is ruled out
  /// for it or its warning hasn't been answered Use It for this package.
  static func runtimeSize(for descriptor: LocalModelDescriptor, preference: LocalContextWindowPreference,
                          accepted: String, hardware: LocalHardwareProfile) -> Int {
    if needsWarning(preference, descriptor: descriptor, hardware: hardware),
       !LocalContextWindowPreference.isAccepted(preference, modelID: descriptor.id, in: accepted) {
      return automatic(for: descriptor, hardware: hardware)
    }
    return size(for: preference, descriptor: descriptor, hardware: hardware) ?? automatic(for: descriptor, hardware: hardware)
  }

  /// The app's choice: the preference in standard defaults and this Mac's memory. Inert under
  /// the test host, whose defaults and hardware are the developer's; tests pass their own.
  static let current: @Sendable (LocalModelDescriptor) -> Int? = { descriptor in
    guard !TestHost.isActive else { return nil }
    return runtimeSize(for: descriptor, preference: .saved(in: .standard),
                       accepted: UserDefaults.standard.string(forKey: LocalContextWindowPreference.acceptedKey) ?? "",
                       hardware: hardware)
  }

  /// Memory doesn't change while the app runs; the disk figure in it isn't read here.
  private static let hardware = LocalHardwareProfile.detect(
    modelsDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
}
