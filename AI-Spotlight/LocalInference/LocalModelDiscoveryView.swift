import SwiftUI

/// Discover in Settings: the featured model, the selected packages, and
/// Hugging Face search.
struct LocalModelDiscoveryView: View {
  /// Where the page lists models from.
  enum Source: String, CaseIterable { case selection = "Selected models", hub = "More on Hugging Face" }

  @ObservedObject var discovery: LocalModelDiscovery
  @ObservedObject var advisor: LocalModelAdvisor
  @ObservedObject var chat: LocalChatViewModel
  var downloads: HuggingFaceModelDownloads = .shared
  var sources: HuggingFaceDownloadSources = .live
  @State private var searchText = ""
  @State private var query = ModelDiscoveryQuery()
  @State private var requestID = UUID()
  @State private var pageRequest: Task<Void, Never>?
  @State private var source = Source.selection
  @State private var downloadModel: HuggingFaceModelListing?
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.enigmaAppearance) private var appearance

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HuggingFaceDownloadProgress(downloads: downloads).padding(.top, 12)
      featuredModel
      browseControls
      if source == .selection { selectedPackages } else { results }
    }
    .task(id: requestID) {
      pageRequest?.cancel()
      if source == .hub { await discovery.search(query) }
    }
    .task { await LocalModelSettingsLogic.prepare(advisor: advisor, chat: chat) }
    .onDisappear { pageRequest?.cancel() }
    .sheet(item: $downloadModel) { model in
      HuggingFaceDownloadSheet(model: model, sources: sources, downloads: downloads)
        .enigmaTheme(appearance)
    }
  }

  private func search() {
    query.search = searchText
    requestID = UUID()
  }

  // MARK: Featured

  private var featuredModel: some View {
    VStack(alignment: .leading, spacing: 0) {
      EnigmaSectionHeader("Featured · local model")
      if let model = advisor.manifest.models.first(where: { $0.id == LocalModelDiscovery.featuredModelID }) {
        let assessment = advisor.recommendations(installedModels: chat.installedModels).assessments
          .first { $0.id == model.id }
        EnigmaRow("Gemma 4 26B-A4B (MoE)", subtitle: "Q4_K_M · Vision · Google") {
          VStack(alignment: .leading, spacing: 4) {
            Text("\(model.downloadByteCount.formatted(.byteCount(style: .file))) download · ~\(model.advertisedMemoryRange ?? "21–25") GB RAM estimate")
              .font(EnigmaTypography.mono(11))
              .foregroundStyle(palette.textTertiary.color)
            if assessment == nil {
              EnigmaStatusLine(.busy, "Checking this Mac’s available memory and storage…")
            }
            if let assessment, let warning = LocalModelSettingsLogic.fitWarning(for: assessment) {
              EnigmaStatusLine(.problem, warning)
            }
            HStack(spacing: 2) {
              Link("Model card", destination: URL(string: "https://huggingface.co/bartowski/google_gemma-4-26B-A4B-it-GGUF")!)
                .enigmaButtonStyle(.text)
              Button("Local models") {
                NotificationCenter.default.post(name: .settingsDestinationRequested,
                                                object: SettingsView.SettingsDestination.local)
              }
              .enigmaButtonStyle(.text)
              .accessibilityLabel("Open Local models")
            }
            .padding(.leading, -8)
          }
          .padding(.top, 3)
        } trailing: {
          featuredAction(model, assessment: assessment)
        }
        .help("A mixture-of-experts model with about 4B active parameters. The full model still needs to fit in memory.")
      }
      if LocalModelSettingsLogic.showsDiscoverOperation(state: chat.state, isBusy: chat.isBusy) {
        LocalModelOperationView(chat: chat, advisor: advisor).padding(.bottom, 10)
      }
      EnigmaHairline()
    }
  }

  /// The page's one accent button: install or use the featured model.
  @ViewBuilder
  private func featuredAction(_ model: LocalModelDescriptor, assessment: LocalModelAssessment?) -> some View {
    let state = LocalModelSettingsLogic.featuredAction(for: model, assessment: assessment,
                                                       installed: chat.installedModels,
                                                       activeID: chat.installedModel?.id, isBusy: chat.isBusy)
    switch state.action {
    case .downloadFiles:
      Button("Download Q4 files") { downloadModel = HuggingFaceModelListing(id: model.huggingFaceRepositoryID) }
        .enigmaButtonStyle(.secondary)
    case .use(let isSelected):
      Button(isSelected ? "Selected" : "Use model") { chat.selectModel(id: model.id) }
        .enigmaButtonStyle(.primary)
        .disabled(!state.isEnabled)
    case .install, .update:
      Button(state.action == .install ? "Install Q4_K_M" : "Update Q4_K_M") { chat.downloadModel(model) }
        .enigmaButtonStyle(.primary)
        .disabled(!state.isEnabled)
    }
  }

  // MARK: Browse

  private var browseControls: some View {
    VStack(alignment: .leading, spacing: 0) {
      EnigmaSectionHeader("Discover vision & audio models")
      EnigmaNote("A selection for visual conversation and speech, with direct downloads.").padding(.bottom, 6)
      EnigmaRow("Browse") {
        EnigmaSegmentedControl("Browse", selection: $source,
                               options: Source.allCases.map { EnigmaOption($0, $0.rawValue) })
      }
      EnigmaRow("Capability") {
        EnigmaSegmentedControl("Capability", selection: $query.scope,
                               options: ModelDiscoveryScope.allCases.map { EnigmaOption($0, $0.rawValue) })
      }
      if source == .hub {
        EnigmaRow("Task") {
          EnigmaMenu("Task", selection: $query.taskID,
                     options: [EnigmaOption<String?>(nil, "All tasks")]
                       + HuggingFaceTask.tasks(for: query.scope).map { EnigmaOption(Optional($0.id), $0.name) })
        }
      }
      HStack(spacing: 8) {
        EnigmaTextField("Search models or publishers", text: $searchText, onSubmit: search)
        Button("Search", action: search).enigmaButtonStyle(.secondary)
      }
      .padding(.vertical, 10)
      .overlay(alignment: .top) { EnigmaHairline() }
      EnigmaHairline()
      EnigmaNote("Enigma supports text and images. Audio models can be downloaded for use in another app.")
        .padding(.top, 8)
    }
    .onChange(of: source) { _, _ in requestID = UUID() }
    .onChange(of: query.scope) { _, _ in
      query.taskID = nil
      requestID = UUID()
    }
    .onChange(of: query.taskID) { _, _ in requestID = UUID() }
  }

  // MARK: Selected packages

  @ViewBuilder
  private var selectedPackages: some View {
    let packages = LocalModelSettingsLogic.discoverPackages(
      advisor.recommendations(installedModels: chat.installedModels).assessments,
      scope: query.scope, search: query.search)
    EnigmaSectionHeader("Selected models")
    if advisor.hardware == nil {
      EnigmaStatusLine(.busy, "Preparing model choices…").padding(.vertical, 8)
    } else if packages.isEmpty {
      emptyState("No matching packages", "Try another search or explore more models on Hugging Face.")
    }
    LazyVStack(alignment: .leading, spacing: 0) {
      ForEach(packages) { assessment in
        DiscoverPackageRow(assessment: assessment, chat: chat) {
          downloadModel = HuggingFaceModelListing(id: assessment.model.huggingFaceRepositoryID)
        }
      }
    }
    if !packages.isEmpty { EnigmaHairline() }
  }

  // MARK: Hugging Face

  @ViewBuilder
  private var results: some View {
    EnigmaSectionHeader("More on Hugging Face")
    HStack(spacing: 10) {
      Text("\(discovery.models.count) \(discovery.models.count == 1 ? "model" : "models") loaded")
        .font(EnigmaTypography.mono(11.5))
        .foregroundStyle(palette.textSecondary.color)
      if discovery.isLoading { EnigmaStatusLine(.busy, "Loading models") }
    }
    if !discovery.models.isEmpty {
      EnigmaNote("Most downloaded among loaded results. Load more to continue through the catalog.").padding(.top, 4)
    }
    if let notice = discovery.notice {
      VStack(alignment: .leading, spacing: 6) {
        EnigmaStatusLine(.problem, notice)
        if discovery.failedTaskCount > 0 {
          EnigmaNote("\(discovery.failedTaskCount) task lists could not load. Available results are shown below.")
        }
        Button("Retry failed requests") { pageRequest = Task { await discovery.retry() } }
          .enigmaButtonStyle(.secondary)
          .disabled(discovery.isLoading)
      }
      .padding(.vertical, 10)
    }
    if discovery.models.isEmpty && !discovery.isLoading && discovery.notice == nil {
      emptyState("No matching models", "Try another model name, publisher or task.")
    }
    // Pages from "Load more" draw only as they scroll into view.
    LazyVStack(alignment: .leading, spacing: 0) {
      ForEach(discovery.models) { model in
        HuggingFaceModelRow(model: model,
          hasLocalPackage: advisor.manifest.models.contains { $0.huggingFaceRepositoryID == model.id },
          download: { downloadModel = model })
      }
      if !discovery.models.isEmpty { EnigmaHairline() }
    }
    .padding(.top, 6)
    if discovery.hasMore {
      Button(discovery.isLoading ? "Loading models…" : "Load more models") {
        pageRequest = Task { await discovery.loadMore() }
      }
      .enigmaButtonStyle(.secondary)
      .disabled(discovery.isLoading)
      .frame(maxWidth: .infinity)
      .padding(.top, 12)
    } else if !discovery.models.isEmpty && !discovery.isLoading {
      EnigmaHint("you’ve reached the end of these results").padding(.top, 10)
    }
    EnigmaNote("Search terms are sent to Hugging Face when you search. Browsing downloads model listings only.")
      .padding(.top, 10)
  }

  private func emptyState(_ title: String, _ detail: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      EnigmaStatusLine(.off, title)
      EnigmaNote(detail)
    }
    .padding(.vertical, 8)
  }
}

