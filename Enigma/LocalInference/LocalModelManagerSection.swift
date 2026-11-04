import SwiftUI
import UniformTypeIdentifiers

/// Local models in Settings, the one place to choose a model: this Mac, the
/// three choices picked for it, installed models, every catalogue family,
/// file tools, and GGUF import.
struct LocalModelManagerSection: View {
  @ObservedObject var advisor: LocalModelAdvisor
  @ObservedObject var chat: LocalChatViewModel
  @State private var isImporterPresented = false
  @State private var pendingDeletion: LocalModel?
  @AppStorage(LocalContextWindowPreference.key) private var contextPreference = LocalContextWindowPreference.automatic
  @AppStorage(LocalContextWindowPreference.acceptedKey) private var contextAccepted = ""
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.enigmaSettingsStyle) private var settingsStyle

  var body: some View {
    let recommendations = advisor.recommendations(installedModels: chat.installedModels)
    VStack(alignment: .leading, spacing: 0) {
      if let hardware = advisor.hardware {
        HStack(alignment: .top, spacing: 22) {
          stat(hardware.inferenceMemoryBudget.formatted(.byteCount(style: .memory)), "available for inference")
          stat(hardware.availableDiskBytes.formatted(.byteCount(style: .file)), "free disk")
          stat(hardware.chip, "chip")
          let bandwidth = LocalModelSettingsLogic.bandwidthStat(hardware)
          stat(bandwidth.value, bandwidth.label)
        }
        .padding(.top, 16)
        Text(LocalModelSettingsLogic.hardwareDetails(hardware))
          .font(EnigmaTypography.detail(11, settings: settingsStyle))
          .foregroundStyle(palette.textTertiary.color)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 6)
      }
      if LocalModelSettingsLogic.showsOperation(chat: chat, advisor: advisor) {
        LocalModelOperationView(chat: chat, advisor: advisor).padding(.top, 14)
      }
      VStack(alignment: .leading, spacing: 6) {
        EnigmaNote("One selected model handles chat, screenshots and search answers. Every recommended package includes image support.")
        if chat.installedModel?.supportsVision == false {
          EnigmaStatusLine(.problem, "Your selected model supports text and OCR only. Install a recommended package to answer visual questions. Your existing files stay available below.")
        }
      }
      .padding(.top, 14)
      HStack(spacing: 8) {
        Button("Check this Mac") {
          Task {
            await advisor.detectHardware(remeasureBandwidth: true)
            await advisor.refreshCatalog(force: true)
          }
        }
        .enigmaButtonStyle(.secondary)
        .enigmaTestMarker("Check this Mac")
        Button("Check performance") { chat.runModelBenchmark() }
          .enigmaButtonStyle(.secondary)
          .disabled(chat.installedModel == nil)
          .enigmaTestMarker("Check performance")
      }
      .disabled(!chat.canChangeModels || advisor.isDetecting)
      .padding(.top, 12)

      EnigmaSectionHeader("For this Mac")
      EnigmaNote("Picked for this Mac's memory and measured speed. Check performance measures the selected model here.")
      if recommendations.roles.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          EnigmaStatusLine(.problem, "No suitable model found")
          Text("No supported text-and-image model fits this Mac's memory or disk budget. All models below shows the specific limits. Cloud is also available.")
            .font(EnigmaTypography.ui(12))
            .foregroundStyle(palette.textSecondary.color)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
      }
      ForEach(recommendations.roles) { choice in modelRow(choice.assessment, badge: choice.tag) }
      EnigmaHairline()

      if !chat.installedModels.isEmpty {
        EnigmaSectionHeader("On this Mac")
        ForEach(chat.installedModels) { model in installedRow(model) }
        EnigmaHairline()
      }

      if !recommendations.allFamilies.isEmpty {
        EnigmaDisclosure("All models") {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(recommendations.allFamilies) { assessment in modelRow(assessment) }
            EnigmaHairline()
          }
        }
        .padding(.top, 12)
      }

      EnigmaSectionHeader("Files")
      LocalFileToolsRow(model: chat.installedModel)
      FileRecoveryRow(files: chat.files)
      EnigmaHairline()
      Button("Advanced: Import text GGUF…") { isImporterPresented = true }
        .enigmaButtonStyle(.text)
        .disabled(!chat.canChangeModels)
        .padding(.leading, -8)
        .padding(.top, 8)
      EnigmaHint("approved model catalog · version \(advisor.manifest.version)").padding(.top, 6)
      SettingsAdvanced { LocalContextSizeRow(advisor: advisor, chat: chat) }
    }
    .task { await LocalModelSettingsLogic.prepare(advisor: advisor, chat: chat) }
    .fileImporter(isPresented: $isImporterPresented,
      allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data], allowsMultipleSelection: false) { result in
      if case .success(let urls) = result, let url = urls.first { chat.installModel(from: url) }
    }
    .alert(item: $pendingDeletion) { model in
      Alert(
        title: Text("Delete \(model.displayName)?"),
        message: Text("This removes the downloaded model and its local support files from this Mac."),
        primaryButton: .destructive(Text("Delete")) { chat.deleteModel(id: model.id) },
        secondaryButton: .cancel()
      )
    }
  }

  private func stat(_ value: String, _ label: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value)
        .font(EnigmaTypography.ui(17, weight: .semibold))
        .foregroundStyle(palette.textPrimary.color)
      Text(label)
        .font(EnigmaTypography.detail(11, settings: settingsStyle))
        .foregroundStyle(palette.textTertiary.color)
    }
    .accessibilityElement(children: .combine)
    .enigmaTestMarker(value)
  }

  private func modelRow(_ assessment: LocalModelAssessment, badge: String? = nil) -> some View {
    let model = assessment.model
    return EnigmaRow(model.displayName, badge: badge, subtitle: model.summary) {
      VStack(alignment: .leading, spacing: 2) {
        if assessment.fit.canRun {
          mono(assessment.fit.rawValue, color: palette.textSecondary)
        } else {
          EnigmaStatusLine(.problem, assessment.fit.rawValue)
        }
        mono("\(model.maker) · \(model.downloadByteCount.formatted(.byteCount(style: .file))) · \(model.license)")
        // When the model can't run here, this is the reason, which people need to read.
        mono(assessment.performanceDescription, color: assessment.fit.canRun ? nil : palette.textSecondary)
        if let range = model.advertisedMemoryRange {
          mono("~\(range) GB RAM planning estimate · \(model.quantization)")
        }
        if model.modelSupportsAudio == true {
          mono("Vision + Audio model · Audio is not yet available in Enigma.")
        }
        if assessment.permitsMemoryOverride {
          EnigmaStatusLine(.problem, LocalModelSettingsLogic.memoryWarning).padding(.top, 2)
        }
        EnigmaDisclosure("Model details") {
          VStack(alignment: .leading, spacing: 2) {
            mono(LocalModelSettingsLogic.contextDetail(for: model, installed: chat.installedModels) { descriptor in
              advisor.hardware.map { LocalContextWindowChoice.runtimeSize(for: descriptor, preference: contextPreference,
                                                                                     accepted: contextAccepted, hardware: $0) }
            })
            mono("Estimated memory \(model.estimatedRuntimeMemory.formatted(.byteCount(style: .memory))) · Minimum Mac memory \(model.minimumMemory.formatted(.byteCount(style: .memory)))")
            Link("Model card and license", destination: model.downloadURL
              .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
              .enigmaButtonStyle(.text)
              .padding(.leading, -8)
          }
        }
      }
      .padding(.top, 3)
    } trailing: {
      HStack(spacing: 6) {
        actionButton(for: assessment)
        if let installed = chat.installedModels.first(where: { $0.id == assessment.id }) {
          deleteButton(installed)
        }
      }
    }
  }

  @ViewBuilder private func actionButton(for assessment: LocalModelAssessment) -> some View {
    let state = LocalModelSettingsLogic.managerAction(for: assessment, installed: chat.installedModels,
                                                      activeID: chat.installedModel?.id, isBusy: !chat.canChangeModels)
    let title = switch state.action {
    case .use(let isSelected): isSelected ? "Selected" : "Use"
    case .update: assessment.permitsMemoryOverride ? "Update anyway" : "Update"
    case .install: "Install"
    }
    Button(title) {
      switch state.action {
      case .use: chat.selectModel(id: assessment.id)
      case .update, .install: chat.downloadModel(assessment.model)
      }
    }
    .enigmaButtonStyle(.secondary)
    .disabled(!state.isEnabled)
    .accessibilityHint(assessment.model.displayName)
    .enigmaTestMarker("\(title) \(assessment.model.displayName)")
  }

  /// An installed model, from the catalogue or not. The installed copy stays
  /// usable while For this Mac offers its update.
  private func installedRow(_ model: LocalModel) -> some View {
    let selected = chat.installedModel?.id == model.id
    let inCatalogue = advisor.manifest.models.contains { $0.id == model.id }
    return EnigmaRow(model.displayName,
                     subtitle: LocalModelSettingsLogic.installedSubtitle(for: model, inCatalogue: inCatalogue)) {
      HStack(spacing: 6) {
        Button(selected ? "Selected" : "Use") { chat.selectModel(id: model.id) }
          .enigmaButtonStyle(.secondary)
          .disabled(!chat.canChangeModels || selected)
          .enigmaTestMarker("\(selected ? "Selected" : "Use") \(model.displayName)")
        deleteButton(model)
      }
    }
  }

  private func deleteButton(_ model: LocalModel) -> some View {
    Button("Delete") { pendingDeletion = model }
      .enigmaButtonStyle(.text)
      .disabled(!chat.canChangeModels)
      .accessibilityLabel("Delete \(model.displayName)")
      .enigmaTestMarker("Delete \(model.displayName)")
  }

  private func mono(_ text: String, color: EnigmaColor? = nil) -> some View {
    Text(text)
      .font(EnigmaTypography.detail(11, settings: settingsStyle))
      .foregroundStyle((color ?? palette.textTertiary).color)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// Settings → On this Mac → › Advanced: the window local models run at (F35). A size over the
/// comfortable memory line asks first; one the model or memory rules out is disabled.
struct LocalContextSizeRow: View {
  @ObservedObject var advisor: LocalModelAdvisor
  @ObservedObject var chat: LocalChatViewModel
  @AppStorage(LocalContextWindowPreference.key) private var preference = LocalContextWindowPreference.automatic
  @AppStorage(LocalContextWindowPreference.acceptedKey) private var accepted = ""
  @State private var pending: LocalContextWindowPreference?

  static let title = "Context size"
  static let detail = "Larger sizes remember more of a long chat but use more memory and answer a little slower."
  static let warning = "This size may not fit in this Mac's memory alongside other apps. Use it anyway?"
  static let waitingNote = "Until you choose Use It, this model runs at Automatic."

  static func ruledOutNote(_ preference: LocalContextWindowPreference) -> String {
    "This model can't use \(preference.title) on this Mac, so it runs at Automatic."
  }

  var body: some View {
    let asking = pending ?? unanswered
    VStack(alignment: .leading, spacing: 0) {
      EnigmaRow(Self.title, subtitle: Self.detail) {
        EnigmaSegmentedControl(Self.title, selection: Binding(get: { pending ?? preference }, set: { choose($0) }),
                               options: Self.options(model: chat.installedModel, hardware: advisor.hardware))
          .fixedSize()
      }
      if let asking {
        VStack(alignment: .leading, spacing: 8) {
          EnigmaStatusLine(.problem, pending == nil ? "\(Self.warning) \(Self.waitingNote)" : Self.warning)
          HStack(spacing: 8) {
            Button("Use It") { apply(asking) }
              .enigmaButtonStyle(.secondary)
              .enigmaTestMarker("Use It")
            Button("Cancel") { if pending == nil { apply(.automatic) } else { pending = nil } }
              .enigmaButtonStyle(.text)
              .enigmaTestMarker("Cancel")
          }
        }
        .padding(.bottom, 10)
      } else if let model = chat.installedModel, let hardware = advisor.hardware,
                LocalContextWindowChoice.size(for: preference, model: model, hardware: hardware) == nil {
        EnigmaNote(Self.ruledOutNote(preference)).padding(.bottom, 10).enigmaTestMarker("Context size ruled out")
      }
      EnigmaHairline()
    }
    // Until this Mac's memory is known nothing can be ruled out or warned about.
    .disabled(!chat.canChangeModels || advisor.hardware == nil)
    .onChange(of: pending) { _, asking in
      if asking != nil { AccessibilityNotification.Announcement(Self.warning).post() }
    }
    // A question about one model doesn't carry over to another.
    .onChange(of: chat.installedModel?.id) { pending = nil }
  }

  /// The saved preset is over the line for the selected model, which hasn't been answered yet.
  private var unanswered: LocalContextWindowPreference? {
    guard let model = chat.installedModel, let hardware = advisor.hardware,
          LocalContextWindowChoice.needsWarning(preference, model: model, hardware: hardware),
          !LocalContextWindowPreference.isAccepted(preference, modelID: model.id, in: accepted) else { return nil }
    return preference
  }

  /// Without a selected model or this Mac's hardware, nothing is ruled out yet.
  static func options(model: LocalModel?, hardware: LocalHardwareProfile?) -> [EnigmaOption<LocalContextWindowPreference>] {
    LocalContextWindowPreference.allCases.map { preference in
      let allowed = preference == .automatic || model.flatMap { model in
        hardware.map { LocalContextWindowChoice.size(for: preference, model: model, hardware: $0) != nil }
      } ?? true
      return EnigmaOption(preference, preference.title, isEnabled: allowed, accessibilityLabel: preference.accessibilityLabel)
    }
  }

  private func choose(_ choice: LocalContextWindowPreference) {
    guard choice != preference || unanswered != nil else { pending = nil; return }
    guard Self.options(model: chat.installedModel, hardware: advisor.hardware).contains(where: { $0.value == choice && $0.isEnabled })
    else { return }
    if let model = chat.installedModel, let hardware = advisor.hardware,
       LocalContextWindowChoice.needsWarning(choice, model: model, hardware: hardware),
       !LocalContextWindowPreference.isAccepted(choice, modelID: model.id, in: accepted) {
      pending = choice
    } else {
      apply(choice)
    }
  }

  /// The runtime starts again at the next request, with the new size; nothing is downloaded. A
  /// size this model hasn't been measured at gets the performance check, as after an install.
  private func apply(_ choice: LocalContextWindowPreference) {
    pending = nil
    if let model = chat.installedModel, let hardware = advisor.hardware,
       LocalContextWindowChoice.needsWarning(choice, model: model, hardware: hardware) {
      accepted = LocalContextWindowPreference.accepting(choice, modelID: model.id, in: accepted)
    }
    preference = choice
    let before = chat.installedModel?.contextWindow
    Task {
      await chat.refreshInstalledModel()
      guard let model = chat.installedModel, model.contextWindow != before,
            advisor.latestBenchmark(for: model) == nil else { return }
      chat.runModelBenchmark()
    }
  }
}
