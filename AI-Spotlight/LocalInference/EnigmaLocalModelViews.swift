import SwiftUI

// The new UI's local model views: a choice row, the install progress, and the
// model sheet. They behave like `LocalModelChoiceCard`, `LocalModelOperationView`,
// and `LocalModelOnboardingView`, and Settings reuses them in phase 5.

/// One local model in a list of choices, with a selection dot.
struct EnigmaLocalModelChoiceRow: View {
  let assessment: LocalModelAssessment
  /// A short tag after the name, like "recommended". VoiceOver reads it too.
  var role: String?
  let isSelected: Bool
  let select: () -> Void
  @Environment(\.enigmaPalette) private var palette

  /// The monospace lines under the summary: the fit and speed, then the package.
  static func details(for assessment: LocalModelAssessment) -> [String] {
    let model = assessment.model
    return [
      "\(assessment.fit.rawValue) · \(assessment.performanceDescription)",
      "\(model.quantization) · \(model.performanceClass) · \(model.license)",
    ]
  }

  static func accessibilityLabel(for assessment: LocalModelAssessment, role: String?) -> String {
    [role, assessment.model.displayName, assessment.fit.rawValue].compactMap { $0 }.joined(separator: ", ")
  }

  var body: some View {
    EnigmaRow(assessment.model.displayName, badge: role, subtitle: assessment.model.summary,
              selection: isSelected, action: select) {
      VStack(alignment: .leading, spacing: 2) {
        ForEach(Self.details(for: assessment), id: \.self) { line in
          Text(line)
            .font(EnigmaTypography.mono(11))
            .foregroundStyle(palette.textTertiary.color)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(.top, 3)
    } trailing: {
      Text(assessment.model.downloadByteCount, format: .byteCount(style: .file))
        .font(EnigmaTypography.mono(11.5))
        .foregroundStyle(palette.textTertiary.color)
    }
    .accessibilityLabel(Self.accessibilityLabel(for: assessment, role: role))
    .accessibilityHint("\(ByteCountFormatter.string(fromByteCount: assessment.model.downloadByteCount, countStyle: .file)) download")
  }
}

/// What the local model runtime is doing: download progress, verification,
/// the performance check, failures, and the last measured speed.
struct EnigmaLocalModelOperationView: View {
  @ObservedObject var chat: LocalChatViewModel
  @ObservedObject var advisor: LocalModelAdvisor
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      switch chat.state {
      case .downloading(let progress):
        HStack(spacing: 12) {
          EnigmaStatusLine(.busy, progress.fractionCompleted < 1
            ? "downloading \(Int(progress.fractionCompleted * 100))%"
            : "verifying and installing package…")
          EnigmaProgressBar(fraction: progress.fractionCompleted)
          Spacer(minLength: 0)
          Button("Cancel") { chat.cancelInstallation() }.enigmaButtonStyle(.text)
        }
      case .installing:
        EnigmaStatusLine(.busy, "installing model…")
      case .deleting:
        EnigmaStatusLine(.busy, "deleting model…")
      case .benchmarking:
        HStack(spacing: 12) {
          EnigmaStatusLine(.busy, "checking performance on this Mac…")
          Spacer(minLength: 0)
          Button("Cancel") { chat.cancelInstallation() }.enigmaButtonStyle(.text)
        }
      case .failed(let message):
        EnigmaStatusLine(.problem, message)
      default:
        if let notice = chat.benchmarkNotice { note(notice) }
      }
      if let benchmark = advisor.latestBenchmark(for: chat.installedModel), !chat.isBusy {
        VStack(alignment: .leading, spacing: 2) {
          Text("first token \(benchmark.metrics.timeToFirstToken, specifier: "%.2f") s · generation \(benchmark.metrics.generationTokensPerSecond, specifier: "%.1f") tokens/s")
          Text("prompt \(benchmark.metrics.promptTokensPerSecond, specifier: "%.0f") tokens/s · peak app memory \(benchmark.metrics.peakMemoryBytes, format: .byteCount(style: .memory))")
        }
        .font(EnigmaTypography.mono(11))
        .foregroundStyle(palette.textTertiary.color)
        if benchmark.underperformed,
           let faster = advisor.recommendations(installedModels: chat.installedModels).fasterAlternative(to: benchmark.modelID) {
          EnigmaStatusLine(.problem, "This model ran slower than expected. For quicker replies, try \(faster.model.displayName) in the model manager.")
        }
      }
      if let notice = advisor.notice { note(notice) }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func note(_ text: String) -> some View {
    Text(text)
      .font(EnigmaTypography.ui(12))
      .foregroundStyle(palette.textSecondary.color)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// The model sheet in the new design. Same choices and actions as
/// `LocalModelOnboardingView`.
struct EnigmaLocalModelOnboardingView: View {
  @ObservedObject var advisor: LocalModelAdvisor
  @ObservedObject var chat: LocalChatViewModel
  @State private var selectedID: String?
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    let recommendations = advisor.recommendations(installedModels: chat.installedModels)
    let selected = recommendations.assessments.first { $0.id == selectedID && $0.fit.canRun }
      ?? recommendations.recommended
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center, spacing: 14) {
        EnigmaMark(style: .filled).frame(width: 30, height: 30)
        VStack(alignment: .leading, spacing: 3) {
          Text("Your Mac. Your AI.")
            .font(EnigmaTypography.ui(20, weight: .semibold))
            .tracking(-0.3)
            .foregroundStyle(palette.textPrimary.color)
          Text("Choose one model for private text chat and screenshots. We leave room for macOS and your other apps.")
            .font(EnigmaTypography.ui(13))
            .foregroundStyle(palette.textSecondary.color)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      VStack(alignment: .leading, spacing: 4) {
        if let hardware = advisor.hardware {
          EnigmaHint("\(hardware.chip) · \(hardware.physicalMemory.formatted(.byteCount(style: .memory))) memory")
        }
        EnigmaHint("Lightweight, middleweight and heavyweight choices for your Mac’s memory.")
      }
      .padding(.top, 12)
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(recommendations.tierGroups, id: \.weight) { group in
            EnigmaSectionHeader(group.weight.rawValue)
            ForEach(group.models) { assessment in
              EnigmaLocalModelChoiceRow(assessment: assessment,
                role: assessment.id == recommendations.recommended?.id ? "recommended" : nil,
                isSelected: selected?.id == assessment.id) { selectedID = assessment.id }
                .disabled(!assessment.fit.canRun)
            }
            EnigmaHairline()
          }
          if recommendations.rankedChoices.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
              EnigmaStatusLine(.problem, "No suitable model found")
              Text("No supported text-and-image model fits this Mac’s memory or disk budget. Review Local Models for the specific limits. Cloud is also available.")
                .font(EnigmaTypography.ui(12))
                .foregroundStyle(palette.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 20)
          }
        }
        .padding(.horizontal, 10)
        .disabled(chat.isBusy)
      }
      .padding(.horizontal, -10)
      .padding(.top, 4)
      EnigmaLocalModelOperationView(chat: chat, advisor: advisor).padding(.top, 12)
      Text("One download includes the model, matching image support and runtime. Every component is verified before installation.")
        .font(EnigmaTypography.ui(12))
        .foregroundStyle(palette.textSecondary.color)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 10)
      HStack(spacing: 12) {
        Button(chat.installedModels.isEmpty ? "Set Up Later" : "Done") { advisor.dismissOnboarding() }
          .enigmaButtonStyle(.text)
          .disabled(chat.isBusy)
        Spacer()
        if let selected {
          let existing = chat.installedModels.first { $0.id == selected.id }
          let installed = existing.map { !selected.model.requiresUpdate($0) } ?? false
          Button {
            if installed {
              chat.selectModel(id: selected.id)
              advisor.dismissOnboarding()
            } else {
              chat.downloadModel(selected.model)
            }
          } label: {
            HStack(spacing: 10) {
              Text(installed ? "Use Model" : "\(existing == nil ? "Download" : "Update") · \(ByteCountFormatter.string(fromByteCount: selected.model.downloadByteCount, countStyle: .file))")
              if installed { EnigmaKeycap("↵") }
            }
          }
          .enigmaButtonStyle(.primary)
          // Return never starts a download, as in the old sheet.
          .keyboardShortcut(installed ? .defaultAction : nil)
          .disabled(chat.isBusy)
        }
      }
      .padding(.top, 16)
    }
    .padding(24)
    .frame(width: 560, height: 650)
    .background(palette.background.color)
    .tint(palette.accent.color)
    .interactiveDismissDisabled(chat.isBusy)
  }
}