/// A selected package in Discover.
struct DiscoverPackageRow: View {
  let assessment: LocalModelAssessment
  @ObservedObject var chat: LocalChatViewModel
  let downloadFiles: () -> Void
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    let model = assessment.model
    EnigmaRow(model.displayName, subtitle: model.summary) {
      VStack(alignment: .leading, spacing: 2) {
        Text("\(model.quantization) · \(model.modelSupportsAudio == true ? "Vision + Audio" : "Vision")")
          .foregroundStyle(palette.accentText.color)
        Text("\(model.maker) · \(model.downloadByteCount.formatted(.byteCount(style: .file))) · ~\(model.advertisedMemoryRange ?? "—") GB RAM estimate")
          .foregroundStyle(palette.textTertiary.color)
        if let warning = LocalModelSettingsLogic.fitWarning(for: assessment) {
          EnigmaStatusLine(.problem, warning).padding(.top, 2)
        }
        if model.modelSupportsAudio == true {
          EnigmaStatusLine(.problem, "Audio warning: the model supports audio, but Enigma currently accepts text and images only.")
            .padding(.top, 2)
        }
      }
      .font(EnigmaTypography.mono(11))
      .fixedSize(horizontal: false, vertical: true)
      .padding(.top, 3)
    } trailing: {
      action
    }
  }

  @ViewBuilder private var action: some View {
    let state = LocalModelSettingsLogic.packageAction(for: assessment, installed: chat.installedModels,
                                                      activeID: chat.installedModel?.id, isBusy: chat.isBusy)
    Group {
      switch state.action {
      case .use(let isSelected):
        Button(isSelected ? "Selected" : "Use") { chat.selectModel(id: assessment.id) }
      case .install, .update:
        Button(state.action == .install ? "Install" : "Update") { chat.downloadModel(assessment.model) }
      case .downloadFiles:
        Button("Download files", action: downloadFiles)
      }
    }
    .enigmaButtonStyle(.secondary)
    .disabled(!state.isEnabled)
    .accessibilityHint(assessment.model.displayName)
  }
}

