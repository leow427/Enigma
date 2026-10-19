import SwiftUI
import UniformTypeIdentifiers

/// Local models in Settings: install, update, use, and delete, the
/// performance check, file downloads, imported models, file tools, and GGUF
/// import.
struct LocalModelManagerSection: View {
  @ObservedObject var advisor: LocalModelAdvisor
  @ObservedObject var chat: LocalChatViewModel
  var downloads: HuggingFaceModelDownloads = .shared
  var sources: HuggingFaceDownloadSources = .live
  @State private var isImporterPresented = false
  @State private var pendingDeletion: LocalModel?
  @State private var downloadListing: HuggingFaceModelListing?
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.enigmaAppearance) private var appearance

  var body: some View {
    let recommendations = advisor.recommendations(installedModels: chat.installedModels)
    VStack(alignment: .leading, spacing: 0) {
      if let hardware = advisor.hardware {
        HStack(alignment: .top, spacing: 22) {
          stat(hardware.inferenceMemoryBudget.formatted(.byteCount(style: .memory)), "available for inference")
          stat(hardware.availableDiskBytes.formatted(.byteCount(style: .file)), "free disk")
          stat(hardware.chip, "chip")
        }
        .padding(.top, 16)
        Text(LocalModelSettingsLogic.hardwareDetails(hardware))
          .font(EnigmaTypography.mono(11))
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
        Button("Detect Mac capabilities") { Task { await advisor.detectHardware() } }
          .enigmaButtonStyle(.secondary)
        Button("Refresh recommendations") {
          Task {
            await advisor.detectHardware()
            await advisor.refreshCatalog(force: true)
          }
        }
        .enigmaButtonStyle(.secondary)
        Button("Check performance") { chat.runModelBenchmark() }
          .enigmaButtonStyle(.secondary)
          .disabled(chat.installedModel == nil)
      }
      .disabled(chat.isBusy || advisor.isDetecting)
      .padding(.top, 12)

      EnigmaSectionHeader("For this Mac")
      ForEach(recommendations.roles) { choice in modelRow(choice.assessment, badge: choice.tag) }
      EnigmaHairline()
      if !recommendations.allFamilies.isEmpty {
        EnigmaDisclosure("All models") {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(recommendations.allFamilies) { assessment in modelRow(assessment) }
            EnigmaHairline()
          }
        }
        .padding(.top, 12)
      }

      let imported = chat.installedModels.filter { model in !advisor.manifest.models.contains { $0.id == model.id } }
      if !imported.isEmpty {
        EnigmaSectionHeader("Imported models")
        ForEach(imported) { model in importedRow(model) }
        EnigmaHairline()
      }

      EnigmaSectionHeader("Files")
      LocalFileToolsRow(model: chat.installedModel)
      FileRecoveryRow(files: chat.files)
      EnigmaHairline()
      Button("Advanced: Import text GGUF…") { isImporterPresented = true }
        .enigmaButtonStyle(.text)
        .disabled(chat.isBusy)
        .padding(.leading, -8)
        .padding(.top, 8)
      EnigmaHint("approved model catalog · version \(advisor.manifest.version)").padding(.top, 6)
    }
    .task { await LocalModelSettingsLogic.prepare(advisor: advisor, chat: chat) }
    .fileImporter(isPresented: $isImporterPresented,
      allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data], allowsMultipleSelection: false) { result in
      if case .success(let urls) = result, let url = urls.first { chat.installModel(from: url) }
    }
    .sheet(item: $downloadListing) { model in
      HuggingFaceDownloadSheet(model: model, sources: sources, downloads: downloads)
        .enigmaTheme(appearance)
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
        .font(EnigmaTypography.mono(11))
        .foregroundStyle(palette.textTertiary.color)
    }
    .accessibilityElement(children: .combine)
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
            mono("\(model.quantization) · \(model.recommendedContextSize) token context · \(model.performanceClass)")
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
                                                      activeID: chat.installedModel?.id, isBusy: chat.isBusy)
    let title = switch state.action {
    case .use(let isSelected): isSelected ? "Selected" : "Use"
    case .update: assessment.permitsMemoryOverride ? "Update anyway" : "Update"
    case .install: "Install"
    case .downloadFiles: "Download files"
    }
    Button(title) {
      switch state.action {
      case .use: chat.selectModel(id: assessment.id)
      case .update, .install: chat.downloadModel(assessment.model)
      case .downloadFiles: downloadListing = HuggingFaceModelListing(id: assessment.model.huggingFaceRepositoryID)
      }
    }
    .enigmaButtonStyle(.secondary)
    .disabled(!state.isEnabled)
    .accessibilityHint(assessment.model.displayName)
    .enigmaTestMarker("\(title) \(assessment.model.displayName)")
  }

  private func importedRow(_ model: LocalModel) -> some View {
    let selected = chat.installedModel?.id == model.id
    return EnigmaRow(model.displayName,
                     subtitle: model.supportsVision
                       ? "Legacy/imported image model · Select to use for all requests"
                       : "Legacy/imported text-only model · OCR available, images unsupported") {
      HStack(spacing: 6) {
        Button(selected ? "Selected" : "Use") { chat.selectModel(id: model.id) }
          .enigmaButtonStyle(.secondary)
          .disabled(chat.isBusy || selected)
          .enigmaTestMarker("\(selected ? "Selected" : "Use") \(model.displayName)")
        deleteButton(model)
      }
    }
  }

  private func deleteButton(_ model: LocalModel) -> some View {
    Button("Delete") { pendingDeletion = model }
      .enigmaButtonStyle(.text)
      .disabled(chat.isBusy)
      .accessibilityLabel("Delete \(model.displayName)")
      .enigmaTestMarker("Delete \(model.displayName)")
  }

  private func mono(_ text: String, color: EnigmaColor? = nil) -> some View {
    Text(text)
      .font(EnigmaTypography.mono(11))
      .foregroundStyle((color ?? palette.textTertiary).color)
      .fixedSize(horizontal: false, vertical: true)
  }
}
