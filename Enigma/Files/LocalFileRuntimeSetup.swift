import Foundation
import SwiftUI

enum LocalFileRuntimeSetup {
  static var directory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "AI Spotlight/File Tools", directoryHint: .isDirectory)
  }
  static var executable: URL { directory.appending(path: LocalVisionRuntime.directoryName + "/llama-server") }

  static func install(progress: @escaping @Sendable (ModelDownloadProgress) async -> Void) async throws {
    if FileManager.default.isExecutableFile(atPath: executable.path) { return }
    let runtime = LocalVisionRuntime.bundled
    try runtime.validate()
    let staging = directory.deletingLastPathComponent().appending(path: ".file-tools-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: staging) }
    let archive = staging.appendingPathComponent("runtime.tar.gz")
    try await runtime.archive.download(to: archive, session: .shared, progress: progress)
    // Existing verified download/extraction path; this is app setup, never an agent command.
    _ = try await runtime.install(archive: archive, staging: staging, destination: directory)
  }
}

/// Installs the file-tools runtime once, with progress and cancellation.
@MainActor
final class LocalFileToolsInstallation: ObservableObject {
  typealias Install = @Sendable (@escaping @Sendable (ModelDownloadProgress) async -> Void) async throws -> Void

  @Published private(set) var isInstalling = false
  @Published private(set) var progress: Double = 0
  @Published private(set) var error: String?
  @Published private(set) var didInstall = false
  private var task: Task<Void, Never>?
  private let install: Install

  init(install: @escaping Install = { try await LocalFileRuntimeSetup.install(progress: $0) }) {
    self.install = install
  }

  /// Ready once installed here, or when the model already has a runtime.
  func isReady(for model: LocalModel?) -> Bool {
    didInstall || model.map { LocalFileRuntime.executable(for: $0) != nil } == true
  }

  func start() {
    guard !isInstalling else { return }
    isInstalling = true
    error = nil
    task = Task { @MainActor in
      defer { isInstalling = false; task = nil }
      do {
        try await install { update in
          await MainActor.run {
            self.progress = Double(update.receivedByteCount) / Double(max(1, update.expectedByteCount))
          }
        }
        didInstall = true
      } catch is CancellationError { }
      catch { self.error = error.localizedDescription }
    }
  }

  func cancel() { task?.cancel() }
}

extension LocalFileToolsInstallation {
  static let readyText = "Ready · Notes and text files can be edited locally. Protected edits offer Codex with your permission, or use a local fallback when Codex is unavailable. Review and Undo remain available."
  static let installText = "Install the small file-tools runtime once to analyze files with imported local models. This download sends no attached files."
}