/// A Hugging Face listing in Discover.
struct HuggingFaceModelRow: View {
  let model: HuggingFaceModelListing
  var hasLocalPackage = false
  let download: () -> Void
  @Environment(\.enigmaPalette) private var palette

  /// Downloads, likes, GGUF, and the license, as one monospace line.
  static func statistics(for model: HuggingFaceModelListing) -> String {
    var parts: [String] = []
    if let downloads = model.downloads { parts.append("↓ \(downloads.formatted(.number.notation(.compactName)))") }
    if let likes = model.likes { parts.append("♥ \(likes.formatted(.number.notation(.compactName)))") }
    if model.isGGUF { parts.append("GGUF") }
    if let license = model.license { parts.append(license) }
    return parts.joined(separator: " · ")
  }

  var body: some View {
    EnigmaRow(model.name, subtitle: model.publisher) {
      VStack(alignment: .leading, spacing: 2) {
        if !model.tasks.isEmpty {
          Text(model.tasks.map(\.name).joined(separator: " · "))
            .foregroundStyle(palette.accentText.color)
        }
        let statistics = Self.statistics(for: model)
        if !statistics.isEmpty {
          Text(statistics)
            .foregroundStyle(palette.textTertiary.color)
            .help("Hugging Face downloads and likes")
        }
        EnigmaStatusLine(.problem, "Compatibility warning: this model may require another runtime. Enigma does not support audio input yet.")
          .padding(.top, 2)
        HStack(spacing: 2) {
          Link("Model card", destination: model.url).enigmaButtonStyle(.text)
          if hasLocalPackage {
            Button("See local packages") {
              NotificationCenter.default.post(name: .settingsDestinationRequested,
                                              object: SettingsView.SettingsDestination.local)
            }
            .enigmaButtonStyle(.text)
          }
        }
        .padding(.leading, -8)
      }
      .font(EnigmaTypography.mono(11))
      .fixedSize(horizontal: false, vertical: true)
      .padding(.top, 3)
    } trailing: {
      Button("Download files", action: download)
        .enigmaButtonStyle(.secondary)
        .accessibilityHint(model.name)
    }
  }
}

