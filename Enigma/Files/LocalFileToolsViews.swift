import SwiftUI

/// The file-tools runtime on the Local models page. It installs through
/// `LocalFileToolsInstallation`.
struct LocalFileToolsRow: View {
  let model: LocalModel?
  @StateObject private var installation: LocalFileToolsInstallation

  init(model: LocalModel?, installation: LocalFileToolsInstallation? = nil) {
    self.model = model
    _installation = StateObject(wrappedValue: installation ?? LocalFileToolsInstallation())
  }

  var body: some View {
    let ready = installation.isReady(for: model)
    EnigmaRow("Local file tools",
              subtitle: ready ? LocalFileToolsInstallation.readyText : LocalFileToolsInstallation.installText) {
      VStack(alignment: .leading, spacing: 6) {
        if !ready && installation.isInstalling {
          EnigmaProgressBar(fraction: installation.progress, width: nil, label: "File tools download progress")
        }
        if let error = installation.error { EnigmaStatusLine(.problem, error) }
      }
      .padding(.top, 4)
    } trailing: {
      if ready {
        EnigmaStatusLine(.on, "ready")
      } else if installation.isInstalling {
        Button("Cancel") { installation.cancel() }
          .enigmaButtonStyle(.text)
          .accessibilityLabel("Cancel file tools install")
      } else {
        Button("Install · 11 MB") { installation.start() }
          .enigmaButtonStyle(.secondary)
          .accessibilityLabel("Install Local File Tools (11 MB)")
      }
    }
    .onDisappear { installation.cancel() }
  }
}

/// Saved file changes, which can be reviewed and undone.
struct FileRecoveryRow: View {
  @ObservedObject var files: FileModeCoordinator
  @State private var selectedChange: WorkspaceChangeSet?
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.enigmaAppearance) private var appearance

  var body: some View {
    Group {
      if !files.changes.isEmpty {
        EnigmaRow("Saved file changes", subtitle: "Review the files Enigma changed, and undo them.") {
          EnigmaMenu("Review saved file changes", sections: [EnigmaMenuSection(items: files.changes.map { change in
            EnigmaMenuItem(id: change.id, title: "\(change.selection.displayName) · \(change.count) files") {
              selectedChange = change
            }
          })]) {
            Text("Review")
          }
        }
      }
    }
    .sheet(item: $selectedChange) { change in
      VStack(alignment: .leading) {
        FileChangesReview(changeSet: change) {
          Task {
            await files.undo(change)
            if !files.changes.contains(where: { $0.id == change.id }) { selectedChange = nil }
          }
        }.disabled(files.isWorking)
        if let error = files.error { EnigmaStatusLine(.problem, error).padding() }
      }
      .background(palette.background.color)
      .enigmaTheme(appearance)
    }
  }
}