/// Where the download sheet gets a repository's file list and the folder to
/// save into. Tests replace both, so nothing touches the network or opens a panel.
struct HuggingFaceDownloadSources {
  var loadRepository: @Sendable (String) async throws -> HuggingFaceRepository = HuggingFaceRepositoryClient.load
  var chooseFolder: @MainActor (String) -> URL? = { HuggingFaceDownloadFolder.choose(for: $0) }

  static var live: HuggingFaceDownloadSources { HuggingFaceDownloadSources() }
}

/// Choose and download a Hugging Face model's files: the file list,
/// selection, folder choice, and warnings.
struct HuggingFaceDownloadSheet: View {
  static let size = CGSize(width: 620, height: 660)

  let model: HuggingFaceModelListing
  var sources: HuggingFaceDownloadSources = .live
  @ObservedObject var downloads: HuggingFaceModelDownloads = .shared
  @Environment(\.dismiss) private var dismiss
  @Environment(\.enigmaPalette) private var palette
  @State private var repository: HuggingFaceRepository?
  @State private var selected: Set<String> = []
  @State private var filter = ""
  @State private var error: String?
  @State private var requestID = UUID()

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Download \(model.name)")
          .font(EnigmaTypography.ui(20, weight: .semibold))
          .tracking(-0.3)
          .foregroundStyle(palette.textPrimary.color)
          .accessibilityAddTraits(.isHeader)
          .enigmaTestMarker("Download sheet \(model.name)")
        Text(model.publisher)
          .font(EnigmaTypography.ui(13))
          .foregroundStyle(palette.textSecondary.color)
      }
      if let repository {
        fileChooser(repository)
      } else if let error {
        VStack(alignment: .leading, spacing: 6) {
          EnigmaStatusLine(.problem, "Could not load model files")
          EnigmaNote(error)
          Button("Retry") { requestID = UUID() }.enigmaButtonStyle(.secondary)
        }
        .padding(.top, 20)
        Spacer(minLength: 0)
      } else {
        Spacer(minLength: 0)
        EnigmaStatusLine(.busy, "Loading model files…").frame(maxWidth: .infinity)
        Spacer(minLength: 0)
      }
      HuggingFaceDownloadProgress(downloads: downloads).padding(.top, 12)
      HStack {
        Link("Model card and license", destination: model.url)
          .enigmaButtonStyle(.text)
          .padding(.leading, -8)
        Spacer()
        Button("Done") { dismiss() }
          .enigmaButtonStyle(.secondary)
          .keyboardShortcut(.cancelAction)
      }
      .padding(.top, 12)
    }
    .padding(24)
    .frame(width: Self.size.width, height: Self.size.height)
    .background(palette.background.color)
    .tint(palette.accent.color)
    .task(id: requestID) {
      error = nil
      do {
        let result = try await sources.loadRepository(model.id)
        try Task.checkCancellation()
        repository = result
        selected = result.suggestedFiles
      } catch is CancellationError { }
      catch { self.error = error.localizedDescription }
    }
  }

  @ViewBuilder
  private func fileChooser(_ repository: HuggingFaceRepository) -> some View {
    EnigmaTextField("Filter files or quantizations, such as Q4", text: $filter).padding(.top, 16)
    HStack(spacing: 2) {
      Button("Suggested files") { selected = repository.suggestedFiles }.enigmaButtonStyle(.text)
      Button("Select all") { selected = Set(repository.siblings.map(\.id)) }.enigmaButtonStyle(.text)
      Button("Clear") { selected = [] }.enigmaButtonStyle(.text)
      Spacer()
      EnigmaHint("\(selected.count) selected")
    }
    .padding(.leading, -8)
    .padding(.top, 8)
    .disabled(downloads.isDownloading)
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(repository.listedFiles(matching: filter)) { file in
          EnigmaRow(file.rfilename, subtitle: file.size.formatted(.byteCount(style: .file))) {
            EnigmaSwitch(file.rfilename, isOn: Binding(get: { selected.contains(file.id) }, set: { enabled in
              if enabled { selected.insert(file.id) } else { selected.remove(file.id) }
            }))
          }
        }
        EnigmaHairline()
      }
    }
    .disabled(downloads.isDownloading)
    .padding(.top, 6)
    let bytes = repository.byteCount(of: selected)
    HStack(alignment: .top, spacing: 16) {
      EnigmaStatusLine(.problem, "Compatibility warning: these files may need another app or runtime. Enigma’s local chat supports text and images; audio is not yet supported. Include matching image/audio components and all weight shards. Downloading files does not automatically enable the model in Enigma.")
      Button("Download \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))…") {
        if let directory = sources.chooseFolder(model.name) {
          downloads.download(repository, selected: selected, into: directory)
        }
      }
      .enigmaButtonStyle(.primary)
      .disabled(selected.isEmpty || downloads.isDownloading)
      .enigmaTestMarker("Download selected files")
    }
    .padding(.top, 12)
  }
}

/// A Hugging Face download's progress, failure, or result.
struct HuggingFaceDownloadProgress: View {
  @ObservedObject var downloads: HuggingFaceModelDownloads
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    if downloads.isDownloading {
      VStack(alignment: .leading, spacing: 6) {
        EnigmaStatusLine(.busy, "Downloading \(downloads.repositoryID ?? "model")")
        if let progress = downloads.progress {
          EnigmaProgressBar(fraction: progress.fractionCompleted, width: nil)
          Text("\(progress.receivedByteCount.formatted(.byteCount(style: .file))) of \(progress.expectedByteCount.formatted(.byteCount(style: .file)))")
            .font(EnigmaTypography.mono(11))
            .foregroundStyle(palette.textTertiary.color)
        }
        HStack {
          Text(downloads.currentFile)
            .font(EnigmaTypography.mono(11))
            .foregroundStyle(palette.textSecondary.color)
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer()
          Button("Cancel download") { downloads.cancel() }.enigmaButtonStyle(.text)
        }
        EnigmaNote("You can close this panel while the download continues.")
      }
      .padding(.bottom, 8)
    } else if let error = downloads.error {
      EnigmaStatusLine(.problem, error).padding(.bottom, 8)
    } else if let folder = downloads.downloadedFolder {
      HStack {
        EnigmaStatusLine(.on, "Download complete")
        Spacer()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
          .enigmaButtonStyle(.secondary)
      }
      .padding(.bottom, 8)
    }
  }
}
